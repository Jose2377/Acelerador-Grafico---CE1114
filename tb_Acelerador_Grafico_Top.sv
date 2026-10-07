//=============================================================================
// tb_Acelerador_Grafico_Top.sv
// Banco de pruebas del rasterizador con color y generador de pixeles
//
// El banco de pruebas no dibuja: mide y vuelca. Produce dos archivos de
// texto plano que la herramienta de visualizacion en Python convierte en
// imagenes y en una tabla de resultados:
//
//   raster_dump.csv     un fotograma por escena, con los pixeles escritos
//                       y su color RGB565
//   raster_pruebas.csv  una fila por comprobacion, con lo obtenido y lo
//                       esperado
//
// Separar la medicion de la presentacion tiene dos ventajas: el transcript
// del simulador queda legible, y la imagen que se revisa es la imagen real
// en color y no una aproximacion en caracteres.
//
// Uso:  vsim -c -do "run -all" tb_Acelerador_Grafico_Top
//       python ver_raster.py
//=============================================================================
module tb_Acelerador_Grafico_Top;

  import Acelerador_pkg::*;

  // Codigos de operacion traidos del paquete con el nombre calificado, por
  // la misma razon que en el nivel superior.
  localparam logic [3:0] OP_PIXEL     = Acelerador_pkg::OP_PIXEL;
  localparam logic [3:0] OP_LINE      = Acelerador_pkg::OP_LINE;
  localparam logic [3:0] OP_RECT      = Acelerador_pkg::OP_RECT;
  localparam logic [3:0] OP_RECT_FILL = Acelerador_pkg::OP_RECT_FILL;
  localparam logic [3:0] OP_CIRC      = Acelerador_pkg::OP_CIRC;
  localparam logic [3:0] OP_CIRC_FILL = Acelerador_pkg::OP_CIRC_FILL;
  localparam logic [3:0] OP_TRIA      = Acelerador_pkg::OP_TRIA;
  localparam logic [3:0] OP_TRIA_FILL = Acelerador_pkg::OP_TRIA_FILL;
  localparam logic [3:0] OP_CLEAR     = Acelerador_pkg::OP_CLEAR;

  localparam int W  = 64;
  localparam int H  = 48;
  localparam int PB = 16;
  localparam int AW = $clog2(W*H);

  //------------------------------------------------------- reloj y reinicio
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz

  //----------------------------------------------------------- senales
  logic               start;
  logic        [3:0]  op;
  logic signed [15:0] x0, y0, x1, y1, x2, y2;
  logic        [9:0]  radius;
  logic        [7:0]  color_r, color_g, color_b;
  logic               clr_cnt;
  logic               busy, done, px_valid;
  logic [$clog2(W)-1:0] px_x;
  logic [$clog2(H)-1:0] px_y;
  logic [PB-1:0]      px_color;
  logic [AW-1:0]      px_addr;
  logic        [31:0] pix_count, clip_count;

  Acelerador_Grafico_Top #(.SCREEN_W(W), .SCREEN_H(H), .PIXEL_BITS(PB)) dut (
    .clk(clk), .rst_n(rst_n),
    .start(start), .op(op),
    .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
    .radius(radius),
    .color_r(color_r), .color_g(color_g), .color_b(color_b),
    .clr_cnt(clr_cnt),
    .busy(busy), .done(done),
    .px_valid(px_valid), .px_x(px_x), .px_y(px_y),
    .px_color(px_color), .px_addr(px_addr),
    .pix_count(pix_count), .clip_count(clip_count)
  );

  //-------------------------------- framebuffer local del banco de pruebas
  logic [PB-1:0] fb  [0:H-1][0:W-1];   // color RGB565
  logic          fbw [0:H-1][0:W-1];   // mascara de escritura
  int   emitidos;          // pixeles del ultimo comando
  int   errores = 0;
  int   err_dir = 0;       // discrepancias entre px_addr y y*W + x

  always @(posedge clk) begin
    if (px_valid) begin
      fb[px_y][px_x]  <= px_color;
      fbw[px_y][px_x] <= 1'b1;
      emitidos        <= emitidos + 1;
      // El generador de pixeles tiene que entregar siempre la direccion
      // lineal coherente con las coordenadas visibles.
      if (px_addr !== AW'(px_y * W + px_x)) err_dir++;
    end
  end

  //-------------------------------------------- archivos de volcado
  int fd_img;              // raster_dump.csv
  int fd_prb;              // raster_pruebas.csv
  int n_frame = 0;

  //------------------------------------------------------------- tareas
  task automatic borrar_fb();
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) begin
        fb[y][x]  = '0;
        fbw[y][x] = 1'b0;
      end
  endtask

  task automatic color(input logic [7:0] r, input logic [7:0] g,
                       input logic [7:0] b);
    color_r = r;  color_g = g;  color_b = b;
  endtask

  // Ejecuta un comando y espera a que termine.
  task automatic cmd(input logic [3:0] o,
                     input int a, input int b,
                     input int c, input int d,
                     input int e, input int f,
                     input int r);
    @(negedge clk);
    op = o;
    x0 = a[15:0];  y0 = b[15:0];
    x1 = c[15:0];  y1 = d[15:0];
    x2 = e[15:0];  y2 = f[15:0];
    radius   = r[9:0];
    emitidos = 0;
    start    = 1'b1;
    @(negedge clk);
    start = 1'b0;
    // espera al pulso de fin
    while (!done) @(negedge clk);
    @(negedge clk);
  endtask

  //----------------------------------------- comprobaciones y su registro
  // Cada comprobacion se imprime en el transcript y se anota en el archivo
  // de pruebas, para que el resumen en Python no dependa de reinterpretar
  // la salida del simulador.
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

  // Comprobacion de ocupacion: hay o no hay pixel escrito en (x,y)
  task automatic chk_px(input string nombre, input int x, input int y,
                        input logic exp);
    anotar(nombre, $sformatf("%0b", fbw[y][x]), $sformatf("%0b", exp),
           fbw[y][x] === exp);
  endtask

  // Comprobacion de color: el pixel (x,y) tiene exactamente este RGB565
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
  // Formato por fotograma:
  //   F;<indice>;<nombre>;<ancho>;<alto>;<pixeles>;<descartados>
  //   P;<x>;<y>;<color RGB565 en hexadecimal>
  // Solo se escriben los pixeles realmente escritos: el fondo no se vuelca,
  // de modo que el archivo crece con la escena y no con la resolucion.
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

  //---------------------------------------------------------- secuencia
  initial begin
    start = 1'b0;  op = '0;  radius = '0;  clr_cnt = 1'b0;
    x0 = '0; y0 = '0; x1 = '0; y1 = '0; x2 = '0; y2 = '0;
    color(8'hFF, 8'hFF, 8'hFF);
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
    $display(" Rasterizador con color y generador de pixeles");
    $display(" Region visible: %0d x %0d pixeles, %0d bits por pixel", W, H, PB);
    $display("==========================================================");

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    //--------------------------------------- 0. conversion RGB888 a RGB565
    $display("");
    $display("--- 0. Conversion de color por desplazamiento y OR --------");
    chk_conv(8'h00, 8'h00, 8'h00, COL_NEGRO);
    chk_conv(8'hFF, 8'hFF, 8'hFF, COL_BLANCO);
    chk_conv(8'hFF, 8'h00, 8'h00, COL_ROJO);
    chk_conv(8'h00, 8'hFF, 8'h00, COL_VERDE);
    chk_conv(8'h00, 8'h00, 8'hFF, COL_AZUL);
    chk_conv(8'hFF, 8'hFF, 8'h00, COL_AMARILLO);
    chk_conv(8'h00, 8'hFF, 8'hFF, COL_CIAN);
    chk_conv(8'hFF, 8'h00, 8'hFF, COL_MAGENTA);
    // truncamiento: los 3 bits bajos de rojo y azul y los 2 de verde se
    // pierden, por eso 0x07 de rojo cae a cero y 0x08 ya enciende el bit 11
    chk_conv(8'h07, 8'h03, 8'h07, 16'h0000);
    chk_conv(8'h08, 8'h04, 8'h08, 16'h0821);
    chk_conv(8'h12, 8'h34, 8'h56, 16'h11AA);

    //------------------------------------------------ 1. pixel y recorte
    $display("");
    $display("--- 1. Pixel suelto y recorte por pixel -------------------");
    borrar_fb();
    color(8'hFF, 8'h00, 8'h00);                   // rojo
    cmd(OP_PIXEL, 10, 10, 0,0, 0,0, 0);
    chk("pixeles emitidos por DRAW_PIXEL", emitidos, 1);
    chk_px("pixel (10,10) escrito", 10, 10, 1'b1);
    chk_col("pixel (10,10) en rojo", 10, 10, COL_ROJO);

    color(8'h00, 8'h00, 8'hFF);                   // azul encima del mismo pixel
    cmd(OP_PIXEL, 10, 10, 0,0, 0,0, 0);
    chk_col("sobrescritura: (10,10) ahora azul", 10, 10, COL_AZUL);

    // el negro es un color valido y debe quedar escrito
    color(8'h00, 8'h00, 8'h00);
    cmd(OP_PIXEL, 11, 10, 0,0, 0,0, 0);
    chk("pixel negro emitido", emitidos, 1);
    chk_col("pixel (11,10) en negro", 11, 10, COL_NEGRO);

    color(8'hFF, 8'hFF, 8'hFF);
    cmd(OP_PIXEL, -5, 20, 0,0, 0,0, 0);
    chk("pixel fuera de pantalla por la izquierda", emitidos, 0);
    cmd(OP_PIXEL, W+3, 20, 0,0, 0,0, 0);
    chk("pixel fuera de pantalla por la derecha", emitidos, 0);
    cmd(OP_PIXEL, 20, H+5, 0,0, 0,0, 0);
    chk("pixel fuera de pantalla por abajo", emitidos, 0);

    //---------------------------------------------------------- 2. linea
    $display("");
    $display("--- 2. Linea de Bresenham ---------------------------------");
    borrar_fb();
    color(8'h00, 8'hFF, 8'h00);                   // verde
    cmd(OP_LINE, 0,0, 10,0, 0,0, 0);
    chk("linea horizontal (0,0)-(10,0)", emitidos, 11);
    chk_col("extremo inicial (0,0) en verde", 0, 0, COL_VERDE);
    chk_col("extremo final (10,0) en verde", 10, 0, COL_VERDE);
    cmd(OP_LINE, 0,0, 0,10, 0,0, 0);
    chk("linea vertical (0,0)-(0,10)", emitidos, 11);
    cmd(OP_LINE, 0,0, 10,10, 0,0, 0);
    chk("diagonal perfecta (0,0)-(10,10)", emitidos, 11);
    cmd(OP_LINE, 0,0, 20,7, 0,0, 0);
    chk("pendiente suave (0,0)-(20,7)", emitidos, 21);
    cmd(OP_LINE, 5,5, 5,5, 0,0, 0);
    chk("linea degenerada (5,5)-(5,5)", emitidos, 1);
    // una linea que entra y sale de la pantalla se dibuja en su parte visible
    cmd(OP_LINE, -20, 24, 20, 24, 0,0, 0);
    chk("linea recortada: solo la parte visible", emitidos, 21);
    chk_col("primer pixel visible (0,24) en verde", 0, 24, COL_VERDE);
    volcar("lineas_bresenham");

    //----------------------------------------------------- 3. rectangulo
    $display("");
    $display("--- 3. Rectangulo, contorno y relleno ---------------------");
    borrar_fb();
    color(8'h00, 8'h00, 8'hFF);                   // azul
    cmd(OP_RECT_FILL, 4,4, 13,9, 0,0, 0);
    chk("relleno 10x6", emitidos, 60);
    chk_px("esquina (4,4)", 4, 4, 1'b1);
    chk_px("esquina (13,9)", 13, 9, 1'b1);
    chk_px("vecino exterior (14,9)", 14, 9, 1'b0);
    chk_col("relleno uniforme: centro (8,6) azul", 8, 6, COL_AZUL);
    chk_col("relleno uniforme: esquina (13,9) azul", 13, 9, COL_AZUL);

    color(8'hFF, 8'hFF, 8'h00);                   // amarillo
    cmd(OP_RECT, 20,4, 29,9, 0,0, 0);
    chk("contorno 10x6 (perimetro)", emitidos, 2*10 + 2*(6-2));
    chk_px("borde superior (25,4)", 25, 4, 1'b1);
    chk_px("interior hueco (25,6)", 25, 6, 1'b0);
    chk_col("borde superior (25,4) amarillo", 25, 4, COL_AMARILLO);
    chk_col("borde inferior (25,9) amarillo", 25, 9, COL_AMARILLO);
    chk_col("borde izquierdo (20,6) amarillo", 20, 6, COL_AMARILLO);
    chk_col("borde derecho (29,6) amarillo", 29, 6, COL_AMARILLO);
    volcar("rectangulos");

    //-------------------------------------------------------- 4. circulo
    $display("");
    $display("--- 4. Circulo, contorno y relleno ------------------------");
    borrar_fb();
    color(8'h00, 8'hFF, 8'hFF);                   // cian
    cmd(OP_CIRC, 32, 24, 0,0, 0,0, 10);
    chk_px("punto derecho del contorno (42,24)", 42, 24, 1'b1);
    chk_px("punto superior del contorno (32,14)", 32, 14, 1'b1);
    chk_px("centro vacio (32,24)", 32, 24, 1'b0);
    chk_col("contorno (42,24) en cian", 42, 24, COL_CIAN);
    chk_col("contorno (32,14) en cian", 32, 14, COL_CIAN);
    chk_col("contorno (22,24) en cian", 22, 24, COL_CIAN);

    // El disco se coloca fuera de la caja de la circunferencia anterior,
    // para que ambos quepan en el mismo fotograma sin tocarse y los puntos
    // de control midan solo la figura que les corresponde.
    color(8'hFF, 8'h00, 8'hFF);                   // magenta
    cmd(OP_CIRC_FILL, 10, 10, 0,0, 0,0, 5);
    chk_px("centro relleno (10,10)", 10, 10, 1'b1);
    chk_px("borde del disco (15,10)", 15, 10, 1'b1);
    chk_px("fuera del disco (16,10)", 16, 10, 1'b0);
    chk_col("centro del disco en magenta", 10, 10, COL_MAGENTA);
    chk_col("borde del disco en magenta", 15, 10, COL_MAGENTA);
    // pi*r^2 con r=5 son unos 78 pixeles; el algoritmo emite 81
    chk_rango("area del disco r=5 (esperado ~79)", emitidos, 70, 95);
    volcar("circulos");

    //------------------------------------------------------ 5. triangulo
    $display("");
    $display("--- 5. Triangulo, contorno y relleno ----------------------");
    borrar_fb();
    color(8'hFF, 8'h00, 8'h00);                   // rojo
    cmd(OP_TRIA, 10,40, 20,20, 30,40, 0);
    chk_px("vertice superior (20,20)", 20, 20, 1'b1);
    chk_px("vertice izquierdo (10,40)", 10, 40, 1'b1);
    chk_px("interior hueco (20,35)", 20, 35, 1'b0);
    // el contorno pasa por tres instancias de draw_line: el color tiene que
    // sobrevivir a las tres aristas
    chk_col("arista 1: vertice (20,20) en rojo", 20, 20, COL_ROJO);
    chk_col("arista 2: vertice (30,40) en rojo", 30, 40, COL_ROJO);
    chk_col("arista 3: base (20,40) en rojo", 20, 40, COL_ROJO);

    color(8'h00, 8'hFF, 8'h00);                   // verde
    cmd(OP_TRIA_FILL, 34,40, 44,20, 54,40, 0);
    chk_px("interior relleno (44,35)", 44, 35, 1'b1);
    chk_px("exterior (36,22)", 36, 22, 1'b0);
    chk_col("interior relleno (44,35) en verde", 44, 35, COL_VERDE);
    // el triangulo mide 20 de base y 20 de alto: unos 200 pixeles
    chk_rango("area del triangulo (esperado ~210)", emitidos, 180, 240);
    volcar("triangulos");

    // el mismo triangulo con los vertices en orden inverso debe dar lo mismo
    borrar_fb();
    cmd(OP_TRIA_FILL, 54,40, 44,20, 34,40, 0);
    chk_px("giro invertido: interior relleno (44,35)", 44, 35, 1'b1);
    chk_col("giro invertido: color conservado", 44, 35, COL_VERDE);
    volcar("triangulo_giro_invertido");

    //--------------------------------------------------------- 6. borrado
    $display("");
    $display("--- 6. Borrado de pantalla completa -----------------------");
    borrar_fb();
    color(8'h00, 8'h00, 8'h00);                   // CLEAR a negro
    cmd(OP_CLEAR, 0,0, 0,0, 0,0, 0);
    chk("pixeles de CLEAR", emitidos, W*H);
    chk_col("esquina (0,0) en negro", 0, 0, COL_NEGRO);
    chk_col("esquina (63,47) en negro", W-1, H-1, COL_NEGRO);

    // CLEAR tambien sirve para pintar un fondo de cualquier color
    color(8'h00, 8'h00, 8'hFF);
    cmd(OP_CLEAR, 0,0, 0,0, 0,0, 0);
    chk("pixeles de CLEAR con color de fondo", emitidos, W*H);
    chk_col("fondo (32,24) en azul", 32, 24, COL_AZUL);
    volcar("clear_con_color_de_fondo");

    //------------------------------------- 7. direccion lineal del pixel
    $display("");
    $display("--- 7. Direccion lineal entregada por pixel_gen -----------");
    chk("discrepancias de px_addr acumuladas", err_dir, 0);
    borrar_fb();
    color(8'hFF, 8'hFF, 8'hFF);
    cmd(OP_PIXEL, 0, 0, 0,0, 0,0, 0);
    chk("px_addr del pixel (0,0)", int'(px_addr), 0);
    cmd(OP_PIXEL, 1, 0, 0,0, 0,0, 0);
    chk("px_addr del pixel (1,0)", int'(px_addr), 1);
    cmd(OP_PIXEL, 0, 1, 0,0, 0,0, 0);
    chk("px_addr del pixel (0,1)", int'(px_addr), W);
    cmd(OP_PIXEL, W-1, H-1, 0,0, 0,0, 0);
    chk("px_addr del ultimo pixel", int'(px_addr), W*H - 1);

    //-------------------------------- 8. contadores de instrumentacion
    $display("");
    $display("--- 8. Contadores del generador de pixeles ----------------");
    @(negedge clk);  clr_cnt = 1'b1;  @(negedge clk);  clr_cnt = 1'b0;
    chk("pix_count tras reiniciar la ventana", int'(pix_count), 0);
    chk("clip_count tras reiniciar la ventana", int'(clip_count), 0);
    borrar_fb();
    cmd(OP_RECT_FILL, 0,0, 9,9, 0,0, 0);
    chk("pix_count tras un relleno 10x10", int'(pix_count), 100);
    chk("clip_count sin pixeles exteriores", int'(clip_count), 0);
    // un rectangulo que se sale por la derecha: los exteriores se cuentan
    color(8'hFF, 8'h00, 8'h00);
    cmd(OP_RECT_FILL, W-5, 0, W+4, 0, 0,0, 0);
    chk("pix_count: solo los 5 visibles se escriben", int'(pix_count), 105);
    chk("clip_count: 5 pixeles descartados", int'(clip_count), 5);
    volcar("recorte_por_el_borde_derecho");

    //------------------------------------------------- 9. escena completa
    $display("");
    $display("--- 9. Escena de demostracion en color --------------------");
    @(negedge clk);  clr_cnt = 1'b1;  @(negedge clk);  clr_cnt = 1'b0;
    borrar_fb();
    color(8'h00, 8'h00, 8'h20);
    cmd(OP_CLEAR,     0,0, 0,0, 0,0, 0);        // fondo azul muy oscuro
    color(8'hFF, 8'hFF, 8'hFF);
    cmd(OP_RECT,      1,1, 62,46, 0,0, 0);      // marco blanco
    color(8'h00, 8'h00, 8'hFF);
    cmd(OP_RECT_FILL, 4,4, 16,14, 0,0, 0);      // rectangulo azul
    color(8'h00, 8'hFF, 8'hFF);
    cmd(OP_CIRC,      45,11, 0,0, 0,0, 8);      // circunferencia cian
    color(8'hFF, 8'hFF, 8'h00);
    cmd(OP_LINE,      4,20, 59,20, 0,0, 0);     // linea amarilla
    color(8'hFF, 8'h00, 8'hFF);
    cmd(OP_LINE,      24,4, 34,17, 0,0, 0);     // linea magenta
    color(8'hFF, 8'h00, 8'h00);
    cmd(OP_TRIA,      5,43, 14,25, 23,43, 0);   // triangulo rojo hueco
    color(8'h00, 8'hFF, 8'h00);
    cmd(OP_TRIA_FILL, 28,43, 37,25, 46,43, 0);  // triangulo verde relleno
    color(8'hFF, 8'h80, 8'h00);
    cmd(OP_CIRC_FILL, 55,35, 0,0, 0,0, 6);      // disco naranja
    volcar("escena_de_demostracion");
    $display("  Pixeles escritos en la ventana: %0d", pix_count);
    $display("  Pixeles descartados por recorte: %0d", clip_count);
    chk("discrepancias de px_addr en la escena", err_dir, 0);

    //----------------------------------- 10. degradado de la rampa de color
    // Barre los 32 niveles de rojo y los 32 de azul que caben en RGB565 y
    // deja el resultado en una imagen: es la prueba visual de que la
    // conversion por desplazamiento cubre el rango completo sin saltos.
    $display("");
    $display("--- 10. Rampa de color RGB565 -----------------------------");
    borrar_fb();
    for (int i = 0; i < 32; i++) begin
      color(8'(i * 8), 8'h00, 8'h00);
      cmd(OP_RECT_FILL, i*2, 0, i*2 + 1, 14, 0,0, 0);
    end
    for (int i = 0; i < 32; i++) begin
      color(8'h00, 8'(i * 8), 8'h00);
      cmd(OP_RECT_FILL, i*2, 16, i*2 + 1, 30, 0,0, 0);
    end
    for (int i = 0; i < 32; i++) begin
      color(8'h00, 8'h00, 8'(i * 8));
      cmd(OP_RECT_FILL, i*2, 32, i*2 + 1, 46, 0,0, 0);
    end
    chk_col("rampa: rojo maximo en (62,7)", 62, 7, COL_ROJO);
    chk_col("rampa: verde maximo en (62,23)", 62, 23, 16'h07C0);
    chk_col("rampa: azul maximo en (62,39)", 62, 39, COL_AZUL);
    chk_col("rampa: nivel cero en (0,7)", 0, 7, COL_NEGRO);
    volcar("rampa_de_color");

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

  //-------------------------------------------------- guardia de tiempo
  initial begin
    #5_000_000;                       // 5 ms
    $display("[ERROR] la simulacion excedio el tiempo maximo");
    $fclose(fd_img);
    $fclose(fd_prb);
    $finish;
  end

endmodule
