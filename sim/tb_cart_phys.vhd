-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- gba_cart_phys against a behavioural GBA Game Pak.
--
-- The cartridge model implements exactly what GBATEK specifies and nothing
-- more, so it fails the DUT rather than covering for it:
--   * A0..A15 are latched into a 16 bit counter on the FALLING edge of /CS,
--     A16..A23 are read live off the pins
--   * the counter increments on every RISING edge of /RD or /WR while /CS is
--     low, and wraps inside its 16 bits (the 128 KB page boundary)
--   * ROM data only appears while /CS and /RD are both low
--   * SRAM is selected by /CS2, addressed by AD0-15, and moves its byte on
--     A16-23
--
-- Plus the two save devices a Game Pak can carry instead of plain SRAM, both
-- modelled the way the silicon actually behaves rather than the way a
-- convenient bus master would like it to:
--   * FLASH on /CS2, with the 5555/2AAA/5555 command unlock, the autoselect
--     ID a save library reads before it will save at all, and byte program
--   * EEPROM on the ROM bus, selected by A23, clocked by /WR and /RD while
--     /CS stays low. It counts bits, and - this is the part that matters -
--     it ABORTS if /CS rises part way through a command, exactly like the
--     real chip. ee_aborts counts those.
--
-- It also asserts on the two ways this bus can be driven into a short:
-- FPGA and cartridge driving the same group, and /CS with /CS2.

entity tb_cart_phys is
end entity;

architecture test of tb_cart_phys is

   -- Both start high so that every rising edge lands on an integer multiple of
   -- TCK6 and clk1x's edges coincide EXACTLY with clk6x's, delta included -
   -- that is what the PLL does. Deriving clk1x from a process clocked by clk6x
   -- instead would put it one delta late, and the clk1x flops would then see
   -- clk6x updates from the very same edge, which silicon never does.
   signal clk6x  : std_logic := '1';
   signal clk1x  : std_logic := '1';
   signal reset  : std_logic := '1';

   signal enable     : std_logic := '1';
   signal timing_sel : std_logic_vector(1 downto 0) := "00";

   signal cart_ena         : std_logic := '0';
   signal cart_32          : std_logic := '0';
   signal cart_rnw         : std_logic := '1';
   signal cart_addr        : std_logic_vector(27 downto 0) := (others => '0');
   signal cart_writedata   : std_logic_vector(7 downto 0) := (others => '0');
   signal cart_writedata32 : std_logic_vector(31 downto 0) := (others => '0');
   signal cart_be32        : std_logic_vector(3 downto 0) := (others => '0');
   signal cart_done        : std_logic;
   signal cart_readdata    : std_logic_vector(31 downto 0);
   signal cart_waitcnt     : std_logic_vector(15 downto 0) := (others => '0');

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

   -- cartridge model state
   signal latched    : unsigned(15 downto 0) := (others => '0');
   type t_sram is array (0 to 255) of std_logic_vector(7 downto 0);
   signal sram       : t_sram := (others => x"00");
   signal rom_wr_addr : unsigned(23 downto 0) := (others => '0');
   signal rom_wr_data : std_logic_vector(15 downto 0) := (others => '0');
   signal rom_wr_cnt  : integer := 0;
   signal cs_fall_cnt : integer := 0;

   -- Which save chip the modelled cartridge carries on /CS2. A real Game Pak
   -- has one or the other, never both, so the stimulus flips this rather than
   -- wiring up two chips at once.
   signal save_is_flash : boolean := false;

   -- FLASH on /CS2 (Macronix-style IDs, which is what most Game Paks answer)
   type t_flstate is (FL_READ_ARRAY, FL_CMD1, FL_CMD2, FL_AUTOSELECT, FL_PROGRAM);
   signal fl_state : t_flstate := FL_READ_ARRAY;
   type t_flash is array (0 to 255) of std_logic_vector(7 downto 0);
   signal flash : t_flash := (others => x"FF");
   constant FL_MANUF : std_logic_vector(7 downto 0) := x"C2";
   constant FL_DEVID : std_logic_vector(7 downto 0) := x"1C";
   signal fl_dataout : std_logic_vector(7 downto 0);

   -- EEPROM on the ROM bus. Both capacities exist and differ only in how many
   -- address bits ride in the command, so the model takes that as a parameter:
   --   4 Kbit  (512 byte)   6 address bits ->  9 bit read request, 73 bit write
   --   64 Kbit (8 KB)      14 address bits -> 17 bit read request, 81 bit write
   -- The 64 Kbit part is the one in Phantasy Star Collection (AGB-AYC, a ROHM
   -- 9854), which is the cartridge that turned this bug up.
   -- A read then moves 4 dummy bits and 64 data bits out on AD0, one per /RD.
   signal ee_abits  : integer range 6 to 14 := 6;
   type t_eestate is (EE_IDLE, EE_CMD, EE_ARMED, EE_READOUT);
   signal ee_state  : t_eestate := EE_IDLE;
   signal ee_bits   : integer range 0 to 127 := 0;
   signal ee_cmd_rd : std_logic := '0';                          -- "11" read / "10" write
   signal ee_addr   : unsigned(13 downto 0) := (others => '0');
   signal ee_wdata  : std_logic_vector(63 downto 0) := (others => '0');
   signal ee_rdaddr : integer range 0 to 1023 := 0;
   signal ee_rdcnt  : integer range 0 to 127 := 0;
   type t_eemem is array (0 to 1023) of std_logic_vector(63 downto 0);
   signal ee_mem    : t_eemem := (others => (others => '0'));
   signal ee_sel    : std_logic;
   signal ee_bitout : std_logic;
   -- scoreboard for the EEPROM: streams torn up by /CS, and completed writes
   signal ee_aborts : integer := 0;
   signal ee_writes : integer := 0;

   -- scoreboard
   signal errors : integer := 0;

   constant TCK6 : time := 9934 ps;   -- 100.663296 MHz

   function rom_word(ha : unsigned(23 downto 0)) return std_logic_vector is
      variable up : unsigned(15 downto 0);
   begin
      up := ha(23 downto 16) & to_unsigned(16#5A#, 8);
      return std_logic_vector(ha(15 downto 0) xor up);
   end function;

   signal eff_ha         : unsigned(23 downto 0);
   signal cart_drives_ad : std_logic;
   signal cart_drives_a  : std_logic;

begin

   ----------------------------------------------------------------------------
   -- clocks: clk1x is clk6x/6 so both stay phase locked like the real PLL
   ----------------------------------------------------------------------------
   clk6x <= not clk6x after TCK6 / 2;
   clk1x <= not clk1x after 3 * TCK6;

   ----------------------------------------------------------------------------
   -- DUT
   ----------------------------------------------------------------------------
   dut : entity work.gba_cart_phys
   port map (
      clk1x => clk1x, clk6x => clk6x, reset => reset,
      enable => enable, timing_sel => timing_sel,
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

   ----------------------------------------------------------------------------
   -- cartridge model
   ----------------------------------------------------------------------------
   eff_ha <= unsigned(pin_a_out) & latched;

   -- A23 is what puts the EEPROM rather than the ROM on the far end of a /CS
   -- access. It stays driven for the whole access, sequential beats included.
   ee_sel <= pin_a_out(7);

   cart_drives_ad <= '1' when (pin_cs_n = '0' and pin_rd_n = '0' and pin_cs2_n = '1') else '0';
   cart_drives_a  <= '1' when (pin_cs2_n = '0' and pin_rd_n = '0') else '0';

   pin_ad_in <= x"000" & "000" & ee_bitout
                   when (cart_drives_ad = '1' and ee_sel = '1' and ee_state = EE_READOUT) else
                rom_word(eff_ha) when cart_drives_ad = '1' else
                (others => '1');

   fl_dataout <= FL_MANUF when (fl_state = FL_AUTOSELECT and unsigned(pin_ad_out) = 0) else
                 FL_DEVID when (fl_state = FL_AUTOSELECT and unsigned(pin_ad_out) = 1) else
                 flash(to_integer(unsigned(pin_ad_out(7 downto 0))));

   pin_a_in  <= fl_dataout when (cart_drives_a = '1' and save_is_flash) else
                sram(to_integer(unsigned(pin_ad_out(7 downto 0))))
                   when (cart_drives_a = '1' and unsigned(pin_ad_out) < 256) else
                (others => '1');

   -- 4 dummy bits, then the 64 data bits MSB first
   ee_bitout <= '0' when (ee_rdcnt < 4 or ee_rdcnt >= 68) else
                ee_mem(ee_rdaddr)(63 - (ee_rdcnt - 4));

   -- latch / increment / writes
   process
      variable cs_p, rd_p, wr_p : std_logic := '1';
   begin
      wait on pin_cs_n, pin_rd_n, pin_wr_n, pin_cs2_n;

      if (pin_cs_n = '0' and cs_p = '1') then
         latched     <= unsigned(pin_ad_out);
         cs_fall_cnt <= cs_fall_cnt + 1;
      elsif (pin_cs_n = '0' and pin_rd_n = '1' and rd_p = '0') then
         latched <= latched + 1;
      elsif (pin_cs_n = '0' and pin_wr_n = '1' and wr_p = '0') then
         rom_wr_addr <= eff_ha;
         rom_wr_data <= pin_ad_out;
         rom_wr_cnt  <= rom_wr_cnt + 1;
         latched     <= latched + 1;
      end if;

      if (pin_cs2_n = '0' and pin_wr_n = '1' and wr_p = '0') then
         if (not save_is_flash) then
            if (unsigned(pin_ad_out) < 256) then
               sram(to_integer(unsigned(pin_ad_out(7 downto 0)))) <= pin_a_out;
            end if;
         else
            -- the 5555 / 2AAA / 5555 unlock every GBA flash save chip wants
            case (fl_state) is
               when FL_READ_ARRAY =>
                  if (unsigned(pin_ad_out) = 16#5555# and pin_a_out = x"AA") then
                     fl_state <= FL_CMD1;
                  end if;
               when FL_CMD1 =>
                  if (unsigned(pin_ad_out) = 16#2AAA# and pin_a_out = x"55") then
                     fl_state <= FL_CMD2;
                  else
                     fl_state <= FL_READ_ARRAY;
                  end if;
               when FL_CMD2 =>
                  if (unsigned(pin_ad_out) = 16#5555#) then
                     case (pin_a_out) is
                        when x"90"  => fl_state <= FL_AUTOSELECT;
                        when x"A0"  => fl_state <= FL_PROGRAM;
                        when others => fl_state <= FL_READ_ARRAY;
                     end case;
                  else
                     fl_state <= FL_READ_ARRAY;
                  end if;
               when FL_AUTOSELECT =>
                  if (pin_a_out = x"F0") then
                     fl_state <= FL_READ_ARRAY;
                  elsif (unsigned(pin_ad_out) = 16#5555# and pin_a_out = x"AA") then
                     fl_state <= FL_CMD1;
                  end if;
               when FL_PROGRAM =>
                  if (unsigned(pin_ad_out) < 256) then
                     flash(to_integer(unsigned(pin_ad_out(7 downto 0)))) <= pin_a_out;
                  end if;
                  fl_state <= FL_READ_ARRAY;
            end case;
         end if;
      end if;

      cs_p := pin_cs_n; rd_p := pin_rd_n; wr_p := pin_wr_n;
   end process;

   -- EEPROM: bit banged on /WR and /RD while /CS is held low for the whole
   -- command. Letting /CS rise part way through is how the real chip loses the
   -- transfer, so the model does exactly that and counts it in ee_aborts.
   process
      variable cs_p, wr_p, rd_p : std_logic := '1';
   begin
      wait on pin_cs_n, pin_wr_n, pin_rd_n;

      if (pin_cs_n = '0' and cs_p = '1' and ee_sel = '1') then
         if (ee_state = EE_ARMED) then
            ee_state <= EE_READOUT;      -- the data phase of a read request
            ee_rdcnt <= 0;
         else
            ee_state <= EE_CMD;
            ee_bits  <= 0;
            ee_addr  <= (others => '0');
         end if;

      elsif (pin_cs_n = '1' and cs_p = '0') then
         -- a /CS cycle that clocked no command bits at all is just an ordinary
         -- ROM access that happened to have A23 set, not a torn up command
         if (ee_state = EE_CMD and ee_bits > 0) then
            ee_aborts <= ee_aborts + 1;
            report "EEPROM: /CS released after only " & integer'image(ee_bits) &
                   " bits - the chip drops the whole command here" severity warning;
         end if;
         if (ee_state /= EE_ARMED) then
            ee_state <= EE_IDLE;
         end if;

      elsif (pin_cs_n = '0' and pin_wr_n = '1' and wr_p = '0' and ee_state = EE_CMD) then
         if (ee_bits = 0) then                            -- leading '1' of the mode field
            ee_bits <= 1;
         elsif (ee_bits = 1) then
            ee_cmd_rd <= pin_ad_out(0);                   -- '1' read, '0' write
            ee_bits   <= 2;
         elsif (ee_bits < 2 + ee_abits) then              -- the address
            ee_addr <= ee_addr(12 downto 0) & pin_ad_out(0);
            ee_bits <= ee_bits + 1;
         elsif (ee_cmd_rd = '1') then                     -- read: next bit is the stop bit
            ee_rdaddr <= to_integer(ee_addr(9 downto 0));
            ee_state  <= EE_ARMED;
         elsif (ee_bits < 2 + ee_abits + 64) then         -- write: 64 data bits
            ee_wdata <= ee_wdata(62 downto 0) & pin_ad_out(0);
            ee_bits  <= ee_bits + 1;
         else                                             -- write: stop bit commits
            ee_mem(to_integer(ee_addr(9 downto 0))) <= ee_wdata;
            ee_writes <= ee_writes + 1;
            ee_state  <= EE_IDLE;
         end if;

      elsif (pin_cs_n = '0' and pin_rd_n = '1' and rd_p = '0' and ee_state = EE_READOUT) then
         ee_rdcnt <= ee_rdcnt + 1;
      end if;

      cs_p := pin_cs_n; wr_p := pin_wr_n; rd_p := pin_rd_n;
   end process;

   -- electrical safety nets
   process (clk6x)
   begin
      if rising_edge(clk6x) then
         assert not (cart_drives_ad = '1' and pin_ad_drive = '1')
            report "BUS CONFLICT: FPGA and cartridge both driving AD0-15" severity failure;
         assert not (cart_drives_a = '1' and pin_a_drive = '1')
            report "BUS CONFLICT: FPGA and cartridge both driving A16-23" severity failure;
         assert not (pin_cs_n = '0' and pin_cs2_n = '0')
            report "BUS CONFLICT: /CS and /CS2 asserted together" severity failure;
      end if;
   end process;

   ----------------------------------------------------------------------------
   -- stimulus
   ----------------------------------------------------------------------------
   process

      procedure tick is begin wait until rising_edge(clk1x); end procedure;

      -- issue one request and wait for the handshake, measuring its length
      procedure access_cart(addr : in unsigned(27 downto 0);
                            rnw  : in std_logic;
                            w32  : in std_logic;
                            wdat : in std_logic_vector(31 downto 0);
                            wbyt : in std_logic_vector(7 downto 0);
                            got  : out std_logic_vector(31 downto 0);
                            cycs : out integer) is
         variable n : integer := 0;
      begin
         wait until rising_edge(clk1x);
         cart_addr        <= std_logic_vector(addr);
         cart_rnw         <= rnw;
         cart_32          <= w32;
         cart_writedata32 <= wdat;
         cart_writedata   <= wbyt;
         cart_ena         <= '1';
         wait until rising_edge(clk1x);
         cart_ena <= '0';
         n := 1;
         while cart_done /= '1' loop
            wait until rising_edge(clk1x);
            n := n + 1;
         end loop;
         got  := cart_readdata;
         cycs := n;
      end procedure;

      -- One EEPROM command, the way DMA3 to 0x0DFFFF00 puts it on the bus:
      -- consecutive halfword writes, one command bit in AD0 each. Both halves
      -- of writedata32 carry the bit because the rotate stage upstream picks a
      -- half by address bit 1.
      procedure ee_stream(bits : in std_logic_vector; base : in unsigned(27 downto 0)) is
         variable dd : std_logic_vector(31 downto 0);
         variable cc : integer;
         variable w  : std_logic_vector(31 downto 0);
         variable a  : unsigned(27 downto 0);
      begin
         a := base;
         for i in bits'range loop
            w := x"000" & "000" & bits(i) & x"000" & "000" & bits(i);
            access_cart(a, '0', '0', w, "0000000" & bits(i), dd, cc);
            a := a + 2;
         end loop;
      end procedure;

      procedure check16(name : in string; got : in std_logic_vector(31 downto 0);
                        want : in std_logic_vector(15 downto 0)) is
      begin
         if got(15 downto 0) /= want then
            report name & ": got " & to_hstring(got(15 downto 0)) &
                   " want " & to_hstring(want) severity error;
            errors <= errors + 1;
         else
            report name & ": ok " & to_hstring(want);
         end if;
      end procedure;

      procedure check32(name : in string; got : in std_logic_vector(31 downto 0);
                        want : in std_logic_vector(31 downto 0)) is
      begin
         if got /= want then
            report name & ": got " & to_hstring(got) & " want " & to_hstring(want) severity error;
            errors <= errors + 1;
         else
            report name & ": ok " & to_hstring(want);
         end if;
      end procedure;

      procedure expect(name : in string; got : in integer; want : in integer) is
      begin
         if got /= want then
            report name & ": got " & integer'image(got) & " want " & integer'image(want) severity error;
            errors <= errors + 1;
         else
            report name & ": ok " & integer'image(want);
         end if;
      end procedure;

      variable d       : std_logic_vector(31 downto 0);
      variable c       : integer;
      variable cs_mark : integer;
      variable nseq_c  : integer;
      variable seq_c   : integer;
      variable ee_wr   : std_logic_vector(0 to 72);
      variable ee_rd   : std_logic_vector(0 to 8);
      variable ee_wr14 : std_logic_vector(0 to 80);
      variable ee_rd14 : std_logic_vector(0 to 16);
      variable ee_got  : std_logic_vector(63 downto 0);
      variable ea      : unsigned(27 downto 0);
      constant EE_PAT  : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
      constant EE_PAT2 : std_logic_vector(63 downto 0) := x"FEDCBA9876543210";
   begin
      reset <= '1';
      for i in 0 to 20 loop tick; end loop;
      reset <= '0';
      for i in 0 to 5 loop tick; end loop;

      report "=== ROM: non-sequential read ===";
      access_cart(x"8000000", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[0]", d, rom_word(to_unsigned(0, 24)));
      nseq_c := c;

      report "=== ROM: sequential read must NOT re-latch /CS ===";
      cs_mark := cs_fall_cnt;
      access_cart(x"8000002", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[1]", d, rom_word(to_unsigned(1, 24)));
      expect("no new /CS for sequential beat", cs_fall_cnt - cs_mark, 0);
      seq_c := c;

      report "=== ROM: 32 bit read is two sequential halfwords ===";
      access_cart(x"8000004", '1', '1', (others => '0'), x"00", d, c);
      check32("rom[2,3]", d, rom_word(to_unsigned(3, 24)) & rom_word(to_unsigned(2, 24)));

      report "=== ROM: random access re-latches ===";
      cs_mark := cs_fall_cnt;
      access_cart(x"8123456", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[0x091a2b]", d, rom_word(to_unsigned(16#091A2B#, 24)));
      expect("new /CS for non-sequential", cs_fall_cnt - cs_mark, 1);

      report "=== ROM: WS1/WS2 mirrors hit the same cartridge address ===";
      access_cart(x"A123456", '1', '0', (others => '0'), x"00", d, c);
      check16("mirror 0xA", d, rom_word(to_unsigned(16#091A2B#, 24)));
      access_cart(x"C123458", '1', '0', (others => '0'), x"00", d, c);
      check16("mirror 0xC", d, rom_word(to_unsigned(16#091A2C#, 24)));

      report "=== ROM: the cartridge counter wraps at 128 KB, so we must not burst across it ===";
      -- 0x0801FFFE is halfword 0x00FFFF, the last one the counter can reach
      access_cart(x"801FFFE", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[0x00ffff]", d, rom_word(to_unsigned(16#00FFFF#, 24)));
      cs_mark := cs_fall_cnt;
      access_cart(x"8020000", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[0x010000] across the wrap", d, rom_word(to_unsigned(16#010000#, 24)));
      expect("wrap forced a fresh address phase", cs_fall_cnt - cs_mark, 1);

      report "=== ROM: 16 bit write (GPIO register) ===";
      access_cart(x"80000C4", '0', '0', x"0000" & x"00A5", x"A5", d, c);
      expect("one ROM write seen", rom_wr_cnt, 1);
      if rom_wr_addr /= to_unsigned(16#000062#, 24) then
         report "GPIO write addr: got " & to_hstring(rom_wr_addr) & " want 000062" severity error;
         errors <= errors + 1;
      else
         report "GPIO write addr: ok 000062";
      end if;
      if rom_wr_data /= x"00A5" then
         report "GPIO write data: got " & to_hstring(rom_wr_data) severity error;
         errors <= errors + 1;
      else
         report "GPIO write data: ok 00A5";
      end if;

      report "=== ROM: 16 bit write at an odd halfword takes the upper rotate half ===";
      access_cart(x"80000C6", '0', '0', x"1234" & x"0000", x"34", d, c);
      if rom_wr_data /= x"1234" then
         report "odd-halfword write data: got " & to_hstring(rom_wr_data) severity error;
         errors <= errors + 1;
      else
         report "odd-halfword write data: ok 1234";
      end if;

      report "=== SRAM: write then read back over /CS2 ===";
      access_cart(x"E000010", '0', '0', (others => '0'), x"3C", d, c);
      access_cart(x"E000011", '0', '0', (others => '0'), x"D7", d, c);
      access_cart(x"E000010", '1', '0', (others => '0'), x"00", d, c);
      check16("sram[0x10]", d, x"003C");
      access_cart(x"E000011", '1', '0', (others => '0'), x"00", d, c);
      check16("sram[0x11]", d, x"00D7");

      report "=== SRAM access must not leave a stale ROM burst behind ===";
      access_cart(x"8000000", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[0] after sram", d, rom_word(to_unsigned(0, 24)));

      report "=== FLASH: the autoselect ID a save library reads before it saves at all ===";
      save_is_flash <= true;
      for i in 0 to 5 loop tick; end loop;
      access_cart(x"E005555", '0', '0', (others => '0'), x"AA", d, c);
      access_cart(x"E002AAA", '0', '0', (others => '0'), x"55", d, c);
      access_cart(x"E005555", '0', '0', (others => '0'), x"90", d, c);
      access_cart(x"E000000", '1', '0', (others => '0'), x"00", d, c);
      check16("flash manufacturer id", d, x"00C2");
      access_cart(x"E000001", '1', '0', (others => '0'), x"00", d, c);
      check16("flash device id", d, x"001C");
      access_cart(x"E005555", '0', '0', (others => '0'), x"AA", d, c);
      access_cart(x"E002AAA", '0', '0', (others => '0'), x"55", d, c);
      access_cart(x"E005555", '0', '0', (others => '0'), x"F0", d, c);

      report "=== FLASH: byte program ===";
      access_cart(x"E005555", '0', '0', (others => '0'), x"AA", d, c);
      access_cart(x"E002AAA", '0', '0', (others => '0'), x"55", d, c);
      access_cart(x"E005555", '0', '0', (others => '0'), x"A0", d, c);
      access_cart(x"E000020", '0', '0', (others => '0'), x"5E", d, c);
      access_cart(x"E000020", '1', '0', (others => '0'), x"00", d, c);
      check16("flash byte programmed", d, x"005E");
      save_is_flash <= false;
      for i in 0 to 5 loop tick; end loop;

      report "=== EEPROM: the write stream is ONE command, /CS low throughout ===";
      -- "10" + address 0x15 + 64 data bits + stop bit = 73 halfword writes
      ee_wr   := "10" & "010101" & EE_PAT & "0";
      cs_mark := cs_fall_cnt;
      ee_stream(ee_wr, x"DFFFF00");
      expect("EEPROM write: one /CS for the whole stream", cs_fall_cnt - cs_mark, 1);
      expect("EEPROM write: no command torn up by /CS", ee_aborts, 0);
      expect("EEPROM write: one complete write latched", ee_writes, 1);

      report "=== EEPROM: read request, then the 68 bit readout ===";
      ee_rd   := "11" & "010101" & "0";
      cs_mark := cs_fall_cnt;
      ee_stream(ee_rd, x"DFFFF00");
      expect("EEPROM read request: one /CS for the whole stream", cs_fall_cnt - cs_mark, 1);
      expect("EEPROM read request: no command torn up by /CS", ee_aborts, 0);

      ee_got := (others => '0');
      ea     := x"DFFFF00";
      for i in 0 to 67 loop
         access_cart(ea, '1', '0', (others => '0'), x"00", d, c);
         if (i >= 4) then
            ee_got := ee_got(62 downto 0) & d(0);
         end if;
         ea := ea + 2;
      end loop;
      if (ee_got /= EE_PAT) then
         report "EEPROM readback: got " & to_hstring(ee_got) &
                " want " & to_hstring(EE_PAT) severity error;
         errors <= errors + 1;
      else
         report "EEPROM readback: ok " & to_hstring(EE_PAT);
      end if;

      report "=== EEPROM 64 Kbit: 14 address bits, so 17 bit request and 81 bit write ===";
      report "    this is the part in Phantasy Star Collection (AGB-AYC, ROHM 9854)";
      ee_abits <= 14;
      for i in 0 to 5 loop tick; end loop;

      ee_wr14 := "10" & "00000000101010" & EE_PAT2 & "0";
      cs_mark := cs_fall_cnt;
      ee_stream(ee_wr14, x"DFFFF00");
      expect("EEPROM 64K write: one /CS for the whole stream", cs_fall_cnt - cs_mark, 1);
      expect("EEPROM 64K write: no command torn up by /CS", ee_aborts, 0);
      expect("EEPROM 64K write: a second complete write latched", ee_writes, 2);

      ee_rd14 := "11" & "00000000101010" & "0";
      cs_mark := cs_fall_cnt;
      ee_stream(ee_rd14, x"DFFFF00");
      expect("EEPROM 64K read request: one /CS for the whole stream", cs_fall_cnt - cs_mark, 1);
      expect("EEPROM 64K read request: no command torn up by /CS", ee_aborts, 0);

      ee_got := (others => '0');
      ea     := x"DFFFF00";
      for i in 0 to 67 loop
         access_cart(ea, '1', '0', (others => '0'), x"00", d, c);
         if (i >= 4) then
            ee_got := ee_got(62 downto 0) & d(0);
         end if;
         ea := ea + 2;
      end loop;
      if (ee_got /= EE_PAT2) then
         report "EEPROM 64K readback: got " & to_hstring(ee_got) &
                " want " & to_hstring(EE_PAT2) severity error;
         errors <= errors + 1;
      else
         report "EEPROM 64K readback: ok " & to_hstring(EE_PAT2);
      end if;
      ee_abits <= 6;
      for i in 0 to 5 loop tick; end loop;

      report "=== EEPROM access must not leave a stale ROM burst behind ===";
      access_cart(x"8000000", '1', '0', (others => '0'), x"00", d, c);
      check16("rom[0] after eeprom", d, rom_word(to_unsigned(0, 24)));

      report "=== PHI terminal follows WAITCNT ===";
      cart_waitcnt <= (others => '0');
      for i in 0 to 30 loop wait until rising_edge(clk6x); end loop;
      if pin_phi /= '0' then
         report "PHI should be off when WAITCNT[12:11]=0" severity error;
         errors <= errors + 1;
      else
         report "PHI off: ok";
      end if;

      report "=== timing summary (emulated 16.78 MHz cycles per access) ===";
      report "  non-sequential ROM read (accurate preset, default): " & integer'image(nseq_c) & " cycles";
      report "  sequential ROM read (accurate preset, default):     " & integer'image(seq_c) & " cycles";

      timing_sel <= "01";   -- tolerant
      for i in 0 to 10 loop tick; end loop;
      access_cart(x"9000000", '1', '0', (others => '0'), x"00", d, c);
      check16("tolerant preset still correct", d, rom_word(to_unsigned(16#800000#, 24)));
      report "  non-sequential ROM read (tolerant preset): " & integer'image(c) & " cycles";
      access_cart(x"9000002", '1', '0', (others => '0'), x"00", d, c);
      report "  sequential ROM read (tolerant preset):     " & integer'image(c) & " cycles";

      timing_sel <= "00";   -- back to accurate
      for i in 0 to 10 loop tick; end loop;
      access_cart(x"9000100", '1', '0', (others => '0'), x"00", d, c);
      check16("accurate preset still correct", d, rom_word(to_unsigned(16#800080#, 24)));
      report "  non-sequential ROM read (accurate preset): " & integer'image(c) & " cycles";
      access_cart(x"9000102", '1', '0', (others => '0'), x"00", d, c);
      check16("accurate preset sequential", d, rom_word(to_unsigned(16#800081#, 24)));
      report "  sequential ROM read (accurate preset):     " & integer'image(c) & " cycles";

      report "=== disabled core must release every pin ===";
      enable <= '0';
      for i in 0 to 10 loop tick; end loop;
      if pin_ad_drive /= '0' or pin_a_drive /= '0' or pin_cs_n /= '1'
         or pin_cs2_n /= '1' or pin_rd_n /= '1' or pin_wr_n /= '1' then
         report "pins not released when disabled" severity error;
         errors <= errors + 1;
      else
         report "pins released: ok";
      end if;

      wait for 1 us;
      if errors = 0 then
         report "ALL CART BUS TESTS PASSED" severity note;
      else
         report integer'image(errors) & " CART BUS TEST FAILURES" severity failure;
      end if;
      std.env.stop;
      wait;
   end process;

end architecture;
