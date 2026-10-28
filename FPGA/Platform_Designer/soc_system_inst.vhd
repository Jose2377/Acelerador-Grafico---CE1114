	component soc_system is
		port (
			avm_regs_waitrequest            : in    std_logic                     := 'X';             -- waitrequest
			avm_regs_readdata               : in    std_logic_vector(31 downto 0) := (others => 'X'); -- readdata
			avm_regs_readdatavalid          : in    std_logic                     := 'X';             -- readdatavalid
			avm_regs_burstcount             : out   std_logic_vector(0 downto 0);                     -- burstcount
			avm_regs_writedata              : out   std_logic_vector(31 downto 0);                    -- writedata
			avm_regs_address                : out   std_logic_vector(5 downto 0);                     -- address
			avm_regs_write                  : out   std_logic;                                        -- write
			avm_regs_read                   : out   std_logic;                                        -- read
			avm_regs_byteenable             : out   std_logic_vector(3 downto 0);                     -- byteenable
			avm_regs_debugaccess            : out   std_logic;                                        -- debugaccess
			clk_50_clk                      : in    std_logic                     := 'X';             -- clk
			hps_io_hps_io_emac1_inst_TX_CLK : out   std_logic;                                        -- hps_io_emac1_inst_TX_CLK
			hps_io_hps_io_emac1_inst_TXD0   : out   std_logic;                                        -- hps_io_emac1_inst_TXD0
			hps_io_hps_io_emac1_inst_TXD1   : out   std_logic;                                        -- hps_io_emac1_inst_TXD1
			hps_io_hps_io_emac1_inst_TXD2   : out   std_logic;                                        -- hps_io_emac1_inst_TXD2
			hps_io_hps_io_emac1_inst_TXD3   : out   std_logic;                                        -- hps_io_emac1_inst_TXD3
			hps_io_hps_io_emac1_inst_RXD0   : in    std_logic                     := 'X';             -- hps_io_emac1_inst_RXD0
			hps_io_hps_io_emac1_inst_MDIO   : inout std_logic                     := 'X';             -- hps_io_emac1_inst_MDIO
			hps_io_hps_io_emac1_inst_MDC    : out   std_logic;                                        -- hps_io_emac1_inst_MDC
			hps_io_hps_io_emac1_inst_RX_CTL : in    std_logic                     := 'X';             -- hps_io_emac1_inst_RX_CTL
			hps_io_hps_io_emac1_inst_TX_CTL : out   std_logic;                                        -- hps_io_emac1_inst_TX_CTL
			hps_io_hps_io_emac1_inst_RX_CLK : in    std_logic                     := 'X';             -- hps_io_emac1_inst_RX_CLK
			hps_io_hps_io_emac1_inst_RXD1   : in    std_logic                     := 'X';             -- hps_io_emac1_inst_RXD1
			hps_io_hps_io_emac1_inst_RXD2   : in    std_logic                     := 'X';             -- hps_io_emac1_inst_RXD2
			hps_io_hps_io_emac1_inst_RXD3   : in    std_logic                     := 'X';             -- hps_io_emac1_inst_RXD3
			hps_io_hps_io_sdio_inst_CMD     : inout std_logic                     := 'X';             -- hps_io_sdio_inst_CMD
			hps_io_hps_io_sdio_inst_D0      : inout std_logic                     := 'X';             -- hps_io_sdio_inst_D0
			hps_io_hps_io_sdio_inst_D1      : inout std_logic                     := 'X';             -- hps_io_sdio_inst_D1
			hps_io_hps_io_sdio_inst_CLK     : out   std_logic;                                        -- hps_io_sdio_inst_CLK
			hps_io_hps_io_sdio_inst_D2      : inout std_logic                     := 'X';             -- hps_io_sdio_inst_D2
			hps_io_hps_io_sdio_inst_D3      : inout std_logic                     := 'X';             -- hps_io_sdio_inst_D3
			hps_io_hps_io_uart0_inst_RX     : in    std_logic                     := 'X';             -- hps_io_uart0_inst_RX
			hps_io_hps_io_uart0_inst_TX     : out   std_logic;                                        -- hps_io_uart0_inst_TX
			memory_mem_a                    : out   std_logic_vector(14 downto 0);                    -- mem_a
			memory_mem_ba                   : out   std_logic_vector(2 downto 0);                     -- mem_ba
			memory_mem_ck                   : out   std_logic;                                        -- mem_ck
			memory_mem_ck_n                 : out   std_logic;                                        -- mem_ck_n
			memory_mem_cke                  : out   std_logic;                                        -- mem_cke
			memory_mem_cs_n                 : out   std_logic;                                        -- mem_cs_n
			memory_mem_ras_n                : out   std_logic;                                        -- mem_ras_n
			memory_mem_cas_n                : out   std_logic;                                        -- mem_cas_n
			memory_mem_we_n                 : out   std_logic;                                        -- mem_we_n
			memory_mem_reset_n              : out   std_logic;                                        -- mem_reset_n
			memory_mem_dq                   : inout std_logic_vector(31 downto 0) := (others => 'X'); -- mem_dq
			memory_mem_dqs                  : inout std_logic_vector(3 downto 0)  := (others => 'X'); -- mem_dqs
			memory_mem_dqs_n                : inout std_logic_vector(3 downto 0)  := (others => 'X'); -- mem_dqs_n
			memory_mem_odt                  : out   std_logic;                                        -- mem_odt
			memory_mem_dm                   : out   std_logic_vector(3 downto 0);                     -- mem_dm
			memory_oct_rzqin                : in    std_logic                     := 'X';             -- oct_rzqin
			pll_0_reset_reset               : in    std_logic                     := 'X';             -- reset
			sdram_controller_0_wire_addr    : out   std_logic_vector(12 downto 0);                    -- addr
			sdram_controller_0_wire_ba      : out   std_logic_vector(1 downto 0);                     -- ba
			sdram_controller_0_wire_cas_n   : out   std_logic;                                        -- cas_n
			sdram_controller_0_wire_cke     : out   std_logic;                                        -- cke
			sdram_controller_0_wire_cs_n    : out   std_logic;                                        -- cs_n
			sdram_controller_0_wire_dq      : inout std_logic_vector(15 downto 0) := (others => 'X'); -- dq
			sdram_controller_0_wire_dqm     : out   std_logic_vector(1 downto 0);                     -- dqm
			sdram_controller_0_wire_ras_n   : out   std_logic;                                        -- ras_n
			sdram_controller_0_wire_we_n    : out   std_logic;                                        -- we_n
			pll_0_sdram_clk                 : out   std_logic;                                        -- clk
			avm_sdram_waitrequest           : out   std_logic;                                        -- waitrequest
			avm_sdram_readdata              : out   std_logic_vector(15 downto 0);                    -- readdata
			avm_sdram_readdatavalid         : out   std_logic;                                        -- readdatavalid
			avm_sdram_burstcount            : in    std_logic_vector(3 downto 0)  := (others => 'X'); -- burstcount
			avm_sdram_writedata             : in    std_logic_vector(15 downto 0) := (others => 'X'); -- writedata
			avm_sdram_address               : in    std_logic_vector(25 downto 0) := (others => 'X'); -- address
			avm_sdram_write                 : in    std_logic                     := 'X';             -- write
			avm_sdram_read                  : in    std_logic                     := 'X';             -- read
			avm_sdram_byteenable            : in    std_logic_vector(1 downto 0)  := (others => 'X'); -- byteenable
			avm_sdram_debugaccess           : in    std_logic                     := 'X';             -- debugaccess
			pll_0_vga_clk                   : out   std_logic                                         -- clk
		);
	end component soc_system;

	u0 : component soc_system
		port map (
			avm_regs_waitrequest            => CONNECTED_TO_avm_regs_waitrequest,            --                avm_regs.waitrequest
			avm_regs_readdata               => CONNECTED_TO_avm_regs_readdata,               --                        .readdata
			avm_regs_readdatavalid          => CONNECTED_TO_avm_regs_readdatavalid,          --                        .readdatavalid
			avm_regs_burstcount             => CONNECTED_TO_avm_regs_burstcount,             --                        .burstcount
			avm_regs_writedata              => CONNECTED_TO_avm_regs_writedata,              --                        .writedata
			avm_regs_address                => CONNECTED_TO_avm_regs_address,                --                        .address
			avm_regs_write                  => CONNECTED_TO_avm_regs_write,                  --                        .write
			avm_regs_read                   => CONNECTED_TO_avm_regs_read,                   --                        .read
			avm_regs_byteenable             => CONNECTED_TO_avm_regs_byteenable,             --                        .byteenable
			avm_regs_debugaccess            => CONNECTED_TO_avm_regs_debugaccess,            --                        .debugaccess
			clk_50_clk                      => CONNECTED_TO_clk_50_clk,                      --                  clk_50.clk
			hps_io_hps_io_emac1_inst_TX_CLK => CONNECTED_TO_hps_io_hps_io_emac1_inst_TX_CLK, --                  hps_io.hps_io_emac1_inst_TX_CLK
			hps_io_hps_io_emac1_inst_TXD0   => CONNECTED_TO_hps_io_hps_io_emac1_inst_TXD0,   --                        .hps_io_emac1_inst_TXD0
			hps_io_hps_io_emac1_inst_TXD1   => CONNECTED_TO_hps_io_hps_io_emac1_inst_TXD1,   --                        .hps_io_emac1_inst_TXD1
			hps_io_hps_io_emac1_inst_TXD2   => CONNECTED_TO_hps_io_hps_io_emac1_inst_TXD2,   --                        .hps_io_emac1_inst_TXD2
			hps_io_hps_io_emac1_inst_TXD3   => CONNECTED_TO_hps_io_hps_io_emac1_inst_TXD3,   --                        .hps_io_emac1_inst_TXD3
			hps_io_hps_io_emac1_inst_RXD0   => CONNECTED_TO_hps_io_hps_io_emac1_inst_RXD0,   --                        .hps_io_emac1_inst_RXD0
			hps_io_hps_io_emac1_inst_MDIO   => CONNECTED_TO_hps_io_hps_io_emac1_inst_MDIO,   --                        .hps_io_emac1_inst_MDIO
			hps_io_hps_io_emac1_inst_MDC    => CONNECTED_TO_hps_io_hps_io_emac1_inst_MDC,    --                        .hps_io_emac1_inst_MDC
			hps_io_hps_io_emac1_inst_RX_CTL => CONNECTED_TO_hps_io_hps_io_emac1_inst_RX_CTL, --                        .hps_io_emac1_inst_RX_CTL
			hps_io_hps_io_emac1_inst_TX_CTL => CONNECTED_TO_hps_io_hps_io_emac1_inst_TX_CTL, --                        .hps_io_emac1_inst_TX_CTL
			hps_io_hps_io_emac1_inst_RX_CLK => CONNECTED_TO_hps_io_hps_io_emac1_inst_RX_CLK, --                        .hps_io_emac1_inst_RX_CLK
			hps_io_hps_io_emac1_inst_RXD1   => CONNECTED_TO_hps_io_hps_io_emac1_inst_RXD1,   --                        .hps_io_emac1_inst_RXD1
			hps_io_hps_io_emac1_inst_RXD2   => CONNECTED_TO_hps_io_hps_io_emac1_inst_RXD2,   --                        .hps_io_emac1_inst_RXD2
			hps_io_hps_io_emac1_inst_RXD3   => CONNECTED_TO_hps_io_hps_io_emac1_inst_RXD3,   --                        .hps_io_emac1_inst_RXD3
			hps_io_hps_io_sdio_inst_CMD     => CONNECTED_TO_hps_io_hps_io_sdio_inst_CMD,     --                        .hps_io_sdio_inst_CMD
			hps_io_hps_io_sdio_inst_D0      => CONNECTED_TO_hps_io_hps_io_sdio_inst_D0,      --                        .hps_io_sdio_inst_D0
			hps_io_hps_io_sdio_inst_D1      => CONNECTED_TO_hps_io_hps_io_sdio_inst_D1,      --                        .hps_io_sdio_inst_D1
			hps_io_hps_io_sdio_inst_CLK     => CONNECTED_TO_hps_io_hps_io_sdio_inst_CLK,     --                        .hps_io_sdio_inst_CLK
			hps_io_hps_io_sdio_inst_D2      => CONNECTED_TO_hps_io_hps_io_sdio_inst_D2,      --                        .hps_io_sdio_inst_D2
			hps_io_hps_io_sdio_inst_D3      => CONNECTED_TO_hps_io_hps_io_sdio_inst_D3,      --                        .hps_io_sdio_inst_D3
			hps_io_hps_io_uart0_inst_RX     => CONNECTED_TO_hps_io_hps_io_uart0_inst_RX,     --                        .hps_io_uart0_inst_RX
			hps_io_hps_io_uart0_inst_TX     => CONNECTED_TO_hps_io_hps_io_uart0_inst_TX,     --                        .hps_io_uart0_inst_TX
			memory_mem_a                    => CONNECTED_TO_memory_mem_a,                    --                  memory.mem_a
			memory_mem_ba                   => CONNECTED_TO_memory_mem_ba,                   --                        .mem_ba
			memory_mem_ck                   => CONNECTED_TO_memory_mem_ck,                   --                        .mem_ck
			memory_mem_ck_n                 => CONNECTED_TO_memory_mem_ck_n,                 --                        .mem_ck_n
			memory_mem_cke                  => CONNECTED_TO_memory_mem_cke,                  --                        .mem_cke
			memory_mem_cs_n                 => CONNECTED_TO_memory_mem_cs_n,                 --                        .mem_cs_n
			memory_mem_ras_n                => CONNECTED_TO_memory_mem_ras_n,                --                        .mem_ras_n
			memory_mem_cas_n                => CONNECTED_TO_memory_mem_cas_n,                --                        .mem_cas_n
			memory_mem_we_n                 => CONNECTED_TO_memory_mem_we_n,                 --                        .mem_we_n
			memory_mem_reset_n              => CONNECTED_TO_memory_mem_reset_n,              --                        .mem_reset_n
			memory_mem_dq                   => CONNECTED_TO_memory_mem_dq,                   --                        .mem_dq
			memory_mem_dqs                  => CONNECTED_TO_memory_mem_dqs,                  --                        .mem_dqs
			memory_mem_dqs_n                => CONNECTED_TO_memory_mem_dqs_n,                --                        .mem_dqs_n
			memory_mem_odt                  => CONNECTED_TO_memory_mem_odt,                  --                        .mem_odt
			memory_mem_dm                   => CONNECTED_TO_memory_mem_dm,                   --                        .mem_dm
			memory_oct_rzqin                => CONNECTED_TO_memory_oct_rzqin,                --                        .oct_rzqin
			pll_0_reset_reset               => CONNECTED_TO_pll_0_reset_reset,               --             pll_0_reset.reset
			sdram_controller_0_wire_addr    => CONNECTED_TO_sdram_controller_0_wire_addr,    -- sdram_controller_0_wire.addr
			sdram_controller_0_wire_ba      => CONNECTED_TO_sdram_controller_0_wire_ba,      --                        .ba
			sdram_controller_0_wire_cas_n   => CONNECTED_TO_sdram_controller_0_wire_cas_n,   --                        .cas_n
			sdram_controller_0_wire_cke     => CONNECTED_TO_sdram_controller_0_wire_cke,     --                        .cke
			sdram_controller_0_wire_cs_n    => CONNECTED_TO_sdram_controller_0_wire_cs_n,    --                        .cs_n
			sdram_controller_0_wire_dq      => CONNECTED_TO_sdram_controller_0_wire_dq,      --                        .dq
			sdram_controller_0_wire_dqm     => CONNECTED_TO_sdram_controller_0_wire_dqm,     --                        .dqm
			sdram_controller_0_wire_ras_n   => CONNECTED_TO_sdram_controller_0_wire_ras_n,   --                        .ras_n
			sdram_controller_0_wire_we_n    => CONNECTED_TO_sdram_controller_0_wire_we_n,    --                        .we_n
			pll_0_sdram_clk                 => CONNECTED_TO_pll_0_sdram_clk,                 --             pll_0_sdram.clk
			avm_sdram_waitrequest           => CONNECTED_TO_avm_sdram_waitrequest,           --               avm_sdram.waitrequest
			avm_sdram_readdata              => CONNECTED_TO_avm_sdram_readdata,              --                        .readdata
			avm_sdram_readdatavalid         => CONNECTED_TO_avm_sdram_readdatavalid,         --                        .readdatavalid
			avm_sdram_burstcount            => CONNECTED_TO_avm_sdram_burstcount,            --                        .burstcount
			avm_sdram_writedata             => CONNECTED_TO_avm_sdram_writedata,             --                        .writedata
			avm_sdram_address               => CONNECTED_TO_avm_sdram_address,               --                        .address
			avm_sdram_write                 => CONNECTED_TO_avm_sdram_write,                 --                        .write
			avm_sdram_read                  => CONNECTED_TO_avm_sdram_read,                  --                        .read
			avm_sdram_byteenable            => CONNECTED_TO_avm_sdram_byteenable,            --                        .byteenable
			avm_sdram_debugaccess           => CONNECTED_TO_avm_sdram_debugaccess,           --                        .debugaccess
			pll_0_vga_clk                   => CONNECTED_TO_pll_0_vga_clk                    --               pll_0_vga.clk
		);

