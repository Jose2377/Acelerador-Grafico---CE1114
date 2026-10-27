`timescale 1ns / 1ps

//=============================================================================
// Acelerador_Grafico_Top.sv
// Modulo   : Nivel superior, integracion de todos los bloques
//
// Camino que recorre un comando desde que el HPS lo escribe hasta que se ve
// en la pantalla:
//
//   CMD_FIFO_W -> ensamblador de paquete -> fifo -> decoder_fsm
//              -> processor_raster -> framebuffer_controller -> memoria
//              -> vga_controller -> conversor de video
//
// Papel de cada bloque instanciado:
//
//   fifo                    Cola de comandos; desacopla al software del ritmo del rasterizador
//   decoder_fsm             Valida, traduce y gobierna los modos MOE
//   processor_raster        Reparte el comando entre las cinco primitivas
//   framebuffer_controller  Agrupa pixeles en rafagas y arbitra la memoria
//   framebuffer_onchip      El framebuffer, cuando FB_ONCHIP esta activo
//   vga_controller          Prebusca lineas y produce la senal de video
//   rend_counter            Medidor de rendimiento de la ventana
//   led_status              Estado del sistema sobre los LED de la placa
//   sync2                   Los dos cruces de dominio de un bit
//
// Dos dominios de reloj. El de rasterizado y memoria va a 100 MHz; el de pixel lo fija la temporizacion VGA. 
// En la placa los produce un ALTPLL a partir del oscilador de 50 MHz, y no guardan relacion de fase: todo lo que
// cruza entre ellos pasa por sync2 (senales de un bit) o por las async_fifo
// que vivien dentro del gestor de framebuffer (direcciones y datos).
//
// Ensamblador de paquete. El puerto CMD_FIFO_W recibe las seis palabras de
// 32 bits del paquete de 24 bytes en orden W0 a W5, una por escritura. El
// contador palabra las va colocando y el comando entra en la cola al llegar
// la sexta. PARAM se toma directamente del puerto y no del registro, porque
// en ese ciclo w[5] todavia no esta escrito.
//
// FB_ONCHIP elige donde vive el framebuffer. Las dos ramas presentan el
// mismo Avalon-MM de rafaga, asi que sustituir la memoria interna por el
// controlador de SDRAM de la placa es cambiar el parametro, nada mas; el
// maestro queda expuesto en los puertos en los dos casos para poder
// observar la transaccion sin sondear la jerarquia.
//
// Lo que el HPS ve de todo esto son los registros del mapa: CONTROL (0x04),
// STATUS (0x08), CMD_FIFO_W (0x0C), ERR_INFO (0x10) y los de rendimiento
// (0x14 a 0x20), cableados a los puertos de este modulo.
//
// Entradas
//   clk, rst_n              dominio de rasterizado y SDRAM, 100 MHz
//   clk_pix, rst_pix_n      dominio de pixel, lo fija la temporizacion VGA
//   enable, reset_soft      bits del registro CONTROL (0x04)
//   comand_w_ena            pulso de escritura en COMAND_FIFO_W (0x0C)
//   comand_w_data           palabra del paquete, escritas en orden W0 a W5
//   sd_waitrequest          el medio de memoria no acepta la transaccion
//   sd_readdata             dato devuelto por la memoria
//   sd_readdatavalid        sd_readdata es valido en este ciclo
//
// Salidas
//   sd_read, sd_write, sd_address, sd_burstcount, sd_writedata
//                           maestro Avalon-MM de rafaga hacia el framebuffer
//                           (sin usar cuando FB_ONCHIP vale 1)
//   vga_r, vga_g, vga_b, vga_hs, vga_vs, vga_blank_n, vga_sync_n
//                           salida de video hacia el conversor de la placa
//   vga_underrun, vga_frames
//                           el barrido se quedo sin datos, y cuadros emitidos
//   px_valid, px_x, px_y, px_color, px_addr
//                           solicitud de pixel del rasterizador, para observacion
//   buffer_sel              buffer delantero, 0 = A y 1 = B
//   busy, modo, fifo_level, fifo_full, fifo_empty, overflow
//                           registro STATUS (0x08)
//   err_last, err_count     registro ERR_INFO (0x10)
//   perf_cycles, perf_commands, perf_pixels, perf_dropped
//                           registros de rendimiento (0x14 a 0x20)
//   seq_last, clip_count    auxiliares de instrumentacion
//   leds                    indicador de estado sobre los LED rojos de la placa
//   burst_writes, burst_reads, pixels_written, out_of_range
//                           instrumentacion del gestor de framebuffer
//=============================================================================
module Acelerador_Grafico_Top #(
  parameter int SCREEN_W   = Acelerador_pkg::SCREEN_W,
  parameter int SCREEN_H   = Acelerador_pkg::SCREEN_H,
  parameter int PIXEL_BITS = Acelerador_pkg::PIXEL_BITS,
  parameter int FIFO_DEPTH = Acelerador_pkg::FIFO_DEPTH,
  parameter int SYS_CLK_HZ = Acelerador_pkg::SYS_CLK_HZ,

  // Temporizacion del barrido de video.
  // Los valores por defecto son los reducidos del paquete, que es lo que usan
  // los bancos de pruebas; el nivel de placa los sobrescribe con la tabla VESA
  // de 640 x 480 a 60 Hz sin tocar el paquete ni la simulacion.
  //
  // Invariante: H_VISIBLE tiene que coincidir con SCREEN_W y V_VISIBLE con
  // SCREEN_H. Si no, el indice de pixel que produce vga_controller y el que
  // espera framebuffer_controller no tienen el mismo ancho.
  parameter int H_VISIBLE  = Acelerador_pkg::H_VISIBLE,
  parameter int H_FRONT    = Acelerador_pkg::H_FRONT,
  parameter int H_SYNC     = Acelerador_pkg::H_SYNC,
  parameter int H_BACK     = Acelerador_pkg::H_BACK,
  parameter int V_VISIBLE  = Acelerador_pkg::V_VISIBLE,
  parameter int V_FRONT    = Acelerador_pkg::V_FRONT,
  parameter int V_SYNC     = Acelerador_pkg::V_SYNC,
  parameter int V_BACK     = Acelerador_pkg::V_BACK,

  // Seleccion del medio que guarda el framebuffer.
  // 1 = framebuffer_onchip, 0 = el maestro de rafaga sale por los puertos
  parameter bit FB_ONCHIP  = 1'b1
)(
  // Dominio de rasterizado y SDRAM, 100 MHz
  input  logic               clk,
  input  logic               rst_n,

  // Dominio de pixel, lo fija la temporizacion VGA. En la placa los dos
  // relojes salen de un ALTPLL alimentado por el oscilador de 50 MHz.
  input  logic               clk_pix,
  input  logic               rst_pix_n,

  // Registro CONTROL (0x04)
  input  logic               enable,
  input  logic               reset_soft,

  // Puerto COMAND_FIFO_W (0x0C)
  // Las seis palabras del paquete, escritas en orden W0 a W5.
  input  logic               comand_w_ena,
  input  logic        [31:0] comand_w_data,

  // Maestro de rafaga Avalon-MM hacia el medio que guarda el framebuffer.
  output logic                                   sd_read,
  output logic                                   sd_write,
  output logic [Acelerador_pkg::SD_ADDR_BITS-1:0] sd_address,
  output logic [$clog2(Acelerador_pkg::BURST_LEN+1)-1:0] sd_burstcount,
  output logic [PIXEL_BITS-1:0]                  sd_writedata,
  input  logic                                   sd_waitrequest,
  input  logic [PIXEL_BITS-1:0]                  sd_readdata,
  input  logic                                   sd_readdatavalid,

  // Salida de video hacia el conversor de la placa
  output logic        [7:0]  vga_r, vga_g, vga_b,
  output logic               vga_hs,
  output logic               vga_vs,
  output logic               vga_blank_n,
  output logic               vga_sync_n,
  output logic               vga_underrun,
  output logic        [31:0] vga_frames,

  // Solicitud de pixel
  output logic               px_valid,
  output logic [$clog2(SCREEN_W)-1:0] px_x,
  output logic [$clog2(SCREEN_H)-1:0] px_y,
  output logic [PIXEL_BITS-1:0]       px_color,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0] px_addr,
  output logic               buffer_sel,

  // Registro STATUS (0x08)
  output logic               busy,
  output logic        [2:0]  modo,
  output logic [$clog2(FIFO_DEPTH):0] fifo_level,
  output logic               fifo_full,
  output logic               fifo_empty,
  output logic               overflow,

  // Registro ERR_INFO (0x10)
  output logic        [3:0]  err_last,
  output logic        [15:0] err_count,

  // Registros de rendimiento (0x14 a 0x20)
  output logic        [31:0] perf_cycles,
  output logic        [31:0] perf_commands,
  output logic        [31:0] perf_pixels,
  output logic        [31:0] perf_dropped,

  // Auxiliares
  output logic        [15:0] seq_last,
  output logic        [31:0] clip_count,

  // Indicador de estado sobre los LED rojos de la placa
  output logic        [9:0]  leds,

  // Instrumentacion del gestor de framebuffer
  output logic        [31:0] burst_writes,
  output logic        [31:0] burst_reads,
  output logic        [31:0] pixels_written,
  output logic        [31:0] out_of_range
);

  // Ensamblador de las seis palabras del paquete
  // Una escritura por palabra, en orden W0 a W5. El contador da la vuelta
  // sola tras la sexta, de modo que el paquete siguiente empieza sin que
  // nadie tenga que reiniciarlo.
  logic [2:0]  palabra;                 // 0 a 5
  logic [31:0] w [0:5];
  logic        comand_push;
  logic [Acelerador_pkg::COMAND_BITS-1:0] comand_data_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      palabra <= '0;
      for (int i = 0; i < 6; i++) w[i] <= '0;
    end else if (reset_soft) begin
      palabra <= '0;
    end else if (comand_w_ena) begin
      w[palabra] <= comand_w_data;
      if (palabra == 3'd5) palabra <= '0;
      else                 palabra <= palabra + 3'd1;
    end
  end

  // El comando entra en la cola en el mismo ciclo en que llega W5.
  assign comand_push = comand_w_ena && (palabra == 3'd5);

  // PARAM se toma del puerto y no de w[5]: en este ciclo el registro
  // todavia no tiene el valor, que se escribe en el flanco.

  assign comand_data_in = {
    w[0][31:24],            // OPCODE
    w[0][23:16],            // FLAGS
    w[0][15:0],             // SEQ_ID
    w[1][31:16], w[1][15:0],// x0, y0
    w[2][31:16], w[2][15:0],// x1, y1
    w[3][31:16], w[3][15:0],// x2, y2
    w[4][23:16],            // R
    w[4][15:8],             // G
    w[4][7:0],              // B
    comand_w_data[15:0]     // PARAM, desde el puerto
  };

  // FIFO
  logic        fifo_rd, fifo_data_out_valid, fifo_drop;
  logic [Acelerador_pkg::COMAND_BITS-1:0] fifo_data_out;
  logic [15:0] drop_count;
  logic        init_flush;

  fifo #(.DATA_W(Acelerador_pkg::COMAND_BITS), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk(clk), .rst_n(rst_n), .flush(init_flush),
    .wr_ena(comand_push), .data_in(comand_data_in),
    .rd_ena(fifo_rd), .data_out(fifo_data_out), .data_out_valid(fifo_data_out_valid),
    .full(fifo_full), .empty(fifo_empty), .level(fifo_level),
    .drop(fifo_drop), .drop_count(drop_count));

  // MOE-01 vacia la cola.
  assign init_flush = (modo == Acelerador_pkg::MOE_INIT);
  assign overflow = (drop_count != 16'd0);

  // Decodificador y maquina de estados del sistema
  logic        ras_start, ras_busy, ras_done;
  logic [3:0]  ras_op;
  logic signed [15:0] ras_x0, ras_y0, ras_x1, ras_y1, ras_x2, ras_y2;
  logic [9:0]  ras_radius;
  logic [7:0]  ras_r, ras_g, ras_b;
  logic        perf_latch, perf_clear, comand_tick;
  logic [31:0] comand_count;
  logic        vsync_sys;             // VSYNC ya sincronizado

  decoder_fsm #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_decoder (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .soft_reset(reset_soft),
    .fifo_empty(fifo_empty), .fifo_data_out(fifo_data_out),
    .fifo_data_out_valid(fifo_data_out_valid), .fifo_drop(fifo_drop),
    .fifo_rd(fifo_rd),
    .ras_start(ras_start), .ras_op(ras_op),
    .ras_x0(ras_x0), .ras_y0(ras_y0), .ras_x1(ras_x1), .ras_y1(ras_y1),
    .ras_x2(ras_x2), .ras_y2(ras_y2), .ras_radius(ras_radius),
    .ras_r(ras_r), .ras_g(ras_g), .ras_b(ras_b),
    .ras_busy(ras_busy), .ras_done(ras_done),
    .vsync(vsync_sys), .buffer_sel(buffer_sel),
    .perf_latch(perf_latch), .perf_clear(perf_clear),
    .modo(modo), .busy(busy),
    .err_last(err_last), .err_count(err_count),
    .comand_count(comand_count), .comand_tick(comand_tick), .seq_last(seq_last));

  // Procesador de comandos y rasterizador 2D
  logic [31:0] pix_count;
  logic        px_ready;

  processor_raster #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H),
                     .PIXEL_BITS(PIXEL_BITS)) u_raster (
    .clk(clk), .rst_n(rst_n),
    .stall(!px_ready),
    .start(ras_start), .op(ras_op),
    .x0(ras_x0), .y0(ras_y0), .x1(ras_x1), .y1(ras_y1),
    .x2(ras_x2), .y2(ras_y2), .radius(ras_radius),
    .color_r(ras_r), .color_g(ras_g), .color_b(ras_b),
    .clr_cnt(perf_clear),
    .busy(ras_busy), .done(ras_done),
    .px_valid(px_valid), .px_x(px_x), .px_y(px_y),
    .px_color(px_color), .px_addr(px_addr),
    .pix_count(pix_count), .clip_count(clip_count));

  // Medidor de rendimiento
  //
  // Se mide el tiempo de rasterizacion, es decir los ciclos con un comando en vuelo
  // NO los ciclos de reloj transcurridos. 
  // Eso hace comparables dos ventanas aunque entre ellas el sistema haya estado esperando a la red.
  
  logic [31:0] ciclos, comandos, pixeles, descartes;
  logic        ventana_reset, px_tick;

  assign ventana_reset = perf_clear || (modo == Acelerador_pkg::MOE_INIT);

  // Un pixel cuenta cuando el gestor de framebuffer lo acepta, no cuando el rasterizador lo presenta.
  // Con contrapresion el mismo pixel se presenta varios ciclos seguidos.
  assign px_tick = px_valid && px_ready;

  rend_counter u_rend (
    .clk(clk), .rst_n(rst_n),
    .latch(perf_latch), .ventana_reset(ventana_reset),
    .rasterizando(busy && enable),
    .comand_tick(comand_tick), .px_tick(px_tick), .drop_tick(fifo_drop),
    .ciclos(ciclos), .comandos(comandos),
    .pixeles(pixeles), .descartes(descartes),
    .perf_cycles(perf_cycles), .perf_commands(perf_commands),
    .perf_pixels(perf_pixels), .perf_dropped(perf_dropped));

  // Indicador de estado
  // El error llega como pulso de un ciclo, asi que el modulo lo alarga hasta
  // hacerlo visible. Aqui solo se detecta el flanco del contador de errores.
  
  logic [15:0] err_count_q;
  logic        err_tick;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) err_count_q <= '0;
    else        err_count_q <= err_count;
  end

  assign err_tick = (err_count != err_count_q);

  led_status #(.SYS_CLK_HZ(SYS_CLK_HZ)) u_leds (
    .clk(clk), .rst_n(rst_n),
    .modo(modo), .busy(busy), .err_tick(err_tick),
    .overflow(overflow), .fifo_full(fifo_full),
    .buffer_sel(buffer_sel), .underrun(vga_underrun),
    .leds(leds));

  // Cruces entre los dos dominios de reloj
  // Son los dos unicos de un bit: la seleccion de buffer baja al dominio de
  // pixel y VSYNC sube al de rasterizado, donde MOE-04 lo espera para hacer
  // efectivo el intercambio. Los buses cruzan por las async_fifo del gestor.
  logic front_buffer_pix;            // buffer_sel visto desde el dominio pixel
  logic vsync_pix;                    // VSYNC activo en alto, dominio de pixel

  // Puerto de lectura del barrido,lo cierra el gestor de framebuffer. 
  // Vive entero en el dominio de pixel.
  logic                                   fb_req, fb_front, fb_ready, fb_valid;
  logic [$clog2(SCREEN_W*SCREEN_H)-1:0]   fb_addr;
  logic [PIXEL_BITS-1:0]                  fb_data;


  sync2 #(.VALOR_RESET(1'b0)) u_sync_buffer (
    .clk_dst(clk_pix), .rst_n(rst_pix_n),
    .data_in(buffer_sel), .data_out(front_buffer_pix));

  sync2 #(.VALOR_RESET(1'b0)) u_sync_vsync (
    .clk_dst(clk), .rst_n(rst_n),
    .data_in(vsync_pix), .data_out(vsync_sys));

  // VGA controller
  vga_controller #(
    .H_VISIBLE(H_VISIBLE), .H_FRONT(H_FRONT),
    .H_SYNC(H_SYNC),       .H_BACK(H_BACK),
    .V_VISIBLE(V_VISIBLE), .V_FRONT(V_FRONT),
    .V_SYNC(V_SYNC),       .V_BACK(V_BACK),
    .H_POL(Acelerador_pkg::VGA_HS_POL),    .V_POL(Acelerador_pkg::VGA_VS_POL),
    .PIXEL_BITS(PIXEL_BITS),
    .LINES(Acelerador_pkg::LINE_BUF_LINES)
  ) u_vga (
    .clk_pix(clk_pix), .rst_n(rst_pix_n),
    .front_buffer(front_buffer_pix),
    .frame_buffer_req(fb_req), .frame_buffer_addr(fb_addr),
    .frame_buffer_front(fb_front),
    .frame_buffer_ready(fb_ready), .frame_buffer_data_in(fb_data),
    .frame_buffer_valid_in(fb_valid),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .vga_hs(vga_hs), .vga_vs(vga_vs),
    .vga_blank_n(vga_blank_n), .vga_sync_n(vga_sync_n),
    .vsync_act(vsync_pix),
    .underrun(vga_underrun), .frame_count(vga_frames));

  // Gestor de framebuffer
  logic vaciar_combinador;
  assign vaciar_combinador = !ras_busy;

  // Maestro de rafaga del gestor. Se mantiene como cable interno para que el
  // medio que lo atiende sea intercambiable sin tocar la instancia.
  logic                                           m_read, m_write;
  logic [Acelerador_pkg::SD_ADDR_BITS-1:0]        m_address;
  logic [$clog2(Acelerador_pkg::BURST_LEN+1)-1:0] m_burstcount;
  logic [PIXEL_BITS-1:0]                          m_writedata;
  logic                                           m_waitrequest;
  logic [PIXEL_BITS-1:0]                          m_readdata;
  logic                                           m_readdatavalid;

  framebuffer_controller #(
    .SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H), .PIXEL_BITS(PIXEL_BITS),
    .BURST_LEN(Acelerador_pkg::BURST_LEN),
    .SD_ADDR_BITS(Acelerador_pkg::SD_ADDR_BITS),
    .FB_BASE_A(Acelerador_pkg::FB_BASE_A),
    .FB_BASE_B(Acelerador_pkg::FB_BASE_B)
  ) u_fbc (
    .clk(clk), .rst_n(rst_n),
    .px_valid(px_valid), .px_addr(px_addr), .px_color(px_color),
    .px_ready(px_ready),
    .buffer_sel(buffer_sel), .vaciar(vaciar_combinador),
    .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
    .frame_buffer_req(fb_req), .frame_buffer_addr(fb_addr),
    .frame_buffer_front(fb_front), .frame_buffer_ready(fb_ready),
    .frame_buffer_data_in(fb_data), .frame_buffer_valid_in(fb_valid),
    .sd_read(m_read), .sd_write(m_write), .sd_address(m_address),
    .sd_burstcount(m_burstcount), .sd_writedata(m_writedata),
    .sd_waitrequest(m_waitrequest), .sd_readdata(m_readdata),
    .sd_readdatavalid(m_readdatavalid),
    .burst_writes(burst_writes), .burst_reads(burst_reads),
    .pixels_written(pixels_written), .out_of_range(out_of_range));

  // Medio que guarda el framebuffer
  //
  // Las dos ramas presentan el mismo Avalon-MM de rafaga, de modo que el
  // gestor no distingue una de otra. Sustituir la memoria interna por el
  // controlador de SDRAM es cambiar este parametro, nada mas.
  generate
    if (FB_ONCHIP) begin : g_fb_interno
      framebuffer_onchip #(
        .SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H), .PIXEL_BITS(PIXEL_BITS),
        .BURST_LEN(Acelerador_pkg::BURST_LEN),
        .SD_ADDR_BITS(Acelerador_pkg::SD_ADDR_BITS),
        .FB_BASE_A(Acelerador_pkg::FB_BASE_A),
        .FB_BASE_B(Acelerador_pkg::FB_BASE_B)
      ) u_fbmem (
        .clk(clk), .rst_n(rst_n),
        .sd_read(m_read), .sd_write(m_write), .sd_address(m_address),
        .sd_burstcount(m_burstcount), .sd_writedata(m_writedata),
        .sd_waitrequest(m_waitrequest), .sd_readdata(m_readdata),
        .sd_readdatavalid(m_readdatavalid),
        .words_written(), .words_read(), .range_errors());
    end else begin : g_fb_externo
      assign m_waitrequest   = sd_waitrequest;
      assign m_readdata      = sd_readdata;
      assign m_readdatavalid = sd_readdatavalid;
    end
  endgenerate

  // Las salidas reflejan el maestro en las dos ramas: con el framebuffer
  // interno dejan ver la transaccion sin sondear la jerarquia.
  assign sd_read       = m_read;
  assign sd_write      = m_write;
  assign sd_address    = m_address;
  assign sd_burstcount = m_burstcount;
  assign sd_writedata  = m_writedata;

endmodule
