-- SPDX-License-Identifier: GPL-2.0-or-later

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_colorshade_tag is
end entity;

architecture sim of tb_colorshade_tag is

   signal clk       : std_logic := '0';
   signal shade_mode : std_logic_vector(2 downto 0) := "000";

   signal in_x, out_x   : integer range 0 to 239 := 0;
   signal in_y, out_y   : integer range 0 to 159 := 0;
   signal in_data       : std_logic_vector(14 downto 0) := (others => '0');
   signal out_data      : std_logic_vector(17 downto 0);
   signal in_we, out_we : std_logic := '0';
   signal in_tag, out_tag : std_logic := '0';

   signal stop : boolean := false;

   type tag_fifo_t is array(0 to 511) of std_logic;
   signal fifo      : tag_fifo_t := (others => '0');
   signal fifo_head : integer := 0;
   signal fifo_tail : integer := 0;
   signal checked   : integer := 0;
   signal errors    : integer := 0;

begin

   clk <= not clk after 5 ns when not stop else clk;

   dut : entity work.gba_gpu_colorshade
      port map
      (
         clk            => clk,
         shade_mode     => shade_mode,
         pixel_in_x     => in_x,
         pixel_in_y     => in_y,
         pixel_in_data  => in_data,
         pixel_in_we    => in_we,
         pixel_in_tag   => in_tag,
         pixel_out_x    => out_x,
         pixel_out_y    => out_y,
         pixel_out_data => out_data,
         pixel_out_we   => out_we,
         pixel_out_tag  => out_tag
      );

   process (clk)
   begin
      if rising_edge(clk) then
         if (in_we = '1') then
            fifo(fifo_head mod 512) <= in_tag;
            fifo_head <= fifo_head + 1;
         end if;
         if (out_we = '1') then
            if (out_tag /= fifo(fifo_tail mod 512)) then
               report "TAG MISMATCH at index " & integer'image(fifo_tail) &
                      " expected " & std_logic'image(fifo(fifo_tail mod 512)) &
                      " got " & std_logic'image(out_tag)
                      severity error;
               errors <= errors + 1;
            end if;
            fifo_tail <= fifo_tail + 1;
            checked   <= checked + 1;
         end if;
      end if;
   end process;

   stim : process
      variable seed1 : positive := 42;
      variable seed2 : positive := 7;
      variable r     : real;
      procedure feed(tag : std_logic) is
      begin
         wait until rising_edge(clk);
         in_we  <= '1';
         in_tag <= tag;
         in_x   <= 0;
         in_y   <= 0;
         in_data <= (others => tag);
         wait until rising_edge(clk);
         in_we  <= '0';
      end procedure;
   begin
      wait for 20 ns;

      shade_mode <= "000";
      for i in 0 to 300 loop
         feed('0');
         feed('1');
         uniform(seed1, seed2, r);
         if (r > 0.5) then
            wait until rising_edge(clk);
         end if;
      end loop;

      wait for 200 ns;

      shade_mode <= "001";
      wait for 200 ns;
      for i in 0 to 300 loop
         feed('0');
         feed('1');
         uniform(seed1, seed2, r);
         if (r > 0.5) then
            wait until rising_edge(clk);
         end if;
      end loop;

      wait for 500 ns;

      report "checked=" & integer'image(checked) & " errors=" & integer'image(errors);
      assert errors = 0 report "TAG PASSTHROUGH BROKEN" severity failure;
      assert checked > 500 report "test didn't exercise enough pixels" severity failure;
      report "PASS";
      stop <= true;
      wait;
   end process;

end architecture;
