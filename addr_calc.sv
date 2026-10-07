module addr_calc #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic [$clog2(SCREEN_W)-1:0]            x,
  input  logic [$clog2(SCREEN_H)-1:0]            y,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0]   addr
);

  assign addr = (y * SCREEN_W) + x;

endmodule
