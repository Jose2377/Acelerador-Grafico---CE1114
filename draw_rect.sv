module draw_rect (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               start,
  input  logic               fill,
  input  logic signed [15:0] x0, y0, x1, y1,
  output logic               busy,
  output logic               done,
  output logic               px_valid,
  output logic signed [15:0] px_x, px_y
);
  typedef enum logic [2:0] {
    R_IDLE, R_FILL, R_TOP, R_BOT, R_LEFT, R_RIGHT, R_DONE
  } rst_e;
  rst_e st;

  logic signed [15:0] xa, xb, ya, yb, cx, cy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= R_IDLE;
      xa <= '0; xb <= '0; ya <= '0; yb <= '0; cx <= '0; cy <= '0;
    end else begin
      case (st)
        R_IDLE: if (start) begin
          xa <= (x0 < x1) ? x0 : x1;   xb <= (x0 > x1) ? x0 : x1;
          ya <= (y0 < y1) ? y0 : y1;   yb <= (y0 > y1) ? y0 : y1;
          cx <= (x0 < x1) ? x0 : x1;   cy <= (y0 < y1) ? y0 : y1;
          st <= fill ? R_FILL : R_TOP;
        end

        R_FILL: begin
          if (cx == xb) begin
            cx <= xa;
            if (cy == yb) st <= R_DONE;
            else          cy <= cy + 1;
          end else cx <= cx + 1;
        end

        R_TOP: begin                                  // arista superior
          if (cx == xb) begin
            cx <= xa;  cy <= yb;
            st <= (yb == ya) ? R_DONE : R_BOT;
          end else cx <= cx + 1;
        end

        R_BOT: begin                                  // arista inferior
          if (cx == xb) begin
            cx <= xa;  cy <= ya + 1;
            st <= (yb <= ya + 1) ? R_DONE : R_LEFT;
          end else cx <= cx + 1;
        end

        R_LEFT: begin                                 // arista izquierda
          if (cy == yb - 1) begin
            cy <= ya + 1;  cx <= xb;
            st <= (xb == xa) ? R_DONE : R_RIGHT;
          end else cy <= cy + 1;
        end

        R_RIGHT: begin                                // arista derecha
          if (cy == yb - 1) st <= R_DONE;
          else              cy <= cy + 1;
        end

        R_DONE:  st <= R_IDLE;
        default: st <= R_IDLE;
      endcase
    end
  end

  assign busy     = (st != R_IDLE);
  assign done     = (st == R_DONE);
  assign px_valid = (st == R_FILL) || (st == R_TOP) || (st == R_BOT)
                 || (st == R_LEFT) || (st == R_RIGHT);
  assign px_x     = cx;
  assign px_y     = cy;
endmodule