module draw_line (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               start,
  input  logic signed [15:0] x0_i, y0_i, x1_i, y1_i,
  output logic               busy,
  output logic               done,      // pulso de un ciclo
  output logic               px_valid,
  output logic signed [15:0] px_x, px_y
);

  typedef enum logic [1:0] {L_IDLE, L_SETUP, L_RUN, L_DONE} lst_e;
  lst_e st;

  logic signed [15:0] x, y, xe, ye, sx, sy;
  logic signed [21:0] dx, dy, err;

  always_ff @(posedge clk or negedge rst_n) begin : p_line
    logic signed [22:0] e2;
    logic signed [21:0] err_n;
    logic signed [15:0] x_n, y_n;

    if (!rst_n) begin
      st <= L_IDLE;
      x <= '0; y <= '0; xe <= '0; ye <= '0; sx <= '0; sy <= '0;
      dx <= '0; dy <= '0; err <= '0;
    end else begin
      case (st)
        L_IDLE: if (start) begin
          x  <= x0_i;  y  <= y0_i;
          xe <= x1_i;  ye <= y1_i;
          dx <= (x1_i > x0_i) ?  (22'(x1_i) - 22'(x0_i)) : (22'(x0_i) - 22'(x1_i));
          dy <= (y1_i > y0_i) ? -(22'(y1_i) - 22'(y0_i)) : -(22'(y0_i) - 22'(y1_i));
          sx <= (x0_i < x1_i) ? 1 : -1;
          sy <= (y0_i < y1_i) ? 1 : -1;
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
endmodule