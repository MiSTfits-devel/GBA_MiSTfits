library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- read path alignment: rotate the raw dword from the selected memory region
-- into the lane the CPU asked for, using the access size and address bits
-- saved when the request was issued. A read completed while ce was stopped is
-- replayed from the latched value instead.

entity gba_mem_readrotate is
   port
   (
      acc_save          : in  std_logic_vector(1 downto 0);
      return_rotate     : in  std_logic_vector(1 downto 0);
      mem_bus_din_unrot : in  std_logic_vector(31 downto 0);
      ce_latched_done   : in  std_logic;
      ce_latched_data   : in  std_logic_vector(31 downto 0);
      saving_savestate  : in  std_logic;

      mem_bus_din       : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of gba_mem_readrotate is
begin

   process (all)
   begin

      mem_bus_din <= (others => '0');

      if (acc_save = ACCESS_8BIT) then
         case (return_rotate) is
            when "00" => mem_bus_din <= x"000000" & mem_bus_din_unrot(7 downto 0);
            when "01" => mem_bus_din <= x"000000" & mem_bus_din_unrot(15 downto 8);
            when "10" => mem_bus_din <= x"000000" & mem_bus_din_unrot(23 downto 16);
            when "11" => mem_bus_din <= x"000000" & mem_bus_din_unrot(31 downto 24);
            when others => null;
         end case;
      elsif (acc_save = ACCESS_16BIT) then
         case (return_rotate) is
            when "00" => mem_bus_din <= x"0000" & mem_bus_din_unrot(15 downto 0);
            when "01" => mem_bus_din <= mem_bus_din_unrot(7 downto 0) & x"0000" & mem_bus_din_unrot(15 downto 8);
            when "10" => mem_bus_din <= x"0000" & mem_bus_din_unrot(31 downto 16);
            when "11" => mem_bus_din <= mem_bus_din_unrot(23 downto 16) & x"0000" & mem_bus_din_unrot(31 downto 24);
            when others => null;
         end case;
      else
         case (return_rotate) is
            when "00" => mem_bus_din <= mem_bus_din_unrot;
            when "01" => mem_bus_din <= mem_bus_din_unrot(7 downto 0) & mem_bus_din_unrot(31 downto 8);
            when "10" => mem_bus_din <= mem_bus_din_unrot(15 downto 0) & mem_bus_din_unrot(31 downto 16);
            when "11" => mem_bus_din <= mem_bus_din_unrot(23 downto 0) & mem_bus_din_unrot(31 downto 24);
            when others => null;
         end case;
      end if;

      if (ce_latched_done = '1' and saving_savestate = '0') then
         mem_bus_din <= ce_latched_data;
      end if;

   end process;

end architecture;
