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

  //------------------------------- Codigos de operacion del paquete (8 bits)
  // Son los de la tabla de la perspectiva de interfaces, tal como viajan en
  // el campo OPCODE de la palabra W0. El decodificador traduce estos a la
  // codificacion reducida de 4 bits que entiende el rasterizador; mantener
  // las dos separadas evita que un cambio del protocolo obligue a rehacer el
  // multiplexor de los modulos de dibujo.
  localparam logic [7:0] OPC_NOP       = 8'h00;
  localparam logic [7:0] OPC_PIXEL     = 8'h01;
  localparam logic [7:0] OPC_LINE      = 8'h02;
  localparam logic [7:0] OPC_TRIA      = 8'h03;
  localparam logic [7:0] OPC_TRIA_FILL = 8'h04;
  localparam logic [7:0] OPC_RECT      = 8'h05;
  localparam logic [7:0] OPC_RECT_FILL = 8'h06;
  localparam logic [7:0] OPC_CIRC      = 8'h07;
  localparam logic [7:0] OPC_CIRC_FILL = 8'h08;
  localparam logic [7:0] OPC_CLEAR     = 8'h09;
  localparam logic [7:0] OPC_SWAP      = 8'h0A;
  localparam logic [7:0] OPC_INF       = 8'h0B;

  //-------------------------------------------------------- Cola de comandos
  // En el sistema completo la cola guarda 256 comandos. Aqui se reduce para
  // que el banco de pruebas pueda llenarla y provocar el desbordamiento en
  // un tiempo de simulacion razonable. Debe ser potencia de dos.
  parameter int FIFO_DEPTH = 16;

  //------------------------------------------------------- Codigos de error
  // EC-01 a EC-04 los emite la interfaz de comandos en el nivel 1 y nunca
  // llegan al hardware. Los tres siguientes son los que el hardware puede
  // detectar por si mismo.
  localparam logic [3:0] EC_NONE     = 4'd0;   // sin error
  localparam logic [3:0] EC_06_OPCODE   = 4'd6;   // codigo de operacion desconocido
  localparam logic [3:0] EC_07_PARAM    = 4'd7;   // parametro geometrico invalido
  localparam logic [3:0] EC_08_OVERFLOW = 4'd8;   // desbordamiento de la cola

  //----------------------------------------------------------- Modos (MOE)
  typedef enum logic [2:0] {
    MOE_INIT  = 3'd0,   // MOE-01  inicializacion
    MOE_IDLE  = 3'd1,   // MOE-02  espera
    MOE_PROC  = 3'd2,   // MOE-03  procesamiento
    MOE_SWAP  = 3'd3,   // MOE-04  intercambio de buffer
    MOE_INFO  = 3'd4,   // MOE-05  informe de rendimiento
    MOE_ERROR = 3'd5,   // MOE-06  error
    MOE_WAIT  = 3'd6    // subestado interno de MOE-03: espera al rasterizador
  } sys_state_e;

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

  //-------------------------------------------- Comando decodificado (168 bits)
  // Corresponde al paquete de 24 bytes de la perspectiva de interfaces sin
  // los campos reservados, que el esclavo Avalon-MM consume al desempacar las
  // seis palabras. Es lo que viaja por la cola de comandos.
  //
  //   W0 = OPCODE[31:24] | FLAGS[23:16] | SEQ_ID[15:0]
  //   W1 = x0[31:16] | y0[15:0]
  //   W2 = x1[31:16] | y1[15:0]
  //   W3 = x2[31:16] | y2[15:0]
  //   W4 = reservado[31:24] | R[23:16] | G[15:8] | B[7:0]
  //   W5 = reservado[31:16] | PARAM[15:0]
  typedef struct packed {
    logic [7:0]         opcode;
    logic [7:0]         flags;
    logic [15:0]        seq_id;
    logic signed [15:0] x0, y0;
    logic signed [15:0] x1, y1;
    logic signed [15:0] x2, y2;
    logic [7:0]         r, g, b;
    logic [15:0]        param;
  } comand_t;

  parameter int COMAND_BITS = $bits(comand_t);

  //------------------------------------- Traduccion de OPCODE a la operacion
  // Devuelve la codificacion reducida de 4 bits que consume el rasterizador.
  // Los codigos que no dibujan (NOP, SWAP_BUFFER, INF) no tienen equivalente
  // y los resuelve la maquina de estados antes de llamar a esta funcion.
  function automatic logic [3:0] opcode_a_op(input logic [7:0] opc);
    case (opc)
      OPC_PIXEL:     opcode_a_op = OP_PIXEL;
      OPC_LINE:      opcode_a_op = OP_LINE;
      OPC_TRIA:      opcode_a_op = OP_TRIA;
      OPC_TRIA_FILL: opcode_a_op = OP_TRIA_FILL;
      OPC_RECT:      opcode_a_op = OP_RECT;
      OPC_RECT_FILL: opcode_a_op = OP_RECT_FILL;
      OPC_CIRC:      opcode_a_op = OP_CIRC;
      OPC_CIRC_FILL: opcode_a_op = OP_CIRC_FILL;
      default:       opcode_a_op = OP_CLEAR;      // OPC_CLEAR
    endcase
  endfunction

  // Cierto para los codigos que producen pixeles.
  function automatic logic opcode_dibuja(input logic [7:0] opc);
    opcode_dibuja = (opc >= OPC_PIXEL) && (opc <= OPC_CLEAR);
  endfunction

  // Cierto para cualquier codigo definido, dibuje o no.
  function automatic logic opcode_valido(input logic [7:0] opc);
    opcode_valido = (opc <= OPC_INF);
  endfunction

endpackage
