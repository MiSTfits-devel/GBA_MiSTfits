-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- Ghost-hunt unit bench for the ch2 cancel/ghost protocol break (session 3
-- prime suspect, see sim/HANDOFF_2P_CRASH.md). Drives the REAL
-- memorymux_extern + REAL gba_mem_ewram_sdram through gba_wrap's verbatim
-- request mux into the behavioral sdram.sv ch2 model of tb_gba2p_sdram --
-- which faithfully reproduces the dangerous contract: sticky rq across
-- cancel, attributes sampled LIVE at grant, cancel killing only the read
-- pipeline, controller-internal 750-cycle refresh.
--
-- Traffic replaces the CPU cores: a branchy cart fetch stream (sequential
-- 16/32-bit reads with pseudo-random jumps -> cache_remove cancels) plus an
-- LFSR EWRAM read/write stream with byte-enable variety. Alignment between
-- jumps, EWRAM ops and refresh sweeps naturally (co-prime-ish periods).
--
-- Detectors, strongest first:
--   D1 EWRAM data integrity: every read checked against a byte-true mirror.
--   D2 cart data integrity: ROM content is f(index); every cart_done checked.
--   D3 hang watchdogs on both handshakes (the EW_WAIT-forever class).
--   D4 write into the ROM region / unmapped space (spurious-write class).
--   D5 model-side GHOST GRANT: a grant executing with no fresh ena after a
--      cancel, and GRANT DRIFT: granted attrs != attrs at the last ena pulse
--      (the live-sampling smoking gun).
--
-- run: sim/run_extern_ghost_tb.sh (STOP_TIME, ENABLE_CART/ENABLE_EWRAM knobs)

entity tb_extern_ghost is
   generic
   (
      ENABLE_CART  : std_logic := '1'; -- cart fetch stream on
      ENABLE_EWRAM : std_logic := '1'; -- EWRAM op stream on
      JUMP_PERIOD  : integer   := 7;   -- cart accesses between jumps
      LFSR_SEED    : integer   := 305419896; -- vary for different trajectories
      -- '1' = model the FIXED sdram.sv (8-cycle write slot); '0' = the
      -- original 6-cycle slot, D6 counts the resulting tRC/tDAL violations
      FIX_WRSLOT8  : std_logic := '1';
      SIM_TRACE    : std_logic := '0'  -- extern cache/SDRAM event trace
   );
end entity;

architecture sim of tb_extern_ghost is

   constant CLK6X_PERIOD : time := 10 ns;
   constant CLK1X_PERIOD : time := 60 ns;

   signal clk1x : std_logic := '0';
   signal clk6x : std_logic := '0';

   signal clk1xToggle     : std_logic := '0';
   signal clk1xToggle6x   : std_logic := '0';
   signal clk1xToggle6x_1 : std_logic := '0';
   signal clk6xIndex      : unsigned(2 downto 0) := (others => '0');

   -- SDRAM layout, byte addresses, matching GBA.sv's gba_wrap generics
   constant Softmap_GBA_Gamerom_ADDR : integer := 524288;
   constant Softmap_GBA_EWRAM_ADDR   : integer := 34078720;
   constant Softmap_GBA_EWRAM2_ADDR  : integer := 34340864;

   constant ROM_HWORDS : integer := 262144; -- 512KB of patterned ROM

   type t_hw_array is array (natural range <>) of std_logic_vector(15 downto 0);
   shared variable ew1_hw : t_hw_array(0 to 131071) := (others => (others => '0'));
   shared variable ew2_hw : t_hw_array(0 to 131071) := (others => (others => '0'));

   -- ROM content is pure function of the halfword index: no preload needed
   function romword(idx : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((idx * 37 + 11) mod 65536, 16));
   end function;

   signal reset : std_logic := '1';

   -- cart bus (bench drives the memorymux side of memorymux_extern)
   signal cart_ena       : std_logic := '0';
   signal cart_idle      : std_logic := '1';
   signal cart_32        : std_logic := '0';
   signal cart_rnw       : std_logic := '1';
   signal cart_addr      : std_logic_vector(27 downto 0) := (others => '0');
   signal cart_done      : std_logic;
   signal cart_readdata  : std_logic_vector(31 downto 0);

   -- EWRAM bus (bench drives the gba_memorymux side of the channel)
   signal ewram_ena, ewram_rnw, ewram_done : std_logic;
   signal ewram_addr      : std_logic_vector(15 downto 0);
   signal ewram_be        : std_logic_vector(3 downto 0);
   signal ewram_writedata : std_logic_vector(31 downto 0);
   signal ewram_readdata  : std_logic_vector(31 downto 0);

   -- core 2 EWRAM bus
   signal ew2_ena, ew2_rnw, ew2_done : std_logic;
   signal ew2_addr      : std_logic_vector(15 downto 0);
   signal ew2_be        : std_logic_vector(3 downto 0);
   signal ew2_writedata : std_logic_vector(31 downto 0);
   signal ew2_readdata  : std_logic_vector(31 downto 0);

   -- core 2 cart bus (served by gba_mem_cart2_sdram, no prefetch)
   signal c2_cart_ena, c2_cart_32, c2_cart_rnw, c2_cart_done : std_logic;
   signal c2_cart_addr     : std_logic_vector(27 downto 0) := (others => '0');
   signal c2_cart_readdata : std_logic_vector(31 downto 0);

   -- guest channel arbitration, verbatim signal set from gba_wrap (3 guests)
   signal guests_active, guests_busy, extern_allow : std_logic;
   signal ewram_active, ewram_busy, ew1_allow      : std_logic;
   signal ew2_active, ew2_busy, ew2_allow          : std_logic;
   signal cart2_active, cart2_busy, cart2_allow    : std_logic;

   signal mmx_sdram_Din : std_logic_vector(31 downto 0);
   signal mmx_sdram_Adr : std_logic_vector(26 downto 0);
   signal mmx_sdram_rnw : std_logic;
   signal mmx_sdram_ena : std_logic;

   signal ew_sdram_ena, ew_sdram_rnw : std_logic;
   signal ew_sdram_Adr : std_logic_vector(26 downto 0);
   signal ew_sdram_Din : std_logic_vector(31 downto 0);
   signal ew_sdram_be  : std_logic_vector(3 downto 0);

   signal ew2_sdram_ena, ew2_sdram_rnw : std_logic;
   signal ew2_sdram_Adr : std_logic_vector(26 downto 0);
   signal ew2_sdram_Din : std_logic_vector(31 downto 0);
   signal ew2_sdram_be  : std_logic_vector(3 downto 0);

   signal c2_sdram_ena  : std_logic;
   signal c2_sdram_Adr  : std_logic_vector(26 downto 0);

   signal sdram_ena, sdram_rnw : std_logic;
   signal sdram_Adr     : std_logic_vector(26 downto 0);
   signal sdram_Din     : std_logic_vector(31 downto 0);
   signal sdram_be      : std_logic_vector(3 downto 0);
   signal sdram_cancel  : std_logic;
   signal sdram_refresh : std_logic;
   signal sdram_Dout    : std_logic_vector(31 downto 0) := (others => '0');
   signal sdram_done16  : std_logic := '0';
   signal sdram_done32  : std_logic := '0';

   signal error_refresh : std_logic;
   signal flash_busy    : std_logic;

   constant SAVESTATE_BUS_ZERO : proc_bus_gb_type :=
      (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
       ena => '0', acc => "00", bEna => (others => '0'), rst => '0');

   -- event counters (heartbeat visibility)
   signal cnt_cart_ops   : integer := 0;
   signal cnt_ewram_ops  : integer := 0;
   signal cnt_cancels    : integer := 0;
   signal cnt_ghosts     : integer := 0;
   signal cnt_drifts     : integer := 0;
   signal cnt_cart_fails : integer := 0;
   signal cnt_ew_fails   : integer := 0;
   signal cnt_wr_act     : integer := 0; -- D6 same-bank ACT <= 6 cycles after write
   signal cnt_wr_rfsh    : integer := 0; -- D7 refresh <= 6 cycles after write
   signal cnt_ew2_ops    : integer := 0;
   signal cnt_c2_ops     : integer := 0;
   signal cnt_ew2_fails  : integer := 0;
   signal cnt_c2_fails   : integer := 0;
   -- worst-case request-to-done latency per client, clk1x cycles (starvation)
   signal lat_cart_max   : integer := 0;
   signal lat_ew1_max    : integer := 0;
   signal lat_ew2_max    : integer := 0;
   signal lat_c2_max     : integer := 0;

begin

   clk6x <= not clk6x after CLK6X_PERIOD / 2;
   clk1x <= not clk1x after CLK1X_PERIOD / 2;

   -- clk6xIndex sync, verbatim from gba_wrap
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;

   process (clk6x)
   begin
      if rising_edge(clk6x) then
         clk1xToggle6x   <= clk1xToggle;
         clk1xToggle6x_1 <= clk1xToggle6x;
         if (clk1xToggle6x = '1' and clk1xToggle6x_1 = '0') then
            clk6xIndex <= "010";
         elsif (clk6xIndex = 5) then
            clk6xIndex <= (others => '0');
         else
            clk6xIndex <= clk6xIndex + 1;
         end if;
      end if;
   end process;

   process
   begin
      wait for 1 us;
      wait until rising_edge(clk1x);
      reset <= '0';
      report "reset released";
      wait;
   end process;

   -- ==================================================================
   -- guest channel arbitration + request mux, verbatim from gba_wrap
   -- (full 2P profile: ew1 + ew2 + cart2 + extern)
   -- ==================================================================
   guests_active <= ewram_active or ew2_active or cart2_active;
   guests_busy   <= ewram_busy   or ew2_busy   or cart2_busy;

   ew1_allow     <= extern_allow and (not ew2_busy)     and (not cart2_busy);
   ew2_allow     <= extern_allow and (not ewram_active) and (not cart2_busy);
   cart2_allow   <= extern_allow and (not ewram_active) and (not ew2_active);

   sdram_ena <= mmx_sdram_ena or ew_sdram_ena or ew2_sdram_ena or c2_sdram_ena;
   sdram_rnw <= ew_sdram_rnw  when (ewram_busy = '1') else
                ew2_sdram_rnw when (ew2_busy   = '1') else
                '1'           when (cart2_busy = '1') else
                mmx_sdram_rnw;
   sdram_Adr <= ew_sdram_Adr  when (ewram_busy = '1') else
                ew2_sdram_Adr when (ew2_busy   = '1') else
                c2_sdram_Adr  when (cart2_busy = '1') else
                mmx_sdram_Adr;
   sdram_Din <= ew_sdram_Din  when (ewram_busy = '1') else
                ew2_sdram_Din when (ew2_busy   = '1') else
                mmx_sdram_Din;
   sdram_be  <= ew_sdram_be   when (ewram_busy = '1') else
                ew2_sdram_be  when (ew2_busy   = '1') else
                "1111";

   -- ==================================================================
   -- devices under test: the REAL extern + REAL EWRAM channel
   -- ==================================================================
   iextern : entity work.memorymux_extern
   generic map
   (
      is_simu                  => '1',
      sim_trace                => SIM_TRACE,
      Softmap_GBA_Gamerom_ADDR => Softmap_GBA_Gamerom_ADDR,
      Softmap_GBA_FLASH_ADDR   => 0,
      Softmap_GBA_EEPROM_ADDR  => 0
   )
   port map
   (
      clk1x                => clk1x,
      clk6x                => clk6x,
      clk6xIndex           => clk6xIndex,
      reset                => reset,

      SramFlashEnable      => '0',

      error_refresh        => error_refresh,
      flash_busy           => flash_busy,

      savestate_bus        => SAVESTATE_BUS_ZERO,
      ss_wired_out         => open,
      ss_wired_done        => open,

      cart_ena             => cart_ena,
      cart_idle            => cart_idle,
      cart_32              => cart_32,
      cart_rnw             => cart_rnw,
      cart_addr            => cart_addr,
      cart_writedata       => x"00",
      cart_done            => cart_done,
      cart_readdata        => cart_readdata,

      cart_waitcnt         => x"4317", -- typical game WAITCNT, prefetch ON

      ewram_active         => guests_active,
      ewram_allow          => extern_allow,
      hold_ena             => guests_busy,

      sdram_Din            => mmx_sdram_Din,
      sdram_Adr            => mmx_sdram_Adr,
      sdram_rnw            => mmx_sdram_rnw,
      sdram_ena            => mmx_sdram_ena,
      sdram_cancel         => sdram_cancel,
      sdram_refresh        => sdram_refresh,
      sdram_Dout           => sdram_Dout,
      sdram_done16         => sdram_done16,
      sdram_done32         => sdram_done32,

      specialmodule        => '0',
      GPIO_readEna         => open,
      GPIO_done            => '0',
      GPIO_Din             => "0000",
      GPIO_Dout            => open,
      GPIO_writeEna        => open,
      GPIO_addr            => open,

      dma_eepromcount      => (others => '0'),
      flash_1m             => '0',
      MaxPakAddr           => (others => '1'),
      memory_remap         => '0',

      save_eeprom          => open,
      save_sram            => open,
      save_flash           => open,

      tilt                 => '0',
      AnalogTiltX          => (others => '0'),
      AnalogTiltY          => (others => '0')
   );

   iewram_sdram : entity work.gba_mem_ewram_sdram
   generic map
   (
      Softmap_GBA_EWRAM_ADDR => Softmap_GBA_EWRAM_ADDR
   )
   port map
   (
      clk1x           => clk1x,
      clk6x           => clk6x,
      clk6xIndex      => clk6xIndex,
      reset           => reset,

      ewram_ena       => ewram_ena,
      ewram_rnw       => ewram_rnw,
      ewram_addr      => ewram_addr,
      ewram_be        => ewram_be,
      ewram_writedata => ewram_writedata,
      ewram_done      => ewram_done,
      ewram_readdata  => ewram_readdata,

      ewram_allow     => ew1_allow,
      ewram_active    => ewram_active,
      ewram_busy      => ewram_busy,

      ew_sdram_ena    => ew_sdram_ena,
      ew_sdram_rnw    => ew_sdram_rnw,
      ew_sdram_Adr    => ew_sdram_Adr,
      ew_sdram_Din    => ew_sdram_Din,
      ew_sdram_be     => ew_sdram_be,
      sdram_Dout      => sdram_Dout,
      sdram_done32    => sdram_done32
   );

   iewram2_sdram : entity work.gba_mem_ewram_sdram
   generic map
   (
      Softmap_GBA_EWRAM_ADDR => Softmap_GBA_EWRAM2_ADDR
   )
   port map
   (
      clk1x           => clk1x,
      clk6x           => clk6x,
      clk6xIndex      => clk6xIndex,
      reset           => reset,

      ewram_ena       => ew2_ena,
      ewram_rnw       => ew2_rnw,
      ewram_addr      => ew2_addr,
      ewram_be        => ew2_be,
      ewram_writedata => ew2_writedata,
      ewram_done      => ew2_done,
      ewram_readdata  => ew2_readdata,

      ewram_allow     => ew2_allow,
      ewram_active    => ew2_active,
      ewram_busy      => ew2_busy,

      ew_sdram_ena    => ew2_sdram_ena,
      ew_sdram_rnw    => ew2_sdram_rnw,
      ew_sdram_Adr    => ew2_sdram_Adr,
      ew_sdram_Din    => ew2_sdram_Din,
      ew_sdram_be     => ew2_sdram_be,
      sdram_Dout      => sdram_Dout,
      sdram_done32    => sdram_done32
   );

   icart2_sdram : entity work.gba_mem_cart2_sdram
   generic map
   (
      Softmap_GBA_Gamerom_ADDR => Softmap_GBA_Gamerom_ADDR
   )
   port map
   (
      clk1x           => clk1x,
      clk6x           => clk6x,
      clk6xIndex      => clk6xIndex,
      reset           => reset,

      memory_remap    => '0',
      MaxPakAddr      => (others => '1'),

      cart_ena        => c2_cart_ena,
      cart_32         => c2_cart_32,
      cart_rnw        => c2_cart_rnw,
      cart_addr       => c2_cart_addr,
      cart_done       => c2_cart_done,
      cart_readdata   => c2_cart_readdata,

      cart_allow      => cart2_allow,
      cart_active     => cart2_active,
      cart_busy       => cart2_busy,

      c2_sdram_ena    => c2_sdram_ena,
      c2_sdram_Adr    => c2_sdram_Adr,
      sdram_Dout      => sdram_Dout,
      sdram_done32    => sdram_done32
   );

   -- ==================================================================
   -- behavioral rtl/sdram.sv ch2 port (copied from tb_gba2p_sdram) with
   -- ghost instrumentation bolted on
   -- ==================================================================
   sdram_model : block
      type t_state is (S_IDLE, S_WAIT, S_RW1, S_RW2, S_IDLE5, S_IDLE4, S_IDLE3, S_IDLE2, S_IDLE1, S_RFSH5, S_RFSH4, S_RFSH3, S_RFSH2, S_RFSH1, S_RFSH0);
      signal state       : t_state := S_IDLE;
      signal rq          : std_logic := '0';
      signal saved_wr    : std_logic;
      signal saved_adr   : std_logic_vector(26 downto 0);
      signal saved_din   : std_logic_vector(31 downto 0);
      signal saved_be    : std_logic_vector(3 downto 0);
      signal delay       : std_logic_vector(6 downto 0) := (others => '0');
      signal pend_lo, pend_hi : std_logic_vector(15 downto 0);
      signal refresh_cnt : integer := 0;

      -- request attributes latched at the ena pulse: the FIXED sdram.sv
      -- contract (a request owns its attributes; live values only for a
      -- same-edge grant). Doubles as the ghost instrumentation.
      signal ena_adr     : std_logic_vector(26 downto 0);
      signal ena_rnw     : std_logic;
      signal ena_din     : std_logic_vector(31 downto 0);
      signal ena_be      : std_logic_vector(3 downto 0);
      signal kill        : std_logic := '0'; -- cancel since grant: fire no done
      signal cancel_seen : std_logic := '0'; -- a cancel hit the latched rq

      -- D6/D7 chip-timing instrumentation: sdram.sv's 6-cycle write slot puts
      -- the next grant's ACTIVATE (or an AUTO_REFRESH) 59.6ns after a write's
      -- ACTIVATE -- violating AS4C32M16SB-7 tRC (63ns) and cutting the
      -- tWR+tRP recovery of the auto-precharged write when the next op hits
      -- the same bank+chip. All of this core's traffic (ROM < 8MB and both
      -- EWRAM slots) lives in chip 0 / bank 00, so every back-to-back pair
      -- qualifies. The model has no analog physics; these monitors count how
      -- often real traffic would fire the hazard on silicon.
      signal grant_age    : integer := 1000; -- cycles since last grant
      signal last_was_wr  : std_logic := '0';
      signal last_gr_bank : std_logic_vector(1 downto 0) := "00";
      signal last_gr_chip : std_logic := '0';

      impure function read_hw(byteaddr : integer) return std_logic_vector is
      begin
         if (byteaddr >= Softmap_GBA_Gamerom_ADDR and byteaddr < Softmap_GBA_Gamerom_ADDR + 2*ROM_HWORDS) then
            return romword((byteaddr - Softmap_GBA_Gamerom_ADDR) / 2);
         elsif (byteaddr >= Softmap_GBA_EWRAM_ADDR and byteaddr < Softmap_GBA_EWRAM_ADDR + 262144) then
            return ew1_hw((byteaddr - Softmap_GBA_EWRAM_ADDR) / 2);
         elsif (byteaddr >= Softmap_GBA_EWRAM2_ADDR and byteaddr < Softmap_GBA_EWRAM2_ADDR + 262144) then
            return ew2_hw((byteaddr - Softmap_GBA_EWRAM2_ADDR) / 2);
         else
            return x"FFFF";
         end if;
      end function;

      procedure write_hw(byteaddr : integer; data : std_logic_vector(15 downto 0); benable : std_logic_vector(1 downto 0)) is
         variable cur : std_logic_vector(15 downto 0);
         variable idx : integer;
      begin
         if (benable = "00") then return; end if;
         if (byteaddr >= Softmap_GBA_EWRAM_ADDR and byteaddr < Softmap_GBA_EWRAM_ADDR + 262144) then
            idx := (byteaddr - Softmap_GBA_EWRAM_ADDR) / 2;
            cur := ew1_hw(idx);
            if (benable(0) = '1') then cur(7 downto 0)  := data(7 downto 0);  end if;
            if (benable(1) = '1') then cur(15 downto 8) := data(15 downto 8); end if;
            ew1_hw(idx) := cur;
         elsif (byteaddr >= Softmap_GBA_EWRAM2_ADDR and byteaddr < Softmap_GBA_EWRAM2_ADDR + 262144) then
            idx := (byteaddr - Softmap_GBA_EWRAM2_ADDR) / 2;
            cur := ew2_hw(idx);
            if (benable(0) = '1') then cur(7 downto 0)  := data(7 downto 0);  end if;
            if (benable(1) = '1') then cur(15 downto 8) := data(15 downto 8); end if;
            ew2_hw(idx) := cur;
         else
            -- D4: nothing in this bench legitimately writes outside the EWRAMs
            report "D4 SPURIOUS WRITE outside EWRAM: byteaddr 0x" &
                   to_hstring(to_unsigned(byteaddr, 28)) & " data " & to_hstring(data)
                   severity error;
         end if;
      end procedure;

   begin

      process (clk6x)
         variable a     : integer;
         variable g_adr : std_logic_vector(26 downto 0);
         variable g_rnw : std_logic;
         variable g_din : std_logic_vector(31 downto 0);
         variable g_be  : std_logic_vector(3 downto 0);
      begin
         if rising_edge(clk6x) then

            -- FIXED contract: cancel clears a pending rq (same-edge relaunch
            -- re-arms), attributes latch at the request pulse
            rq <= (rq and not sdram_cancel) or sdram_ena;
            sdram_done16 <= '0';
            sdram_done32 <= '0';

            if (sdram_ena = '1') then
               ena_adr     <= sdram_Adr;
               ena_rnw     <= sdram_rnw;
               ena_din     <= sdram_Din;
               ena_be      <= sdram_be;
               cancel_seen <= '0';
            elsif (sdram_cancel = '1' and rq = '1') then
               cancel_seen <= '1';
            end if;
            if (sdram_cancel = '1') then
               cnt_cancels <= cnt_cancels + 1;
            end if;

            delay <= '0' & delay(6 downto 1);
            if (delay(3) = '1') then
               sdram_Dout(15 downto 0) <= pend_lo;
               sdram_done16            <= '1';
               if (SIM_TRACE = '1') then
                  report "TRC-M done16 adr " & to_hstring(unsigned(saved_adr)) &
                         " data " & to_hstring(pend_lo);
               end if;
            end if;
            if (delay(2) = '1') then
               sdram_Dout(31 downto 16) <= pend_hi;
               sdram_done32             <= '1';
               if (SIM_TRACE = '1') then
                  report "TRC-M done32 adr " & to_hstring(unsigned(saved_adr)) &
                         " data " & to_hstring(pend_hi);
               end if;
            end if;

            refresh_cnt <= refresh_cnt + 1;

            if (grant_age < 1000) then
               grant_age <= grant_age + 1;
            end if;

            case (state) is

               when S_IDLE =>
                  if (sdram_refresh = '1' or refresh_cnt > 750) then
                     state       <= S_RFSH5;
                     refresh_cnt <= 0;
                     -- D7: AUTO_REFRESH needs every bank precharged; entered
                     -- 6 cycles after a write grant the written bank is still
                     -- inside its tWR+tRP recovery window
                     if (last_was_wr = '1' and grant_age <= 6) then
                        cnt_wr_rfsh <= cnt_wr_rfsh + 1;
                     end if;
                  elsif (rq = '1' or sdram_ena = '1') then
                     -- granted attributes: live for a same-edge request,
                     -- the request-pulse latch for a queued rq. Cancel is
                     -- NOT in this condition (timing: it would land in the
                     -- SDRAM_A cone); a stale grant at the cancel edge is
                     -- silenced by kill below, which is assigned last
                     if (sdram_ena = '1') then
                        g_adr := sdram_Adr; g_rnw := sdram_rnw;
                        g_din := sdram_Din; g_be := sdram_be;
                     else
                        g_adr := ena_adr; g_rnw := ena_rnw;
                        g_din := ena_din; g_be := ena_be;
                     end if;

                     -- D6: same-bank ACTIVATE-to-ACTIVATE below tRC after a
                     -- write (the 6-cycle write slot); reads leave 8 cycles
                     if (last_was_wr = '1' and grant_age <= 6 and
                         g_adr(24 downto 23) = last_gr_bank and
                         g_adr(26) = last_gr_chip) then
                        cnt_wr_act <= cnt_wr_act + 1;
                     end if;
                     grant_age    <= 1;
                     last_was_wr  <= not g_rnw;
                     last_gr_bank <= g_adr(24 downto 23);
                     last_gr_chip <= g_adr(26);
                     saved_adr <= g_adr;
                     saved_din <= g_din;
                     saved_be  <= g_be;
                     saved_wr  <= not g_rnw;
                     rq        <= '0';
                     kill      <= '0';
                     state     <= S_WAIT;

                     if (SIM_TRACE = '1') then
                        report "TRC-M grant adr " & to_hstring(unsigned(g_adr)) &
                               " rnw " & std_logic'image(g_rnw) &
                               " live " & std_logic'image(sdram_ena) &
                               " kill " & std_logic'image(kill) &
                               " cancel " & std_logic'image(sdram_cancel);
                     end if;

                     -- D5 regression tripwires: neither can fire under the
                     -- fixed contract. drifts counts how often the live
                     -- attrs had moved (i.e. how often the latch saved us).
                     if (sdram_ena = '0' and cancel_seen = '1') then
                        cnt_ghosts <= cnt_ghosts + 1;
                        report "D5 GHOST GRANT: cancelled rq granted, adr 0x" &
                               to_hstring(unsigned(g_adr)) & " rnw " & std_logic'image(g_rnw)
                               severity warning;
                     end if;
                     if (sdram_ena = '0' and (sdram_Adr /= ena_adr or sdram_rnw /= ena_rnw)) then
                        cnt_drifts <= cnt_drifts + 1;
                     end if;
                  end if;

               when S_WAIT => state <= S_RW1;

               when S_RW1 =>
                  a := to_integer(unsigned(saved_adr(26 downto 1) & '0'));
                  if (saved_wr = '1') then
                     write_hw(a, saved_din(15 downto 0), saved_be(1 downto 0));
                     state <= S_RW2;
                  else
                     pend_lo  <= read_hw(a);
                     pend_hi  <= read_hw(a + 2);
                     -- a cancel since grant means nobody wants this data
                     if (kill = '0') then
                        delay(6) <= '1';
                     end if;
                     state    <= S_IDLE5;
                  end if;

               when S_RW2 =>
                  a := to_integer(unsigned(saved_adr(26 downto 1) & '0'));
                  write_hw(a + 2, saved_din(31 downto 16), saved_be(3 downto 2));
                  sdram_done16 <= '1';
                  sdram_done32 <= '1';
                  if (FIX_WRSLOT8 = '1') then
                     state <= S_IDLE4;
                  else
                     state <= S_IDLE2;
                  end if;

               when S_IDLE5 => state <= S_IDLE4;
               when S_IDLE4 => state <= S_IDLE3;
               when S_IDLE3 => state <= S_IDLE2;
               when S_IDLE2 => state <= S_IDLE1;
               when S_IDLE1 => state <= S_IDLE;

               when S_RFSH5 => state <= S_RFSH4;
               when S_RFSH4 => state <= S_RFSH3;
               when S_RFSH3 => state <= S_RFSH2;
               when S_RFSH2 => state <= S_RFSH1;
               when S_RFSH1 => state <= S_RFSH0;
               when S_RFSH0 => state <= S_IDLE;

            end case;

            if (sdram_cancel = '1') then
               delay        <= (others => '0');
               sdram_done16 <= '0'; -- incl. a done registered this very edge
               sdram_done32 <= '0';
               if (sdram_ena = '0') then -- a same-edge relaunch keeps its op
                  kill <= '1';           -- last assignment: wins over grant
               end if;
            end if;

         end if;
      end process;

   end block;

   -- ==================================================================
   -- cart fetch stream: sequential 16/32-bit reads with jumps, like a CPU
   -- running branchy code from ROM (jumps -> cache_remove -> sdram_cancel)
   -- ==================================================================
   cart_driver : process
      variable lfsr    : unsigned(31 downto 0) := to_unsigned(LFSR_SEED, 32);
      variable fetch   : integer := 0; -- byte offset into ROM span
      variable sincejump : integer := 0;
      variable is32    : boolean;
      variable idx     : integer;
      variable guard   : integer;

      procedure lfsr_step is
      begin
         -- xorshift32
         lfsr := lfsr xor (lfsr sll 13);
         lfsr := lfsr xor (lfsr srl 17);
         lfsr := lfsr xor (lfsr sll 5);
      end procedure;
   begin
      if (ENABLE_CART = '0') then wait; end if;
      wait until reset = '0';
      wait until rising_edge(clk1x);

      loop
         lfsr_step;
         -- mix of 16/32-bit accesses; 32-bit only word-aligned, like the
         -- real memorymux (extern's cache indexing relies on it)
         is32 := (lfsr(9) = '1') and (fetch mod 4 = 0);

         cart_addr <= std_logic_vector(to_unsigned(16#8000000# + fetch, 28));
         cart_32   <= '1' when is32 else '0';
         cart_rnw  <= '1';
         cart_ena  <= '1';
         wait until rising_edge(clk1x);
         cart_ena  <= '0';

         guard := 0;
         while (cart_done /= '1') loop
            wait until rising_edge(clk1x);
            guard := guard + 1;
            assert guard < 2000
               report "D3 CART HANG at fetch 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28))
               severity failure;
         end loop;
         if (guard > lat_cart_max) then lat_cart_max <= guard; end if;

         -- D2: data integrity against the pure ROM pattern. Odd-halfword
         -- 16-bit reads come back in [31:16] (both the cache-hit path and
         -- WAIT_SDRAM swap them there for the downstream readrotate).
         idx := fetch / 2;
         if (is32) then
            if (cart_readdata /= romword(idx + 1) & romword(idx)) then
               cnt_cart_fails <= cnt_cart_fails + 1;
               report "D2 CART DATA CORRUPT (32b) at 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28)) &
                      " got " & to_hstring(cart_readdata) &
                      " want " & to_hstring(romword(idx + 1) & romword(idx))
                      severity error;
            end if;
         elsif (fetch mod 4 = 2) then
            if (cart_readdata(31 downto 16) /= romword(idx)) then
               cnt_cart_fails <= cnt_cart_fails + 1;
               report "D2 CART DATA CORRUPT (16b hi) at 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28)) &
                      " got " & to_hstring(cart_readdata(31 downto 16)) &
                      " want " & to_hstring(romword(idx))
                      severity error;
            end if;
         else
            if (cart_readdata(15 downto 0) /= romword(idx)) then
               cnt_cart_fails <= cnt_cart_fails + 1;
               report "D2 CART DATA CORRUPT (16b) at 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28)) &
                      " got " & to_hstring(cart_readdata(15 downto 0)) &
                      " want " & to_hstring(romword(idx))
                      severity error;
            end if;
         end if;
         cnt_cart_ops <= cnt_cart_ops + 1;

         -- advance: mostly sequential, jump every JUMP_PERIOD accesses
         sincejump := sincejump + 1;
         if (sincejump >= JUMP_PERIOD) then
            sincejump := 0;
            lfsr_step;
            fetch := 4 * (to_integer(lfsr(16 downto 2))); -- word-aligned jump target
            if (fetch >= 2*ROM_HWORDS - 8) then
               fetch := fetch mod (2*ROM_HWORDS - 8);
            end if;
         else
            if (is32) then
               fetch := fetch + 4;
            else
               fetch := fetch + 2;
            end if;
            if (fetch >= 2*ROM_HWORDS - 8) then fetch := 0; end if;
         end if;

         -- 1..4 idle cycles, sweeps alignment against EWRAM/refresh
         lfsr_step;
         for i in 0 to to_integer(lfsr(1 downto 0)) loop
            wait until rising_edge(clk1x);
         end loop;
      end loop;
   end process;

   -- ==================================================================
   -- EWRAM op stream: LFSR reads/writes with byte-enable variety, checked
   -- against a byte-true mirror
   -- ==================================================================
   ewram_driver : process
      variable lfsr   : unsigned(31 downto 0) := to_unsigned(LFSR_SEED, 32) xor x"5A5A5A5A";
      variable mirror : t_hw_array(0 to 131071) := (others => (others => '0'));
      variable dwaddr : integer;
      variable wdata  : std_logic_vector(31 downto 0);
      variable be     : std_logic_vector(3 downto 0);
      variable cur    : std_logic_vector(15 downto 0);
      variable expect : std_logic_vector(31 downto 0);
      variable guard  : integer;

      procedure lfsr_step is
      begin
         lfsr := lfsr xor (lfsr sll 13);
         lfsr := lfsr xor (lfsr srl 17);
         lfsr := lfsr xor (lfsr sll 5);
      end procedure;
   begin
      ewram_ena <= '0';
      if (ENABLE_EWRAM = '0') then wait; end if;
      wait until reset = '0';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);

      loop
         lfsr_step;
         -- keep the working set small-ish so read-after-write is frequent
         dwaddr := to_integer(lfsr(11 downto 0));
         lfsr_step;

         if (lfsr(31) = '1') then
            -- write with varied byte enables
            wdata := std_logic_vector(lfsr);
            case to_integer(lfsr(1 downto 0)) is
               when 0      => be := "1111";
               when 1      => be := "0011";
               when 2      => be := "1100";
               when others => be := "0001";
            end case;

            ewram_addr      <= std_logic_vector(to_unsigned(dwaddr, 16));
            ewram_rnw       <= '0';
            ewram_be        <= be;
            ewram_writedata <= wdata;
            ewram_ena       <= '1';
            wait until rising_edge(clk1x);
            ewram_ena       <= '0';

            guard := 0;
            while (ewram_done /= '1') loop
               wait until rising_edge(clk1x);
               guard := guard + 1;
               assert guard < 2000
                  report "D3 EWRAM HANG (write) at dword " & integer'image(dwaddr)
                  severity failure;
            end loop;
            if (guard > lat_ew1_max) then lat_ew1_max <= guard; end if;

            cur := mirror(2*dwaddr);
            if (be(0) = '1') then cur(7 downto 0)  := wdata(7 downto 0);  end if;
            if (be(1) = '1') then cur(15 downto 8) := wdata(15 downto 8); end if;
            mirror(2*dwaddr) := cur;
            cur := mirror(2*dwaddr + 1);
            if (be(2) = '1') then cur(7 downto 0)  := wdata(23 downto 16); end if;
            if (be(3) = '1') then cur(15 downto 8) := wdata(31 downto 24); end if;
            mirror(2*dwaddr + 1) := cur;
         else
            -- read + D1 integrity check
            ewram_addr <= std_logic_vector(to_unsigned(dwaddr, 16));
            ewram_rnw  <= '1';
            ewram_be   <= "1111";
            ewram_ena  <= '1';
            wait until rising_edge(clk1x);
            ewram_ena  <= '0';

            guard := 0;
            while (ewram_done /= '1') loop
               wait until rising_edge(clk1x);
               guard := guard + 1;
               assert guard < 2000
                  report "D3 EWRAM HANG (read) at dword " & integer'image(dwaddr)
                  severity failure;
            end loop;
            if (guard > lat_ew1_max) then lat_ew1_max <= guard; end if;

            expect := mirror(2*dwaddr + 1) & mirror(2*dwaddr);
            if (ewram_readdata /= expect) then
               cnt_ew_fails <= cnt_ew_fails + 1;
               report "D1 EWRAM DATA CORRUPT at dword " & integer'image(dwaddr) &
                      " got " & to_hstring(ewram_readdata) &
                      " want " & to_hstring(expect)
                      severity error;
            end if;
         end if;
         cnt_ewram_ops <= cnt_ewram_ops + 1;

         -- 0..7 idle cycles between ops
         lfsr_step;
         for i in 1 to to_integer(lfsr(2 downto 0)) loop
            wait until rising_edge(clk1x);
         end loop;
      end loop;
   end process;

   -- ==================================================================
   -- core 2 EWRAM op stream, same recipe as core 1's with its own mirror
   -- ==================================================================
   ew2_driver : process
      variable lfsr   : unsigned(31 downto 0) := to_unsigned(LFSR_SEED, 32) xor x"A5A5A5A5";
      variable mirror : t_hw_array(0 to 131071) := (others => (others => '0'));
      variable dwaddr : integer;
      variable wdata  : std_logic_vector(31 downto 0);
      variable be     : std_logic_vector(3 downto 0);
      variable cur    : std_logic_vector(15 downto 0);
      variable expect : std_logic_vector(31 downto 0);
      variable guard  : integer;

      procedure lfsr_step is
      begin
         lfsr := lfsr xor (lfsr sll 13);
         lfsr := lfsr xor (lfsr srl 17);
         lfsr := lfsr xor (lfsr sll 5);
      end procedure;
   begin
      ew2_ena <= '0';
      if (ENABLE_EWRAM = '0') then wait; end if;
      wait until reset = '0';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);

      loop
         lfsr_step;
         dwaddr := to_integer(lfsr(11 downto 0));
         lfsr_step;

         if (lfsr(31) = '1') then
            wdata := std_logic_vector(lfsr);
            case to_integer(lfsr(1 downto 0)) is
               when 0      => be := "1111";
               when 1      => be := "0011";
               when 2      => be := "1100";
               when others => be := "0100";
            end case;

            ew2_addr      <= std_logic_vector(to_unsigned(dwaddr, 16));
            ew2_rnw       <= '0';
            ew2_be        <= be;
            ew2_writedata <= wdata;
            ew2_ena       <= '1';
            wait until rising_edge(clk1x);
            ew2_ena       <= '0';

            guard := 0;
            while (ew2_done /= '1') loop
               wait until rising_edge(clk1x);
               guard := guard + 1;
               assert guard < 2000
                  report "D3 EW2 HANG (write) at dword " & integer'image(dwaddr)
                  severity failure;
            end loop;
            if (guard > lat_ew2_max) then lat_ew2_max <= guard; end if;

            cur := mirror(2*dwaddr);
            if (be(0) = '1') then cur(7 downto 0)  := wdata(7 downto 0);  end if;
            if (be(1) = '1') then cur(15 downto 8) := wdata(15 downto 8); end if;
            mirror(2*dwaddr) := cur;
            cur := mirror(2*dwaddr + 1);
            if (be(2) = '1') then cur(7 downto 0)  := wdata(23 downto 16); end if;
            if (be(3) = '1') then cur(15 downto 8) := wdata(31 downto 24); end if;
            mirror(2*dwaddr + 1) := cur;
         else
            ew2_addr <= std_logic_vector(to_unsigned(dwaddr, 16));
            ew2_rnw  <= '1';
            ew2_be   <= "1111";
            ew2_ena  <= '1';
            wait until rising_edge(clk1x);
            ew2_ena  <= '0';

            guard := 0;
            while (ew2_done /= '1') loop
               wait until rising_edge(clk1x);
               guard := guard + 1;
               assert guard < 2000
                  report "D3 EW2 HANG (read) at dword " & integer'image(dwaddr)
                  severity failure;
            end loop;
            if (guard > lat_ew2_max) then lat_ew2_max <= guard; end if;

            expect := mirror(2*dwaddr + 1) & mirror(2*dwaddr);
            if (ew2_readdata /= expect) then
               cnt_ew2_fails <= cnt_ew2_fails + 1;
               report "D1b EW2 DATA CORRUPT at dword " & integer'image(dwaddr) &
                      " got " & to_hstring(ew2_readdata) &
                      " want " & to_hstring(expect)
                      severity error;
            end if;
         end if;
         cnt_ew2_ops <= cnt_ew2_ops + 1;

         lfsr_step;
         for i in 1 to to_integer(lfsr(2 downto 0)) loop
            wait until rising_edge(clk1x);
         end loop;
      end loop;
   end process;

   -- ==================================================================
   -- core 2 cart fetch stream: NO prefetch cache, every fetch is its own
   -- SDRAM roundtrip through gba_mem_cart2_sdram -- the highest-duty
   -- client in the full 2P profile
   -- ==================================================================
   c2_driver : process
      variable lfsr    : unsigned(31 downto 0) := to_unsigned(LFSR_SEED, 32) xor x"C2C2C2C2";
      variable fetch   : integer := 65536;
      variable sincejump : integer := 0;
      variable is32    : boolean;
      variable idx     : integer;
      variable guard   : integer;

      procedure lfsr_step is
      begin
         lfsr := lfsr xor (lfsr sll 13);
         lfsr := lfsr xor (lfsr srl 17);
         lfsr := lfsr xor (lfsr sll 5);
      end procedure;
   begin
      c2_cart_ena <= '0';
      c2_cart_rnw <= '1';
      c2_cart_32  <= '0';
      if (ENABLE_CART = '0') then wait; end if;
      wait until reset = '0';
      wait until rising_edge(clk1x);
      wait until rising_edge(clk1x);

      loop
         lfsr_step;
         is32 := (lfsr(9) = '1') and (fetch mod 4 = 0);

         c2_cart_addr <= std_logic_vector(to_unsigned(16#8000000# + fetch, 28));
         c2_cart_32   <= '1' when is32 else '0';
         c2_cart_rnw  <= '1';
         c2_cart_ena  <= '1';
         wait until rising_edge(clk1x);
         c2_cart_ena  <= '0';

         guard := 0;
         while (c2_cart_done /= '1') loop
            wait until rising_edge(clk1x);
            guard := guard + 1;
            assert guard < 2000
               report "D3 C2 HANG at fetch 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28))
               severity failure;
         end loop;
         if (guard > lat_c2_max) then lat_c2_max <= guard; end if;

         -- D2b: same rotation contract as extern (odd halfword -> [31:16])
         idx := fetch / 2;
         if (is32) then
            if (c2_cart_readdata /= romword(idx + 1) & romword(idx)) then
               cnt_c2_fails <= cnt_c2_fails + 1;
               report "D2b C2 DATA CORRUPT (32b) at 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28)) &
                      " got " & to_hstring(c2_cart_readdata) &
                      " want " & to_hstring(romword(idx + 1) & romword(idx))
                      severity error;
            end if;
         elsif (fetch mod 4 = 2) then
            if (c2_cart_readdata(31 downto 16) /= romword(idx)) then
               cnt_c2_fails <= cnt_c2_fails + 1;
               report "D2b C2 DATA CORRUPT (16b hi) at 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28)) &
                      " got " & to_hstring(c2_cart_readdata(31 downto 16)) &
                      " want " & to_hstring(romword(idx))
                      severity error;
            end if;
         else
            if (c2_cart_readdata(15 downto 0) /= romword(idx)) then
               cnt_c2_fails <= cnt_c2_fails + 1;
               report "D2b C2 DATA CORRUPT (16b) at 0x" & to_hstring(to_unsigned(16#8000000# + fetch, 28)) &
                      " got " & to_hstring(c2_cart_readdata(15 downto 0)) &
                      " want " & to_hstring(romword(idx))
                      severity error;
            end if;
         end if;
         cnt_c2_ops <= cnt_c2_ops + 1;

         sincejump := sincejump + 1;
         if (sincejump >= JUMP_PERIOD + 2) then
            sincejump := 0;
            lfsr_step;
            fetch := 4 * (to_integer(lfsr(16 downto 2)));
            if (fetch >= 2*ROM_HWORDS - 8) then
               fetch := fetch mod (2*ROM_HWORDS - 8);
            end if;
         else
            if (is32) then
               fetch := fetch + 4;
            else
               fetch := fetch + 2;
            end if;
            if (fetch >= 2*ROM_HWORDS - 8) then fetch := 0; end if;
         end if;

         -- core 2 fetches nearly back to back: 0..1 idle cycles
         lfsr_step;
         if (lfsr(0) = '1') then
            wait until rising_edge(clk1x);
         end if;
      end loop;
   end process;

   -- ==================================================================
   -- heartbeat
   -- ==================================================================
   heartbeat : process
   begin
      wait for 1 ms;
      report "heartbeat: cart " & integer'image(cnt_cart_ops) &
             " ew1 " & integer'image(cnt_ewram_ops) &
             " ew2 " & integer'image(cnt_ew2_ops) &
             " c2 " & integer'image(cnt_c2_ops) &
             " cancels " & integer'image(cnt_cancels) &
             " ghosts " & integer'image(cnt_ghosts) &
             " drifts " & integer'image(cnt_drifts) &
             " fails " & integer'image(cnt_cart_fails) & "/" & integer'image(cnt_ew_fails) &
             "/" & integer'image(cnt_ew2_fails) & "/" & integer'image(cnt_c2_fails) &
             " D6 " & integer'image(cnt_wr_act) &
             " D7 " & integer'image(cnt_wr_rfsh) &
             " maxlat " & integer'image(lat_cart_max) & "/" & integer'image(lat_ew1_max) &
             "/" & integer'image(lat_ew2_max) & "/" & integer'image(lat_c2_max);
   end process;

end architecture;
