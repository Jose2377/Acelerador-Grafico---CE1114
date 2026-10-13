//=============================================================================
// tb_Acelerador_Grafico_Top.sv
// Banco de pruebas del camino completo: paquete de 24 bytes, cola,
// decodificador, rasterizador y generador de pixeles
//
// Los comandos ya no se inyectan decodificados: se escriben como las seis
// palabras del paquete sobre el puerto CMD_FIFO_W, en el mismo orden en que
// lo hara el driver. Eso pone a prueba el ensamblador, la cola y la maquina
// de estados ademas de la geometria.
//
// El banco de pruebas no dibuja: mide y vuelca. Produce dos archivos que la
// herramienta de visualizacion en Python convierte en imagenes y en una
// tabla de resultados:
//
//   raster_dump.csv     un fotograma por escena, con los pixeles escritos
//   raster_pruebas.csv  una fila por comprobacion
//
// Uso:  vsim -c -do "run -all" tb_Acelerador_Grafico_Top
//       python ver_raster.py
//=============================================================================
module tb_Acelerador_Grafico_Top;

  import Acelerador_pkg::*;

  // Constantes del paquete traidas con el nombre calificado: una importacion
  // comodin no resuelve igual en todas las herramientas.
  localparam logic [7:0] OPC_NOP       = Acelerador_pkg::OPC_NOP;
  localparam logic [7:0] OPC_PIXEL     = Acelerador_pkg::OPC_PIXEL;
  localparam logic [7:0] OPC_LINE      = Acelerador_pkg::OPC_LINE;
  localparam logic [7:0] OPC_TRIA      = Acelerador_pkg::OPC_TRIA;
  localparam logic [7:0] OPC_TRIA_FILL = Acelerador_pkg::OPC_TRIA_FILL;
  localparam logic [7:0] OPC_RECT      = Acelerador_pkg::OPC_RECT;
  localparam logic [7:0] OPC_RECT_FILL = Acelerador_pkg::OPC_RECT_FILL;
  localparam logic [7:0] OPC_CIRC      = Acelerador_pkg::OPC_CIRC;
  localparam logic [7:0] OPC_CIRC_FILL = Acelerador_pkg::OPC_CIRC_FILL;
  localparam logic [7:0] OPC_CLEAR     = Acelerador_pkg::OPC_CLEAR;
  localparam logic [7:0] OPC_SWAP      = Acelerador_pkg::OPC_SWAP;
  localparam logic [7:0] OPC_INF       = Acelerador_pkg::OPC_INF;

  localparam logic [2:0] M_INIT  = Acelerador_pkg::MOE_INIT;
  localparam logic [2:0] M_IDLE  = Acelerador_pkg::MOE_IDLE;
  localparam logic [2:0] M_PROC  = Acelerador_pkg::MOE_PROC;
  localparam logic [2:0] M_SWAP  = Acelerador_pkg::MOE_SWAP;
  localparam logic [2:0] M_INFO  = Acelerador_pkg::MOE_INFO;
  localparam logic [2:0] M_ERROR = Acelerador_pkg::MOE_ERROR;

  localparam int W  = 64;
  localparam int H  = 48;
  localparam int PB = 16;
  localparam int FD = Acelerador_pkg::FIFO_DEPTH;
  localparam int AW = $clog2(W*H);

  //------------------------------------------------------- relojes y reinicio
  // Dos dominios sin relacion de fase, como en la placa. El de pixel se
  // elige deliberadamente con un periodo que no es multiplo entero del otro,
  // para que los flancos caigan en todas las posiciones relativas posibles y
  // los sincronizadores trabajen de verdad.
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz

  logic clk_pix = 1'b0;
  logic rst_pix_n = 1'b0;
  always #19.7 clk_pix = ~clk_pix;      // 25,38 MHz, primo con el anterior

  //----------------------------------------------------------- senales
  logic               enable, reset_soft;
  logic               comand_w_ena;
  logic        [31:0] comand_w_data;

  // Maestro de rafaga hacia la SDRAM, atendido por el modelo del banco
  logic               sd_read, sd_write, sd_waitrequest, sd_readdatavalid;
  logic [Acelerador_pkg::SD_ADDR_BITS-1:0] sd_address;
  logic [$clog2(Acelerador_pkg::BURST_LEN+1)-1:0] sd_burstcount;
  logic [PB-1:0]      sd_writedata, sd_readdata;

  // Instrumentacion del gestor de framebuffer
  logic [31:0]        burst_writes, burst_reads, pixels_written, out_of_range;
  logic [9:0]         leds;

  // Salida de video
  logic        [7:0]  vga_r, vga_g, vga_b;
  logic               vga_hs, vga_vs, vga_blank_n, vga_sync_n;
  logic               vga_underrun;
  logic        [31:0] vga_frames;

  logic               px_valid;
  logic [$clog2(W)-1:0] px_x;
  logic [$clog2(H)-1:0] px_y;
  logic [PB-1:0]      px_color;
  logic [AW-1:0]      px_addr;
  logic               buffer_sel;
  logic               busy;
  logic        [2:0]  modo;
  logic [$clog2(FD):0] fifo_level;
  logic               fifo_full, fifo_empty, overflow;
  logic        [3:0]  err_last;
  logic        [15:0] err_count;
  logic        [31:0] perf_cycles, perf_commands, perf_pixels, perf_dropped;
  logic        [15:0] seq_last;
  logic        [31:0] clip_count;

  // El reloj declarado al indicador de estado se reduce a proposito: con los
  // 100 MHz reales un destello dura 12 millones de ciclos y no cabria en la
  // simulacion. La logica que se verifica es la misma.
  localparam int LED_CLK_HZ   = 10_000;
  localparam int LED_DESTELLO = (LED_CLK_HZ / 1000) * 120;   // 1200 ciclos
  localparam int LED_LATIDO   = (LED_CLK_HZ / 1000) * 500;   // 5000 ciclos

  Acelerador_Grafico_Top #(.SCREEN_W(W), .SCREEN_H(H), .PIXEL_BITS(PB),
                           .FIFO_DEPTH(FD), .SYS_CLK_HZ(LED_CLK_HZ)) dut (
    .clk(clk), .rst_n(rst_n),
    .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
    .enable(enable), .reset_soft(reset_soft),
    .comand_w_ena(comand_w_ena), .comand_w_data(comand_w_data),
    .sd_read(sd_read), .sd_write(sd_write), .sd_address(sd_address),
    .sd_burstcount(sd_burstcount), .sd_writedata(sd_writedata),
    .sd_waitrequest(sd_waitrequest), .sd_readdata(sd_readdata),
    .sd_readdatavalid(sd_readdatavalid),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .vga_hs(vga_hs), .vga_vs(vga_vs),
    .vga_blank_n(vga_blank_n), .vga_sync_n(vga_sync_n),
    .vga_underrun(vga_underrun), .vga_frames(vga_frames),
    .px_valid(px_valid), .px_x(px_x), .px_y(px_y),
    .px_color(px_color), .px_addr(px_addr), .buffer_sel(buffer_sel),
    .busy(busy), .modo(modo),
    .fifo_level(fifo_level), .fifo_full(fifo_full),
    .fifo_empty(fifo_empty), .overflow(overflow),
    .err_last(err_last), .err_count(err_count),
    .perf_cycles(perf_cycles), .perf_commands(perf_commands),
    .perf_pixels(perf_pixels), .perf_dropped(perf_dropped),
    .leds(leds),
    .seq_last(seq_last), .clip_count(clip_count),
    .burst_writes(burst_writes), .burst_reads(burst_reads),
    .pixels_written(pixels_written), .out_of_range(out_of_range)
  );

  //====================================================== modelo de la SDRAM
  // Ocupa el lugar de sdram_controller. Habla el mismo Avalon-MM de rafaga
  // que implementara el modulo real: peticion con direccion y longitud,
  // espera mediante waitrequest y datos de vuelta marcados con valid.
  //
  // La memoria se modela plana e indexada por direccion de palabra, con los
  // dos buffers separados por FB_BASE_B. Ademas introduce esperas: es lo que
  // obliga al arbitro a decidir y al rasterizador a detenerse.
  localparam int SD_LAT   = 4;        // ciclos entre la peticion y el dato
  localparam int SD_WORDS = 2 * Acelerador_pkg::FB_BASE_B;

  logic [PB-1:0] sdram [0:SD_WORDS-1];

  // Esperas periodicas, como las de un refresco o una activacion de fila.
  int   sd_espera_cnt = 0;
  logic sd_ocupada;
  always @(posedge clk) sd_espera_cnt <= (sd_espera_cnt == 29) ? 0 : sd_espera_cnt + 1;
  assign sd_ocupada     = (sd_espera_cnt < 3);
  assign sd_waitrequest = sd_ocupada;

  // Escritura de rafaga: la direccion llega con el primer latido y avanza
  // sola mientras write siga alto y waitrequest en bajo.
  logic [Acelerador_pkg::SD_ADDR_BITS-1:0] sd_wr_ptr;
  int   sd_wr_quedan  = 0;
  int   sd_escrituras = 0;            // palabras escritas en total

  always @(posedge clk) begin
    if (sd_write && !sd_waitrequest) begin
      if (sd_wr_quedan == 0) begin
        sdram[sd_address] <= sd_writedata;
        sd_wr_ptr         <= sd_address + 1;
        sd_wr_quedan      <= sd_burstcount - 1;
      end else begin
        sdram[sd_wr_ptr] <= sd_writedata;
        sd_wr_ptr        <= sd_wr_ptr + 1;
        sd_wr_quedan     <= sd_wr_quedan - 1;
      end
      sd_escrituras <= sd_escrituras + 1;
    end
  end

  // Lectura de rafaga: se acepta la peticion y los datos salen en orden,
  // uno por ciclo, tras SD_LAT ciclos.
  logic [Acelerador_pkg::SD_ADDR_BITS-1:0] sd_rd_ptr;
  int   sd_rd_quedan = 0;

  logic [PB-1:0] sd_lat_data [0:SD_LAT-1];
  logic          sd_lat_val  [0:SD_LAT-1];
  int            sd_lecturas = 0;

  always @(posedge clk) begin
    for (int i = SD_LAT-1; i > 0; i--) begin
      sd_lat_data[i] <= sd_lat_data[i-1];
      sd_lat_val[i]  <= sd_lat_val[i-1];
    end
    sd_lat_val[0]  <= 1'b0;

    if (sd_read && !sd_waitrequest && (sd_rd_quedan == 0)) begin
      // Primer latido de la rafaga
      sd_lat_data[0] <= sdram[sd_address];
      sd_lat_val[0]  <= 1'b1;
      sd_rd_ptr      <= sd_address + 1;
      sd_rd_quedan   <= sd_burstcount - 1;
      sd_lecturas    <= sd_lecturas + 1;
    end else if (sd_rd_quedan > 0) begin
      sd_lat_data[0] <= sdram[sd_rd_ptr];
      sd_lat_val[0]  <= 1'b1;
      sd_rd_ptr      <= sd_rd_ptr + 1;
      sd_rd_quedan   <= sd_rd_quedan - 1;
      sd_lecturas    <= sd_lecturas + 1;
    end
  end

  assign sd_readdata      = sd_lat_data[SD_LAT-1];
  assign sd_readdatavalid = sd_lat_val[SD_LAT-1];

  // Vista de la memoria por buffer, para las comprobaciones del banco.
  function automatic logic [PB-1:0] sdram_px(input logic buf_b, input int idx);
    sdram_px = sdram[(buf_b ? Acelerador_pkg::FB_BASE_B
                            : Acelerador_pkg::FB_BASE_A) + idx];
  endfunction

  //================================================ captura de la salida VGA
  // Reconstruye el cuadro a partir de lo que sale por el puerto de video, no
  // de lo que escribio el rasterizador. Es la comprobacion de extremo a
  // extremo: si el buffer de lineas o la temporizacion fallan, la imagen
  // capturada no coincide con la rasterizada.
  logic [PB-1:0] cap_fb [0:H-1][0:W-1];
  int cap_x = 0, cap_y = 0;
  int cap_pixeles = 0;
  logic de_q, vs_q;

  // De RGB888 de vuelta a RGB565 tomando los bits altos: es exacto, porque
  // la expansion solo replico bits que ya estaban.
  function automatic logic [PB-1:0] a565(input logic [7:0] r, g, b);
    a565 = {r[7:3], g[7:2], b[7:3]};
  endfunction

  always @(posedge clk_pix) begin
    de_q <= vga_blank_n;
    vs_q <= vga_vs;

    if (vga_blank_n) begin
      if ((cap_y < H) && (cap_x < W)) begin
        cap_fb[cap_y][cap_x] <= a565(vga_r, vga_g, vga_b);
        cap_pixeles          <= cap_pixeles + 1;
      end
      cap_x <= cap_x + 1;
    end

    // Fin de linea visible
    if (de_q && !vga_blank_n) begin
      cap_x <= 0;
      cap_y <= cap_y + 1;
    end

    // Flanco activo de VSYNC: empieza un cuadro nuevo
    if ((vga_vs == Acelerador_pkg::VGA_VS_POL) &&
        (vs_q  != Acelerador_pkg::VGA_VS_POL)) begin
      cap_x <= 0;
      cap_y <= 0;
    end
  end

  //================================ medicion de la temporizacion VESA
  // Instancia independiente del generador de temporizacion, con los valores
  // del sistema completo. Su reloj no pretende ser 25,175 MHz: se elige
  // rapido para que un cuadro entero quepa en poco tiempo de simulacion.
  // Lo que se verifica es la estructura de los contadores contra la tabla.
  logic vesa_clk = 1'b0;
  always #0.05 vesa_clk = ~vesa_clk;   // rapido a proposito: un cuadro en 42 us

  logic vesa_hs, vesa_vs, vesa_de, vesa_lfin, vesa_cini, vesa_vact;

  vga_timing #(
    .H_VISIBLE(Acelerador_pkg::VGA_H_VISIBLE),
    .H_FRONT(Acelerador_pkg::VGA_H_FRONT),
    .H_SYNC(Acelerador_pkg::VGA_H_SYNC),
    .H_BACK(Acelerador_pkg::VGA_H_BACK),
    .V_VISIBLE(Acelerador_pkg::VGA_V_VISIBLE),
    .V_FRONT(Acelerador_pkg::VGA_V_FRONT),
    .V_SYNC(Acelerador_pkg::VGA_V_SYNC),
    .V_BACK(Acelerador_pkg::VGA_V_BACK),
    .H_POL(Acelerador_pkg::VGA_HS_POL),
    .V_POL(Acelerador_pkg::VGA_VS_POL)
  ) u_vesa (
    .clk_pix(vesa_clk), .rst_n(rst_n),
    .hsync(vesa_hs), .vsync(vesa_vs), .data_active(vesa_de),
    .pix_x(), .pix_y(),
    .linea_fin(vesa_lfin), .cuadro_inicio(vesa_cini),
    .vsync_act(vesa_vact));

  int vesa_h_periodo = 0, vesa_hs_ancho = 0;
  int vesa_v_periodo = 0, vesa_vs_ancho = 0;
  int vesa_visibles  = 0;
  logic vesa_hs_reposo = 1'b0, vesa_vs_reposo = 1'b0;

  int vh = 0, vhs = 0, vl = 0, vls = 0, vvis = 0;
  int vesa_cuadros = 0;   // cuadros completos medidos
  logic vesa_hs_q, vesa_vs_q, vesa_lfin_q;

  always @(posedge vesa_clk) begin
    vesa_hs_q   <= vesa_hs;
    vesa_vs_q   <= vesa_vs;
    vesa_lfin_q <= vesa_lfin;

    // Periodo horizontal: entre dos flancos activos de HSYNC
    vh <= vh + 1;
    if (vesa_hs_q && !vesa_hs) begin        // flanco de bajada: pulso activo
      vesa_h_periodo <= vh;
      vh  <= 1;
      vhs <= 1;
    end else if (!vesa_hs) begin
      vhs <= vhs + 1;
    end else if (!vesa_hs_q && vesa_hs) begin
      vesa_hs_ancho <= vhs;
    end

    // Periodo vertical, contado en lineas completas
    if (vesa_hs_q && !vesa_hs) begin
      vl <= vl + 1;
      if (!vesa_vs) vls <= vls + 1;
    end
    if (vesa_vs_q && !vesa_vs) begin        // empieza el pulso vertical
      vls <= 0;
    end
    if (!vesa_vs_q && vesa_vs) begin        // termina el pulso vertical
      vesa_vs_ancho  <= vls;
      vesa_v_periodo <= vl;
      vesa_visibles  <= vvis;
      vesa_cuadros   <= vesa_cuadros + 1;
      vl   <= 0;
      vvis <= 0;
    end

    if (vesa_de) vvis <= vvis + 1;

    // Nivel en reposo: fuera del pulso la senal debe estar en alto
    if (vesa_de) begin
      vesa_hs_reposo <= vesa_hs;
      vesa_vs_reposo <= vesa_vs;
    end
  end

  task automatic borrar_captura();
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) cap_fb[y][x] = '0;
    cap_pixeles = 0;
  endtask

  // Espera a que termine el cuadro que se esta barriendo y se capture uno
  // entero desde el principio.
  task automatic capturar_cuadro();
    @(negedge vga_vs);                  // sincroniza con el inicio de cuadro
    @(posedge vga_vs);
    borrar_captura();
    @(negedge vga_vs);                  // cuadro completo capturado
  endtask

  //-------------------------------- framebuffer local del banco de pruebas
  logic [PB-1:0] fb  [0:H-1][0:W-1];   // color RGB565
  logic          fbw [0:H-1][0:W-1];   // mascara de escritura
  int   emitidos;          // pixeles del ultimo comando
  int   errores = 0;
  int   err_dir = 0;       // discrepancias entre px_addr y y*W + x
  int   difs = 0;          // diferencias entre lo barrido y lo rasterizado
  logic buffer_antes;      // buffer delantero antes de un intercambio
  logic latido_antes;      // estado del latido antes de esperar
  int   ciclos_antes = 0, ciclos_reales = 0;

  // Reloj de referencia del banco, para contrastar el tiempo transcurrido
  // contra el tiempo de rasterizacion que publica el medidor.
  int   ciclos_tb = 0;
  always @(posedge clk) ciclos_tb <= ciclos_tb + 1;
  logic vio_moe06 = 1'b0;  // la maquina paso por MOE-06 alguna vez

  // Con contrapresion el mismo pixel se presenta varios ciclos seguidos
  // hasta que el gestor de framebuffer lo acepta. Lo que se cuenta es el
  // pixel aceptado, no el ciclo en que estuvo presentado.
  always @(posedge clk) begin
    if (px_valid && dut.px_ready) begin
      fb[px_y][px_x]  <= px_color;
      fbw[px_y][px_x] <= 1'b1;
      emitidos        <= emitidos + 1;
      if (px_addr !== AW'(px_y * W + px_x)) err_dir++;
    end
    if (modo == M_ERROR) vio_moe06 <= 1'b1;
  end

  //-------------------------------------------- archivos de volcado
  int fd_img;              // raster_dump.csv
  int fd_prb;              // raster_pruebas.csv
  int n_frame = 0;

  //------------------------------------------------- escritura de paquetes
  // Una palabra por ciclo, como la hara el driver sobre CMD_FIFO_W. Todas
  // las tareas se llaman estando en un flanco de bajada.
  task automatic palabra(input logic [31:0] d);
    comand_w_ena  = 1'b1;
    comand_w_data = d;
    @(negedge clk);
    comand_w_ena  = 1'b0;
  endtask

  // Escribe las seis palabras del paquete de 24 bytes.
  task automatic enviar(input logic [7:0]  opc,
                        input logic [15:0] seq,
                        input int a, input int b,
                        input int c, input int d,
                        input int e, input int f,
                        input logic [7:0] r, input logic [7:0] g,
                        input logic [7:0] bl,
                        input int param);
    palabra({opc, 8'h00, seq});                       // W0
    palabra({a[15:0], b[15:0]});                      // W1
    palabra({c[15:0], d[15:0]});                      // W2
    palabra({e[15:0], f[15:0]});                      // W3
    palabra({8'h00, r, g, bl});                       // W4
    palabra({16'h0000, param[15:0]});                 // W5
  endtask

  // Espera a que la cola se vacie y el sistema vuelva a la espera.
  task automatic esperar_fin();
    @(negedge clk);
    while (busy || !fifo_empty) @(negedge clk);
    repeat (2) @(negedge clk);
  endtask

  // Envia un comando y espera a que termine. Es la forma de medir cuantos
  // pixeles produjo uno solo.
  task automatic cmd(input logic [7:0] opc,
                     input int a, input int b,
                     input int c, input int d,
                     input int e, input int f,
                     input logic [7:0] r, input logic [7:0] g,
                     input logic [7:0] bl,
                     input int param);
    emitidos = 0;
    enviar(opc, 16'hABCD, a, b, c, d, e, f, r, g, bl, param);
    esperar_fin();
  endtask

  //------------------------------------------------------------- tareas
  task automatic borrar_fb();
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) begin
        fb[y][x]  = '0;
        fbw[y][x] = 1'b0;
      end
  endtask

  //----------------------------------------- comprobaciones y su registro
  task automatic anotar(input string nombre, input string obtenido,
                        input string esperado, input logic ok);
    string veredicto;
    if (ok) veredicto = "OK";
    else    veredicto = "FALLA";
    $fdisplay(fd_prb, "%0s;%0s;%0s;%0s",
              nombre, obtenido, esperado, veredicto);
    if (ok) $display("  [OK  ] %-46s = %0s", nombre, obtenido);
    else begin
      $display("  [FALLA] %-46s = %0s (esperado %0s)",
               nombre, obtenido, esperado);
      errores++;
    end
  endtask

  task automatic chk(input string nombre, input int got, input int exp);
    anotar(nombre, $sformatf("%0d", got), $sformatf("%0d", exp), got === exp);
  endtask

  task automatic chk_px(input string nombre, input int x, input int y,
                        input logic exp);
    anotar(nombre, $sformatf("%0b", fbw[y][x]), $sformatf("%0b", exp),
           fbw[y][x] === exp);
  endtask

  task automatic chk_col(input string nombre, input int x, input int y,
                         input logic [PB-1:0] exp);
    string obtenido;
    if (fbw[y][x]) obtenido = $sformatf("0x%04h", fb[y][x]);
    else           obtenido = "sin escribir";
    anotar(nombre, obtenido, $sformatf("0x%04h", exp),
           fbw[y][x] && (fb[y][x] === exp));
  endtask

  task automatic chk_conv(input logic [7:0] r, input logic [7:0] g,
                          input logic [7:0] b, input logic [PB-1:0] exp);
    logic [PB-1:0] got;
    got = rgb888_to_rgb565(r, g, b);
    anotar($sformatf("RGB888(%0d,%0d,%0d) a RGB565", r, g, b),
           $sformatf("0x%04h", got), $sformatf("0x%04h", exp), got === exp);
  endtask

  task automatic chk_rango(input string nombre, input int got,
                           input int lo, input int hi);
    anotar(nombre, $sformatf("%0d", got),
           $sformatf("entre %0d y %0d", lo, hi), (got > lo) && (got < hi));
  endtask

  //------------------------------------------------- volcado de un fotograma
  task automatic volcar(input string nombre);
    int n;
    n = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) if (fbw[y][x]) n++;

    $fdisplay(fd_img, "F;%0d;%0s;%0d;%0d;%0d;%0d",
              n_frame, nombre, W, H, n, clip_count);
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++)
        if (fbw[y][x]) $fdisplay(fd_img, "P;%0d;%0d;%04h", x, y, fb[y][x]);

    $display("  -> fotograma %0d volcado: %0s (%0d pixeles)", n_frame, nombre, n);
    n_frame++;
  endtask

  // Igual que el anterior pero con lo capturado del puerto de video, no con
  // lo que emitio el rasterizador. Aqui si se vuelca el cuadro completo,
  // porque el barrido entrega todos los pixeles, negros incluidos.
  task automatic volcar_captura(input string nombre);
    $fdisplay(fd_img, "F;%0d;%0s;%0d;%0d;%0d;%0d",
              n_frame, nombre, W, H, W*H, 0);
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++)
        $fdisplay(fd_img, "P;%0d;%0d;%04h", x, y, cap_fb[y][x]);

    $display("  -> fotograma %0d volcado: %0s (barrido de video)",
             n_frame, nombre);
    n_frame++;
  endtask

  //---------------------------------------------------------- secuencia
  initial begin
    comand_w_ena = 1'b0;  comand_w_data = '0;
    enable = 1'b1;  reset_soft = 1'b0;
    emitidos = 0;
    borrar_fb();

    fd_img = $fopen("raster_dump.csv", "w");
    fd_prb = $fopen("raster_pruebas.csv", "w");
    if ((fd_img == 0) || (fd_prb == 0)) begin
      $display("[ERROR] no se pudieron abrir los archivos de volcado");
      $finish;
    end
    $fdisplay(fd_prb, "prueba;obtenido;esperado;resultado");

    $display("");
    $display("==========================================================");
    $display(" Cola de comandos, decodificador y rasterizador");
    $display(" Region visible: %0d x %0d, %0d bits por pixel", W, H, PB);
    $display(" Profundidad de la cola: %0d comandos", FD);
    $display("==========================================================");

    repeat (4) @(negedge clk);
    rst_n     = 1'b1;
    rst_pix_n = 1'b1;
    repeat (4) @(negedge clk);

    //--------------------------------------------- 0. arranque (MOE-01)
    $display("");
    $display("--- 0. Inicializacion y estado de arranque ----------------");
    // MOE-01 dura unos pocos ciclos y deja el sistema en espera.
    while (modo == M_INIT) @(negedge clk);
    chk("modo tras la inicializacion", int'(modo), int'(M_IDLE));
    chk("cola vacia al arrancar", int'(fifo_empty), 1);
    chk("nivel de la cola al arrancar", int'(fifo_level), 0);
    chk("sin errores al arrancar", int'(err_count), 0);
    chk("buffer delantero al arrancar", int'(buffer_sel), 0);

    //--------------------------------------- 1. conversion RGB888 a RGB565
    $display("");
    $display("--- 1. Conversion de color por desplazamiento y OR --------");
    chk_conv(8'h00, 8'h00, 8'h00, COL_NEGRO);
    chk_conv(8'hFF, 8'hFF, 8'hFF, COL_BLANCO);
    chk_conv(8'hFF, 8'h00, 8'h00, COL_ROJO);
    chk_conv(8'h00, 8'hFF, 8'h00, COL_VERDE);
    chk_conv(8'h00, 8'h00, 8'hFF, COL_AZUL);
    chk_conv(8'hFF, 8'hFF, 8'h00, COL_AMARILLO);
    chk_conv(8'h00, 8'hFF, 8'hFF, COL_CIAN);
    chk_conv(8'hFF, 8'h00, 8'hFF, COL_MAGENTA);
    chk_conv(8'h07, 8'h03, 8'h07, 16'h0000);
    chk_conv(8'h08, 8'h04, 8'h08, 16'h0821);
    chk_conv(8'h12, 8'h34, 8'h56, 16'h11AA);

    //------------------------------- 2. recorrido de un paquete completo
    $display("");
    $display("--- 2. Un paquete de 24 bytes de extremo a extremo --------");
    borrar_fb();
    cmd(OPC_PIXEL, 10, 10, 0,0, 0,0, 8'hFF, 8'h00, 8'h00, 0);
    chk("pixeles emitidos por DRAW_PIXEL", emitidos, 1);
    chk_col("pixel (10,10) en rojo", 10, 10, COL_ROJO);
    chk("SEQ_ID recuperado del paquete", int'(seq_last), 'hABCD);
    chk("comandos de la ventana", int'(dut.comandos), 1);

    // NOP no dibuja pero si cuenta como comando ejecutado
    cmd(OPC_NOP, 0,0, 0,0, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    chk("NOP no emite pixeles", emitidos, 0);
    chk("NOP cuenta como comando", int'(dut.comandos), 2);

    // el negro es un color valido y debe quedar escrito
    cmd(OPC_PIXEL, 11, 10, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    chk_col("pixel (11,10) en negro", 11, 10, COL_NEGRO);

    // recorte por pixel: el comando es valido, los pixeles exteriores no
    cmd(OPC_PIXEL, -5, 20, 0,0, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    chk("pixel fuera de pantalla no se escribe", emitidos, 0);
    chk("recortar no genera error", int'(err_count), 0);

    //---------------------------------------------------------- 3. linea
    $display("");
    $display("--- 3. Linea de Bresenham ---------------------------------");
    borrar_fb();
    cmd(OPC_LINE, 0,0, 10,0, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("linea horizontal (0,0)-(10,0)", emitidos, 11);
    chk_col("extremo inicial (0,0) en verde", 0, 0, COL_VERDE);
    chk_col("extremo final (10,0) en verde", 10, 0, COL_VERDE);
    cmd(OPC_LINE, 0,0, 0,10, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("linea vertical (0,0)-(0,10)", emitidos, 11);
    cmd(OPC_LINE, 0,0, 10,10, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("diagonal perfecta (0,0)-(10,10)", emitidos, 11);
    cmd(OPC_LINE, 0,0, 20,7, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("pendiente suave (0,0)-(20,7)", emitidos, 21);
    cmd(OPC_LINE, 5,5, 5,5, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("linea degenerada (5,5)-(5,5)", emitidos, 1);
    cmd(OPC_LINE, -20, 24, 20, 24, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("linea recortada: solo la parte visible", emitidos, 21);
    volcar("lineas_bresenham");

    //----------------------------------------------------- 4. rectangulo
    $display("");
    $display("--- 4. Rectangulo, contorno y relleno ---------------------");
    borrar_fb();
    cmd(OPC_RECT_FILL, 4,4, 13,9, 0,0, 8'h00, 8'h00, 8'hFF, 0);
    chk("relleno 10x6", emitidos, 60);
    chk_px("vecino exterior (14,9)", 14, 9, 1'b0);
    chk_col("relleno uniforme: centro (8,6) azul", 8, 6, COL_AZUL);
    cmd(OPC_RECT, 20,4, 29,9, 0,0, 8'hFF, 8'hFF, 8'h00, 0);
    chk("contorno 10x6 (perimetro)", emitidos, 2*10 + 2*(6-2));
    chk_px("interior hueco (25,6)", 25, 6, 1'b0);
    chk_col("borde superior (25,4) amarillo", 25, 4, COL_AMARILLO);
    chk_col("borde derecho (29,6) amarillo", 29, 6, COL_AMARILLO);
    volcar("rectangulos");

    //-------------------------------------------------------- 5. circulo
    $display("");
    $display("--- 5. Circulo, contorno y relleno ------------------------");
    borrar_fb();
    cmd(OPC_CIRC, 32, 24, 0,0, 0,0, 8'h00, 8'hFF, 8'hFF, 10);
    chk_px("centro vacio (32,24)", 32, 24, 1'b0);
    chk_col("contorno (42,24) en cian", 42, 24, COL_CIAN);
    chk_col("contorno (32,14) en cian", 32, 14, COL_CIAN);
    cmd(OPC_CIRC_FILL, 10, 10, 0,0, 0,0, 8'hFF, 8'h00, 8'hFF, 5);
    chk_px("fuera del disco (16,10)", 16, 10, 1'b0);
    chk_col("centro del disco en magenta", 10, 10, COL_MAGENTA);
    chk_col("borde del disco en magenta", 15, 10, COL_MAGENTA);
    chk_rango("area del disco r=5 (esperado ~79)", emitidos, 70, 95);
    volcar("circulos");

    //------------------------------------------------------ 6. triangulo
    $display("");
    $display("--- 6. Triangulo, contorno y relleno ----------------------");
    borrar_fb();
    cmd(OPC_TRIA, 10,40, 20,20, 30,40, 8'hFF, 8'h00, 8'h00, 0);
    chk_px("interior hueco (20,35)", 20, 35, 1'b0);
    chk_col("arista 1: vertice (20,20) en rojo", 20, 20, COL_ROJO);
    chk_col("arista 2: vertice (30,40) en rojo", 30, 40, COL_ROJO);
    chk_col("arista 3: base (20,40) en rojo", 20, 40, COL_ROJO);
    cmd(OPC_TRIA_FILL, 34,40, 44,20, 54,40, 8'h00, 8'hFF, 8'h00, 0);
    chk_px("exterior (36,22)", 36, 22, 1'b0);
    chk_col("interior relleno (44,35) en verde", 44, 35, COL_VERDE);
    chk_rango("area del triangulo (esperado ~210)", emitidos, 180, 240);
    volcar("triangulos");

    //--------------------------------------------------------- 7. borrado
    $display("");
    $display("--- 7. Borrado de pantalla completa -----------------------");
    borrar_fb();
    cmd(OPC_CLEAR, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'hFF, 0);
    chk("pixeles de CLEAR", emitidos, W*H);
    chk_col("fondo (32,24) en azul", 32, 24, COL_AZUL);
    chk_col("esquina (63,47) en azul", W-1, H-1, COL_AZUL);

    //------------------------------------------------- 8. orden de la cola
    // Un lote entero se escribe de corrido, sin esperar entre comandos: es
    // el modo normal de trabajo. La cola tiene que entregarlos en orden.
    $display("");
    $display("--- 8. Lote de comandos y orden FIFO ----------------------");
    borrar_fb();
    emitidos = 0;
    for (int i = 0; i < 8; i++)
      enviar(OPC_PIXEL, 16'(i), i*3, 5, 0,0, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    // El decodificador consume mientras la interfaz sigue escribiendo, asi
    // que el nivel de la cola nunca llega a ocho: lo que se comprueba es que
    // los ocho se ejecutaron, en orden y sin perdidas.
    esperar_fin();
    chk("ocho pixeles del lote escritos", emitidos, 8);
    chk("ningun comando del lote se perdio", int'(err_count), 0);
    chk("SEQ_ID del ultimo del lote", int'(seq_last), 7);
    chk_px("primero del lote (0,5)", 0, 5, 1'b1);
    chk_px("ultimo del lote (21,5)", 21, 5, 1'b1);
    chk("todos los del lote presentes", perfilar_escritos(), 8);
    chk("cola vacia tras el lote", int'(fifo_empty), 1);

    //------------------------------------- 9. desbordamiento de la cola
    // Con el decodificador detenido se llena la cola a proposito. Deben
    // sobrevivir los primeros FD comandos y descartarse el resto.
    $display("");
    $display("--- 9. Desbordamiento de la cola (EC-08) ------------------");
    borrar_fb();
    enable = 1'b0;
    @(negedge clk);
    for (int i = 0; i < FD + 4; i++)
      enviar(OPC_PIXEL, 16'(i), i, 20, 0,0, 0,0, 8'hFF, 8'h00, 8'h00, 0);
    chk("cola llena", int'(fifo_full), 1);
    chk("nivel de la cola al tope", int'(fifo_level), FD);
    chk("bit de overflow activo", int'(overflow), 1);
    chk("ultimo error registrado es EC-08", int'(err_last), 8);
    chk("errores contabilizados", int'(err_count), 4);

    enable = 1'b1;
    esperar_fin();
    chk("los almacenados se ejecutaron", int'(perfilar_escritos()), FD);
    chk_px("primer comando del lote sobrevivio", 0, 20, 1'b1);
    chk_px("comando FD-1 sobrevivio", FD-1, 20, 1'b1);
    chk_px("comando FD fue descartado", FD, 20, 1'b0);
    chk_px("comando FD+3 fue descartado", FD+3, 20, 1'b0);
    chk("la maquina paso por MOE-06", int'(vio_moe06), 1);
    chk("MOE-06 no es absorbente", int'(modo), int'(M_IDLE));
    volcar("desbordamiento_de_la_cola");

    //------------------------------------- 10. comandos invalidos
    $display("");
    $display("--- 10. Comandos invalidos (EC-06 y EC-07) ----------------");
    borrar_fb();
    cmd(OPC_INF, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);   // cierra ventana
    @(negedge clk);

    // codigo de operacion inexistente
    cmd(8'h0C, 0,0, 0,0, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    chk("opcode desconocido no dibuja", emitidos, 0);
    chk("ultimo error es EC-06", int'(err_last), 6);

    // radio nulo: el comando esta bien formado pero no describe un circulo
    cmd(OPC_CIRC, 30, 30, 0,0, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    chk("radio nulo no dibuja", emitidos, 0);
    chk("ultimo error es EC-07", int'(err_last), 7);

    // el sistema continua: el siguiente comando valido se ejecuta
    cmd(OPC_RECT_FILL, 2,2, 11,11, 0,0, 8'h00, 8'hFF, 8'h00, 0);
    chk("tras dos errores el sistema sigue", emitidos, 100);
    chk_col("comando valido posterior (6,6)", 6, 6, COL_VERDE);
    chk("modo final de vuelta en espera", int'(modo), int'(M_IDLE));
    volcar("errores_y_recuperacion");

    //-------------------------------------- 11. intercambio de buffer
    $display("");
    $display("--- 11. SWAP_BUFFER en el flanco de VSYNC (MOE-04) --------");
    // Se espera a que vsync este en bajo para que el flanco llegue despues
    // de pedir el intercambio y no antes.
    while (dut.vsync_sys) @(negedge clk);
    chk("buffer antes del swap", int'(buffer_sel), 0);
    enviar(OPC_SWAP, 16'd100, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    repeat (10) @(negedge clk);
    chk("el swap espera al flanco de VSYNC", int'(buffer_sel), 0);
    chk("modo durante la espera es MOE-04", int'(modo), int'(M_SWAP));
    esperar_fin();
    chk("buffer intercambiado tras el VSYNC", int'(buffer_sel), 1);

    while (dut.vsync_sys) @(negedge clk);
    enviar(OPC_SWAP, 16'd101, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    esperar_fin();
    chk("segundo swap vuelve al buffer A", int'(buffer_sel), 0);

    //------------------------------------------- 12. informe (MOE-05)
    $display("");
    $display("--- 12. Ventana de medicion e informe (MOE-05) ------------");
    borrar_fb();
    cmd(OPC_INF, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);  // abre ventana nueva
    chk("contador de comandos reiniciado", int'(dut.comandos), 0);
    chk("contador de pixeles reiniciado", int'(dut.u_raster.pix_count), 0);

    cmd(OPC_RECT_FILL, 0,0, 9,9, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);  // 100 pixeles
    cmd(OPC_RECT_FILL, 0,12, 9,21, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);// 100 pixeles
    chk("pixeles acumulados en la ventana", int'(dut.u_raster.pix_count), 200);

    cmd(OPC_INF, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    chk("INF publica los pixeles de la ventana", int'(perf_pixels), 200);
    chk("INF publica los comandos de la ventana", int'(perf_commands), 2);
    chk("INF publica los descartes de la ventana", int'(perf_dropped), 0);
    chk_rango("INF publica ciclos distintos de cero", int'(perf_cycles), 200, 100000);
    chk("la ventana queda reiniciada", int'(dut.u_raster.pix_count), 0);
    volcar("ventana_de_medicion");

    //------------------------------------------------- 13. escena completa
    // Toda la escena se envia como un lote, igual que lo hara la interfaz.
    $display("");
    $display("--- 13. Escena de demostracion en color -------------------");
    borrar_fb();
    enviar(OPC_CLEAR,     16'd200, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h20, 0);
    enviar(OPC_RECT,      16'd201, 1,1, 62,46, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    enviar(OPC_RECT_FILL, 16'd202, 4,4, 16,14, 0,0, 8'h00, 8'h00, 8'hFF, 0);
    enviar(OPC_CIRC,      16'd203, 45,11, 0,0, 0,0, 8'h00, 8'hFF, 8'hFF, 8);
    enviar(OPC_LINE,      16'd204, 4,20, 59,20, 0,0, 8'hFF, 8'hFF, 8'h00, 0);
    enviar(OPC_LINE,      16'd205, 24,4, 34,17, 0,0, 8'hFF, 8'h00, 8'hFF, 0);
    enviar(OPC_TRIA,      16'd206, 5,43, 14,25, 23,43, 8'hFF, 8'h00, 8'h00, 0);
    enviar(OPC_TRIA_FILL, 16'd207, 28,43, 37,25, 46,43, 8'h00, 8'hFF, 8'h00, 0);
    enviar(OPC_CIRC_FILL, 16'd208, 55,35, 0,0, 0,0, 8'hFF, 8'h80, 8'h00, 6);
    esperar_fin();
    chk("la escena completa se ejecuto en orden", int'(seq_last), 208);
    chk("sin descartes en la escena", int'(perf_dropped), 0);
    chk("discrepancias de px_addr", err_dir, 0);
    volcar("escena_de_demostracion");

    //----------------------------------- 14. rampa de color RGB565
    $display("");
    $display("--- 14. Rampa de color RGB565 -----------------------------");
    borrar_fb();
    for (int i = 0; i < 32; i++) begin
      enviar(OPC_RECT_FILL, 16'(i), i*2, 0, i*2+1, 14, 0,0,
             8'(i*8), 8'h00, 8'h00, 0);
      esperar_fin();
    end
    for (int i = 0; i < 32; i++) begin
      enviar(OPC_RECT_FILL, 16'(i), i*2, 16, i*2+1, 30, 0,0,
             8'h00, 8'(i*8), 8'h00, 0);
      esperar_fin();
    end
    for (int i = 0; i < 32; i++) begin
      enviar(OPC_RECT_FILL, 16'(i), i*2, 32, i*2+1, 46, 0,0,
             8'h00, 8'h00, 8'(i*8), 0);
      esperar_fin();
    end
    chk_col("rampa: rojo maximo en (62,7)", 62, 7, COL_ROJO);
    chk_col("rampa: verde maximo en (62,23)", 62, 23, 16'h07C0);
    chk_col("rampa: azul maximo en (62,39)", 62, 39, COL_AZUL);
    chk_col("rampa: nivel cero en (0,7)", 0, 7, COL_NEGRO);
    volcar("rampa_de_color");

    //--------------------------------- 15. temporizacion VESA 640x480 a 60 Hz
    // El modulo de temporizacion se verifica contra la tabla del estandar con
    // una instancia aparte, parametrizada con los valores del sistema
    // completo. Su reloj en simulacion no guarda relacion con los 25,175 MHz
    // de la placa: lo que se comprueba es la estructura de los contadores, y
    // la frecuencia solo importa sobre el hardware.
    $display("");
    $display("--- 15. Temporizacion VESA 640 x 480 a 60 Hz --------------");
    // El primer cuadro arranca a medias, porque los contadores empiezan con
    // el reinicio y no con el inicio de cuadro. Se descarta esperando a que
    // haya varios cuadros completos medidos.
    while (vesa_cuadros < 3) @(posedge vesa_clk);
    chk("periodo horizontal en relojes de pixel", vesa_h_periodo,
        Acelerador_pkg::VGA_H_VISIBLE + Acelerador_pkg::VGA_H_FRONT +
        Acelerador_pkg::VGA_H_SYNC    + Acelerador_pkg::VGA_H_BACK);
    chk("ancho del pulso HSYNC", vesa_hs_ancho, Acelerador_pkg::VGA_H_SYNC);
    chk("lineas por cuadro", vesa_v_periodo,
        Acelerador_pkg::VGA_V_VISIBLE + Acelerador_pkg::VGA_V_FRONT +
        Acelerador_pkg::VGA_V_SYNC    + Acelerador_pkg::VGA_V_BACK);
    chk("ancho del pulso VSYNC en lineas", vesa_vs_ancho,
        Acelerador_pkg::VGA_V_SYNC);
    chk("pixeles visibles por cuadro", vesa_visibles,
        Acelerador_pkg::VGA_H_VISIBLE * Acelerador_pkg::VGA_V_VISIBLE);
    chk("HSYNC en reposo es alto (polaridad negativa)", int'(vesa_hs_reposo), 1);
    chk("VSYNC en reposo es alto (polaridad negativa)", int'(vesa_vs_reposo), 1);

    //------------------------------- 16. salida de video de extremo a extremo
    // Se dibuja una escena en el buffer trasero, se intercambia y se captura
    // lo que realmente sale por el puerto de video. La comparacion no es
    // contra lo que escribio el rasterizador en la memoria, sino contra lo
    // que el monitor recibiria: si el buffer de lineas, la prebusqueda o la
    // temporizacion fallan, la imagen capturada no coincide.
    $display("");
    $display("--- 16. Barrido de video de extremo a extremo -------------");
    borrar_fb();
    emitidos = 0;
    enviar(OPC_CLEAR,     16'd300, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h20, 0);
    enviar(OPC_RECT,      16'd301, 1,1, 62,46, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);
    enviar(OPC_RECT_FILL, 16'd302, 4,4, 16,14, 0,0, 8'h00, 8'h00, 8'hFF, 0);
    enviar(OPC_CIRC,      16'd303, 45,11, 0,0, 0,0, 8'h00, 8'hFF, 8'hFF, 8);
    enviar(OPC_LINE,      16'd304, 4,20, 59,20, 0,0, 8'hFF, 8'hFF, 8'h00, 0);
    enviar(OPC_TRIA_FILL, 16'd305, 28,43, 37,25, 46,43, 8'h00, 8'hFF, 8'h00, 0);
    enviar(OPC_CIRC_FILL, 16'd306, 55,35, 0,0, 0,0, 8'hFF, 8'h80, 8'h00, 6);
    esperar_fin();
    chk("la escena se rasterizo entera", perfilar_escritos(), W*H);
    volcar("escena_referencia");

    // Antes de intercambiar: lo que el gestor dejo en la memoria tiene que
    // ser exactamente lo que el rasterizador produjo. Esta comprobacion
    // separa el camino de escritura del de lectura, de modo que una
    // diferencia posterior solo puede venir del barrido.
    difs = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++)
        if (sdram_px(~buffer_sel, y*W + x) !== fb[y][x]) begin
          if (difs < 8)
            $display("      memoria (%0d,%0d) idx=%0d: 0x%04h, esperado 0x%04h",
                     x, y, y*W+x, sdram_px(~buffer_sel, y*W + x), fb[y][x]);
          difs++;
        end
    chk("la memoria contiene la escena rasterizada", difs, 0);

    // Hasta aqui la escena esta en el buffer trasero y el monitor sigue
    // viendo el delantero. El intercambio es lo que la hace visible.
    buffer_antes = buffer_sel;
    enviar(OPC_SWAP, 16'd307, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    esperar_fin();
    chk("el intercambio cambio de buffer",
        int'(buffer_sel != buffer_antes), 1);

    capturar_cuadro();
    chk("pixeles capturados en un cuadro", cap_pixeles, W*H);

    difs = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++)
        if (cap_fb[y][x] !== fb[y][x]) begin
          if (difs < 12)
            $display("      dif en (%0d,%0d): barrido 0x%04h, rasterizado 0x%04h",
                     x, y, cap_fb[y][x], fb[y][x]);
          difs++;
        end
    chk("la imagen barrida coincide con la rasterizada", difs, 0);

    // Contabilidad de la ruta de escritura: lo que el rasterizador entrego,
    // lo que el gestor acepto y lo que llego de verdad a la memoria tienen
    // que coincidir. Si no, se estan perdiendo pixeles entre medio.
    chk("ninguna escritura se perdio camino a memoria",
        sd_escrituras, int'(pixels_written));
    chk("ninguna escritura fuera de region", int'(out_of_range), 0);

    // La razon de ser del combinador: un relleno a pantalla completa escribe
    // en direcciones contiguas, de modo que la memoria tiene que ver ocho
    // veces menos transacciones que pixeles. Sin combinar, bw valdria lo
    // mismo que el numero de pixeles.
    chk_rango("palabras por transaccion de escritura",
              int'(pixels_written) / int'(burst_writes), 2, 9);
    chk_rango("palabras por transaccion de lectura",
              int'(sd_lecturas) / int'(burst_reads), 2, 9);
    chk("sin vaciado del buffer de lineas", int'(vga_underrun), 0);
    chk_rango("cuadros barridos", int'(vga_frames), 0, 1000000);
    volcar_captura("salida_vga");

    //-------------------------- 17. Medidor de rendimiento e indicador
    $display("");
    $display("--- 17. Medidor de rendimiento e indicador de estado ------");

    // Lo que mide perf_cycles es el tiempo de rasterizacion, no el tiempo
    // transcurrido. Se cierra una ventana, se deja el sistema parado un buen
    // rato sin mandar nada y se vuelve a cerrar: los ciclos publicados tienen
    // que ser una fraccion minima de los ciclos que pasaron de verdad.
    cmd(OPC_INF, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    ciclos_antes = ciclos_tb;
    cmd(OPC_RECT_FILL, 0,0, 9,9, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);  // 100 pixeles
    repeat (4000) @(negedge clk);                               // sistema parado
    cmd(OPC_INF, 0,0, 0,0, 0,0, 8'h00, 8'h00, 8'h00, 0);
    ciclos_reales = ciclos_tb - ciclos_antes;
    chk_rango("ciclos publicados por el medidor", int'(perf_cycles), 100, 2000);
    chk_rango("ciclos reales transcurridos", ciclos_reales, 4000, 100000);
    chk("el medidor ignora el tiempo en reposo",
        int'(perf_cycles < (ciclos_reales / 2)), 1);
    chk("pixeles de la ventana", int'(perf_pixels), 100);
    // La foto se toma al decodificar INF, antes de contarlo: el comando que
    // cierra la ventana no forma parte de lo medido.
    chk("comandos de la ventana, sin contar el INF", int'(perf_commands), 1);

    // Indicador de estado: los tres bits bajos reproducen el modo.
    chk("LED del modo coincide con el modo", int'(leds[2:0]), int'(modo));
    chk("LED de ocupado en reposo", int'(leds[3]), 0);
    chk("LED de buffer sigue a buffer_sel", int'(leds[6]), int'(buffer_sel));

    // El error dura un ciclo; el indicador tiene que alargarlo. Se provoca
    // uno y se comprueba que enciende, que sigue encendido mucho despues del
    // ciclo en que ocurrio, y que acaba apagandose.
    chk("LED de error apagado antes", int'(leds[4]), 0);
    cmd(8'h0C, 0,0, 0,0, 0,0, 8'hFF, 8'hFF, 8'hFF, 0);   // opcode inexistente
    chk("LED de error encendido tras el fallo", int'(leds[4]), 1);
    repeat (LED_DESTELLO / 2) @(negedge clk);
    chk("el destello sigue encendido a mitad", int'(leds[4]), 1);
    repeat (LED_DESTELLO) @(negedge clk);
    chk("el destello se apaga al cumplirse", int'(leds[4]), 0);

    // El latido distingue un sistema parado de uno en reposo.
    latido_antes = leds[9];
    repeat (LED_LATIDO + 10) @(negedge clk);
    chk("el latido cambio de estado", int'(leds[9] != latido_antes), 1);

    //------------------------------------------------------------ resumen
    $display("");
    $display("==========================================================");
    if (errores == 0) $display(" RESULTADO: todas las comprobaciones pasaron");
    else              $display(" RESULTADO: %0d comprobacion(es) fallaron", errores);
    $display(" Fotogramas volcados: %0d", n_frame);
    $display(" Archivos: raster_dump.csv, raster_pruebas.csv");
    $display(" Para verlos:  python ver_raster.py");
    $display("==========================================================");
    $display("");

    $fclose(fd_img);
    $fclose(fd_prb);
    $finish;
  end

  //------------------------------------------- utilidades del banco
  // Cuenta los pixeles escritos en el framebuffer local. Se usa para
  // comprobar cuantos comandos del lote desbordado llegaron a dibujar.
  function automatic int perfilar_escritos();
    int n;
    n = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) if (fbw[y][x]) n++;
    perfilar_escritos = n;
  endfunction

  //-------------------------------------------------- guardia de tiempo
  initial begin
    #20_000_000;                      // 20 ms
    $display("[ERROR] la simulacion excedio el tiempo maximo");
    $fclose(fd_img);
    $fclose(fd_prb);
    $finish;
  end

endmodule
