-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pProc_bus_gba.all;
use work.gdb_tb_mailbox.all;

entity tb_gdb_core is
end entity;

architecture sim of tb_gdb_core is
   constant CLK_PERIOD : time := 10 ns;
   constant ROM_BASE   : natural := 16#08000000#;
   constant IWRAM_BASE : natural := 16#03000000#;
   constant ADD_PC     : natural := ROM_BASE + 4;
   constant STR_PC     : natural := ROM_BASE + 8;
   constant LOOP_WORD  : natural := 8;
   constant MOV_R0     : word32 := x"E3A00001";
   constant ADD_R0     : word32 := x"E2800001";
   constant STR_R0     : word32 := x"E5810000";
   constant IWRAM_SEED : word32 := x"12345678";
   constant ROM_PATCH  : word32 := x"E3A00063";
   constant STALE_SEQ  : natural := 1;

   type words is array (natural range <>) of word32;
   constant BIOS : words(0 to 3) := (
      x"E59F1000", -- ldr r1, [pc, #0]  ; IWRAM address at 0x08
      x"E59FF000", -- ldr pc, [pc, #0]  ; ROM entry at 0x0C
      x"03000000", x"08000000");
   constant ROM : words(0 to LOOP_WORD) := (
      0 => MOV_R0, 1 => ADD_R0, 2 => STR_R0,
      LOOP_WORD => x"EAFFFFFE", -- b .
      others => x"E1A00000");  -- nop

   signal clk, gba_on : std_logic := '0';
   signal gdb_reset : std_logic := '1';
   signal bios_wr : std_logic := '0';
   signal bios_addr : std_logic_vector(11 downto 0) := (others => '0');
   signal bios_data : word32 := (others => '0');

   signal host : host_write := HOST_IDLE;
   signal ddr3_req : ddr_request;
   signal ddr3_rsp : ddr_response;
   signal mbox : mailbox_words;

   signal cart_ena, cart_32, cart_rnw : std_logic;
   signal cart_addr : std_logic_vector(27 downto 0);
   signal cart_be : std_logic_vector(3 downto 0);
   signal cart_wdata : word32;
   signal cart_done : std_logic := '0';
   signal cart_rdata : word32 := (others => '0');
   signal block_loop_fetch : boolean := true;
   signal loop_fetch_pending : boolean := false;

   signal ss_bus : proc_bus_gb_type;
   signal ss_req, ss_done : std_logic;
   signal ss_data : std_logic_vector(proc_buswidth - 1 downto 0);
   signal bus_addr : std_logic_vector(27 downto 0);
   signal bus_rnw, bus_written, bus_done, memaccess, mem_ready : std_logic;
   signal bus_acc : std_logic_vector(1 downto 0);
   signal bus_wdata, bus_rdata : word32;
   signal dbg_hold, dbg_step, dbg_stop_now, dbg_reg_wr, gdb_halted : std_logic;
   signal dbg_reg_idx : std_logic_vector(4 downto 0);
   signal dbg_reg_data : word32;

   signal ce, decode_load, execute_stall, cpu_done, cpu_halt, cpu_jump : std_logic;
   signal arch_pc, fetch_pc, stall_pc : unsigned(31 downto 0);
   signal opcode, cpu_bus_addr : word32;
   signal cpu_bus_ena, cpu_bus_rnw, cpu_bus_code : std_logic;
   signal cycles, retired, jumps, stores : natural := 0;

begin
   clk <= not clk after CLK_PERIOD / 2;
   cpu_jump <= << signal .tb_gdb_core.core.cpu_jump : std_logic >>;

   mailbox : entity work.gdb_tb_ddr3 port map (clk, host, ddr3_req, ddr3_rsp, mbox);

   igdb : entity work.gba_gdb
   generic map (MAILBOX_ADDR => MB_BASE, DUAL_CORE => '0')
   port map (
      clk1x => clk, reset => gdb_reset, gdb_enable => '1',
      ddr3_request => ddr3_req.ena, ddr3_rnw => ddr3_req.rnw,
      ddr3_address => ddr3_req.addr, ddr3_burstcount => ddr3_req.burst,
      ddr3_writeMask => ddr3_req.mask, ddr3_dataWrite => ddr3_req.data,
      ddr3_granted => ddr3_rsp.granted, ddr3_done => ddr3_rsp.done,
      ddr3_dataRead => ddr3_rsp.data,
      ss_bus_out => ss_bus, ss_bus_req => ss_req,
      ss_wired_out => ss_data, ss_wired_done => ss_done,
      GBA_BusAddr => bus_addr, GBA_BusRnW => bus_rnw, GBA_BusACC => bus_acc,
      GBA_BusWriteData => bus_wdata, GBA_Bus_written => bus_written,
      GBA_BusReadData => bus_rdata, GBA_BusReadDone => bus_done,
      gdb_memaccess => memaccess, mem_dbg_ready => mem_ready,
      dbg_reg_wr => dbg_reg_wr, dbg_reg_idx => dbg_reg_idx, dbg_reg_data => dbg_reg_data,
      dbg_hold => dbg_hold, dbg_step => dbg_step, dbg_stop_now => dbg_stop_now,
      gdb_halted => gdb_halted,
      c0_ce => ce, c0_arch_pc => arch_pc, c0_fetch_instr_pc => fetch_pc,
      c0_stall_instr_pc => stall_pc, c0_decode_load => decode_load,
      c0_execute_stall => execute_stall, c0_decode_opcode => opcode,
      c0_cpu_done => cpu_done, c0_cpu_halt => cpu_halt
   );

   core : entity work.gba_top
   generic map (
      Softmap_GBA_Gamerom_ADDR => 0, Softmap_GBA_FLASH_ADDR => 0,
      Softmap_GBA_EEPROM_ADDR => 0, Softmap_SaveState_ADDR => 0, Softmap_Rewind_ADDR => 0,
      is_simu => '1', simu_export_trace => '0', strip_savestates => '1',
      strip_cheats => '1', ewram_in_sdram => '0', turbosound => '0'
   )
   port map (
      clk1x => clk, GBA_on => gba_on, pause => '0', allowUnpause => '1', inPause => open,
      GBA_lockspeed => '1', GBA_cputurbo => '0', GBA_flash_1m => '0', Underclock => "00",
      CyclesMissing => open, CyclesVsyncSpeed => open, increaseSSHeaderCount => '0',
      save_state => '0', load_state => '0', interframe_blend => "00", shade_mode => "000",
      rewind_on => '0', rewind_active => '0', savestate_number => 0,
      error_cpu => open, error_memRequ_timeout => open, error_memResp_timeout => open,
      flash_busy => '0', cheat_clear => '0', cheats_enabled => '0', cheat_on => '0',
      cheat_in => (others => '0'), cheats_active => open,
      cart_ena => cart_ena, cart_idle => open, cart_32 => cart_32,
      cart_rnw => cart_rnw, cart_addr => cart_addr, cart_writedata32 => cart_wdata,
      cart_be32 => cart_be, cart_done => cart_done, cart_readdata => cart_rdata,
      cart_waitcnt => open, dma_eepromcount => open, cart_reset => open,
      SAVE_out_Din => open, SAVE_out_Dout => (others => '0'), SAVE_out_Adr => open,
      SAVE_out_rnw => open, SAVE_out_ena => open, SAVE_out_active => open,
      SAVE_out_be => open, SAVE_out_done => '0', savestate_bus_ext => open,
      ss_wired_done_ext => '0', bios_wraddr => bios_addr, bios_wrdata => bios_data,
      bios_wr => bios_wr, load_done => open,
      KeyA => '0', KeyB => '0', KeySelect => '0', KeyStart => '0', KeyRight => '0',
      KeyLeft => '0', KeyUp => '0', KeyDown => '0', KeyR => '0', KeyL => '0', KeyPause => '0',
      GBA_BusAddr => bus_addr, GBA_BusRnW => bus_rnw, GBA_BusACC => bus_acc,
      GBA_BusWriteData => bus_wdata, GBA_Bus_written => bus_written,
      GBA_BusReadData => bus_rdata, GBA_BusReadDone => bus_done,
      pixel_out_x => open, pixel_out_y => open, pixel_out_addr => open,
      pixel_out_data => open, pixel_out_we => open, vblank_trigger => open,
      debug_cpu_pc => open, debug_cpu_mixed => open, debug_irq => open,
      debug_dma => open, debug_mem => open,
      dbg_hold => dbg_hold, dbg_step => dbg_step, dbg_stop_now => dbg_stop_now,
      gdb_memaccess => memaccess, dbg_mem_ready => mem_ready,
      dbg_reg_wr => dbg_reg_wr, dbg_reg_idx => dbg_reg_idx, dbg_reg_data => dbg_reg_data,
      ss_bus_gdb_req => ss_req, ss_bus_gdb_in => ss_bus,
      ss_wired_out_dbg => ss_data, ss_wired_done_dbg => ss_done,
      dbg_ce => ce, dbg_arch_pc => arch_pc, dbg_fetch_instr_pc => fetch_pc,
      dbg_stall_instr_pc => stall_pc, dbg_decode_load => decode_load,
      dbg_execute_stall => execute_stall, dbg_decode_opcode => opcode,
      dbg_cpu_done => cpu_done, dbg_cpu_halt => cpu_halt,
      dbg_cpu_bus_adr => cpu_bus_addr, dbg_cpu_bus_ena => cpu_bus_ena,
      dbg_cpu_bus_rnw => cpu_bus_rnw, dbg_cpu_bus_code => cpu_bus_code
   );

   -- The only core-side model is the physical cartridge interface. Hold the
   -- last instruction fetch to make a running, non-branching CPU reproducible.
   cart : process (clk)
      variable image : words(ROM'range) := ROM;
      variable idx : natural;
   begin
      if rising_edge(clk) then
         cart_done <= '0';
         if loop_fetch_pending then
            assert cart_ena = '0' report "second cart request before response" severity failure;
            if not block_loop_fetch then
               loop_fetch_pending <= false;
               cart_rdata <= image(LOOP_WORD);
               cart_done <= '1';
            end if;
         elsif cart_ena = '1' then
            assert unsigned(cart_addr) >= ROM_BASE and cart_32 = '1'
               report "unexpected cart address or non-ARM transfer" severity failure;
            idx := (to_integer(unsigned(cart_addr)) - ROM_BASE) / 4;
            if cart_rnw = '1' then
               if idx = LOOP_WORD and block_loop_fetch then
                  loop_fetch_pending <= true;
               else
                  if idx <= image'high then
                     cart_rdata <= image(idx);
                  else
                     cart_rdata <= x"E1A00000";
                  end if;
                  cart_done <= '1';
               end if;
            else
               assert idx <= image'high and memaccess = '1' and cart_be = "1111"
                  report "unexpected cart write" severity failure;
               image(idx) := cart_wdata;
               cart_done <= '1';
            end if;
         end if;
      end if;
   end process;

   monitor : process (clk)
   begin
      if rising_edge(clk) then
         if gdb_reset = '0' and ce = '1' then
            cycles <= cycles + 1;
            if cpu_done = '1' then retired <= retired + 1; end if;
            if cpu_jump = '1' then jumps <= jumps + 1; end if;
            if cpu_bus_ena = '1' and cpu_bus_rnw = '0' and cpu_bus_code = '0' and
               cpu_bus_addr = u32(IWRAM_BASE) then
               stores <= stores + 1;
            end if;
         end if;
      end if;
   end process;

   stimulus : process
      variable seq : natural := STALE_SEQ;
      variable before_retired, before_cycles, before_jumps, halt_pc : natural;
      procedure post(op : natural; arg, adr, len : natural := 0) is
      begin
         seq := seq + 1;
         post_cmd(clk, host, op, seq, arg, adr, len);
      end procedure;
      procedure send(op : natural; arg, adr, len : natural := 0) is
      begin
         post(op, arg, adr, len);
         await_ack(clk, mbox, seq);
      end procedure;
      procedure stop_at(reason, pc : natural; slot : natural := 0) is
      begin
         await_stop(clk, mbox, reason, slot);
         assert mbox(OFF_STATE)(63 downto 32) = u32(pc) and arch_pc = pc and
                gdb_halted = '1' and ce = '0'
            report "core did not stop at PC " & to_hstring(u32(pc)) &
                   "; STATE=" & to_hstring(mbox(OFF_STATE)) severity failure;
      end procedure;
      procedure read_regs(r0, pc : natural) is
      begin
         send(CMD_RDREGS);
         assert data_word(mbox, 0) = u32(r0) and data_word(mbox, 15) = u32(pc)
            report "unexpected live r0=" & to_hstring(data_word(mbox, 0)) &
                   " r15=" & to_hstring(data_word(mbox, 15)) severity failure;
      end procedure;
      procedure read_mem(adr : natural; expected : word32) is
      begin
         send(CMD_RDMEM, adr => adr, len => 4);
         assert data_word(mbox, 0) = expected
            report "bad memory read at " & to_hstring(u32(adr)) & ": " &
                   to_hstring(data_word(mbox, 0)) severity failure;
      end procedure;
      procedure write_mem(adr : natural; data : word32) is
      begin
         put_word(clk, host, OFF_DATA, x"00000000" & data);
         send(CMD_WRMEM, adr => adr, len => 4);
      end procedure;
   begin
      ticks(clk);
      for i in BIOS'range loop
         bios_wr <= '1';
         bios_addr <= std_logic_vector(to_unsigned(i, bios_addr'length));
         bios_data <= BIOS(i);
         ticks(clk);
      end loop;
      bios_wr <= '0';
      put_word(clk, host, OFF_CMD, command_word(CMD_CONT, STALE_SEQ, 0));
      gdb_reset <= '0';
      await_ack(clk, mbox, STALE_SEQ);

      -- Arm the first instruction before power-on so mailbox polling cannot
      -- race the short BIOS stub or the first ARM instructions.
      send(CMD_SETBP, 16#10#, ROM_BASE);
      gba_on <= '1';
      stop_at(STOP_BP, ROM_BASE);
      assert opcode = MOV_R0 report "boot did not decode the first ROM instruction" severity failure;
      read_regs(0, ROM_BASE);
      assert data_word(mbox, 1) = u32(IWRAM_BASE) report "BIOS did not initialize r1" severity failure;

      before_retired := retired;
      send(CMD_STEP, 1);
      stop_at(STOP_STEP, ADD_PC);
      assert retired = before_retired + 1 and opcode = ADD_R0
         report "STEP did not retire exactly MOV and stop at ADD" severity failure;
      read_regs(1, ADD_PC);

      before_cycles := cycles;
      write_mem(IWRAM_BASE, IWRAM_SEED);
      read_mem(IWRAM_BASE, IWRAM_SEED);
      read_mem(ROM_BASE, MOV_R0);
      write_mem(ROM_BASE, ROM_PATCH);
      read_mem(ROM_BASE, ROM_PATCH);
      assert cycles = before_cycles and unsigned(mbox(OFF_CYCLES)) = before_cycles
         report "halted IWRAM or ROM access clocked the core" severity failure;

      send(CMD_WRREG, 41, 0);
      read_regs(41, ADD_PC);
      send(CMD_SETBP, 16#11#, STR_PC);
      before_retired := retired;
      send(CMD_CONT);
      stop_at(STOP_BP, STR_PC, 1);
      assert retired = before_retired + 1 and opcode = STR_R0 and stores = 0
         report "STR breakpoint did not stop before the store executed" severity failure;
      read_regs(42, STR_PC); -- ADD must have used r0 written by WRREG.
      read_mem(IWRAM_BASE, IWRAM_SEED);

      send(CMD_CONT);
      for i in 1 to 512 loop
         exit when loop_fetch_pending;
         ticks(clk);
      end loop;
      ticks(clk, 8);
      assert loop_fetch_pending and cpu_jump = '0' and ce = '1' and stores = 1 and mem_ready = '0'
         report "running core did not stall after its one STR" severity failure;
      before_jumps := jumps;
      before_retired := retired;
      halt_pc := to_integer(arch_pc);
      send(CMD_HALT);
      stop_at(STOP_HOST, halt_pc);
      before_cycles := cycles;
      ticks(clk, 16);
      assert loop_fetch_pending and cpu_jump = '0' and jumps = before_jumps and
             retired = before_retired and cycles = before_cycles
         report "host halt waited for a jump or failed to freeze the core" severity failure;
      read_regs(42, halt_pc);

      -- While frozen, a real outstanding cart fetch must drain before the
      -- memory mux can switch to the debugger. No CPU cycle is needed to do so.
      post(CMD_RDMEM, adr => IWRAM_BASE, len => 4);
      ticks(clk, 160);
      assert mbox(OFF_ACK) = ok_ack(seq - 1) and memaccess = '0' and mem_ready = '0'
         report "debug memory request did not wait for the suspended cart fetch" severity failure;
      block_loop_fetch <= false;
      await_ack(clk, mbox, seq);
      assert data_word(mbox, 0) = u32(42) and cycles = before_cycles
         report "resumed STR did not store the debugger-written/updated r0" severity failure;

      send(CMD_STEP_CYCLES, 1);
      await_stop(clk, mbox, STOP_STEP_CYCLE);
      assert cycles = before_cycles + 1 and unsigned(mbox(OFF_CYCLES)) = before_cycles + 1 and
             ce = '0' and gdb_halted = '1'
         report "single-cycle step did not advance total_cycles by exactly one" severity failure;
      report "ALL FULL-CORE GDB TESTS PASSED";
      std.env.finish;
   end process;
end architecture;
