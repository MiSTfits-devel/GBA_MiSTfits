library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- clock enable / pause control: gates the whole core through ce. Pausing only
-- happens on an instruction boundary with no DMA running, and a short settle
-- time is enforced before pause_active is reported. KeyPause requests are
-- jittered with an LFSR so repeated pausing doesn't beat against the frame.

entity gba_ctrl_pause is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk1x               : in  std_logic;
      gbaon               : in  std_logic;
      savestate_loadstate : in  std_logic;
      pause               : in  std_logic;
      allowUnpause        : in  std_logic;
      sleep_savestate     : in  std_logic;
      sleep_rewind        : in  std_logic;
      dma_on_next         : in  std_logic;
      cpu_jump            : in  std_logic;
      KeyPause            : in  std_logic;

      ce                  : out std_logic := '0';
      pause_active        : out std_logic := '0'
   );
end entity;

architecture arch of gba_ctrl_pause is

   type tState is
   (
      PAUSING,
      RUNNING,
      WAITPAUSE,
      WAITUNPAUSE
   );
   signal state : tState := PAUSING;

   signal pauseCnt : unsigned(8 downto 0);
   signal lfsr     : unsigned(22 downto 0) := (others => '0');

begin

   process (clk1x)
   begin
      if rising_edge(clk1x) then

         ce            <= '0';
         pause_active  <= '0';

         lfsr(22 downto 1) <= lfsr(21 downto 0);
         lfsr(0) <= not(lfsr(22) xor lfsr(18));

         if (gbaon = '0' or savestate_loadstate = '1') then
            state    <= PAUSING;
            pauseCnt <= (others => '0');
         else

            case (state) is

               when PAUSING =>
                  if (pauseCnt(8) = '0') then
                     pauseCnt <= pauseCnt + 1;
                  else
                     pause_active <= '1';
                  end if;
                  if (pauseCnt(8 downto 7) > 0 and pause = '0' and sleep_savestate = '0' and sleep_rewind = '0') then
                     state <= WAITUNPAUSE;
                  end if;
                  if (dma_on_next = '1') then -- should never happen here, save exit
                     state <= RUNNING;
                  end if;

               when RUNNING =>
                  ce    <= '1';
                  if (pause = '1' or sleep_savestate = '1' or sleep_rewind = '1' or (KeyPause = '1' and lfsr(5 downto 0) = 0)) then
                     state <= WAITPAUSE;
                  end if;

               when WAITPAUSE =>
                  ce    <= '1';
                  if (dma_on_next = '0' and cpu_jump = '1') then
                     state    <= PAUSING;
                     ce       <= '0';
                     pauseCnt <= (others => '0');
                  end if;

               when WAITUNPAUSE =>
                  if (allowUnpause = '1' or is_simu = '1') then
                     state <= RUNNING;
                  end if;

            end case;

         end if;

      end if;
   end process;

end architecture;
