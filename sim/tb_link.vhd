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
   signal multi_cable : std_logic := '1'; -- 1 = GBA multi cable: A sits in the 1P plug, which grounds A's SI

   signal sc_line, sd_line, a_si, b_si : std_logic;

   -- wire order capture: first frame on SD after arming
   signal cap_arm    : std_logic := '0';
   signal cap_done   : std_logic := '0';
   signal cap_bits   : std_logic_vector(15 downto 0) := (others => '0');

   constant ADR_SIOMULTI0 : integer := 16#120#;
   constant ADR_SIOMULTI1 : integer := 16#122#;
   constant ADR_SIOMULTI2 : integer := 16#124#;
   constant ADR_SIOMULTI3 : integer := 16#126#;
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

   procedure buswrite32(signal b : out proc_bus_gb_type; adr : in integer; dat : in std_logic_vector(31 downto 0)) is
   begin
      wait until rising_edge(clk);
      b.Adr  <= std_logic_vector(to_unsigned((adr / 4) * 4, proc_busadr));
      b.rnw  <= '0';
      b.ena  <= '1';
      b.acc  <= "10";
      b.Din  <= dat;
      b.bEna <= "1111";
      wait until rising_edge(clk);
      b.ena  <= '0';
      b.rnw  <= '1';
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
   a_si    <= '0' when (multi_cable = '1') else
              '0' when (b_connected = '1' and b_so_oe = '1' and b_so_out = '0') else '1';
   b_si    <= '0' when (a_so_oe = '1' and a_so_out = '0') else '1';

   -- both ends actively transmitting a multiplayer frame at once = protocol
   -- violation. Checked on the engines' own send state, not raw SD oe: in
   -- Normal mode both ends legitimately hold SD low simultaneously (manual
   -- p.108/111 -- open drain, no electrical conflict).

   iserial_a : entity work.gba_serial
   port map
   (
      clk100           => clk,
      ce               => ce,
      gb_bus           => bus_a,
      wired_out        => wired_a,
      wired_done       => open,
      link_enable      => '1',
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

   check_double_tx : block
      signal a_sending : std_logic;
      signal b_sending : std_logic;
   begin
      a_sending <= << signal ^.iserial_a.multisendmode : std_logic >>;
      b_sending <= << signal ^.iserial_b.multisendmode : std_logic >>;
      process (clk)
      begin
         if rising_edge(clk) then
            assert not (a_sending = '1' and b_sending = '1' and b_connected = '1')
               report "multiplayer frame transmitted by both ends at once" severity failure;
         end if;
      end process;
   end block;

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
      -- normal mode over the multi cable is one-way by design (manual
      -- p.111: the 1P plug grounds the master's SI). Model a direct
      -- symmetric connection here (e.g. a Wireless Adapter on the port)
      -- so the master receive path is exercised too.
      multi_cable <= '0';
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
      multi_cable <= '1'; -- back on the multi cable (test 4 modeled a direct connection)
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

      ------------------------------------------------------------------
      -- replay the exact register choreography of pret link.c (Pokemon
      -- gen 3 Cable Club, src/link.c of pokeemerald): EnableSerial's
      -- double SIOCNT write (0x2000 then 0x6003), the DoHandshake rounds
      -- with their 64-bit SIOMULTI read + REG_SIOMLT_RECV=0 write-back,
      -- then the data phase: 9 words per frame, each started by a blind
      -- SIOCNT |= 0x80 read-modify-write with NO busy check, spaced
      -- 12608 cycles apart by Timer3 (-197 @ /64) *measured from the
      -- previous word's serial IRQ* (SendRecvDone enables the timer from
      -- inside the ISR). LinkVSync declares a link error (LAG_MASTER) if
      -- all 9 words don't complete within one frame -- so each exchange
      -- MUST be over well inside the 12608-cycle gap; that budget is the
      -- assert. SerialCB also reads SIOCNT bit6 (error) every word and
      -- any 1 there is a hardware-error link abort, so bit6 is asserted
      -- 0 throughout.
      report "test 6: pret link.c cable club choreography";
      irq_clear <= '1';
      wait for 4 * CLK_PERIOD;
      irq_clear <= '0';

      -- EnableSerial on both ends (pret: RCNT=0; SIOCNT=0x2000; SIOCNT=0x6003; SIOMLT_SEND=0)
      buswrite16(bus_a, ADR_SIOCNT,  x"2000");
      buswrite16(bus_a, ADR_SIOCNT,  x"6003");
      buswrite16(bus_a, ADR_SIOSEND, x"0000");
      buswrite16(bus_b, ADR_SIOCNT,  x"2000");
      buswrite16(bus_b, ADR_SIOCNT,  x"6003");
      buswrite16(bus_b, ADR_SIOSEND, x"0000");

      -- CheckMasterOrSlave gates: master needs SD=1,SI=0,id=0; slave sees SI=1
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      assert (r16(3) = '1' and r16(2) = '0' and r16(5 downto 4) = "00")
         report "pret: master pregate SD/SI/id wrong" severity failure;
      busread16(bus_b, wired_b, ADR_SIOCNT, r16);
      assert r16(2) = '1' report "pret: slave must read SI=1" severity failure;

      -- handshake round 1: both still send 0x0000 (pret's first transfer
      -- goes out before DoHandshake ever loaded a handshake word)
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");
      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' and irq_b_seen = '1' report "pret: hs1 IRQ missing" severity failure;
      irq_clear <= '1'; wait for 4 * CLK_PERIOD; irq_clear <= '0';

      -- ISR on both: read all four slots, then REG_SIOMLT_RECV = 0
      busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
      assert r16 = x"0000" report "pret: hs1 A slot0 /= 0000" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
      assert r16 = x"0000" report "pret: hs1 A slot1 /= 0000" severity failure;
      buswrite32(bus_a, 16#120#, x"00000000");
      buswrite32(bus_a, 16#124#, x"00000000");
      buswrite32(bus_b, 16#120#, x"00000000");
      buswrite32(bus_b, 16#124#, x"00000000");
      -- both load SLAVE_HANDSHAKE (leader hasn't confirmed yet)
      buswrite16(bus_a, ADR_SIOSEND, x"B9A0");
      buswrite16(bus_b, ADR_SIOSEND, x"B9A0");

      -- handshake round 2 (a VBlank later): expect B9A0/B9A0/FFFF/FFFF on both
      wait for 20000 * 6 * CLK_PERIOD;
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      assert r16(7) = '0' report "pret: hs2 master busy should be idle" severity failure;
      buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");
      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' and irq_b_seen = '1' report "pret: hs2 IRQ missing" severity failure;
      irq_clear <= '1'; wait for 4 * CLK_PERIOD; irq_clear <= '0';
      busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
      assert r16 = x"B9A0" report "pret: hs2 A slot0 /= B9A0 (self echo)" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
      assert r16 = x"B9A0" report "pret: hs2 A slot1 /= B9A0" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI2, r16);
      assert r16 = x"FFFF" report "pret: hs2 A slot2 /= FFFF" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI3, r16);
      assert r16 = x"FFFF" report "pret: hs2 A slot3 /= FFFF" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
      assert r16 = x"B9A0" report "pret: hs2 B slot0 /= B9A0" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI1, r16);
      assert r16 = x"B9A0" report "pret: hs2 B slot1 /= B9A0 (self echo)" severity failure;
      buswrite32(bus_a, 16#120#, x"00000000");
      buswrite32(bus_a, 16#124#, x"00000000");
      buswrite32(bus_b, 16#120#, x"00000000");
      buswrite32(bus_b, 16#124#, x"00000000");

      -- leader confirmed: master loads MASTER_HANDSHAKE for one round
      buswrite16(bus_a, ADR_SIOSEND, x"8FFF");
      buswrite16(bus_b, ADR_SIOSEND, x"B9A0");
      wait for 20000 * 6 * CLK_PERIOD;
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");
      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' and irq_b_seen = '1' report "pret: hs3 IRQ missing" severity failure;
      irq_clear <= '1'; wait for 4 * CLK_PERIOD; irq_clear <= '0';
      busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
      assert r16 = x"8FFF" report "pret: hs3 A slot0 /= 8FFF (handshake-complete view)" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
      assert r16 = x"8FFF" report "pret: hs3 B slot0 /= 8FFF" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI1, r16);
      assert r16 = x"B9A0" report "pret: hs3 B slot1 /= B9A0" severity failure;

      -- data phase: one full 9-word packet, Timer3-paced. Every word:
      -- load sends in the "ISR", wait the 12608-cycle timer gap, then a
      -- blind RMW start. The busy assert directly encodes the LAG_MASTER
      -- budget: the previous exchange must be long over when Timer3 fires.
      buswrite16(bus_a, ADR_SIOSEND, x"A001");
      buswrite16(bus_b, ADR_SIOSEND, x"B001");
      for word in 1 to 9 loop
         wait for 12608 * 6 * CLK_PERIOD;
         busread16(bus_a, wired_a, ADR_SIOCNT, r16);
         assert r16(7) = '0' report "pret: word " & integer'image(word) & " master still busy at Timer3 fire (LAG_MASTER)" severity failure;
         busread16(bus_b, wired_b, ADR_SIOCNT, r16);
         assert r16(7) = '0' report "pret: word " & integer'image(word) & " slave still busy at Timer3 fire" severity failure;
         busread16(bus_a, wired_a, ADR_SIOCNT, r16);
         buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");
         wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
         assert irq_a_seen = '1' report "pret: word " & integer'image(word) & " master IRQ missing" severity failure;
         assert irq_b_seen = '1' report "pret: word " & integer'image(word) & " slave IRQ missing" severity failure;
         irq_clear <= '1'; wait for 4 * CLK_PERIOD; irq_clear <= '0';

         -- SerialCB view on both ends: own echo + peer data + FFFF slots + no error bit
         busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
         assert r16 = std_logic_vector(to_unsigned(16#A000# + word, 16)) report "pret: word " & integer'image(word) & " A slot0 (self echo) wrong" severity failure;
         busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
         assert r16 = std_logic_vector(to_unsigned(16#B000# + word, 16)) report "pret: word " & integer'image(word) & " A slot1 wrong" severity failure;
         busread16(bus_a, wired_a, ADR_SIOMULTI2, r16);
         assert r16 = x"FFFF" report "pret: word " & integer'image(word) & " A slot2 /= FFFF" severity failure;
         busread16(bus_a, wired_a, ADR_SIOMULTI3, r16);
         assert r16 = x"FFFF" report "pret: word " & integer'image(word) & " A slot3 /= FFFF" severity failure;
         busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
         assert r16 = std_logic_vector(to_unsigned(16#A000# + word, 16)) report "pret: word " & integer'image(word) & " B slot0 wrong" severity failure;
         busread16(bus_b, wired_b, ADR_SIOMULTI1, r16);
         assert r16 = std_logic_vector(to_unsigned(16#B000# + word, 16)) report "pret: word " & integer'image(word) & " B slot1 (self echo) wrong" severity failure;
         busread16(bus_a, wired_a, ADR_SIOCNT, r16);
         assert r16(6) = '0' report "pret: word " & integer'image(word) & " A error bit set" severity failure;
         assert r16(5 downto 4) = "00" report "pret: word " & integer'image(word) & " A id /= 0" severity failure;
         busread16(bus_b, wired_b, ADR_SIOCNT, r16);
         assert r16(6) = '0' report "pret: word " & integer'image(word) & " B error bit set" severity failure;
         assert r16(5 downto 4) = "01" report "pret: word " & integer'image(word) & " B id /= 1" severity failure;

         -- ISR loads the next word
         buswrite16(bus_a, ADR_SIOSEND, std_logic_vector(to_unsigned(16#A001# + word, 16)));
         buswrite16(bus_b, ADR_SIOSEND, std_logic_vector(to_unsigned(16#B001# + word, 16)));
      end loop;
      report "test 6 passed";

      ------------------------------------------------------------------
      -- a SIOCNT rewrite (bit7=0, e.g. pret re-running EnableSerial or a
      -- standby callback) landing on the CHILD while the master is mid-
      -- frame must not abort the wire-driven reception: the child's d07
      -- is read-only status. Before the fix this cancelled the exchange
      -- and the master timed out into FFFF.
      report "test 7: child SIOCNT rewrite mid-exchange is ignored";
      irq_clear <= '1'; wait for 4 * CLK_PERIOD; irq_clear <= '0';
      buswrite16(bus_a, ADR_SIOSEND, x"CA5E");
      buswrite16(bus_b, ADR_SIOSEND, x"5EED");
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");
      wait for 6 * 145 * 6 * CLK_PERIOD;  -- ~6 bit periods: master mid-frame
      buswrite16(bus_b, ADR_SIOCNT, x"6003");
      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' and irq_b_seen = '1' report "rewrite: IRQ missing" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
      assert r16 = x"5EED" report "rewrite: A slot1 lost the child's answer" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
      assert r16 = x"CA5E" report "rewrite: B slot0 lost the master's frame" severity failure;
      report "test 7 passed";

      ------------------------------------------------------------------
      -- DisableSerial mid-session then a fresh OpenLink (the retry-after-
      -- error path every Cable Club player actually hits): stale exchange
      -- state must not leak into the next linkup.
      report "test 8: DisableSerial / re-enable clean restart";
      irq_clear <= '1'; wait for 4 * CLK_PERIOD; irq_clear <= '0';
      -- DisableSerial on both: SIOCNT=0x2000, SIOMLT_SEND=0, SIOMULTI=0
      buswrite16(bus_a, ADR_SIOCNT,  x"2000");
      buswrite16(bus_a, ADR_SIOSEND, x"0000");
      buswrite32(bus_a, 16#120#, x"00000000");
      buswrite32(bus_a, 16#124#, x"00000000");
      buswrite16(bus_b, ADR_SIOCNT,  x"2000");
      buswrite16(bus_b, ADR_SIOSEND, x"0000");
      buswrite32(bus_b, 16#120#, x"00000000");
      buswrite32(bus_b, 16#124#, x"00000000");
      wait for 1000 * CLK_PERIOD;
      -- re-EnableSerial + one exchange
      buswrite16(bus_a, ADR_SIOCNT,  x"2000");
      buswrite16(bus_a, ADR_SIOCNT,  x"6003");
      buswrite16(bus_b, ADR_SIOCNT,  x"2000");
      buswrite16(bus_b, ADR_SIOCNT,  x"6003");
      buswrite16(bus_a, ADR_SIOSEND, x"0D15");
      buswrite16(bus_b, ADR_SIOSEND, x"0DA7");
      busread16(bus_a, wired_a, ADR_SIOCNT, r16);
      buswrite16(bus_a, ADR_SIOCNT, r16 or x"0080");
      wait until irq_a_seen = '1' and irq_b_seen = '1' for 3 ms;
      assert irq_a_seen = '1' and irq_b_seen = '1' report "restart: IRQ missing" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI0, r16);
      assert r16 = x"0D15" report "restart: A slot0 wrong" severity failure;
      busread16(bus_a, wired_a, ADR_SIOMULTI1, r16);
      assert r16 = x"0DA7" report "restart: A slot1 wrong" severity failure;
      busread16(bus_b, wired_b, ADR_SIOMULTI0, r16);
      assert r16 = x"0D15" report "restart: B slot0 wrong" severity failure;
      report "test 8 passed";

      report "ALL LINK TESTS PASSED";
      done <= true;
      wait;
   end process;

end architecture;
