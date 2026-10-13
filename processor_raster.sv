`timescale 1ns / 1ps

//=============================================================================
// processor_raster.sv
// Modulo : Rasterizador 2D, reparto de comandos entre los modulos de dibujo
//
// Recibe un comando ya decodificado y lo encamina al modulo que sabe
// dibujarlo. Tiene las cinco primitivas instanciadas en paralelo y
// permanentemente, porque en hardware no se crean a demanda: lo que se
// multiplexa es cual de ellas arranca y cual de las cinco salidas se
// escucha. Solo una esta activa en cada momento, de modo que el area es el
// precio y a cambio no hay recurso que compartir ni que arbitrar.
//
//   start   pulso del decodificador con los argumentos ya presentados
//   op      operacion en codificacion reducida de 4 bits
//   stall   el gestor de framebuffer no acepta: congela todo el camino
//   busy    hay un comando en vuelo (incluido el que esta pendiente)
//   done    pulso de un ciclo al completarse; lo espera MOE_WAIT
//
// Tres decisiones de diseno concentradas aqui:
//
//   - El color llega en RGB888 y se convierte a RGB565 con la funcion del
//     paquete, que es desplazamiento y OR: no cuesta ningun ciclo.
//   - CLEAR no tiene modulo propio. Se reescribe como un rectangulo relleno
//     del tamano de la pantalla antes de arrancar draw_rect.
//   - La operacion se registra en op_q al arrancar, de modo que el
//     multiplexor de salida sigue apuntando al modulo correcto aunque la
//     entrada op ya haya cambiado.
//
// start_pend retiene la peticion cuando llega durante un stall o con una
// figura todavia en curso, y la suelta en cuanto se puede atender; sin ello
// un pulso de start coincidente con una espera se perderia.
//
// done se filtra por flanco porque las maquinas de dibujo levantan su done
// durante un ciclo entero y el decodificador espera un pulso unico.
//=============================================================================
module processor_raster #(
  parameter int SCREEN_W   = Acelerador_pkg::SCREEN_W,
  parameter int SCREEN_H   = Acelerador_pkg::SCREEN_H,
  parameter int PIXEL_BITS = Acelerador_pkg::PIXEL_BITS
)(
  input  logic               clk,
  input  logic               rst_n,

  // Comando decodificado
  input  logic               start,
  input  logic               stall,     // El gestor de framebuffer no acepta
  input  logic        [3:0]  op,
  input  logic signed [15:0] x0, y0, x1, y1, x2, y2,
  input  logic        [9:0]  radius,

  // Color de la palabra W4 del paquete, en RGB888
  input  logic        [7:0]  color_r,
  input  logic        [7:0]  color_g,
  input  logic        [7:0]  color_b,

  // Control de la ventana de medicion
  input  logic               clr_cnt,

  output logic               busy,
  output logic               done,

  // Solicitud de pixel
  output logic               px_valid,
  output logic [$clog2(SCREEN_W)-1:0] px_x,
  output logic [$clog2(SCREEN_H)-1:0] px_y,
  output logic [PIXEL_BITS-1:0]       px_color,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0] px_addr,

  // Instrumentacion
  output logic        [31:0] pix_count,
  output logic        [31:0] clip_count
);

  // Codigos de operacion
  localparam logic [3:0] OP_PIXEL     = Acelerador_pkg::OP_PIXEL;
  localparam logic [3:0] OP_LINE      = Acelerador_pkg::OP_LINE;
  localparam logic [3:0] OP_RECT      = Acelerador_pkg::OP_RECT;
  localparam logic [3:0] OP_RECT_FILL = Acelerador_pkg::OP_RECT_FILL;
  localparam logic [3:0] OP_CIRC      = Acelerador_pkg::OP_CIRC;
  localparam logic [3:0] OP_CIRC_FILL = Acelerador_pkg::OP_CIRC_FILL;
  localparam logic [3:0] OP_TRIA      = Acelerador_pkg::OP_TRIA;
  localparam logic [3:0] OP_TRIA_FILL = Acelerador_pkg::OP_TRIA_FILL;
  localparam logic [3:0] OP_CLEAR     = Acelerador_pkg::OP_CLEAR;

  // Conversion de color
  // Desplazamiento y OR, sin aritmetica ni condicionales, se resuelve en cableado y no consume ningun ciclo. 
  logic [PIXEL_BITS-1:0] color565;
  assign color565 = Acelerador_pkg::rgb888_to_rgb565(color_r, color_g, color_b);

  // Operacion en curso
  logic [3:0] op_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     op_q <= OP_PIXEL;
    else if (start) op_q <= op;
  end

  // Reasignacion de parametros
  // CLEAR se reescribe como un rectangulo relleno del tamano de la pantalla
  logic signed [15:0] rx0, ry0, rx1, ry1;
  logic               rfill;

  always_comb begin
    case (op)
      OP_CLEAR: begin
        rx0 = 16'sd0;  ry0 = 16'sd0;
        rx1 = 16'(SCREEN_W - 1);  ry1 = 16'(SCREEN_H - 1);  rfill = 1'b1;
      end
      default: begin
        rx0 = x0;  ry0 = y0;  rx1 = x1;  ry1 = y1;
        rfill = (op == OP_RECT_FILL);
      end
    endcase
  end

  // Inicializacion de variables
  logic s_pix, s_rect, s_line, s_circ, s_tria;

  logic start_pend, start_ef, ocupado;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)      start_pend <= 1'b0;
    else if (start)  start_pend <= 1'b1;
    else if (start_ef) start_pend <= 1'b0;
  end

  assign start_ef = start_pend && !stall && !ocupado;

  assign s_pix  = start_ef &&  (op == OP_PIXEL);
  assign s_rect = start_ef && ((op == OP_RECT) || (op == OP_RECT_FILL)
                         || (op == OP_CLEAR));
  assign s_line = start_ef &&  (op == OP_LINE);
  assign s_circ = start_ef && ((op == OP_CIRC) || (op == OP_CIRC_FILL));
  assign s_tria = start_ef && ((op == OP_TRIA) || (op == OP_TRIA_FILL));

  logic               bp, br, bl, bc, bt;
  logic               dp, dr, dl, dc, dt;
  logic               vp, vr, vl, vc, vt;
  logic signed [15:0] xp, xr, xl, xc, xt;
  logic signed [15:0] yp, yr, yl, yc, yt;
  logic [PIXEL_BITS-1:0] cp, cr, cl, cc, ct;

  // Llamados de operaciones
  draw_pixel #(.PIXEL_BITS(PIXEL_BITS)) u_pix (
    .clk(clk), .rst_n(rst_n), .start(s_pix), .stall(stall),
    .x0(x0), .y0(y0), .color_in(color565),
    .busy(bp), .done(dp), .px_valid(vp),
    .px_x(xp), .px_y(yp), .px_color(cp));

  draw_rect #(.PIXEL_BITS(PIXEL_BITS)) u_rect (
    .clk(clk), .rst_n(rst_n), .start(s_rect), .stall(stall), .fill(rfill),
    .x0(rx0), .y0(ry0), .x1(rx1), .y1(ry1), .color_in(color565),
    .busy(br), .done(dr), .px_valid(vr),
    .px_x(xr), .px_y(yr), .px_color(cr));

  draw_line #(.PIXEL_BITS(PIXEL_BITS)) u_line (
    .clk(clk), .rst_n(rst_n), .start(s_line), .stall(stall),
    .x0_in(x0), .y0_in(y0), .x1_in(x1), .y1_in(y1), .color_in(color565),
    .busy(bl), .done(dl), .px_valid(vl),
    .px_x(xl), .px_y(yl), .px_color(cl));

  draw_circle #(.PIXEL_BITS(PIXEL_BITS)) u_circ (
    .clk(clk), .rst_n(rst_n), .start(s_circ), .stall(stall), .fill(op == OP_CIRC_FILL),
    .cx_in(x0), .cy_in(y0), .r_in(radius), .color_in(color565),
    .busy(bc), .done(dc), .px_valid(vc),
    .px_x(xc), .px_y(yc), .px_color(cc));

  draw_trian #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H),
               .PIXEL_BITS(PIXEL_BITS)) u_tria (
    .clk(clk), .rst_n(rst_n), .start(s_tria), .stall(stall), .fill(op == OP_TRIA_FILL),
    .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
    .color_in(color565),
    .busy(bt), .done(dt), .px_valid(vt),
    .px_x(xt), .px_y(yt), .px_color(ct));

  // Multiplexor de salida
  logic                  v_raw;
  logic signed [15:0]    x_raw, y_raw;
  logic [PIXEL_BITS-1:0] k_raw;

  always_comb begin
    case (op_q)
      OP_PIXEL:               begin v_raw = vp; x_raw = xp; y_raw = yp; k_raw = cp; end
      OP_LINE:                begin v_raw = vl; x_raw = xl; y_raw = yl; k_raw = cl; end
      OP_CIRC, OP_CIRC_FILL:  begin v_raw = vc; x_raw = xc; y_raw = yc; k_raw = cc; end
      OP_TRIA, OP_TRIA_FILL:  begin v_raw = vt; x_raw = xt; y_raw = yt; k_raw = ct; end
      default:                begin v_raw = vr; x_raw = xr; y_raw = yr; k_raw = cr; end
    endcase
  end

  // Generador de pixeles
  pixel_gen #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H),
              .PIXEL_BITS(PIXEL_BITS)) u_pxgen (
    .clk(clk), .rst_n(rst_n), .clr_cnt(clr_cnt), .px_ready(!stall),
    .valid_in(v_raw), .x_in(x_raw), .y_in(y_raw), .color_in(k_raw),
    .px_valid(px_valid), .px_x(px_x), .px_y(px_y),
    .px_color(px_color), .px_addr(px_addr),
    .pix_count(pix_count), .clip_count(clip_count));

  assign ocupado = bp | br | bl | bc | bt;
  assign busy    = ocupado | start_pend;

  logic done_raw, done_q;

  assign done_raw = dp | dr | dl | dc | dt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) done_q <= 1'b0;
    else        done_q <= done_raw;
  end

  assign done = done_raw && !done_q;

endmodule
