module sync2 #(
  parameter bit VALOR_RESET = 1'b0
)(
  input  logic clk_dst,
  input  logic rst_n,
  input  logic data_in,      // dominio de origen
  output logic data_out      // dominio de clk_dst
);

  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  logic meta, estable;

  always_ff @(posedge clk_dst or negedge rst_n) begin
    if (!rst_n) begin
      meta    <= VALOR_RESET;
      estable <= VALOR_RESET;
    end else begin
      meta    <= data_in;
      estable <= meta;
    end
  end

  assign data_out = estable;

endmodule
