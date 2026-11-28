-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Plain 8N1 UART for the gba_wireless <-> HPS daemon byte stream, on the
-- framework's UART_RXD/UART_TXD pins (the MidiLink pattern: an ARM daemon
-- opens the FPGA serial device and bridges to the network). Select 2 Mbaud:
-- the HPS (100 MHz / 16 / 3) and FPGA (16.78 MHz / 8) differ by <1%, and a
-- 123-byte ACK fits the game's 15-scanline (~1.10 ms) handshake budget.
entity gba_wireless_uart is
   generic
   (
      CLKSPEED : integer := 16777216;
      BAUD     : integer := 2000000
   );
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      uart_rx   : in  std_logic;
      uart_tx   : out std_logic := '1';

      tx_data   : in  std_logic_vector(7 downto 0);
      tx_valid  : in  std_logic;
      tx_ready  : out std_logic := '1';

      rx_data   : out std_logic_vector(7 downto 0) := (others => '0');
      rx_valid  : out std_logic := '0'
   );
end entity;

architecture arch of gba_wireless_uart is

   constant DIV : integer := CLKSPEED / BAUD;
   -- Abort a TX byte that somehow never completes (4 byte times).
   constant TX_STALL_MAX : integer := 4 * 10 * DIV;

   signal tx_shift  : std_logic_vector(9 downto 0) := (others => '1');
   signal tx_cnt    : integer range 0 to 10 := 0;
   signal tx_div    : integer range 0 to 65535 := 0;
   -- '1' once tx_valid has been seen low since the last latched byte, so a
   -- producer that holds tx_valid across a byte boundary is latched once
   -- instead of re-latching the same byte for ever (tx_ready would never rise
   -- again and the whole FPGA->HPS path would be dead until reset).
   signal tx_armed  : std_logic := '1';
   signal tx_watch  : integer range 0 to TX_STALL_MAX := 0;

   signal rx_sync   : std_logic_vector(1 downto 0) := "11";
   signal rx_div    : integer range 0 to 65535 := 0;
   signal rx_cnt    : integer range 0 to 9 := 0;
   signal rx_shift  : std_logic_vector(7 downto 0) := (others => '0');
   signal rx_active : std_logic := '0';

begin

   process (clk)
   begin
      if rising_edge(clk) then

         rx_valid <= '0';
         rx_sync  <= rx_sync(0) & uart_rx;

         if (tx_valid = '0') then
            tx_armed <= '1';
         end if;

         -- transmit
         if (tx_cnt = 0) then
            tx_ready <= '1';
            tx_watch <= 0;
            if (tx_valid = '1' and tx_armed = '1') then
               tx_shift <= '1' & tx_data & '0'; -- stop, data (lsb out first), start
               tx_cnt   <= 10;
               tx_div   <= DIV - 1;
               tx_ready <= '0';
               tx_armed <= '0';
            end if;
         else
            tx_ready <= '0';
            uart_tx  <= tx_shift(0);
            if (tx_watch = TX_STALL_MAX) then
               -- bounded self-recovery: drop a byte that cannot complete
               tx_cnt   <= 0;
               tx_ready <= '1';
               uart_tx  <= '1';
               tx_watch <= 0;
            elsif (tx_div = 0) then
               tx_shift <= '1' & tx_shift(9 downto 1);
               tx_cnt   <= tx_cnt - 1;
               tx_div   <= DIV - 1;
               tx_watch <= tx_watch + 1;
            else
               tx_div <= tx_div - 1;
               tx_watch <= tx_watch + 1;
            end if;
         end if;

         -- receive
         if (rx_active = '0') then
            if (rx_sync(1) = '0') then -- start bit edge
               rx_active <= '1';
               rx_cnt    <= 0;
               rx_div    <= DIV + DIV/2 - 1; -- sample mid first data bit
            end if;
         else
            if (rx_div = 0) then
               rx_div <= DIV - 1;
               if (rx_cnt = 8) then
                  -- mid stop bit: safe to re-arm the start-edge detector
                  rx_active <= '0';
               else
                  rx_shift <= rx_sync(1) & rx_shift(7 downto 1); -- lsb first
                  if (rx_cnt = 7) then
                     rx_data  <= rx_sync(1) & rx_shift(7 downto 1);
                     rx_valid <= '1';
                  end if;
                  rx_cnt <= rx_cnt + 1;
               end if;
            else
               rx_div <= rx_div - 1;
            end if;
         end if;

         if (reset = '1') then
            tx_cnt    <= 0;
            tx_ready  <= '1';
            tx_armed  <= '1';
            tx_watch  <= 0;
            uart_tx   <= '1';
            rx_active <= '0';
         end if;

      end if;
   end process;

end architecture;
