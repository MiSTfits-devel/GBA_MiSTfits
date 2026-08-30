-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- Oracle bench for gba_wireless against Nintendo's OWN driver.
--
-- WHY THIS EXISTS, and how it differs from sim/tb_wireless.vhd:
--   tb_wireless.vhd declares its own copy of the 10-entry login keystream
--   -- the SAME constant that gba_wireless.vhd implements -- and replays it
--   back at the DUT. That is a self-consistency check: it passes whether or
--   not a real GBA can ever log in. It cannot answer "does Pokemon work".
--
--   This bench instead ports the real algorithm out of pret/pokeemerald
--   src/librfu_sio32id.c (Sio32IDIntr / Sio32IDMain / AgbRFU_checkID) and
--   src/librfu_stwi.c (AgbRFU_SoftReset) LITERALLY, line for line. The
--   stimulus is therefore an independent authority: librfu decides for
--   itself what to send and what to accept, exactly as a real cartridge
--   does. Whatever this bench says about our RTL is a real verdict.
--
-- What librfu does, for readers without the C to hand:
--   AgbRFU_SoftReset()  RCNT 0x8000 -> 0x80A0 -> 0x80A2 (SD high ~1.13ms)
--                       -> 0x80A0 (SD low). An SD pulse -- same gesture
--                       afska's pingAdapter() uses, just spelled in RCNT.
--   Sio32IDInit()       RCNT=0, SIOCNT=32bit|irq|enable
--   Sio32IDMain() st0   SIOCNT |= 0x0001. NOTE: the constant is spelled
--                       SIO_38400_BPS but in Normal-32 mode bit0 is the
--                       internal-shift-clock select, so this means
--                       "master, 256 kHz" -- NOT 38400 baud.
--   Sio32IDIntr()       per completed word, with MS_mode = AGB_CLK_MASTER:
--                         adapterLo := received(15 downto 0)
--                         adapterHi := received(31 downto 16)
--                         if adapterLo = recv_id then
--                            if count < 4 then
--                               if recv_id = not send_id
--                                  and adapterHi = not recv_id then
--                                     count := count + 1
--                            else lastId := adapterHi      -- expect 0x8001
--                         else count := 0                  -- resync
--                         send_id := count<4 ? NINTENDO(count) : RFU_ID
--                         recv_id := not adapterHi
--                         transmit recv_id & send_id       -- hi & lo
--
--   So the GBA transmits the NINTENDO word in the LOW half and its
--   complement-echo in the HIGH half, and it advances `count` ONLY on a
--   fully matching round. `count` is a live state machine, not a script.
--
-- The pass condition is librfu's own: AgbRFU_checkID must observe
-- lastId = RFU_ID (0x8001). Anything else is a real-hardware failure.
--
-- run: sim/run_wireless_librfu_tb.sh
entity tb_wireless_librfu is
   generic (
      -- how many word exchanges to grant librfu before declaring failure
      MAX_EXCHANGES : integer := 48
   );
end entity;

architecture sim of tb_wireless_librfu is

   constant CLK_PERIOD : time := 59.6 ns;
   constant CLKSPEED   : integer := 16777216;

   signal clk   : std_logic := '0';
   signal done  : boolean := false;

   signal bus_g   : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal wired_g : std_logic_vector(31 downto 0);
   signal irq_g   : std_logic;
   signal irq_seen: std_logic := '0';
   signal irq_clr : std_logic := '0';

   signal g_clk_out, g_clk_oe, g_so_out, g_so_oe, g_sd_out, g_sd_oe : std_logic;
   signal a_sc_out, a_sc_oe, a_so_out, a_so_oe : std_logic;

   signal sc_line, sd_line, gba_si, adp_si : std_logic;
   signal lp_clk_in, lp_si_in, lp_sd_in     : std_logic;
   signal user_in, user_out                 : std_logic_vector(6 downto 0);

   signal d_tx_data  : std_logic_vector(7 downto 0);
   signal d_tx_valid : std_logic;
   signal d_tx_ready : std_logic := '1';
   signal d_rx_data  : std_logic_vector(7 downto 0) := (others => '0');
   signal d_rx_valid : std_logic := '0';

   signal ping_seen       : std_logic := '0';
   signal login_done_seen : std_logic := '0';

   constant ADR_SIODATA32 : integer := 16#120#;
   constant ADR_SIOCNT    : integer := 16#128#;
   constant ADR_RCNT      : integer := 16#134#;

   -- librfu constants, verbatim from librfu_sio32id.c / librfu.h
   type tNintendo is array(0 to 3) of std_logic_vector(15 downto 0);
   constant Sio32ConnectionData : tNintendo :=
      (x"494E", x"544E", x"4E45", x"4F44"); -- "NINTENDO"
   constant RFU_ID : std_logic_vector(15 downto 0) := x"8001";

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

   -- identical SNAC wiring to tb_wireless.vhd: creator-confirmed pins
   -- SC=USER_IO[0], SO=[1], SI=[2], SD=[5]
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

   -- passive daemon: consume and log the adapter's event bytes only.
   -- The ID check never reaches command phase, so no ACKs are needed.
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
   begin
      loop
         getbyte(ptype);
         getbyte(b1);
         getbyte(b2);
         nbytes := to_integer(unsigned(b2)) * 4;
         for i in 1 to nbytes loop
            getbyte(junk);
         end loop;
         if (ptype = x"04") then
            case b1 is
               when x"00" =>
                  ping_seen <= '1';
                  report "adapter event: PING RESET (woke from PWRSAVE)";
               when x"01" =>
                  login_done_seen <= '1';
                  report "adapter event: LOGIN COMPLETE";
               when x"04" =>
                  report "adapter event: word watchdog fired";
               when others =>
                  report "adapter event: " & to_hstring(b1);
            end case;
         end if;
      end loop;
   end process;

   main : process
      variable r32 : std_logic_vector(31 downto 0);

      -- librfu ISR state (struct RfuSIO32Id), zeroed by Sio32IDInit's CpuFill32
      variable send_id : std_logic_vector(15 downto 0) := x"0000";
      variable recv_id : std_logic_vector(15 downto 0) := x"0000";
      variable lastId  : std_logic_vector(15 downto 0) := x"0000";
      variable count   : integer := 0;
      variable maxcount_reached : integer := 0;

      variable adapterHi, adapterLo : std_logic_vector(15 downto 0);
      variable txword : std_logic_vector(31 downto 0);
      variable nex    : integer := 0;

      -- one blocking Normal-32 master transfer at 256 kHz
      -- (SIOCNT: 32bit | irq | start | internal clock, bit1=0 => 256kHz)
      procedure xfer32(d : in std_logic_vector(31 downto 0); variable res : out std_logic_vector(31 downto 0)) is
      begin
         buswrite32(bus_g, ADR_SIODATA32, d);
         irq_clr <= '1';
         wait for 4 * CLK_PERIOD;
         irq_clr <= '0';
         buswrite16(bus_g, ADR_SIOCNT, x"5081");
         wait until irq_seen = '1' for 3 ms;
         assert irq_seen = '1'
            report "librfu: SIO transfer never completed -- the GBA side hung"
            severity failure;
         busread32(bus_g, wired_g, ADR_SIODATA32, res);
      end procedure;
   begin
      wait for 20 * CLK_PERIOD;

      ------------------------------------------------------------------
      report "=== AgbRFU_SoftReset(): RCNT SD pulse ===";
      -- librfu_stwi.c AgbRFU_SoftReset(), verbatim register sequence
      buswrite16(bus_g, ADR_RCNT, x"8000");
      buswrite16(bus_g, ADR_RCNT, x"80A0");
      wait for 4 * CLK_PERIOD;
      assert user_out(5) = '0'
         report "RCNT 0x80A0 should drive SD low on USER_IO[5]" severity failure;
      buswrite16(bus_g, ADR_RCNT, x"80A2"); -- SD high
      wait for 4 * CLK_PERIOD;
      assert user_out(5) = '1'
         report "RCNT 0x80A2 should drive SD high on USER_IO[5]" severity failure;
      -- while (*timerL <= 0x11) with TIMER_1024CLK => 0x12 * 1024 cycles
      wait for 1.13 ms;
      buswrite16(bus_g, ADR_RCNT, x"80A0"); -- SD low -> adapter must reset
      wait for 100 us;

      wait until ping_seen = '1' for 1 ms;
      assert ping_seen = '1'
         report "adapter never detected librfu's RCNT SD pulse -- it is still "
              & "in PWRSAVE and no Pokemon game could ever reach login"
         severity failure;

      ------------------------------------------------------------------
      report "=== Sio32IDInit() + Sio32IDMain() state 0 ===";
      buswrite16(bus_g, ADR_RCNT, x"0000");  -- REG_RCNT = 0
      -- REG_SIOCNT = SIO_32BIT_MODE; |= SIO_INTR_ENABLE | SIO_ENABLE
      -- then Main state 0 sets bit0 (internal clock / "SIO_38400_BPS").
      -- The first transfer is started WITHOUT writing SIODATA32 first --
      -- librfu genuinely sends whatever the register happens to hold.
      wait for 50 us;

      report "=== AgbRFU_checkID(): complement-echo ID handshake ===";
      txword := x"00000000";  -- SIODATA32 as left by reset

      while nex < MAX_EXCHANGES and lastId /= RFU_ID loop
         xfer32(txword, r32);
         nex := nex + 1;

         -- ---- Sio32IDIntr(), MS_mode = AGB_CLK_MASTER ----------------
         adapterLo := r32(15 downto 0);   -- (v << 16) >> 16
         adapterHi := r32(31 downto 16);  -- (v <<  0) >> 16

         report "ex " & integer'image(nex) &
                ": GBA tx=" & to_hstring(txword) &
                " adapter rx=" & to_hstring(r32) &
                " | count=" & integer'image(count) &
                " send_id=" & to_hstring(send_id) &
                " recv_id=" & to_hstring(recv_id);

         if (lastId = x"0000") then
            if (adapterLo = recv_id) then
               if (count < 4) then
                  if (recv_id = not send_id) then
                     if (adapterHi = not recv_id) then
                        count := count + 1;
                        if count > maxcount_reached then
                           maxcount_reached := count;
                        end if;
                        report "   -> librfu accepted round, count=" & integer'image(count);
                     end if;
                  end if;
               else
                  lastId := adapterHi;
                  report "   -> librfu latched lastId=" & to_hstring(lastId);
               end if;
            else
               if (count /= 0) then
                  report "   -> librfu RESYNC (adapterLo " & to_hstring(adapterLo) &
                         " /= recv_id " & to_hstring(recv_id) & "), count 0";
               end if;
               count := 0;
            end if;
         end if;

         if (count < 4) then
            send_id := Sio32ConnectionData(count);
         else
            send_id := RFU_ID;
         end if;
         recv_id := not adapterHi;
         txword  := recv_id & send_id;   -- hi = recv_id, lo = send_id
         -- --------------------------------------------------------------

         -- the ISR's `for (delay = 0; delay < 600; ++delay)` spin, then
         -- REG_SIOCNT |= SIO_ENABLE re-arms the next word
         wait for 150 us;
      end loop;

      ------------------------------------------------------------------
      report "=== RESULT ===";
      report "exchanges run: " & integer'image(nex) &
             "   highest count reached: " & integer'image(maxcount_reached) &
             "/4   lastId=" & to_hstring(lastId);

      assert lastId = RFU_ID
         report "LIBRFU ID CHECK FAILED: AgbRFU_checkID never saw RFU_ID " &
                "(0x8001) after " & integer'image(nex) & " exchanges; best " &
                "count was " & integer'image(maxcount_reached) & "/4. " &
                "IsWirelessAdapterConnected() would return FALSE, so every " &
                "Pokemon wireless feature is unreachable on this RTL."
         severity failure;

      report "LIBRFU ID CHECK PASSED: adapter returned RFU_ID 0x8001";
      done <= true;
      wait;
   end process;

end architecture;
