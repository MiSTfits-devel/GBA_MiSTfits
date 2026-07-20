-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;


entity tb_rtc_dst is
end entity;

architecture sim of tb_rtc_dst is

   constant CLK_PERIOD : time := 10 ns;

   signal clk  : std_logic := '0';
   signal done : boolean := false;

   signal reset         : std_logic := '1';
   signal GBA_on        : std_logic := '0';
   signal savestate_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   signal RTC_timestampNew : std_logic := '0';
   signal RTC_timestampIn  : std_logic_vector(31 downto 0) := (others => '0');
   signal RTC_saveLoaded   : std_logic := '0';
   signal RTC_savedtimeOut : std_logic_vector(41 downto 0);
   signal RTC_dstPlusHour  : std_logic := '0';

   alias out_year : std_logic_vector(7 downto 0) is RTC_savedtimeOut(41 downto 34);
   alias out_mon  : std_logic_vector(4 downto 0) is RTC_savedtimeOut(33 downto 29);
   alias out_mday : std_logic_vector(5 downto 0) is RTC_savedtimeOut(28 downto 23);
   alias out_wday : std_logic_vector(2 downto 0) is RTC_savedtimeOut(22 downto 20);
   alias out_hour : std_logic_vector(5 downto 0) is RTC_savedtimeOut(19 downto 14);
   alias out_min  : std_logic_vector(6 downto 0) is RTC_savedtimeOut(13 downto 7);

   constant SEED_WAIT : time := 40000 * CLK_PERIOD;

   procedure rearm(signal GBA_on : out std_logic) is
   begin
      GBA_on <= '1';
      wait for 4 * CLK_PERIOD;
      GBA_on <= '0';
      wait for 4 * CLK_PERIOD;
   end procedure;

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   idut : entity work.gba_gpioRTCSolarGyro
   port map
   (
      clk1x               => clk,
      reset               => reset,
      GBA_on              => GBA_on,
      rtc_noselect_quirk  => '0',

      savestate_bus       => savestate_bus,
      ss_wired_out        => open,
      ss_wired_done       => open,

      GPIO_readEna        => '0',
      GPIO_done           => open,
      GPIO_Din            => open,
      GPIO_Dout           => "0000",
      GPIO_writeEna       => '0',
      GPIO_addr           => "00",

      RTC_timestampNew    => RTC_timestampNew,
      RTC_timestampIn     => RTC_timestampIn,
      RTC_timestampSaved  => (others => '0'),
      RTC_savedtimeIn     => (others => '0'),
      RTC_saveLoaded      => RTC_saveLoaded,
      RTC_timestampOut    => open,
      RTC_savedtimeOut    => RTC_savedtimeOut,
      RTC_inuse           => open,
      RTC_dstPlusHour     => RTC_dstPlusHour,

      rumble              => open,
      AnalogX             => (others => '0'),
      solar_in            => "000"
   );

   process
   begin
      wait for 10 * CLK_PERIOD;
      wait until rising_edge(clk);
      reset <= '0';

      RTC_timestampIn  <= std_logic_vector(to_unsigned(1783418400, 32));
      RTC_dstPlusHour  <= '0';
      wait until rising_edge(clk);
      RTC_timestampNew <= '1';
      wait for SEED_WAIT;

      assert out_year = x"26"      report "case1: year wrong, got 0x"    & to_hstring(out_year) severity failure;
      assert out_mon  = "00111"    report "case1: month wrong, got 0b"   & to_string(out_mon)   severity failure;
      assert out_mday = "000111"   report "case1: day wrong, got 0b"     & to_string(out_mday)  severity failure;
      assert out_wday = "010"      report "case1: weekday wrong, got 0b" & to_string(out_wday)  severity failure;
      assert out_hour = "010000"   report "case1: hour wrong, got 0b"    & to_string(out_hour)  severity failure;
      assert out_min  = "0000000"  report "case1: minute wrong, got 0b"  & to_string(out_min)   severity failure;
      report "case1 ok: DST off decodes 2026-07-07 10:00:00 UTC verbatim";

      rearm(GBA_on);

      RTC_dstPlusHour  <= '1';
      RTC_timestampNew <= '0';
      wait until rising_edge(clk);
      RTC_timestampNew <= '1';
      wait for SEED_WAIT;

      assert out_mday = "000111" report "case2: day should be unchanged, got 0b" & to_string(out_mday) severity failure;
      assert out_hour = "010001" report "case2: hour should be 11 (10+1), got 0b" & to_string(out_hour) severity failure;
      report "case2 ok: DST on adds exactly one hour without touching the date";

      rearm(GBA_on);

      RTC_timestampIn  <= std_logic_vector(to_unsigned(1783467000, 32));
      RTC_dstPlusHour  <= '1';
      RTC_timestampNew <= '0';
      wait until rising_edge(clk);
      RTC_timestampNew <= '1';
      wait for SEED_WAIT;

      assert out_mday = "001000"  report "case3: day should roll to the 8th, got 0b"   & to_string(out_mday) severity failure;
      assert out_hour = "000000"  report "case3: hour should wrap to 0, got 0b"        & to_string(out_hour) severity failure;
      assert out_min  = "0110000" report "case3: minute should stay 30, got 0b"        & to_string(out_min)  severity failure;
      assert out_wday = "011"     report "case3: weekday should roll to Wednesday, got 0b" & to_string(out_wday) severity failure;
      report "case3 ok: DST correction cascades a midnight day/weekday rollover correctly";

      report "tb_rtc_dst all checks passed";
      done <= true;
      wait;
   end process;

end architecture;
