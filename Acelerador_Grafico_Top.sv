module Acelerador_Grafico_Top #(
  parameter int SCREEN_W   = Acelerador_pkg::SCREEN_W,
  parameter int SCREEN_H   = Acelerador_pkg::SCREEN_H,
  parameter int PIXEL_BITS = Acelerador_pkg::PIXEL_BITS,
  parameter int FIFO_DEPTH = Acelerador_pkg::FIFO_DEPTH
)(
  input  logic               clk,
  input  logic               rst_n,

  // Registro CONTROL (0x04)
  input  logic               enable,
  input  logic               reset_soft,

  // Puerto COMAND_FIFO_W (0x0C)
  // Las seis palabras del paquete, escritas en orden W0 a W5.
  input  logic               comand_w_ena,
  input  logic        [31:0] comand_w_data,

  // Video
  input  logic               vsync,

  // Solicitud de pixel
  output logic               px_valid,
  output logic [$clog2(SCREEN_W)-1:0] px_x,
  output logic [$clog2(SCREEN_H)-1:0] px_y,
  output logic [PIXEL_BITS-1:0]       px_color,
  output logic [$clog2(SCREEN_W*SCREEN_H)-1:0] px_addr,
  output logic               buffer_sel,

  // Registro STATUS (0x08)
  output logic               busy,
  output logic        [2:0]  modo,
  output logic [$clog2(FIFO_DEPTH):0] fifo_level,
  output logic               fifo_full,
  output logic               fifo_empty,
  output logic               overflow,

  // Registro ERR_INFO (0x10)
  output logic        [3:0]  err_last,
  output logic        [15:0] err_count,

  // Registros de rendimiento (0x14 a 0x20)
  output logic        [31:0] perf_cycles,
  output logic        [31:0] perf_commands,
  output logic        [31:0] perf_pixels,
  output logic        [31:0] perf_dropped,

  // Auxiliares
  output logic        [15:0] seq_last,
  output logic        [31:0] clip_count
);

  // Ensamblador de las seis palabras del paquete
  logic [2:0]  palabra;                 // 0 a 5
  logic [31:0] w [0:5];
  logic        comand_push;
  logic [Acelerador_pkg::COMAND_BITS-1:0] comand_data_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      palabra <= '0;
      for (int i = 0; i < 6; i++) w[i] <= '0;
    end else if (reset_soft) begin
      palabra <= '0;
    end else if (comand_w_ena) begin
      w[palabra] <= comand_w_data;
      if (palabra == 3'd5) palabra <= '0;
      else                 palabra <= palabra + 3'd1;
    end
  end

  assign comand_push = comand_w_ena && (palabra == 3'd5);

  assign comand_data_in = {
    w[0][31:24],            // OPCODE
    w[0][23:16],            // FLAGS
    w[0][15:0],             // SEQ_ID
    w[1][31:16], w[1][15:0],// x0, y0
    w[2][31:16], w[2][15:0],// x1, y1
    w[3][31:16], w[3][15:0],// x2, y2
    w[4][23:16],            // R
    w[4][15:8],             // G
    w[4][7:0],              // B
    comand_w_data[15:0]     // PARAM, desde el puerto
  };

  // FIFO
  logic        fifo_rd, fifo_data_out_valid, fifo_drop;
  logic [Acelerador_pkg::COMAND_BITS-1:0] fifo_data_out;
  logic [15:0] drop_count;
  logic        init_flush;

  fifo #(.DATA_W(Acelerador_pkg::COMAND_BITS), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk(clk), .rst_n(rst_n), .flush(init_flush),
    .wr_ena(comand_push), .data_in(comand_data_in),
    .rd_ena(fifo_rd), .data_out(fifo_data_out), .data_out_valid(fifo_data_out_valid),
    .full(fifo_full), .empty(fifo_empty), .level(fifo_level),
    .drop(fifo_drop), .drop_count(drop_count));

  // MOE-01 vacia la cola.
  assign init_flush = (modo == Acelerador_pkg::MOE_INIT);
  assign overflow = (drop_count != 16'd0);

  // Decodificador y maquina de estados del sistema
  logic        ras_start, ras_busy, ras_done;
  logic [3:0]  ras_op;
  logic signed [15:0] ras_x0, ras_y0, ras_x1, ras_y1, ras_x2, ras_y2;
  logic [9:0]  ras_radius;
  logic [7:0]  ras_r, ras_g, ras_b;
  logic        perf_latch, perf_clear, comand_tick;
  logic [31:0] comand_count;

  decoder_fsm #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H)) u_decoder (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .soft_reset(reset_soft),
    .fifo_empty(fifo_empty), .fifo_data_out(fifo_data_out),
    .fifo_data_out_valid(fifo_data_out_valid), .fifo_drop(fifo_drop),
    .fifo_rd(fifo_rd),
    .ras_start(ras_start), .ras_op(ras_op),
    .ras_x0(ras_x0), .ras_y0(ras_y0), .ras_x1(ras_x1), .ras_y1(ras_y1),
    .ras_x2(ras_x2), .ras_y2(ras_y2), .ras_radius(ras_radius),
    .ras_r(ras_r), .ras_g(ras_g), .ras_b(ras_b),
    .ras_busy(ras_busy), .ras_done(ras_done),
    .vsync(vsync), .buffer_sel(buffer_sel),
    .perf_latch(perf_latch), .perf_clear(perf_clear),
    .modo(modo), .busy(busy),
    .err_last(err_last), .err_count(err_count),
    .comand_count(comand_count), .comand_tick(comand_tick), .seq_last(seq_last));

  // Procesador de comandos y rasterizador 2D
  logic [31:0] pix_count;

  processor_raster #(.SCREEN_W(SCREEN_W), .SCREEN_H(SCREEN_H),
                     .PIXEL_BITS(PIXEL_BITS)) u_raster (
    .clk(clk), .rst_n(rst_n),
    .start(ras_start), .op(ras_op),
    .x0(ras_x0), .y0(ras_y0), .x1(ras_x1), .y1(ras_y1),
    .x2(ras_x2), .y2(ras_y2), .radius(ras_radius),
    .color_r(ras_r), .color_g(ras_g), .color_b(ras_b),
    .clr_cnt(perf_clear),
    .busy(ras_busy), .done(ras_done),
    .px_valid(px_valid), .px_x(px_x), .px_y(px_y),
    .px_color(px_color), .px_addr(px_addr),
    .pix_count(pix_count), .clip_count(clip_count));

  // Medidor de rendimiento
  //
  // La ventana se abre al salir de MOE-01 o tras cada INF, y se cierra cuando el decodificador decodifica INF.
  // Los registros publicados se conservan hasta el siguiente informe, el HPS puede leerlos sin prisa.

  logic [31:0] ciclos, comandos, descartes;
  logic        ventana_reset;

  assign ventana_reset = perf_clear || (modo == Acelerador_pkg::MOE_INIT);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ciclos        <= '0;
      comandos      <= '0;
      descartes     <= '0;
      perf_cycles   <= '0;
      perf_commands <= '0;
      perf_pixels   <= '0;
      perf_dropped  <= '0;
    end else begin
      if (perf_latch) begin
        // Foto de la ventana que se cierra.
        perf_cycles   <= ciclos;
        perf_commands <= comandos;
        perf_pixels   <= pix_count;
        perf_dropped  <= descartes;
      end

      if (ventana_reset)   ciclos <= '0;
      else if (enable)     ciclos <= ciclos + 32'd1;

      if (ventana_reset)   comandos <= '0;
      else if (comand_tick)   comandos <= comandos + 32'd1;

      if (ventana_reset)   descartes <= '0;
      else if (fifo_drop)  descartes <= descartes + 32'd1;
    end
  end

endmodule
