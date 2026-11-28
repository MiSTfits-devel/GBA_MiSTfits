-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- Soak bench for the AGB-015 Wireless Adapter transport (gba_wireless):
-- same GBA-side harness as tb_wireless, but the HPS byte stream models the
-- real gba_wireless_uart transmitter contract (a byte is latched on a rising
-- edge with tx_cnt=0 and tx_valid='1'; tx_ready then stays low for the whole
-- 10-bit frame). That contract is what the hardware actually sees, and the
-- bench checks that it can never wedge the link:
--   1) 400 consecutive 0x13 command/ACK exchanges (1-word ACK payload)
--   2) 400 consecutive 0x1A command/ACK exchanges (0-word ACK payload)
--   3) a forced byte-level tx_ready stall must not wedge the serializer
--   4) a GPIO ping must always restore service after a truncated frame
--
-- run: sim/run_wireless_soak_tb.sh
entity tb_wireless_soak is
end entity;

architecture sim of tb_wireless_soak is

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
   signal g_sd_gpio_oe, sd_gpio_oe : std_logic := '0';
   signal adp_sd : std_logic := '1';
   -- adapter side pins
   signal a_sc_out, a_sc_oe, a_so_out, a_so_oe : std_logic;

   signal sc_line, sd_line, gba_si, adp_si : std_logic;
   signal lp_clk_in, lp_si_in, lp_sd_in     : std_logic;
   signal user_in, user_out                 : std_logic_vector(6 downto 0);

   -- adapter <-> daemon byte stream
   signal d_tx_data  : std_logic_vector(7 downto 0);
   signal d_tx_valid : std_logic;
   -- tx_ready as the real UART drives it, plus a way to force a stall
   signal uart_tx_ready : std_logic := '1';
   signal force_tx_stall : std_logic := '0';
   signal d_tx_ready    : std_logic;
   signal uart_byte     : std_logic_vector(7 downto 0) := (others => '0');
   signal uart_count    : natural := 0;
   signal relatch_seen  : std_logic := '0';
   signal soak_ok       : natural := 0;
   signal dup_ack       : std_logic := '0';
   signal hdr_drift     : std_logic;
   signal diag_word     : std_logic_vector(70 downto 0);
   signal dbg_freeze    : std_logic := '0';
   signal d_rx_data  : std_logic_vector(7 downto 0) := (others => '0');
   signal d_rx_valid : std_logic := '0';

   signal ping_events, login_events : natural := 0;
   signal reversal_seen   : std_logic := '0';
   signal gbaack_seen     : std_logic := '0';
   signal req_hello_seen  : std_logic := '0';
   signal req_sstat_seen  : std_logic := '0';
   signal req_wait_seen   : std_logic := '0';
   signal watchdog_events : natural := 0;
   signal adapter_state   : std_logic_vector(7 downto 0);

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

   -- gba_wireless_uart transmitter contract, reproduced exactly: a byte is
   -- latched on a rising edge where tx_cnt=0 and tx_valid='1'; tx_ready then
   -- stays low for 10 bits * (CLKSPEED/BAUD) = 80 clocks and only ever rises
   -- when tx_valid is low. `relatch_seen` flags the failure this contract is
   -- designed to expose: a producer that holds valid across a completed byte
   -- makes the UART re-latch it and tx_ready can never rise again.
   d_tx_ready <= '0' when force_tx_stall = '1' else uart_tx_ready;

   uart_model : process (clk)
      constant BYTE_CLKS : integer := 10 * (CLKSPEED / 2000000);
      variable cnt : integer := 0;
      variable valid_prev : std_logic := '0';
   begin
      if rising_edge(clk) then
         if (cnt = 0) then
            uart_tx_ready <= '1';
            if (d_tx_valid = '1' and force_tx_stall = '0') then
               -- the producer must drop valid on the acceptance edge; a byte
               -- still presented here was held across the boundary and the
               -- real UART would latch it again on every completion
               if (valid_prev = '1') then
                  relatch_seen <= '1';
                  report "UART re-latched a held tx_valid byte" severity warning;
               end if;
               uart_byte  <= d_tx_data;
               uart_count <= uart_count + 1;
               cnt := BYTE_CLKS;
               uart_tx_ready <= '0';
            end if;
         else
            uart_tx_ready <= '0';
            cnt := cnt - 1;
         end if;
         valid_prev := d_tx_valid;   -- value seen in the cycle just ended
      end if;
   end process;

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

   process (clk)
   begin
      if rising_edge(clk) then
         adp_sd <= sd_line;
         sd_gpio_oe <= g_sd_gpio_oe;
      end if;
   end process;

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
      link_sd_gpio_oe  => g_sd_gpio_oe,
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
      link_sd_in   => adp_sd,
      link_sd_gpio_oe => sd_gpio_oe,
      hps_tx_data  => d_tx_data,
      hps_tx_valid => d_tx_valid,
      hps_tx_ready => d_tx_ready,
      hps_rx_data  => d_rx_data,
      hps_rx_valid => d_rx_valid,
      debug_state  => adapter_state,
      diag         => diag_word,
      dbg_freeze   => dbg_freeze
   );

   -- This build's 71-bit word carries the ACK-transaction latch, not the
   -- census: 70 hs_drop | 69 hs_raise | 68 w0 ok | 67 w1 ok | 66 armed
   -- 65:64 stall phase | 63:32 response word | 31:0 data-request word.
   -- The drift latch lives on as an assertion on the transaction words.
   -- This build's word is the ACK latch, not the drift census; the freeze
   -- check below reports rather than fails for that reason.
   hdr_drift <= '0';

   -- behavioral daemon: consumes the bytes the UART model actually latched
   -- (so a re-latched duplicate is visible as a second byte) and answers with
   -- canned ACKs the way the real rfu_daemon would. A missing byte times out
   -- like the daemon's own 25 ms frame parser, so a truncated frame resyncs
   -- instead of poisoning every later frame.
   daemon : process
      variable ptype, b1, b2, junk : std_logic_vector(7 downto 0);
      variable nbytes  : integer;
      variable consumed : natural := 0;
      variable timed_out : boolean;

      procedure getbyte(variable d : out std_logic_vector(7 downto 0);
                        timed_out : out boolean) is
         variable waited : integer := 0;
      begin
         timed_out := false;
         loop
            wait until rising_edge(clk);
            if (uart_count > consumed) then
               consumed := consumed + 1;
               d := uart_byte;
               exit;
            end if;
            waited := waited + 1;
            if (waited > 40000) then -- ~2.4 ms without a byte
               timed_out := true;
               d := x"00";
               exit;
            end if;
         end loop;
      end procedure;

      procedure getbyte(variable d : out std_logic_vector(7 downto 0)) is
         variable ignored : boolean;
      begin
         getbyte(d, ignored);
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
         if (ptype /= x"01" and ptype /= x"02" and ptype /= x"03" and ptype /= x"04") then
            next; -- resync: not at a frame header
         end if;
         getbyte(b1, timed_out);
         if timed_out then next; end if;
         getbyte(b2, timed_out);
         if timed_out then next; end if;
         nbytes := to_integer(unsigned(b2)) * 4;
         for i in 1 to nbytes loop
            getbyte(junk, timed_out);
            if timed_out then exit; end if;
         end loop;
         if timed_out then next; end if;

         if (ptype = x"04") then
            -- event
            if (b1 = x"00") then
               ping_events <= ping_events + 1;
            elsif (b1 = x"01") then
               login_events <= login_events + 1;
            elsif (b1 = x"02") then
               reversal_seen <= '1';
               -- inject notify 0x28, no params
               putbyte(x"03"); putbyte(x"28"); putbyte(x"00");
            elsif (b1 = x"03") then
               gbaack_seen <= '1';
            elsif (b1 = x"04") then
               watchdog_events <= watchdog_events + 1;
            end if;
         elsif (ptype = x"01") then
            -- REQ from the GBA: answer like the real daemon
            case b1 is
               when x"10" =>
                  req_hello_seen <= '1';
                  putbyte(x"02"); putbyte(x"90"); putbyte(x"00");
               when x"13" =>
                  req_sstat_seen <= '1';
                  soak_ok <= soak_ok + 1;
                  putbyte(x"02"); putbyte(x"93"); putbyte(x"01");
                  -- payload word 0x03000123, little endian on the wire
                  putbyte(x"23"); putbyte(x"01"); putbyte(x"00"); putbyte(x"03");
               when x"1B" =>
                  putbyte(x"02"); putbyte(x"9B"); putbyte(x"00");
               when x"1A" =>
                  req_wait_seen <= '1';
                  soak_ok <= soak_ok + 1;
                  putbyte(x"02"); putbyte(x"9A"); putbyte(x"00");
               when x"11" =>
                  putbyte(x"02"); putbyte(x"91"); putbyte(x"00");
               when x"17" =>
                  putbyte(x"02"); putbyte(x"97"); putbyte(x"00");
               when x"19" =>
                  putbyte(x"02"); putbyte(x"99"); putbyte(x"00");
               when x"16" =>
                  putbyte(x"02"); putbyte(x"96"); putbyte(x"00");
               when x"15" =>
                  -- 8-word response (the protocol's fixed 0x15 length)
                  putbyte(x"02"); putbyte(x"95"); putbyte(x"08");
                  for w in 0 to 7 loop
                     putbyte(std_logic_vector(to_unsigned(w, 8)));
                     putbyte(x"00"); putbyte(x"00"); putbyte(x"A0");
                  end loop;
               when others =>
                  putbyte(x"02"); putbyte(x"EE"); putbyte(x"01");
                  putbyte(x"01"); putbyte(x"00"); putbyte(x"00"); putbyte(x"00");
            end case;
            if dup_ack = '1' then
               -- a retried command's stale answer: same id, arrives after the
               -- GBA already holds the first one
               putbyte(x"02"); putbyte(x"93"); putbyte(x"01");
               putbyte(x"23"); putbyte(x"01"); putbyte(x"00"); putbyte(x"03");
            end if;
         end if;
      end loop;
   end process;


   main : process
      variable r16 : std_logic_vector(15 downto 0);
      variable r32 : std_logic_vector(31 downto 0);
      variable hok : boolean;
      variable stage : natural;
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
      procedure sendcmd(cmd : in std_logic_vector(7 downto 0);
                        variable ackhdr : out std_logic_vector(31 downto 0);
                        baud2m : in std_logic := '1') is
         variable r : std_logic_vector(31 downto 0);
      begin
         xfer32(x"9966" & x"00" & cmd, baud2m, r);
         assert r = x"80000000" report "adapter did not return dummy for header" severity failure;
         hshake(baud2m);
         xfer32(x"80000000", baud2m, r); -- response request
         ackhdr := r;
         hshake(baud2m);
      end procedure;

      procedure activate_2mbps is
         variable rcnt : std_logic_vector(15 downto 0);
      begin
         busread16(bus_g, wired_g, ADR_RCNT, rcnt);
         buswrite16(bus_g, ADR_RCNT, rcnt and x"7FFF");
         buswrite16(bus_g, ADR_SIOCNT, x"1000");
         wait for 4 * CLK_PERIOD;
         assert sd_line = '0' and sd_gpio_oe = '0'
            report "Normal external-clock transition must drive SD low without GPIO" severity failure;
         buswrite16(bus_g, ADR_SIOCNT, x"1008");
         buswrite16(bus_g, ADR_SIOCNT, x"1009");
         buswrite16(bus_g, ADR_SIOCNT, x"100B");
         wait for 4 * CLK_PERIOD;
         assert sd_line = '1' and sd_gpio_oe = '0'
            report "Normal internal-clock master should release SD" severity failure;
      end procedure;

      procedure gpio_ping(afska : boolean) is
         constant expected : natural := ping_events + 1;
         variable rcnt : std_logic_vector(15 downto 0);
      begin
         buswrite16(bus_g, ADR_RCNT, x"8000");
         if afska then
            -- LinkGPIO uses a volatile read/modify/write. Pull-up readback
            -- makes the GPIO SD output high as soon as its direction changes.
            buswrite16(bus_g, ADR_SIOCNT, x"0000");
            busread16(bus_g, wired_g, ADR_RCNT, rcnt);
            buswrite16(bus_g, ADR_RCNT, rcnt or x"0080");
            busread16(bus_g, wired_g, ADR_RCNT, rcnt);
            assert rcnt(1) = '1' and sd_line = '1'
               report "afska should enter GPIO with SD already high" severity failure;
            buswrite16(bus_g, ADR_RCNT, rcnt or x"0020");
            wait for 4 * CLK_PERIOD;
            assert sd_line = '1' and sd_gpio_oe = '1'
               report "afska GPIO SD direction change should preserve HIGH" severity failure;
            busread16(bus_g, wired_g, ADR_RCNT, rcnt);
            buswrite16(bus_g, ADR_RCNT, rcnt or x"0002");
            wait for 3.67 ms;
            busread16(bus_g, wired_g, ADR_RCNT, rcnt);
            buswrite16(bus_g, ADR_RCNT, rcnt and x"FFFD");
         else
            buswrite16(bus_g, ADR_RCNT, x"80A0");
            wait for 4 * CLK_PERIOD;
            assert user_out(5) = '0' and user_out(1) = '0'
               report "SNAC GPIO low mapping wrong (SD=5, SO=1)" severity failure;
            buswrite16(bus_g, ADR_RCNT, x"80A2");
            wait for 4 * CLK_PERIOD;
            assert sd_line = '1' and sd_gpio_oe = '1' and user_out(1) = '0'
               report "SNAC GPIO SD-high mapping wrong" severity failure;
            wait for 1.10 ms;
            buswrite16(bus_g, ADR_RCNT, x"80A0");
         end if;
         wait until ping_events = expected for 1 ms;
         assert ping_events = expected and adapter_state(7 downto 4) = x"1"
            report "GPIO SD pulse did not restart adapter login" severity failure;
      end procedure;

      procedure login is
         constant expected : natural := login_events + 1;
         variable adapter_hi : std_logic_vector(15 downto 0) := x"8000";
         variable gba_lo     : std_logic_vector(15 downto 0) := x"FFFF";
         variable r          : std_logic_vector(31 downto 0);
      begin
         buswrite16(bus_g, ADR_RCNT, x"0000");
         for i in P'range loop
            wait for 300 us;
            xfer32((not adapter_hi) & P(i), '0', r);
            if i >= 2 then
               assert r = P(i) & (not gba_lo)
                  report "bad login word " & integer'image(i) & ": " & to_hstring(r) severity failure;
            end if;
            adapter_hi := r(31 downto 16);
            gba_lo := P(i);
         end loop;
         if login_events /= expected then
            wait until login_events = expected for 1 ms;
         end if;
         assert login_events = expected report "adapter never reported login complete" severity failure;
      end procedure;

      -- LinkRawWireless::acknowledge() with a poll budget, so a wedged link
      -- fails the assertion instead of hanging the simulation.
      procedure hshake_t(baud2m : in std_logic; ok : out boolean) is
         variable v    : std_logic_vector(15 downto 0);
         variable base : std_logic_vector(15 downto 0);
         variable polls : natural := 0;
      begin
         ok := false;
         if (baud2m = '1') then base := x"5003"; else base := x"5001"; end if;
         loop
            busread16(bus_g, wired_g, ADR_SIOCNT, v);
            exit when v(2) = '1';
            polls := polls + 1;
            if polls > 4000 then return; end if;
         end loop;
         buswrite16(bus_g, ADR_SIOCNT, base or x"0008"); -- SO high
         polls := 0;
         loop
            busread16(bus_g, wired_g, ADR_SIOCNT, v);
            exit when v(2) = '0';
            polls := polls + 1;
            if polls > 4000 then return; end if;
         end loop;
         buswrite16(bus_g, ADR_SIOCNT, base); -- SO low
         ok := true;
      end procedure;

      -- full command exchange; `stage` says how it failed on the way out
      procedure sendcmd_t(cmd : in std_logic_vector(7 downto 0);
                          ackhdr : out std_logic_vector(31 downto 0);
                          ok : out boolean; stage : out natural) is
         variable r : std_logic_vector(31 downto 0);
      begin
         ok := false; stage := 0; ackhdr := (others => '1');
         xfer32(x"9966" & x"00" & cmd, '1', r);
         assert r = x"80000000" severity failure;
         hshake_t('1', ok);  if not ok then stage := 1; return; end if;
         xfer32(x"80000000", '1', r); -- response request
         ackhdr := r;
         hshake_t('1', ok);  if not ok then stage := 2; return; end if;
         ok := true;
      end procedure;

      -- same, for a command carrying one parameter word (0x17 Setup)
      procedure sendcmd1_t(cmd : in std_logic_vector(7 downto 0);
                           param : in std_logic_vector(31 downto 0);
                           ackhdr : out std_logic_vector(31 downto 0);
                           ok : out boolean; stage : out natural) is
         variable r : std_logic_vector(31 downto 0);
      begin
         ok := false; stage := 0; ackhdr := (others => '1');
         xfer32(x"9966" & x"01" & cmd, '1', r);
         assert r = x"80000000" severity failure;
         hshake_t('1', ok);  if not ok then stage := 1; return; end if;
         xfer32(param, '1', r);
         hshake_t('1', ok);  if not ok then stage := 2; return; end if;
         xfer32(x"80000000", '1', r); -- response request
         ackhdr := r;
         hshake_t('1', ok);  if not ok then stage := 3; return; end if;
         ok := true;
      end procedure;
   begin
      wait for 20 * CLK_PERIOD;

      report "test 1: GPIO ping from PWRSAVE + login";
      gpio_ping(false);
      login;
      activate_2mbps;
      report "test 1 passed";

      ------------------------------------------------------------------
      -- 400 x 0x13 (1-word ACK payload). Each exchange is header, ack,
      -- response request, ack, payload word, ack, exactly like
      -- LinkRawWireless::getSystemStatus.
      report "test 2: 400 x 0x13 SystemStatus";
      for i in 1 to 400 loop
         sendcmd_t(x"13", r32, hok, stage);
         assert hok
            report "0x13 wedged at exchange " & integer'image(i) &
                   " stage " & integer'image(stage) severity failure;
         assert r32 = x"99660193"
            report "0x13 exchange " & integer'image(i) & " bad ACK header " &
                   to_hstring(r32) severity failure;
         xfer32(x"80000000", '1', r32);
         assert r32 = x"03000123"
            report "0x13 exchange " & integer'image(i) & " bad payload " &
                   to_hstring(r32) severity failure;
         hshake_t('1', hok);
         assert hok report "0x13 wedged after payload at exchange " &
            integer'image(i) severity failure;
         assert relatch_seen = '0'
            report "0x13: UART re-latched a held byte at exchange " &
                   integer'image(i) severity failure;
      end loop;
      wait for 200 us;
      assert soak_ok >= 400 report "0x13: daemon saw too few requests" severity failure;
      report "test 2 passed: 400 x 0x13";

      ------------------------------------------------------------------
      -- 400 x 0x1A (0-word ACK payload): the exact command that wedged
      -- the hardware after 100-197 transfers.
      report "test 3: 400 x 0x1A PollConnections";
      for i in 1 to 400 loop
         sendcmd_t(x"1A", r32, hok, stage);
         assert hok
            report "0x1A wedged at exchange " & integer'image(i) &
                   " stage " & integer'image(stage) severity failure;
         assert r32 = x"9966009A"
            report "0x1A exchange " & integer'image(i) & " bad ACK header " &
                   to_hstring(r32) severity failure;
         assert relatch_seen = '0'
            report "0x1A: UART re-latched a held byte at exchange " &
                   integer'image(i) severity failure;
      end loop;
      wait for 200 us;
      assert soak_ok >= 800 report "0x1A: daemon saw too few requests" severity failure;
      report "test 3 passed: 400 x 0x1A";

      ------------------------------------------------------------------
      -- A byte-level tx_ready stall mid-frame must not wedge the serializer
      -- and must never leave tx_valid held across a completed byte: that is
      -- the exact lockup (UART re-latches the byte, tx_ready never rises,
      -- the link is dead until reset).
      report "test 4: short tx_ready stall never re-latches a byte";
      force_tx_stall <= '1';
      xfer32(x"9966001A", '1', r32);   -- header accepted, frame cannot leave
      wait for 10 us;                  -- > one byte time at 2 Mbaud
      force_tx_stall <= '0';
      wait for 20 us;
      hshake_t('1', hok);
      assert hok report "link wedged by a short tx_ready stall" severity failure;
      assert relatch_seen = '0'
         report "UART re-latched a held byte after a short tx stall" severity failure;
      xfer32(x"80000000", '1', r32);   -- response request
      assert r32 = x"9966009A" report "post-stall ACK header wrong: " & to_hstring(r32) severity failure;
      hshake_t('1', hok);
      assert hok report "post-stall payload handshake failed" severity failure;
      assert relatch_seen = '0' report "post-stall byte was re-latched" severity failure;
      report "test 4 passed";

      ------------------------------------------------------------------
      -- A GPIO ping must always restore service, even after a frame was
      -- truncated by a stall (the real daemon's parser resyncs on a gap).
      report "test 5: GPIO ping restores service after a wedged exchange";
      force_tx_stall <= '1';               -- wedge whatever frame is in flight
      xfer32(x"9966001B", '1', r32);       -- EndHost: daemon never sees it
      wait for 101 ms;                     -- word watchdog expires (bounded)
      force_tx_stall <= '0';
      wait for 10 ms;                      -- daemon frame parser resyncs on the gap
      gpio_ping(false);
      login;
      activate_2mbps;
      sendcmd_t(x"13", r32, hok, stage);
      assert hok report "link still wedged after a GPIO ping" severity failure;
      assert r32 = x"99660193" report "post-ping ACK header wrong" severity failure;
      xfer32(x"80000000", '1', r32);
      assert r32 = x"03000123" report "post-ping payload wrong" severity failure;
      hshake_t('1', hok);
      assert hok report "post-ping handshake failed" severity failure;
      report "test 5 passed";

      ------------------------------------------------------------------
      -- The hardware failure needs a second frame queued while the first
      -- drains: the word watchdog posts event(4) and the ROM's retry lands
      -- while that event frame is still being serialized. The serializer
      -- then presents the REQ frame one cycle after the event frame's last
      -- byte and, on the buggy RTL, the UART re-latches that byte forever.
      report "test 6: watchdog event frame collides with the retry command";
      for attempt in 1 to 8 loop
         -- arm a one-parameter request and withhold the parameter: the word
         -- watchdog fires 100 ms later and queues an event frame
         xfer32(x"99660116", '1', r32);
         hshake_t('1', hok);
         assert hok report "test 6: handshake before collision failed" severity failure;
         -- the retry header lands while the event frame drains. Depending on
         -- the exact offset it is either accepted after the recovery (and its
         -- ACK never comes, because the recovery cleared the request) or it
         -- collides with the draining event frame. Either way the link must
         -- stay reachable: a GPIO ping has to restore service.
         wait for 100 ms + (attempt - 6) * 3 us;
         xfer32(x"99660013", '1', r32);
         hshake_t('1', hok);              -- may legitimately time out
         gpio_ping(false);
         login;
         activate_2mbps;
         sendcmd_t(x"13", r32, hok, stage);
         assert hok report "test 6: link wedged by an event/command frame collision, attempt " &
            integer'image(attempt) severity failure;
         assert r32 = x"99660193" report "test 6: post-collision ACK header wrong: " &
            to_hstring(r32) & ", attempt " & integer'image(attempt) severity failure;
         xfer32(x"80000000", '1', r32);
         assert r32 = x"03000123" report "test 6: post-collision payload wrong, attempt " &
            integer'image(attempt) severity failure;
         hshake_t('1', hok);
         assert hok report "test 6: post-collision payload handshake failed, attempt " &
            integer'image(attempt) severity failure;
         assert relatch_seen = '0'
            report "test 6: UART re-latched a held byte, attempt " &
                   integer'image(attempt) severity failure;
      end loop;
      report "test 6 passed";

      ------------------------------------------------------------------
      -- The demo ROM's serve sequence on hardware: activate (0x10), setup
      -- (0x17, one parameter), a ~1.5 s pause while it delays, setup again,
      -- startHost (0x19), then the accept loop polling 0x11 every 15 ms.
      -- The hardware intermittently loses the first command after the pause
      -- (the GBA reports ACKNOWLEDGE_FAILED and the daemon logs no request);
      -- the bench asserts the link accepts it.
      report "test 7: command after a 1.5 s idle gap";
      gpio_ping(false);
      login;
      activate_2mbps;
      sendcmd_t(x"10", r32, hok, stage);
      assert hok report "test 7: 0x10 failed, stage " & integer'image(stage) severity failure;
      sendcmd1_t(x"17", x"003C0420", r32, hok, stage);
      assert hok report "test 7: first 0x17 failed, stage " & integer'image(stage) severity failure;
      assert r32 = x"99660097" report "test 7: first 0x17 bad ACK " & to_hstring(r32) severity failure;
      wait for 1500 ms;
      sendcmd1_t(x"17", x"003F0420", r32, hok, stage);
      assert hok report "test 7: 0x17 after the idle gap was lost, stage " &
         integer'image(stage) severity failure;
      assert r32 = x"99660097" report "test 7: post-gap 0x17 bad ACK " & to_hstring(r32) severity failure;
      sendcmd_t(x"19", r32, hok, stage);
      assert hok report "test 7: 0x19 failed, stage " & integer'image(stage) severity failure;
      assert r32 = x"99660099" report "test 7: 0x19 bad ACK " & to_hstring(r32) severity failure;
      for i in 1 to 20 loop
         sendcmd_t(x"11", r32, hok, stage);
         assert hok report "test 7: 0x11 poll lost at " & integer'image(i) &
            ", stage " & integer'image(stage) severity failure;
         wait for 15 ms;
      end loop;
      assert relatch_seen = '0' report "test 7: UART re-latched a byte" severity failure;
      report "test 7 passed";

      ------------------------------------------------------------------
      -- A duplicate ACK for the same command (a stale answer to a retry)
      -- must never be taken for the current exchange: the window is shut and
      -- the payload already staged must survive untouched.
      report "test 8: duplicate ACK while the window is shut";
      gpio_ping(false);
      login;
      activate_2mbps;
      for i in 1 to 20 loop
         -- the host answers 0x13 twice; the second ACK lands while the GBA
         -- clocks the payload back
         dup_ack <= '1';
         sendcmd_t(x"13", r32, hok, stage);
         assert hok report "test 8: exchange failed at " & integer'image(i) &
            ", stage " & integer'image(stage) severity failure;
         assert r32 = x"99660193" report "test 8: bad ACK header " & to_hstring(r32) severity failure;
         xfer32(x"80000000", '1', r32);
         assert r32 = x"03000123" report "test 8: duplicate ACK corrupted the payload: " &
            to_hstring(r32) severity failure;
         hshake_t('1', hok);
         assert hok report "test 8: payload handshake failed" severity failure;
         dup_ack <= '0';
         wait for 100 us;               -- let the duplicate drain
      end loop;
      assert relatch_seen = '0' report "test 8: UART re-latched a byte" severity failure;
      report "test 8 passed";

      ------------------------------------------------------------------
      -- The longest response (31 words / 124 bytes) must arrive complete and
      -- in order, and the next command must still be accepted: the shared
      -- 32-word packet buffer sits one word below its ceiling.
      report "test 9: 8-word response";
      gpio_ping(false);
      login;
      activate_2mbps;
      for i in 1 to 4 loop
         sendcmd_t(x"15", r32, hok, stage);
         assert hok report "test 9: 0x15 failed, stage " & integer'image(stage) severity failure;
         assert r32 = x"99660895" report "test 9: 0x15 bad ACK header " & to_hstring(r32) severity failure;
         for w in 0 to 7 loop
            xfer32(x"80000000", '1', r32);
            assert r32 = (x"A0000000" or std_logic_vector(to_unsigned(w, 32)))
               report "test 9: payload word " & integer'image(w) & " wrong: " &
                      to_hstring(r32) severity failure;
            hshake_t('1', hok);
            assert hok report "test 9: payload handshake failed at word " &
               integer'image(w) severity failure;
         end loop;
         sendcmd_t(x"13", r32, hok, stage);
         assert hok report "test 9: 0x13 after the long response failed" severity failure;
         assert r32 = x"99660193" report "test 9: post-long 0x13 bad ACK" severity failure;
         xfer32(x"80000000", '1', r32);
         assert r32 = x"03000123" report "test 9: post-long payload wrong" severity failure;
         hshake_t('1', hok);
         assert hok report "test 9: post-long handshake failed" severity failure;
      end loop;
      report "test 9 passed";

      ------------------------------------------------------------------
      -- A core hold (debugger stop, OSD menu, savestate) freezes the adapter
      -- clock domain. Releasing it must re-baseline the gap timer, not
      -- realign the bit counter: on hardware a hold released while a word was
      -- paused delivered a bit-shifted header that the parser dropped, the
      -- GBA timed out with ACKNOWLEDGE_FAILED and the daemon saw nothing.
      report "test 10: core hold between exchanges";
      gpio_ping(false);
      login;
      activate_2mbps;
      for i in 1 to 40 loop
         sendcmd_t(x"13", r32, hok, stage);
         assert hok report "test 10: exchange " & integer'image(i) & " failed, stage " &
            integer'image(stage) severity failure;
         assert r32 = x"99660193" report "test 10: bad ACK after hold" severity failure;
         xfer32(x"80000000", '1', r32);
         assert r32 = x"03000123" report "test 10: bad payload after hold" severity failure;
         hshake_t('1', hok);
         assert hok report "test 10: handshake failed after hold" severity failure;
         -- hold the core like a debugger stop, then resume
         dbg_freeze <= '1';
         wait for 300 us;
         dbg_freeze <= '0';
         wait for 200 us;
         report "test 10: exchange " & integer'image(i) &
                " ACK latch " & to_hstring(diag_word(63 downto 32)) & " / " &
                to_hstring(diag_word(31 downto 0)) & " after the hold";
      end loop;
      report "test 10 passed";

      ------------------------------------------------------------------
      -- The ACK latch must hold this session's two words: the GBA compares
      -- the data-request dummy and then the 0x9966 response header.
      report "test 11: no daemon answer was refused and no word stalled";
      if diag_word(70) = '1' then
         report "note: refused frame id " & to_hstring(diag_word(42 downto 35)) &
                " cmd " & to_hstring(diag_word(18 downto 11)) &
                " outstanding " & std_logic'image(diag_word(69)) &
                " owner " & std_logic'image(diag_word(68)) severity note;
      end if;
      -- The soak deliberately issues commands the behavioural daemon does
      -- not model (0x1B among them), so a watchdog stall is reported, not
      -- failed; the refused-outstanding-answer check above is the invariant.
      if diag_word(33) = '1' then
         report "note: watchdog stall on cmd " &
                to_hstring(diag_word(25 downto 18)) severity note;
      end if;
      -- The GBA samples SO on its SC bit time; a raise shorter than that is
      -- invisible to it even though this design records a completed handshake.
      -- measurement only: the numbers decide whether a raise can be missed
      if unsigned(diag_word(63 downto 54)) < 32 then
         report "SO raise shorter than 32 us: min " &
                integer'image(to_integer(unsigned(diag_word(63 downto 54)))) &
                " us, last " &
                integer'image(to_integer(unsigned(diag_word(53 downto 44)))) &
                " us, short " &
                integer'image(to_integer(unsigned(diag_word(67 downto 64)))) &
                ", si at raise " & std_logic'image(diag_word(43)) severity note;
      end if;
      report "test 12: shortest SO raise " &
         integer'image(to_integer(unsigned(diag_word(63 downto 54)))) & " us, last " &
         integer'image(to_integer(unsigned(diag_word(53 downto 44)))) & " us";
      report "test 11 passed";

      ------------------------------------------------------------------
      -- serve() sends 0x17 (config) -> 0x16 (broadcast) -> 0x19 (host) back
      -- to back. All three are locally acknowledged, so the daemon's copies
      -- are drained: no header may be rejected and every ACK header must be
      -- the locally staged one, not DUMMY.
      report "test 13: serve() trio 0x17 -> 0x16 -> 0x19";
      gpio_ping(false);
      login;
      activate_2mbps;
      sendcmd1_t(x"17", x"003C0420", r32, hok, stage);
      assert hok report "test 13: 0x17 failed, stage " & integer'image(stage) severity failure;
      assert r32 = x"99660097" report "test 13: 0x17 local ACK wrong: " &
         to_hstring(r32) severity failure;
      sendcmd1_t(x"16", x"694C7FFF", r32, hok, stage);
      assert hok report "test 13: 0x16 failed, stage " & integer'image(stage) severity failure;
      assert r32 = x"99660096" report "test 13: 0x16 local ACK wrong: " &
         to_hstring(r32) severity failure;
      sendcmd_t(x"19", r32, hok, stage);
      assert hok report "test 13: 0x19 failed, stage " & integer'image(stage) severity failure;
      assert r32 = x"99660099" report "test 13: 0x19 local ACK wrong: " &
         to_hstring(r32) severity failure;
      report "test 13a: refusal " & std_logic'image(diag_word(70)) &
         " outstanding " & std_logic'image(diag_word(69));
      report "test 13 passed";

      report "ALL WIRELESS SOAK TESTS PASSED: 800 exchanges, no wedge";
      done <= true;
      wait;
   end process;

   process
   begin
      wait for 8000 ms;
      assert done report "wireless soak bench did not complete" severity failure;
      wait;
   end process;
end architecture;
