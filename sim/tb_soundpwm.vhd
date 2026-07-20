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

   signal xq_audio_on : std_logic := '0';
   signal robby_mode  : std_logic := '0';

   -- checker control
   signal chk_ena   : std_logic := '0';
   signal chk_seen  : integer := 0;
   signal cadence_ena : std_logic := '0';

   constant ADR_SOUND1CNT_L : integer := 16#60#;
   constant ADR_SOUND1CNT_H : integer := 16#62#;
   constant ADR_SOUND1CNT_X : integer := 16#64#;
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
      xq_audio_on       => xq_audio_on,
      robby_mode        => robby_mode,
      timer0_tick       => '0',
      timer1_tick       => '0',
      sound_dma_req     => open,
      sound_out_left    => snd_l,
      sound_out_right   => snd_r,
      debug_fifocount   => open
   );

   process (clk)
      variable last_val    : std_logic_vector(15 downto 0) := (others => '0');
      variable phase       : integer range 0 to 16_777_215 := 0;
      variable boundary    : boolean := false;
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            phase    := 0;
            boundary := false;
         elsif (ce = '1') then
            if (cadence_ena = '1' and snd_l /= last_val) then
               assert boundary report "96kHz output changed between resample boundaries" severity failure;
            end if;
            if (phase + 96_000 >= 16_777_216) then
               phase := phase + 96_000 - 16_777_216;
               boundary := true;
            else
               phase := phase + 96_000;
               boundary := false;
            end if;
         elsif (cadence_ena = '1' and snd_l /= last_val) then
            assert boundary report "paused output changed without a pending resample boundary" severity failure;
            boundary := false;
         end if;

         if (chk_ena = '0') then
            chk_seen    <= 0;
         elsif (snd_l /= last_val) then
            chk_seen    <= chk_seen + 1;
         end if;
         last_val := snd_l;
      end if;
   end process;

   process
      variable held : std_logic_vector(15 downto 0);
   begin
      gb_bus.rst <= '1';
      ss_bus.rst <= '1';
      wait for 10 * CLK_PERIOD;
      wait until rising_edge(clk);
      gb_bus.rst <= '0';
      ss_bus.rst <= '0';
      reset      <= '0';

      buswrite16(gb_bus, ADR_SOUNDCNT_X,  x"0080");
      buswrite16(gb_bus, ADR_SOUNDBIAS,   x"0301");
      wait for 1200 * CLK_PERIOD;
      assert signed(snd_l) = 4096 report "9-bit PWM/resampler positive DC gain is not unity" severity failure;

      reset <= '1';
      wait for 2 * CLK_PERIOD;
      assert signed(snd_l) = 0 report "resampler output was not cleared by reset" severity failure;
      reset <= '0';
      wait for 1200 * CLK_PERIOD;
      assert signed(snd_l) = 4096 report "resampler did not recover after reset" severity failure;

      buswrite16(gb_bus, ADR_SOUNDBIAS, x"0101");
      wait for 1200 * CLK_PERIOD;
      assert signed(snd_l) = -4096 report "9-bit PWM/resampler negative DC gain is not unity" severity failure;

      -- master on, ch4 left+right at full volume, fastest noise, no envelope
      buswrite16(gb_bus, ADR_SOUNDCNT_L,  x"8877");
      buswrite16(gb_bus, ADR_SOUNDCNT_H,  x"0002");
      buswrite16(gb_bus, ADR_SOUNDBIAS,   x"0200");
      buswrite16(gb_bus, ADR_SOUND4CNT_L, x"F000");
      buswrite16(gb_bus, ADR_SOUND4CNT_H, x"8000");

      wait for 100 * CLK_PERIOD;
      cadence_ena <= '1';
      chk_ena   <= '1';
      wait for 24000 * CLK_PERIOD;       -- ~46 PWM periods
      assert chk_seen >= 5 report "phase 1: noise never changed the held output (" & integer'image(chk_seen) & " changes)" severity failure;
      chk_ena   <= '0';
      report "phase 1 ok: 32.768kHz PWM reconstructed at 96kHz, " & integer'image(chk_seen) & " changes";

      held := snd_l;
      ce <= '0';
      wait for 500 * CLK_PERIOD;
      assert snd_l = held report "audio output changed while the GBA clock enable was paused" severity failure;
      ce <= '1';
      wait for 10 * CLK_PERIOD;
      buswrite16(gb_bus, ADR_SOUND4CNT_L, x"F000");
      buswrite16(gb_bus, ADR_SOUND4CNT_H, x"8000");

      buswrite16(gb_bus, ADR_SOUNDBIAS, x"C200");
      wait for 2400 * CLK_PERIOD;       -- let the new setting take a few periods
      chk_ena   <= '1';
      wait for 24000 * CLK_PERIOD;      -- ~375 PWM periods
      assert chk_seen >= 20 report "phase 2: noise never changed the held output (" & integer'image(chk_seen) & " changes)" severity failure;
      chk_ena   <= '0';
      cadence_ena <= '0';
      report "phase 2 ok: 262.144kHz PWM reconstructed at 96kHz, " & integer'image(chk_seen) & " changes";

      -- phase 3: channels 1-3 must NOT be held/quantized to the PWM rate
      -- (Robert/MiSTer-devel's ask: "keep the other channels as they are").
      -- ch4 off, ch1 running fast (131072Hz) against the *coarsest* PWM
      -- setting (32.768kHz, 512-cycle hold). If ch1 were still forced
      -- through the same sample&hold as ch4, the output could change at
      -- most once per 512-cycle PWM period -- about 24000/512 = 46 times in
      -- this window, the same ballpark as phase 1's ch4-driven count. If
      -- ch1 bypasses that hold as intended, changes should track the full
      -- ~96kHz resample rate instead (up to ~24000*96000/16777216 = 137).
      buswrite16(gb_bus, ADR_SOUNDCNT_L,  x"1177");  -- ch1 L+R only, master vol max, ch2-4 off
      buswrite16(gb_bus, ADR_SOUNDBIAS,   x"0200");  -- 9bit / 32.768kHz -- coarsest hold
      buswrite16(gb_bus, ADR_SOUND1CNT_L, x"0000");  -- no sweep
      buswrite16(gb_bus, ADR_SOUND1CNT_H, x"F080");  -- 50%-ish duty, no envelope, max volume
      -- load the frequency divider before triggering: freq_cnt is seeded
      -- from freq_divider on the SAME edge Initial is written, using its
      -- pre-write (stale) value if both are written together
      buswrite16(gb_bus, ADR_SOUND1CNT_X, x"07FF");  -- max frequency (131072Hz), not yet triggered
      buswrite16(gb_bus, ADR_SOUND1CNT_X, x"87FF");  -- trigger, frequency already loaded

      xq_audio_on <= '1';
      wait for 2400 * CLK_PERIOD;       -- let ch1 start up and settle
      cadence_ena <= '1';               -- still must only change on a resample boundary
      chk_ena     <= '1';
      wait for 24000 * CLK_PERIOD;
      chk_ena     <= '0';
      cadence_ena <= '0';
      assert chk_seen > 80 report "phase 3: ch1 output only changed " & integer'image(chk_seen) & " times -- looks quantized to the PWM rate instead of running at full native resolution" severity failure;
      report "phase 3 ok: xq_audio_on='1', ch1 (unquantized) changed " & integer'image(chk_seen) & " times in a window where PWM-held ch4 changed under 50";

      -- phase 4: xq_audio_on='0' (the default) must reproduce the original,
      -- strictly hardware-accurate behavior -- the same ch1 setup, still
      -- held down to the coarse PWM rate along with everything else
      xq_audio_on <= '0';
      wait for 2400 * CLK_PERIOD;
      cadence_ena <= '1';
      chk_ena     <= '1';
      wait for 24000 * CLK_PERIOD;
      chk_ena     <= '0';
      cadence_ena <= '0';
      assert chk_seen <= 80 report "phase 4: xq_audio_on='0' should reproduce the original PWM-held behavior, but ch1 changed " & integer'image(chk_seen) & " times -- looks unquantized" severity failure;
      report "phase 4 ok: xq_audio_on='0', ch1 correctly held down to the PWM rate, " & integer'image(chk_seen) & " changes";

      robby_mode  <= '1';
      wait for 2400 * CLK_PERIOD;
      chk_ena     <= '1';
      wait for 150 * CLK_PERIOD;
      chk_ena     <= '0';
      assert chk_seen >= 2 report "phase 5: robby_mode='1' only changed " & integer'image(chk_seen) & " times in 150 native cycles (< one 174-cycle resample period) -- looks decimated, not raw native-rate" severity failure;
      report "phase 5 ok: robby_mode='1', ch1 changed " & integer'image(chk_seen) & " times within a single resample period -- confirmed native-rate, undecimated";
      robby_mode  <= '0';

      report "tb_soundpwm all checks passed";
      done <= true;
      wait;
   end process;

end architecture;
