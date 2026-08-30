-- SPDX-License-Identifier: GPL-3.0-or-later
-- Regression for the production gba_wireless -> gba_wireless_uart ready/valid seam.
-- A GPIO ping must serialize exactly one event frame: 04 00 00.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_wireless_uart_frame is
end entity;

architecture sim of tb_wireless_uart_frame is
   constant CLKSPEED  : integer := 16777216;
   constant BAUD      : integer := 921600;
   constant DIV       : integer := CLKSPEED / BAUD;
   constant CLK_PERIOD: time := 1 sec / CLKSPEED;
   constant BIT_TIME  : time := DIV * CLK_PERIOD;

   signal clk          : std_logic := '0';
   signal reset        : std_logic := '1';
   signal sd_in        : std_logic := '0';
   signal uart_tx      : std_logic;
   signal uart_rx      : std_logic := '1';

   signal htx_data     : std_logic_vector(7 downto 0);
   signal htx_valid    : std_logic;
   signal htx_ready    : std_logic;
   signal hrx_data     : std_logic_vector(7 downto 0);
   signal hrx_valid    : std_logic;

   signal link_sc_out  : std_logic;
   signal link_sc_oe   : std_logic;
   signal link_so_out  : std_logic;
   signal link_so_oe   : std_logic;
   signal debug_state  : std_logic_vector(7 downto 0);

   procedure recv_uart_byte(
      signal serial : in std_logic;
      variable value: out std_logic_vector(7 downto 0);
      constant label_text: in string) is
   begin
      wait until falling_edge(serial) for 200 us;
      assert serial = '0'
         report "UART event frame missing " & label_text severity failure;
      wait for BIT_TIME + BIT_TIME / 2;
      for i in 0 to 7 loop
         value(i) := serial;
         wait for BIT_TIME;
      end loop;
      assert serial = '1'
         report "UART stop bit low while receiving " & label_text severity failure;
      wait for BIT_TIME / 2;
   end procedure;
begin
   clk <= not clk after CLK_PERIOD / 2;

   dut : entity work.gba_wireless
      generic map (CLKSPEED => CLKSPEED)
      port map (
         clk          => clk,
         reset        => reset,
         wireless_ena => '1',
         link_sc_in   => '1',
         link_sc_out  => link_sc_out,
         link_sc_oe   => link_sc_oe,
         link_si_in   => '0',
         link_so_out  => link_so_out,
         link_so_oe   => link_so_oe,
         link_sd_in   => sd_in,
         hps_tx_data  => htx_data,
         hps_tx_valid => htx_valid,
         hps_tx_ready => htx_ready,
         hps_rx_data  => hrx_data,
         hps_rx_valid => hrx_valid,
         debug_state  => debug_state
      );

   uart : entity work.gba_wireless_uart
      generic map (CLKSPEED => CLKSPEED, BAUD => BAUD)
      port map (
         clk      => clk,
         reset    => reset,
         uart_rx  => uart_rx,
         uart_tx  => uart_tx,
         tx_data  => htx_data,
         tx_valid => htx_valid,
         tx_ready => htx_ready,
         rx_data  => hrx_data,
         rx_valid => hrx_valid
      );

   main : process
      variable b0, b1, b2            : std_logic_vector(7 downto 0);
      variable c0, c1, c2            : std_logic_vector(7 downto 0);
   begin
      wait for 20 * CLK_PERIOD;
      reset <= '0';
      wait for 20 * CLK_PERIOD;

      -- AgbRFU_SoftReset / pingAdapter shape: SD high for >0.5 ms, then low.
      sd_in <= '1';
      wait for 700 us;
      sd_in <= '0';

      recv_uart_byte(uart_tx, b0, "type byte");
      recv_uart_byte(uart_tx, b1, "event byte");
      recv_uart_byte(uart_tx, b2, "length byte");

      assert b0 = x"04" report "wrong UART frame type: " & to_hstring(b0) severity failure;
      assert b1 = x"00" report "wrong UART event id: " & to_hstring(b1) severity failure;
      assert b2 = x"00" report "wrong UART event length: " & to_hstring(b2) severity failure;

      -- Line must return to MARK and stay there before a second ping.
      wait for 500 us;
      assert uart_tx = '1'
         report "UART TX did not return to idle (mark) after the first frame"
         severity failure;

      -- Second GPIO ping must serialise a fresh 04 00 00 with no echoes.
      sd_in <= '1';
      wait for 700 us;
      sd_in <= '0';

      recv_uart_byte(uart_tx, c0, "second type byte");
      recv_uart_byte(uart_tx, c1, "second event byte");
      recv_uart_byte(uart_tx, c2, "second length byte");

      assert c0 = x"04" report "wrong second frame type: " & to_hstring(c0) severity failure;
      assert c1 = x"00" report "wrong second frame event id: " & to_hstring(c1) severity failure;
      assert c2 = x"00" report "wrong second frame event length: " & to_hstring(c2) severity failure;

      -- The line must return to MARK and STAY idle long-term and stay clean
      -- (no lingering 0x00 flood between/after frames).
      wait for 100 us;
      assert uart_tx = '1'
         report "UART TX did not return to idle (mark) after the second frame: continuous 0x00 flood"
         severity failure;
      wait for 5 ms;
      assert uart_tx = '1'
         report "UART TX is stuck driving the line low long after the frames (0x00 flood)"
         severity failure;

      report "WIRELESS UART FRAME TEST PASSED: two ping events serialized as 04 00 00 each, line returns to idle";
      std.env.stop;
      wait;
   end process;
end architecture;
