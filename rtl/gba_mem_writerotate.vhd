library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- write path alignment: place the written 8/16 bit value into its lane of the
-- full dword and produce the matching byte enables. Cheat engine writes bypass
-- the CPU bus and are always full dwords.

entity gba_mem_writerotate is
   port
   (
      mem_bus_Adr         : in  std_logic_vector(1 downto 0);
      mem_bus_acc         : in  std_logic_vector(1 downto 0);
      mem_bus_dout        : in  std_logic_vector(31 downto 0);
      mem_bus_ena         : in  std_logic;
      Cheats_BusWriteData : in  std_logic_vector(31 downto 0);

      rotate_writedata    : out std_logic_vector(31 downto 0);
      rotate_BE           : out std_logic_vector(3 downto 0)
   );
end entity;

architecture arch of gba_mem_writerotate is
begin

   process (all)
   begin

      rotate_writedata <= mem_bus_dout; -- default, full dword
      if (mem_bus_acc = ACCESS_8BIT) then
         case(mem_bus_Adr(1 downto 0)) is
            when "00" => rotate_writedata( 7 downto  0) <= mem_bus_dout(7 downto 0);
            when "01" => rotate_writedata(15 downto  8) <= mem_bus_dout(7 downto 0);
            when "10" => rotate_writedata(23 downto 16) <= mem_bus_dout(7 downto 0);
            when "11" => rotate_writedata(31 downto 24) <= mem_bus_dout(7 downto 0);
            when others => null;
         end case;
      elsif (mem_bus_acc = ACCESS_16BIT and mem_bus_Adr(1) = '1') then
         rotate_writedata(31 downto 16) <= mem_bus_dout(15 downto 0);
      end if;

      rotate_BE <= "1111";
      case (mem_bus_acc) is
         when ACCESS_8BIT  =>
            case (mem_bus_Adr(1 downto 0)) is
               when "00" => rotate_BE <= "0001";
               when "01" => rotate_BE <= "0010";
               when "10" => rotate_BE <= "0100";
               when "11" => rotate_BE <= "1000";
               when others => null;
            end case;
         when ACCESS_16BIT =>
            if (mem_bus_Adr(1) = '1') then
               rotate_BE <= "1100";
            else
               rotate_BE <= "0011";
            end if;
         when ACCESS_32BIT => rotate_BE <= "1111";
         when others => null;
      end case;

      if (mem_bus_ena = '0') then
         rotate_writedata <= Cheats_BusWriteData;
         rotate_BE        <= "1111";
      end if;

   end process;

end architecture;
