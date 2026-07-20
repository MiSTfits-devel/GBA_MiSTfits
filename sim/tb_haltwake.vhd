-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_haltwake is
   generic
   (
      WAITSTATES : integer := 0;
      WAKE_DELAY : integer := 200
   );
end entity;

architecture sim of tb_haltwake is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal bus_Adr  : std_logic_vector(31 downto 0);
   signal bus_rnw  : std_logic;
   signal bus_ena  : std_logic;
   signal bus_seq  : std_logic;
   signal bus_code : std_logic;
   signal bus_acc  : std_logic_vector(1 downto 0);
   signal bus_dout : std_logic_vector(31 downto 0);
   signal bus_din  : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done : std_logic := '0';

   signal cpu_halt  : std_logic;
   signal error_cpu : std_logic;
   signal irq_in    : std_logic := '0';
   signal unhalt    : std_logic := '0';
   signal new_halt  : std_logic;

   signal ss_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   type t_ram is array (0 to 4095) of std_logic_vector(31 downto 0);
   signal ram : t_ram := (
      16#00# / 4 => x"EA00000E",
      16#18# / 4 => x"EA000018",
      16#40# / 4 => x"E3A00000",
      16#44# / 4 => x"E10F2000",
      16#48# / 4 => x"E3C22080",
      16#4C# / 4 => x"E121F002",
      16#50# / 4 => x"E3A01301",
      16#54# / 4 => x"E3A03001",
      16#58# / 4 => x"E5C13301",
      16#5C# / 4 => x"E2800001",
      16#60# / 4 => x"E2800002",
      16#64# / 4 => x"E3A04A01",
      16#68# / 4 => x"E5840000",
      16#6C# / 4 => x"EAFFFFFE",
      16#80# / 4 => x"E3A05A02",
      16#84# / 4 => x"E3A06001",
      16#88# / 4 => x"E5856000",
      16#8C# / 4 => x"E25EF004",
      others => (others => '0'));

   signal result_seen : std_logic := '0';
   signal irq_acked   : std_logic := '0';

begin

   clk <= not clk after 5 ns;
   reset <= '0' after 100 ns;

   icpu : entity work.gba_cpu
   generic map (is_simu => '1')
   port map
   (
      clk           => clk,
      ce            => '1',
      reset         => reset,
      error_cpu     => error_cpu,
      savestate_bus => ss_bus,
      ss_wired_out  => open,
      ss_wired_done => open,
      gb_bus_Adr    => bus_Adr,
      gb_bus_rnw    => bus_rnw,
      gb_bus_ena    => bus_ena,
      gb_bus_seq    => bus_seq,
      gb_bus_code   => bus_code,
      gb_bus_acc    => bus_acc,
      gb_bus_dout   => bus_dout,
      gb_bus_din    => bus_din,
      gb_bus_done   => bus_done,
      bus_lowbits   => open,
      dma_on        => '0',
      done          => open,
      CPU_bus_idle  => open,
      PC_in_BIOS    => open,
      cpu_halt      => cpu_halt,
      lastread      => open,
      jump_out      => open,
      IRQ_in        => irq_in,
      unhalt        => unhalt,
      new_halt      => new_halt
   );

   new_halt <= '1' when (bus_ena = '1' and bus_rnw = '0' and bus_acc = "00" and bus_Adr = x"04000301") else '0';

   mem : process (clk)
      variable idx  : integer;
      variable wait_cnt : integer := 0;
      variable pending  : boolean := false;
      variable l_adr  : std_logic_vector(31 downto 0);
      variable l_rnw  : std_logic;
      variable l_acc  : std_logic_vector(1 downto 0);
      variable l_dout : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if (bus_ena = '1') then
            pending  := true;
            wait_cnt := WAITSTATES;
            l_adr  := bus_Adr;
            l_rnw  := bus_rnw;
            l_acc  := bus_acc;
            l_dout := bus_dout;
         end if;
         if (pending and wait_cnt > 0) then
            wait_cnt := wait_cnt - 1;
         elsif (pending) then
            pending := false;
            bus_done <= '1';
            idx := to_integer(unsigned(l_adr(13 downto 2)));
            if (l_adr(31 downto 14) = (17 downto 0 => '0')) then
               if (l_rnw = '1') then
                  bus_din <= ram(idx);
               elsif (l_acc = "10") then
                  ram(idx) <= l_dout;
                  if (l_adr = x"00001000") then
                     result_seen <= '1';
                     if (l_dout = x"00000003") then
                        report "HALT-WAKE TEST PASSED: result = 3" severity note;
                     else
                        report "HALT-WAKE TEST FAILED: result = 0x" & to_hstring(l_dout) &
                               " (expected 3; 2 means the instruction after halt was skipped)"
                               severity failure;
                     end if;
                  elsif (l_adr = x"00002000") then
                     irq_acked <= '1';
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

   wake : process
   begin
      wait until cpu_halt = '1';
      for i in 1 to WAKE_DELAY loop wait until rising_edge(clk); end loop;
      unhalt <= '1';
      wait until rising_edge(clk);
      irq_in <= '1';
      wait until irq_acked = '1';
      irq_in <= '0';
      unhalt <= '0';
      wait;
   end process;

   probe : process (clk)
      alias p_decode_halt  is <<signal icpu.decode_halt  : std_logic>>;
      alias p_decode_ready is <<signal icpu.decode_ready : std_logic>>;
      alias p_decode_PC    is <<signal icpu.decode_PC    : unsigned(31 downto 0)>>;
      alias p_fetch_PC     is <<signal icpu.fetch_PC     : unsigned(31 downto 0)>>;
      variable was_halt : std_logic := '0';
   begin
      if rising_edge(clk) then
         if (p_decode_halt /= was_halt) then
            report "halt=" & std_logic'image(p_decode_halt) &
                   " decode_ready=" & std_logic'image(p_decode_ready) &
                   " decode_PC=0x" & to_hstring(p_decode_PC) &
                   " fetch_PC=0x" & to_hstring(p_fetch_PC) severity note;
            was_halt := p_decode_halt;
         end if;
      end if;
   end process;

   watchdog : process
   begin
      wait until result_seen = '1' for 1 ms;
      if (result_seen = '0') then
         report "HALT-WAKE TEST TIMEOUT" severity failure;
      end if;
      stop;
   end process;

end architecture;
