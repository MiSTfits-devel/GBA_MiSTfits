-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Plain 8N1 UART for the gba_wireless <-> HPS daemon byte stream, on the
-- framework's UART_RXD/UART_TXD pins (the MidiLink pattern: an ARM daemon
-- opens the FPGA serial device and bridges to the network). 921600 baud
-- moves a worst-case 95 byte RFU packet in ~1 ms against the protocol's
-- 64.8 ms budget.
entity gba_wireless_uart is
   generic
   (
      CLKSPEED : integer := 16777216;
      BAUD     : integer := 921600
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

   constant DIV : integer := CLKSPEED / BAUD; -- ~18 at 16.78MHz/921600

   signal tx_shift  : std_logic_vector(9 downto 0) := (others => '1');
   signal tx_cnt    : integer range 0 to 10 := 0;
   signal tx_div    : integer range 0 to 65535 := 0;

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

         -- transmit
         if (tx_cnt = 0) then
            tx_ready <= '1';
            if (tx_valid = '1') then
               tx_shift <= '1' & tx_data & '0'; -- stop, data (lsb out first), start
               tx_cnt   <= 10;
               tx_div   <= DIV - 1;
               tx_ready <= '0';
            end if;
         else
            tx_ready <= '0';
            uart_tx  <= tx_shift(0);
            if (tx_div = 0) then
               tx_shift <= '1' & tx_shift(9 downto 1);
               tx_cnt   <= tx_cnt - 1;
               tx_div   <= DIV - 1;
            else
               tx_div <= tx_div - 1;
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
            uart_tx   <= '1';
            rx_active <= '0';
         end if;

      end if;
   end process;

end architecture;
