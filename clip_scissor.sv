module clip_scissor #(
  parameter int SCREEN_W = 64,
  parameter int SCREEN_H = 48
)(
  input  logic               valid_in,
  input  logic signed [15:0] x_in, y_in,
  output logic               valid_out,
  output logic [$clog2(SCREEN_W)-1:0] x_out,
  output logic [$clog2(SCREEN_H)-1:0] y_out,
  output logic               fuera
);

  logic dentro;

  assign dentro  = (x_in >= 0) && (x_in < SCREEN_W)
                && (y_in >= 0) && (y_in < SCREEN_H);

  assign valid_out = valid_in &&  dentro;
  assign fuera   = valid_in && !dentro;

  assign x_out = x_in[$clog2(SCREEN_W)-1:0];
  assign y_out = y_in[$clog2(SCREEN_H)-1:0];

endmodule
