// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

`timescale 1ns/1ps

module tb_audio_resample;

reg clk = 0;
reg reset = 1;
reg sample_rate = 1;
reg signed [15:0] core_l = 0;
reg signed [15:0] core_r = 0;
reg fir_ce = 0;
reg signed [15:0] fir_din = 0;
wire signed [15:0] fir_dout;

always #1 clk = ~clk;

audio_fir_96k_48k fir
(
	.clk(clk),
	.reset(reset),
	.ce(fir_ce),
	.din(fir_din),
	.dout(fir_dout)
);

audio_out dut
(
	.reset(reset),
	.clk(clk),
	.sample_rate(sample_rate),
	.flt_rate(32'd0),
	.cx(40'd0),
	.cx0(8'd0),
	.cx1(8'd0),
	.cx2(8'd0),
	.cy0(24'd0),
	.cy1(24'd0),
	.cy2(24'd0),
	.att(5'd0),
	.mix(2'd0),
	.is_signed(1'b1),
	.core_l(core_l),
	.core_r(core_r),
	.alsa_l(16'd0),
	.alsa_r(16'd0),
	.i2s_bclk(),
	.i2s_lrclk(),
	.i2s_data(),
	.spdif(),
	.dac_l(),
	.dac_r()
);

task wait_core_ce;
	begin
		begin : wait_loop
			forever begin
				@(posedge clk);
				#0.1;
				if(dut.core_96k_ce) disable wait_loop;
			end
		end
	end
endtask

task wait_sample_ce;
	begin
		begin : wait_loop
			forever begin
				@(posedge clk);
				#0.1;
				if(dut.sample_ce) disable wait_loop;
			end
		end
	end
endtask

task fir_sample;
	input signed [15:0] sample_value;
	begin
		@(negedge clk);
		fir_din = sample_value;
		fir_ce = 1;
		@(posedge clk);
		@(negedge clk);
		fir_ce = 0;
		repeat(13) @(posedge clk);
		#0.1;
	end
endtask

integer i;
integer cycles;
integer value;
integer peak;

initial begin
	repeat(4) @(posedge clk);
	#0.1 reset = 0;

	core_l = 16'sd12345;
	wait_core_ce();
	wait_core_ce();
	@(posedge clk);
	#0.1;
	if($signed(dut.cl) != 12345 || $signed(dut.core_l_aa) != 12345) begin
		$display("96 kHz path did not bypass the decimation filter: input=%0d iir=%0d selected=%0d", $signed(dut.cl), $signed(dut.acl), $signed(dut.core_l_aa));
		$fatal(1);
	end

	wait_sample_ce();
	cycles = 0;
	begin : count_96k
		forever begin
			@(posedge clk);
			#0.1 cycles = cycles + 1;
			if(dut.sample_ce) disable count_96k;
		end
	end
	if(cycles != 256) begin
		$display("96 kHz sample period was %0d clocks", cycles);
		$fatal(1);
	end

	sample_rate = 0;
	wait_sample_ce();
	wait_sample_ce();
	cycles = 0;
	begin : count_48k
		forever begin
			@(posedge clk);
			#0.1 cycles = cycles + 1;
			if(dut.sample_ce) disable count_48k;
		end
	end
	if(cycles != 512) begin
		$display("48 kHz sample period was %0d clocks", cycles);
		$fatal(1);
	end

	core_l = 16'sd12000;
	repeat(6) @(posedge clk);
	for(i = 0; i < 55; i = i + 1) wait_core_ce();
	#0.1;
	if($signed(dut.cl_48) != 12000 || $signed(dut.core_l_aa) != 12000) begin
		$display("48 kHz filter failed unity DC gain: fir=%0d selected=%0d", $signed(dut.cl_48), $signed(dut.core_l_aa));
		$fatal(1);
	end

	for(i = 0; i < 55; i = i + 1) fir_sample(16'sd12000);
	if(fir_dout != 12000) begin
		$display("standalone filter failed unity DC gain: %0d", fir_dout);
		$fatal(1);
	end

	peak = 0;
	for(i = 0; i < 64; i = i + 1) begin
		if(i[0]) fir_sample(-16'sd16000);
		else fir_sample(16'sd16000);
		if(i >= 48) begin
			value = $signed(fir_dout);
			if(value < 0) value = -value;
			if(value > peak) peak = value;
		end
	end
	if(peak > 5) begin
		$display("48 kHz anti-alias filter left excessive 48 kHz energy: peak %0d", peak);
		$fatal(1);
	end

	peak = 0;
	for(i = 0; i < 96; i = i + 1) begin
		case(i % 24)
			0: fir_sample(16'sd16000);
			1: fir_sample(-16'sd4141);
			2: fir_sample(-16'sd13856);
			3: fir_sample(16'sd11314);
			4: fir_sample(16'sd8000);
			5: fir_sample(-16'sd15455);
			6: fir_sample(16'sd0);
			7: fir_sample(16'sd15455);
			8: fir_sample(-16'sd8000);
			9: fir_sample(-16'sd11314);
			10: fir_sample(16'sd13856);
			11: fir_sample(16'sd4141);
			12: fir_sample(-16'sd16000);
			13: fir_sample(16'sd4141);
			14: fir_sample(16'sd13856);
			15: fir_sample(-16'sd11314);
			16: fir_sample(-16'sd8000);
			17: fir_sample(16'sd15455);
			18: fir_sample(16'sd0);
			19: fir_sample(-16'sd15455);
			20: fir_sample(16'sd8000);
			21: fir_sample(16'sd11314);
			22: fir_sample(-16'sd13856);
			default: fir_sample(-16'sd4141);
		endcase
		if(i >= 64) begin
			value = $signed(fir_dout);
			if(value < 0) value = -value;
			if(value > peak) peak = value;
		end
	end
	if(peak > 20) begin
		$display("48 kHz anti-alias filter left excessive 28 kHz energy: peak %0d", peak);
		$fatal(1);
	end

	peak = 0;
	for(i = 0; i < 96; i = i + 1) begin
		case(i % 6)
			0: fir_sample(16'sd16000);
			1: fir_sample(16'sd8000);
			2: fir_sample(-16'sd8000);
			3: fir_sample(-16'sd16000);
			4: fir_sample(-16'sd8000);
			default: fir_sample(16'sd8000);
		endcase
		if(i >= 64) begin
			value = $signed(fir_dout);
			if(value < 0) value = -value;
			if(value > peak) peak = value;
		end
	end
	if(peak < 15000) begin
		$display("48 kHz anti-alias filter attenuated 16 kHz passband excessively: peak %0d", peak);
		$fatal(1);
	end

	$display("tb_audio_resample all checks passed");
	$finish;
end

endmodule

module IIR_filter
#(
	parameter use_params = 1
)
(
	input clk,
	input reset,
	input ce,
	input sample_ce,
	input [39:0] cx,
	input [7:0] cx0,
	input [7:0] cx1,
	input [7:0] cx2,
	input [23:0] cy0,
	input [23:0] cy1,
	input [23:0] cy2,
	input [15:0] input_l,
	input [15:0] input_r,
	output reg [15:0] output_l,
	output reg [15:0] output_r
);

always @(posedge clk, posedge reset) begin
	if(reset) begin
		output_l <= 0;
		output_r <= 0;
	end
	else if(sample_ce) begin
		output_l <= input_l;
		output_r <= input_r;
	end
end

endmodule

module DC_blocker
(
	input clk,
	input ce,
	input mute,
	input sample_rate,
	input [15:0] din,
	output [15:0] dout
);

assign dout = din;

endmodule

module i2s
(
	input reset,
	input clk,
	input ce,
	output sclk,
	output lrclk,
	output sdata,
	input [15:0] left_chan,
	input [15:0] right_chan
);

assign sclk = 0;
assign lrclk = 0;
assign sdata = 0;

endmodule

module spdif
(
	input rst_i,
	input clk_i,
	input bit_out_en_i,
	input [31:0] sample_i,
	output spdif_o
);

assign spdif_o = 0;

endmodule

module sigma_delta_dac
#(
	parameter MSBI = 7,
	parameter INV = 1'b1
)
(
	input CLK,
	input RESET,
	input [MSBI:0] DACin,
	output DACout
);

assign DACout = 0;

endmodule
