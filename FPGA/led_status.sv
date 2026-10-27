`timescale 1ns / 1ps

//=============================================================================
// led_status.sv
// Modulo : Indicador de estado sobre los diez LED rojos de la DE1-SoC
//
//
//   LEDR[0]    Señal de refresco. Cambia de estado cada CUADROS_PARPADEO flancos de VSYNC,
//              de modo que con 60 cuadros por segundo y el valor por defecto (30) parpadea a 1 Hz.
//              Un cambio por cuadro (30 Hz) se veria como un LED a media luz
//              y no permitiria distinguir un barrido detenido de uno vivo.
//   LEDR[1]    Error detectado. Se enciende con cada error y se mantiene MS_DESTELLO ms, recargandose si llegan mas.
//   LEDR[2]    Buffer delantero: 0 = A, 1 = B
//   LEDR[3]    Señal del sistema (latido): cambia cada MS_LATIDO ms; distingue un sistema colgado de uno en espera
//   LEDR[6:4]  Ocupacion de la cola, como barra:
//                000 vacia, 001 menos de la mitad, 011 de la mitad en adelante, 111 llena
//   LEDR[9:7]  Modo activo:
//                000 MOE-01 Inicio, 001 MOE-02 Espera, 010 MOE-03 Procesamiento,
//                011 MOE-04 Swap Buffer, 100 MOE-05 Informe, 111 MOE-06 Error
//
// En los dos campos de tres bits el LED de numero menor es el bit menos significativo:
// la barra crece desde LEDR[4] y el codigo 001 enciende LEDR[7].
//
// MOE-06 dura un solo ciclo en decoder_fsm, de modo que sin alargarlo no se veria nunca.
// Los LED de modo muestran 111 durante el mismo destello que el LED de error y despues vuelven a seguir al modo real.
//
// Entradas
//   clk, rst_n   Reloj del sistema y reinicio
//   modo         Modo del sistema (codificacion sys_state_e del paquete)
//   err_tick     Señal: se registro un error
//   fifo_level   Comandos en la cola
//   fifo_full    La cola esta llena
//   buffer_sel   Buffer delantero, 0 es A y 1 es B
//   vsync        VSYNC ya sincronizado al dominio del sistema
//
// Salidas
//   leds         Los diez LED rojos de la placa, con el reparto de arriba
//=============================================================================
module led_status #(
  parameter int SYS_CLK_HZ       = 100_000_000,
  parameter int FIFO_DEPTH       = 16,
  parameter int MS_DESTELLO      = 120,   // Duracion del destello de error
  parameter int MS_LATIDO        = 500,   // Semiperiodo del latido
  parameter int CUADROS_PARPADEO = 30     // Cuadros por cambio del LED de refresco
)(
  input  logic                          clk,
  input  logic                          rst_n,

  input  logic [2:0]                    modo,
  input  logic                          err_tick,
  input  logic [$clog2(FIFO_DEPTH):0]   fifo_level,
  input  logic                          fifo_full,
  input  logic                          buffer_sel,
  input  logic                          vsync,

  output logic [9:0]                    leds
);

  localparam int CICLOS_DESTELLO = (SYS_CLK_HZ / 1000) * MS_DESTELLO;
  localparam int CICLOS_LATIDO   = (SYS_CLK_HZ / 1000) * MS_LATIDO;
  localparam int DW              = $clog2(CICLOS_DESTELLO + 1);
  localparam int LW              = $clog2(CICLOS_LATIDO + 1);
  localparam int FW              = $clog2(CUADROS_PARPADEO + 1);
  localparam int NW              = $clog2(FIFO_DEPTH) + 1;

  // Alargador del error. Se recarga con cada suceso,
  // de modo que una racha mantiene el LED encendido en vez de parpadear mas rapido de lo que el ojo resuelve.
  logic [DW-1:0] cnt_err;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            cnt_err <= '0;
    else if (err_tick)     cnt_err <= DW'(CICLOS_DESTELLO);
    else if (cnt_err != 0) cnt_err <= cnt_err - 1'b1;
  end

  // Latido del reloj del sistema
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

  // Señal de refresco: cuenta flancos de subida de VSYNC
  logic          vsync_q;
  logic [FW-1:0] cnt_cuadros;
  logic          refresco;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vsync_q     <= 1'b0;
      cnt_cuadros <= '0;
      refresco    <= 1'b0;
    end else begin
      vsync_q <= vsync;
      if (vsync && !vsync_q) begin
        if (cnt_cuadros == FW'(CUADROS_PARPADEO - 1)) begin
          cnt_cuadros <= '0;
          refresco    <= ~refresco;
        end else begin
          cnt_cuadros <= cnt_cuadros + 1'b1;
        end
      end
    end
  end

  // Barra de ocupacion de la cola
  logic [2:0] barra;

  always_comb begin
    if (fifo_full)                                barra = 3'b111;
    else if (fifo_level == '0)                    barra = 3'b000;
    else if (fifo_level < NW'(FIFO_DEPTH / 2))    barra = 3'b001;
    else                                          barra = 3'b011;
  end

  // Codigo de modo de la tabla. MOE-06 se mantiene mientras dure el destello.
  logic [2:0] codigo_modo;

  always_comb begin
    if ((modo == Acelerador_pkg::MOE_ERROR) || (cnt_err != 0))
      codigo_modo = 3'b111;                                 // MOE-06
    else if (modo == Acelerador_pkg::MOE_WAIT)
      codigo_modo = 3'b010;                                 // Subestado de MOE-03
    else
      codigo_modo = modo;                                   // MOE-01 a MOE-05: 000 a 100
  end

  // Reparto final
  always_comb begin
    leds[0]   = refresco;
    leds[1]   = (cnt_err != 0);
    leds[2]   = buffer_sel;
    leds[3]   = latido;
    leds[6:4] = barra;
    leds[9:7] = codigo_modo;
  end

endmodule
