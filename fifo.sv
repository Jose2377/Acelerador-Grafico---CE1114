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

  // Aceptar y extraer son las dos condiciones de las que depende todo lo
  // demas; nombrarlas evita repetir la misma conjuncion en cada bloque.
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
  // La profundidad tiene que ser potencia de dos: los punteros dan la vuelta
  // solos y no hay comparacion contra DEPTH en el camino critico.
  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH - 1)) != 0)) begin
      $error("fifo: DEPTH (%0d) debe ser una potencia de dos mayor o igual a 2",
             DEPTH);
    end
  end
`endif

endmodule
