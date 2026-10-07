//=============================================================================
// Acelerador_pkg.sv
// Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
// Modulo   : Paquete de parametros, tipos y conversion de color compartidos
// Autor    : Jose Maria Vindas Ortiz (2022209471)
//
// Incremento actual (rasterizador aislado con color):
//   - region visible reducida de 64 x 48 pixeles
//   - pixel de 16 bits en formato RGB565 (PIXEL_BITS del Documento de Diseno)
//   - sin SDRAM, sin controlador VGA, sin HPS: la salida del rasterizador es
//     la solicitud de pixel de la interfaz IF-07
//=============================================================================
package Acelerador_pkg;

  //--------------------------------------------------------------- Geometria
  // En el sistema completo SCREEN_W y SCREEN_H valen 640 y 480. Aqui se
  // reducen para que el banco de pruebas quepa en la consola; ningun cuerpo
  // de modulo depende del valor concreto.
  parameter int SCREEN_W   = 64;
  parameter int SCREEN_H   = 48;

  parameter int XW         = $clog2(SCREEN_W);              // bits de x visible
  parameter int YW         = $clog2(SCREEN_H);              // bits de y visible
  parameter int AW         = $clog2(SCREEN_W * SCREEN_H);   // direccion lineal

  parameter int CW         = 16;   // coordenada con signo del paquete W1..W3
  parameter int PIXEL_BITS = 16;   // RGB565

  //------------------------------------------------------- Codigos de operacion
  // Codificacion reducida de 4 bits del incremento actual. El paquete de 24
  // bytes usa OPCODE de 8 bits (0x00 a 0x0B); el decodificador del sistema
  // completo hace la traduccion entre ambas.
  localparam logic [3:0] OP_PIXEL     = 4'd0;
  localparam logic [3:0] OP_LINE      = 4'd1;
  localparam logic [3:0] OP_RECT      = 4'd2;
  localparam logic [3:0] OP_RECT_FILL = 4'd3;
  localparam logic [3:0] OP_CIRC      = 4'd4;
  localparam logic [3:0] OP_CIRC_FILL = 4'd5;
  localparam logic [3:0] OP_TRIA      = 4'd6;
  localparam logic [3:0] OP_TRIA_FILL = 4'd7;
  localparam logic [3:0] OP_CLEAR     = 4'd8;

  //------------------------------------------------------- Conversion de color
  // La interfaz de comandos entrega el color en RGB888 (palabra W4 del
  // paquete) y el framebuffer almacena RGB565. La conversion es la descrita
  // en la perspectiva de algoritmos: desplazamiento de bits y OR, sin
  // aritmetica ni condicionales.
  //
  //   rojo  : 8 -> 5 bits, se desplaza 3 a la derecha y 11 a la izquierda
  //   verde : 8 -> 6 bits, se desplaza 2 a la derecha y  5 a la izquierda
  //   azul  : 8 -> 5 bits, se desplaza 3 a la derecha y queda en la base
  //
  // El costo es una perdida de brillo de hasta 7/255 por componente; la
  // ganancia es que la conversion no consume ningun ciclo ni ningun DSP,
  // se resuelve con cableado.
  function automatic logic [PIXEL_BITS-1:0] rgb888_to_rgb565(
      input logic [7:0] r,
      input logic [7:0] g,
      input logic [7:0] b);
    logic [PIXEL_BITS-1:0] cr, cg, cb;
    cr = PIXEL_BITS'(r >> 3) << 11;
    cg = PIXEL_BITS'(g >> 2) << 5;
    cb = PIXEL_BITS'(b >> 3);
    rgb888_to_rgb565 = cr | cg | cb;
  endfunction

  // Vuelta a RGB888 replicando los bits altos en los bajos. No forma parte
  // de la ruta de datos: la usan los bancos de prueba y, en el sistema
  // completo, el controlador VGA para expandir a los conversores de la placa.
  function automatic logic [23:0] rgb565_to_rgb888(
      input logic [PIXEL_BITS-1:0] c);
    logic [7:0] r, g, b;
    r = {c[15:11], c[15:13]};
    g = {c[10:5],  c[10:9]};
    b = {c[4:0],   c[4:2]};
    rgb565_to_rgb888 = {r, g, b};
  endfunction

  //------------------------------------------- Colores de referencia RGB565
  parameter logic [PIXEL_BITS-1:0] COL_NEGRO    = 16'h0000;
  parameter logic [PIXEL_BITS-1:0] COL_BLANCO   = 16'hFFFF;
  parameter logic [PIXEL_BITS-1:0] COL_ROJO     = 16'hF800;
  parameter logic [PIXEL_BITS-1:0] COL_VERDE    = 16'h07E0;
  parameter logic [PIXEL_BITS-1:0] COL_AZUL     = 16'h001F;
  parameter logic [PIXEL_BITS-1:0] COL_AMARILLO = 16'hFFE0;
  parameter logic [PIXEL_BITS-1:0] COL_CIAN     = 16'h07FF;
  parameter logic [PIXEL_BITS-1:0] COL_MAGENTA  = 16'hF81F;

  //-------------------------------------------- Solicitud de pixel (IF-07)
  // Interfaz uniforme entre los modulos de dibujo y el gestor de framebuffer.
  // Los modulos la exponen en puertos sueltos para no obligar a importar el
  // paquete en cada hoja de la jerarquia; este tipo documenta su contenido y
  // sirve para empaquetarla cuando el gestor de framebuffer se incorpore.
  typedef struct packed {
    logic                  valid;
    logic [XW-1:0]         x;
    logic [YW-1:0]         y;
    logic [PIXEL_BITS-1:0] color;
  } solicitud_pixel_t;

  parameter int PIXREQ_BITS = $bits(solicitud_pixel_t);

endpackage
