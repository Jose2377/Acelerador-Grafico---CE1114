module draw_pixel #(
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,
  input  logic signed [15:0]      x0, y0,
  input  logic [PIXEL_BITS-1:0]   color_in,
  output logic                    busy,
  output logic                    done,      // pulso de un ciclo
  output logic                    px_valid,
  output logic signed [15:0]      px_x, px_y,
  output logic [PIXEL_BITS-1:0]   px_color
);

  typedef enum logic [1:0] {P_IDLE, P_OUT, P_DONE} pst_e;
  pst_e st;

  logic signed [15:0]    x, y;
  logic [PIXEL_BITS-1:0] col;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= P_IDLE;
      x <= '0;  y <= '0;  col <= '0;
    end else begin
      case (st)
        P_IDLE: if (start) begin
          x <= x0;  y <= y0;  col <= color_in;
          st <= P_OUT;
        end

        P_OUT:   st <= P_DONE;
        P_DONE:  st <= P_IDLE;
        default: st <= P_IDLE;
      endcase
    end
  end

  assign busy     = (st != P_IDLE);
  assign done     = (st == P_DONE);
  assign px_valid = (st == P_OUT);
  assign px_x     = x;
  assign px_y     = y;
  assign px_color = col;

endmodule
