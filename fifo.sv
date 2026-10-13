//=============================================================================
// fifo.sv
// Modulo : Cola de comandos sincrona  (registro COMAND_FIFO_W)
//
// Guarda los comandos de 168 bits que el nivel superior ensambla a partir de
// los paquetes de 24 bytes, y los entrega al decodificador en el mismo orden
// en que llegaron. Desacopla la velocidad a la que el HPS escribe comandos
// de la velocidad a la que el rasterizador los consume: sin ella el software
// tendria que esperar a que cada figura terminara antes de mandar la
// siguiente.
//
// Un solo dominio de reloj (el de rasterizado)
//
// Puntos a tener en cuenta al usarla:
//
//   - La lectura esta registrada: data_out aparece un ciclo despues de
//     rd_ena, acompanado de data_out_valid. La maquina de estados del
//     decodificador cuenta con ese ciclo de retardo.
//
//   - Una escritura con la cola llena no se encola ni sobreescribe nada: se
//     pierde, drop sube un ciclo y drop_count lo registra. Es el origen del
//     error EC-08. Descartar el comando nuevo y no el mas antiguo es
//     deliberado, porque el mas antiguo puede estar ya a punto de salir.
//
//   - drop_count satura en lugar de dar la vuelta, para que una racha larga
//     de descartes no acabe mostrando una cuenta pequena.
//
//   - flush la vacia por completo; lo activa el nivel superior durante
//     MOE-01.
//
//   - level necesita un bit mas que los punteros para poder valer DEPTH, que
//     es la condicion de lleno.
//
// DEPTH debe ser potencia de dos: asi los punteros dan la vuelta solos al
// desbordar y no hace falta comparar contra DEPTH en el camino critico. La
// comprobacion del final del archivo lo verifica en simulacion.
//=============================================================================
module fifo #(
  parameter int DATA_W = 168,
  parameter int DEPTH  = 16
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                flush,

  // Escritura
  input  logic                wr_ena,
  input  logic [DATA_W-1:0]   data_in,

  // Lectura
  input  logic                rd_ena,
  output logic [DATA_W-1:0]   data_out,
  output logic                data_out_valid,

  // Estado
  output logic                full,
  output logic                empty,
  output logic [$clog2(DEPTH):0] level,
  output logic                drop,
  output logic [15:0]         drop_count
);

  localparam int PW = $clog2(DEPTH);// bits de puntero

  // El nivel necesita un bit mas que el puntero para poder valer DEPTH.
  localparam logic [PW:0] NIVEL_MAX = (PW + 1)'(DEPTH);

  logic [DATA_W-1:0] mem [0:DEPTH-1];
  logic [PW-1:0]     wr_ptr, rd_ptr;

  // Escritura y lectura
  logic escritura, lectura;
  assign escritura = wr_ena && !full;
  assign lectura = rd_ena && !empty;

  assign full  = (level == NIVEL_MAX);
  assign empty = (level == '0);
  assign drop  = wr_ena && full;

  // Memoria
  always_ff @(posedge clk) begin
    if (escritura) mem[wr_ptr] <= data_in;
  end

  // Punteros
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      level  <= '0;
    end else if (flush) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      level  <= '0;
    end else begin
      if (escritura) wr_ptr <= wr_ptr + 1'b1;
      if (lectura) rd_ptr <= rd_ptr + 1'b1;

      case ({escritura, lectura})
        2'b10:   level <= level + 1'b1;
        2'b01:   level <= level - 1'b1;
        default: level <= level;
      endcase
    end
  end

  // Salida
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_out       <= '0;
      data_out_valid <= 1'b0;
    end else if (flush) begin
      data_out_valid <= 1'b0;
    end else begin
      data_out_valid <= lectura;
      if (lectura) data_out <= mem[rd_ptr];
    end
  end

  // Contador de descartes
  // Satura en lugar de dar la vuelta
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                       drop_count <= '0;
    else if (flush)                   drop_count <= '0;
    else if (drop && !(&drop_count)) drop_count <= drop_count + 16'd1;
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
