`timescale 1ns / 1ps
//=============================================================================
// tb_escena_faro.sv
// Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
// Banco de pruebas de escena unica: "Faro en la costa al atardecer"
//
// A diferencia de tb_Acelerador_Grafico_Top.sv, que recorre una bateria de
// casos (desbordamientos, codigos invalidos, temporizacion VESA, rampas de
// color), este banco hace una sola cosa y la hace entera: dibuja un cuadro
// con sentido pictorico y comprueba que llega intacto hasta la salida de
// video. Es el caso de uso real del acelerador, el que ejecutaria una
// aplicacion: construir una escena, presentarla y pedir el informe.
//
// La escena usa las ocho primitivas:
//
//   CLEAR      el cielo del cenit, de una sola orden
//   RECT_FILL  las bandas del degradado del poniente, el mar en tres
//              profundidades y el cuerpo del faro con sus franjas
//   CIRC       el halo del sol
//   CIRC_FILL  el disco del sol, que el mar tapa por la mitad
//   TRIA_FILL  el acantilado, el techo del faro, las velas y el casco
//   LINE       el reguero del sol en el agua, los rayos de la lampara,
//              el mastil y las aves
//   PIXEL      las estrellas que aun se ven en lo alto
//   SWAP       presenta el cuadro terminado en el flanco de VSYNC
//   INF        cierra la ventana de medicion y publica el rendimiento
//
// El orden de los comandos es el del pintor: lo que esta detras se dibuja
// antes y lo de delante lo tapa. Por eso el sol se dibuja antes que el mar
// (queda medio hundido) y el velero despues del sol (queda a contraluz).
//
// Que se comprueba:
//   1. ningun comando se pierde ni produce error
//   2. ningun pixel cae fuera de la pantalla
//   3. once pixeles de referencia tienen exactamente el color esperado
//   4. el cuadro que sale por el puerto VGA es identico, pixel a pixel, al
//      que escribio el rasterizador. Esta es la comprobacion fuerte: recorre
//      el doble buffer, el cruce de dominios de reloj, la prebusqueda de
//      lineas y la expansion de color de vuelta a RGB888
//
// Salidas, en el formato que ya entiende ver_raster.py:
//   raster_dump.csv     dos fotogramas: el rasterizado y el barrido de video
//   raster_pruebas.csv  una fila por comprobacion
//
// Uso:  vsim -c -do "run -all" tb_escena_faro
//       python ver_raster.py
//=============================================================================
module tb_escena_faro;

  import Acelerador_pkg::*;

  // Constantes del paquete con el nombre calificado: una importacion comodin
  // no resuelve igual en todas las herramientas.
  localparam logic [7:0] OPC_PIXEL     = Acelerador_pkg::OPC_PIXEL;
  localparam logic [7:0] OPC_LINE      = Acelerador_pkg::OPC_LINE;
  localparam logic [7:0] OPC_TRIA_FILL = Acelerador_pkg::OPC_TRIA_FILL;
  localparam logic [7:0] OPC_RECT_FILL = Acelerador_pkg::OPC_RECT_FILL;
  localparam logic [7:0] OPC_CIRC      = Acelerador_pkg::OPC_CIRC;
  localparam logic [7:0] OPC_CIRC_FILL = Acelerador_pkg::OPC_CIRC_FILL;
  localparam logic [7:0] OPC_CLEAR     = Acelerador_pkg::OPC_CLEAR;
  localparam logic [7:0] OPC_SWAP      = Acelerador_pkg::OPC_SWAP;
  localparam logic [7:0] OPC_INF       = Acelerador_pkg::OPC_INF;

  localparam logic [2:0] M_IDLE = Acelerador_pkg::MOE_IDLE;
  localparam logic [2:0] M_INIT = Acelerador_pkg::MOE_INIT;

  localparam int W  = 64;
  localparam int H  = 48;
  localparam int PB = 16;
  localparam int FD = Acelerador_pkg::FIFO_DEPTH;
  localparam int AW = $clog2(W*H);

  // Nombres de los volcados. Son los que busca ver_raster.py sin argumentos;
  // para no pisar la salida del otro banco, correr cada simulacion en su
  // propia carpeta y apuntar con "python ver_raster.py --dir <carpeta>".
  localparam string ARCHIVO_IMG = "raster_dump.csv";
  localparam string ARCHIVO_PRB = "raster_pruebas.csv";

  //------------------------------------------------------- relojes y reinicio
  // Dos dominios sin relacion de fase, como en la placa. El periodo del reloj
  // de pixel no es multiplo entero del otro a proposito, para que los flancos
  // caigan en todas las posiciones relativas y los sincronizadores trabajen.
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz

  logic clk_pix = 1'b0;
  logic rst_pix_n = 1'b0;
  always #19.7 clk_pix = ~clk_pix;      // 25,38 MHz

  //------------------------------------------------------------------ senales
  logic               enable, reset_soft;
  logic               comand_w_ena;
  logic        [31:0] comand_w_data;

  // Maestro de rafaga. Con FB_ONCHIP el framebuffer vive dentro del diseno y
  // estas entradas quedan sin usar; se atan a un valor fijo para que no haya
  // ninguna X entrando al modulo.
  logic               sd_read, sd_write;
  logic [Acelerador_pkg::SD_ADDR_BITS-1:0] sd_address;
  logic [$clog2(Acelerador_pkg::BURST_LEN+1)-1:0] sd_burstcount;
  logic [PB-1:0]      sd_writedata;
  logic               sd_waitrequest    = 1'b0;
  logic [PB-1:0]      sd_readdata       = '0;
  logic               sd_readdatavalid  = 1'b0;

  logic [31:0]        burst_writes, burst_reads, pixels_written, out_of_range;
  logic [9:0]         leds;

  logic        [7:0]  vga_r, vga_g, vga_b;
  logic               vga_hs, vga_vs, vga_blank_n, vga_sync_n;
  logic               vga_underrun;
  logic        [31:0] vga_frames;

  logic               px_valid;
  logic [$clog2(W)-1:0] px_x;
  logic [$clog2(H)-1:0] px_y;
  logic [PB-1:0]      px_color;
  logic [AW-1:0]      px_addr;
  logic [3:0]         px_len;
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

  Acelerador_Grafico_Top #(.SCREEN_W(W), .SCREEN_H(H), .PIXEL_BITS(PB),
                           .FIFO_DEPTH(FD), .FB_ONCHIP(1'b1)) dut (
    .clk(clk), .rst_n(rst_n),
    .clk_pix(clk_pix), .rst_pix_n(rst_pix_n),
    .enable(enable), .reset_soft(reset_soft), .perf_window(1'b0),
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
    .px_color(px_color), .px_addr(px_addr), .px_len(px_len), .buffer_sel(buffer_sel),
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

  //------------------------------- framebuffer espejo, lo que emite el raster
  // Con contrapresion el mismo pixel se presenta varios ciclos seguidos hasta
  // que el gestor lo acepta, asi que lo que se anota es el pixel aceptado y
  // no el ciclo en que estuvo presentado.
  logic [PB-1:0] fb  [0:H-1][0:W-1];
  logic          fbw [0:H-1][0:W-1];
  int            emitidos = 0;
  logic [31:0]   pw_arranque = '0;     // pixels_written al terminar MOE-01
  int            err_dir  = 0;          // discrepancias entre px_addr y y*W+x

  always @(posedge clk) begin
    // Cada solicitud trae px_len pixeles consecutivos desde (px_x, px_y)
    if (px_valid && dut.px_ready) begin
      for (int i = 0; i < px_len; i++) begin
        // Bloqueante: el modelo solo se consulta en flancos de bajada
        fb[px_y][px_x + i]  = px_color;
        fbw[px_y][px_x + i] = 1'b1;
      end
      emitidos <= emitidos + px_len;
      if (px_addr !== AW'(px_y * W + px_x)) err_dir++;
    end
  end

  //-------------------------------- captura de lo que sale por el puerto VGA
  // Reconstruye el cuadro a partir de la senal de video, no de lo que
  // escribio el rasterizador: es la comprobacion de extremo a extremo.
  logic [PB-1:0] cap_fb [0:H-1][0:W-1];
  int   cap_x = 0, cap_y = 0;
  int   cap_pixeles = 0;
  logic de_q, vs_q;

  // De RGB888 de vuelta a RGB565 tomando los bits altos. Es exacto, porque la
  // expansion del controlador solo replico bits que ya estaban.
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

    if (de_q && !vga_blank_n) begin     // fin de linea visible
      cap_x <= 0;
      cap_y <= cap_y + 1;
    end

    if ((vga_vs == Acelerador_pkg::VGA_VS_POL) &&
        (vs_q  != Acelerador_pkg::VGA_VS_POL)) begin   // cuadro nuevo
      cap_x <= 0;
      cap_y <= 0;
    end
  end

  //------------------------------------------------------- estado del banco
  int   errores     = 0;
  int   n_comandos  = 0;      // comandos enviados
  int   difs        = 0;      // diferencias entre lo barrido y lo rasterizado
  logic [15:0] seq  = 16'd1;  // SEQ_ID incremental, como haria un driver
  int   fd_img, fd_prb;
  int   n_frame = 0;

  //------------------------------------------------- escritura de paquetes
  // Una palabra por ciclo sobre CMD_FIFO_W, en el mismo orden en que lo hara
  // el driver. Todas las tareas se llaman estando en un flanco de bajada.
  task automatic palabra(input logic [31:0] d);
    comand_w_ena  = 1'b1;
    comand_w_data = d;
    @(negedge clk);
    comand_w_ena  = 1'b0;
  endtask

  task automatic enviar(input logic [7:0]  opc,
                        input logic [15:0] s,
                        input int a, input int b,
                        input int c, input int d,
                        input int e, input int f,
                        input logic [7:0] r, input logic [7:0] g,
                        input logic [7:0] bl,
                        input int param);
    palabra({opc, 8'h00, s});                         // W0
    palabra({a[15:0], b[15:0]});                      // W1
    palabra({c[15:0], d[15:0]});                      // W2
    palabra({e[15:0], f[15:0]});                      // W3
    palabra({8'h00, r, g, bl});                       // W4
    palabra({16'h0000, param[15:0]});                 // W5
  endtask

  // Espera a que haya sitio en la cola. Es lo que hace un driver real: mira
  // STATUS y solo escribe cuando cabe, en lugar de arriesgarse a EC-08.
  // Basta mirar antes de W0: entre la consulta y el empuje de W5 nadie mas
  // escribe, de modo que la cola solo puede vaciarse.
  task automatic espera_sitio();
    @(negedge clk);
    while (fifo_full) @(negedge clk);
  endtask

  // Encola un comando sin esperar a que termine: asi la cola se mantiene
  // llena y el rasterizador nunca se queda ocioso, que es el caso que
  // interesa medir.
  task automatic dib(input logic [7:0] opc,
                     input int a, input int b,
                     input int c, input int d,
                     input int e, input int f,
                     input logic [7:0] r, input logic [7:0] g,
                     input logic [7:0] bl,
                     input int param);
    espera_sitio();
    enviar(opc, seq, a, b, c, d, e, f, r, g, bl, param);
    n_comandos = n_comandos + 1;
    seq        = seq + 16'd1;
  endtask

  // Espera a que la cola se vacie y el sistema vuelva a la espera.
  task automatic esperar_fin();
    @(negedge clk);
    while (busy || !fifo_empty) @(negedge clk);
    repeat (2) @(negedge clk);
  endtask

  task automatic borrar_fb();
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) begin
        fb[y][x]  = '0;
        fbw[y][x] = 1'b0;
      end
  endtask

  task automatic borrar_captura();
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) cap_fb[y][x] = '0;
    cap_pixeles = 0;
  endtask

  // Deja pasar el cuadro en curso y captura el siguiente entero.
  task automatic capturar_cuadro();
    @(negedge vga_vs);
    @(posedge vga_vs);
    borrar_captura();
    @(negedge vga_vs);
  endtask

  //----------------------------------------- comprobaciones y su registro
  task automatic anotar(input string nombre, input string obtenido,
                        input string esperado, input logic ok);
    string veredicto;
    if (ok) veredicto = "OK";
    else    veredicto = "FALLA";
    $fdisplay(fd_prb, "%0s;%0s;%0s;%0s", nombre, obtenido, esperado, veredicto);
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

  // Comprueba el color de un pixel del framebuffer rasterizado.
  task automatic chk_col(input string nombre, input int x, input int y,
                         input logic [PB-1:0] exp);
    string obtenido;
    if (fbw[y][x]) obtenido = $sformatf("0x%04h", fb[y][x]);
    else           obtenido = "sin escribir";
    anotar(nombre, obtenido, $sformatf("0x%04h", exp),
           fbw[y][x] && (fb[y][x] === exp));
  endtask

  //------------------------------------------------- volcado de fotogramas
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

  // Igual, pero con lo capturado del puerto de video. Aqui si se vuelca el
  // cuadro completo, porque el barrido entrega todos los pixeles.
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

  //===========================================================================
  // La escena
  //===========================================================================
  // Orden del pintor: el fondo primero, lo de delante despues.
  task automatic escena();

    // Cielo del cenit. CLEAR pinta la pantalla entera de una sola orden.
    dib(OPC_CLEAR,      0,  0,   0,  0,   0,  0, 8'd28 ,8'd22 ,8'd62 , 0);

    // Degradado del poniente, de arriba hacia el horizonte.
    dib(OPC_RECT_FILL,  0,  6,  63, 11,   0,  0, 8'd52 ,8'd34 ,8'd92 , 0);
    dib(OPC_RECT_FILL,  0, 12,  63, 16,   0,  0, 8'd104,8'd48 ,8'd104, 0);
    dib(OPC_RECT_FILL,  0, 17,  63, 21,   0,  0, 8'd168,8'd72 ,8'd88 , 0);
    dib(OPC_RECT_FILL,  0, 22,  63, 25,   0,  0, 8'd226,8'd118,8'd58 , 0);
    dib(OPC_RECT_FILL,  0, 26,  63, 29,   0,  0, 8'd248,8'd178,8'd84 , 0);

    // Estrellas que aun se ven en lo alto.
    dib(OPC_PIXEL,     16,  1,   0,  0,   0,  0, 8'd226,8'd228,8'd255, 0);
    dib(OPC_PIXEL,     23,  4,   0,  0,   0,  0, 8'd226,8'd228,8'd255, 0);
    dib(OPC_PIXEL,     30,  1,   0,  0,   0,  0, 8'd226,8'd228,8'd255, 0);
    dib(OPC_PIXEL,     38,  3,   0,  0,   0,  0, 8'd226,8'd228,8'd255, 0);
    dib(OPC_PIXEL,     46,  0,   0,  0,   0,  0, 8'd226,8'd228,8'd255, 0);
    dib(OPC_PIXEL,     57,  1,   0,  0,   0,  0, 8'd226,8'd228,8'd255, 0);

    // El sol. El halo es un contorno y el disco un relleno; el mar, que se
    // dibuja despues, lo deja medio hundido tras el horizonte.
    dib(OPC_CIRC,      46, 28,   0,  0,   0,  0, 8'd255,8'd196,8'd104, 10);
    dib(OPC_CIRC_FILL, 46, 28,   0,  0,   0,  0, 8'd255,8'd238,8'd150,  7);

    // El mar, en tres franjas de profundidad.
    dib(OPC_RECT_FILL,  0, 30,  63, 33,   0,  0, 8'd86 ,8'd104,8'd140, 0);
    dib(OPC_RECT_FILL,  0, 34,  63, 39,   0,  0, 8'd34 ,8'd66 ,8'd112, 0);
    dib(OPC_RECT_FILL,  0, 40,  63, 47,   0,  0, 8'd18 ,8'd38 ,8'd76 , 0);

    // Reguero del sol sobre el agua, en primer plano y cada vez mas corto.
    dib(OPC_LINE,      43, 38,  51, 38,   0,  0, 8'd255,8'd214,8'd126, 0);
    dib(OPC_LINE,      44, 40,  50, 40,   0,  0, 8'd255,8'd214,8'd126, 0);
    dib(OPC_LINE,      44, 42,  49, 42,   0,  0, 8'd255,8'd214,8'd126, 0);
    dib(OPC_LINE,      45, 44,  49, 44,   0,  0, 8'd255,8'd214,8'd126, 0);
    dib(OPC_LINE,      45, 46,  48, 46,   0,  0, 8'd255,8'd214,8'd126, 0);

    // El acantilado, en contraluz.
    dib(OPC_TRIA_FILL,  0, 18,   0, 47,  20, 47, 8'd30 ,8'd34 ,8'd46 , 0);
    dib(OPC_TRIA_FILL, 10, 47,  14, 36,  30, 47, 8'd38 ,8'd42 ,8'd56 , 0);

    // El faro: torre, tres franjas rojas, linterna, lampara y techo.
    dib(OPC_RECT_FILL,  4, 10,   9, 28,   0,  0, 8'd236,8'd234,8'd224, 0);
    dib(OPC_RECT_FILL,  4, 13,   9, 15,   0,  0, 8'd198,8'd52 ,8'd46 , 0);
    dib(OPC_RECT_FILL,  4, 19,   9, 21,   0,  0, 8'd198,8'd52 ,8'd46 , 0);
    dib(OPC_RECT_FILL,  4, 25,   9, 27,   0,  0, 8'd198,8'd52 ,8'd46 , 0);
    dib(OPC_RECT_FILL,  2,  7,  11,  9,   0,  0, 8'd58 ,8'd58 ,8'd72 , 0);
    dib(OPC_RECT_FILL,  4,  7,   9,  9,   0,  0, 8'd255,8'd250,8'd194, 0);
    dib(OPC_TRIA_FILL,  2,  7,  11,  7,   6,  2, 8'd188,8'd44 ,8'd38 , 0);

    // Destellos de la lampara: tres rayos cortos en abanico. Un sector
    // relleno taparia el cielo y se leeria como una nube, y una linea larga
    // casi horizontal sale escalonada y parece una raya suelta.
    dib(OPC_LINE,      12,  6,  18,  3,   0,  0, 8'd255,8'd242,8'd190, 0);
    dib(OPC_LINE,      12,  8,  19,  8,   0,  0, 8'd255,8'd242,8'd190, 0);
    dib(OPC_LINE,      12, 10,  18, 13,   0,  0, 8'd255,8'd242,8'd190, 0);

    // Velero a contraluz sobre el disco del sol. Las velas se dejan separadas
    // del mastil por una columna de fondo; pegadas, la silueta se funde en
    // una sola mancha y el barco deja de reconocerse.
    dib(OPC_LINE,      47, 23,  47, 34,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_TRIA_FILL, 45, 24,  45, 33,  39, 33, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_TRIA_FILL, 49, 26,  49, 33,  54, 33, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_TRIA_FILL, 41, 34,  54, 34,  47, 37, 8'd26 ,8'd24 ,8'd44 , 0);

    // Aves, cada una de dos trazos.
    dib(OPC_LINE,      27, 11,  29,  9,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_LINE,      29,  9,  31, 11,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_LINE,      35,  7,  37,  5,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_LINE,      37,  5,  39,  7,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_LINE,      21, 16,  23, 14,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
    dib(OPC_LINE,      23, 14,  25, 16,   0,  0, 8'd26 ,8'd24 ,8'd44 , 0);
  endtask

  //===========================================================================
  // Secuencia
  //===========================================================================
  initial begin
    comand_w_ena = 1'b0;  comand_w_data = '0;
    enable = 1'b1;  reset_soft = 1'b0;
    borrar_fb();
    borrar_captura();

    fd_img = $fopen(ARCHIVO_IMG, "w");
    fd_prb = $fopen(ARCHIVO_PRB, "w");
    if ((fd_img == 0) || (fd_prb == 0)) begin
      $display("[ERROR] no se pudieron abrir los archivos de volcado");
      $finish;
    end
    $fdisplay(fd_prb, "prueba;obtenido;esperado;resultado");

    $display("");
    $display("==========================================================");
    $display(" Escena unica: Faro en la costa al atardecer");
    $display(" Region visible: %0d x %0d, %0d bits por pixel", W, H, PB);
    $display("==========================================================");

    repeat (4) @(negedge clk);
    rst_n     = 1'b1;
    rst_pix_n = 1'b1;
    repeat (8) @(negedge clk);

    // MOE-01 limpia los dos buffers y descarta lo que llegue a la cola
    // mientras tanto: la escena se envia cuando el sistema ya esta en espera.
    while (modo == M_INIT) @(negedge clk);
    repeat (64) @(negedge clk);
    borrar_fb();
    emitidos = 0;
    pw_arranque = pixels_written;          // pixeles escritos por MOE-01

    //------------------------------------------------- 1. dibujo de la escena
    $display("");
    $display("--- 1. Dibujo de la escena -------------------------------");
    escena();
    esperar_fin();
    $display("  %0d comandos de dibujo, %0d pixeles aceptados",
             n_comandos, emitidos);

    //----------------------------------------- 2. presentacion e informe
    $display("");
    $display("--- 2. Presentacion e informe ----------------------------");
    // SWAP solo se hace efectivo en el flanco de VSYNC, de modo que el
    // cuadro nunca se parte por la mitad.
    dib(OPC_SWAP, 0, 0, 0, 0, 0, 0, 8'd0, 8'd0, 8'd0, 0);
    esperar_fin();
    $display("  buffer delantero tras el intercambio: %0s",
             buffer_sel ? "B" : "A");

    dib(OPC_INF, 0, 0, 0, 0, 0, 0, 8'd0, 8'd0, 8'd0, 0);
    esperar_fin();
    $display("  ciclos de rasterizacion : %0d", perf_cycles);
    $display("  comandos completados    : %0d", perf_commands);
    $display("  pixeles escritos        : %0d", perf_pixels);
    $display("  paquetes descartados    : %0d", perf_dropped);
    $display("  rafagas de escritura    : %0d", burst_writes);
    $display("  rafagas de lectura      : %0d", burst_reads);

    //------------------------------------- 3. captura del barrido de video
    $display("");
    $display("--- 3. Captura del barrido de video ----------------------");
    capturar_cuadro();
    $display("  cuadros barridos: %0d, pixeles capturados: %0d",
             vga_frames, cap_pixeles);

    //--------------------------------------------------- 4. comprobaciones
    $display("");
    $display("--- 4. Comprobaciones ------------------------------------");

    chk("el sistema vuelve a la espera",      modo,            M_IDLE);
    chk("ocupado en bajo",                    busy,            0);
    chk("cola vacia",                         fifo_empty,      1);
    chk("sin errores registrados",            err_count,       0);
    chk("sin desbordamiento de la cola",      overflow,        0);
    chk("sin paquetes descartados",           perf_dropped,    0);
    // INF congela los contadores en el ciclo en que se decodifica, que es
    // antes de contarse a si mismo como completado. Por eso el informe
    // publica uno menos que el total enviado, y no es un fallo.
    chk("comandos completados",               perf_commands,   n_comandos - 1);
    chk("ultimo SEQ_ID atendido",             seq_last,        n_comandos);

    // El medidor y el observador del banco cuentan el mismo suceso: el pixel
    // aceptado por el gestor de framebuffer. Si discrepan, uno de los dos
    // esta contando ciclos de contrapresion en lugar de pixeles.
    chk("el medidor coincide con lo observado", perf_pixels,   emitidos);
    chk("pixeles anotados por el gestor",     pixels_written - pw_arranque, emitidos);
    chk("ningun pixel fuera de pantalla",     clip_count,      0);
    chk("direccion lineal siempre correcta",  err_dir,         0);
    chk("sin escrituras fuera de region",     out_of_range,    0);
    chk("el barrido nunca se quedo sin datos",vga_underrun,    0);
    chk("buffer delantero tras el SWAP",      buffer_sel,      1);

    // La escena cubre la pantalla entera: CLEAR escribe los 3072 pixeles.
    begin : cuenta_escritos
      int n_escritos;
      n_escritos = 0;
      for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) if (fbw[y][x]) n_escritos++;
      chk("pixeles distintos escritos", n_escritos, W*H);
    end

    // Colores de referencia. Son los que produce el modelo de las primitivas
    // sobre esta misma lista de comandos, de modo que comprueban a la vez la
    // geometria, el orden de pintado y la conversion RGB888 a RGB565.
    $display("");
    chk_col("cielo del cenit",                   32,  0, 16'h18A7);
    chk_col("banda alta del cielo",              60, 10, 16'h310B);
    chk_col("banda del horizonte",               60, 27, 16'hFD8A);
    chk_col("centro del disco solar",            46, 28, 16'hFF72);
    chk_col("torre del faro, tramo blanco",       6, 17, 16'hEF5C);
    chk_col("torre del faro, franja roja",        6, 20, 16'hC1A5);
    chk_col("lampara encendida",                  6,  8, 16'hFFD8);
    chk_col("acantilado en primer plano",         2, 45, 16'h1905);
    chk_col("mar en primer plano",               60, 45, 16'h1129);
    chk_col("mastil del velero",                 47, 30, 16'h18C5);
    chk_col("reguero del sol en el agua",        46, 44, 16'hFEAF);

    // Comprobacion fuerte: el cuadro que sale por el puerto de video tiene
    // que ser identico al que escribio el rasterizador. Recorre el doble
    // buffer, el cruce de dominios, la prebusqueda de lineas y la expansion
    // de color de vuelta a RGB888.
    $display("");
    difs = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++)
        if (cap_fb[y][x] !== fb[y][x]) difs++;
    chk("el barrido coincide con lo rasterizado", difs, 0);

    //---------------------------------------------------- 5. volcados
    $display("");
    $display("--- 5. Volcado -------------------------------------------");
    volcar("faro_rasterizado");
    volcar_captura("faro_barrido_vga");

    //------------------------------------------------------ 6. veredicto
    $display("");
    $display("==========================================================");
    if (errores == 0)
      $display(" ESCENA CORRECTA: todas las comprobaciones pasaron");
    else
      $display(" %0d COMPROBACIONES FALLARON", errores);
    $display("==========================================================");
    $display("");
    $display(" Para ver la imagen:  python ver_raster.py");
    $display("");

    $fclose(fd_img);
    $fclose(fd_prb);
    $finish;
  end

  //--------------------------------------------------------------- vigilante
  // Red de seguridad: si algo se queda esperando, la simulacion termina con
  // un mensaje en lugar de colgarse. El cuadro completo cabe de sobra en
  // este plazo.
  initial begin
    #20_000_000;                        // 20 ms
    $display("");
    $display("[ERROR] se agoto el tiempo de simulacion con el sistema en");
    $display("        modo %0d, cola %0s, ocupado %0b",
             modo, fifo_empty ? "vacia" : "con comandos", busy);
    $finish;
  end

endmodule
