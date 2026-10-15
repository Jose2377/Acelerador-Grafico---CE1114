
module soc_system (
	avm_regs_waitrequest,
	avm_regs_readdata,
	avm_regs_readdatavalid,
	avm_regs_burstcount,
	avm_regs_writedata,
	avm_regs_address,
	avm_regs_write,
	avm_regs_read,
	avm_regs_byteenable,
	avm_regs_debugaccess,
	clk_100_clk,
	reset_reset_n);	

	input		avm_regs_waitrequest;
	input	[31:0]	avm_regs_readdata;
	input		avm_regs_readdatavalid;
	output	[0:0]	avm_regs_burstcount;
	output	[31:0]	avm_regs_writedata;
	output	[5:0]	avm_regs_address;
	output		avm_regs_write;
	output		avm_regs_read;
	output	[3:0]	avm_regs_byteenable;
	output		avm_regs_debugaccess;
	input		clk_100_clk;
	input		reset_reset_n;
endmodule
