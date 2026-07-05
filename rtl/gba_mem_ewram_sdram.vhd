-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- EWRAM in SDRAM (2P profile): request channel between gba_memorymux and the
-- SDRAM controller. Follows the cart_ena/cart_done handshake idiom of
-- memorymux_extern: the request is latched on clk1x, issued on clk6x at
-- index 0 when the extern scheduler is idle (ewram_allow) and runs as a
-- single 32bit SDRAM op - a burst read or a byte enabled double 16bit write.
-- ewram_active must gate the extern cache fill and refresh scheduling so no
-- second SDRAM op is launched while this one owns the shared request bus.
entity gba_mem_ewram_sdram is
   generic
   (
      Softmap_GBA_EWRAM_ADDR : integer -- count: 262144  -- 256 Kbyte Data for EWRAM
   );
   port
   (
      clk1x           : in  std_logic;
      clk6x           : in  std_logic;
      clk6xIndex      : in  unsigned(2 downto 0);
      reset           : in  std_logic;

      ewram_ena       : in  std_logic;
      ewram_rnw       : in  std_logic;
      ewram_addr      : in  std_logic_vector(15 downto 0); -- dword address inside the 256 Kbyte
      ewram_be        : in  std_logic_vector(3 downto 0);
      ewram_writedata : in  std_logic_vector(31 downto 0);
      ewram_done      : out std_logic := '0';
      ewram_readdata  : out std_logic_vector(31 downto 0) := (others => '0');

      ewram_allow     : in  std_logic; -- extern scheduler idle, may start at clk6xIndex 0
      ewram_active    : out std_logic; -- request pending or in flight -> extern must not launch
      ewram_busy      : out std_logic; -- SDRAM op in flight -> owns the request bus

      ew_sdram_ena    : out std_logic := '0';
      ew_sdram_rnw    : out std_logic := '0';
      ew_sdram_Adr    : out std_logic_vector(26 downto 0) := (others => '0');
      ew_sdram_Din    : out std_logic_vector(31 downto 0) := (others => '0');
      ew_sdram_be     : out std_logic_vector(3 downto 0) := (others => '1');
      sdram_Dout      : in  std_logic_vector(31 downto 0);
      sdram_done32    : in  std_logic
   );
end entity;

architecture arch of gba_mem_ewram_sdram is

   type tState6X is
   (
      EW_IDLE,
      EW_WAIT,
      EW_DONE
   );
   signal state6x : tState6X := EW_IDLE;

   signal req_pending : std_logic := '0';
   signal readdata_6x : std_logic_vector(31 downto 0) := (others => '0');

begin

   ewram_active   <= req_pending;
   ewram_busy     <= '1' when (state6x = EW_WAIT) else '0';

   -- done/readdata are re-registered on clk1x before export, same as
   -- cart_done/cart_readdata in memorymux_extern: the 6x->1x crossing must be
   -- a plain register capture. Exporting readdata_6x combinationally put the
   -- whole readmux->CPU->extern cone into the single 9.9ns clk6x->clk1x
   -- transfer window and failed setup by ~1.5ns. Costs one clk1x cycle of
   -- EWRAM latency, which only exists in the 2P profile.
   process (clk1x)
   begin
      if rising_edge(clk1x) then

         ewram_done <= '0';

         if (reset = '1') then
            req_pending <= '0';
         elsif (ewram_ena = '1') then
            req_pending  <= '1';
            ew_sdram_rnw <= ewram_rnw;
            ew_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_GBA_EWRAM_ADDR, 27) + (unsigned(ewram_addr) & "00"));
            ew_sdram_Din <= ewram_writedata;
            ew_sdram_be  <= ewram_be;
         elsif (req_pending = '1' and state6x = EW_DONE) then
            req_pending    <= '0';
            ewram_done     <= '1';
            ewram_readdata <= readdata_6x;
         end if;

      end if;
   end process;

   process (clk6x)
   begin
      if rising_edge(clk6x) then

         ew_sdram_ena <= '0';

         case (state6x) is

            when EW_IDLE =>
               if (reset = '0' and req_pending = '1' and clk6xIndex = 0 and ewram_allow = '1') then
                  state6x      <= EW_WAIT;
                  ew_sdram_ena <= '1';
               end if;

            -- drains even during reset: the request bus stays owned (ewram_busy)
            -- until the controller has consumed addr/rnw/din of the pending op
            when EW_WAIT =>
               if (sdram_done32 = '1') then
                  readdata_6x <= sdram_Dout;
                  if (reset = '1') then
                     state6x <= EW_IDLE;
                  else
                     state6x <= EW_DONE;
                  end if;
               end if;

            when EW_DONE =>
               if (reset = '1' or req_pending = '0') then
                  state6x <= EW_IDLE;
               end if;

         end case;

      end if;
   end process;

end architecture;
