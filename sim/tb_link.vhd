-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- unit testbench for the link subsystem: two gba_serial engines over a
-- modeled open drain cable (the internal 2P wiring: SC/SD bussed, SO/SI
-- crossed). Checks, in order:
--   1) multiplayer exchange: data lands in SIOMULTI0/1 on both ends,
--      both IRQs fire, busy clears
--   2) wire order: the parent frame on SD is LSB first (real hardware order)
--   3) parent timeout: no child answering completes with FFFF, no hang
--   4) normal mode 8 bit master/slave exchange
-- plus a standing assertion that SD is never driven by both ends at once.
--
-- run: sim/run_link_tb.sh

entity tb_link is
end entity;

architecture sim of tb_link is

   constant CLK_PERIOD : time := 10 ns;

   signal clk       : std_logic := '0';
   signal ce        : std_logic := '0';
   signal ce_cnt    : integer range 0 to 5 := 0;
   signal done      : boolean := false;

   signal bus_a     : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal bus_b     : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal wired_a   : std_logic_vector(31 downto 0);
   signal wired_b   : std_logic_vector(31 downto 0);

   signal irq_a, irq_b           : std_logic;
   signal irq_a_seen, irq_b_seen : std_logic := '0';
   signal irq_clear              : std_logic := '0';

   -- engine A (parent)
   signal a_clk_out, a_clk_oe, a_so_out, a_so_oe, a_sd_out, a_sd_oe : std_logic;
   -- engine B (child)
   signal b_clk_out, b_clk_oe, b_so_out, b_so_oe, b_sd_out, b_sd_oe : std_logic;

   signal b_connected : std_logic := '1'; -- 0 = unplug B from the cable

   signal sc_line, sd_line, a_si, b_si : std_logic;

   -- wire order capture: first frame on SD after arming
   signal cap_arm    : std_logic := '0';
   signal cap_done   : std_logic := '0';
   signal cap_bits   : std_logic_vector(15 downto 0) := (others => '0');

   constant ADR_SIOMULTI0 : integer := 16#120#;
   constant ADR_SIOMULTI1 : integer := 16#122#;
   constant ADR_SIOCNT    : integer := 16#128#;
   constant ADR_SIOSEND   : integer := 16#12A#; -- SIOMLT_SEND / SIODATA8
   constant MULTISPEED    : integer := 145;     -- 115200 baud, in ce ticks

   -- The real gba_memorymux presents the proc bus WORD-ALIGNED (low 2
   -- address bits forced to "00") and routes halfword data through byte
   -- enables / the upper data lanes -- these models MUST do the same, or
   -- the bench exercises decode paths the CPU can never reach. An earlier
   -- version of these procedures presented exact halfword addresses, which
   -- is precisely how the reggba_serial.vhd word-alignment bug (SIOMLT_SEND
   -- et al unreachable from the real bus) sailed through this bench.
   procedure buswrite16(signal b : out proc_bus_gb_type; adr : in integer; dat : in std_logic_vector(15 downto 0)) is
      constant word_adr : integer := (adr / 4) * 4;
   begin
      wait until rising_edge(clk);
      b.Adr  <= std_logic_vector(to_unsigned(word_adr, proc_busadr));
      b.rnw  <= '0';
      b.ena  <= '1';
      b.acc  <= "01";
      if ((adr mod 4) = 2) then
         b.Din  <= dat & x"0000";
         b.bEna <= "1100";
      else
         b.Din  <= x"0000" & dat;
         b.bEna <= "0011";
      end if;
      wait until rising_edge(clk);
      b.ena  <= '0';
      b.rnw  <= '1';
   end procedure;

   procedure busread16(signal b : out proc_bus_gb_type; signal wired : in std_logic_vector(31 downto 0); adr : in integer; dat : out std_logic_vector(15 downto 0)) is
      constant word_adr : integer := (adr / 4) * 4;
   begin
      wait until rising_edge(clk);
      b.Adr <= std_logic_vector(to_unsigned(word_adr, proc_busadr));
      b.rnw <= '1';
      b.ena <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      if ((adr mod 4) = 2) then
         dat := wired(31 downto 16);
      else
         dat := wired(15 downto 0);
      end if;
   end procedure;

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   process (clk)
   begin
      if rising_edge(clk) then
         if (ce_cnt = 5) then
            ce_cnt <= 0;
            ce     <= '1';
         else
            ce_cnt <= ce_cnt + 1;
            ce     <= '0';
         end if;

         if (irq_clear = '1') then
            irq_a_seen <= '0';
            irq_b_seen <= '0';
         else
            irq_a_seen <= irq_a_seen or irq_a;
            irq_b_seen <= irq_b_seen or irq_b;
         end if;
      end if;
   end process;

   -- open drain cable, SO/SI crossed, B detachable
   sc_line <= '0' when (a_clk_oe = '1' and a_clk_out = '0') or
                       (b_connected = '1' and b_clk_oe = '1' and b_clk_out = '0') else '1';
   sd_line <= '0' when (a_sd_oe = '1' and a_sd_out = '0') or
                       (b_connected = '1' and b_sd_oe = '1' and b_sd_out = '0') else '1';
   a_si    <= '0' when (b_connected = '1' and b_so_oe = '1' and b_so_out = '0') else '1';
   b_si    <= '0' when (a_so_oe = '1' and a_so_out = '0') else '1';

   -- both ends actively transmitting on SD at once = protocol violation
   process (clk)
   begin
      if rising_edge(clk) then
         assert not (a_sd_oe = '1' and b_sd_oe = '1' and b_connected = '1')
            report "SD driven by both ends" severity failure;
      end if;
   end process;

   iserial_a : entity work.gba_serial
   port map
   (
      clk100           => clk,
      ce               => ce,
      gb_bus           => bus_a,
      wired_out        => wired_a,
      wired_done       => open,
      link_enable      => '1',
      link_role_parent => '1',
      link_clk_out     => a_clk_out,
      link_clk_oe      => a_clk_oe,
      link_clk_in      => sc_line,
      link_so_out      => a_so_out,
      link_so_oe       => a_so_oe,
      link_si_in       => a_si,
      link_sd_out      => a_sd_out,
      link_sd_oe       => a_sd_oe,
      link_sd_in       => sd_line,
      IRP_Serial       => irq_a
   );

   iserial_b : entity work.gba_serial
   port map
   (
      clk100           => clk,
      ce               => ce,
      gb_bus           => bus_b,
      wired_out        => wired_b,
      wired_done       => open,
      link_enable      => '1',
      link_role_parent => '0',
      link_clk_out     => b_clk_out,
      link_clk_oe      => b_clk_oe,
      link_clk_in      => sc_line,
      link_so_out      => b_so_out,
      link_so_oe       => b_so_oe,
      link_si_in       => b_si,
      link_sd_out      => b_sd_out,
      link_sd_oe       => b_sd_oe,
      link_sd_in       => sd_line,
      IRP_Serial       => irq_b
   );

   -- samples the first SD frame after cap_arm rises: waits for the start bit
   -- edge, then samples 16 data bits at their midpoints. cap_bits(k) = k-th
   -- bit on the wire, so cap_bits equals the sent word iff the wire is LSB
   -- first.
   process
      variable cecount : integer;
   begin
      wait until cap_arm = '1';
      cap_done <= '0';
      wait until sd_line = '0';         -- start bit edge
      for k in 0 to 15 loop
         -- advance to middle of data bit k: (k+1) full bits + half
         cecount := 0;
         while cecount < MULTISPEED loop
            wait until rising_edge(clk);
            if ce = '1' then cecount := cecount + 1; end if;
         end loop;
         if k = 0 then
            -- burn the remaining half of the start bit once
            cecount := 0;
            while cecount < MULTISPEED / 2 loop
               wait until rising_edge(clk);
               if ce = '1' then cecount := cecount + 1; end if;
            end loop;
         end if;
         cap_bits(k) <= sd_line;
      end loop;
      cap_done <= '1';
      wait until cap_arm = '0';
   end process;

   process
      variable r16 : std_logic_vector(15 downto 0);
   begin
      wait for 20 * CLK_PERIOD;

      ------------------------------------------------------------------
      report "test 1+2: multiplayer exchange, parent CAFE / child BEEF";
      irq_clear <= '1';
      wait for 4 * CLK_PERIOD;
      irq_clear <= '0';
      cap_arm   <= '1';

      buswrite16(bus_b, ADR_SIOCNT,  x"6003");  -- child: multi, 115200, irq on
      buswrite16(bus_b, ADR_SIOSEND, x"BEEF");
      buswrite16(bus_a, ADR_SIOSEND, x"CAFE");
      buswrite16(bus_a, ADR_SIOCNT,  x"6083");  -- parent: multi, 115200, irq, start

      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' report "parent IRQ missing" severity failure;
      assert irq_b_seen = '1' report "child IRQ missing" severity failure;

      busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
      assert r16 = x"CAFE" report "A SIOMULTI0 /= CAFE" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
      assert r16 = x"BEEF" report "A SIOMULTI1 /= BEEF" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
      assert r16 = x"CAFE" report "B SIOMULTI0 /= CAFE" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI1, r16);
      assert r16 = x"BEEF" report "B SIOMULTI1 /= BEEF" severity failure;

      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      assert r16(7) = '0' report "parent busy stuck" severity failure;
      busread16(bus_b, wired_b, ADR_SIOCNT, r16);
      assert r16(7) = '0' report "child busy stuck" severity failure;

      assert cap_done = '1' report "wire capture incomplete" severity failure;
      assert cap_bits = x"CAFE" report "wire order is not LSB first" severity failure;
      cap_arm <= '0';
      report "test 1+2 passed";

      ------------------------------------------------------------------
      report "test 3: parent alone times out with FFFF";
      b_connected <= '0';
      buswrite16(bus_b, ADR_SIOCNT, x"0000");   -- child engine off the bus
      irq_clear <= '1';
      wait for 4 * CLK_PERIOD;
      irq_clear <= '0';

      buswrite16(bus_a, ADR_SIOSEND, x"1234");
      buswrite16(bus_a, ADR_SIOCNT,  x"6083");

      wait until irq_a_seen = '1' for 5 ms;
      assert irq_a_seen = '1' report "parent timeout IRQ missing" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
      assert r16 = x"FFFF" report "absent child /= FFFF" severity failure;
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      assert r16(7) = '0' report "parent busy stuck after timeout" severity failure;
      report "test 3 passed";

      ------------------------------------------------------------------
      report "test 4: normal mode 8 bit, master 5A / slave A3";
      b_connected <= '1';
      irq_clear <= '1';
      wait for 4 * CLK_PERIOD;
      irq_clear <= '0';

      buswrite16(bus_b, ADR_SIOSEND, x"00A3");
      buswrite16(bus_b, ADR_SIOCNT,  x"4080");  -- slave: external clock, irq, start
      buswrite16(bus_a, ADR_SIOSEND, x"005A");
      buswrite16(bus_a, ADR_SIOCNT,  x"4081");  -- master: internal clock 256k, irq, start

      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' report "master IRQ missing" severity failure;
      assert irq_b_seen = '1' report "slave IRQ missing" severity failure;

      busread16(bus_a, wired_a, ADR_SIOSEND, r16);
      assert r16(7 downto 0) = x"A3" report "master received /= A3" severity failure;
      busread16(bus_b, wired_b, ADR_SIOSEND, r16);
      assert r16(7 downto 0) = x"5A" report "slave received /= 5A" severity failure;
      report "test 4 passed";

      ------------------------------------------------------------------
      -- replay the exact register choreography of afska/gba-link-connection
      -- LinkRawCable/LinkCable v8.0.3: activate() writes SIOCNT = MULTI|baud
      -- with no irq/start, interrupts and start are set by read-modify-write
      -- THROUGH THE LIVE READBACK, and the library gates on readback bits:
      -- master = not bit2, allReady = bit3, error = bit6, ids = bits 5:4.
      report "test 5: LinkCable.hpp choreography, 3 rounds";
      irq_clear <= '1';
      wait for 4 * CLK_PERIOD;
      irq_clear <= '0';

      -- activate() on both ends
      buswrite16(bus_a, ADR_SIOCNT,  x"2003");
      buswrite16(bus_a, ADR_SIOSEND, x"0000");
      buswrite16(bus_b, ADR_SIOCNT,  x"2003");
      buswrite16(bus_b, ADR_SIOSEND, x"0000");
      -- setInterruptsOn(): SIOCNT |= 1<<14 as read-modify-write
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      buswrite16(bus_a, ADR_SIOCNT, r16 or x"4000");
      busread16(bus_b, wired_b, ADR_SIOCNT, r16);
      buswrite16(bus_b, ADR_SIOCNT, r16 or x"4000");

      -- the library's gates before it ever transfers
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      assert r16(2) = '0' report "parent not seen as master (bit2)" severity failure;
      assert r16(3) = '1' report "parent not allReady (bit3)" severity failure;
      assert r16(6) = '0' report "parent hasError (bit6)" severity failure;
      busread16(bus_b, wired_b, ADR_SIOCNT, r16);
      assert r16(2) = '1' report "child not seen as slave (bit2)" severity failure;

      for round in 1 to 3 loop
         irq_clear <= '1';
         wait for 4 * CLK_PERIOD;
         irq_clear <= '0';

         buswrite16(bus_a, ADR_SIOSEND, std_logic_vector(to_unsigned(16#1110# + round, 16)));
         buswrite16(bus_b, ADR_SIOSEND, std_logic_vector(to_unsigned(16#AAA0# + round, 16)));

         -- startTransfer(): SIOCNT |= 1<<7 as read-modify-write, master only
         busread16(bus_a, wired_a, ADR_SIOCNT, r16);
         buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");

         wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
         assert irq_a_seen = '1' report "round: parent IRQ missing" severity failure;
         assert irq_b_seen = '1' report "round: child IRQ missing" severity failure;

         busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
         assert r16 = std_logic_vector(to_unsigned(16#1110# + round, 16)) report "round: A MULTI0 wrong" severity failure;
         busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
         assert r16 = std_logic_vector(to_unsigned(16#AAA0# + round, 16)) report "round: A MULTI1 wrong" severity failure;
         busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
         assert r16 = std_logic_vector(to_unsigned(16#1110# + round, 16)) report "round: B MULTI0 wrong" severity failure;
         busread16(bus_b, wired_b, ADR_SIOMULTI1, r16);
         assert r16 = std_logic_vector(to_unsigned(16#AAA0# + round, 16)) report "round: B MULTI1 wrong" severity failure;

         -- getData() reads the player id from live bits 5:4
         busread16(bus_a, wired_a, ADR_SIOCNT, r16);
         assert r16(5 downto 4) = "00" report "parent id /= 0" severity failure;
         busread16(bus_b, wired_b, ADR_SIOCNT, r16);
         assert r16(5 downto 4) = "01" report "child id /= 1" severity failure;
      end loop;
      report "test 5 passed";

      report "ALL LINK TESTS PASSED";
      done <= true;
      wait;
   end process;

end architecture;
