-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_rorshift is
end entity;

architecture sim of tb_rorshift is

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

   signal ss_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   type t_ram is array (0 to 4095) of std_logic_vector(31 downto 0);
   signal ram : t_ram := (
      16#00# / 4 => x"EA00000E",
      16#40# / 4 => x"E3A00000",
      16#44# / 4 => x"E3A01102",
      16#48# / 4 => x"E3811001",
      16#4C# / 4 => x"E3A02040",
      16#50# / 4 => x"E2900000",
      16#54# / 4 => x"E1B03271",
      16#58# / 4 => x"E3A04000",
      16#5C# / 4 => x"E2A44000",
      16#60# / 4 => x"E3A02F48",
      16#64# / 4 => x"E2900000",
      16#68# / 4 => x"E1B05271",
      16#6C# / 4 => x"E3A06000",
      16#70# / 4 => x"E2A66000",
      16#74# / 4 => x"E3A02C01",
      16#78# / 4 => x"E2507000",
      16#7C# / 4 => x"E1B08271",
      16#80# / 4 => x"E3A07000",
      16#84# / 4 => x"E2A77000",
      16#88# / 4 => x"E3A02020",
      16#8C# / 4 => x"E2900000",
      16#90# / 4 => x"E1B09271",
      16#94# / 4 => x"E3A0A000",
      16#98# / 4 => x"E2AAA000",
      16#9C# / 4 => x"E3A0BA01",
      16#A0# / 4 => x"E48B3004",
      16#A4# / 4 => x"E48B4004",
      16#A8# / 4 => x"E48B5004",
      16#AC# / 4 => x"E48B6004",
      16#B0# / 4 => x"E48B8004",
      16#B4# / 4 => x"E48B7004",
      16#B8# / 4 => x"E48B9004",
      16#BC# / 4 => x"E48BA004",
      16#C0# / 4 => x"E3A0CA02",
      16#C4# / 4 => x"E58CC000",
      16#C8# / 4 => x"EAFFFFFE",
      others => (others => '0'));

   type t_exp is array (0 to 7) of std_logic_vector(31 downto 0);
   constant expected : t_exp := (
      x"80000001", x"00000001",
      x"80000001", x"00000001",
      x"80000001", x"00000001",
      x"80000001", x"00000001");

   signal done_seen : std_logic := '0';

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
      error_cpu     => open,
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
      cpu_halt      => open,
      lastread      => open,
      jump_out      => open,
      IRQ_in        => '0',
      unhalt        => '0',
      new_halt      => '0'
   );

   mem : process (clk)
      variable idx    : integer;
      variable errors : integer;
   begin
      if rising_edge(clk) then
         bus_done <= '0';
         if (bus_ena = '1') then
            bus_done <= '1';
            idx := to_integer(unsigned(bus_Adr(13 downto 2)));
            if (bus_Adr(31 downto 14) = (17 downto 0 => '0')) then
               if (bus_rnw = '1') then
                  bus_din <= ram(idx);
               elsif (bus_acc = "10") then
                  ram(idx) <= bus_dout;
                  if (bus_Adr = x"00002000") then
                     errors := 0;
                     for i in 0 to 7 loop
                        if (ram(16#1000# / 4 + i) /= expected(i)) then
                           report "mismatch at 0x" & to_hstring(to_unsigned(16#1000# + 4 * i, 32)) &
                                  ": got 0x" & to_hstring(ram(16#1000# / 4 + i)) &
                                  " expected 0x" & to_hstring(expected(i)) severity error;
                           errors := errors + 1;
                        end if;
                     end loop;
                     done_seen <= '1';
                     if (errors = 0) then
                        report "ROR-SHIFT TEST PASSED: all 8 values match" severity note;
                     else
                        report "ROR-SHIFT TEST FAILED: " & integer'image(errors) & " mismatches" severity failure;
                     end if;
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

   watchdog : process
   begin
      wait until done_seen = '1' for 100 us;
      if (done_seen = '0') then
         report "ROR-SHIFT TEST TIMEOUT" severity failure;
      end if;
      stop;
   end process;

end architecture;
