-- SPDX-License-Identifier: GPL-3.0-or-later
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
-- The default pin mapping uses USER_IO 0/1/2/5, confirmed directly by Blue
-- (the SNAC adapter's creator) -- SC=0, SO=1, SI=2, SD=5. SC/SO/SI independently
-- matched the convention already deployed on real SNAC hardware by
-- Gameboy_MiSTer's rtl/gb.v (USER_OUT[0]=SC, USER_OUT[1]=data out,
-- USER_IN[2]=data in) -- pin 2 doubles as HDMI I2S in sys_top when SW[1]
-- selects it, same tradeoff the GameBoy core already accepts. SD's pin 5 was
-- independently confirmed on real hardware first, via a raw USER_IO overlay
-- (gba_wrap.vhd's debug_link_state "P:" row) showing real activity there
-- during a real GBA's BIOS boot, before Blue's answer arrived. Pin 4 is also
-- HDMI-shared and must stay untouched. Adjust the generics to the actual
-- adapter wiring, not this file's logic.

entity gba_linkport is
   generic
   (
      PIN_SC : integer range 0 to 6 := 0;
      PIN_SO : integer range 0 to 6 := 1;
      PIN_SI : integer range 0 to 6 := 2;
      PIN_SD : integer range 0 to 6 := 5
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
