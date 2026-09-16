-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use STD.env.all;
use IEEE.std_logic_textio.all;

use work.pProc_bus_gba.all;

entity tb_cart_eeprom is
end entity;

architecture sim of tb_cart_eeprom is

   constant CLK_PERIOD : time := 10 ns;

   signal clk   : std_logic := '1';
   signal clk6x : std_logic := '1';
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

   signal done_seen : std_logic := '0';

   signal cart_32           : std_logic;
   signal cart_writedata32  : std_logic_vector(31 downto 0);
   signal cart_be32         : std_logic_vector(3 downto 0);
   signal cart_waitcnt      : std_logic_vector(15 downto 0);
   signal dma_eepromcount   : unsigned(16 downto 0);

   -- physical cartridge pins
   signal pin_ad_out   : std_logic_vector(15 downto 0);
   signal pin_ad_in    : std_logic_vector(15 downto 0) := (others => '1');
   signal pin_ad_drive : std_logic;
   signal pin_a_out    : std_logic_vector(7 downto 0);
   signal pin_a_in     : std_logic_vector(7 downto 0) := (others => '1');
   signal pin_a_drive  : std_logic;
   signal pin_cs_n     : std_logic;
   signal pin_cs2_n    : std_logic;
   signal pin_rd_n     : std_logic;
   signal pin_wr_n     : std_logic;
   signal pin_phi      : std_logic;

   -- cartridge model: ROM plus a 64 Kbit EEPROM on A23
   signal latched     : unsigned(15 downto 0) := (others => '0');
   signal cs_fall_cnt : integer := 0;
   signal wr_pulses   : integer := 0;
   signal rd_pulses   : integer := 0;

   constant EE_ABITS : integer := 14;
   type t_eestate is (EE_IDLE, EE_CMD, EE_ARMED, EE_READOUT);
   signal ee_state  : t_eestate := EE_IDLE;
   signal ee_bits   : integer range 0 to 127 := 0;
   signal ee_cmd_rd : std_logic := '0';
   signal ee_addr   : unsigned(13 downto 0) := (others => '0');
   signal ee_wdata  : std_logic_vector(63 downto 0) := (others => '0');
   signal ee_rdaddr : integer range 0 to 1023 := 0;
   signal ee_rdcnt  : integer range 0 to 127 := 0;
   type t_eemem is array (0 to 1023) of std_logic_vector(63 downto 0);
   signal ee_mem    : t_eemem := (others => (others => '0'));
   signal ee_bitout : std_logic;
   signal ee_aborts : integer := 0;
   signal ee_writes : integer := 0;
   -- how many /CS assertions the command stream was chopped into
   signal ee_cs_in_cmd : integer := 0;

begin

   clk   <= not clk   after CLK_PERIOD / 2  when not done else '0';
   -- exactly 6x and phase locked, the way the PLL drives the real core
   clk6x <= not clk6x after CLK_PERIOD / 12 when not done else '0';

   preload : process
   begin
      rom_image  := load_hexfile("sim/tests/eeprom_words.hex", ROM_WORDS);
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

   -- the real physical-cartridge bus master, driven by the real core
   iphys : entity work.gba_cart_phys
   port map (
      clk1x => clk, clk6x => clk6x, reset => '0',
      enable => '1', timing_sel => "00",
      cart_ena => cart_ena, cart_32 => cart_32, cart_rnw => cart_rnw,
      cart_addr => cart_addr, cart_writedata => cart_writedata,
      cart_writedata32 => cart_writedata32, cart_be32 => cart_be32,
      cart_done => cart_done, cart_readdata => cart_readdata,
      cart_waitcnt => cart_waitcnt,
      pin_ad_out => pin_ad_out, pin_ad_in => pin_ad_in, pin_ad_drive => pin_ad_drive,
      pin_a_out => pin_a_out, pin_a_in => pin_a_in, pin_a_drive => pin_a_drive,
      pin_cs_n => pin_cs_n, pin_cs2_n => pin_cs2_n,
      pin_rd_n => pin_rd_n, pin_wr_n => pin_wr_n, pin_phi => pin_phi
   );

   ee_bitout <= '0' when (ee_rdcnt < 4 or ee_rdcnt >= 68) else
                ee_mem(ee_rdaddr)(63 - (ee_rdcnt - 4));

   -- ROM on /CS with A23 low, EEPROM on /CS with A23 high
   cartread : process (pin_cs_n, pin_rd_n, pin_cs2_n, pin_a_out, latched,
                       ee_state, ee_bitout)
      variable ha  : unsigned(23 downto 0);
      variable wrd : std_logic_vector(31 downto 0);
   begin
      pin_ad_in <= (others => '1');
      if (pin_cs_n = '0' and pin_rd_n = '0' and pin_cs2_n = '1') then
         ha := unsigned(pin_a_out) & latched;
         if (ha(23) = '1') then
            pin_ad_in <= x"000" & "000" & ee_bitout;
         elsif (ha < 16#20000#) then
            wrd := rom_image(to_integer(ha(16 downto 1)));
            if (ha(0) = '1') then
               pin_ad_in <= wrd(31 downto 16);
            else
               pin_ad_in <= wrd(15 downto 0);
            end if;
         end if;
      end if;
   end process;

   -- address latch and the cartridge's own counter
   cartlatch : process
      variable cs_p, rd_p, wr_p : std_logic := '1';
   begin
      wait on pin_cs_n, pin_rd_n, pin_wr_n;
      if (pin_cs_n = '0' and cs_p = '1') then
         latched     <= unsigned(pin_ad_out);
         cs_fall_cnt <= cs_fall_cnt + 1;
         if (ee_state = EE_CMD) then
            ee_cs_in_cmd <= ee_cs_in_cmd + 1;
         end if;
      elsif (pin_cs_n = '0' and pin_rd_n = '1' and rd_p = '0') then
         latched   <= latched + 1;
         rd_pulses <= rd_pulses + 1;
      elsif (pin_cs_n = '0' and pin_wr_n = '1' and wr_p = '0') then
         latched   <= latched + 1;
         wr_pulses <= wr_pulses + 1;
      end if;
      cs_p := pin_cs_n; rd_p := pin_rd_n; wr_p := pin_wr_n;
   end process;

   -- the EEPROM itself, which aborts on a mid-command /CS like the real chip
   eeprom : process
      variable cs_p, wr_p, rd_p : std_logic := '1';
   begin
      wait on pin_cs_n, pin_wr_n, pin_rd_n;

      if (pin_cs_n = '0' and cs_p = '1' and pin_a_out(7) = '1') then
         if (ee_state = EE_ARMED) then
            ee_state <= EE_READOUT;
            ee_rdcnt <= 0;
         else
            ee_state <= EE_CMD;
            ee_bits  <= 0;
            ee_addr  <= (others => '0');
         end if;

      elsif (pin_cs_n = '1' and cs_p = '0') then
         if (ee_state = EE_CMD and ee_bits > 0) then
            ee_aborts <= ee_aborts + 1;
         end if;
         if (ee_state /= EE_ARMED) then
            ee_state <= EE_IDLE;
         end if;

      elsif (pin_cs_n = '0' and pin_wr_n = '1' and wr_p = '0' and ee_state = EE_CMD) then
         if (ee_bits = 0) then
            ee_bits <= 1;
         elsif (ee_bits = 1) then
            ee_cmd_rd <= pin_ad_out(0);
            ee_bits   <= 2;
         elsif (ee_bits < 2 + EE_ABITS) then
            ee_addr <= ee_addr(12 downto 0) & pin_ad_out(0);
            ee_bits <= ee_bits + 1;
         elsif (ee_cmd_rd = '1') then
            ee_rdaddr <= to_integer(ee_addr(9 downto 0));
            ee_state  <= EE_ARMED;
         elsif (ee_bits < 2 + EE_ABITS + 64) then
            ee_wdata <= ee_wdata(62 downto 0) & pin_ad_out(0);
            ee_bits  <= ee_bits + 1;
         else
            ee_mem(to_integer(ee_addr(9 downto 0))) <= ee_wdata;
            ee_writes <= ee_writes + 1;
            ee_state  <= EE_IDLE;
         end if;

      elsif (pin_cs_n = '0' and pin_rd_n = '1' and rd_p = '0' and ee_state = EE_READOUT) then
         ee_rdcnt <= ee_rdcnt + 1;
      end if;

      cs_p := pin_cs_n; wr_p := pin_wr_n; rd_p := pin_rd_n;
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
      cart_32               => cart_32,
      cart_rnw              => cart_rnw,
      cart_addr             => cart_addr,
      cart_writedata        => cart_writedata,
      cart_writedata32      => cart_writedata32,
      cart_be32             => cart_be32,
      cart_done             => cart_done,
      cart_readdata         => cart_readdata,
      cart_waitcnt          => cart_waitcnt,
      dma_eepromcount       => dma_eepromcount,
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
      signal m_adr  : std_logic_vector(31 downto 0);
      signal m_ena  : std_logic;
      signal m_rnw  : std_logic;
      signal m_dout : std_logic_vector(31 downto 0);
   begin
      m_adr  <= << signal .tb_cart_eeprom.icore1.mem_bus_Adr  : std_logic_vector(31 downto 0) >>;
      m_ena  <= << signal .tb_cart_eeprom.icore1.mem_bus_ena  : std_logic >>;
      m_rnw  <= << signal .tb_cart_eeprom.icore1.mem_bus_rnw  : std_logic >>;
      m_dout <= << signal .tb_cart_eeprom.icore1.mem_bus_dout : std_logic_vector(31 downto 0) >>;

      sampler : process (clk)
      begin
         if rising_edge(clk) then
            if (m_ena = '1' and m_rnw = '0' and m_adr = x"03007800"
                and m_dout = x"DEADBEEF") then
               done_seen <= '1';
            end if;
         end if;
      end process;
   end block;

   check : process
   begin
      wait until done_seen = '1' for 60 ms;
      wait for 1 us;

      report "=== the real core driving a real EEPROM command ===";
      report "  /WR pulses on the cartridge : " & integer'image(wr_pulses);
      report "  /RD pulses on the cartridge : " & integer'image(rd_pulses);
      report "  /CS assertions total        : " & integer'image(cs_fall_cnt);
      report "  /CS assertions mid-command  : " & integer'image(ee_cs_in_cmd);
      report "  EEPROM commands aborted     : " & integer'image(ee_aborts);
      report "  EEPROM writes completed     : " & integer'image(ee_writes);
      report "  WAITCNT the game asked for  : 0x" & to_hstring(cart_waitcnt);

      if (cart_waitcnt(4) = '0' or cart_waitcnt(3 downto 2) /= "01") then
         report "probe did not take the fast WAITCNT - test is not proving anything"
            severity failure;
      end if;

      if (done_seen = '0') then
         report "probe never finished" severity failure;
      end if;
      if (wr_pulses < 81) then
         report "the core never put the 81 command bits on the bus (saw " &
                integer'image(wr_pulses) & ")" severity failure;
      end if;
      if (ee_aborts > 0) then
         report "EEPROM command torn up by /CS " & integer'image(ee_aborts) &
                " times - saves cannot work" severity failure;
      end if;
      if (ee_writes /= 1) then
         report "EEPROM did not latch exactly one write (got " &
                integer'image(ee_writes) & ")" severity failure;
      end if;
      report "EEPROM COMMAND SURVIVED THE REAL CORE" severity note;

      done <= true;
      stop;
   end process;

end architecture;
