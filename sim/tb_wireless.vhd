-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- unit bench for the AGB-015 Wireless Adapter transport (gba_wireless):
-- a real gba_serial instance plays the GBA, driven through its register
-- bus exactly the way LinkSPI/LinkRawWireless drive the real one (GPIO
-- ping via RCNT, Normal-32 master transfers, SIOCNT bit3 SO handshake,
-- SIOCNT bit2 live-SI polling). A behavioral daemon answers on the byte
-- ports. Checks, in order:
--   1) GPIO ping wakes the adapter, login keystream completes
--   2) Hello (0x10): ACK header 0x99660090 comes back
--   3) SystemStatus (0x13): 1-word payload arrives intact
--   4) wait (0x27) -> clock reversal -> daemon notify 0x28 arrives as an
--      adapter-mastered command, GBA ACKs, clock returns to the GBA
--
-- run: sim/run_wireless_tb.sh
entity tb_wireless is
end entity;

architecture sim of tb_wireless is

   -- clk models clk1x (16.78 MHz); ce is held '1' like the real core's
   -- run gate, so SIOCNT baud settings produce their real bit rates
   constant CLK_PERIOD : time := 59.6 ns;
   constant CLKSPEED   : integer := 16777216;

   signal clk   : std_logic := '0';
   signal done  : boolean := false;

   signal bus_g   : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal wired_g : std_logic_vector(31 downto 0);
   signal irq_g   : std_logic;
   signal irq_seen: std_logic := '0';
   signal irq_clr : std_logic := '0';

   -- GBA side pins
   signal g_clk_out, g_clk_oe, g_so_out, g_so_oe, g_sd_out, g_sd_oe : std_logic;
   -- adapter side pins
   signal a_sc_out, a_sc_oe, a_so_out, a_so_oe : std_logic;

   signal sc_line, sd_line, gba_si, adp_si : std_logic;
   signal lp_clk_in, lp_si_in, lp_sd_in     : std_logic;
   signal user_in, user_out                 : std_logic_vector(6 downto 0);

   -- adapter <-> daemon byte stream
   signal d_tx_data  : std_logic_vector(7 downto 0);
   signal d_tx_valid : std_logic;
   signal d_tx_ready : std_logic := '1';
   signal d_rx_data  : std_logic_vector(7 downto 0) := (others => '0');
   signal d_rx_valid : std_logic := '0';

   signal login_done_seen : std_logic := '0';
   signal reversal_seen   : std_logic := '0';
   signal gbaack_seen     : std_logic := '0';
   signal req_hello_seen  : std_logic := '0';
   signal req_sstat_seen  : std_logic := '0';
   signal req_wait_seen   : std_logic := '0';

   constant ADR_SIODATA32 : integer := 16#120#;
   constant ADR_SIOCNT    : integer := 16#128#;
   constant ADR_RCNT      : integer := 16#134#;

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

   procedure buswrite32(signal b : out proc_bus_gb_type; adr : in integer; dat : in std_logic_vector(31 downto 0)) is
   begin
      wait until rising_edge(clk);
      b.Adr  <= std_logic_vector(to_unsigned(adr, proc_busadr));
      b.rnw  <= '0';
      b.ena  <= '1';
      b.acc  <= "10";
      b.Din  <= dat;
      b.bEna <= "1111";
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

   procedure busread32(signal b : out proc_bus_gb_type; signal wired : in std_logic_vector(31 downto 0); adr : in integer; dat : out std_logic_vector(31 downto 0)) is
   begin
      wait until rising_edge(clk);
      b.Adr <= std_logic_vector(to_unsigned(adr, proc_busadr));
      b.rnw <= '1';
      b.ena <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      dat := wired;
   end procedure;

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   process (clk)
   begin
      if rising_edge(clk) then
         if (irq_clr = '1') then
            irq_seen <= '0';
         else
            irq_seen <= irq_seen or irq_g;
         end if;
      end if;
   end process;

   -- Exact real SNAC path. gba_linkport maps creator-confirmed pins
   -- SC=USER_IO[0], SD=[5], SI=[2], SO=[1], drives open drain, and adds the
   -- same two-stage input synchronizers used in hardware. External adapter:
   -- GBA SO -> adapter SI, adapter SO -> GBA SI, SC and SD shared.
   sc_line <= '0' when user_out(0) = '0' or
                       (a_sc_oe = '1' and a_sc_out = '0') else '1';
   sd_line <= '0' when user_out(5) = '0' else '1';
   gba_si  <= '0' when (a_so_oe = '1' and a_so_out = '0') else '1';
   adp_si  <= user_out(1);

   user_in(0) <= sc_line;
   user_in(1) <= user_out(1);
   user_in(2) <= gba_si;
   user_in(3) <= '1';
   user_in(4) <= '1';
   user_in(5) <= sd_line;
   user_in(6) <= '1';

   ilinkport : entity work.gba_linkport
   port map
   (
      clk          => clk,
      port_enable  => '1',
      user_in      => user_in,
      user_out     => user_out,
      link_clk_out => g_clk_out,
      link_clk_oe  => g_clk_oe,
      link_clk_in  => lp_clk_in,
      link_so_out  => g_so_out,
      link_so_oe   => g_so_oe,
      link_si_in   => lp_si_in,
      link_sd_out  => g_sd_out,
      link_sd_oe   => g_sd_oe,
      link_sd_in   => lp_sd_in
   );

   igba : entity work.gba_serial
   port map
   (
      clk100           => clk,
      ce               => '1',
      gb_bus           => bus_g,
      wired_out        => wired_g,
      wired_done       => open,
      link_enable      => '1',
      link_clk_out     => g_clk_out,
      link_clk_oe      => g_clk_oe,
      link_clk_in      => lp_clk_in,
      link_so_out      => g_so_out,
      link_so_oe       => g_so_oe,
      link_si_in       => lp_si_in,
      link_sd_out      => g_sd_out,
      link_sd_oe       => g_sd_oe,
      link_sd_in       => lp_sd_in,
      IRP_Serial       => irq_g
   );

   iadapter : entity work.gba_wireless
   generic map ( CLKSPEED => CLKSPEED )
   port map
   (
      clk          => clk,
      reset        => '0',
      wireless_ena => '1',
      link_sc_in   => sc_line,
      link_sc_out  => a_sc_out,
      link_sc_oe   => a_sc_oe,
      link_si_in   => adp_si,
      link_so_out  => a_so_out,
      link_so_oe   => a_so_oe,
      link_sd_in   => sd_line,
      hps_tx_data  => d_tx_data,
      hps_tx_valid => d_tx_valid,
      hps_tx_ready => d_tx_ready,
      hps_rx_data  => d_rx_data,
      hps_rx_valid => d_rx_valid
   );

   -- behavioral daemon: parses FPGA->HPS packets and answers with canned
   -- ACKs the way the real rfu_daemon would
   daemon : process
      variable ptype, b1, b2, junk : std_logic_vector(7 downto 0);
      variable nbytes : integer;

      procedure getbyte(variable d : out std_logic_vector(7 downto 0)) is
      begin
         loop
            wait until rising_edge(clk);
            if (d_tx_valid = '1') then
               d := d_tx_data;
               exit;
            end if;
         end loop;
      end procedure;

      procedure putbyte(d : in std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         d_rx_data  <= d;
         d_rx_valid <= '1';
         wait until rising_edge(clk);
         d_rx_valid <= '0';
         wait until rising_edge(clk);
      end procedure;
   begin
      loop
         getbyte(ptype);
         getbyte(b1);
         getbyte(b2);
         nbytes := to_integer(unsigned(b2)) * 4;
         for i in 1 to nbytes loop
            getbyte(junk);
         end loop;
         report "daemon: pkt type=" & to_hstring(ptype) & " b1=" & to_hstring(b1) & " b2=" & to_hstring(b2);

         if (ptype = x"04") then
            -- event
            if (b1 = x"01") then
               login_done_seen <= '1';
            elsif (b1 = x"02") then
               reversal_seen <= '1';
               -- inject notify 0x28, no params
               putbyte(x"03"); putbyte(x"28"); putbyte(x"00");
            elsif (b1 = x"03") then
               gbaack_seen <= '1';
            end if;
         elsif (ptype = x"01") then
            -- REQ from the GBA: answer like the real daemon
            case b1 is
               when x"10" =>
                  req_hello_seen <= '1';
                  putbyte(x"02"); putbyte(x"90"); putbyte(x"00");
               when x"13" =>
                  req_sstat_seen <= '1';
                  putbyte(x"02"); putbyte(x"93"); putbyte(x"01");
                  -- payload word 0x03000123, little endian on the wire
                  putbyte(x"23"); putbyte(x"01"); putbyte(x"00"); putbyte(x"03");
               when x"27" =>
                  req_wait_seen <= '1';
                  putbyte(x"02"); putbyte(x"A7"); putbyte(x"00");
               when x"11" =>
                  putbyte(x"02"); putbyte(x"91"); putbyte(x"00");
               when others =>
                  putbyte(x"02"); putbyte(x"EE"); putbyte(x"01");
                  putbyte(x"01"); putbyte(x"00"); putbyte(x"00"); putbyte(x"00");
            end case;
         end if;
      end loop;
   end process;

   main : process
      variable r16 : std_logic_vector(15 downto 0);
      variable r32 : std_logic_vector(31 downto 0);
      variable adapter_hi : std_logic_vector(15 downto 0);
      variable gba_lo     : std_logic_vector(15 downto 0);
      type tKeystream is array(0 to 9) of std_logic_vector(15 downto 0);
      constant P : tKeystream := (x"494E", x"494E", x"494E", x"544E", x"544E",
                                  x"4E45", x"4E45", x"4F44", x"4F44", x"8001");

      -- one blocking Normal-32 master transfer at the given baud bits
      procedure xfer32(d : in std_logic_vector(31 downto 0); baud2m : in std_logic; variable res : out std_logic_vector(31 downto 0)) is
         variable cnt : std_logic_vector(15 downto 0);
      begin
         buswrite32(bus_g, ADR_SIODATA32, d);
         if (baud2m = '1') then
            cnt := x"5083"; -- 32bit, irq, start, internal clock 2MHz
         else
            cnt := x"5081"; -- 32bit, irq, start, internal clock 256kHz
         end if;
         irq_clr <= '1';
         wait for 4 * CLK_PERIOD;
         irq_clr <= '0';
         buswrite16(bus_g, ADR_SIOCNT, cnt);
         wait for 4 * CLK_PERIOD;
         assert user_out(5) = '1'
            report "SNAC SD pin must be released for Normal internal-clock master" severity failure;
         wait until irq_seen = '1' for 2 ms;
         assert irq_seen = '1' report "transfer never completed" severity failure;
         busread32(bus_g, wired_g, ADR_SIODATA32, res);
      end procedure;

      -- LinkRawWireless::acknowledge(), GBA side of the forward handshake:
      -- wait SI high, raise SO, wait SI low, drop SO
      procedure hshake(baud2m : in std_logic) is
         variable v : std_logic_vector(15 downto 0);
         variable base : std_logic_vector(15 downto 0);
      begin
         if (baud2m = '1') then base := x"5003"; else base := x"5001"; end if;
         loop
            busread16(bus_g, wired_g, ADR_SIOCNT, v);
            exit when v(2) = '1';
         end loop;
         buswrite16(bus_g, ADR_SIOCNT, base or x"0008"); -- SO high
         loop
            busread16(bus_g, wired_g, ADR_SIOCNT, v);
            exit when v(2) = '0';
         end loop;
         buswrite16(bus_g, ADR_SIOCNT, base); -- SO low
      end procedure;

      -- sendCommand: header + params, then response request; returns the
      -- ACK header word
      procedure sendcmd(cmd : in std_logic_vector(7 downto 0); variable ackhdr : out std_logic_vector(31 downto 0)) is
         variable r : std_logic_vector(31 downto 0);
      begin
         xfer32(x"9966" & x"00" & cmd, '1', r);
         assert r = x"80000000" report "adapter did not return dummy for header" severity failure;
         hshake('1');
         xfer32(x"80000000", '1', r); -- response request
         ackhdr := r;
         hshake('1');
      end procedure;
   begin
      wait for 20 * CLK_PERIOD;

      ------------------------------------------------------------------
      report "test 1: GPIO ping + login";
      -- pingAdapter(): GPIO mode, SD+SO outputs, SD high ~1.1ms, then low
      buswrite16(bus_g, ADR_RCNT, x"8000");
      buswrite16(bus_g, ADR_RCNT, x"80A0"); -- SD/SO outputs, low
      wait for 4 * CLK_PERIOD;
      assert user_out(5) = '0' and user_out(1) = '0'
         report "SNAC GPIO low mapping wrong (SD=5, SO=1)" severity failure;
      buswrite16(bus_g, ADR_RCNT, x"80A2"); -- SD high
      wait for 4 * CLK_PERIOD;
      assert user_out(5) = '1' and user_out(1) = '0'
         report "SNAC GPIO SD-high mapping wrong" severity failure;
      wait for 1.2 ms;
      buswrite16(bus_g, ADR_RCNT, x"80A0"); -- SD low
      wait for 50 us;
      buswrite16(bus_g, ADR_RCNT, x"0000"); -- leave GPIO mode

      -- login: 10 exchanges at 256kbps, no handshake, ~1ms gaps
      adapter_hi := x"8000";
      gba_lo     := x"FFFF";
      for i in 0 to 9 loop
         wait for 300 us;
         xfer32((not adapter_hi) & P(i), '0', r32);
         if (i >= 2) then
            assert r32 = P(i) & (not gba_lo)
               report "login word " & integer'image(i) & " wrong: got " & to_hstring(r32) &
                      " want " & to_hstring(P(i) & (not gba_lo)) severity failure;
         end if;
         adapter_hi := r32(31 downto 16);
         gba_lo     := P(i);
      end loop;
      wait until login_done_seen = '1' for 1 ms;
      assert login_done_seen = '1' report "adapter never reported login complete" severity failure;
      report "test 1 passed";

      ------------------------------------------------------------------
      report "test 2: Hello (0x10)";
      sendcmd(x"10", r32);
      assert r32 = x"99660090" report "hello ACK wrong: " & to_hstring(r32) severity failure;
      assert req_hello_seen = '1' report "daemon never saw hello" severity failure;
      report "test 2 passed";

      ------------------------------------------------------------------
      report "test 3: SystemStatus (0x13) with payload";
      sendcmd(x"13", r32);
      assert r32 = x"99660193" report "sstat ACK wrong: " & to_hstring(r32) severity failure;
      xfer32(x"80000000", '1', r32); -- clock out the payload word
      assert r32 = x"03000123" report "sstat payload wrong: " & to_hstring(r32) severity failure;
      hshake('1');
      report "test 3 passed";

      ------------------------------------------------------------------
      report "test 4: wait (0x27) -> reversal -> notify 0x28";
      sendcmd(x"27", r32);
      assert r32 = x"996600A7" report "wait ACK wrong: " & to_hstring(r32) severity failure;
      wait until reversal_seen = '1' for 1 ms;
      assert reversal_seen = '1' report "adapter never entered reversal" severity failure;

      -- GBA side: become slave, receive the adapter's command
      -- (LinkRawWireless::receiveCommandFromAdapter)
      -- word 1: adapter header; we answer 0x80000000
      for w in 0 to 2 loop
         buswrite32(bus_g, ADR_SIODATA32, x"80000000");
         if (w = 1) then
            -- word 2 carries our ACK to the notify
            buswrite32(bus_g, ADR_SIODATA32, x"996600A8");
         end if;
         irq_clr <= '1';
         wait for 4 * CLK_PERIOD;
         irq_clr <= '0';
         buswrite16(bus_g, ADR_SIOCNT, x"5080"); -- slave (external clock), start
         wait until irq_seen = '1' for 3 ms;
         assert irq_seen = '1' report "reversed word " & integer'image(w) & " never clocked" severity failure;
         busread32(bus_g, wired_g, ADR_SIODATA32, r32);
         if (w = 0) then
            assert r32 = x"99660028" report "notify header wrong: " & to_hstring(r32) severity failure;
         else
            assert r32 = x"80000000" report "reversed word " & integer'image(w) & " wrong: " & to_hstring(r32) severity failure;
         end if;
         -- reversed handshake, GBA side: SI low observed (word done);
         -- raise SO, wait SI high, drop SO (arms next word)
         loop
            busread16(bus_g, wired_g, ADR_SIOCNT, r16);
            exit when r16(2) = '0';
         end loop;
         buswrite16(bus_g, ADR_SIOCNT, x"5008"); -- slave idle, SO high
         loop
            busread16(bus_g, wired_g, ADR_SIOCNT, r16);
            exit when r16(2) = '1';
         end loop;
         buswrite16(bus_g, ADR_SIOCNT, x"5000"); -- SO low
      end loop;

      wait until gbaack_seen = '1' for 1 ms;
      assert gbaack_seen = '1' report "adapter never reported our ACK" severity failure;

      -- clock is ours again: a plain command must work
      sendcmd(x"11", r32);
      assert r32 = x"99660091" report "post-reversal command broken: " & to_hstring(r32) severity failure;
      report "test 4 passed";

      report "ALL WIRELESS TESTS PASSED";
      done <= true;
      wait;
   end process;

end architecture;
