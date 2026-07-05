-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Unit bench for the WP4 dual-mode scanout + frame pacing loop:
-- real videoout160 (dual = '1') + two real gba_ctrl_pause instances
-- (is_simu = '0', the HARDWARE configuration -- the full-core benches can't
-- exercise this because is_simu bypasses allowUnpause), driven by two
-- synthetic "cores" that raster GBA-shaped pixel streams gated by their ce.
--
-- Hunted failure modes (hardware symptom: GBA 1 paints one frame then the
-- picture freezes, GBA 2 side never shows, OSD alive):
--   * pauseState wedge: requestPause never released or allowUnpause never
--     granted -> both cores stop (audio would stop too)
--   * scanout death: the fractional y=264 frame reset misses in dual mode,
--     y saturates at 511 -> vsync/fetch stop, display freezes on the last
--     frame while the cores keep running (audio keeps playing)
--
-- Checks: vsync must keep a steady cadence, both cores must keep rendering
-- frames, and every pause request must resolve within two output frames.
--
-- run: sim/run_pause160_tb.sh  (a few output frames, seconds of wall time)

entity tb_pause160 is
   generic
   (
      dual : std_logic := '1'
   );
end entity;

architecture sim of tb_pause160 is

   constant CLK1X_PERIOD : time := 60 ns;
   constant CLK3X_PERIOD : time := 20 ns;

   signal clk1x : std_logic := '0';
   signal clk3x : std_logic := '0';

   -- fake core 1 / core 2 rasterizers
   signal c1_ce, c2_ce                 : std_logic;
   signal c1_pause_active, c2_pause_active : std_logic;
   signal c1_x, c2_x                   : integer range 0 to 239 := 0;
   signal c1_y, c2_y                   : integer range 0 to 159 := 0;
   signal c1_we, c2_we                 : std_logic := '0';
   signal c1_jump, c2_jump             : std_logic := '0';
   signal c1_frames, c2_frames         : integer := 0;

   signal requestPause, allowUnpause   : std_logic;
   signal gbaon                        : std_logic := '0';
   signal vsync, vblank, hsync         : std_logic;

   signal vsync_count                  : integer := 0;

begin

   clk1x <= not clk1x after CLK1X_PERIOD / 2;
   clk3x <= not clk3x after CLK3X_PERIOD / 2;

   gbaon <= '1' after 1 us; -- ctrl_pause resets internal counters while low

   -- ==================================================================
   -- synthetic cores: GBA-ish raster, one pixel per 4 ce ticks over
   -- 240x160, then an idle gap that lands the frame near 59.7 Hz core
   -- side; cpu_jump pulses regularly so ctrl_pause can find a boundary
   -- ==================================================================
   fakecore1 : process (clk1x)
      variable phase : integer := 0;
      variable gap   : integer := 0;
   begin
      if rising_edge(clk1x) then
         c1_we   <= '0';
         c1_jump <= '0';
         if (c1_ce = '1') then
            phase := phase + 1;
            if (phase mod 5 = 0) then c1_jump <= '1'; end if;
            if (gap > 0) then
               gap := gap - 1;
            elsif (phase mod 4 = 0) then
               c1_we <= '1';
               if (c1_x = 239) then
                  c1_x <= 0;
                  if (c1_y = 159) then
                     c1_y      <= 0;
                     c1_frames <= c1_frames + 1;
                     gap       := 74240; -- 68 vblank lines x 1232 clk1x
                  else
                     c1_y <= c1_y + 1;
                  end if;
               else
                  c1_x <= c1_x + 1;
               end if;
            end if;
         end if;
      end if;
   end process;

   fakecore2 : process (clk1x)
      variable phase : integer := 0;
      variable gap   : integer := 12345; -- core 2 skewed vs core 1
   begin
      if rising_edge(clk1x) then
         c2_we   <= '0';
         c2_jump <= '0';
         if (c2_ce = '1') then
            phase := phase + 1;
            if (phase mod 5 = 0) then c2_jump <= '1'; end if;
            if (gap > 0) then
               gap := gap - 1;
            elsif (phase mod 4 = 0) then
               c2_we <= '1';
               if (c2_x = 239) then
                  c2_x <= 0;
                  if (c2_y = 159) then
                     c2_y      <= 0;
                     c2_frames <= c2_frames + 1;
                     gap       := 74240;
                  else
                     c2_y <= c2_y + 1;
                  end if;
               else
                  c2_x <= c2_x + 1;
               end if;
            end if;
         end if;
      end if;
   end process;

   -- ==================================================================
   -- the real pause controllers, hardware configuration
   -- ==================================================================
   ictrlpause1 : entity work.gba_ctrl_pause
   generic map ( is_simu => '0' )
   port map
   (
      clk1x               => clk1x,
      gbaon               => gbaon,
      savestate_loadstate => '0',
      pause               => requestPause,
      allowUnpause        => allowUnpause,
      sleep_savestate     => '0',
      sleep_rewind        => '0',
      dma_on_next         => '0',
      cpu_jump            => c1_jump,
      KeyPause            => '0',
      ce                  => c1_ce,
      pause_active        => c1_pause_active
   );

   ictrlpause2 : entity work.gba_ctrl_pause
   generic map ( is_simu => '0' )
   port map
   (
      clk1x               => clk1x,
      gbaon               => gbaon,
      savestate_loadstate => '0',
      pause               => requestPause,
      allowUnpause        => allowUnpause,
      sleep_savestate     => '0',
      sleep_rewind        => '0',
      dma_on_next         => '0',
      cpu_jump            => c2_jump,
      KeyPause            => '0',
      ce                  => c2_ce,
      pause_active        => c2_pause_active
   );

   -- ==================================================================
   -- the real scanout, dual mode, with a dummy DDR3 responder
   -- ==================================================================
   ddr3 : block
      signal req_r    : std_logic;
      signal burst    : integer := 0;
      signal ready    : std_logic := '0';
      signal done     : std_logic := '0';
      signal reqburst : unsigned(9 downto 0);
   begin
      process (clk1x)
      begin
         if rising_edge(clk1x) then
            ready <= '0';
            done  <= '0';
            if (req_r = '1' and burst = 0) then
               burst <= to_integer(reqburst);
            elsif (burst > 0) then
               ready <= '1';
               burst <= burst - 1;
               if (burst = 1) then
                  done <= '1';
               end if;
            end if;
         end if;
      end process;

      ivideoout160 : entity work.videoout160
      generic map
      (
         dual => dual
      )
      port map
      (
         clk1x                   => clk1x,
         clk3x                   => clk3x,

         blend                   => '0',
         borderOn                => '0',
         videoHshift             => (others => '0'),
         videoVshift             => (others => '0'),

         pixel_x                 => c1_x,
         pixel_y                 => c1_y,
         pixel_we                => c1_we,
         vblank_trigger          => '0',

         pixel2_x                => c2_x,
         pixel2_y                => c2_y,
         pixel2_we               => c2_we,

         nextFrame_out           => open,
         nextFrame2_out          => open,

         inPause                 => c1_pause_active,
         requestPause            => requestPause,
         allowUnpause            => allowUnpause,

         ddr3_request            => req_r,
         ddr3_address            => open,
         ddr3_burstcnt           => reqburst,
         ddr3_ready              => ready,
         ddr3_done               => done,
         ddr3_data               => (others => '0'),

         videoout_hsync          => hsync,
         videoout_vsync          => vsync,
         videoout_hblank         => open,
         videoout_vblank         => vblank,
         videoout_ce             => open,
         videoout_interlace      => open,
         videoout_r              => open,
         videoout_g              => open,
         videoout_b              => open
      );
   end block;

   -- ==================================================================
   -- checks
   -- ==================================================================

   -- vsync cadence: a rising edge every ~16.74ms, none may go missing
   vsync_watch : process
      variable t_last : time := 0 ns;
   begin
      loop
         wait until rising_edge(vsync) for 25 ms;
         if not vsync'event then
            report "SCANOUT DEAD: no vsync for 25ms (frames so far: " &
                   integer'image(vsync_count) & ", core1 frames " &
                   integer'image(c1_frames) & ", core2 frames " &
                   integer'image(c2_frames) & ")" severity failure;
         end if;
         vsync_count <= vsync_count + 1;
         if (t_last /= 0 ns) then
            report "vsync #" & integer'image(vsync_count + 1) &
                   " period " & time'image(now - t_last) &
                   "  core1_frames=" & integer'image(c1_frames) &
                   " core2_frames=" & integer'image(c2_frames) &
                   " reqPause=" & std_logic'image(requestPause) &
                   " allowUnpause=" & std_logic'image(allowUnpause);
         end if;
         t_last := now;
      end loop;
   end process;

   -- pause resolution: requestPause high for more than 2 output frames = wedge
   pause_watch : process (clk1x)
      variable cnt : integer := 0;
   begin
      if rising_edge(clk1x) then
         if (requestPause = '1') then
            cnt := cnt + 1;
            if (cnt = 600000) then -- ~36ms of clk1x
               report "PAUSE WEDGE: requestPause stuck for 2+ output frames" &
                      "  c1_pause_active=" & std_logic'image(c1_pause_active) &
                      "  allowUnpause=" & std_logic'image(allowUnpause)
                  severity failure;
            end if;
         else
            cnt := 0;
         end if;
      end if;
   end process;

   -- render-progress heartbeat
   hb : process
   begin
      loop
         wait for 5 ms;
         report "hb: c1=(" & integer'image(c1_x) & "," & integer'image(c1_y) &
                ") f" & integer'image(c1_frames) &
                "  c2=(" & integer'image(c2_x) & "," & integer'image(c2_y) &
                ") f" & integer'image(c2_frames) &
                "  reqP=" & std_logic'image(requestPause) &
                " allowU=" & std_logic'image(allowUnpause) &
                " c1_paused=" & std_logic'image(c1_pause_active) &
                " c2_paused=" & std_logic'image(c2_pause_active);
      end loop;
   end process;

   -- core starvation: core 1 must keep completing frames while scanout runs
   core_watch : process
      variable last_frames : integer := 0;
   begin
      wait for 40 ms; -- boot slack
      loop
         wait for 40 ms;
         if (c1_frames = last_frames) then
            report "CORE STARVED: core1 rendered no frame in 40ms" &
                   "  reqPause=" & std_logic'image(requestPause) &
                   "  allowUnpause=" & std_logic'image(allowUnpause) &
                   "  c1_pause_active=" & std_logic'image(c1_pause_active)
               severity failure;
         end if;
         last_frames := c1_frames;
      end loop;
   end process;

end architecture;
