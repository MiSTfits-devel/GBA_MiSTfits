-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Cart channel for the second GBA core (2P profile). Serves core 2's gamepak
-- bus from the shared SDRAM port as a guest channel with the same
-- allow/active/busy handshake as gba_mem_ewram_sdram.
--
--   * ROM reads (0x8..0xC) hit the shared ROM image in SDRAM. Both cores boot
--     the same cart until two-ROM support lands (WP5); the image is read only,
--     so serving two masters is race free and needs no locking.
--   * reads behind the cart data return the open bus pattern, mirroring
--     READAFTERPAK in memorymux_extern.
--   * EEPROM (0xD) reads answer "ready" (1), Flash/SRAM (0xE/0xF) reads answer
--     open bus (all 1) exactly like SramFlashEnable = 0 in memorymux_extern.
--     Core 2 has no save memory yet: all cart writes complete immediately and
--     are dropped.
--
-- No prefetch cache: a single SDRAM roundtrip is well below the modeled cart
-- waitstates in gba_memorymux, so core 2 only stalls extra while the shared
-- port is contended. Reads always run the full 32bit burst (done32), which
-- keeps the channel free of burst tails that could alias into other channels.
entity gba_mem_cart2_sdram is
   generic
   (
      Softmap_GBA_Gamerom_ADDR : integer -- count: 8388608 -- 32 Mbyte Data for GameRom
   );
   port
   (
      clk1x           : in  std_logic;
      clk6x           : in  std_logic;
      clk6xIndex      : in  unsigned(2 downto 0);
      reset           : in  std_logic;

      memory_remap    : in  std_logic;
      MaxPakAddr      : in  std_logic_vector(24 downto 0);

      cart_ena        : in  std_logic;
      cart_32         : in  std_logic;
      cart_rnw        : in  std_logic;
      cart_addr       : in  std_logic_vector(27 downto 0);
      cart_done       : out std_logic := '0';
      cart_readdata   : out std_logic_vector(31 downto 0) := (others => '0');

      cart_allow      : in  std_logic; -- shared port idle, may start at clk6xIndex 0
      cart_active     : out std_logic; -- SDRAM request pending or in flight -> extern must not launch
      cart_busy       : out std_logic; -- SDRAM op in flight -> owns the request bus

      c2_sdram_ena    : out std_logic := '0';
      c2_sdram_Adr    : out std_logic_vector(26 downto 0) := (others => '0');
      sdram_Dout      : in  std_logic_vector(31 downto 0);
      sdram_done32    : in  std_logic
   );
end entity;

architecture arch of gba_mem_cart2_sdram is

   type tState1X is
   (
      IDLE1X,
      ANSWER,   -- request served without SDRAM, complete next cycle
      WAITDATA
   );
   signal state1x : tState1X := IDLE1X;

   type tState6X is
   (
      C2_IDLE,
      C2_WAIT,
      C2_DONE
   );
   signal state6x : tState6X := C2_IDLE;

   signal req_pending : std_logic := '0';
   signal readdata_6x : std_logic_vector(31 downto 0) := (others => '0');

   signal addr1_1     : std_logic := '0';
   signal c32_1       : std_logic := '0';
   signal ansdata      : std_logic_vector(31 downto 0) := (others => '0');

begin

   cart_active <= req_pending;
   cart_busy   <= '1' when (state6x = C2_WAIT) else '0';

   -- done/readdata are registered on clk1x before export, following the WP2
   -- discipline: the 6x->1x crossing must be a plain register capture.
   process (clk1x)
   begin
      if rising_edge(clk1x) then

         cart_done <= '0';

         if (reset = '1') then
            state1x     <= IDLE1X;
            req_pending <= '0';
         else
            case (state1x) is

               when IDLE1X =>
                  if (cart_ena = '1') then
                     addr1_1 <= cart_addr(1);
                     c32_1   <= cart_32;
                     if (cart_rnw = '0') then
                        -- no save memory on core 2 (yet): writes are dropped
                        state1x <= ANSWER;
                        ansdata  <= (others => '0');
                     else
                        case (cart_addr(27 downto 24)) is

                           when x"8" | x"9" | x"A" | x"B" | x"C" =>
                              if (unsigned(cart_addr(24 downto 2)) >= unsigned(MaxPakAddr)) then
                                 -- open bus behind the cart data, like READAFTERPAK
                                 state1x <= ANSWER;
                                 ansdata  <= std_logic_vector(unsigned(cart_addr(16 downto 1)) + 1) & cart_addr(16 downto 1);
                              else
                                 state1x     <= WAITDATA;
                                 req_pending <= '1';
                                 if (memory_remap = '1') then
                                    c2_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_GBA_Gamerom_ADDR, 27) + unsigned(cart_addr(19 downto 0)));
                                 else
                                    c2_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_GBA_Gamerom_ADDR, 27) + unsigned(cart_addr(24 downto 0)));
                                 end if;
                              end if;

                           when x"D" => -- EEPROM: always ready, reads back erased data
                              state1x <= ANSWER;
                              ansdata  <= x"00000001";

                           when x"E" | x"F" => -- Flash/SRAM: open bus, like SramFlashEnable = 0
                              state1x <= ANSWER;
                              ansdata  <= (others => '1');

                           when others =>
                              state1x <= ANSWER;
                              ansdata  <= (others => '0');

                        end case;
                     end if;
                  end if;

               when ANSWER =>
                  state1x   <= IDLE1X;
                  cart_done <= '1';
                  if (c32_1 = '0' and addr1_1 = '1') then
                     cart_readdata <= ansdata(15 downto 0) & ansdata(31 downto 16);
                  else
                     cart_readdata <= ansdata;
                  end if;

               when WAITDATA =>
                  if (req_pending = '1' and state6x = C2_DONE) then
                     req_pending <= '0';
                     state1x     <= IDLE1X;
                     cart_done   <= '1';
                     if (c32_1 = '1') then
                        cart_readdata <= readdata_6x;
                     elsif (addr1_1 = '1') then
                        cart_readdata <= readdata_6x(15 downto 0) & x"0000";
                     else
                        cart_readdata <= x"0000" & readdata_6x(15 downto 0);
                     end if;
                  end if;

            end case;
         end if;

      end if;
   end process;

   process (clk6x)
   begin
      if rising_edge(clk6x) then

         c2_sdram_ena <= '0';

         case (state6x) is

            when C2_IDLE =>
               if (reset = '0' and req_pending = '1' and clk6xIndex = 0 and cart_allow = '1') then
                  state6x      <= C2_WAIT;
                  c2_sdram_ena <= '1';
               end if;

            -- drains even during reset: the request bus stays owned (cart_busy)
            -- until the controller has consumed the pending op
            when C2_WAIT =>
               if (sdram_done32 = '1') then
                  readdata_6x <= sdram_Dout;
                  if (reset = '1') then
                     state6x <= C2_IDLE;
                  else
                     state6x <= C2_DONE;
                  end if;
               end if;

            when C2_DONE =>
               if (reset = '1' or req_pending = '0') then
                  state6x <= C2_IDLE;
               end if;

         end case;

      end if;
   end process;

end architecture;
