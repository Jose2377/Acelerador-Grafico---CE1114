`timescale 1ns / 1ps

//=============================================================================
// avalon_reg_file.sv
// Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
// Modulo   : Banco de registros Avalon-MM esclavo, cara visible del HPS
//
// Este modulo es lo unico que el HPS toca. Detras del puente ligero
// (h2f_lw_axi_master, base 0xFF20_0000) traduce lecturas y escrituras de
// 32 bits en los puertos sueltos que Acelerador_Grafico_Top ya expone.
//
// Platform Designer no genera este modulo: la IP del HPS entrega el maestro,
// pero el mapa de registros del proyecto es propio y hay que escribirlo.
//
// Mapa de registros (desplazamientos en bytes desde la base del puente)
//
//   0x00  ID          R   constante 0xACE1_1140, confirma que el puente vive
//   0x04  CONTROL     RW  [0] enable     nivel, queda puesto
//                         [1] soft_reset pulso de un ciclo, se autolimpia
//   0x08  STATUS      R   [0]     busy
//                         [3:1]   modo (MOE)
//                         [4]     fifo_full
//                         [5]     fifo_empty
//                         [6]     overflow
//                         [7]     vga_underrun
//                         [15:8]  fifo_level
//                         [31:16] seq_last
//   0x0C  CMD_FIFO_W  W   una palabra del paquete; seis escrituras
//                         consecutivas (W0 a W5) encolan un comando
//   0x10  ERR_INFO    R   [3:0] err_last, [31:16] err_count
//   0x14  PERF_CYCLES R
//   0x18  PERF_CMDS   R
//   0x1C  PERF_PIXELS R
//   0x20  PERF_DROP   R
//   0x24  CLIP_COUNT  R
//   0x28  BURST_WR    R
//   0x2C  BURST_RD    R
//   0x30  PIXELS_WR   R
//   0x34  OUT_RANGE   R
//   0x38  VGA_FRAMES  R
//   0x3C  LEDS        R   copia del indicador de estado, para depurar
//
// Protocolo. Esclavo Avalon-MM de 32 bits, sin waitrequest (nunca bloquea)
// y con readLatency = 1: readdata es valido el ciclo siguiente a read. Esos
// dos valores son los que hay que declarar en Platform Designer si algun dia
// este modulo se empaqueta como componente.
//
// avs_address llega en BYTES, como lo entrega el maestro exportado del
// Avalon-MM Pipeline Bridge. Los dos bits bajos se descartan y el indice de
// palabra es avs_address[5:2]. Si en su lugar se conecta un maestro declarado
// en palabras, hay que quitar ese desplazamiento.
//
// La escritura a CMD_FIFO_W es la razon de que esto no pueda ser un PIO del
// catalogo: comand_w_ena tiene que durar exactamente un ciclo, porque el
// ensamblador del nivel superior cuenta palabras con el. Un PIO deja un
// registro en alto y encolaria la misma palabra seis veces.
//=============================================================================
module avalon_reg_file #(
  parameter int FIFO_DEPTH = Acelerador_pkg::FIFO_DEPTH,
  parameter int LVL_BITS   = $clog2(FIFO_DEPTH) + 1
)(
  // Reloj y reset del dominio del sistema. En la placa es el mismo que
  // alimenta h2f_lw_axi_clk, de modo que no hay cruce de dominio aqui.
  input  logic        clk,
  input  logic        rst_n,

  //--------------------------------------------------- Avalon-MM esclavo
  input  logic [5:0]  avs_address,      // bytes, 64 posiciones
  input  logic        avs_read,
  input  logic        avs_write,
  input  logic [31:0] avs_writedata,
  output logic [31:0] avs_readdata,

  //------------------------------- Hacia Acelerador_Grafico_Top (salidas)
  output logic        enable,
  output logic        reset_soft,
  output logic        comand_w_ena,
  output logic [31:0] comand_w_data,

  //----------------------------- Desde Acelerador_Grafico_Top (entradas)
  input  logic              busy,
  input  logic [2:0]        modo,
  input  logic [LVL_BITS-1:0] fifo_level,
  input  logic              fifo_full,
  input  logic              fifo_empty,
  input  logic              overflow,
  input  logic [3:0]        err_last,
  input  logic [15:0]       err_count,
  input  logic [31:0]       perf_cycles,
  input  logic [31:0]       perf_commands,
  input  logic [31:0]       perf_pixels,
  input  logic [31:0]       perf_dropped,
  input  logic [15:0]       seq_last,
  input  logic [31:0]       clip_count,
  input  logic [31:0]       burst_writes,
  input  logic [31:0]       burst_reads,
  input  logic [31:0]       pixels_written,
  input  logic [31:0]       out_of_range,
  input  logic [31:0]       vga_frames,
  input  logic              vga_underrun,
  input  logic [9:0]        leds
);

  localparam logic [31:0] ID_MAGIC = 32'hACE1_1140;

  // Indice de palabra dentro del bloque de 16 registros.
  logic [3:0] idx;
  assign idx = avs_address[5:2];

  localparam logic [3:0] R_ID          = 4'h0;
  localparam logic [3:0] R_CONTROL     = 4'h1;
  localparam logic [3:0] R_STATUS      = 4'h2;
  localparam logic [3:0] R_CMD_FIFO_W  = 4'h3;
  localparam logic [3:0] R_ERR_INFO    = 4'h4;
  localparam logic [3:0] R_PERF_CYCLES = 4'h5;
  localparam logic [3:0] R_PERF_CMDS   = 4'h6;
  localparam logic [3:0] R_PERF_PIXELS = 4'h7;
  localparam logic [3:0] R_PERF_DROP   = 4'h8;
  localparam logic [3:0] R_CLIP_COUNT  = 4'h9;
  localparam logic [3:0] R_BURST_WR    = 4'hA;
  localparam logic [3:0] R_BURST_RD    = 4'hB;
  localparam logic [3:0] R_PIXELS_WR   = 4'hC;
  localparam logic [3:0] R_OUT_RANGE   = 4'hD;
  localparam logic [3:0] R_VGA_FRAMES  = 4'hE;
  localparam logic [3:0] R_LEDS        = 4'hF;

  //------------------------------------------------------------- Escritura
  // enable es un nivel que persiste. soft_reset es un pulso de un ciclo: el
  // nivel superior lo usa para vaciar el ensamblador de paquete y avisar al
  // decodificador, y dejarlo en alto mantendria el sistema detenido.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable     <= 1'b0;
      reset_soft <= 1'b0;
    end else begin
      reset_soft <= 1'b0;                      // se autolimpia cada ciclo
      if (avs_write && (idx == R_CONTROL)) begin
        enable     <= avs_writedata[0];
        reset_soft <= avs_writedata[1];
      end
    end
  end

  // Palabra del paquete. Se pasa combinacional junto con el pulso para que
  // el ensamblador del nivel superior la capture en el mismo flanco en que
  // ve comand_w_ena, igual que hace el banco de pruebas.
  assign comand_w_ena  = avs_write && (idx == R_CMD_FIFO_W);
  assign comand_w_data = avs_writedata;

  //-------------------------------------------------------------- Lectura
  // readLatency = 1. El multiplexor se registra, de modo que la ruta critica
  // no atraviesa el interconnect del puente.
  logic [31:0] status_word, err_word;

  assign status_word = {seq_last,                        // [31:16]
                        {(8-LVL_BITS){1'b0}}, fifo_level,// [15:8]
                        vga_underrun,                    // [7]
                        overflow,                        // [6]
                        fifo_empty,                      // [5]
                        fifo_full,                       // [4]
                        modo,                            // [3:1]
                        busy};                           // [0]

  assign err_word = {err_count, 12'd0, err_last};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      avs_readdata <= '0;
    end else if (avs_read) begin
      case (idx)
        R_ID          : avs_readdata <= ID_MAGIC;
        R_CONTROL     : avs_readdata <= {30'd0, 1'b0, enable};
        R_STATUS      : avs_readdata <= status_word;
        R_ERR_INFO    : avs_readdata <= err_word;
        R_PERF_CYCLES : avs_readdata <= perf_cycles;
        R_PERF_CMDS   : avs_readdata <= perf_commands;
        R_PERF_PIXELS : avs_readdata <= perf_pixels;
        R_PERF_DROP   : avs_readdata <= perf_dropped;
        R_CLIP_COUNT  : avs_readdata <= clip_count;
        R_BURST_WR    : avs_readdata <= burst_writes;
        R_BURST_RD    : avs_readdata <= burst_reads;
        R_PIXELS_WR   : avs_readdata <= pixels_written;
        R_OUT_RANGE   : avs_readdata <= out_of_range;
        R_VGA_FRAMES  : avs_readdata <= vga_frames;
        R_LEDS        : avs_readdata <= {22'd0, leds};
        default       : avs_readdata <= 32'd0;
      endcase
    end
  end

endmodule
