library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Shared by the engine-only and full-core benches. Mailbox indices are qwords;
-- the simulated DDR3 master still uses the byte addresses from gdb_proto.h.
package gdb_tb_mailbox is
   constant MB_BASE    : natural := 16#C800000#;
   constant OFF_CMD    : natural := 16#000# / 8;
   constant OFF_ADDR   : natural := 16#008# / 8;
   constant OFF_LEN    : natural := 16#010# / 8;
   constant OFF_ACK    : natural := 16#018# / 8;
   constant OFF_STATE  : natural := 16#020# / 8;
   constant OFF_CYCLES : natural := 16#028# / 8;
   constant OFF_DATA   : natural := 16#100# / 8;

   constant CMD_HALT        : natural := 1;
   constant CMD_CONT        : natural := 2;
   constant CMD_STEP        : natural := 3;
   constant CMD_RDMEM       : natural := 4;
   constant CMD_WRMEM       : natural := 5;
   constant CMD_RDREGS      : natural := 6;
   constant CMD_WRREG       : natural := 7;
   constant CMD_SETBP       : natural := 8;
   constant CMD_SETWP       : natural := 9;
   constant CMD_STEP_CYCLES : natural := 10;
   constant CMD_STEP_FRAMES : natural := 11;
   constant CMD_STEP_LINE   : natural := 12;
   constant CMD_BREAK_CYCLE : natural := 13;
   constant CMD_BREAK_EVENT : natural := 14;
   constant CMD_RDSTATE     : natural := 15;
   constant CMD_SET_CORE    : natural := 16;
   constant CMD_SET_INPUT   : natural := 17;
   constant CMD_RESET       : natural := 18;
   constant CMD_RD_TRACE    : natural := 19;

   constant STOP_HOST        : natural := 1;
   constant STOP_BP          : natural := 2;
   constant STOP_STEP        : natural := 3;
   constant STOP_WP          : natural := 4;
   constant STOP_STEP_CYCLE  : natural := 5;
   constant STOP_STEP_FRAME  : natural := 6;
   constant STOP_STEP_LINE   : natural := 7;
   constant STOP_BREAK_CYCLE : natural := 8;
   constant STOP_BREAK_EVENT : natural := 9;
   constant STOP_RESET_HALT  : natural := 10;

   subtype word32 is std_logic_vector(31 downto 0);
   subtype qword is std_logic_vector(63 downto 0);
   subtype mailbox_index is natural range 0 to OFF_DATA + 4096 / 8 - 1;
   type mailbox_words is array (mailbox_index) of qword;
   type host_write is record
      ena : boolean;
      idx : mailbox_index;
      data : qword;
   end record;
   constant HOST_IDLE : host_write := (false, 0, (others => '0'));
   type ddr_request is record
      ena, rnw : std_logic;
      addr : unsigned(27 downto 0);
      burst : unsigned(9 downto 0);
      mask : std_logic_vector(7 downto 0);
      data : qword;
   end record;
   type ddr_response is record
      granted, done : std_logic;
      data : qword;
   end record;

   function u32(n : natural) return word32;
   function u64(n : natural) return qword;
   function command_word(op, seq, arg : natural) return qword;
   function ok_ack(seq : natural) return qword;
   function data_word(mbox : mailbox_words; idx : natural) return word32;
   procedure ticks(signal clk : in std_logic; n : natural := 1);
   procedure put_word(signal clk : in std_logic; signal host : out host_write;
                      idx : mailbox_index; data : qword);
   procedure post_cmd(signal clk : in std_logic; signal host : out host_write;
                      op, seq : natural; arg, adr, len : natural := 0);
   procedure await_ack(signal clk : in std_logic; signal mbox : in mailbox_words;
                       seq : natural; status : natural := 0);
   procedure await_stop(signal clk : in std_logic; signal mbox : in mailbox_words;
                        reason : natural; slot : natural := 0);
end package;

package body gdb_tb_mailbox is
   function u32(n : natural) return word32 is
   begin
      return std_logic_vector(to_unsigned(n, 32));
   end function;

   function u64(n : natural) return qword is
   begin
      return std_logic_vector(to_unsigned(n, 64));
   end function;

   function command_word(op, seq, arg : natural) return qword is
   begin
      return u32(arg) & x"0000" & std_logic_vector(to_unsigned(seq, 8)) &
             std_logic_vector(to_unsigned(op, 8));
   end function;

   function ok_ack(seq : natural) return qword is
   begin
      return x"47424432000200" & std_logic_vector(to_unsigned(seq, 8));
   end function;

   function data_word(mbox : mailbox_words; idx : natural) return word32 is
   begin
      if idx mod 2 = 0 then
         return mbox(OFF_DATA + idx / 2)(31 downto 0);
      end if;
      return mbox(OFF_DATA + idx / 2)(63 downto 32);
   end function;

   procedure ticks(signal clk : in std_logic; n : natural := 1) is
   begin
      for i in 1 to n loop
         wait until falling_edge(clk);
      end loop;
   end procedure;

   procedure put_word(signal clk : in std_logic; signal host : out host_write;
                      idx : mailbox_index; data : qword) is
   begin
      host <= (true, idx, data);
      ticks(clk);
      host <= HOST_IDLE;
   end procedure;

   procedure post_cmd(signal clk : in std_logic; signal host : out host_write;
                      op, seq : natural; arg, adr, len : natural := 0) is
   begin
      put_word(clk, host, OFF_ADDR, u64(adr));
      put_word(clk, host, OFF_LEN, u64(len));
      put_word(clk, host, OFF_CMD, command_word(op, seq, arg));
   end procedure;

   procedure await_ack(signal clk : in std_logic; signal mbox : in mailbox_words;
                       seq : natural; status : natural := 0) is
      variable expected : qword := ok_ack(seq);
   begin
      expected(15 downto 8) := std_logic_vector(to_unsigned(status, 8));
      for i in 0 to 8192 loop
         if mbox(OFF_ACK)(7 downto 0) = std_logic_vector(to_unsigned(seq, 8)) then
            assert mbox(OFF_ACK) = expected
               report "unexpected ACK: " & to_hstring(mbox(OFF_ACK)) severity failure;
            return;
         end if;
         ticks(clk);
      end loop;
      assert false report "mailbox ACK timed out for seq " & natural'image(seq) severity failure;
   end procedure;

   procedure await_stop(signal clk : in std_logic; signal mbox : in mailbox_words;
                        reason : natural; slot : natural := 0) is
   begin
      for i in 0 to 8192 loop
         if mbox(OFF_STATE)(0) = '1' then
            assert unsigned(mbox(OFF_STATE)(7 downto 4)) = reason and
                   unsigned(mbox(OFF_STATE)(11 downto 8)) = slot
               report "unexpected stop: " & to_hstring(mbox(OFF_STATE)) severity failure;
            return;
         end if;
         ticks(clk);
      end loop;
      assert false report "debug stop timed out for reason " & natural'image(reason) severity failure;
   end procedure;
end package body;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.gdb_tb_mailbox.all;

entity gdb_tb_ddr3 is
   port (
      clk  : in std_logic;
      host : in host_write;
      req  : in ddr_request;
      rsp  : out ddr_response := ('0', '0', (others => '0'));
      mbox : out mailbox_words := (others => (others => '0'))
   );
end entity;

architecture sim of gdb_tb_ddr3 is
begin
   process (clk)
      variable lat : natural := 0;
      variable idx : mailbox_index := 0;
      variable txn : ddr_request;
   begin
      if rising_edge(clk) then
         rsp.granted <= '0';
         rsp.done <= '0';
         if host.ena then
            mbox(host.idx) <= host.data;
         end if;
         if req.ena = '1' then
            assert lat = 0 and req.burst = 1 and req.addr(2 downto 0) = 0 and
                   req.addr >= MB_BASE and req.addr < MB_BASE + 8 * mbox'length
               report "invalid DDR3 mailbox request" severity failure;
            idx := (to_integer(req.addr) - MB_BASE) / 8;
            txn := req;
            lat := 3;
            rsp.granted <= req.rnw;
         elsif lat /= 0 then
            lat := lat - 1;
            if lat = 0 then
               if txn.rnw = '1' then
                  rsp.data <= mbox(idx);
               else
                  assert txn.mask = x"FF" report "partial DDR3 mailbox write" severity failure;
                  mbox(idx) <= txn.data;
               end if;
               rsp.done <= '1';
            end if;
         end if;
      end if;
   end process;
end architecture;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.pProc_bus_gba.all;
use work.gdb_tb_mailbox.all;

entity tb_gdb is
end entity;

architecture sim of tb_gdb is
   constant CLK_PERIOD : time := 10 ns;
   constant MEM_BASE   : natural := 16#03000000#;
   constant ROM_BASE   : natural := 16#08000000#;
   constant BP_PC      : natural := ROM_BASE + 16#100#;
   constant STALE_SEQ  : natural := 16#A5#;
   constant SENTINEL   : qword := x"123456789ABCDEF0";
   constant IRQ_FLAGS  : std_logic_vector(15 downto 0) := x"2468";

   signal clk, reset : std_logic := '0';
   signal host : host_write := HOST_IDLE;
   signal ddr3_req : ddr_request;
   signal ddr3_rsp : ddr_response;
   signal mbox : mailbox_words;

   signal ss_bus : proc_bus_gb_type;
   signal ss_req, ss_done : std_logic;
   signal ss_data : word32;
   signal bus_addr : std_logic_vector(27 downto 0);
   signal bus_rnw, bus_written, bus_done, memaccess : std_logic := '0';
   signal bus_acc : std_logic_vector(1 downto 0);
   signal bus_wdata, bus_rdata : word32 := (others => '0');
   signal mem_ready : std_logic := '1';
   signal mem_reads, mem_writes : natural := 0;

   signal dbg_hold, dbg_step, dbg_stop_now, dbg_reset_req, gdb_halted : std_logic;
   signal dbg_reg_wr, active_core : std_logic;
   signal dbg_reg_idx : std_logic_vector(4 downto 0);
   signal dbg_reg_data : word32;
   signal mask0, val0, mask1, val1 : std_logic_vector(9 downto 0);
   signal cycle_count, insn_count, step_pulses, reg_pulses, reset_ticks : natural := 0;
   signal ce, decode_load, cpu_done : std_logic := '0';
   signal arch_pc, fetch_pc : unsigned(31 downto 0) := to_unsigned(ROM_BASE, 32);
   signal cpu_bus_addr : word32 := (others => '0');
   signal cpu_bus_ena, cpu_bus_code : std_logic := '0';
   signal cpu_bus_rnw : std_logic := '1';
   signal vblank, hblank, line_trigger, dma_on : std_logic := '0';
   signal dispstat : word32 := x"002A0040";

   signal r0 : word32 := x"00001000";

   function ss_word(adr, core : natural) return word32 is
   begin
      if adr >= 1 and adr <= 16 then
         return u32(16#1000# + adr - 1 + core * 16#100#);
      elsif adr = 17 then
         return x"6000001F";
      else
         return u32(16#20000000# + adr + core * 16#100#);
      end if;
   end function;
begin
   clk <= not clk after CLK_PERIOD / 2;

   mailbox : entity work.gdb_tb_ddr3 port map (clk, host, ddr3_req, ddr3_rsp, mbox);

   igdb : entity work.gba_gdb
   generic map (MAILBOX_ADDR => MB_BASE, BP_COUNT => 2, WP_COUNT => 1, DUAL_CORE => '1')
   port map (
      clk1x => clk, reset => reset, gdb_enable => '1',
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
      dbg_reset_req => dbg_reset_req, gdb_halted => gdb_halted, active_core_out => active_core,
      joy_ov_mask_c0 => mask0, joy_ov_val_c0 => val0,
      joy_ov_mask_c1 => mask1, joy_ov_val_c1 => val1,
      c0_ce => ce, c0_arch_pc => arch_pc, c0_fetch_instr_pc => fetch_pc,
      c0_stall_instr_pc => x"0800A000", c0_decode_opcode => x"E3A00001",
      c0_decode_load => decode_load, c0_cpu_done => cpu_done,
      c0_cpu_bus_adr => cpu_bus_addr, c0_cpu_bus_ena => cpu_bus_ena,
      c0_cpu_bus_rnw => cpu_bus_rnw, c0_cpu_bus_code => cpu_bus_code,
      c0_dma_on => dma_on, c0_vblank => vblank, c0_hblank => hblank,
      c0_line_trigger => line_trigger, c0_dispstat => dispstat, c0_irq_if => IRQ_FLAGS,
      c1_arch_pc => x"08001234", c1_fetch_instr_pc => x"08001238",
      wireless_debug_state => x"AB"
   );

   ss_done <= ss_req and ss_bus.ena;
   process (all)
      variable adr : natural;
   begin
      ss_data <= (others => '0');
      if ss_req = '1' and ss_bus.ena = '1' then
         adr := to_integer(unsigned(ss_bus.Adr));
         if active_core = '1' then
            ss_data <= ss_word(adr, 1);
         elsif adr = 1 then
            ss_data <= r0;
         else
            ss_data <= ss_word(adr, 0);
         end if;
      end if;
   end process;

   -- Registered CE: a stop edge still loads Decode but admits no following
   -- Execute edge. Stimulus controls the CPU strobes independently of CE.
   process (clk)
   begin
      if rising_edge(clk) then
         if reset = '1' or dbg_hold = '1' or dbg_stop_now = '1' then
            ce <= dbg_step and not reset;
         else
            ce <= '1';
         end if;
         if ce = '1' and reset = '0' then
            cycle_count <= cycle_count + 1;
            if decode_load = '1' then arch_pc <= fetch_pc; end if;
            if cpu_done = '1' then insn_count <= insn_count + 1; end if;
         end if;
         if dbg_step = '1' then
            assert dbg_hold = '1' report "single-cycle pulse released hold" severity failure;
            step_pulses <= step_pulses + 1;
         end if;
         if dbg_reset_req = '1' then
            assert dbg_hold = '1' report "reset did not hold CPU" severity failure;
            reset_ticks <= reset_ticks + 1;
         end if;
         if dbg_reg_wr = '1' then
            assert dbg_hold = '1' and dbg_reg_idx = "00000"
               report "invalid live register write" severity failure;
            r0 <= dbg_reg_data;
            reg_pulses <= reg_pulses + 1;
         end if;
      end if;
   end process;

   process (clk)
      type words is array (0 to 15) of word32;
      variable ram : words := (others => x"CAFEF00D");
      variable delay_left : natural := 0;
      variable rd, access_prev : std_logic := '0';
      variable idx : natural := 0;
      variable data : word32;
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if bus_written = '1' then
            assert access_prev = '1' and memaccess = '1' and mem_ready = '1' and
                   bus_acc = ACCESS_32BIT and delay_left = 0
               report "debug bus request without ready/entry cycle" severity failure;
            assert unsigned(bus_addr) >= MEM_BASE and unsigned(bus_addr) < MEM_BASE + 64
               report "debug bus address out of bounds" severity failure;
            delay_left := 3;
            idx := (to_integer(unsigned(bus_addr)) - MEM_BASE) / 4;
            rd := bus_rnw;
            data := bus_wdata;
         elsif delay_left /= 0 then
            delay_left := delay_left - 1;
            if delay_left = 0 then
               assert memaccess = '1' report "debug access ended before bus done" severity failure;
               if rd = '1' then
                  bus_rdata <= ram(idx);
                  mem_reads <= mem_reads + 1;
               else
                  ram(idx) := data;
                  mem_writes <= mem_writes + 1;
               end if;
               bus_done <= '1';
            end if;
         end if;
         access_prev := memaccess;
      end if;
   end process;

   stimulus : process
      variable seq : natural := STALE_SEQ;
      variable before_cycles, before_insns, before_reads : natural;
      variable trace_entry : qword;
      procedure post(op : natural; arg, adr, len : natural := 0) is
      begin
         seq := seq + 1;
         post_cmd(clk, host, op, seq, arg, adr, len);
      end procedure;
      procedure send(op : natural; arg, adr, len : natural := 0; status : natural := 0) is
      begin
         post(op, arg, adr, len);
         await_ack(clk, mbox, seq, status);
      end procedure;
      procedure stop_at(reason, pc : natural; slot : natural := 0) is
      begin
         await_stop(clk, mbox, reason, slot);
         assert mbox(OFF_STATE)(63 downto 32) = u32(pc) and
                arch_pc = pc and gdb_halted = '1' and ce = '0'
            report "stop did not freeze at architectural PC " & to_hstring(u32(pc)) severity failure;
      end procedure;
      procedure retire is
      begin
         cpu_done <= '1';
         ticks(clk);
         cpu_done <= '0';
      end procedure;
      procedure decode(pc : natural; expect_stop : boolean) is
      begin
         fetch_pc <= to_unsigned(pc, 32);
         decode_load <= '1';
         wait for CLK_PERIOD / 4;
         assert (dbg_stop_now = '1') = expect_stop and gdb_halted = '0' and ce = '1'
            report "wrong combinational stop at Decode" severity failure;
         ticks(clk);
         decode_load <= '0';
         assert (ce = '0') = expect_stop
            report "Decode stop did not prevent the subsequent Execute edge" severity failure;
      end procedure;
      procedure poison_data(n : natural) is
      begin
         for i in 0 to n loop
            put_word(clk, host, OFF_DATA + i, SENTINEL);
         end loop;
      end procedure;
   begin
      reset <= '1';
      ticks(clk);
      put_word(clk, host, OFF_CMD, command_word(CMD_HALT, STALE_SEQ, 0));
      reset <= '0';
      await_ack(clk, mbox, STALE_SEQ);
      -- Span a full running poll so stale HALT would be observed.
      ticks(clk, 4200);
      assert gdb_halted = '0' and ce = '1' and mbox(OFF_STATE)(2 downto 0) = "100"
         report "INIT_SYNC executed stale OFF_CMD or published wrong mode" severity failure;
      decode(ROM_BASE, false);

      send(CMD_HALT);
      stop_at(STOP_HOST, ROM_BASE);
      before_cycles := cycle_count;
      ticks(clk, 10);
      assert cycle_count = before_cycles and unsigned(mbox(OFF_CYCLES)) = before_cycles
         report "host halt did not freeze cycles" severity failure;

      send(CMD_RDREGS);
      for i in 0 to 16 loop
         if i = 15 then
            assert data_word(mbox, i) = u32(ROM_BASE) report "r15 was not true arch_pc" severity failure;
         else
            assert data_word(mbox, i) = ss_word(i + 1, 0)
               report "RDREGS mismatch at slot " & natural'image(i) severity failure;
         end if;
      end loop;
      send(CMD_WRREG, 16#5EADBEEF#);
      assert reg_pulses = 1 and r0 = x"5EADBEEF" report "WRREG pulse/value mismatch" severity failure;
      send(CMD_RDREGS);
      assert data_word(mbox, 0) = x"5EADBEEF" and reg_pulses = 1
         report "live register write did not persist or pulsed again" severity failure;

      put_word(clk, host, OFF_DATA, x"5566778811223344");
      mem_ready <= '0';
      post(CMD_WRMEM, adr => MEM_BASE, len => 8);
      ticks(clk, 200);
      assert mbox(OFF_ACK) = ok_ack(seq - 1) and memaccess = '0' and mem_writes = 0
         report "WRMEM did not wait for mem_dbg_ready" severity failure;
      mem_ready <= '1';
      await_ack(clk, mbox, seq);
      assert mem_writes = 2 and mem_reads = 0 report "whole write used unexpected bus cycles" severity failure;

      mem_ready <= '0';
      post(CMD_RDMEM, adr => MEM_BASE, len => 8);
      ticks(clk, 200);
      assert mbox(OFF_ACK) = ok_ack(seq - 1) and memaccess = '0' and mem_reads = 0
         report "RDMEM did not wait for mem_dbg_ready" severity failure;
      mem_ready <= '1';
      await_ack(clk, mbox, seq);
      assert mbox(OFF_DATA) = x"5566778811223344" report "whole readback mismatch" severity failure;

      before_reads := mem_reads;
      put_word(clk, host, OFF_DATA, x"0000EEFFAABBCCDD");
      send(CMD_WRMEM, adr => MEM_BASE + 8, len => 6);
      assert mem_reads = before_reads + 1 and mem_writes = 4
         report "ragged write did not RMW only the tail" severity failure;
      put_word(clk, host, OFF_DATA + 1, SENTINEL);
      send(CMD_RDMEM, adr => MEM_BASE + 8, len => 9);
      assert mbox(OFF_DATA) = x"CAFEEEFFAABBCCDD" and mbox(OFF_DATA + 1) = x"00000000CAFEF00D"
         report "ragged RMW/odd-word readback mismatch" severity failure;
      assert cycle_count = before_cycles report "debug memory commands ran the core" severity failure;

      send(CMD_STEP_CYCLES, 1);
      stop_at(STOP_STEP_CYCLE, ROM_BASE);
      assert step_pulses = 1 and cycle_count = before_cycles + 1 and
             unsigned(mbox(OFF_CYCLES)) = before_cycles + 1
         report "N=1 did not inject one cycle" severity failure;
      send(CMD_STEP_CYCLES, 5);
      stop_at(STOP_STEP_CYCLE, ROM_BASE);
      assert step_pulses = 1 and cycle_count = before_cycles + 6 and
             unsigned(mbox(OFF_CYCLES)) = before_cycles + 6
         report "N=5 countdown was not exact" severity failure;

      before_insns := insn_count;
      send(CMD_STEP);
      retire;
      ticks(clk, 3);
      assert gdb_halted = '0' and dbg_stop_now = '0' and insn_count = before_insns + 1
         report "step must retire once and wait for Decode" severity failure;
      decode(ROM_BASE + 4, true);
      stop_at(STOP_STEP, ROM_BASE + 4);

      send(CMD_SETBP, 16#12#, BP_PC + 4, status => 3);
      send(CMD_SETBP, 16#11#, BP_PC);
      fetch_pc <= to_unsigned(BP_PC, 32);
      send(CMD_CONT);
      assert gdb_halted = '0' and dbg_stop_now = '0'
         report "fetch match without Decode incorrectly stopped" severity failure;
      decode(BP_PC, true);
      retire; -- would be the Execute edge if the comparator failed to stop CE
      stop_at(STOP_BP, BP_PC, 1);
      assert insn_count = before_insns + 1 report "breakpoint instruction executed" severity failure;

      send(CMD_STEP, 1);
      retire;
      decode(BP_PC + 4, true);
      stop_at(STOP_STEP, BP_PC + 4);
      assert insn_count = before_insns + 2 report "step-off re-triggered breakpoint" severity failure;
      send(CMD_SETBP, 1, BP_PC);
      send(CMD_CONT);
      decode(BP_PC, false);
      retire;
      send(CMD_HALT);
      stop_at(STOP_HOST, BP_PC);
      assert insn_count = before_insns + 3 report "disarmed breakpoint prevented execution" severity failure;

      poison_data(65);
      send(CMD_RD_TRACE);
      assert mbox(OFF_DATA) = u64(16#0303#) report "trace head count/pointer mismatch" severity failure;
      for i in 1 to 3 loop
         trace_entry := mbox(OFF_DATA + i);
         assert trace_entry(63 downto 40) = IRQ_FLAGS & x"2A" and
                trace_entry(39 downto 32) /= x"00"
            report "trace context/delta mismatch" severity failure;
         if i = 1 then
            assert trace_entry(39 downto 32) = x"FF" and trace_entry(31 downto 0) = u32(ROM_BASE)
               report "first retirement PC or saturated delta mismatch" severity failure;
         else
            assert trace_entry(31 downto 0) = u32(BP_PC)
               report "trace did not report retired PC in order" severity failure;
         end if;
      end loop;
      for i in 4 to 64 loop
         assert mbox(OFF_DATA + i) = u64(0) report "unused trace entry not cleared" severity failure;
      end loop;
      assert mbox(OFF_DATA + 65) = SENTINEL report "trace exceeded 65 qwords" severity failure;

      send(CMD_SETWP, 16#31#, MEM_BASE + 4, status => 3);
      send(CMD_SETWP, 16#30#, MEM_BASE);
      send(CMD_CONT);
      cpu_bus_addr <= u32(MEM_BASE + 2);
      cpu_bus_code <= '1';
      cpu_bus_ena <= '1';
      ticks(clk, 3);
      assert gdb_halted = '0' and dbg_stop_now = '0' report "watchpoint matched a fetch" severity failure;
      cpu_bus_code <= '0';
      cpu_bus_rnw <= '0';
      ticks(clk, 3);
      assert gdb_halted = '0' and dbg_stop_now = '0' report "read watchpoint matched a write" severity failure;
      cpu_bus_rnw <= '1';
      ticks(clk);
      cpu_bus_ena <= '0';
      cpu_bus_addr <= u32(MEM_BASE + 16);
      stop_at(STOP_WP, BP_PC, 0);

      send(CMD_SET_INPUT, 16#03150101#);
      send(CMD_SET_CORE, 1);
      assert active_core = '1' and mbox(OFF_STATE)(2 downto 0) = "111" and mbox(OFF_STATE)(12) = '0'
         report "core select also changed stop core or was not published" severity failure;
      send(CMD_SET_INPUT, 16#020A0202#);
      assert unsigned(mask0) = 16#315# and unsigned(val0) = 16#101# and
             unsigned(mask1) = 16#20A# and unsigned(val1) = 16#202#
         report "2P input masks/values not independent" severity failure;
      send(CMD_RDREGS);
      assert data_word(mbox, 0) = x"00001100" and data_word(mbox, 15) = x"08001234"
         report "RDREGS did not follow selected core" severity failure;

      poison_data(51);
      send(CMD_RDSTATE);
      assert mbox(OFF_DATA) = mbox(OFF_STATE) and mbox(OFF_DATA + 1) = mbox(OFF_CYCLES) and
             mbox(OFF_DATA + 2) = u64(before_insns + 3) and mbox(OFF_DATA + 3) = u64(0) and
             mbox(OFF_DATA + 4) = u32(MEM_BASE + 2) & u32(0)
         report "state header/counters/latched watch address mismatch" severity failure;
      assert mbox(OFF_DATA + 5) = u32(BP_PC) & u32(BP_PC) and
             mbox(OFF_DATA + 6) = x"E3A000010800A000" and
             mbox(OFF_DATA + 7) = dispstat & u32(MEM_BASE + 16) and
             mbox(OFF_DATA + 8) = x"000000000000" & IRQ_FLAGS and
             mbox(OFF_DATA + 9) = u64(0) and
             mbox(OFF_DATA + 10) = x"02AC008000000000"
         report "core 0 telemetry mismatch" severity failure;
      assert mbox(OFF_DATA + 11) = x"0800123808001234" report "core 1 PC telemetry mismatch" severity failure;
      for i in 12 to 16 loop
         assert mbox(OFF_DATA + i) = u64(0) report "core 1 telemetry mismatch" severity failure;
      end loop;
      for i in 0 to 33 loop
         assert mbox(OFF_DATA + 17 + i) = ss_word(2 * i + 1, 1) & ss_word(2 * i, 1)
            report "RDSTATE savestate pair mismatch at " & natural'image(i) severity failure;
      end loop;
      assert mbox(OFF_DATA + 51) = SENTINEL report "state exceeded 51 qwords" severity failure;
      send(CMD_SET_CORE);
      send(CMD_SET_INPUT);
      assert active_core = '0' and unsigned(mask0) = 0 and unsigned(val0) = 0 and unsigned(mask1) = 16#20A#
         report "clearing core 0 override affected core 1" severity failure;

      send(CMD_STEP_FRAMES, 2);
      vblank <= '1';
      ticks(clk);
      vblank <= '0';
      ticks(clk, 2);
      assert gdb_halted = '0' report "frame-step stopped after first VBlank" severity failure;
      vblank <= '1';
      ticks(clk);
      vblank <= '0';
      stop_at(STOP_STEP_FRAME, BP_PC);

      send(CMD_STEP_LINE, 42);
      dispstat <= x"00290040";
      line_trigger <= '1';
      ticks(clk);
      line_trigger <= '0';
      dispstat <= x"002A0040";
      hblank <= '1';
      ticks(clk);
      hblank <= '0';
      assert gdb_halted = '0' report "line-step accepted wrong line/edge" severity failure;
      line_trigger <= '1';
      ticks(clk);
      line_trigger <= '0';
      stop_at(STOP_STEP_LINE, BP_PC);
      send(CMD_STEP_LINE, 16#12A#);
      line_trigger <= '1';
      ticks(clk);
      line_trigger <= '0';
      assert gdb_halted = '0' report "HBlank line-step accepted line start" severity failure;
      hblank <= '1';
      ticks(clk);
      hblank <= '0';
      stop_at(STOP_STEP_LINE, BP_PC);

      before_cycles := cycle_count;
      send(CMD_BREAK_CYCLE, adr => before_cycles + 5);
      send(CMD_CONT);
      stop_at(STOP_BREAK_CYCLE, BP_PC);
      assert cycle_count = before_cycles + 5 and unsigned(mbox(OFF_CYCLES)) = before_cycles + 5
         report "absolute cycle break was off by a cycle" severity failure;
      send(CMD_BREAK_EVENT, 4); -- DMA start only
      send(CMD_CONT);
      hblank <= '1';
      ticks(clk);
      hblank <= '0';
      assert gdb_halted = '0' report "event mask accepted unrelated HBlank" severity failure;
      dma_on <= '1';
      ticks(clk);
      dma_on <= '0';
      stop_at(STOP_BREAK_EVENT, BP_PC);
      send(CMD_BREAK_EVENT);

      send(CMD_RESET, 1);
      stop_at(STOP_RESET_HALT, BP_PC);
      assert reset_ticks = 16 and dbg_reset_req = '0' and unsigned(mbox(OFF_CYCLES)) = 0
         report "reset pulse width, hold or cycle clear mismatch" severity failure;
      report "ALL GDB ENGINE TESTS PASSED";
      std.env.finish;
   end process;
end architecture;
