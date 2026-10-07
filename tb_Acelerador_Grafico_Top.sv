module tb_Acelerador_Grafico_Top;
 
  localparam int W = 64;
  localparam int H = 48;
 
  // codigos de operacion, iguales a los de raster2d
  localparam logic [3:0] OP_PIXEL     = 4'd0;
  localparam logic [3:0] OP_LINE      = 4'd1;
  localparam logic [3:0] OP_RECT      = 4'd2;
  localparam logic [3:0] OP_RECT_FILL = 4'd3;
  localparam logic [3:0] OP_CIRC      = 4'd4;
  localparam logic [3:0] OP_CIRC_FILL = 4'd5;
  localparam logic [3:0] OP_TRIA      = 4'd6;
  localparam logic [3:0] OP_TRIA_FILL = 4'd7;
  localparam logic [3:0] OP_CLEAR     = 4'd8;
 
  //------------------------------------------------------- reloj y reinicio
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz
 
  //----------------------------------------------------------- senales
  logic               start;
  logic        [3:0]  op;
  logic signed [15:0] x0, y0, x1, y1, x2, y2;
  logic        [9:0]  radius;
  logic               busy, done, px_valid;
  logic [$clog2(W)-1:0] px_x;
  logic [$clog2(H)-1:0] px_y;
  logic        [31:0] pix_count;
 
  Acelerador_Grafico_Top #(.SCREEN_W(W), .SCREEN_H(H)) dut (
    .clk(clk), .rst_n(rst_n),
    .start(start), .op(op),
    .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
    .radius(radius),
    .busy(busy), .done(done),
    .px_valid(px_valid), .px_x(px_x), .px_y(px_y),
    .pix_count(pix_count)
  );
 
  //-------------------------------- framebuffer local del banco de pruebas
  logic fb [0:H-1][0:W-1];
  int   emitidos;          // pixeles del ultimo comando
  int   errores = 0;
 
  always @(posedge clk) begin
    if (px_valid) begin
      fb[px_y][px_x] <= 1'b1;
      emitidos       <= emitidos + 1;
    end
  end
 
  //------------------------------------------------------------- tareas
  task automatic borrar_fb();
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) fb[y][x] = 1'b0;
  endtask
 
  // Ejecuta un comando y espera a que termine. Devuelve cuantos pixeles emitio.
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
 
  task automatic chk(input string nombre, input int got, input int exp);
    if (got === exp)
      $display("  [OK  ] %-46s = %0d", nombre, got);
    else begin
      $display("  [FALLA] %-46s = %0d (esperado %0d)", nombre, got, exp);
      errores++;
    end
  endtask
 
  task automatic chk_px(input string nombre, input int x, input int y,
                        input logic exp);
    if (fb[y][x] === exp)
      $display("  [OK  ] %-46s = %0b", nombre, fb[y][x]);
    else begin
      $display("  [FALLA] %-46s = %0b (esperado %0b)", nombre, fb[y][x], exp);
      errores++;
    end
  endtask
 
  task automatic dibujar(input string titulo);
    $display("");
    $write("  +");  for (int x = 0; x < W; x++) $write("-");  $display("+");
    for (int y = 0; y < H; y++) begin
      $write("  |");
      for (int x = 0; x < W; x++) $write("%c", fb[y][x] ? "#" : ".");
      $display("|");
    end
    $write("  +");  for (int x = 0; x < W; x++) $write("-");  $display("+");
    $display("  %0s", titulo);
    $display("");
  endtask
 
  //---------------------------------------------------------- secuencia
  initial begin
    start = 1'b0;  op = '0;  radius = '0;
    x0 = '0; y0 = '0; x1 = '0; y1 = '0; x2 = '0; y2 = '0;
    emitidos = 0;
    borrar_fb();
 
    $display("");
    $display("==========================================================");
    $display(" raster2d  -  banco de pruebas del rasterizador aislado");
    $display(" Region visible: %0d x %0d pixeles", W, H);
    $display("==========================================================");
 
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);
 
    //------------------------------------------------ 1. pixel y recorte
    $display("");
    $display("--- 1. Pixel suelto y recorte por pixel -------------------");
    borrar_fb();
    cmd(OP_PIXEL, 10, 10, 0,0, 0,0, 0);
    chk("pixeles emitidos por DRAW_PIXEL", emitidos, 1);
    chk_px("pixel (10,10) encendido", 10, 10, 1'b1);
 
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
    cmd(OP_LINE, 0,0, 10,0, 0,0, 0);
    chk("linea horizontal (0,0)-(10,0)", emitidos, 11);
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
 
    //----------------------------------------------------- 3. rectangulo
    $display("");
    $display("--- 3. Rectangulo, contorno y relleno ---------------------");
    borrar_fb();
    cmd(OP_RECT_FILL, 4,4, 13,9, 0,0, 0);
    chk("relleno 10x6", emitidos, 60);
    chk_px("esquina (4,4)", 4, 4, 1'b1);
    chk_px("esquina (13,9)", 13, 9, 1'b1);
    chk_px("vecino exterior (14,9)", 14, 9, 1'b0);
 
    borrar_fb();
    cmd(OP_RECT, 20,4, 29,9, 0,0, 0);
    chk("contorno 10x6 (perimetro)", emitidos, 2*10 + 2*(6-2));
    chk_px("borde superior (25,4)", 25, 4, 1'b1);
    chk_px("interior hueco (25,6)", 25, 6, 1'b0);
 
    //-------------------------------------------------------- 4. circulo
    $display("");
    $display("--- 4. Circulo, contorno y relleno ------------------------");
    borrar_fb();
    cmd(OP_CIRC, 32, 24, 0,0, 0,0, 10);
    chk_px("punto derecho del contorno (42,24)", 42, 24, 1'b1);
    chk_px("punto superior del contorno (32,14)", 32, 14, 1'b1);
    chk_px("centro vacio (32,24)", 32, 24, 1'b0);
 
    borrar_fb();
    cmd(OP_CIRC_FILL, 32, 24, 0,0, 0,0, 5);
    chk_px("centro relleno (32,24)", 32, 24, 1'b1);
    chk_px("borde del disco (37,24)", 37, 24, 1'b1);
    chk_px("fuera del disco (38,24)", 38, 24, 1'b0);
    // pi*r^2 con r=5 son unos 78 pixeles; el algoritmo emite 81
    if ((emitidos > 70) && (emitidos < 95))
      $display("  [OK  ] %-46s = %0d", "area del disco r=5 (esperado ~79)", emitidos);
    else begin
      $display("  [FALLA] area del disco r=5 = %0d, fuera del rango razonable", emitidos);
      errores++;
    end
 
    //------------------------------------------------------ 5. triangulo
    $display("");
    $display("--- 5. Triangulo, contorno y relleno ----------------------");
    borrar_fb();
    cmd(OP_TRIA, 10,40, 20,20, 30,40, 0);
    chk_px("vertice superior (20,20)", 20, 20, 1'b1);
    chk_px("vertice izquierdo (10,40)", 10, 40, 1'b1);
    chk_px("interior hueco (20,35)", 20, 35, 1'b0);
 
    borrar_fb();
    cmd(OP_TRIA_FILL, 10,40, 20,20, 30,40, 0);
    chk_px("interior relleno (20,35)", 20, 35, 1'b1);
    chk_px("exterior (12,22)", 12, 22, 1'b0);
    // el triangulo mide 20 de base y 20 de alto: unos 200 pixeles
    if ((emitidos > 180) && (emitidos < 240))
      $display("  [OK  ] %-46s = %0d", "area del triangulo (esperado ~210)", emitidos);
    else begin
      $display("  [FALLA] area del triangulo = %0d, fuera del rango razonable", emitidos);
      errores++;
    end
 
    // el mismo triangulo con los vertices en orden inverso debe dar lo mismo
    borrar_fb();
    cmd(OP_TRIA_FILL, 30,40, 20,20, 10,40, 0);
    chk_px("giro invertido: interior relleno (20,35)", 20, 35, 1'b1);
 
    //--------------------------------------------------------- 6. borrado
    $display("");
    $display("--- 6. Borrado de pantalla completa -----------------------");
    borrar_fb();
    cmd(OP_CLEAR, 0,0, 0,0, 0,0, 0);
    chk("pixeles de CLEAR", emitidos, W*H);
 
    //------------------------------------------------- 7. escena completa
    $display("");
    $display("--- 7. Escena de demostracion -----------------------------");
    borrar_fb();
    cmd(OP_RECT,      1,1, 62,46, 0,0, 0);      // marco
    cmd(OP_RECT_FILL, 4,4, 16,14, 0,0, 0);      // rectangulo relleno
    cmd(OP_CIRC,      45,11, 0,0, 0,0, 8);      // circunferencia
    cmd(OP_LINE,      4,20, 59,20, 0,0, 0);     // linea horizontal
    cmd(OP_LINE,      24,4, 34,17, 0,0, 0);     // linea oblicua
    cmd(OP_TRIA,      5,43, 14,25, 23,43, 0);   // triangulo hueco
    cmd(OP_TRIA_FILL, 28,43, 37,25, 46,43, 0);  // triangulo relleno
    cmd(OP_CIRC_FILL, 55,35, 0,0, 0,0, 6);      // disco
    dibujar("Escena de demostracion (# = pixel encendido)");
    $display("  Pixeles emitidos en total desde el reinicio: %0d", pix_count);
 
    //------------------------------------------------------------ resumen
    $display("");
    $display("==========================================================");
    if (errores == 0) $display(" RESULTADO: todas las comprobaciones pasaron");
    else              $display(" RESULTADO: %0d comprobacion(es) fallaron", errores);
    $display("==========================================================");
    $display("");
    $finish;
  end
 
  //-------------------------------------------------- guardia de tiempo
  initial begin
    #5_000_000;                       // 5 ms
    $display("[ERROR] la simulacion excedio el tiempo maximo");
    $finish;
  end
 
endmodule