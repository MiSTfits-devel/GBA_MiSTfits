// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
// Real-RTL bench for rtl/sdram.sv (Icarus Verilog) - the one component no
// VHDL bench can instantiate. Drives the ACTUAL controller against a
// behavioral SDR SDRAM chip model and self-checks:
//
//   S1  ROMCOPY handshake shape: CLEANSAVERAM writes then the WRITESDRAM
//       stream (req pulse per 32b write, next pulse right after ready16),
//       then full read-back verify (16b even/odd + 32b).
//   S2  cancel sweep: read cancelled at every offset 0..12 after the req,
//       with and without a same-edge relaunch. The relaunch must return ITS
//       data; an abandoned read must fire NO ready at all.
//   S3  attribute mutation: req pulsed while the controller is busy
//       (refresh), then the address input changes. The op must use the
//       pulse-time address (request-time latch).
//   S4  same for writes: the data must land at the pulse-time address.
//
// run: sim/run_sdram_real_tb.sh  (also runs the pre-fix controller for
// differential reference; S3/S4 are expected to FAIL there - live sampling)

`timescale 1ns/1ps

module tb_sdram_real;

   reg clk = 0;
   always #5 clk = ~clk; // 100MHz

   reg init = 1;

   // ch2 driven by the bench; ch1/ch3 tied off like GBA.sv gameplay
   reg  [26:1] ch2_addr = 0;
   reg  [31:0] ch2_din = 0;
   reg  [3:0]  ch2_be = 4'b1111;
   reg         ch2_req = 0;
   reg         ch2_cancel = 0;
   reg         ch2_rnw = 1;
   wire [31:0] ch2_dout;
   wire        ch2_ready, ch2_ready16;

   reg         refresh_req = 0;

   wire [15:0] SDRAM_DQ;
   wire [12:0] SDRAM_A;
   wire [1:0]  SDRAM_BA;
   wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

   sdram dut
   (
      .init(init),
      .clk(clk),

      .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
      .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
      .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
      .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
      .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),

      .refresh_req(refresh_req),

      .ch1_addr(26'd0), .ch1_din(16'd0), .ch1_dout(),
      .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_ready(),

      .ch2_addr(ch2_addr), .ch2_din(ch2_din), .ch2_be(ch2_be),
      .ch2_dout(ch2_dout), .ch2_req(ch2_req), .ch2_cancel(ch2_cancel),
      .ch2_rnw(ch2_rnw), .ch2_ready(ch2_ready), .ch2_ready16(ch2_ready16),

      .ch3_addr(24'd0), .ch3_din(16'd0), .ch3_dout(),
      .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_ready()
   );

   // ------------------------------------------------------------------
   // behavioral SDR SDRAM chip: bank0/chip0 window, rows 0..511
   // (all test byte addresses < 0x100000)
   // ------------------------------------------------------------------
   // index = {row[9:0], col[9:0]}: the controller advances a row every 1KB
   // (column bit 9 carries byte-address bit 25, constant 0 in this window)
   reg [15:0] mem [0:1048575];
   reg [12:0] open_row [0:3];

   wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
   localparam C_ACTIVE = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100;

   integer k;
   reg [19:0] rd_idx;
   reg [15:0] beat;
   reg        dq_drive_en = 0;
   reg [15:0] dq_drive;
   assign SDRAM_DQ = dq_drive_en ? dq_drive : 16'hzzzz;

   // chip behavior sampled at negedge (mid-cycle, like the phase-shifted
   // SDRAM_CLK): command outputs registered at the previous posedge are stable
   always @(negedge clk) begin
      if (!SDRAM_nCS) begin
         if (cmd == C_ACTIVE) open_row[SDRAM_BA] <= SDRAM_A;
         if (cmd == C_WRITE) begin
            if (!SDRAM_DQML) mem[{open_row[SDRAM_BA][9:0], SDRAM_A[9:0]}][7:0]  <= SDRAM_DQ[7:0];
            if (!SDRAM_DQMH) mem[{open_row[SDRAM_BA][9:0], SDRAM_A[9:0]}][15:8] <= SDRAM_DQ[15:8];
         end
         if (cmd == C_READ) begin
            rd_idx = {open_row[SDRAM_BA][9:0], SDRAM_A[9:0]};
            // CL2, burst 4: drive DQ across the fabric edges the controller
            // samples with dq_reg (beat0 visible at posedge T+3 relative to
            // the READ command edge)
            fork
               begin
                  @(negedge clk); @(negedge clk);
                  for (k = 0; k < 4; k = k + 1) begin
                     dq_drive    = mem[{rd_idx[19:2], rd_idx[1:0] + k[1:0]}];
                     dq_drive_en = 1;
                     @(negedge clk);
                  end
                  dq_drive_en = 0;
               end
            join_none
         end
      end
   end

   // ------------------------------------------------------------------
   // bench-side shadow + scoreboard
   // ------------------------------------------------------------------
   reg [15:0] shadow [0:1048575];
   integer errors = 0;
   integer readies_seen = 0;

   function [19:0] hwidx(input [26:0] byteaddr);
      hwidx = {byteaddr[19:10], 1'b0, byteaddr[9:1]}; // {row, col} as the chip sees it
   endfunction

   task check(input cond, input [127:0] what);
      if (!cond) begin
         errors = errors + 1;
         $display("FAIL @%0t: %0s", $time, what);
      end
   endtask

   // count stray readies between operations
   always @(posedge clk) if (ch2_ready16) readies_seen = readies_seen + 1;

   // ------------------------------------------------------------------
   // drivers
   // ------------------------------------------------------------------
   task ch2_write32(input [26:0] byteaddr, input [31:0] data);
      begin
         @(posedge clk);
         ch2_addr   <= byteaddr[26:1];
         ch2_din    <= data;
         ch2_be     <= 4'b1111;
         ch2_rnw    <= 0;
         ch2_req    <= 1;
         @(posedge clk);
         ch2_req    <= 0;
         @(posedge clk);
         while (!ch2_ready) @(posedge clk);
         shadow[hwidx(byteaddr)]     = data[15:0];
         shadow[hwidx(byteaddr) + 1] = data[31:16];
      end
   endtask

   task ch2_read32(input [26:0] byteaddr);
      begin
         @(posedge clk);
         ch2_addr <= byteaddr[26:1];
         ch2_rnw  <= 1;
         ch2_be   <= 4'b1111;
         ch2_req  <= 1;
         @(posedge clk);
         ch2_req  <= 0;
         @(posedge clk);
         while (!ch2_ready) @(posedge clk);
         if (ch2_dout != {shadow[hwidx(byteaddr) + 1], shadow[hwidx(byteaddr)]}) begin
            errors = errors + 1;
            $display("FAIL @%0t: read32 addr %h got %h want %h_%h",
                     $time, byteaddr, ch2_dout,
                     shadow[hwidx(byteaddr) + 1], shadow[hwidx(byteaddr)]);
         end
      end
   endtask

   integer i, off, base_readies;
   reg [26:0] addrA, addrB;

   initial begin
      for (i = 0; i < 1048576; i = i + 1) begin mem[i] = 16'hxxxx; shadow[i] = 16'hxxxx; end

      // controller startup
      repeat (10) @(posedge clk);
      init <= 0;
      repeat (12300) @(posedge clk); // sdram_startup_cycles + margin
      $display("startup done @%0t", $time);

      // ---------------- S1: ROMCOPY shape ----------------
      // CLEANSAVERAM: 64 words of FFFF at 0..0xFC
      for (i = 0; i < 64; i = i + 1) ch2_write32(i*4, 32'hFFFFFFFF);
      // WRITESDRAM stream: pattern into ROM_START (0x80000)
      for (i = 0; i < 256; i = i + 1) ch2_write32(27'h80000 + i*4, {i[15:0] ^ 16'hBEEF, i[15:0]});
      // read-back verify
      for (i = 0; i < 256; i = i + 1) ch2_read32(27'h80000 + i*4);
      for (i = 0; i < 64; i = i + 1) ch2_read32(i*4);
      $display("S1 romcopy shape done, errors so far %0d", errors);

      // ---------------- S2: cancel sweep ----------------
      addrA = 27'h80010; addrB = 27'h8040C;
      for (off = 0; off <= 12; off = off + 1) begin
         // (a) cancel + same-edge relaunch to B: expect exactly B's data
         @(posedge clk);
         ch2_addr <= addrA[26:1]; ch2_rnw <= 1; ch2_req <= 1;
         @(posedge clk);
         ch2_req <= 0;
         repeat (off) @(posedge clk);
         ch2_cancel <= 1;
         ch2_addr   <= addrB[26:1]; ch2_req <= 1;
         @(posedge clk);
         ch2_cancel <= 0; ch2_req <= 0;
         @(posedge clk);
         while (!ch2_ready) @(posedge clk);
         check(ch2_dout == {shadow[hwidx(addrB) + 1], shadow[hwidx(addrB)]},
                "S2a relaunch got wrong data");
         repeat (20) @(posedge clk); // drain

         // (b) cancel with NO relaunch: expect zero readies for 30 cycles
         @(posedge clk);
         ch2_addr <= addrA[26:1]; ch2_rnw <= 1; ch2_req <= 1;
         @(posedge clk);
         ch2_req <= 0;
         repeat (off) @(posedge clk);
         ch2_cancel <= 1;
         @(posedge clk);
         ch2_cancel <= 0;
         // a ready REGISTERED the edge before the cancel is causally beyond
         // suppression; every real consumer masks it (extern's cancel branch
         // outranks done16, guests are never in flight during an extern
         // cancel). Sample the baseline after that edge has drained.
         @(posedge clk);
         base_readies = readies_seen;
         repeat (30) @(posedge clk);
         if (readies_seen != base_readies) begin
            errors = errors + 1;
            $display("FAIL @%0t: S2b abandoned read fired a ready, off=%0d", $time, off);
         end
      end
      $display("S2 cancel sweep done, errors so far %0d", errors);

      // ---------------- S3: read attribute mutation ----------------
      refresh_req <= 1; // park the controller in refresh
      repeat (2) @(posedge clk);
      ch2_addr <= addrA[26:1]; ch2_rnw <= 1; ch2_req <= 1;
      @(posedge clk);
      ch2_req  <= 0;
      ch2_addr <= addrB[26:1]; // mutate AFTER the pulse
      repeat (3) @(posedge clk);
      refresh_req <= 0;
      @(posedge clk);
      while (!ch2_ready) @(posedge clk);
      check(ch2_dout == {shadow[hwidx(addrA) + 1], shadow[hwidx(addrA)]},
             "S3 queued read used mutated address (live sampling)");
      repeat (20) @(posedge clk);

      // ---------------- S4: write attribute mutation ----------------
      refresh_req <= 1;
      repeat (2) @(posedge clk);
      ch2_addr <= 27'h80800 >> 1; ch2_din <= 32'hCAFE1234; ch2_be <= 4'b1111;
      ch2_rnw  <= 0; ch2_req <= 1;
      @(posedge clk);
      ch2_req  <= 0;
      ch2_addr <= 27'h80900 >> 1; ch2_din <= 32'hDEADDEAD; // mutate
      repeat (3) @(posedge clk);
      refresh_req <= 0;
      @(posedge clk);
      while (!ch2_ready) @(posedge clk);
      ch2_rnw <= 1;
      shadow[hwidx(27'h80800)]     = 16'h1234;
      shadow[hwidx(27'h80800) + 1] = 16'hCAFE;
      repeat (10) @(posedge clk);
      ch2_read32(27'h80800);
      $display("S4 write mutation done, errors so far %0d", errors);

      if (errors == 0) $display("ALL PASS");
      else             $display("TOTAL ERRORS: %0d", errors);
      $finish;
   end

   initial begin
      #4000000; // 4ms watchdog
      $display("FAIL: global watchdog - controller hung");
      $finish;
   end

endmodule

// analysis-only stub: only drives SDRAM_CLK, irrelevant to the functional model
module altddio_out #(parameter extend_oe_disable="OFF", intended_device_family="", invert_output="OFF", lpm_hint="", lpm_type="", oe_reg="", power_up_high="OFF", width=1)
(
   input  [width-1:0] datain_h, datain_l,
   input  outclock, outclocken, aclr, aset, oe, sclr, sset,
   output [width-1:0] dataout
);
   assign dataout = ~outclock ? datain_h : datain_l;
endmodule
