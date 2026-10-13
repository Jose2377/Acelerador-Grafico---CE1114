//=============================================================================
// line_buffer.sv
// Modulo : Memoria de lineas entre la prebusqueda y el barrido de video
//
// Guarda LINES lineas de pantalla para desacoplar el barrido de la latencia
// de la memoria. El motor de prebusqueda del controlador VGA va llenando
// ranuras por delante mientras el barrido consume la que esta mostrando: sin
// este margen cada pixel tendria que esperar su rafaga y la imagen se
// cortaria con cada espera de la SDRAM.
//
// Las ranuras se indexan por los bits bajos del numero de linea, lo que
// convierte el buffer en circular sin ningun resto ni comparacion; por eso
// LINES debe ser potencia de dos.
//
// Doble puerto simple: una escritura y una lectura por ciclo en el mismo
// bloque always_ff. Es la plantilla que infiere un M10K de la FPGA. La
// lectura queda registrada, de modo que el dato aparece un ciclo despues de
// presentar la direccion; el controlador VGA compensa ese ciclo retrasando
// igual las senales de sincronizacion.
//=============================================================================
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
