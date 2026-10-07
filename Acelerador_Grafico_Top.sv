module Acelerador_Grafico_Top #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic               clk,
  input  logic               rst_n,

  input  logic               start,
  input  logic        [3:0]  op,
  input  logic signed [15:0] x0, y0, x1, y1, x2, y2,
  input  logic        [9:0]  radius,

  output logic               busy,
  output logic               done,
  output logic               px_valid,
  output logic [$clog2(SCREEN_W)-1:0] px_x,
  output logic [$clog2(SCREEN_H)-1:0] px_y,
  output logic        [31:0] pix_count
);

  localparam logic [3:0] OP_PIXEL     = 4'd0;
  localparam logic [3:0] OP_LINE      = 4'd1;
  localparam logic [3:0] OP_RECT      = 4'd2;
  localparam logic [3:0] OP_RECT_FILL = 4'd3;
  localparam logic [3:0] OP_CIRC      = 4'd4;
  localparam logic [3:0] OP_CIRC_FILL = 4'd5;
  localparam logic [3:0] OP_TRIA      = 4'd6;
  localparam logic [3:0] OP_TRIA_FILL = 4'd7;
  localparam logic [3:0] OP_CLEAR     = 4'd8;

  //-------------------------------------------------- operacion en curso
  logic [3:0] op_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     op_q <= OP_PIXEL;
    else if (start) op_q <= op;
  end

  //------------------------------------------- reasignacion de parametros
  // PIXEL -> rectangulo relleno de una sola celda
  // CLEAR -> rectangulo relleno del tamano de la pantalla
  logic signed [15:0] rx0, ry0, rx1, ry1;
  logic               rfill;

  always_comb begin
    case (op)
      OP_PIXEL: begin
        rx0 = x0;  ry0 = y0;  rx1 = x0;  ry1 = y0;  rfill = 1'b1;
      end
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

  //------------------------------------------------- pulsos de arranque
  logic s_rect, s_line, s_circ, s_tria;
  assign s_rect = start && ((op == OP_PIXEL) || (op == OP_RECT)
                         || (op == OP_RECT_FILL) || (op == OP_CLEAR));
  assign s_line = start &&  (op == OP_LINE);
  assign s_circ = start && ((op == OP_CIRC) || (op == OP_CIRC_FILL));
  assign s_tria = start && ((op == OP_TRIA) || (op == OP_TRIA_FILL));

  //------------------------------------------------------- primitivas
  logic               br, bl, bc, bt;
  logic               dr, dl, dc, dt;
  logic               vr, vl, vc, vt;
  logic signed [15:0] xr, xl, xc, xt, yr, yl, yc, yt;

  draw_rect u_rect (
    .clk(clk), .rst_n(rst_n), .start(s_rect), .fill(rfill),
    .x0(rx0), .y0(ry0), .x1(rx1), .y1(ry1),
    .busy(br), .done(dr), .px_valid(vr), .px_x(xr), .px_y(yr));

  draw_line u_line (
    .clk(clk), .rst_n(rst_n), .start(s_line),
    .x0_i(x0), .y0_i(y0), .x1_i(x1), .y1_i(y1),
    .busy(bl), .done(dl), .px_valid(vl), .px_x(xl), .px_y(yl));

  draw_circle u_circ (
    .clk(clk), .rst_n(rst_n), .start(s_circ), .fill(op == OP_CIRC_FILL),
    .cx_i(x0), .cy_i(y0), .r_i(radius),
    .busy(bc), .done(dc), .px_valid(vc), .px_x(xc), .px_y(yc));

  draw_trian #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_tria (
    .clk(clk), .rst_n(rst_n), .start(s_tria), .fill(op == OP_TRIA_FILL),
    .x0(x0), .y0(y0), .x1(x1), .y1(y1), .x2(x2), .y2(y2),
    .busy(bt), .done(dt), .px_valid(vt), .px_x(xt), .px_y(yt));

  //--------------------------------------------- multiplexado de salida
  logic               v_raw;
  logic signed [15:0] x_raw, y_raw;

  always_comb begin
    case (op_q)
      OP_LINE:                begin v_raw = vl; x_raw = xl; y_raw = yl; end
      OP_CIRC, OP_CIRC_FILL:  begin v_raw = vc; x_raw = xc; y_raw = yc; end
      OP_TRIA, OP_TRIA_FILL:  begin v_raw = vt; x_raw = xt; y_raw = yt; end
      default:                begin v_raw = vr; x_raw = xr; y_raw = yr; end
    endcase
  end

  //---------------------------------------------------- recorte por pixel
  logic in_view;
  assign in_view = (x_raw >= 0) && (x_raw < SCREEN_W)
                && (y_raw >= 0) && (y_raw < SCREEN_H);

  assign px_valid = v_raw && in_view;
  assign px_x     = x_raw[$clog2(SCREEN_W)-1:0];
  assign px_y     = y_raw[$clog2(SCREEN_H)-1:0];

  assign busy = br | bl | bc | bt;
  assign done = dr | dl | dc | dt;

  //------------------------------------------------------- instrumentacion
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        pix_count <= '0;
    else if (px_valid) pix_count <= pix_count + 32'd1;
  end

endmodule