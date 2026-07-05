library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- cheat engine read path: a small side channel that reads EWRAM/IWRAM through
-- the second port of their RAMs while the main memory bus is idle. Completely
-- independent of the main memory state machine.

entity gba_mem_cheatread is
   port
   (
      clk                : in  std_logic;
      mem_bus_ena        : in  std_logic;
      Cheats_Bus_ena     : in  std_logic;
      Cheats_BusAddr     : in  std_logic_vector(27 downto 0);
      largeram_DataOut   : in  std_logic_vector(31 downto 0);
      smallram_DataOut   : in  std_logic_vector(31 downto 0);

      Cheats_BusReadData : out std_logic_vector(31 downto 0) := (others => '0');
      Cheats_Bus_done    : out std_logic := '0'
   );
end entity;

architecture arch of gba_mem_cheatread is

   type treadStateCheats is
   (
      READSTATECHEATS_IDLE,
      READSTATECHEATS_EWRAM,
      READSTATECHEATS_IRAM
   );
   signal readStateCheats : treadStateCheats := READSTATECHEATS_IDLE;

begin

   process (clk)
   begin
      if rising_edge(clk) then

         Cheats_Bus_done <= '0';
         case readStateCheats is
            when READSTATECHEATS_IDLE =>
               if (mem_bus_ena = '0' and Cheats_Bus_ena = '1') then
                  case (Cheats_BusAddr(27 downto 24)) is

                     when x"2" =>
                        readStateCheats    <= READSTATECHEATS_EWRAM;

                     when x"3" =>
                        readStateCheats    <= READSTATECHEATS_IRAM;

                     when others => null;

                  end case;
               end if;

            when READSTATECHEATS_EWRAM =>
               readStateCheats    <= READSTATECHEATS_IDLE;
               Cheats_BusReadData <= largeram_DataOut;
               Cheats_Bus_done    <= '1';

            when READSTATECHEATS_IRAM =>
               readStateCheats    <= READSTATECHEATS_IDLE;
               Cheats_BusReadData <= smallram_DataOut;
               Cheats_Bus_done    <= '1';

         end case;

      end if;
   end process;

end architecture;
