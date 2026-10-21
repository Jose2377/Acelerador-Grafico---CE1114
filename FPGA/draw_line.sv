`timescale 1ns / 1ps

//=============================================================================
// draw_line.sv
// Modulo : Dibujo de linea recta por el algoritmo de Bresenham  (OP_LINE)
//
// Traza la linea de (x0, y0) a (x1, y1) a razon de un pixel por ciclo. Es la
// variante del algoritmo que sirve para cualquier pendiente y cualquier
// sentido, sin tener que partir el problema en octantes.
//
// La idea es llevar un termino de error entero que mide cuanto se ha
// desviado la linea ideal del pixel elegido. En cada paso se comparan err
// duplicado contra dx y dy y se avanza en x, en y, o en las dos a la vez; el
// error se corrige con la pendiente correspondiente. Todo son sumas, restas
// y comparaciones de enteros: ni una division ni un multiplicador, que es
// justamente la razon de usar Bresenham en hardware.
//
// Convenio de signos: dx se guarda positivo y dy negativo, de modo que el
// error combinado es dx + dy y las dos comparaciones del lazo quedan
// simetricas. sx y sy llevan la direccion de avance de cada eje.
//
// Estados:
//   L_IDLE   espera start y captura extremos, pendientes y direcciones
//   L_SETUP  inicializa el error; un ciclo aparte porque dx y dy acaban de
//            quedar registrados y todavia no se pueden leer
//   L_RUN    un pixel por ciclo hasta alcanzar el extremo final
//   L_DONE   pulso de fin
//
// draw_trian reutiliza este mismo modulo para las tres aristas del
// triangulo sin relleno.
//=============================================================================
module draw_line #(
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,
  input  logic                    stall,
  input  logic signed [15:0]      x0_in, y0_in, x1_in, y1_in,
  input  logic [PIXEL_BITS-1:0]   color_in,
  output logic                    busy,
  output logic                    done,
  output logic                    px_valid,
  output logic signed [15:0]      px_x, px_y,
  output logic [PIXEL_BITS-1:0]   px_color
);

  typedef enum logic [1:0] {L_IDLE, L_SETUP, L_RUN, L_DONE} lst_e;
  lst_e st;

  logic signed [15:0] x, y, xe, ye, sx, sy;
  logic signed [21:0] dx, dy, err;
  logic [PIXEL_BITS-1:0] col;

  always_ff @(posedge clk or negedge rst_n) begin : p_line
    logic signed [22:0] e2;
    logic signed [21:0] err_n;
    logic signed [15:0] x_n, y_n;

    if (!rst_n) begin
      st <= L_IDLE;
      x <= '0; y <= '0; xe <= '0; ye <= '0; sx <= '0; sy <= '0;
      dx <= '0; dy <= '0; err <= '0; col <= '0;
    end else if (!stall) begin
      case (st)
        L_IDLE: if (start) begin
          x  <= x0_in;  y  <= y0_in;
          xe <= x1_in;  ye <= y1_in;
          dx <= (x1_in > x0_in) ?  (22'(x1_in) - 22'(x0_in)) : (22'(x0_in) - 22'(x1_in));
          dy <= (y1_in > y0_in) ? -(22'(y1_in) - 22'(y0_in)) : -(22'(y0_in) - 22'(y1_in));
          sx <= (x0_in < x1_in) ? 1 : -1;
          sy <= (y0_in < y1_in) ? 1 : -1;
          col <= color_in;
          st <= L_SETUP;
        end

        L_SETUP: begin
          err <= dx + dy;
          st  <= L_RUN;
        end

        L_RUN: begin
          if ((x == xe) && (y == ye)) begin
            st <= L_DONE;
          end else begin
            e2    = err + err;
            err_n = err;  x_n = x;  y_n = y;
            if (e2 >= dy) begin err_n = err_n + dy;  x_n = x_n + sx; end
            if (e2 <= dx) begin err_n = err_n + dx;  y_n = y_n + sy; end
            err <= err_n;  x <= x_n;  y <= y_n;
          end
        end

        L_DONE:  st <= L_IDLE;
        default: st <= L_IDLE;
      endcase
    end
  end

  assign busy     = (st != L_IDLE);
  assign done     = (st == L_DONE);
  assign px_valid = (st == L_RUN);
  assign px_x     = x;
  assign px_y     = y;
  assign px_color = col;
endmodule
