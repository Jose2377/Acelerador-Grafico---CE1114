`timescale 1ns / 1ps
//=============================================================================
// tb_avalon_reg_file.sv
// Banco de pruebas del banco de registros Avalon-MM
//
// Comprueba los campos de CONTROL (enable, reset_soft, perf_window, irq_en y
// las banderas de interrupcion W1C) y el empaquetado de STATUS y ERR_INFO.
// No instancia el acelerador: las entradas de estado las acciona el banco.
//=============================================================================
module tb_avalon_reg_file;

  localparam int FD = 256;
  localparam int LB = $clog2(FD) + 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [5:0]  avs_address = '0;
  logic        avs_read = 1'b0, avs_write = 1'b0;
  logic [31:0] avs_writedata = '0, avs_readdata;

  logic enable, reset_soft, perf_window, irq, comand_w_ena;
  logic [31:0] comand_w_data;

  logic          busy = 0, fifo_full = 0, fifo_empty = 1, overflow = 0;
  logic [2:0]    modo = 3'd1;
  logic [LB-1:0] fifo_level = '0;
  logic          buffer_sel = 0, evt_inf = 0, evt_err = 0;
  logic [3:0]    err_last = 4'd7;
  logic [15:0]   err_count = 16'd3, seq_last = 16'h1234;
  logic          vga_underrun = 0;

  avalon_reg_file #(.FIFO_DEPTH(FD)) dut (
    .clk(clk), .rst_n(rst_n),
    .avs_address(avs_address), .avs_read(avs_read), .avs_write(avs_write),
    .avs_writedata(avs_writedata), .avs_readdata(avs_readdata),
    .enable(enable), .reset_soft(reset_soft), .perf_window(perf_window), .irq(irq),
    .comand_w_ena(comand_w_ena), .comand_w_data(comand_w_data),
    .busy(busy), .modo(modo), .fifo_level(fifo_level), .fifo_full(fifo_full),
    .fifo_empty(fifo_empty), .overflow(overflow),
    .buffer_sel(buffer_sel), .evt_inf(evt_inf), .evt_err(evt_err),
    .err_last(err_last), .err_count(err_count),
    .perf_cycles('0), .perf_commands('0), .perf_pixels('0), .perf_dropped('0),
    .seq_last(seq_last), .clip_count('0), .burst_writes('0), .burst_reads('0),
    .pixels_written('0), .out_of_range('0), .vga_frames('0),
    .vga_underrun(vga_underrun), .leds('0));

  int errores = 0;
  task automatic chk(input string n, input longint got, input longint exp);
    if (got === exp) $display("  [OK  ] %-46s = 0x%0h", n, got);
    else begin $display("  [FALLA] %-46s = 0x%0h (esperado 0x%0h)", n, got, exp); errores++; end
  endtask

  task automatic wr(input logic [5:0] a, input logic [31:0] d);
    avs_address = a; avs_writedata = d; avs_write = 1'b1;
    @(negedge clk); avs_write = 1'b0;
  endtask

  task automatic rd(input logic [5:0] a, output logic [31:0] d);
    avs_address = a; avs_read = 1'b1;
    @(negedge clk); avs_read = 1'b0; d = avs_readdata;
  endtask

  task automatic pulso(ref logic s);
    s = 1'b1; @(negedge clk); s = 1'b0;
  endtask

  logic [31:0] d;
  int pulsos_pw, pulsos_rs;
  always @(posedge clk) begin
    if (perf_window) pulsos_pw++;
    if (reset_soft)  pulsos_rs++;
  end

  initial begin
    pulsos_pw = 0; pulsos_rs = 0;
    repeat (3) @(negedge clk); rst_n = 1'b1; @(negedge clk);

    $display("--- CONTROL ---");
    rd(6'h04, d); chk("CONTROL tras el reinicio", d, 0);
    chk("irq en bajo tras el reinicio", irq, 0);

    wr(6'h04, 32'h1);
    chk("enable queda puesto", enable, 1);
    wr(6'h04, 32'h1 | 32'h4);            // enable + perf_window
    chk("perf_window sube tras la escritura", perf_window, 1);
    @(negedge clk);
    chk("perf_window dura un ciclo", perf_window, 0);
    chk("perf_window genero un solo pulso", pulsos_pw, 1);
    chk("enable sigue puesto", enable, 1);
    rd(6'h04, d); chk("perf_window se lee como 0", d[2], 0);
    wr(6'h04, 32'h1 | 32'h2);            // enable + reset_soft
    @(negedge clk);
    chk("reset_soft genero un solo pulso", pulsos_rs, 1);

    $display("--- Interrupcion ---");
    pulso(evt_inf);
    rd(6'h04, d); chk("evt_inf marca irq_inf aunque irq_en este en 0", d[4], 1);
    chk("sin irq_en no hay interrupcion", irq, 0);
    wr(6'h04, 32'h1 | 32'h8);            // enable + irq_en
    chk("irq_en con pendiente levanta irq", irq, 1);
    wr(6'h04, 32'h1 | 32'h8);            // escribir sin bit 4 no limpia
    chk("escribir CONTROL sin W1C no limpia", irq, 1);
    wr(6'h04, 32'h1 | 32'h8 | 32'h10);   // W1C irq_inf
    chk("W1C limpia irq_inf", irq, 0);
    rd(6'h04, d); chk("CONTROL = enable | irq_en", d, 32'h9);
    pulso(evt_err);
    rd(6'h04, d); chk("evt_err marca irq_err", d[5], 1);
    chk("irq_err levanta irq", irq, 1);
    wr(6'h04, 32'h1 | 32'h20);           // W1C irq_err y baja irq_en
    rd(6'h04, d); chk("W1C limpia irq_err e irq_en baja", d, 32'h1);
    // Evento y limpieza en el mismo ciclo: gana el evento
    avs_address = 6'h04; avs_writedata = 32'h9 | 32'h10; avs_write = 1'b1; evt_inf = 1'b1;
    @(negedge clk); avs_write = 1'b0; evt_inf = 1'b0;
    rd(6'h04, d); chk("evento simultaneo a la limpieza no se pierde", d[4], 1);

    $display("--- STATUS y ERR_INFO ---");
    buffer_sel = 1'b1; @(negedge clk);
    rd(6'h08, d); chk("STATUS.buffer_sel (bit 7) en 1", d[7], 1);
    chk("STATUS.modo", d[3:1], 1);
    chk("STATUS.seq_last", d[31:16], 16'h1234);
    buffer_sel = 1'b0; @(negedge clk);
    rd(6'h08, d); chk("STATUS.buffer_sel (bit 7) en 0", d[7], 0);
    vga_underrun = 1'b1; @(negedge clk);
    rd(6'h10, d); chk("ERR_INFO.err_last", d[3:0], 7);
    chk("ERR_INFO.vga_underrun (bit 4)", d[4], 1);
    chk("ERR_INFO.err_count", d[31:16], 3);

    $display("");
    if (errores == 0) $display(" RESULTADO: todas las comprobaciones pasaron");
    else              $display(" RESULTADO: %0d comprobacion(es) fallaron", errores);
    $finish;
  end
endmodule
