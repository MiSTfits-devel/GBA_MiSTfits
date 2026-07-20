-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use STD.env.all;
use IEEE.std_logic_textio.all;

use work.pProc_bus_gba.all;

entity tb_bustiming is
end entity;

architecture sim of tb_bustiming is

   constant CLK_PERIOD : time := 10 ns;

   signal clk  : std_logic := '0';
   signal done : boolean   := false;

   constant BIOS_WORDS : integer := 4096;
   constant ROM_WORDS  : integer := 65536;

   type t_word_array is array (natural range <>) of std_logic_vector(31 downto 0);

   impure function load_hexfile(path : string; max_words : integer) return t_word_array is
      file     f       : text;
      variable ln      : line;
      variable words   : t_word_array(0 to max_words - 1) := (others => (others => '0'));
      variable i       : integer := 0;
      variable hexword : std_logic_vector(31 downto 0);
      variable ok      : boolean;
   begin
      file_open(f, path, read_mode);
      while not endfile(f) and i < max_words loop
         readline(f, ln);
         hread(ln, hexword, ok);
         assert ok report "hread failed on " & path severity failure;
         words(i) := hexword;
         i := i + 1;
      end loop;
      file_close(f);
      report path & ": loaded " & integer'image(i) & " words";
      return words;
   end function;

   shared variable rom_image  : t_word_array(0 to ROM_WORDS - 1);
   shared variable bios_image : t_word_array(0 to BIOS_WORDS - 1);

   signal cart_ena       : std_logic;
   signal cart_rnw       : std_logic;
   signal cart_addr      : std_logic_vector(27 downto 0);
   signal cart_writedata : std_logic_vector(7 downto 0);
   signal cart_done      : std_logic := '0';
   signal cart_readdata  : std_logic_vector(31 downto 0) := (others => '0');

   signal bios_wraddr : std_logic_vector(11 downto 0) := (others => '0');
   signal bios_wrdata : std_logic_vector(31 downto 0) := (others => '0');
   signal bios_wr     : std_logic := '0';

   signal GBA_on : std_logic := '0';

   constant ZERO28 : std_logic_vector(27 downto 0) := (others => '0');
   constant ZERO32 : std_logic_vector(31 downto 0) := (others => '0');
   constant ZERO64 : std_logic_vector(63 downto 0) := (others => '0');

   constant NRESULT : integer := 15;
   type t_res is array (0 to NRESULT-1) of integer;
   signal results   : t_res := (others => -1);
   signal nresults  : integer := 0;
   signal done_seen : std_logic := '0';

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   preload : process
   begin
      rom_image  := load_hexfile("sim/tests/probe_words.hex", ROM_WORDS);
      bios_image := load_hexfile("sim/tests/bios_words.hex", BIOS_WORDS);
      wait;
   end process;

   biosload : process
   begin
      wait for 100 ns;
      wait until rising_edge(clk);
      for i in 0 to BIOS_WORDS - 1 loop
         bios_wraddr <= std_logic_vector(to_unsigned(i, 12));
         bios_wrdata <= bios_image(i);
         bios_wr     <= '1';
         wait until rising_edge(clk);
      end loop;
      bios_wr <= '0';
      report "BIOS loaded";
      wait for 100 ns;
      GBA_on <= '1';
      wait;
   end process;

   cart : process (clk)
      variable idx : integer;
   begin
      if rising_edge(clk) then
         cart_done <= '0';
         if (cart_ena = '1') then
            idx := to_integer(unsigned(cart_addr(23 downto 2)));
            if (idx < ROM_WORDS) then
               cart_readdata <= rom_image(idx);
            else
               cart_readdata <= x"FFFFFFFF";
            end if;
            cart_done <= '1';
         end if;
      end if;
   end process;

   icore1 : entity work.gba_top
   generic map
   (
      Softmap_GBA_Gamerom_ADDR => 0,
      Softmap_GBA_FLASH_ADDR   => 0,
      Softmap_GBA_EEPROM_ADDR  => 0,
      Softmap_SaveState_ADDR   => 0,
      Softmap_Rewind_ADDR      => 0,
      is_simu                  => '1',
      simu_export_trace        => '0',
      strip_savestates         => '1',
      strip_cheats             => '1',
      ewram_in_sdram           => '0',
      turbosound               => '0'
   )
   port map
   (
      clk1x                 => clk,
      GBA_on                => GBA_on,
      pause                 => '0',
      allowUnpause          => '1',
      inPause               => open,
      GBA_lockspeed         => '1',
      GBA_cputurbo          => '0',
      GBA_flash_1m          => '0',
      Underclock            => "00",
      CyclesMissing         => open,
      CyclesVsyncSpeed      => open,
      increaseSSHeaderCount => '0',
      save_state            => '0',
      load_state            => '0',
      interframe_blend      => "00",
      shade_mode            => "000",
      rewind_on             => '0',
      rewind_active         => '0',
      savestate_number      => 0,

      error_cpu             => open,
      error_memRequ_timeout => open,
      error_memResp_timeout => open,
      flash_busy            => '0',

      cheat_clear           => '0',
      cheats_enabled        => '0',
      cheat_on              => '0',
      cheat_in              => (others => '0'),
      cheats_active         => open,

      cart_ena              => cart_ena,
      cart_idle             => open,
      cart_32               => open,
      cart_rnw              => cart_rnw,
      cart_addr             => cart_addr,
      cart_writedata        => cart_writedata,
      cart_done             => cart_done,
      cart_readdata         => cart_readdata,
      cart_waitcnt          => open,
      dma_eepromcount       => open,
      cart_reset            => open,

      ewram_ena             => open,
      ewram_rnw             => open,
      ewram_addr            => open,
      ewram_be              => open,
      ewram_writedata       => open,
      ewram_done            => '0',
      ewram_readdata        => (others => '0'),

      SAVE_out_Din          => open,
      SAVE_out_Dout         => ZERO64,
      SAVE_out_Adr          => open,
      SAVE_out_rnw          => open,
      SAVE_out_ena          => open,
      SAVE_out_active       => open,
      SAVE_out_be           => open,
      SAVE_out_done         => '0',
      savestate_bus_ext     => open,
      ss_wired_out_ext      => ZERO32,
      ss_wired_done_ext     => '0',

      bios_wraddr           => bios_wraddr,
      bios_wrdata           => bios_wrdata,
      bios_wr               => bios_wr,

      load_done             => open,

      KeyA                  => '0',
      KeyB                  => '0',
      KeySelect             => '0',
      KeyStart              => '0',
      KeyRight              => '0',
      KeyLeft               => '0',
      KeyUp                 => '0',
      KeyDown               => '0',
      KeyR                  => '0',
      KeyL                  => '0',
      KeyPause              => '0',

      link_enable           => '0',
      link_clk_out          => open,
      link_clk_oe           => open,
      link_clk_in           => '1',
      link_so_out           => open,
      link_so_oe            => open,
      link_si_in            => '1',
      link_sd_out           => open,
      link_sd_oe            => open,
      link_sd_in            => '1',

      GBA_BusAddr           => ZERO28,
      GBA_BusRnW            => '1',
      GBA_BusACC            => "01",
      GBA_BusWriteData      => ZERO32,
      GBA_BusReadData       => open,
      GBA_Bus_written       => '0',

      pixel_out_x           => open,
      pixel_out_y           => open,
      pixel_out_addr        => open,
      pixel_out_data        => open,
      pixel_out_we          => open,
      vblank_trigger        => open,

      sound_out_left        => open,
      sound_out_right       => open,

      debug_cpu_pc          => open,
      debug_cpu_mixed       => open,
      debug_irq             => open,
      debug_dma             => open,
      debug_mem             => open
   );

   monitor : block
      signal m_adr : std_logic_vector(31 downto 0);
      signal m_ena : std_logic;
      signal m_rnw : std_logic;
      signal m_dout : std_logic_vector(31 downto 0);
      signal c1_export : work.pexport.cpu_export_type;
   begin
      m_adr <= << signal .tb_bustiming.icore1.mem_bus_Adr  : std_logic_vector(31 downto 0) >>;
      m_ena <= << signal .tb_bustiming.icore1.mem_bus_ena  : std_logic >>;
      m_rnw <= << signal .tb_bustiming.icore1.mem_bus_rnw  : std_logic >>;
      m_dout <= << signal .tb_bustiming.icore1.mem_bus_dout : std_logic_vector(31 downto 0) >>;
      c1_export <= << signal .tb_bustiming.icore1.cpu_export : work.pexport.cpu_export_type >>;

      sampler : process (clk)
         variable idx : integer;
      begin
         if rising_edge(clk) then
            if (m_ena = '1' and m_rnw = '0' and
                unsigned(m_adr) >= x"03007800" and unsigned(m_adr) < x"0300783C") then
               idx := to_integer(unsigned(m_adr(5 downto 2)));
               if (idx < NRESULT and nresults = idx) then
                  results(idx) <= to_integer(unsigned(m_dout));
                  nresults     <= nresults + 1;
                  report "result[" & integer'image(idx) & "] = " &
                         integer'image(to_integer(unsigned(m_dout))) & " at " & time'image(now);
               end if;
            end if;
            if (done_seen = '0' and nresults = NRESULT) then
               done_seen <= '1';
            end if;
         end if;
      end process;

      progress : process
      begin
         for i in 1 to 60 loop
            wait for 2 ms;
            exit when done_seen = '1';
            report "progress: pc=0x" & to_hstring(c1_export.pc) &
                   " nresults=" & integer'image(nresults);
         end loop;
         wait;
      end process;
   end block;

   check : process
      type t_check is record
         id   : integer;
         name : string(1 to 14);
         exp  : integer;
         tol  : integer;
      end record;
      type t_checks is array (natural range <>) of t_check;
      constant checks : t_checks := (
         (1,  "IWRAM_NOP256  ",  256,  32),
         (2,  "ROM_NOP_OFF42 ",  768,  64),
         (3,  "ROM_NOP_ON42  ",  768,  64),
         (4,  "ROM_MUL_ON31  ",  384,  56),
         (5,  "ROM_MUL_OFF31 ",  512,  56),
         (12, "EWRAM_LDR128  ", 1024,  96),
         (13, "DMA_ROM64     ",  456,  72),
         (14, "DMA_IWRAM64   ",  134,  40));
      variable adj   : t_res;
      variable gaps  : integer := 0;
      variable d     : integer;
   begin
      wait until done_seen = '1' for 79 ms;
      if (done_seen = '0') then
         report "BUSTIME TIMEOUT: nresults=" & integer'image(nresults) severity failure;
      end if;
      wait for 100 ns;

      report "raw overhead O = " & integer'image(results(0));
      for i in 0 to NRESULT-1 loop
         adj(i) := results(i) - results(0);
         report "raw[" & integer'image(i) & "] = " & integer'image(results(i));
      end loop;

      for c in checks'range loop
         d := adj(checks(c).id);
         if (abs(d - checks(c).exp) <= checks(c).tol) then
            report "BUSTIME " & checks(c).name & " measured " & integer'image(d) &
                   "  expected " & integer'image(checks(c).exp) & "  OK";
         else
            report "BUSTIME " & checks(c).name & " measured " & integer'image(d) &
                   "  expected " & integer'image(checks(c).exp) & "  GAP" severity warning;
            gaps := gaps + 1;
         end if;
      end loop;

      if (adj(3) < 600) then
         report "BUSTIME PREFETCH_RATE  sustained ROM fetch " & integer'image(adj(3)) &
                " for 256 THUMB ops (< 600): prefetch serves faster than the bus can fill = core too fast" severity warning;
         gaps := gaps + 1;
      end if;

      d := results(7) - results(6);
      if (d >= 2) then
         report "BUSTIME PAGE_CROSS     delta " & integer'image(d) & "  (>=2 expected)  OK";
      else
         report "BUSTIME PAGE_CROSS     delta " & integer'image(d) &
                "  expected >=2: no 0x20000-boundary prefetch stop modeled" severity warning;
         gaps := gaps + 1;
      end if;

      d := results(8) - results(9);
      if (d >= 16) then
         report "BUSTIME VRAM_CONTEND   delta " & integer'image(d) & "  (draw vs vblank)  OK";
      else
         report "BUSTIME VRAM_CONTEND   delta " & integer'image(d) &
                "  expected >=16: CPU does not stall against PPU VRAM access" severity warning;
         gaps := gaps + 1;
      end if;

      d := results(10) - results(11);
      if (d >= 16) then
         report "BUSTIME OAM_CONTEND    delta " & integer'image(d) & "  (draw vs vblank)  OK";
      else
         report "BUSTIME OAM_CONTEND    delta " & integer'image(d) &
                "  expected >=16: CPU does not stall against PPU OAM access" severity warning;
         gaps := gaps + 1;
      end if;

      if (gaps = 0) then
         report "BUSTIME: all checks match hardware expectations" severity note;
      else
         report "BUSTIME: " & integer'image(gaps) & " deviations from hardware timing" severity warning;
      end if;

      done <= true;
      stop;
   end process;

end architecture;
