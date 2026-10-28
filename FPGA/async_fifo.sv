`timescale 1ns / 1ps

//=============================================================================
// async_fifo.sv
// Modulo : Cola asincrona entre dos dominios de reloj
//
// Pasa datos del dominio de rasterizado (100 MHz) al de pixel y al contrario,
// sin ninguna relacion de fase entre los dos relojes. 
// El gestor de framebuffer la instancia dos veces: 
// una para las direcciones que el barrido de video pide y otra para los pixeles que vuelven.
//
// El problema de una cola asincrona no son los datos, 
// que viven en una memoria y se leen cuando ya estan estables, sino los punteros: 
// cada lado necesita conocer el puntero del otro para decidir si esta lleno o vacio, 
// y un contador binario cambia varios bits a la vez. 
// Si esos bits se capturan en flancos distintos, 
// el valor leido puede ser uno que nunca existio 
// y la cola se creeria vacia estando llena.
//
// La solucion es el codigo Gray: entre dos valores consecutivos cambia un solo bit, 
// de modo que una captura a medias devuelve o el valor anterior o el nuevo, los dos seguros. 
// Cada puntero se convierte a Gray, cruza por una cadena de dos biestables y se compara ya en el dominio destino.
//
// Los punteros llevan un bit mas de los que necesita la memoria. 
// Ese bit extra es lo que distingue la cola llena de la vacia cuando los dos punteros apuntan a la misma posicion: 
// si coinciden del todo esta vacia; si coinciden salvo en los dos bits altos del Gray, 
// el de escritura ha dado una vuelta mas y esta llena.
//
// La salida es show-ahead: data_out ya muestra el primer elemento sin pedir nada, y rd_ena solo avanza el puntero.
//
// Conservadora por construccion: full puede quedarse alto un poco mas de lo necesario y empty tambien, 
// porque los punteros cruzados llegan con dos ciclos de retraso.
// Nunca al contrario, que es lo que importa.
//
// Entradas
//   wr_clk, wr_rst_n   Reloj y reinicio del dominio de escritura
//   wr_ena, data_in    Escritura de un dato en el dominio de escritura
//   rd_clk, rd_rst_n   Reloj y reinicio del dominio de lectura
//   rd_ena             Extraccion de un dato en el dominio de lectura
//
// Salidas
//   full               No caben mas datos; visto desde el dominio de escritura
//   data_out           Dato en la cabeza, visto desde el dominio de lectura
//   empty              No hay datos que leer
//=============================================================================
module async_fifo #(
  parameter int DATA_W = 16,
  parameter int DEPTH  = 16          // Potencia de 2
)(
  // Dominio de escritura
  input  logic                wr_clk,   // Reloj del dominio de escritura
  input  logic                wr_rst_n, // Reinicio del dominio de escritura
  input  logic                wr_ena,   // Permiso de escritura de un dato en el dominio de escritura
  input  logic [DATA_W-1:0]   data_in,  // Dato a escribir en el dominio de escritura
  output logic                full,     // No caben mas datos; visto desde el dominio de escritura

  // Dominio de lectura
  input  logic                rd_clk,   // Reloj del dominio de lectura
  input  logic                rd_rst_n, // Reinicio del dominio de lectura
  input  logic                rd_ena,   // Permiso de lectura de un dato en el dominio de lectura
  output logic [DATA_W-1:0]   data_out, // Dato en la cabeza, visto desde el dominio de lectura
  output logic                empty     // No hay datos que leer
);

  localparam int PW = $clog2(DEPTH);  // Tamaño de puntero
  logic [DATA_W-1:0] mem [0:DEPTH-1]; // Memoria

  // Un bit mas que el puntero para distinguir lleno de vacio: 
  // cuando los punteros coinciden salvo en el bit alto, la cola esta llena.
  logic [PW:0] wr_bin, rd_bin;            // Lectura y escritura en binario
  logic [PW:0] wr_gray, rd_gray;          // Lectura y escritura en gray
  logic [PW:0] wr_gray_s1, wr_gray_s2;    // Multiples variables para metaestabilidad
  logic [PW:0] rd_gray_s1, rd_gray_s2;    // Multiples variables para metaestabilidad

  // Funcion para cambiar a codigo gray
  function automatic logic [PW:0] a_gray(input logic [PW:0] b);
    a_gray = b ^ (b >> 1);
  endfunction

  // Lado de escritura
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin // Reset de escritura
      wr_bin  <= '0;
      wr_gray <= '0;
    end else if (wr_ena && !full) begin // Permiso de escritura
      wr_bin  <= wr_bin + 1'b1;
      wr_gray <= a_gray(wr_bin + 1'b1);
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_ena && !full) mem[wr_bin[PW-1:0]] <= data_in; // Escritura en memoria
  end

  // El puntero de lectura llega sincronizado con dos biestables.
  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin // Reset
      rd_gray_s1 <= '0;
      rd_gray_s2 <= '0;
    end else begin // Metaestabilidad
      rd_gray_s1 <= rd_gray;
      rd_gray_s2 <= rd_gray_s1;
    end
  end

  // Lleno: Los dos punteros apuntan a la misma posicion pero con los dos bits altos invertidos. 
  // Significando que el de escritura ha dado una vuelta mas.
  assign full = (wr_gray == {~rd_gray_s2[PW:PW-1], rd_gray_s2[PW-2:0]});

  // Lado de lectura
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin // Reset
      rd_bin  <= '0;
      rd_gray <= '0;
    end else if (rd_ena && !empty) begin // Permiso de lectura
      rd_bin  <= rd_bin + 1'b1;
      rd_gray <= a_gray(rd_bin + 1'b1);
    end
  end
 
  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin // Reset
      wr_gray_s1 <= '0;
      wr_gray_s2 <= '0;
    end else begin // Metaestabilidad
      wr_gray_s1 <= wr_gray;
      wr_gray_s2 <= wr_gray_s1;
    end
  end

  // Verifica si esta vacio
  assign empty = (rd_gray == wr_gray_s2);

  // Lectura
  // Show-ahead: lectura combinacional de la posicion apuntada.
  assign data_out = mem[rd_bin[PW-1:0]]; 

`ifndef SYNTHESIS
  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH - 1)) != 0))
      $error("async_fifo: DEPTH (%0d) debe ser potencia de dos", DEPTH);
  end
`endif

endmodule
