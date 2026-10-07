module pixel_gen #(
  parameter int SCREEN_W   = 64,
  parameter int SCREEN_H   = 48,
  parameter int PIXEL_BITS = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    clr_cnt,

  // Flujo
  input  logic                    valid_in,
  input  logic signed [15:0]      x_in, y_in,
  input  logic [PIXEL_BITS-1:0]   color_in,

  // Solicitud
  output logic                    px_valid,
  output logic [$clog2(SCREEN_W)-1:0] px_x,
  output logic [$clog2(SCREEN_H)-1:0] px_y,
  output logic [PIXEL_BITS-1:0]   px_color,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0] px_addr,

  // Instrumentacion
  output logic [31:0]             pix_count,
  output logic [31:0]             clip_count
);

  logic fuera;

  clip_scissor #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_clip (
    .valid_in(valid_in), .x_in(x_in), .y_in(y_in),
    .valid_out(px_valid), .x_out(px_x), .y_out(px_y), .fuera(fuera));

  addr_calc #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_addr (
    .x(px_x), .y(px_y), .addr(px_addr));

  assign px_color = color_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pix_count  <= '0;
      clip_count <= '0;
    end else if (clr_cnt) begin
      pix_count  <= '0;
      clip_count <= '0;
    end else begin
      if (px_valid) pix_count  <= pix_count  + 32'd1;
      if (fuera)    clip_count <= clip_count + 32'd1;
    end
  end

endmodule
