module framebuffer_controller #(
  parameter int SCREEN_W      = 64,
  parameter int SCREEN_H      = 48,
  parameter int PIXEL_BITS    = 16,
  parameter int BURST_LEN     = 8,
  parameter int SD_ADDR_BITS  = 25,
  parameter int FB_BASE_A     = 0,
  parameter int FB_BASE_B     = 'h100000,
  parameter int RD_FIFO_DEPTH = 16
)(
  // Dominio de rasterizado y SDRAM
  input  logic clk,
  input  logic rst_n,

  // Puerto de escritura del rasterizador.
  // Con px_ready en bajo el rasterizador se congela y mantiene el pixel hasta que se acepte.
  input  logic                                   px_valid,
  input  logic [$clog2(SCREEN_W*SCREEN_H)-1:0]   px_addr,      // Indice de pixel
  input  logic [PIXEL_BITS-1:0]                  px_color,
  output logic                                   px_ready,

  // 0 = buffer A delante, 1 = buffer B. 
  // El rasterizador escribe siempre en el contrario.
  input  logic                                   buffer_sel,

  // Vaciado del combinador. 
  // El nivel superior lo activa cuando el rasterizador queda inactivo.
  // Para que la ultima rafaga incompleta no se quede esperando un pixel que no va a llegar.
  input  logic                                   vaciar,

  // Dominio de pixel (VGA)
  input  logic clk_pix,
  input  logic rst_pix_n,

  input  logic                                   frame_buffer_req,
  input  logic [$clog2(SCREEN_W*SCREEN_H)-1:0]   frame_buffer_addr,
  input  logic                                   frame_buffer_front,
  output logic                                   frame_buffer_ready,
  output logic [PIXEL_BITS-1:0]                  frame_buffer_data_in,
  output logic                                   frame_buffer_valid_in,

  // Maestro de rafaga hacia el controlador SDRAM
  // Avalon-MM de rafaga. Lo implementara sdram_controller.
  // ACTUALMENTE SOLO modela el banco de pruebas.
  output logic                                   sd_read,
  output logic                                   sd_write,
  output logic [SD_ADDR_BITS-1:0]                sd_address,
  output logic [$clog2(BURST_LEN+1)-1:0]         sd_burstcount,
  output logic [PIXEL_BITS-1:0]                  sd_writedata,
  input  logic                                   sd_waitrequest,
  input  logic [PIXEL_BITS-1:0]                  sd_readdata,
  input  logic                                   sd_readdatavalid,

  // Estado
  output logic [31:0] burst_writes,    // Transacciones de escritura emitidas
  output logic [31:0] burst_reads,     // Transacciones de lectura emitidas
  output logic [31:0] pixels_written,  // Pixeles aceptados del rasterizador
  output logic [31:0] out_of_range     // Escrituras descartadas por region
);

  localparam int PXAW      = $clog2(SCREEN_W*SCREEN_H);
  localparam int BCW       = $clog2(BURST_LEN+1);
  localparam int IDXW      = $clog2(BURST_LEN);
  localparam int FB_PIXELS = SCREEN_W * SCREEN_H;

  // Base del buffer segun quien pregunte.
  function automatic logic [SD_ADDR_BITS-1:0] base_de(input logic buf_b);
    base_de = buf_b ? SD_ADDR_BITS'(FB_BASE_B) : SD_ADDR_BITS'(FB_BASE_A);
  endfunction

  // Cruce de dominios del barrido
  // El bit alto acompana al indice para que cada peticion lleve su propio
  // buffer y no dependa de cuando se sincronice el selector.
  logic          arf_wr, arf_full, arf_rd, arf_empty;
  logic [PXAW:0] arf_data_in, arf_data_out;

  assign arf_wr             = frame_buffer_req && !arf_full;
  assign arf_data_in        = {frame_buffer_front, frame_buffer_addr};
  assign frame_buffer_ready = !arf_full;

  async_fifo #(.DATA_W(PXAW+1), .DEPTH(RD_FIFO_DEPTH)) u_arf (
    .wr_clk(clk_pix), .wr_rst_n(rst_pix_n),
    .wr_ena(arf_wr), .data_in(arf_data_in), .full(arf_full),
    .rd_clk(clk), .rd_rst_n(rst_n),
    .rd_ena(arf_rd), .data_out(arf_data_out), .empty(arf_empty));

  logic                  drf_wr, drf_full, drf_rd, drf_empty;
  logic [PIXEL_BITS-1:0] drf_data_in;

  logic [PIXEL_BITS-1:0] drf_data_out;

  async_fifo #(.DATA_W(PIXEL_BITS), .DEPTH(RD_FIFO_DEPTH)) u_drf (
    .wr_clk(clk), .wr_rst_n(rst_n),
    .wr_ena(drf_wr), .data_in(drf_data_in), .full(drf_full),
    .rd_clk(clk_pix), .rd_rst_n(rst_pix_n),
    .rd_ena(drf_rd), .data_out(drf_data_out), .empty(drf_empty));

  // Se extrae un dato por ciclo mientras haya.
  // Si solo se registrara el valid, llegaria acompanando al elemento siguiente
  // y toda la linea saldria corrida una posicion.
  assign drf_rd = !drf_empty;

  always_ff @(posedge clk_pix or negedge rst_pix_n) begin
    if (!rst_pix_n) begin
      frame_buffer_valid_in <= 1'b0;
      frame_buffer_data_in  <= '0;
    end else begin
      frame_buffer_valid_in <= drf_rd;
      if (drf_rd) frame_buffer_data_in <= drf_data_out;
    end
  end

  // Declaraciones de las dos maquinas
  typedef enum logic [1:0] {R_LIBRE, R_AGRUPA, R_PIDE, R_DATOS} rdst_e;
  typedef enum logic [1:0] {W_LIBRE, W_PIDE, W_DATOS}           wrst_e;

  rdst_e rd_st;
  wrst_e wr_st;

  logic [PXAW-1:0] rd_base;
  logic            rd_buf;
  logic [BCW-1:0]  rd_cnt, rd_recibidos;

  logic [PXAW-1:0]       wr_base;
  logic                  wr_buf;
  logic [BCW-1:0]        wr_cnt, wr_enviados;
  logic [PIXEL_BITS-1:0] wr_datos [0:BURST_LEN-1];
  logic                  vaciar_pend;   // Hay rafaga que mandar antes de seguir

  // Arbitro de prioridad fija
  // La lectura del barrido gana siempre. 
  // La escritura solo arranca si la lectura no esta activa ni tiene trabajo esperando.
  // Una vez arrancada se completa, no se puede detener.
  
  logic lectura_activa, escritura_activa, permiso_escritura, permiso_lectura;

  assign lectura_activa    = (rd_st != R_LIBRE);
  assign escritura_activa  = (wr_st != W_LIBRE);


  assign permiso_escritura = (rd_st == R_LIBRE)
                          || ((rd_st == R_AGRUPA) && !rd_listo);
  assign permiso_lectura   = !escritura_activa;


  // Agrupador de lectura

  // El barrido pide direcciones consecutivas de una en una. 
  // Aqui se juntan las que lo sean en una sola rafaga.
  // El agrupador espera un poco a que lleguen.
  // PACIENCIA acota esa espera para que una peticion suelta no se quede retenida indefinidamente.
  
  localparam int PACIENCIA = 16;      // ciclos sin direccion nueva

  logic rd_contiguo, rd_frontera, rd_cabe, rd_hay_sitio, rd_listo;
  logic [$clog2(PACIENCIA+1)-1:0] rd_espera;

  assign rd_contiguo  = !arf_empty
                     && (arf_data_out[PXAW-1:0] == rd_base + PXAW'(rd_cnt))
                     && (arf_data_out[PXAW] == rd_buf);
  assign rd_frontera  = (((rd_base + PXAW'(rd_cnt)) % PXAW'(BURST_LEN)) == '0);
  assign rd_cabe      = (rd_cnt < BCW'(BURST_LEN));
  assign rd_hay_sitio = !drf_full;

  // La rafaga esta lista para emitirse cuando ya no puede crecer
  // O cuando se agote la espera por direcciones nuevas.
  assign rd_listo = !rd_cabe || rd_frontera
                 || (rd_espera >= $clog2(PACIENCIA+1)'(PACIENCIA));

  always_comb begin
    arf_rd = 1'b0;
    case (rd_st)
      R_LIBRE:  arf_rd = !arf_empty && rd_hay_sitio;
      R_AGRUPA: arf_rd = rd_contiguo && rd_cabe && !rd_frontera;
      default:  arf_rd = 1'b0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_st        <= R_LIBRE;
      rd_base      <= '0;
      rd_buf       <= 1'b0;
      rd_cnt       <= '0;
      rd_recibidos <= '0;
      rd_espera    <= '0;
      burst_reads  <= '0;
    end else begin
      case (rd_st)
        R_LIBRE: if (arf_rd) begin
          rd_base   <= arf_data_out[PXAW-1:0];
          rd_buf    <= arf_data_out[PXAW];
          rd_cnt    <= BCW'(1);
          rd_espera <= '0;
          rd_st     <= R_AGRUPA;
        end

        R_AGRUPA: begin
          if (arf_rd) begin
            rd_cnt    <= rd_cnt + 1'b1;
            rd_espera <= '0;
          end else if (rd_listo && permiso_lectura) begin
            rd_st <= R_PIDE;
          end else if (!rd_listo) begin
            rd_espera <= rd_espera + 1'b1;
          end
        end

        R_PIDE: if (!sd_waitrequest) begin
          burst_reads  <= burst_reads + 32'd1;
          rd_recibidos <= '0;
          rd_st        <= R_DATOS;
        end

        R_DATOS: if (sd_readdatavalid) begin
          if (rd_recibidos == rd_cnt - 1'b1) rd_st <= R_LIBRE;
          else rd_recibidos <= rd_recibidos + 1'b1;
        end

        default: rd_st <= R_LIBRE;
      endcase
    end
  end

  assign drf_wr      = sd_readdatavalid && (rd_st == R_DATOS);
  assign drf_data_in = sd_readdata;

  // Combinador de escritura
  logic wr_extiende, wr_frontera, wr_cabe, wr_en_region, wr_cierra;

  // Restriccion de region: el indice tiene que caer dentro del buffer.
  assign wr_en_region = (px_addr < PXAW'(FB_PIXELS));

  assign wr_frontera  = (((wr_base + PXAW'(wr_cnt)) % PXAW'(BURST_LEN)) == '0);
  assign wr_cabe      = (wr_cnt < BCW'(BURST_LEN));
  assign wr_extiende  = (wr_cnt != '0)
                     && (px_addr == wr_base + PXAW'(wr_cnt))
                     && wr_cabe && !wr_frontera;

  // Se acepta el pixel si cabe en la rafaga en curso o si no hay ninguna.

  assign px_ready = (wr_st == W_LIBRE) && !vaciar_pend
                 && (!px_valid || !wr_en_region
                     || (wr_cnt == '0) || wr_extiende);

  // El pixel que llega no cabe en la rafaga en curso: hay que vaciarla
  // primero. px_ready ya esta en bajo, asi que el rasterizador lo vuelve a
  // presentar cuando se le acepte.
  assign wr_cierra = (wr_st == W_LIBRE) && !vaciar_pend && px_valid
                  && wr_en_region && (wr_cnt != '0) && !wr_extiende;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_st          <= W_LIBRE;
      wr_base        <= '0;
      wr_buf         <= 1'b0;
      wr_cnt         <= '0;
      wr_enviados    <= '0;
      vaciar_pend    <= 1'b0;
      burst_writes   <= '0;
      pixels_written <= '0;
      out_of_range   <= '0;
      for (int i = 0; i < BURST_LEN; i++) wr_datos[i] <= '0;
    end else begin
      case (wr_st)
        W_LIBRE: begin
          if (vaciar_pend) begin
            if (permiso_escritura) wr_st <= W_PIDE;

          end else if (wr_cierra) begin
            vaciar_pend <= 1'b1;

          end else if (px_valid && px_ready) begin
            if (!wr_en_region) begin
              out_of_range <= out_of_range + 32'd1;

            end else if (wr_cnt == '0) begin
              // Primera palabra de una rafaga nueva.
              wr_base        <= px_addr;
              wr_buf         <= ~buffer_sel;     // siempre el buffer trasero
              wr_datos[0]    <= px_color;
              wr_cnt         <= BCW'(1);
              pixels_written <= pixels_written + 32'd1;
              if (((px_addr + PXAW'(1)) % PXAW'(BURST_LEN)) == '0)
                vaciar_pend <= 1'b1;

            end else begin
              // Extiende la rafaga en curso.
              wr_datos[wr_cnt[IDXW-1:0]] <= px_color;
              wr_cnt                     <= wr_cnt + 1'b1;
              pixels_written             <= pixels_written + 32'd1;
              if ((wr_cnt + 1'b1 == BCW'(BURST_LEN)) ||
                  (((px_addr + PXAW'(1)) % PXAW'(BURST_LEN)) == '0))
                vaciar_pend <= 1'b1;
            end
          end
        end

        W_PIDE: if (!sd_waitrequest) begin
          burst_writes <= burst_writes + 32'd1;
          // La primera palabra viaja con la peticion.
          if (wr_cnt == BCW'(1)) begin
            wr_cnt      <= '0;
            vaciar_pend <= 1'b0;
            wr_st       <= W_LIBRE;
          end else begin
            wr_enviados <= BCW'(1);
            wr_st       <= W_DATOS;
          end
        end

        W_DATOS: if (!sd_waitrequest) begin
          if (wr_enviados == wr_cnt - 1'b1) begin
            wr_cnt      <= '0;
            vaciar_pend <= 1'b0;
            wr_st       <= W_LIBRE;
          end else begin
            wr_enviados <= wr_enviados + 1'b1;
          end
        end

        default: wr_st <= W_LIBRE;
      endcase

      // Vaciado pedido desde fuera: el rasterizador quedo inactivo y la
      // rafaga incompleta tiene que llegar a memoria.
      if (vaciar && (wr_cnt != '0) && (wr_st == W_LIBRE)) vaciar_pend <= 1'b1;
    end
  end

  // Puerto hacia la SDRAM
  assign sd_read  = (rd_st == R_PIDE);
  assign sd_write = (wr_st == W_PIDE) || (wr_st == W_DATOS);

  // El multiplexor se gobierna por sd_write y no por el estado de lectura:
  // una rafaga de escritura en curso conserva su direccion pase lo que pase
  // al otro lado.
  always_comb begin
    if (sd_write) begin
      sd_address    = base_de(wr_buf) + SD_ADDR_BITS'(wr_base);
      sd_burstcount = BCW'(wr_cnt);
    end else begin
      sd_address    = base_de(rd_buf) + SD_ADDR_BITS'(rd_base);
      sd_burstcount = BCW'(rd_cnt);
    end
  end

  assign sd_writedata = (wr_st == W_PIDE) ? wr_datos[0]
                                          : wr_datos[wr_enviados[IDXW-1:0]];

`ifndef SYNTHESIS
  initial begin
    if ((BURST_LEN < 2) || ((BURST_LEN & (BURST_LEN - 1)) != 0))
      $error("framebuffer_controller: BURST_LEN (%0d) debe ser potencia de dos",
             BURST_LEN);
  end
`endif

endmodule
