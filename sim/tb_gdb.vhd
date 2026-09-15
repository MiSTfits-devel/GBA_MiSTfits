library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

use work.pProc_bus_gba.all;

-- Unit test for the gdb debug engine (rtl/gba_gdb.vhd).
--
-- Models the four things the engine talks to: the DDR3 mailbox, the savestate
-- register bus, the GBA memory bus, and enough of the CPU and pause controller
-- to exercise halting. The stimulus drives the mailbox exactly the way
-- support/gdb_daemon does, so what passes here is the same handshake the
-- daemon will run against real fabric.

entity tb_gdb is
end entity;

architecture arch of tb_gdb is

   constant CLKPER   : time    := 29.8 ns;   -- 16.777216 MHz
   constant MB_BASE  : integer := 16#C800000#;

   constant OFF_CMD   : integer := 16#000#;
   constant OFF_ADDR  : integer := 16#008#;
   constant OFF_LEN   : integer := 16#010#;
   constant OFF_ACK   : integer := 16#018#;
   constant OFF_STATE : integer := 16#020#;
   constant OFF_DATA  : integer := 16#100#;

   constant CMD_HALT   : integer := 1;
   constant CMD_CONT   : integer := 2;
   constant CMD_STEP   : integer := 3;
   constant CMD_RDMEM  : integer := 4;
   constant CMD_WRMEM  : integer := 5;
   constant CMD_RDREGS : integer := 6;
   constant CMD_WRREG  : integer := 7;
   constant CMD_SETBP  : integer := 8;

   constant STOP_HOST : integer := 1;
   constant STOP_BP   : integer := 2;
   constant STOP_STEP : integer := 3;

   signal clk        : std_logic := '0';
   signal reset      : std_logic := '1';
   signal gdb_enable : std_logic := '1';
   signal sim_done   : boolean   := false;

   -- ddr3
   signal ddr3_request   : std_logic;
   signal ddr3_rnw       : std_logic;
   signal ddr3_address   : unsigned(27 downto 0);
   signal ddr3_writeMask : std_logic_vector(7 downto 0);
   signal ddr3_dataWrite : std_logic_vector(63 downto 0);
   signal ddr3_granted   : std_logic := '0';
   signal ddr3_done      : std_logic := '0';
   signal ddr3_dataRead  : std_logic_vector(63 downto 0) := (others => '0');

   -- savestate register bus
   signal ss_bus       : proc_bus_gb_type;
   signal ss_bus_req   : std_logic;
   signal ss_wired_out : std_logic_vector(31 downto 0) := (others => '0');
   signal ss_wired_done: std_logic := '0';

   -- gba memory bus
   signal bus_addr   : std_logic_vector(27 downto 0);
   signal bus_rnw    : std_logic;
   signal bus_acc    : std_logic_vector(1 downto 0);
   signal bus_wdata  : std_logic_vector(31 downto 0);
   signal bus_written: std_logic;
   signal bus_rdata  : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done   : std_logic := '0';
   signal memaccess  : std_logic;

   -- cpu
   signal cpu_PC       : unsigned(31 downto 0) := x"08000000";
   signal cpu_dec_rdy  : std_logic := '1';
   signal cpu_halt     : std_logic := '0';
   signal cpu_done     : std_logic := '0';
   signal cpu_inhibit  : std_logic;
   signal cpu_new_halt : std_logic;
   signal cpu_unhalt   : std_logic;
   signal instr_count  : integer := 0;

   signal cpu_bus_Adr : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_bus_ena : std_logic := '0';
   signal cpu_bus_rnw : std_logic := '1';

   -- pause
   signal gdb_pause    : std_logic;
   signal pause_active : std_logic := '0';
   signal gdb_halted   : std_logic;

   -- ddr3 backing store, one qword per entry, covering the mailbox
   type t_mbox is array(0 to 127) of std_logic_vector(63 downto 0);
   shared variable mbox : t_mbox := (others => (others => '0'));

   -- gba memory model, word addressed from GBA_MEM_BASE
   constant GBA_MEM_BASE : integer := 16#3000000#;
   type t_gbamem is array(0 to 63) of std_logic_vector(31 downto 0);
   shared variable gbamem : t_gbamem := (others => (others => '0'));

   -- the register file the engine reads over the savestate bus
   type t_regs is array(0 to 17) of std_logic_vector(31 downto 0);
   shared variable regfile : t_regs := (others => (others => '0'));

   signal errors : integer := 0;

   procedure check(cond : boolean; msg : string; signal errs : inout integer) is
   begin
      if not cond then
         report "FAIL: " & msg severity error;
         errs <= errs + 1;
      end if;
   end procedure;

begin

   clk <= not clk after CLKPER / 2 when not sim_done else '0';

   igdb : entity work.gba_gdb
   generic map
   (
      MAILBOX_ADDR => MB_BASE
   )
   port map
   (
      clk1x            => clk,
      reset            => reset,
      gdb_enable       => gdb_enable,

      ddr3_request     => ddr3_request,
      ddr3_rnw         => ddr3_rnw,
      ddr3_address     => ddr3_address,
      ddr3_burstcount  => open,
      ddr3_writeMask   => ddr3_writeMask,
      ddr3_dataWrite   => ddr3_dataWrite,
      ddr3_granted     => ddr3_granted,
      ddr3_done        => ddr3_done,
      ddr3_dataRead    => ddr3_dataRead,

      ss_bus_out       => ss_bus,
      ss_bus_req       => ss_bus_req,
      ss_wired_out     => ss_wired_out,
      ss_wired_done    => ss_wired_done,

      GBA_BusAddr      => bus_addr,
      GBA_BusRnW       => bus_rnw,
      GBA_BusACC       => bus_acc,
      GBA_BusWriteData => bus_wdata,
      GBA_Bus_written  => bus_written,
      GBA_BusReadData  => bus_rdata,
      GBA_BusReadDone  => bus_done,
      gdb_memaccess    => memaccess,

      cpu_PC           => cpu_PC,
      cpu_decode_ready => cpu_dec_rdy,
      cpu_halt         => cpu_halt,
      cpu_done         => cpu_done,
      cpu_inhibit      => cpu_inhibit,
      cpu_new_halt     => cpu_new_halt,
      cpu_unhalt       => cpu_unhalt,

      cpu_bus_Adr      => cpu_bus_Adr,
      cpu_bus_ena      => cpu_bus_ena,
      cpu_bus_rnw      => cpu_bus_rnw,

      gdb_pause        => gdb_pause,
      pause_active     => pause_active,
      gdb_halted       => gdb_halted
   );

   ------------------------------------------------------------------
   -- DDR3 model: latches a single cycle request, answers a few cycles later
   ------------------------------------------------------------------
   process (clk)
      variable busy   : std_logic := '0';
      variable lat    : integer := 0;
      variable adr    : unsigned(27 downto 0);
      variable rnw    : std_logic;
      variable wdata  : std_logic_vector(63 downto 0);
      variable idx    : integer;
   begin
      if rising_edge(clk) then
         ddr3_granted <= '0';
         ddr3_done    <= '0';

         if (busy = '0') then
            if (ddr3_request = '1') then
               busy  := '1';
               lat   := 3;
               adr   := ddr3_address;
               rnw   := ddr3_rnw;
               wdata := ddr3_dataWrite;
               if (ddr3_rnw = '1') then
                  ddr3_granted <= '1';
               end if;
            end if;
         else
            if (lat > 0) then
               lat := lat - 1;
            else
               busy := '0';
               idx  := (to_integer(adr) - MB_BASE) / 8;
               assert idx >= 0 and idx <= 127
                  report "ddr3 access outside the modelled mailbox" severity failure;
               if (rnw = '1') then
                  ddr3_dataRead <= mbox(idx);
               else
                  mbox(idx) := wdata;
               end if;
               ddr3_done <= '1';
            end if;
         end if;
      end if;
   end process;

   ------------------------------------------------------------------
   -- savestate register file, combinational on the address like eProcReg
   ------------------------------------------------------------------
   process (all)
      variable a : integer;
   begin
      a := to_integer(unsigned(ss_bus.adr));
      if (a >= 1 and a <= 18) then
         ss_wired_out  <= regfile(a - 1);
         ss_wired_done <= '1';
      else
         ss_wired_out  <= (others => '0');
         ss_wired_done <= '0';
      end if;
   end process;

   -- register writes land on the same bus
   process (clk)
      variable a : integer;
   begin
      if rising_edge(clk) then
         if (ss_bus.ena = '1' and ss_bus.rnw = '0') then
            a := to_integer(unsigned(ss_bus.adr));
            if (a >= 1 and a <= 18) then
               regfile(a - 1) := ss_bus.Din;
            end if;
         end if;
      end if;
   end process;

   ------------------------------------------------------------------
   -- GBA memory model
   ------------------------------------------------------------------
   process (clk)
      variable pend : integer := 0;
      variable adr  : integer;
      variable rnw  : std_logic;
      variable wdat : std_logic_vector(31 downto 0);
      variable idx  : integer;
   begin
      if rising_edge(clk) then
         bus_done <= '0';

         if (bus_written = '1') then
            pend := 3;
            adr  := to_integer(unsigned(bus_addr));
            rnw  := bus_rnw;
            wdat := bus_wdata;
            assert bus_acc = ACCESS_32BIT
               report "debug bus access was not 32 bit" severity error;
         elsif (pend > 0) then
            pend := pend - 1;
            if (pend = 0) then
               idx := (adr - GBA_MEM_BASE) / 4;
               assert idx >= 0 and idx <= 63
                  report "gba bus access outside the modelled memory" severity failure;
               if (rnw = '1') then
                  bus_rdata <= gbamem(idx);
               else
                  gbamem(idx) := wdat;
               end if;
               bus_done <= '1';
            end if;
         end if;
      end if;
   end process;

   ------------------------------------------------------------------
   -- CPU model: retires one instruction every 4 cycles unless halted or
   -- inhibited, and honours the engine's halt/unhalt exactly as gba_cpu does
   ------------------------------------------------------------------
   process (clk)
      variable tick : integer := 0;
   begin
      if rising_edge(clk) then
         cpu_done <= '0';

         if (reset = '1') then
            cpu_halt <= '0';
            cpu_PC   <= x"08000000";
         else
            -- decode_halt: set by new_halt, cleared by unhalt
            if (cpu_new_halt = '1') then
               cpu_halt <= '1';
            elsif (cpu_halt = '1' and cpu_unhalt = '1') then
               cpu_halt <= '0';
            end if;

            -- execute_now is gated by both decode_halt and the combinational
            -- inhibit, and the whole core stops when the pause takes effect
            if (cpu_halt = '0' and cpu_inhibit = '0' and pause_active = '0') then
               tick := tick + 1;
               if (tick = 4) then
                  tick        := 0;
                  cpu_PC      <= cpu_PC + 4;
                  cpu_done    <= '1';
                  instr_count <= instr_count + 1;
               end if;
            end if;
         end if;

         -- regs(15) is what the engine reports as the stop PC, so keep the
         -- model register file consistent with the model CPU
         regfile(15) := std_logic_vector(cpu_PC);
      end if;
   end process;

   ------------------------------------------------------------------
   -- pause controller model
   ------------------------------------------------------------------
   process (clk)
      variable dly : integer := 0;
   begin
      if rising_edge(clk) then
         if (gdb_pause = '1' and pause_active = '0') then
            dly := dly + 1;
            if (dly >= 4) then
               pause_active <= '1';
               dly := 0;
            end if;
         elsif (gdb_pause = '0' and pause_active = '1') then
            dly := dly + 1;
            if (dly >= 4) then
               pause_active <= '0';
               dly := 0;
            end if;
         else
            dly := 0;
         end if;
      end if;
   end process;

   ------------------------------------------------------------------
   -- stimulus
   ------------------------------------------------------------------
   process
      variable seq : integer := 0;

      procedure wait_clk(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      -- drive one mailbox command and block until the engine acknowledges,
      -- the same handshake gdb_mbox_cmd() performs
      procedure send_cmd(op : integer; arg : integer; adr : integer; len : integer) is
         variable guard : integer := 0;
      begin
         seq := seq + 1;
         if (seq > 255) then seq := 1; end if;
         mbox(OFF_ADDR / 8) := std_logic_vector(to_unsigned(adr, 64));
         mbox(OFF_LEN  / 8) := std_logic_vector(to_unsigned(len, 64));
         -- [7:0] opcode, [15:8] sequence, [63:32] argument
         mbox(OFF_CMD  / 8) := std_logic_vector(to_unsigned(arg, 32)) &
                               x"0000" &
                               std_logic_vector(to_unsigned(seq, 8)) &
                               std_logic_vector(to_unsigned(op, 8));
         loop
            wait until rising_edge(clk);
            guard := guard + 1;
            assert guard < 200000 report "mailbox command timed out" severity failure;
            exit when to_integer(unsigned(mbox(OFF_ACK / 8)(7 downto 0))) = seq;
         end loop;
         -- let the engine publish any state change the command caused
         wait_clk(80);
      end procedure;

      impure function state_halted return boolean is
      begin
         return mbox(OFF_STATE / 8)(0) = '1';
      end function;

      impure function state_reason return integer is
      begin
         return to_integer(unsigned(mbox(OFF_STATE / 8)(7 downto 4)));
      end function;

      impure function state_pc return unsigned is
      begin
         return unsigned(mbox(OFF_STATE / 8)(63 downto 32));
      end function;

      impure function data_word(i : integer) return std_logic_vector is
         variable qw : std_logic_vector(63 downto 0);
      begin
         qw := mbox(OFF_DATA / 8 + i / 2);
         if (i mod 2) = 0 then
            return qw(31 downto 0);
         else
            return qw(63 downto 32);
         end if;
      end function;

      procedure set_data_word(i : integer; v : std_logic_vector(31 downto 0)) is
         variable qw : std_logic_vector(63 downto 0);
      begin
         qw := mbox(OFF_DATA / 8 + i / 2);
         if (i mod 2) = 0 then
            qw(31 downto 0) := v;
         else
            qw(63 downto 32) := v;
         end if;
         mbox(OFF_DATA / 8 + i / 2) := qw;
      end procedure;

      variable pc_at_halt : unsigned(31 downto 0);
      variable n_before   : integer;

   begin
      -- seed the register file and memory
      for i in 0 to 14 loop
         regfile(i) := std_logic_vector(to_unsigned(16#1000# + i, 32));
      end loop;
      regfile(16) := x"6000001F";      -- CPSR
      for i in 0 to 15 loop
         gbamem(i) := std_logic_vector(to_unsigned(16#20000000# + i, 32));
      end loop;

      wait_clk(10);
      reset <= '0';
      wait_clk(20);

      report "--- 1. core runs freely with the stub idle";
      n_before := instr_count;
      wait_clk(200);
      check(instr_count > n_before, "cpu should be running before any halt", errors);

      report "--- 2. host halt request";
      send_cmd(CMD_HALT, 0, 0, 0);
      check(state_halted, "STATE should report halted after CMD_HALT", errors);
      check(state_reason = STOP_HOST, "stop reason should be host request", errors);
      check(gdb_halted = '1', "gdb_halted should be asserted", errors);
      check(pause_active = '1', "whole core should be frozen once halted", errors);

      pc_at_halt := state_pc;
      n_before   := instr_count;
      wait_clk(300);
      check(instr_count = n_before, "cpu must not retire while halted", errors);

      report "--- 3. register read over the savestate bus";
      send_cmd(CMD_RDREGS, 0, 0, 0);
      check(data_word(0) = x"00001000", "r0 mismatch: " &
            to_hstring(data_word(0)), errors);
      check(data_word(14) = x"0000100E", "r14 mismatch: " &
            to_hstring(data_word(14)), errors);
      check(unsigned(data_word(15)) = pc_at_halt, "r15 should equal the stop PC",
            errors);
      check(data_word(16) = x"6000001F", "cpsr mismatch: " &
            to_hstring(data_word(16)), errors);

      report "--- 4. register write";
      send_cmd(CMD_WRREG, 16#5EADBEEF#, 0, 0);
      check(regfile(0) = x"5EADBEEF", "r0 write did not land: " &
            to_hstring(regfile(0)), errors);

      report "--- 5. memory read, 8 words";
      send_cmd(CMD_RDMEM, 0, GBA_MEM_BASE, 32);
      for i in 0 to 7 loop
         check(data_word(i) = std_logic_vector(to_unsigned(16#20000000# + i, 32)),
               "memory read word " & integer'image(i) & " = " &
               to_hstring(data_word(i)), errors);
      end loop;

      report "--- 6. memory write, whole words";
      set_data_word(0, x"11223344");
      set_data_word(1, x"55667788");
      send_cmd(CMD_WRMEM, 0, GBA_MEM_BASE + 16#20#, 8);
      check(gbamem(8) = x"11223344", "word write 0 = " & to_hstring(gbamem(8)),
            errors);
      check(gbamem(9) = x"55667788", "word write 1 = " & to_hstring(gbamem(9)),
            errors);

      report "--- 7. ragged tail write must read-modify-write the last word";
      gbamem(13) := x"CAFEF00D";   -- only its low half is inside the request
      set_data_word(0, x"AABBCCDD");
      set_data_word(1, x"0000EEFF");   -- only the low 2 bytes are in range
      send_cmd(CMD_WRMEM, 0, GBA_MEM_BASE + 16#30#, 6);
      check(gbamem(12) = x"AABBCCDD", "full word of the ragged write = " &
            to_hstring(gbamem(12)), errors);
      check(gbamem(13)(15 downto 0) = x"EEFF", "tail bytes written = " &
            to_hstring(gbamem(13)), errors);
      check(gbamem(13)(31 downto 16) = x"CAFE", "tail RMW clobbered the " &
            "bytes past the request: " & to_hstring(gbamem(13)), errors);

      report "--- 8. resume";
      n_before := instr_count;
      send_cmd(CMD_CONT, 0, 0, 0);
      wait_clk(200);
      check(not state_halted, "STATE should clear halted after CMD_CONT", errors);
      check(instr_count > n_before, "cpu should retire again after resume",
            errors);

      report "--- 9. single step retires exactly one instruction";
      send_cmd(CMD_HALT, 0, 0, 0);
      n_before := instr_count;
      send_cmd(CMD_STEP, 0, 0, 0);
      check(state_halted, "step should leave the core halted", errors);
      check(state_reason = STOP_STEP, "stop reason should be step", errors);
      check(instr_count = n_before + 1,
            "step retired " & integer'image(instr_count - n_before) &
            " instructions, want 1", errors);

      report "--- 10. breakpoint stops before the instruction executes";
      -- arm a comparator a little ahead of where we are, then run
      pc_at_halt := state_pc;
      send_cmd(CMD_SETBP, 16#11#, to_integer(pc_at_halt) + 16#20#, 0);
      send_cmd(CMD_CONT, 0, 0, 0);

      for i in 1 to 4000 loop
         wait until rising_edge(clk);
         exit when state_halted;
      end loop;
      check(state_halted, "breakpoint never fired", errors);
      check(state_reason = STOP_BP, "stop reason should be breakpoint", errors);
      check(state_pc = pc_at_halt + 16#20#,
            "stopped at " & to_hstring(state_pc) & ", want " &
            to_hstring(pc_at_halt + 16#20#), errors);
      -- the breakpointed instruction must NOT have retired
      check(cpu_PC = pc_at_halt + 16#20#,
            "cpu ran past the breakpoint to " & to_hstring(cpu_PC), errors);

      report "--- 11. stepping off a breakpoint does not re-trigger it";
      n_before := instr_count;
      send_cmd(CMD_STEP, 0, 0, 0);
      check(instr_count = n_before + 1,
            "could not step off the breakpoint (retired " &
            integer'image(instr_count - n_before) & ")", errors);
      check(state_reason = STOP_STEP,
            "step off a breakpoint should report a step, not a breakpoint",
            errors);

      report "--- 12. disarming the comparator lets the core run past it";
      send_cmd(CMD_SETBP, 16#01#, to_integer(pc_at_halt) + 16#20#, 0);
      n_before := instr_count;
      send_cmd(CMD_CONT, 0, 0, 0);
      wait_clk(1000);
      check(not state_halted, "core should still be running with the bp off",
            errors);
      check(instr_count > n_before + 20,
            "core did not run freely after the breakpoint was cleared", errors);

      wait_clk(20);
      if (errors = 0) then
         report "ALL GDB ENGINE TESTS PASSED";
      else
         report integer'image(errors) & " CHECK(S) FAILED" severity failure;
      end if;

      sim_done <= true;
      wait;
   end process;

end architecture;
