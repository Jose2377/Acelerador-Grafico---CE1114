`timescale 1ns / 1ps

//=============================================================================
// DE1_SoC_top_level.sv
// Proyecto : Unidad de aceleracion grafica 2D  -  ITCR CE-1114
// Modulo   : Nivel superior de placa
//
// Une las tres piezas del sistema:
//
//   soc_system              HPS, puente ligero HPS-FPGA, PLL, controlador de
//                           la SDRAM externa y los dos Avalon-MM Pipeline
//                           Bridge (mm_bridge_0 hacia los registros y
//                           mm_bridge_sdram hacia la SDRAM), generados por
//                           Platform Designer
//   avalon_reg_file         el mapa de registros que el HPS ve del acelerador
//   Acelerador_Grafico_Top  el acelerador completo, sin un solo cambio
//
// Camino de ida. El HPS escribe en 0xFF20_0000 + desplazamiento, el puente
// ligero entrega el acceso por avm_regs, avalon_reg_file lo traduce a los
// puertos sueltos del acelerador, y seis escrituras consecutivas a CMD_FIFO_W
// (0x0C) encolan un comando de 24 bytes.
//
// Camino de la imagen. El rasterizador escribe pixeles en el buffer trasero a
// traves de su maestro de rafaga, que aqui ya no habla con la memoria interna
// de la FPGA sino, a traves de mm_bridge_sdram, con la SDRAM de 64 MB de la
// placa (FB_ONCHIP en cero), y el barrido lee el buffer delantero y lo saca
// por el conversor de video.
//
// Resolucion. Acelerador_pkg sigue declarando 64 x 48, que es lo que usan los
// bancos de pruebas para correr rapido en ModelSim. Aqui se sobrescriben los
// parametros de la instancia con 640 x 480 y la tabla VESA real, que tambien
// viven en el paquete (VGA_H_VISIBLE y companeros), y la cola con sus 256
// comandos. Ni el paquete ni la simulacion cambian: el override es solo de
// esta instancia.
//
// Relojes. Los tres salen del mismo PLL dentro de soc_system, alimentado por
// el oscilador de 50 MHz de la placa:
//
//   clk_100_clk      100 MHz             dominio de HPS, SDRAM y rasterizado
//   pll_0_vga_clk    25.175 MHz          dominio de pixel
//   pll_0_sdram_clk  100 MHz, +2917 ps (ver Acelerador_Grafico.sdc)   solo hacia el pin DRAM_CLK
//
// Que los tres vengan del mismo PLL es lo que da dos garantias: el reloj que
// llega al chip de SDRAM tiene una relacion de fase conocida con el que usa su
// controlador, y avalon_reg_file comparte reloj con el puente ligero, de modo
// que no hay cruce de dominio en el camino de los registros, tal como asume
// la cabecera de avalon_reg_file.sv.
//
// SDRAM. El controlador es el de Platform Designer (sdram_controller_0), no
// uno propio. Su captura de lectura a 100 MHz no cierra en tiempo: es una
// violacion conocida y temporal que Acelerador_Grafico.sdc documenta, junto
// con la solucion prevista (un sdram_controller.sv propio y DRAM_CLK
// reenviado por un registro DDIO).
//
// Entradas
//   CLOCK_50          Oscilador de 50 MHz de la placa; alimenta el PLL de soc_system
//   KEY_N             Pulsadores, activos en bajo; KEY0 es el reinicio
//   DRAM_DQ           Bus de datos de la SDRAM (bidireccional)
//   HPS_DDR3_*        Bus de la DDR3 del HPS; parte es bidireccional
//   HPS_ENET_RX_CLK, HPS_ENET_RX_DV, HPS_ENET_RX_DATA, HPS_ENET_MDIO
//                     Recepcion y gestion del Ethernet del HPS (IF-03)
//   HPS_SD_CMD, HPS_SD_DATA
//                     MicroSD de arranque del HPS (bidireccionales)
//   HPS_UART_RX       Consola serial del HPS, entrada
//
// Salidas
//   LEDR              Indicador de estado del sistema
//   DRAM_ADDR, DRAM_BA, DRAM_CAS_N, DRAM_CKE, DRAM_CLK, DRAM_CS_N,
//   DRAM_LDQM, DRAM_RAS_N, DRAM_UDQM, DRAM_WE_N
//                     Control de la SDRAM externa donde vive el framebuffer
//   VGA_R, VGA_G, VGA_B, VGA_BLANK_N, VGA_CLK, VGA_HS, VGA_SYNC_N, VGA_VS
//                     Salida de video hacia el conversor de la placa
//   HPS_ENET_GTX_CLK, HPS_ENET_TX_EN, HPS_ENET_TX_DATA, HPS_ENET_MDC
//                     Transmision y gestion del Ethernet del HPS
//   HPS_SD_CLK        Reloj de la microSD
//   HPS_UART_TX       Consola serial del HPS, salida
//=============================================================================
module DE1_SoC_top_level (
  //------------------------------------------------------- Reloj y pulsadores
  input  logic        CLOCK_50,
  input  logic [3:0]  KEY_N,              // Activos en bajo. KEY0 = reinicio
  output logic [9:0]  LEDR,               // Indicador de estado del sistema

  //------------------------------------------- SDRAM externa del lado FPGA
  // IS42S16320D, 32M x 16. Aqui vive el framebuffer de doble buffer.
  output logic [12:0] DRAM_ADDR,
  output logic [1:0]  DRAM_BA,
  output logic        DRAM_CAS_N,
  output logic        DRAM_CKE,
  output logic        DRAM_CLK,
  output logic        DRAM_CS_N,
  inout  wire  [15:0] DRAM_DQ,
  output logic        DRAM_LDQM,
  output logic        DRAM_RAS_N,
  output logic        DRAM_UDQM,
  output logic        DRAM_WE_N,

  //------------------------------------------------------- Salida de video
  output logic [7:0]  VGA_R,
  output logic [7:0]  VGA_G,
  output logic [7:0]  VGA_B,
  output logic        VGA_BLANK_N,
  output logic        VGA_CLK,
  output logic        VGA_HS,
  output logic        VGA_SYNC_N,
  output logic        VGA_VS,

  //--------------------------------------------------------- HPS, DDR3 propia
  // No la usa el acelerador, pero es obligatoria: es donde corre Linux.
  output logic [14:0] HPS_DDR3_ADDR,
  output logic [2:0]  HPS_DDR3_BA,
  output logic        HPS_DDR3_CK_P,
  output logic        HPS_DDR3_CK_N,
  output logic        HPS_DDR3_CKE,
  output logic        HPS_DDR3_CS_N,
  output logic        HPS_DDR3_RAS_N,
  output logic        HPS_DDR3_CAS_N,
  output logic        HPS_DDR3_WE_N,
  output logic        HPS_DDR3_RESET_N,
  inout  wire  [31:0] HPS_DDR3_DQ,
  inout  wire  [3:0]  HPS_DDR3_DQS_P,
  inout  wire  [3:0]  HPS_DDR3_DQS_N,
  output logic        HPS_DDR3_ODT,
  output logic [3:0]  HPS_DDR3_DM,
  input  logic        HPS_DDR3_RZQ,

  //------------------------------------------------- HPS, Ethernet (IF-03)
  output logic        HPS_ENET_GTX_CLK,
  output logic        HPS_ENET_TX_EN,
  output logic [3:0]  HPS_ENET_TX_DATA,
  input  logic        HPS_ENET_RX_CLK,
  input  logic        HPS_ENET_RX_DV,
  input  logic [3:0]  HPS_ENET_RX_DATA,
  inout  wire         HPS_ENET_MDIO,
  output logic        HPS_ENET_MDC,

  //------------------------------------------------- HPS, microSD (arranque)
  output logic        HPS_SD_CLK,
  inout  wire         HPS_SD_CMD,
  inout  wire  [3:0]  HPS_SD_DATA,

  //------------------------------------------------- HPS, consola serial
  input  logic        HPS_UART_RX,
  output logic        HPS_UART_TX
);

  //===========================================================================
  // Configuracion de esta instancia
  //===========================================================================
  // La resolucion de placa sale de las constantes VESA del paquete, no de
  // SCREEN_W y SCREEN_H, que siguen valiendo 64 x 48 para la simulacion.
  localparam int SCREEN_W   = Acelerador_pkg::VGA_H_VISIBLE;      // 640
  localparam int SCREEN_H   = Acelerador_pkg::VGA_V_VISIBLE;      // 480

  localparam int PIXEL_BITS = Acelerador_pkg::PIXEL_BITS;         // 16, RGB565
  // La cola de 256 comandos que fija el documento de diseno. No se sube en
  // Acelerador_pkg porque los bancos de pruebas leen FIFO_DEPTH de ahi y
  // tendrian que encolar 256 comandos para provocar el desbordamiento de
  // EC-08, alargando la simulacion sin ganar nada.
  localparam int FIFO_DEPTH = 256;
  localparam int SD_AW      = Acelerador_pkg::SD_ADDR_BITS;       // 25, palabras
  localparam int BCW        = $clog2(Acelerador_pkg::BURST_LEN + 1);
  localparam int LVLW       = $clog2(FIFO_DEPTH) + 1;

  //===========================================================================
  // Relojes y reinicio
  //===========================================================================
  logic clk_sys;        // 100 MHz, del PLL de soc_system
  logic clk_pix;        // 25.175 MHz, dominio de pixel
  logic clk_sdram;      // 100 MHz desfasado, unicamente hacia el pin

  // KEY0 es el reinicio manual. El pulsador es activo en bajo y la entrada de
  // reinicio del PLL es activa en alto, de modo que se invierte aqui.
  logic reset_ext;
  assign reset_ext = ~KEY_N[0];

  // Reinicio de arranque. El PLL se instancio sin puerto locked, asi que en su
  // lugar se cuentan 1024 ciclos de cada reloj antes de soltar el reinicio. Si
  // el PLL todavia no entrega reloj la cuenta no avanza y el reinicio sigue
  // puesto, que es exactamente el comportamiento deseado.
  //
  // Se pone de forma asincrona con reset_ext y se suelta de forma sincrona en
  // cada dominio, que es la forma habitual de meter un reinicio externo.
  logic [9:0] cuenta_sys, cuenta_pix;
  logic       rst_n, rst_pix_n;

  always_ff @(posedge clk_sys or posedge reset_ext) begin
    if (reset_ext)             cuenta_sys <= '0;
    else if (cuenta_sys != '1) cuenta_sys <= cuenta_sys + 10'd1;
  end
  assign rst_n = (cuenta_sys == '1);

  always_ff @(posedge clk_pix or posedge reset_ext) begin
    if (reset_ext)             cuenta_pix <= '0;
    else if (cuenta_pix != '1) cuenta_pix <= cuenta_pix + 10'd1;
  end
  assign rst_pix_n = (cuenta_pix == '1);

  //===========================================================================
  // Avalon-MM del puente ligero hacia el banco de registros
  //===========================================================================
  // El maestro lo entrega mm_bridge_0 dentro de soc_system. avalon_reg_file no
  // bloquea nunca y responde con latencia fija de un ciclo, de modo que aqui
  // waitrequest va a cero y readdatavalid es simplemente read retrasado un
  // ciclo, que es cuando el multiplexor registrado del banco presenta el dato.
  logic        regs_read, regs_write;
  logic [5:0]  regs_address;
  logic [31:0] regs_writedata, regs_readdata;
  logic        regs_readdatavalid;

  always_ff @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) regs_readdatavalid <= 1'b0;
    else        regs_readdatavalid <= regs_read;
  end

  //===========================================================================
  // Avalon-MM de rafaga del acelerador hacia la SDRAM (via mm_bridge_sdram)
  //===========================================================================
  logic                  fb_read, fb_write;
  logic [SD_AW-1:0]      fb_address;        // Direccion en PALABRAS de 16 bits
  logic [BCW-1:0]        fb_burstcount;
  logic [PIXEL_BITS-1:0] fb_writedata;
  logic                  fb_waitrequest;
  logic [PIXEL_BITS-1:0] fb_readdata;
  logic                  fb_readdatavalid;

  //===========================================================================
  // Senales entre el banco de registros y el acelerador
  //===========================================================================
  logic              gfx_enable, gfx_reset_soft;
  logic              gfx_cmd_w_ena;
  logic [31:0]       gfx_cmd_w_data;

  logic              gfx_busy;
  logic [2:0]        gfx_modo;
  logic [LVLW-1:0]   gfx_fifo_level;
  logic              gfx_fifo_full, gfx_fifo_empty, gfx_overflow;
  logic [3:0]        gfx_err_last;
  logic [15:0]       gfx_err_count;
  logic [31:0]       gfx_perf_cycles, gfx_perf_commands;
  logic [31:0]       gfx_perf_pixels, gfx_perf_dropped;
  logic [15:0]       gfx_seq_last;
  logic [31:0]       gfx_clip_count;
  logic [31:0]       gfx_burst_writes, gfx_burst_reads;
  logic [31:0]       gfx_pixels_written, gfx_out_of_range;
  logic [31:0]       gfx_vga_frames;
  logic              gfx_vga_underrun;
  logic [9:0]        gfx_leds;

  //===========================================================================
  // Sistema generado en Platform Designer
  //===========================================================================
  soc_system u_soc (
    //-------------------------------------- Maestro del puente ligero
    .avm_regs_address       (regs_address),
    .avm_regs_read          (regs_read),
    .avm_regs_write         (regs_write),
    .avm_regs_writedata     (regs_writedata),
    .avm_regs_readdata      (regs_readdata),
    .avm_regs_readdatavalid (regs_readdatavalid),
    .avm_regs_waitrequest   (1'b0),          // el banco nunca bloquea
    // El puente los emite por ser un maestro Avalon-MM completo; el banco de
    // registros no los usa, porque el driver siempre accede en palabras de 32
    // bits y no hay rafagas sobre el mapa de registros.
    .avm_regs_burstcount    (),
    .avm_regs_byteenable    (),
    .avm_regs_debugaccess   (),

    //-------------------------------------- Esclavo de la SDRAM externa
    // El acelerador direcciona en palabras de 16 bits y Avalon-MM direcciona
    // en bytes, de modo que la conversion es un corrimiento de un bit.
    .avm_sdram_address      ({fb_address, 1'b0}),
    .avm_sdram_read         (fb_read),
    .avm_sdram_write        (fb_write),
    .avm_sdram_writedata    (fb_writedata),
    .avm_sdram_burstcount   (fb_burstcount),
    .avm_sdram_byteenable   (2'b11),         // un pixel ocupa la palabra entera
    .avm_sdram_debugaccess  (1'b0),
    .avm_sdram_readdata     (fb_readdata),
    .avm_sdram_readdatavalid(fb_readdatavalid),
    .avm_sdram_waitrequest  (fb_waitrequest),

    //-------------------------------------- Relojes y reinicio
    .clk_50_clk             (CLOCK_50),
    .pll_0_reset_reset      (reset_ext),
    .clk_100_clk            (clk_sys),
    .pll_0_vga_clk          (clk_pix),
    .pll_0_sdram_clk        (clk_sdram),

    //-------------------------------------- Pines de la SDRAM externa
    .sdram_controller_0_wire_addr (DRAM_ADDR),
    .sdram_controller_0_wire_ba   (DRAM_BA),
    .sdram_controller_0_wire_cas_n(DRAM_CAS_N),
    .sdram_controller_0_wire_cke  (DRAM_CKE),
    .sdram_controller_0_wire_cs_n (DRAM_CS_N),
    .sdram_controller_0_wire_dq   (DRAM_DQ),
    .sdram_controller_0_wire_dqm  ({DRAM_UDQM, DRAM_LDQM}),
    .sdram_controller_0_wire_ras_n(DRAM_RAS_N),
    .sdram_controller_0_wire_we_n (DRAM_WE_N),

    //-------------------------------------- Pines de la DDR3 del HPS
    .memory_mem_a           (HPS_DDR3_ADDR),
    .memory_mem_ba          (HPS_DDR3_BA),
    .memory_mem_ck          (HPS_DDR3_CK_P),
    .memory_mem_ck_n        (HPS_DDR3_CK_N),
    .memory_mem_cke         (HPS_DDR3_CKE),
    .memory_mem_cs_n        (HPS_DDR3_CS_N),
    .memory_mem_ras_n       (HPS_DDR3_RAS_N),
    .memory_mem_cas_n       (HPS_DDR3_CAS_N),
    .memory_mem_we_n        (HPS_DDR3_WE_N),
    .memory_mem_reset_n     (HPS_DDR3_RESET_N),
    .memory_mem_dq          (HPS_DDR3_DQ),
    .memory_mem_dqs         (HPS_DDR3_DQS_P),
    .memory_mem_dqs_n       (HPS_DDR3_DQS_N),
    .memory_mem_odt         (HPS_DDR3_ODT),
    .memory_mem_dm          (HPS_DDR3_DM),
    .memory_oct_rzqin       (HPS_DDR3_RZQ),

    //-------------------------------------- Perifericos duros del HPS
    .hps_io_hps_io_emac1_inst_TX_CLK(HPS_ENET_GTX_CLK),
    .hps_io_hps_io_emac1_inst_TXD0  (HPS_ENET_TX_DATA[0]),
    .hps_io_hps_io_emac1_inst_TXD1  (HPS_ENET_TX_DATA[1]),
    .hps_io_hps_io_emac1_inst_TXD2  (HPS_ENET_TX_DATA[2]),
    .hps_io_hps_io_emac1_inst_TXD3  (HPS_ENET_TX_DATA[3]),
    .hps_io_hps_io_emac1_inst_RXD0  (HPS_ENET_RX_DATA[0]),
    .hps_io_hps_io_emac1_inst_RXD1  (HPS_ENET_RX_DATA[1]),
    .hps_io_hps_io_emac1_inst_RXD2  (HPS_ENET_RX_DATA[2]),
    .hps_io_hps_io_emac1_inst_RXD3  (HPS_ENET_RX_DATA[3]),
    .hps_io_hps_io_emac1_inst_MDIO  (HPS_ENET_MDIO),
    .hps_io_hps_io_emac1_inst_MDC   (HPS_ENET_MDC),
    .hps_io_hps_io_emac1_inst_RX_CTL(HPS_ENET_RX_DV),
    .hps_io_hps_io_emac1_inst_TX_CTL(HPS_ENET_TX_EN),
    .hps_io_hps_io_emac1_inst_RX_CLK(HPS_ENET_RX_CLK),

    .hps_io_hps_io_sdio_inst_CLK    (HPS_SD_CLK),
    .hps_io_hps_io_sdio_inst_CMD    (HPS_SD_CMD),
    .hps_io_hps_io_sdio_inst_D0     (HPS_SD_DATA[0]),
    .hps_io_hps_io_sdio_inst_D1     (HPS_SD_DATA[1]),
    .hps_io_hps_io_sdio_inst_D2     (HPS_SD_DATA[2]),
    .hps_io_hps_io_sdio_inst_D3     (HPS_SD_DATA[3]),

    .hps_io_hps_io_uart0_inst_RX    (HPS_UART_RX),
    .hps_io_hps_io_uart0_inst_TX    (HPS_UART_TX)
  );

  //===========================================================================
  // Banco de registros, la cara visible del acelerador para el HPS
  //===========================================================================
  avalon_reg_file #(
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_regs (
    .clk            (clk_sys),
    .rst_n          (rst_n),

    .avs_address    (regs_address),
    .avs_read       (regs_read),
    .avs_write      (regs_write),
    .avs_writedata  (regs_writedata),
    .avs_readdata   (regs_readdata),

    .enable         (gfx_enable),
    .reset_soft     (gfx_reset_soft),
    .comand_w_ena   (gfx_cmd_w_ena),
    .comand_w_data  (gfx_cmd_w_data),

    .busy           (gfx_busy),
    .modo           (gfx_modo),
    .fifo_level     (gfx_fifo_level),
    .fifo_full      (gfx_fifo_full),
    .fifo_empty     (gfx_fifo_empty),
    .overflow       (gfx_overflow),
    .err_last       (gfx_err_last),
    .err_count      (gfx_err_count),
    .perf_cycles    (gfx_perf_cycles),
    .perf_commands  (gfx_perf_commands),
    .perf_pixels    (gfx_perf_pixels),
    .perf_dropped   (gfx_perf_dropped),
    .seq_last       (gfx_seq_last),
    .clip_count     (gfx_clip_count),
    .burst_writes   (gfx_burst_writes),
    .burst_reads    (gfx_burst_reads),
    .pixels_written (gfx_pixels_written),
    .out_of_range   (gfx_out_of_range),
    .vga_frames     (gfx_vga_frames),
    .vga_underrun   (gfx_vga_underrun),
    .leds           (gfx_leds)
  );

  //===========================================================================
  // El acelerador, a resolucion de placa
  //===========================================================================
  // FB_ONCHIP en cero: a 640 x 480 cada buffer ocupa 307 200 palabras de 16
  // bits, y los dos juntos no caben en la memoria embebida de la FPGA, de modo
  // que el maestro de rafaga sale por los puertos hacia la SDRAM externa. Esa
  // es justo la rama que el modulo ya preveia.
  Acelerador_Grafico_Top #(
    .SCREEN_W   (SCREEN_W),
    .SCREEN_H   (SCREEN_H),
    .PIXEL_BITS (PIXEL_BITS),
    .FIFO_DEPTH (FIFO_DEPTH),
    .SYS_CLK_HZ (Acelerador_pkg::SYS_CLK_HZ),

    .H_VISIBLE  (Acelerador_pkg::VGA_H_VISIBLE),
    .H_FRONT    (Acelerador_pkg::VGA_H_FRONT),
    .H_SYNC     (Acelerador_pkg::VGA_H_SYNC),
    .H_BACK     (Acelerador_pkg::VGA_H_BACK),
    .V_VISIBLE  (Acelerador_pkg::VGA_V_VISIBLE),
    .V_FRONT    (Acelerador_pkg::VGA_V_FRONT),
    .V_SYNC     (Acelerador_pkg::VGA_V_SYNC),
    .V_BACK     (Acelerador_pkg::VGA_V_BACK),

    .FB_ONCHIP  (1'b0)
  ) u_acelerador (
    .clk              (clk_sys),
    .rst_n            (rst_n),
    .clk_pix          (clk_pix),
    .rst_pix_n        (rst_pix_n),

    // CONTROL (0x04) y CMD_FIFO_W (0x0C)
    .enable           (gfx_enable),
    .reset_soft       (gfx_reset_soft),
    .comand_w_ena     (gfx_cmd_w_ena),
    .comand_w_data    (gfx_cmd_w_data),

    // Maestro de rafaga hacia la SDRAM
    .sd_read          (fb_read),
    .sd_write         (fb_write),
    .sd_address       (fb_address),
    .sd_burstcount    (fb_burstcount),
    .sd_writedata     (fb_writedata),
    .sd_waitrequest   (fb_waitrequest),
    .sd_readdata      (fb_readdata),
    .sd_readdatavalid (fb_readdatavalid),

    // Salida de video hacia el conversor de la placa
    .vga_r            (VGA_R),
    .vga_g            (VGA_G),
    .vga_b            (VGA_B),
    .vga_hs           (VGA_HS),
    .vga_vs           (VGA_VS),
    .vga_blank_n      (VGA_BLANK_N),
    .vga_sync_n       (VGA_SYNC_N),
    .vga_underrun     (gfx_vga_underrun),
    .vga_frames       (gfx_vga_frames),

    // Solicitud de pixel. Es observacion para el banco de pruebas y ya queda
    // cerrada dentro del acelerador, de modo que aqui no se conecta a nada.
    .px_valid         (),
    .px_x             (),
    .px_y             (),
    .px_color         (),
    .px_addr          (),
    .buffer_sel       (),

    // STATUS (0x08)
    .busy             (gfx_busy),
    .modo             (gfx_modo),
    .fifo_level       (gfx_fifo_level),
    .fifo_full        (gfx_fifo_full),
    .fifo_empty       (gfx_fifo_empty),
    .overflow         (gfx_overflow),

    // ERR_INFO (0x10)
    .err_last         (gfx_err_last),
    .err_count        (gfx_err_count),

    // Rendimiento (0x14 a 0x20)
    .perf_cycles      (gfx_perf_cycles),
    .perf_commands    (gfx_perf_commands),
    .perf_pixels      (gfx_perf_pixels),
    .perf_dropped     (gfx_perf_dropped),

    .seq_last         (gfx_seq_last),
    .clip_count       (gfx_clip_count),

    .leds             (gfx_leds),

    // Instrumentacion del gestor de framebuffer
    .burst_writes     (gfx_burst_writes),
    .burst_reads      (gfx_burst_reads),
    .pixels_written   (gfx_pixels_written),
    .out_of_range     (gfx_out_of_range)
  );

  //===========================================================================
  // Pines que se cablean directo
  //===========================================================================
  // El indicador de estado del sistema sale tal cual por los diez LED rojos.
  assign LEDR = gfx_leds;

  // Reloj del chip de SDRAM. Sale del PLL desfasado 2917 ps, que es el minimo
  // con el que el chip toma el comando sin un ciclo de retraso tras el
  // retardo de pista de la placa (ver Acelerador_Grafico.sdc, que tambien
  // explica la violacion de tiempo conocida en la lectura).
  assign DRAM_CLK = clk_sdram;

  // Reloj del conversor de video. Si en la placa la imagen apareciera corrida
  // un pixel o con el color desplazado, lo habitual es invertir este reloj
  // (assign VGA_CLK = ~clk_pix) para muestrear en el flanco contrario.
  assign VGA_CLK = clk_pix;

endmodule
