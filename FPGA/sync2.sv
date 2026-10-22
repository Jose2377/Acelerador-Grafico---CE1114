`timescale 1ns / 1ps

//=============================================================================
// sync2.sv
// Modulo : Sincronizador de dos biestables para cruce de dominios de reloj
//
// Pasa una senal de un bit de un dominio de reloj a otro. Los dos biestables
// en cadena dan tiempo a que una captura metaestable se resuelva antes de
// que el valor alcance la logica del destino: el primero puede quedar en un
// estado indefinido, el segundo entrega ya un nivel limpio.
//
// Solo vale para senales de un bit o para buses cuyos bits cambian de uno en
// uno (codigo Gray). Un bus binario cualquiera necesita otro mecanismo,
// porque sus bits pueden cruzar en ciclos distintos; por eso async_fifo pasa
// sus punteros en Gray y no por aqui.
//
// En el sistema se usa dos veces: buffer_sel hacia el dominio de pixel y
// VSYNC de vuelta hacia el de rasterizado.
//
// El atributo de Altera marca la cadena para que el analizador de tiempos la
// reconozca y no intente cerrar camino entre los dos dominios.
//
// Entradas
//   clk_dst    reloj del dominio de destino
//   rst_n      reinicio asincrono activo en bajo, del dominio de destino
//   data_in    senal de un bit procedente del dominio de origen
//
// Salidas
//   data_out   la misma senal, ya estable y alineada a clk_dst, dos ciclos despues
//=============================================================================
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
