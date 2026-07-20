library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- drop in replacement for gba_savestates when a build strips the savestate
-- machinery (e.g. the 2P profile). gba_savestates doubles as the core's reset
-- controller, so only that part is kept: register_reset on power on,
-- a savestate-bus clear plus a long core reset pulse on power off. Everything
-- savestate related is tied inactive, which lets synthesis sweep the
-- savestate shadow registers across the whole core.

entity gba_savestates_stub is
   generic
   (
      Softmap_GBA_FLASH_ADDR   : integer; -- unused, interface identical to gba_savestates
      Softmap_GBA_EEPROM_ADDR  : integer; -- unused
      is_simu                  : std_logic := '0'
   );
   port
   (
      clk                    : in     std_logic;
      gb_on                  : in     std_logic;
      reset                  : out    std_logic := '0';
      register_reset         : out    std_logic := '0';

      load_done              : out    std_logic := '0';

      increaseSSHeaderCount  : in     std_logic;
      save                   : in     std_logic;
      load                   : in     std_logic;
      savestate_address      : in     integer;
      savestate_busy         : out    std_logic;

      internal_bus_out       : buffer proc_bus_gb_type := ((others => '0'), (others => '0'), '0', '0', "00", "0000", '0');
      wired_out              : in     std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
      wired_done             : in     std_logic;

      loading_savestate      : out    std_logic := '0';
      saving_savestate       : out    std_logic := '0';
      sleep_savestate        : out    std_logic := '0';
      pause_active           : in     std_logic;

      gb_bus                 : in     proc_bus_gb_type;

      SAVE_BusAddr           : buffer std_logic_vector(27 downto 0);
      SAVE_BusRnW            : out    std_logic;
      SAVE_BusACC            : out    std_logic_vector(1 downto 0);
      SAVE_BusWriteData      : out    std_logic_vector(31 downto 0);
      SAVE_Bus_ena           : out    std_logic := '0';

      SAVE_BusReadData       : in     std_logic_vector(31 downto 0);
      SAVE_BusReadDone       : in     std_logic;

      bus_out_Din            : out    std_logic_vector(63 downto 0) := (others => '0');
      bus_out_Dout           : in     std_logic_vector(63 downto 0);
      bus_out_Adr            : buffer std_logic_vector(25 downto 0) := (others => '0');
      bus_out_rnw            : out    std_logic := '0';
      bus_out_ena            : out    std_logic := '0';
      bus_out_active         : out    std_logic := '0';
      bus_out_be             : out    std_logic_vector(7 downto 0) := (others => '0');
      bus_out_done           : in     std_logic;
      bus_out_burstcnt       : out    std_logic_vector(7 downto 0) := x"01";
      fifo_Din               : out    std_logic_vector(63 downto 0) := (others => '0');
      fifo_Wr                : out    std_logic := '0';
      fifo_NearFull          : in     std_logic := '0'
   );
end entity;

architecture arch of gba_savestates_stub is

   type tstate is
   (
      IDLE,
      RESET_CLEAR,
      RESET_CORE
   );
   signal state   : tstate := IDLE;
   signal gb_on_1 : std_logic := '0';
   signal count   : integer range 0 to 100 := 0;

begin

   loading_savestate <= '0';
   saving_savestate  <= '0';
   sleep_savestate   <= '0';
   savestate_busy    <= '0';

   SAVE_BusAddr      <= (others => '0');
   SAVE_BusRnW       <= '1';
   SAVE_BusACC       <= "00";
   SAVE_BusWriteData <= (others => '0');

   bus_out_burstcnt  <= x"01";
   fifo_Din          <= (others => '0');
   fifo_Wr           <= '0';

   internal_bus_out.Din  <= (others => '0');
   internal_bus_out.Adr  <= (others => '0');
   internal_bus_out.rnw  <= '0';
   internal_bus_out.ena  <= '0';
   internal_bus_out.acc  <= "00";
   internal_bus_out.bEna <= "0000";

   process (clk)
   begin
      if rising_edge(clk) then

         reset                <= '0';
         register_reset       <= '0';
         internal_bus_out.rst <= '0';

         gb_on_1 <= gb_on;

         if (gb_on = '1' and gb_on_1 = '0') then
            register_reset <= '1';
         end if;

         case state is

            when IDLE =>
               if (gb_on = '0' and gb_on_1 = '1') then
                  state <= RESET_CLEAR;
               end if;

            when RESET_CLEAR =>
               state                <= RESET_CORE;
               internal_bus_out.rst <= '1';
               count                <= 100;

            when RESET_CORE =>
               reset <= '1';
               if (count > 0) then
                  count <= count - 1;
               else
                  state <= IDLE;
               end if;

         end case;

      end if;
   end process;

end architecture;
