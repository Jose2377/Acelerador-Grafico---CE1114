`timescale 1ns / 1ps
//=============================================================================
// Acelerador_pkg.sv
// Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
// Modulo   : Paquete de parametros, tipos y conversion de color compartidos
// Autor    : Jose Maria Vindas Ortiz (2022209471)
//
// Incremento actual (camino completo hasta la salida de video):
//   - region visible reducida de 64 x 48 pixeles
//   - pixel de 16 bits en formato RGB565 (PIXEL_BITS del Documento de Diseno)
//   - cola de comandos, decodificador, rasterizador, gestor de framebuffer
//     con doble buffer y controlador VGA, todos presentes
//   - el framebuffer vive en memoria interna de la FPGA (framebuffer_onchip);
//     el controlador de SDRAM todavia no existe, pero el gestor ya habla el
//     Avalon-MM de rafaga que ese modulo implementara, de modo que el cambio
//     es el parametro FB_ONCHIP del nivel superior
//   - sin HPS: los registros del mapa estan cableados a los puertos del
//     nivel superior y es el banco de pruebas quien los acciona
//
// Dos tablas de temporizacion y dos codificaciones de operacion conviven aqui
// a proposito; cada una dice en su seccion a quien sirve.
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

  // Ancho de la coordenada con signo del paquete (W1 a W3). Documenta el
  // formato; los modulos escriben 16 directamente en sus puertos, asi que
  // ningun cuerpo lo lee todavia.
  parameter int CW         = 16;
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

  //------------------------------------------------------------ Relojes
  // Dos dominios. El de rasterizado y SDRAM va a 100 MHz; el de pixel lo
  // fija la temporizacion VGA. En la placa los produce un ALTPLL a partir
  // del oscilador de 50 MHz.
  //
  // SYS_CLK_HZ lo usa led_status para dimensionar sus cuentas atras (el
  // banco de pruebas le pasa un valor reducido para no simular doce
  // millones de ciclos por destello). PIX_CLK_HZ es solo documentacion:
  // ningun modulo lo lee, porque la temporizacion se expresa en ciclos de
  // clk_pix y no en hercios.
  parameter int SYS_CLK_HZ = 100_000_000;
  parameter int PIX_CLK_HZ =  25_175_000;

  //------------------------------------------------------- Framebuffer
  // Bases de los dos buffers dentro de la SDRAM, en palabras de 16 bits.
  // Un buffer de 640 x 480 ocupa 307 200 palabras y la separacion es de
  // 1 048 576, de modo que queda margen de sobra y las dos bases estan
  // alineadas a potencia de dos.
  //
  // Esa alineacion permitiria resolver la direccion con una concatenacion,
  // pero ni framebuffer_controller ni framebuffer_onchip la aprovechan: el
  // primero suma la base al indice y el segundo compara contra los dos
  // rangos. Es deliberado, para que los dos modulos sigan siendo correctos
  // si estas bases cambian y dejan de ser potencias de dos.
  parameter int FB_BASE_A = 25'h000000;
  parameter int FB_BASE_B = 25'h100000;

  parameter int BURST_LEN      = 8;   // palabras por rafaga hacia la SDRAM
  parameter int LINE_BUF_LINES = 4;   // lineas que el VGA lleva prellenadas

  //------------------------------------- Temporizacion VESA 640 x 480 a 60 Hz
  // 800 x 525 relojes de pixel por cuadro a 25,175 MHz dan 59,94 Hz. Los dos
  // sincronismos son de polaridad negativa en este modo. Son los valores del
  // sistema completo: cambiar SCREEN_W o SCREEN_H obliga a recalcular la
  // temporizacion entera, por eso las dos tablas viven juntas.
  parameter int VGA_H_VISIBLE = 640;
  parameter int VGA_H_FRONT   =  16;
  parameter int VGA_H_SYNC    =  96;
  parameter int VGA_H_BACK    =  48;
  parameter int VGA_V_VISIBLE = 480;
  parameter int VGA_V_FRONT   =  10;
  parameter int VGA_V_SYNC    =   2;
  parameter int VGA_V_BACK    =  33;
  parameter bit VGA_HS_POL    = 1'b0;   // nivel activo del pulso
  parameter bit VGA_VS_POL    = 1'b0;

  //------------------------- Temporizacion reducida del incremento actual
  // Proporcional a la anterior para la region de 64 x 48. Conserva la
  // estructura de porches, de modo que el banco de pruebas recorre el mismo
  // camino logico en una fraccion del tiempo de simulacion.
  //   total horizontal 80, total vertical 53
  parameter int H_VISIBLE = SCREEN_W;   // 64
  parameter int H_FRONT   = 2;
  parameter int H_SYNC    = 10;
  parameter int H_BACK    = 4;
  parameter int V_VISIBLE = SCREEN_H;   // 48
  parameter int V_FRONT   = 1;
  parameter int V_SYNC    = 2;
  parameter int V_BACK    = 2;

  parameter int H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
  parameter int V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

  //------------------------------------- SDRAM IS42S16320D de la placa
  // 32M x 16 en cuatro bancos: 13 bits de fila, 10 de columna, 2 de banco,
  // que suman los 25 de SD_ADDR_BITS y cubren las 33 554 432 palabras.
  //
  // De los cinco, el unico que sale del paquete es SD_ADDR_BITS, que fija el
  // ancho del bus de direccion del maestro de rafaga. Los otros describen el
  // dispositivo para cuando exista sdram_controller; SD_DATA_BITS coincide
  // con PIXEL_BITS por casualidad del formato de color, y los modulos usan
  // PIXEL_BITS, que es lo que de verdad quieren decir.
  parameter int SD_ROW_BITS  = 13;
  parameter int SD_COL_BITS  = 10;
  parameter int SD_BANK_BITS =  2;
  parameter int SD_DATA_BITS = 16;
  parameter int SD_ADDR_BITS = SD_ROW_BITS + SD_COL_BITS + SD_BANK_BITS;  // 25

  //------------------------------------------------------- Codigos de error
  // EC-01 a EC-05 los emite la interfaz de comandos en el nivel 1 y nunca
  // llegan al hardware, de modo que no se definen aqui: el salto de 0 a 6 en
  // los valores es intencionado y conserva la numeracion del documento.
  // Los tres definidos son los que el hardware detecta por si mismo; los
  // emite decoder_fsm y quedan visibles en el registro ERR_INFO.
  localparam logic [3:0] EC_NONE        = 4'd0;   // sin error
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

  // Vuelta a RGB888 replicando los bits altos en los bajos. La usa
  // vga_controller en cada pixel visible para expandir el color hacia el
  // conversor de video de la placa, de modo que si forma parte de la ruta de
  // datos; el banco de pruebas hace el camino inverso para comprobar que lo
  // barrido coincide con lo rasterizado.
  //
  // Replicar los bits altos y no rellenar con ceros es lo que hace que el
  // blanco siga siendo blanco: 5 bits a uno dan 0xFF y no 0xF8. La ida y la
  // vuelta no son exactamente inversas (se perdieron bits al reducir), pero
  // volver a RGB565 desde aqui recupera el valor original, porque la
  // expansion solo repitio bits que ya estaban.
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
  // Los modulos la exponen en puertos sueltos (px_valid, px_x, px_y,
  // px_color) para no obligar a importar el paquete en cada hoja de la
  // jerarquia, y el gestor de framebuffer, ya incorporado, los recibe igual
  // de sueltos.
  //
  // Es decir que este tipo no esta en uso: queda como documentacion del
  // contenido de la interfaz IF-07 y como base si alguna vez conviene
  // empaquetarla en un solo bus. Lo mismo vale para PIXREQ_BITS.
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
      // Atrapa OPC_CLEAR y, de paso, cualquier codigo no listado. Es seguro
      // porque decoder_fsm ya rechazo los invalidos con opcode_valido y
      // desvio NOP, SWAP e INF antes de llegar aqui; si alguna vez se llama
      // sin esos filtros, un codigo desconocido borraria la pantalla.
      default:       opcode_a_op = OP_CLEAR;      // OPC_CLEAR
    endcase
  endfunction

  // Cierto para los codigos que producen pixeles (OPC_PIXEL a OPC_CLEAR).
  // Sin consumidor por ahora: decoder_fsm distingue los tres que no dibujan
  // con un case explicito en lugar de llamar aqui.
  function automatic logic opcode_dibuja(input logic [7:0] opc);
    opcode_dibuja = (opc >= OPC_PIXEL) && (opc <= OPC_CLEAR);
  endfunction

  // Cierto para cualquier codigo definido, dibuje o no.
  function automatic logic opcode_valido(input logic [7:0] opc);
    opcode_valido = (opc <= OPC_INF);
  endfunction

endpackage
