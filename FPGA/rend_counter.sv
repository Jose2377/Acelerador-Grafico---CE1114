`timescale 1ns / 1ps

// El diseno distingue dos magnitudes.
//
// Tiempo de rasterizacion: 
// Ciclos desde que el decodificador extrae un comando de la cola hasta que ese comando queda completado. 
// Es lo que caracteriza al acelerador y lo que mide este modulo, con precision de un ciclo.
//
// Tiempo de extremo a extremo: lo mide el sistema de usuario e incluye la red, las llamadas al sistema y la latencia del puente.
// No es observable desde aqui.
//
// perf_cycles no cuenta los ciclos de reloj transcurridos sino los ciclos en que hubo un comando en vuelo.

// La ventana se abre al salir de MOE-01 y tras cada INF, y se cierra cuando el decodificador decodifica INF. 
// Al cerrarse se toma una foto que los registros conservan hasta el siguiente informe, 
// de modo que el HPS pueda leer los cuatro valores sin carrera y sin prisa.
//
// Entradas
//   clk, rst_n       Reloj de rasterizado y reinicio
//   latch            Señal para cerrar la ventana y tomar la foto de los cuatro valores
//   ventana_reset    Señal para abrir una ventana de medicion nueva
//   rasterizando     hay un comando en vuelo; es lo que cuenta perf_cycles
//   comand_tick      Señal que avisa que un comando mas fue completado
//   px_n             Pixeles aceptados por el gestor de framebuffer en este ciclo
//                    (hasta BURST_LEN cuando el rectangulo relleno entrega un tramo)
//   drop_tick        Señal que avisa que un paquete mas fue descartado por la cola
//
// Salidas
//   ciclos, comandos, pixeles, descartes                    Valores en curso de la ventana abierta, para observacion
//   perf_cycles, perf_commands, perf_pixels, perf_dropped   La foto de la ultima ventana cerrada, 
//                                                           que leen los registros PERF_* del mapa

module rend_counter (
  input  logic clk,
  input  logic rst_n,

  // Cierre y apertura de la ventana. 
  // latch llega un ciclo antes que ventana_reset.
  // La foto se toma sobre la ventana cerrada y el reinicio ocurre despues.
  
  input  logic        latch,            // Señal: INF decodificado
  input  logic        ventana_reset,    // Señal: abrir ventana nueva

  // Sucesos que se contabilizan
  input  logic        rasterizando,     // Hay un comando en vuelo
  input  logic        comand_tick,      // Un comando mas completado
  input  logic [3:0]  px_n,             // Pixeles aceptados por el gestor en este ciclo
  input  logic        drop_tick,        // Un paquete mas descartado por la cola

  // Valores en curso, para observacion
  output logic [31:0] ciclos,
  output logic [31:0] comandos,
  output logic [31:0] pixeles,
  output logic [31:0] descartes,

  // Registros publicados: PERF_CYCLES, PERF_COMMANDS, PERF_PIXELS,
  // PERF_DROPPED del mapa de registros
  output logic [31:0] perf_cycles,
  output logic [31:0] perf_commands,
  output logic [31:0] perf_pixels,
  output logic [31:0] perf_dropped
);

  // Los contadores saturan en lugar de dar la vuelta.
  function automatic logic [31:0] sumar(input logic [31:0] v, input logic inc);
    if (!inc)             sumar = v;
    else if (&v)          sumar = v;        // Ya saturado
    else                  sumar = v + 32'd1;
  endfunction

  // Suma de varios a la vez, tambien saturada
  function automatic logic [31:0] sumar_n(input logic [31:0] v, input logic [3:0] n);
    logic [32:0] t;
    t = {1'b0, v} + 33'(n);
    sumar_n = t[32] ? 32'hFFFF_FFFF : t[31:0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin // Reset
      ciclos        <= '0;
      comandos      <= '0;
      pixeles       <= '0;
      descartes     <= '0;
      perf_cycles   <= '0;
      perf_commands <= '0;
      perf_pixels   <= '0;
      perf_dropped  <= '0;
    end else begin
      if (latch) begin // Sube los resultados
        perf_cycles   <= ciclos;
        perf_commands <= comandos;
        perf_pixels   <= pixeles;
        perf_dropped  <= descartes;
      end

      if (ventana_reset) begin // Reinicia
        ciclos    <= '0;
        comandos  <= '0;
        pixeles   <= '0;
        descartes <= '0;
      end else begin // Caso contrario, suma valores
        ciclos    <= sumar(ciclos,    rasterizando);
        comandos  <= sumar(comandos,  comand_tick);
        pixeles   <= sumar_n(pixeles, px_n);
        descartes <= sumar(descartes, drop_tick);
      end
    end
  end

endmodule
