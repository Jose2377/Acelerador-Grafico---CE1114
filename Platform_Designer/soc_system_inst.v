	soc_system u0 (
		.avm_regs_waitrequest   (<connected-to-avm_regs_waitrequest>),   // avm_regs.waitrequest
		.avm_regs_readdata      (<connected-to-avm_regs_readdata>),      //         .readdata
		.avm_regs_readdatavalid (<connected-to-avm_regs_readdatavalid>), //         .readdatavalid
		.avm_regs_burstcount    (<connected-to-avm_regs_burstcount>),    //         .burstcount
		.avm_regs_writedata     (<connected-to-avm_regs_writedata>),     //         .writedata
		.avm_regs_address       (<connected-to-avm_regs_address>),       //         .address
		.avm_regs_write         (<connected-to-avm_regs_write>),         //         .write
		.avm_regs_read          (<connected-to-avm_regs_read>),          //         .read
		.avm_regs_byteenable    (<connected-to-avm_regs_byteenable>),    //         .byteenable
		.avm_regs_debugaccess   (<connected-to-avm_regs_debugaccess>),   //         .debugaccess
		.clk_100_clk            (<connected-to-clk_100_clk>),            //  clk_100.clk
		.reset_reset_n          (<connected-to-reset_reset_n>)           //    reset.reset_n
	);

