`timescale 1ns / 1ps

//=============================================================================
// fifo.sv
// Modulo : Cola de comandos sincrona  (registro COMAND_FIFO_W)
//
// Guarda los comandos de 168 bits que el nivel superior ensambla a partir de los paquetes de 24 bytes,
// y los entrega al decodificador en el mismo orden en que llegaron. 
//
// Desacopla la velocidad a la que el HPS escribe comandos de la velocidad a la que el rasterizador los consume: 
// sin ella el software tendria que esperar a que cada figura terminara antes de mandar la siguiente.
//
// Un solo dominio de reloj (el de rasterizado)
//
// Puntos a tener en cuenta al usarla:
//
//   - La lectura esta registrada: data_out aparece un ciclo despues de
//     rd_ena, acompanado de data_out_valid. La maquina de estados del
//     decodificador cuenta con ese ciclo de retardo.
//
//   - Una escritura con la cola llena no se encola ni sobreescribe nada:
//     se pierde, drop sube un ciclo y drop_count lo registra. 
//		 Es el origen del error EC-08. 
//     Descartar el comando nuevo y no el mas antiguo es deliberado,
//		 porque el mas antiguo puede estar ya a punto de salir.
//
//   - drop_count satura en lugar de dar la vuelta,
//     Para que una racha larga de descartes no acabe mostrando una cuenta pequena.
//
//   - flush la vacia por completo; lo activa el nivel superior durante MOE-01.
//
//   - level necesita un bit mas que los punteros para poder valer DEPTH, que es la condicion de lleno.
//
// DEPTH debe ser potencia de dos: asi los punteros dan la vuelta solos al
// desbordar y no hace falta comparar contra DEPTH en el camino critico. 
// La comprobacion del final del archivo lo verifica en simulacion.
//
// Entradas:
//   clk, rst_n       Reloj del sistema y reinicio
//   flush            Vacia la cola de inmediato y pone los punteros a cero
//   wr_ena, data_in  Escritura de un paquete de comando, Permiso y dato
//   rd_ena           Lectura de un paquete, Permiso
//
// Salidas:
//   data_out         Paquete de lectura 
//   data_out_valid   Si data_out es valido
//   full, empty      Si la cola esta llena o vacia
//   level            Cantidad de paquetes almacenados
//   drop             Aviso de intento de escritura con cola llena
//   drop_count       Cantidad de descartes por desborde.
//=============================================================================
module fifo #(
  parameter int DATA_W = 168,
  parameter int DEPTH  = 16
)(
  input  logic                clk,            // Relog del sistema
  input  logic                rst_n,          // Reset del sistema
  input  logic                flush,          // Señal para Vacio de la cola de inmediato y poner los punteros a cero

  // Escritura
  input  logic                wr_ena,			 // Permiso de escritura
  input  logic [DATA_W-1:0]   data_in,        // Paquete de escritura

  // Lectura
  input  logic                rd_ena,         // Permiso de lectura
  output logic [DATA_W-1:0]   data_out,       // Paquete de lectura 
  output logic                data_out_valid, // Si data_out es valido

  // Estado
  output logic                full,           // Cola esta llena
  output logic                empty,          // Cola esta vacia
  output logic [$clog2(DEPTH):0] level,       // Cantidad de paquetes almacenados
  output logic                drop,           // Aviso de intento de escritura con cola llena
  output logic [15:0]         drop_count      // Cantidad de descartes por desborde.
);

  localparam int PW = $clog2(DEPTH);// Bits de puntero

  // El nivel necesita un bit mas que el puntero para poder valer DEPTH.
  localparam logic [PW:0] NIVEL_MAX = (PW + 1)'(DEPTH);

  // Memoria y punteros
  logic [DATA_W-1:0] mem [0:DEPTH-1];
  logic [PW-1:0]     wr_ptr, rd_ptr;

  // Escritura y lectura
  logic escritura, lectura;
  assign escritura = wr_ena && !full;
  assign lectura = rd_ena && !empty;

  // Señales de llenado, vacio y desborde
  assign full  = (level == NIVEL_MAX);
  assign empty = (level == '0);
  assign drop  = wr_ena && full;

  // Escritura de memoria en caso de permiso de escritura
  always_ff @(posedge clk) begin
    if (escritura) mem[wr_ptr] <= data_in;
  end

  // Punteros
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin // Reset
      wr_ptr <= '0;
      rd_ptr <= '0;
      level  <= '0;
    end else if (flush) begin // Flush
      wr_ptr <= '0;
      rd_ptr <= '0;
      level  <= '0;
    end else begin // Avance en los punteros, en caso de escritura y/o lectura
      if (escritura) wr_ptr <= wr_ptr + 1'b1;
      if (lectura) rd_ptr <= rd_ptr + 1'b1;

      case ({escritura, lectura}) // Aumentar o disminuir el nivel de llenado, en caso de escritura o lectura, respectivamente.
        2'b10:   level <= level + 1'b1;
        2'b01:   level <= level - 1'b1;
        default: level <= level;
      endcase
    end
  end

  // Lectura de memoria en caso de permiso de lectura
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin // Reset
      data_out       <= '0;
      data_out_valid <= 1'b0;
    end else if (flush) begin // Flush
      data_out_valid <= 1'b0;
    end else begin // Lee el valor de memoria.
      data_out_valid <= lectura;
      if (lectura) data_out <= mem[rd_ptr];
    end
  end

  // Contador de descartes
  // Satura en lugar de dar la vuelta
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                       drop_count <= '0; //Reset
    else if (flush)                   drop_count <= '0; //Flush
    else if (drop && !(&drop_count)) drop_count <= drop_count + 16'd1; // Suma en caso de drop y no esta lleno.
  end

`ifndef SYNTHESIS
  // La profundidad tiene que ser potencia de dos.
  // Los punteros dan la vuelta solos y no hay comparacion contra DEPTH en el camino critico.
  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH - 1)) != 0)) begin
      $error("fifo: DEPTH (%0d) debe ser una potencia de dos mayor o igual a 2",
             DEPTH);
    end
  end
`endif

endmodule
