-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Adapter between gba_serial's logical link lines and the open drain USER_IO
-- pins of the MiSTer user port (GBA link cable on a SNAC style adapter).
--
-- This module knows nothing about the SIO protocol. It only
--   * maps the four link lines onto configurable USER_IO pins,
--   * drives them with the framework's open drain convention
--     (user_out bit low = pull pin low, high = release),
--   * runs every input through a 2 stage synchronizer, because the other end
--     of the cable lives in a different clock domain.
--
-- The default pin mapping uses USER_IO 0/1/3/6: pins 2, 4 and 5 are shared
-- with HDMI I2S audio in sys_top and must stay untouched. Adjust the generics
-- to the actual adapter wiring, not this file's logic.

entity gba_linkport is
   generic
   (
      PIN_SC : integer range 0 to 6 := 0;
      PIN_SO : integer range 0 to 6 := 1;
      PIN_SI : integer range 0 to 6 := 3;
      PIN_SD : integer range 0 to 6 := 6
   );
   port
   (
      clk           : in  std_logic;
      port_enable   : in  std_logic;                                   -- 0 = release all pins
      user_in       : in  std_logic_vector(6 downto 0);
      user_out      : out std_logic_vector(6 downto 0) := (others => '1');

      link_clk_out  : in  std_logic;
      link_clk_oe   : in  std_logic;
      link_clk_in   : out std_logic := '1';
      link_so_out   : in  std_logic;
      link_so_oe    : in  std_logic;
      link_si_in    : out std_logic := '1';
      link_sd_out   : in  std_logic;
      link_sd_oe    : in  std_logic;
      link_sd_in    : out std_logic := '1'
   );
end entity;

architecture arch of gba_linkport is

   signal sc_sync : std_logic_vector(1 downto 0) := (others => '1');
   signal si_sync : std_logic_vector(1 downto 0) := (others => '1');
   signal sd_sync : std_logic_vector(1 downto 0) := (others => '1');

begin

   -- SI is receive only from our side: the cable crosses SO and SI, the peer's
   -- SO arrives here. Never driven.
   process (all)
   begin
      user_out <= (others => '1');
      if (port_enable = '1') then
         if (link_clk_oe = '1' and link_clk_out = '0') then
            user_out(PIN_SC) <= '0';
         end if;
         if (link_so_oe = '1' and link_so_out = '0') then
            user_out(PIN_SO) <= '0';
         end if;
         if (link_sd_oe = '1' and link_sd_out = '0') then
            user_out(PIN_SD) <= '0';
         end if;
      end if;
   end process;

   process (clk)
   begin
      if rising_edge(clk) then
         sc_sync <= sc_sync(0) & user_in(PIN_SC);
         si_sync <= si_sync(0) & user_in(PIN_SI);
         sd_sync <= sd_sync(0) & user_in(PIN_SD);
      end if;
   end process;

   link_clk_in <= sc_sync(1);
   link_si_in  <= si_sync(1);
   link_sd_in  <= sd_sync(1);

end architecture;
