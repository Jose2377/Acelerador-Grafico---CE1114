module draw_trian #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic               clk,
  input  logic               rst_n,
  input  logic               start,
  input  logic               fill,
  input  logic signed [15:0] x0, y0, x1, y1, x2, y2,
  output logic               busy,
  output logic               done,
  output logic               px_valid,
  output logic signed [15:0] px_x, px_y
);
  typedef enum logic [2:0] {
    T_IDLE, T_E0, T_E1, T_E2, T_SETUP, T_FILL, T_DONE
  } tst_e;
  tst_e st;

  logic signed [15:0] ax, ay, bx, by, gx, gy;
  logic signed [15:0] bx0, bx1, by0, by1, cx, cy;
  logic signed [35:0] e0, e1, e2, e0r, e1r, e2r;
  logic signed [35:0] sx0, sx1, sx2, sy0, sy1, sy2;

  logic               lg_start, lg_busy, lg_done, lg_valid;
  logic signed [15:0] lg_x0, lg_y0, lg_x1, lg_y1, lg_px, lg_py;

  draw_line u_gen (
    .clk(clk), .rst_n(rst_n), .start(lg_start),
    .x0_i(lg_x0), .y0_i(lg_y0), .x1_i(lg_x1), .y1_i(lg_y1),
    .busy(lg_busy), .done(lg_done),
    .px_valid(lg_valid), .px_x(lg_px), .px_y(lg_py));

  always_comb begin
    case (st)
      T_E0:    begin lg_x0 = ax; lg_y0 = ay; lg_x1 = bx; lg_y1 = by; end
      T_E1:    begin lg_x0 = bx; lg_y0 = by; lg_x1 = gx; lg_y1 = gy; end
      default: begin lg_x0 = gx; lg_y0 = gy; lg_x1 = ax; lg_y1 = ay; end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin : p_tri
    logic signed [35:0] area, ev0, ev1, ev2;
    logic signed [15:0] v1x, v1y, v2x, v2y, mnx, mxx, mny, mxy;

    if (!rst_n) begin
      st <= T_IDLE;  lg_start <= 1'b0;
      ax <= '0; ay <= '0; bx <= '0; by <= '0; gx <= '0; gy <= '0;
      bx0 <= '0; bx1 <= '0; by0 <= '0; by1 <= '0; cx <= '0; cy <= '0;
      e0 <= '0; e1 <= '0; e2 <= '0; e0r <= '0; e1r <= '0; e2r <= '0;
      sx0 <= '0; sx1 <= '0; sx2 <= '0; sy0 <= '0; sy1 <= '0; sy2 <= '0;
    end else begin
      lg_start <= 1'b0;
      case (st)
        T_IDLE: if (start) begin
          // Normalizacion del giro: si el area con signo es negativa se
          // intercambian v1 y v2, de modo que la prueba de signo sea unica.
          area = (36'(x1) - 36'(x0)) * (36'(y2) - 36'(y0))
               - (36'(y1) - 36'(y0)) * (36'(x2) - 36'(x0));
          if (area >= 0) begin v1x = x1; v1y = y1; v2x = x2; v2y = y2; end
          else           begin v1x = x2; v1y = y2; v2x = x1; v2y = y1; end

          ax <= x0;  ay <= y0;
          bx <= v1x; by <= v1y;
          gx <= v2x; gy <= v2y;

          if (fill) begin
            // Caja envolvente acotada a la pantalla: ahorra ciclos sin
            // cambiar el resultado, porque el recorte por pixel sigue activo.
            mnx = (((x0 < v1x) ? ((x0 < v2x) ? x0 : v2x)
                               : ((v1x < v2x) ? v1x : v2x)) > 0)
                  ? ((x0 < v1x) ? ((x0 < v2x) ? x0 : v2x)
                                : ((v1x < v2x) ? v1x : v2x)) : 16'sd0;
            mny = (((y0 < v1y) ? ((y0 < v2y) ? y0 : v2y)
                               : ((v1y < v2y) ? v1y : v2y)) > 0)
                  ? ((y0 < v1y) ? ((y0 < v2y) ? y0 : v2y)
                                : ((v1y < v2y) ? v1y : v2y)) : 16'sd0;
            mxx = (((x0 > v1x) ? ((x0 > v2x) ? x0 : v2x)
                               : ((v1x > v2x) ? v1x : v2x)) < SCREEN_W - 1)
                  ? ((x0 > v1x) ? ((x0 > v2x) ? x0 : v2x)
                                : ((v1x > v2x) ? v1x : v2x)) : 16'(SCREEN_W - 1);
            mxy = (((y0 > v1y) ? ((y0 > v2y) ? y0 : v2y)
                               : ((v1y > v2y) ? v1y : v2y)) < SCREEN_H - 1)
                  ? ((y0 > v1y) ? ((y0 > v2y) ? y0 : v2y)
                                : ((v1y > v2y) ? v1y : v2y)) : 16'(SCREEN_H - 1);

            bx0 <= mnx;  bx1 <= mxx;  by0 <= mny;  by1 <= mxy;
            cx  <= mnx;  cy  <= mny;

            sx0 <= -(36'(v1y) - 36'(y0));    sy0 <= (36'(v1x) - 36'(x0));
            sx1 <= -(36'(v2y) - 36'(v1y));   sy1 <= (36'(v2x) - 36'(v1x));
            sx2 <= -(36'(y0)  - 36'(v2y));   sy2 <= (36'(x0)  - 36'(v2x));

            ev0 = (36'(v1x) - 36'(x0))  * (36'(mny) - 36'(y0))
                - (36'(v1y) - 36'(y0))  * (36'(mnx) - 36'(x0));
            ev1 = (36'(v2x) - 36'(v1x)) * (36'(mny) - 36'(v1y))
                - (36'(v2y) - 36'(v1y)) * (36'(mnx) - 36'(v1x));
            ev2 = (36'(x0)  - 36'(v2x)) * (36'(mny) - 36'(v2y))
                - (36'(y0)  - 36'(v2y)) * (36'(mnx) - 36'(v2x));

            e0 <= ev0;  e1 <= ev1;  e2 <= ev2;
            e0r <= ev0; e1r <= ev1; e2r <= ev2;

            st <= ((area == 0) || (mnx > mxx) || (mny > mxy)) ? T_DONE : T_SETUP;
          end else begin
            lg_start <= 1'b1;
            st       <= T_E0;
          end
        end

        T_E0: if (lg_done) begin lg_start <= 1'b1; st <= T_E1; end
        T_E1: if (lg_done) begin lg_start <= 1'b1; st <= T_E2; end
        T_E2: if (lg_done) st <= T_DONE;

        T_SETUP: st <= T_FILL;

        T_FILL: begin
          if (cx == bx1) begin
            if (cy == by1) st <= T_DONE;
            else begin
              cy  <= cy + 1;      cx  <= bx0;
              e0  <= e0r + sy0;   e0r <= e0r + sy0;
              e1  <= e1r + sy1;   e1r <= e1r + sy1;
              e2  <= e2r + sy2;   e2r <= e2r + sy2;
            end
          end else begin
            cx <= cx + 1;
            e0 <= e0 + sx0;  e1 <= e1 + sx1;  e2 <= e2 + sx2;
          end
        end

        T_DONE:  st <= T_IDLE;
        default: st <= T_IDLE;
      endcase
    end
  end

  assign busy = (st != T_IDLE);
  assign done = (st == T_DONE);

  always_comb begin
    px_valid = 1'b0;  px_x = '0;  px_y = '0;
    if ((st == T_E0) || (st == T_E1) || (st == T_E2)) begin
      px_valid = lg_valid;  px_x = lg_px;  px_y = lg_py;
    end else if (st == T_FILL) begin
      px_valid = (e0 >= 0) && (e1 >= 0) && (e2 >= 0);
      px_x     = cx;        px_y = cy;
    end
  end
endmodule
