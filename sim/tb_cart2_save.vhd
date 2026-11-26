-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.finish;

entity tb_cart2_save is
end entity;

architecture sim of tb_cart2_save is
   constant ROM_BASE   : natural := 16#0080000#;
   constant FLASH_BASE : natural := 16#4000000#;
   constant CART_ROM   : natural := 16#8000000#;
   constant CART_SAVE  : natural := 16#E000000#;
   constant CART_ALIAS : natural := 16#F000000#;

   signal clk1x, clk6x : std_logic := '0';
   signal phase : unsigned(2 downto 0) := (others => '0');
   signal reset : std_logic := '1';
   signal save_enable : std_logic := '1';

   signal cart_ena, cart_32, cart_rnw : std_logic := '0';
   signal cart_addr : std_logic_vector(27 downto 0) := (others => '0');
   signal cart_writedata : std_logic_vector(7 downto 0) := (others => '0');
   signal cart_done : std_logic;
   signal cart_readdata : std_logic_vector(31 downto 0);

   signal sdram_ena, sdram_rnw, sdram_done : std_logic := '0';
   signal sdram_addr : std_logic_vector(26 downto 0);
   signal sdram_din, sdram_dout : std_logic_vector(31 downto 0);
   signal sdram_be : std_logic_vector(3 downto 0);
begin
   clk1x <= not clk1x after 30 ns;
   clk6x <= not clk6x after 5 ns;
   process (clk6x)
   begin
      if rising_edge(clk6x) then
         if phase = 5 then phase <= (others => '0');
         else              phase <= phase + 1;
         end if;
      end if;
   end process;

   dut : entity work.gba_mem_cart2_sdram
      generic map (
         Softmap_GBA_Gamerom_ADDR => ROM_BASE,
         Softmap_GBA_FLASH_ADDR2  => FLASH_BASE
      )
      port map (
         clk1x           => clk1x,
         clk6x           => clk6x,
         clk6xIndex      => phase,
         reset           => reset,
         memory_remap    => '0',
         MaxPakAddr      => 25x"1",
         flash_1m        => '1',
         SramFlashEnable => save_enable,
         cart_ena        => cart_ena,
         cart_32         => cart_32,
         cart_rnw        => cart_rnw,
         cart_addr       => cart_addr,
         cart_writedata  => cart_writedata,
         cart_done       => cart_done,
         cart_readdata   => cart_readdata,
         cart_allow      => '1',
         cart_active     => open,
         cart_busy       => open,
         c2_sdram_ena    => sdram_ena,
         c2_sdram_rnw    => sdram_rnw,
         c2_sdram_Adr    => sdram_addr,
         c2_sdram_Din    => sdram_din,
         c2_sdram_be     => sdram_be,
         sdram_Dout      => sdram_dout,
         sdram_done32    => sdram_done
      );

   -- SDRAM stores one save byte per word; keep unrelated lanes nonzero to
   -- catch accidental lane selection. The cart sees the addressed ROM
   -- halfword in the low lanes and places it for the CPU bus.
   backing_store : process (clk6x)
      type bytes is array (0 to 131071) of std_logic_vector(7 downto 0);
      variable save_bytes : bytes := (others => x"FF");
      variable addr, idx : natural;
   begin
      if rising_edge(clk6x) then
         sdram_done <= sdram_ena;
         if sdram_ena = '1' then
            addr := to_integer(unsigned(sdram_addr));
            case addr is
               when ROM_BASE     => sdram_dout <= x"BEEF1234";
               when ROM_BASE + 2 => sdram_dout <= x"FEDCBEEF";
               when others =>
                  assert addr >= FLASH_BASE and addr < FLASH_BASE + 4 * save_bytes'length and addr mod 4 = 0
                     report "unexpected SDRAM address 0x" & to_hstring(sdram_addr) severity failure;
                  idx := (addr - FLASH_BASE) / 4;
                  if sdram_rnw = '0' then
                     assert sdram_be = "0001" report "save byte written to wrong lane" severity failure;
                     save_bytes(idx) := sdram_din(7 downto 0);
                  else
                     sdram_dout <= x"A5C3DE" & save_bytes(idx);
                  end if;
            end case;
         end if;
      end if;
   end process;

   stimulus : process
      procedure reset_cart is
      begin
         reset <= '1';
         wait until falling_edge(clk1x);
         wait until falling_edge(clk1x);
         reset <= '0';
      end procedure;

      procedure transfer(addr : natural; rnw, wide : std_logic; data : natural := 0) is
      begin
         wait until falling_edge(clk1x);
         cart_addr      <= std_logic_vector(to_unsigned(addr, cart_addr'length));
         cart_rnw       <= rnw;
         cart_32        <= wide;
         cart_writedata <= std_logic_vector(to_unsigned(data, cart_writedata'length));
         cart_ena       <= '1';
         wait until rising_edge(clk1x);
         cart_ena       <= '0';
         cart_addr      <= (others => '0');
         wait until cart_done = '1' for 1 ms;
         assert cart_done = '1' report "cart request timed out at 0x" & to_hstring(to_unsigned(addr, 28)) severity failure;
      end procedure;

      procedure expect_word(addr : natural; data : std_logic_vector(31 downto 0); wide : std_logic := '0') is
      begin
         transfer(addr, '1', wide);
         assert cart_readdata = data
            report "read 0x" & to_hstring(to_unsigned(addr, 28)) & ": expected " & to_hstring(data) & ", got " & to_hstring(cart_readdata)
            severity failure;
      end procedure;

      procedure expect_byte(addr, data : natural) is
      begin
         transfer(addr, '1', '0');
         assert unsigned(cart_readdata(7 downto 0)) = data
            report "save read 0x" & to_hstring(to_unsigned(addr, 28)) & ": expected " & to_hstring(to_unsigned(data, 8)) & ", got " & to_hstring(cart_readdata)
            severity failure;
      end procedure;

      procedure wr(addr, data : natural) is
      begin
         transfer(CART_SAVE + addr, '0', '0', data);
      end procedure;

      procedure flash_cmd(cmd : natural) is
      begin
         wr(16#5555#, 16#AA#);
         wr(16#2AAA#, 16#55#);
         wr(16#5555#, cmd);
      end procedure;
   begin
      reset_cart;
      expect_word(CART_ROM, x"BEEF1234", '1');
      expect_word(CART_ROM, x"00001234");
      expect_word(CART_ROM + 2, x"BEEF0000");
      expect_word(CART_ROM + 6, x"00030004"); -- out-of-range ROM uses ANSWER

      flash_cmd(16#90#);
      expect_word(CART_SAVE, x"62626262");
      expect_word(CART_SAVE + 1, x"13131313");
      expect_word(CART_SAVE + 2, x"00000000");
      expect_word(CART_SAVE + 3, x"00000000");
      wr(16#5555#, 16#F0#);

      -- Different patterns in the two banks detect aliasing as well as
      -- dropped bytes at guest address offsets 2 and 3.
      for bank in 0 to 1 loop
         flash_cmd(16#B0#);
         wr(0, bank);
         for offset in 0 to 15 loop
            flash_cmd(16#A0#);
            wr(offset, 16#20# + bank * 16#80# + offset);
            expect_byte(CART_SAVE + offset, 16#20# + bank * 16#80# + offset);
         end loop;
      end loop;

      reset_cart;  -- bank resets to 0; the backing store must survive
      for bank in 0 to 1 loop
         if bank = 1 then
            flash_cmd(16#B0#);
            wr(0, bank);
         end if;
         for offset in 0 to 15 loop
            expect_byte(CART_SAVE + offset, 16#20# + bank * 16#80# + offset);
            expect_byte(CART_ALIAS + offset, 16#20# + bank * 16#80# + offset);
         end loop;
      end loop;

      flash_cmd(16#80#);
      wr(16#5555#, 16#AA#);
      wr(16#2AAA#, 16#55#);
      wr(0, 16#30#);
      expect_word(CART_SAVE + 2, x"FFFFFFFF"); -- erase-complete ANSWER
      for offset in 0 to 15 loop
         expect_byte(CART_SAVE + offset, 16#FF#);
      end loop;
      flash_cmd(16#B0#);
      wr(0, 0);
      expect_byte(CART_SAVE + 2, 16#22#); -- erasing bank 1 must not erase bank 0

      reset_cart; -- a first write away from the unlock address selects SRAM
      for offset in 0 to 15 loop
         wr(offset, 16#60# + offset);
      end loop;
      for offset in 0 to 15 loop
         expect_byte(CART_SAVE + offset, 16#60# + offset);
         expect_byte(CART_ALIAS + offset, 16#60# + offset);
      end loop;

      save_enable <= '0';
      for offset in 0 to 3 loop
         expect_word(CART_SAVE + offset, x"FFFFFFFF");
      end loop;
      report "Core 2 Flash1M and SRAM byte-lane tests passed";
      finish;
   end process;
end architecture;
