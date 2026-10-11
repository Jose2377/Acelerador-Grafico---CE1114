module line_buffer #(
  parameter int LINES  = 4,
  parameter int WIDTH  = 64,
  parameter int DATA_W = 16
)(
  input  logic clk,

  // Escritura, desde el motor de prebusqueda
  input  logic                     wr_ena,
  input  logic [$clog2(LINES)-1:0] wr_line,
  input  logic [$clog2(WIDTH)-1:0] wr_x,
  input  logic [DATA_W-1:0]        data_in,

  // Lectura, desde el barrido; la salida llega un ciclo despues
  input  logic [$clog2(LINES)-1:0] rd_line,
  input  logic [$clog2(WIDTH)-1:0] rd_x,
  output logic [DATA_W-1:0]        data_out
);

  logic [DATA_W-1:0] mem [0:LINES*WIDTH-1];

  always_ff @(posedge clk) begin
    if (wr_ena) mem[wr_line * WIDTH + wr_x] <= data_in;
    data_out <= mem[rd_line * WIDTH + rd_x];
  end

endmodule
