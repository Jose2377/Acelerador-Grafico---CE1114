module draw_circle #(
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,
  input  logic                    fill,
  input  logic signed [15:0]      cx_in, cy_in,
  input  logic        [9:0]       r_in,
  input  logic [PIXEL_BITS-1:0]   color_in,
  output logic                    busy,
  output logic                    done,
  output logic                    px_valid,
  output logic signed [15:0]      px_x, px_y,
  output logic [PIXEL_BITS-1:0]   px_color
);
  typedef enum logic [2:0] {K_IDLE, K_SETUP, K_OUT, K_UPD, K_FILL, K_DONE} kst_e;
  kst_e st;

  logic signed [15:0] cx, cy, rr, x, y, dx, dy;
  logic signed [21:0] err, r2, dx2, dy2;
  logic        [2:0]  oct;
  logic signed [15:0] ox, oy;
  logic [PIXEL_BITS-1:0] col;

  always_comb begin
    case (oct)
      3'd0:    begin ox = cx + x; oy = cy + y; end
      3'd1:    begin ox = cx + y; oy = cy + x; end
      3'd2:    begin ox = cx - y; oy = cy + x; end
      3'd3:    begin ox = cx - x; oy = cy + y; end
      3'd4:    begin ox = cx - x; oy = cy - y; end
      3'd5:    begin ox = cx - y; oy = cy - x; end
      3'd6:    begin ox = cx + y; oy = cy - x; end
      default: begin ox = cx + x; oy = cy - y; end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin : p_circ
    logic signed [21:0] err_n;
    logic signed [15:0] x_n, y_n;

    if (!rst_n) begin
      st <= K_IDLE;
      cx <= '0; cy <= '0; rr <= '0; x <= '0; y <= '0; oct <= '0;
      dx <= '0; dy <= '0; err <= '0; r2 <= '0; dx2 <= '0; dy2 <= '0;
      col <= '0;
    end else begin
      case (st)
        K_IDLE: if (start) begin
          cx <= cx_in;  cy <= cy_in;  rr <= 16'(r_in);
          col <= color_in;
          st <= K_SETUP;
        end

        K_SETUP: begin
          if (fill) begin
            r2  <= 22'(rr) * 22'(rr);
            dx2 <= 22'(rr) * 22'(rr);
            dy2 <= 22'(rr) * 22'(rr);
            dx  <= -rr;  dy <= -rr;
            st  <= K_FILL;
          end else begin
            x <= rr;  y <= '0;  err <= '0;  oct <= '0;
            st <= K_OUT;
          end
        end

        K_OUT: begin                        // ocho octantes, uno por ciclo
          if (oct == 3'd7) begin oct <= '0; st <= K_UPD; end
          else                   oct <= oct + 1'b1;
        end

        K_UPD: begin
          err_n = err;  x_n = x;  y_n = y;
          if (err_n <= 0) begin
            y_n   = y_n + 1;
            err_n = err_n + 22'(y_n) + 22'(y_n) + 1;    // err += 2*y + 1
          end
          if (err_n > 0) begin
            x_n   = x_n - 1;
            err_n = err_n - 22'(x_n) - 22'(x_n) - 1;    // err -= 2*x + 1
          end
          err <= err_n;  x <= x_n;  y <= y_n;
          st  <= (x_n < y_n) ? K_DONE : K_OUT;
        end

        K_FILL: begin
          if (dx == rr) begin
            dx <= -rr;  dx2 <= r2;
            if (dy == rr) st <= K_DONE;
            else begin
              dy2 <= dy2 + 22'(dy) + 22'(dy) + 1;       // dy2 += 2*dy + 1
              dy  <= dy + 1;
            end
          end else begin
            dx2 <= dx2 + 22'(dx) + 22'(dx) + 1;         // dx2 += 2*dx + 1
            dx  <= dx + 1;
          end
        end

        K_DONE:  st <= K_IDLE;
        default: st <= K_IDLE;
      endcase
    end
  end

  assign busy = (st != K_IDLE);
  assign done = (st == K_DONE);

  always_comb begin
    px_valid = 1'b0;  px_x = '0;  px_y = '0;  px_color = col;
    if (st == K_OUT) begin
      px_valid = 1'b1;       px_x = ox;       px_y = oy;
    end else if (st == K_FILL) begin
      px_valid = ((dx2 + dy2) <= r2);
      px_x     = cx + dx;    px_y = cy + dy;
    end
  end
endmodule
