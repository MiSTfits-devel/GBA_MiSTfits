-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- unit testbench for the sound PWM output stage (issue #143): the noise
--
-- run: sim/run_soundpwm_tb.sh

entity tb_soundpwm is
end entity;

architecture sim of tb_soundpwm is

   constant CLK_PERIOD : time := 10 ns;

   signal clk       : std_logic := '0';
   signal ce        : std_logic := '1';  -- clk1x is the 16.78MHz domain, ce is the pause gate and stays high
   signal done      : boolean := false;

   signal gb_bus    : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal ss_bus    : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal wired     : std_logic_vector(31 downto 0);

   signal reset     : std_logic := '1';

   signal snd_l     : std_logic_vector(15 downto 0);
   signal snd_r     : std_logic_vector(15 downto 0);

   -- checker control
   signal chk_ena   : std_logic := '0';
   signal chk_seen  : integer := 0;

   constant ADR_SOUND4CNT_L : integer := 16#78#;
   constant ADR_SOUND4CNT_H : integer := 16#7C#;
   constant ADR_SOUNDCNT_L  : integer := 16#80#;
   constant ADR_SOUNDCNT_H  : integer := 16#82#;
   constant ADR_SOUNDCNT_X  : integer := 16#84#;
   constant ADR_SOUNDBIAS   : integer := 16#88#;

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

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   isound : entity work.gba_sound
   generic map ( turbosound => '0' )
   port map
   (
      clk1x             => clk,
      ce                => ce,
      reset             => reset,
      loading_savestate => '0',
      savestate_bus     => ss_bus,
      ss_wired_out      => open,
      ss_wired_done     => open,
      gb_bus            => gb_bus,
      wired_out         => wired,
      wired_done        => open,
      lockspeed         => '1',
      timer0_tick       => '0',
      timer1_tick       => '0',
      sound_dma_req     => open,
      sound_out_left    => snd_l,
      sound_out_right   => snd_r,
      debug_fifocount   => open
   );

   process (clk)
      variable last_val    : std_logic_vector(15 downto 0) := (others => '0');
   begin
      if rising_edge(clk) then
         if (chk_ena = '0') then
            last_val    := snd_l;
            chk_seen    <= 0;
         elsif (snd_l /= last_val) then
            last_val    := snd_l;
            chk_seen    <= chk_seen + 1;
         end if;
      end if;
   end process;

   process
   begin
      gb_bus.rst <= '1';
      ss_bus.rst <= '1';
      wait for 10 * CLK_PERIOD;
      wait until rising_edge(clk);
      gb_bus.rst <= '0';
      ss_bus.rst <= '0';
      reset      <= '0';

      -- master on, ch4 left+right at full volume, fastest noise, no envelope
      buswrite16(gb_bus, ADR_SOUNDCNT_X,  x"0080");
      buswrite16(gb_bus, ADR_SOUNDCNT_L,  x"8877");
      buswrite16(gb_bus, ADR_SOUNDCNT_H,  x"0002");
      buswrite16(gb_bus, ADR_SOUNDBIAS,   x"0200");
      buswrite16(gb_bus, ADR_SOUND4CNT_L, x"F000");
      buswrite16(gb_bus, ADR_SOUND4CNT_H, x"8000");

      wait for 100 * CLK_PERIOD;
      chk_ena   <= '1';
      wait for 24000 * CLK_PERIOD;       -- ~46 PWM periods
      assert chk_seen >= 5 report "phase 1: noise never changed the held output (" & integer'image(chk_seen) & " changes)" severity failure;
      chk_ena   <= '0';
      report "phase 1 ok: 32.768kHz PWM reconstructed at 96kHz, " & integer'image(chk_seen) & " changes";

      buswrite16(gb_bus, ADR_SOUNDBIAS, x"C200");
      wait for 2400 * CLK_PERIOD;       -- let the new setting take a few periods
      chk_ena   <= '1';
      wait for 24000 * CLK_PERIOD;      -- ~375 PWM periods
      assert chk_seen >= 20 report "phase 2: noise never changed the held output (" & integer'image(chk_seen) & " changes)" severity failure;
      chk_ena   <= '0';
      report "phase 2 ok: 262.144kHz PWM reconstructed at 96kHz, " & integer'image(chk_seen) & " changes";

      report "tb_soundpwm all checks passed";
      done <= true;
      wait;
   end process;

end architecture;
