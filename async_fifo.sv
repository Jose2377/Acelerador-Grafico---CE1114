//=============================================================================
// async_fifo.sv
// Modulo : Cola asincrona entre dos dominios de reloj
//
// Pasa datos del dominio de rasterizado (100 MHz) al de pixel y al contrario,
// sin ninguna relacion de fase entre los dos relojes. El gestor de
// framebuffer la instancia dos veces: una para las direcciones que el
// barrido de video pide y otra para los pixeles que vuelven.
//
// El problema de una cola asincrona no son los datos, que viven en una
// memoria y se leen cuando ya estan estables, sino los punteros: cada lado
// necesita conocer el puntero del otro para decidir si esta lleno o vacio, y
// un contador binario cambia varios bits a la vez. Si esos bits se capturan
// en flancos distintos, el valor leido puede ser uno que nunca existio y la
// cola se creeria vacia estando llena.
//
// La solucion es el codigo Gray: entre dos valores consecutivos cambia un
// solo bit, de modo que una captura a medias devuelve o el valor anterior o
// el nuevo, los dos seguros. Cada puntero se convierte a Gray, cruza por una
// cadena de dos biestables y se compara ya en el dominio destino.
//
// Los punteros llevan un bit mas de los que necesita la memoria. Ese bit
// extra es lo que distingue la cola llena de la vacia cuando los dos
// punteros apuntan a la misma posicion: si coinciden del todo esta vacia; si
// coinciden salvo en los dos bits altos del Gray, el de escritura ha dado una
// vuelta mas y esta llena.
//
// La salida es show-ahead: data_out ya muestra el primer elemento sin pedir
// nada, y rd_ena solo avanza el puntero.
//
// Conservadora por construccion: full puede quedarse alto un poco mas de lo
// necesario y empty tambien, porque los punteros cruzados llegan con dos
// ciclos de retraso. Nunca al contrario, que es lo que importa.
//=============================================================================
module async_fifo #(
  parameter int DATA_W = 16,
  parameter int DEPTH  = 16          // Potencia de 2
)(
  // Dominio de escritura
  input  logic                wr_clk,
  input  logic                wr_rst_n,
  input  logic                wr_ena,
  input  logic [DATA_W-1:0]   data_in,
  output logic                full,

  // Dominio de lectura
  input  logic                rd_clk,
  input  logic                rd_rst_n,
  input  logic                rd_ena,
  output logic [DATA_W-1:0]   data_out,
  output logic                empty
);

  localparam int PW = $clog2(DEPTH);

  logic [DATA_W-1:0] mem [0:DEPTH-1];

  // Un bit mas que el puntero para distinguir lleno de vacio: cuando los
  // punteros coinciden salvo en el bit alto, la cola esta llena.
  logic [PW:0] wr_bin, rd_bin;
  logic [PW:0] wr_gray, rd_gray;
  logic [PW:0] wr_gray_s1, wr_gray_s2;    // en el dominio de lectura
  logic [PW:0] rd_gray_s1, rd_gray_s2;    // en el dominio de escritura

  function automatic logic [PW:0] a_gray(input logic [PW:0] b);
    a_gray = b ^ (b >> 1);
  endfunction

  // Lado de escritura
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_bin  <= '0;
      wr_gray <= '0;
    end else if (wr_ena && !full) begin
      wr_bin  <= wr_bin + 1'b1;
      wr_gray <= a_gray(wr_bin + 1'b1);
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_ena && !full) mem[wr_bin[PW-1:0]] <= data_in;
  end

  // El puntero de lectura llega sincronizado con dos biestables.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      rd_gray_s1 <= '0;
      rd_gray_s2 <= '0;
    end else begin
      rd_gray_s1 <= rd_gray;
      rd_gray_s2 <= rd_gray_s1;
    end
  end

  // Lleno: Los dos punteros apuntan a la misma posicion pero con los dos bits altos invertidos. 
  // Significando que el de escritura ha dado una vuelta mas.
  assign full = (wr_gray == {~rd_gray_s2[PW:PW-1], rd_gray_s2[PW-2:0]});

  // Lado de lectura
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_bin  <= '0;
      rd_gray <= '0;
    end else if (rd_ena && !empty) begin
      rd_bin  <= rd_bin + 1'b1;
      rd_gray <= a_gray(rd_bin + 1'b1);
    end
  end

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      wr_gray_s1 <= '0;
      wr_gray_s2 <= '0;
    end else begin
      wr_gray_s1 <= wr_gray;
      wr_gray_s2 <= wr_gray_s1;
    end
  end

  assign empty = (rd_gray == wr_gray_s2);

  // Show-ahead: lectura combinacional de la posicion apuntada.
  assign data_out = mem[rd_bin[PW-1:0]];

`ifndef SYNTHESIS
  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH - 1)) != 0))
      $error("async_fifo: DEPTH (%0d) debe ser potencia de dos", DEPTH);
  end
`endif

endmodule
