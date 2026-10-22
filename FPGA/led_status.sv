`timescale 1ns / 1ps

// Reparto de los diez LED de la DE1-SoC:
//
//   LEDR[2:0]  modo del sistema, MOE-01 a MOE-06 en binario
//   LEDR[3]    ocupado
//   LEDR[4]    error reciente             (alargado)
//   LEDR[5]    desbordamiento de la cola  (alargado)
//   LEDR[6]    buffer delantero: 0 es A, 1 es B
//   LEDR[7]    cola de comandos llena     (alargado)
//   LEDR[8]    el barrido se quedo sin datos
//   LEDR[9]    latido, indica que el reloj del sistema vive
//
// El latido no es decorativo: distingue un sistema detenido de un sistema en reposo
//
// Entradas
//   clk, rst_n   reloj del sistema y reinicio asincrono activo en bajo
//   modo         modo del sistema, MOE-01 a MOE-06; sale por LEDR[2:0]
//   busy         hay trabajo en curso
//   err_tick     pulso: se registro un error; se alarga para que se vea
//   overflow     nivel: hubo descartes en la ventana de medicion
//   fifo_full    nivel: la cola de comandos esta llena ahora
//   buffer_sel   buffer delantero, 0 es A y 1 es B
//   underrun     nivel pegajoso del controlador VGA: el barrido se quedo sin datos
//
// Salidas
//   leds         los diez LED rojos de la placa, con el reparto de arriba

module led_status #(
  parameter int SYS_CLK_HZ = 100_000_000,
  // Duracion del destello de un suceso instantaneo.
  parameter int MS_DESTELLO = 120,
  // Periodo del latido, en milisegundos.
  parameter int MS_LATIDO   = 500
)(
  input  logic       clk,
  input  logic       rst_n,

  input  logic [2:0] modo,
  input  logic       busy,
  input  logic       err_tick,       // Pulso: se registro un error
  input  logic       overflow,       // Nivel: hubo descartes en la ventana
  input  logic       fifo_full,      // Nivel: la cola esta llena ahora
  input  logic       buffer_sel,
  input  logic       underrun,       // Nivel pegajoso del controlador VGA

  output logic [9:0] leds
);

  localparam int CICLOS_DESTELLO = (SYS_CLK_HZ / 1000) * MS_DESTELLO;
  localparam int CICLOS_LATIDO   = (SYS_CLK_HZ / 1000) * MS_LATIDO;
  localparam int DW              = $clog2(CICLOS_DESTELLO + 1);
  localparam int LW              = $clog2(CICLOS_LATIDO + 1);

  // Alargador de pulsos
  // Tres instancias de la misma cuenta atras. Se recarga con cada suceso,
  // de modo que una racha mantiene el LED encendido en vez de parpadear a
  // una frecuencia que el ojo no resuelve.
  logic [DW-1:0] cnt_err, cnt_ovf, cnt_full;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_err  <= '0;
      cnt_ovf  <= '0;
      cnt_full <= '0;
    end else begin
      if (err_tick)           cnt_err  <= DW'(CICLOS_DESTELLO);
      else if (cnt_err  != 0) cnt_err  <= cnt_err - 1'b1;

      if (overflow)           cnt_ovf  <= DW'(CICLOS_DESTELLO);
      else if (cnt_ovf  != 0) cnt_ovf  <= cnt_ovf - 1'b1;

      if (fifo_full)          cnt_full <= DW'(CICLOS_DESTELLO);
      else if (cnt_full != 0) cnt_full <= cnt_full - 1'b1;
    end
  end

  // Latido
  logic [LW-1:0] cnt_latido;
  logic          latido;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt_latido <= '0;
      latido     <= 1'b0;
    end else if (cnt_latido == LW'(CICLOS_LATIDO - 1)) begin
      cnt_latido <= '0;
      latido     <= ~latido;
    end else begin
      cnt_latido <= cnt_latido + 1'b1;
    end
  end

  // Reparto final
  always_comb begin
    leds        = '0;
    leds[2:0]   = modo;
    leds[3]     = busy;
    leds[4]     = (cnt_err  != 0);
    leds[5]     = (cnt_ovf  != 0);
    leds[6]     = buffer_sel;
    leds[7]     = (cnt_full != 0);
    leds[8]     = underrun;
    leds[9]     = latido;
  end

endmodule
