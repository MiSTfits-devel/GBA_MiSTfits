library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library mem;

entity videoout160 is
   generic
   (
      dual                    : std_logic := '0' -- 2P profile: 480x160 side by side, pixel clock doubled within the same line time
   );
   port
   (
      clk1x                   : in  std_logic;
      clk3x                   : in  std_logic;

      blend                   : in  std_logic;
      borderOn                : in  std_logic;
      videoHshift             : in  signed(3 downto 0);
      videoVshift             : in  signed(2 downto 0);

      pixel_x                 : in  integer range 0 to 239;
      pixel_y                 : in  integer range 0 to 159;
      pixel_we                : in  std_logic;
      vblank_trigger          : in  std_logic;

      -- core 2 (dual only): frame pacing stays on core 1, these only step core 2's buffer flip
      pixel2_x                : in  integer range 0 to 239 := 0;
      pixel2_y                : in  integer range 0 to 159 := 0;
      pixel2_we               : in  std_logic := '0';

      -- 2P profile view options (dual only, ignored otherwise): both cores
      -- always keep rendering into their own half of the line buffer, this
      -- only changes what gets scanned out. 0 = both side by side (default),
      -- 1 = player 1 only (pixel-doubled to fill the line), 2 = player 2 only
      display_select          : in  std_logic_vector(1 downto 0) := "00";
      separator_on            : in  std_logic := '0'; -- thin line at the x=239/240 seam, "both" mode only

      nextFrame_out           : out std_logic_vector(1 downto 0);
      nextFrame2_out          : out std_logic_vector(1 downto 0);

      inPause                 : in  std_logic;
      requestPause            : out std_logic := '0';
      allowUnpause            : out std_logic := '0';

      ddr3_request            : out std_logic := '0';
      ddr3_address            : out unsigned(27 downto 0):= (others => '0');
      ddr3_burstcnt           : out unsigned(9 downto 0):= (others => '0');
      ddr3_ready              : in  std_logic;
      ddr3_done               : in  std_logic;
      ddr3_data               : in  std_logic_vector(63 downto 0):= (others => '0');

      videoout_hsync          : out std_logic := '0';
      videoout_vsync          : out std_logic := '0';
      videoout_hblank         : out std_logic := '0';
      videoout_vblank         : out std_logic := '0';
      videoout_ce             : out std_logic;
      videoout_interlace      : out std_logic;
      videoout_r              : out unsigned(7 downto 0);
      videoout_g              : out unsigned(7 downto 0);
      videoout_b              : out unsigned(7 downto 0)
   );
end entity;

architecture arch of videoout160 is

   function sel(cond : std_logic; a : integer; b : integer) return integer is
   begin
      if (cond = '1') then return a; end if;
      return b;
   end function;

   -- dual doubles the active width within the unchanged line time: ce = clk3x/4
   -- instead of clk3x/8, all horizontal positions scale x2, vertical unchanged
   constant HACT      : integer := sel(dual, 480, 240);
   constant HTOTAL    : integer := sel(dual, 797, 398);
   constant HSYNC_ST  : integer := sel(dual, 586, 293);
   constant HSYNC_LEN : integer := sel(dual,  64,  32);
   constant LINE_AW_A : integer := sel(dual,   8,   7); -- 64bit write side: 2 lines x 60/120 words
   constant LINE_AW_B : integer := sel(dual,  10,   9); -- 16bit read side:  2 lines x 240/480 pixels

   -- timing
   signal div              : unsigned(2 downto 0) := (others => '0');
   signal x                : unsigned(9 downto 0) := (others => '0');
   signal y                : unsigned(8 downto 0) := (others => '0');

   signal lineInNew        : std_logic := '0';
   signal lineInNew_1      : std_logic := '0';
   signal vpos             : unsigned(7 downto 0) := (others => '0');

   signal borderEff        : std_logic;

   type tPauseState is
   (
      IDLE,
      WAIT_PAUSING,
      WAIT_LINES
   );
   signal pauseState       : tPauseState := IDLE;
   signal vsyncwaitcnt     : unsigned(8 downto 0) := (others => '0');

   -- output
   signal lineWriteAddr    : unsigned(7 downto 0) := (others => '0');
   signal lineReadAddr     : unsigned(9 downto 0) := (others => '0');
   signal read_data        : std_logic_vector(15 downto 0);
   signal read_data2       : std_logic_vector(15 downto 0);
   signal secondFrame      : std_logic := '0';
   signal borderReadOn     : std_logic := '0';

   signal blineWriteAddr   : unsigned(8 downto 0) := (others => '0');
   signal blineReadAddr    : unsigned(9 downto 0) := (others => '0');
   signal bread_data       : std_logic_vector(31 downto 0);

   -- single-player scanout (dual only): each source column is read twice to
   -- fill the 480 wide line at the unchanged pixel clock, so the read
   -- address only advances on every other output column
   signal singleDoubleTick : std_logic := '0';

   signal nextFrame        : unsigned(1 downto 0) := (others => '0');
   signal currFrame        : unsigned(1 downto 0) := (others => '0');
   signal prevFrame        : unsigned(1 downto 0) := (others => '0');

   -- core 2 buffer flip (dual only): free running counters stepped by core 2's
   -- last pixel, latched once per scanout frame so the right half never
   -- switches buffers mid frame. 4 buffers absorb the slow EWRAM skew between
   -- the cores, worst case is the right half lagging one frame.
   signal fetchPhase       : unsigned(1 downto 0) := (others => '0');
   signal nextFrame2       : unsigned(1 downto 0) := (others => '0');
   signal currFrame2       : unsigned(1 downto 0) := (others => '0');
   signal prevFrame2       : unsigned(1 downto 0) := (others => '0');
   signal currFrame2_scan  : unsigned(1 downto 0) := (others => '0');
   signal prevFrame2_scan  : unsigned(1 downto 0) := (others => '0');

   signal pixelData_R      : std_logic_vector(7 downto 0);
   signal pixelData_G      : std_logic_vector(7 downto 0);
   signal pixelData_B      : std_logic_vector(7 downto 0);

   signal pixelData_Add_R  : std_logic_vector(5 downto 0);
   signal pixelData_Add_G  : std_logic_vector(5 downto 0);
   signal pixelData_Add_B  : std_logic_vector(5 downto 0);

begin

   -- dual has no border framebuffer (it would need a 960 wide image)
   borderEff <= borderOn and (not dual);

   ilineram: entity mem.dpram_dif
   generic map
   (
      addr_width_a  => LINE_AW_A,
      data_width_a  => 64,
      addr_width_b  => LINE_AW_B,
      data_width_b  => 16
   )
   port map
   (
      clock_a     => clk1x,
      address_a   => std_logic_vector(lineWriteAddr(LINE_AW_A - 1 downto 0)),
      data_a      => ddr3_data,
      wren_a      => ddr3_ready and (not secondFrame) and (not borderReadOn),

      clock_b     => clk3x,
      address_b   => std_logic_vector(lineReadAddr(LINE_AW_B - 1 downto 0)),
      data_b      => 16x"0",
      wren_b      => '0',
      q_b         => read_data
   );

   ilineram2: entity mem.dpram_dif
   generic map
   (
      addr_width_a  => LINE_AW_A,
      data_width_a  => 64,
      addr_width_b  => LINE_AW_B,
      data_width_b  => 16
   )
   port map
   (
      clock_a     => clk1x,
      address_a   => std_logic_vector(lineWriteAddr(LINE_AW_A - 1 downto 0)),
      data_a      => ddr3_data,
      wren_a      => ddr3_ready and secondFrame and (not borderReadOn),

      clock_b     => clk3x,
      address_b   => std_logic_vector(lineReadAddr(LINE_AW_B - 1 downto 0)),
      data_b      => 16x"0",
      wren_b      => '0',
      q_b         => read_data2
   );

   iborderlineram: entity mem.dpram_dif
   generic map
   (
      addr_width_a  => 9,
      data_width_a  => 64,
      addr_width_b  => 10,
      data_width_b  => 32
   )
   port map
   (
      clock_a     => clk1x,
      address_a   => std_logic_vector(blineWriteAddr),
      data_a      => ddr3_data,
      wren_a      => ddr3_ready and borderReadOn,

      clock_b     => clk3x,
      address_b   => std_logic_vector(blineReadAddr),
      data_b      => 32x"0",
      wren_b      => '0',
      q_b         => bread_data
   );

   nextFrame_out  <= std_logic_vector(nextFrame);
   nextFrame2_out <= std_logic_vector(nextFrame2);

   videoout_interlace <= '0';

   pixelData_Add_R <= std_logic_vector(unsigned('0' & read_data(14 downto 10)) + unsigned('0' & read_data2(14 downto 10)));
   pixelData_Add_G <= std_logic_vector(unsigned('0' & read_data(9  downto  5)) + unsigned('0' & read_data2(9  downto  5)));
   pixelData_Add_B <= std_logic_vector(unsigned('0' & read_data(4  downto  0)) + unsigned('0' & read_data2(4  downto  0)));

   pixelData_R <= pixelData_Add_R & pixelData_Add_R(5 downto 4) when (blend = '1') else read_data(14 downto 10) & read_data(14 downto 12);
   pixelData_G <= pixelData_Add_G & pixelData_Add_G(5 downto 4) when (blend = '1') else read_data(9  downto  5) & read_data(9  downto  7);
   pixelData_B <= pixelData_Add_B & pixelData_Add_B(5 downto 4) when (blend = '1') else read_data(4  downto  0) & read_data(4  downto  2);

   process (clk1x)
   begin
      if rising_edge(clk1x) then

         ddr3_request <= '0';

         if (ddr3_ready = '1') then
            lineWriteAddr  <= lineWriteAddr + 1;
            blineWriteAddr <= blineWriteAddr + 1;
         end if;

         lineInNew_1 <= lineInNew;

         if (dual = '1') then

            -- per line: core 1 into words 0..59, core 2 into words 60..119,
            -- with blend the same again from the previous frames into lineram2
            if (lineInNew /= lineInNew_1 and y < 61) then
               currFrame2_scan <= currFrame2;
               prevFrame2_scan <= prevFrame2;
            end if;

            if (y >= 61 and y < 62+160) then
               if (lineInNew /= lineInNew_1) then
                  ddr3_request  <= '1';
                  ddr3_address  <= '1' & 8x"0" & currFrame & vpos & 6x"0" & "000";
                  ddr3_burstcnt <= 10x"3C"; -- 60 * 64bit = 240 * 16 bit
                  lineWriteAddr <= vpos(0) & 7x"0";
                  secondFrame   <= '0';
                  fetchPhase    <= "00";
               elsif (ddr3_done = '1') then
                  case (fetchPhase) is
                     when "00" =>
                        ddr3_request  <= '1';
                        ddr3_address  <= '1' & 7x"0" & '1' & currFrame2_scan & vpos & 6x"0" & "000";
                        ddr3_burstcnt <= 10x"3C";
                        lineWriteAddr <= vpos(0) & to_unsigned(60, 7);
                        fetchPhase    <= "01";
                     when "01" =>
                        if (blend = '1') then
                           ddr3_request  <= '1';
                           ddr3_address  <= '1' & 8x"0" & prevFrame & vpos & 6x"0" & "000";
                           ddr3_burstcnt <= 10x"3C";
                           lineWriteAddr <= vpos(0) & 7x"0";
                           secondFrame   <= '1';
                           fetchPhase    <= "10";
                        end if;
                     when "10" =>
                        ddr3_request  <= '1';
                        ddr3_address  <= '1' & 7x"0" & '1' & prevFrame2_scan & vpos & 6x"0" & "000";
                        ddr3_burstcnt <= 10x"3C";
                        lineWriteAddr <= vpos(0) & to_unsigned(60, 7);
                        fetchPhase    <= "11";
                     when others => null;
                  end case;
               end if;
            end if;

            if (pixel2_we = '1' and pixel2_x = 239 and pixel2_y = 159) then
               nextFrame2 <= nextFrame2 + 1;
               currFrame2 <= nextFrame2;
               prevFrame2 <= currFrame2;
            end if;

         else

            if (lineInNew /= lineInNew_1 and borderEff = '1') then
               borderReadOn   <= '1';
               ddr3_request   <= '1';
               ddr3_address   <= x"D" & to_unsigned(1280 * to_integer(y - 21), 24);
               ddr3_burstcnt <= 10x"A0"; -- 160 * 64bit = 320 * 32 bit
               blineWriteAddr <= vpos(0) & 8x"0";
            elsif (y >= 61 and y < 62+160) then
               if ((lineInNew /= lineInNew_1 and borderEff = '0') or (ddr3_done = '1' and borderReadOn = '1')) then
                  borderReadOn <= '0';
                  ddr3_request  <= '1';
                  ddr3_address  <= '1' & "00000000" & currFrame & vpos & 6x"0" & "000";
                  ddr3_burstcnt <= 10x"3C"; -- 60 * 64bit = 240 * 16 bit
                  lineWriteAddr <= '0' & vpos(0) & 6x"0";
                  secondFrame   <= '0';
               elsif (ddr3_done = '1' and secondFrame = '0' and blend = '1' ) then
                  secondFrame                <= '1';
                  ddr3_request               <= '1';
                  ddr3_address(18 downto 17) <= prevFrame;
                  lineWriteAddr(5 downto 0)  <= (others => '0');
               end if;
            end if;

         end if;

         if (pixel_we = '1' and pixel_x = 239 and pixel_y = 159) then
            nextFrame <= nextFrame + 1;
            currFrame <= nextFrame;
            prevFrame <= currFrame;
         end if;

      end if;
   end process;

   process (clk3x)
   begin
      if rising_edge(clk3x) then

         videoout_ce <= '0';

         div <= div + 1;

         if (div = 0 or (dual = '1' and div = 4)) then
            videoout_ce <= '1';

            if (x < HACT and y >= 62 and y < 222) then
               if (dual = '1' and separator_on = '1' and display_select = "00" and (x = 239 or x = 240)) then
                  -- 2P separator: neutral 50% gray, RGB555 0x3DEF widened to 8 bits/channel
                  videoout_r      <= "01111011";
                  videoout_g      <= "01111011";
                  videoout_b      <= "01111011";
               else
                  videoout_r      <= unsigned(pixelData_R);
                  videoout_g      <= unsigned(pixelData_G);
                  videoout_b      <= unsigned(pixelData_B);
               end if;
            else
               videoout_r      <= unsigned(bread_data( 7 downto  0));
               videoout_g      <= unsigned(bread_data(15 downto  8));
               videoout_b      <= unsigned(bread_data(23 downto 16));
            end if;

            if (borderEff = '1') then
               if (x = 280)             then videoout_hblank <= '1'; end if;
               if (x = 359)             then videoout_hblank <= '0'; end if;
               if (y  = 21 and x = 359) then videoout_vblank <= '0'; end if;
               if (y >= 62+199)         then videoout_vblank <= '1'; end if;
            else
               if (x = HACT)    then videoout_hblank <= '1'; end if;
               if (x =    0)    then videoout_hblank <= '0'; end if;
               if (y  = 62)     then videoout_vblank <= '0'; end if;
               if (y >= 62+160) then videoout_vblank <= '1'; end if;
            end if;

            if(x = HSYNC_ST + to_integer(videoHshift)) then
               videoout_hsync <= '1';
               if (videoVshift < -1) then
                  if (y = 265 + to_integer(videoVshift)) then videoout_vsync <= '1'; end if;
               else
                  if (y = 1 + to_integer(videoVshift)) then videoout_vsync <= '1'; end if;
               end if;
               if (y = 4 + to_integer(videoVshift)) then videoout_vsync <= '0'; end if;
            end if;

            if(x = HSYNC_ST + HSYNC_LEN + to_integer(videoHshift)) then videoout_hsync <= '0'; end if;

            if (x = 0) then
               if (y >= 21 and y < 62+199) then
                  lineInNew <= not lineInNew;
                  vpos      <= resize(y - 61, vpos'length);
               end if;
            end if;
         end if;

         if(videoout_ce = '1') then
            if(videoout_hblank = '1') then
               if (dual = '1') then
                  if (display_select = "10") then
                     lineReadAddr <= vpos(0) & to_unsigned(240, 9); -- player 2 half: +240
                  else
                     lineReadAddr <= vpos(0) & 9x"0";                -- both, or player 1 half
                  end if;
               else
                  lineReadAddr <= '0' & vpos(0) & x"00";
               end if;
               blineReadAddr    <= vpos(0) & 9x"00";
               singleDoubleTick <= '0';
            else
               blineReadAddr <= blineReadAddr + 1;
               if (x < HACT) then
                  if (dual = '1' and display_select /= "00") then
                     -- single-player: advance the source column every other
                     -- output column so each pixel is shown twice (2x wide)
                     singleDoubleTick <= not singleDoubleTick;
                     if (singleDoubleTick = '1') then
                        lineReadAddr <= lineReadAddr + 1;
                     end if;
                  else
                     lineReadAddr <= lineReadAddr + 1;
                  end if;
               end if;
            end if;

            x <= x + 1;
            if(x = HTOTAL) then
               x <= (others => '0');
               if (y < 511) then y <= y + 1; end if;
            end if;
         end if;

         -- fractional frame reset, must hit between two ce ticks: div = 5 is
         -- one of 8 subticks at ce = clk3x/8, one of the two "01" subticks
         -- falls inside the 4 subtick window at ce = clk3x/4
         if (x = 0 and y = 264 and ((dual = '0' and div = 5) or (dual = '1' and div(1 downto 0) = "01"))) then
            x  <= (others => '0');
            y  <= (others => '0');
         end if;

         case (pauseState) is
            when IDLE =>
               allowUnpause <= '1';
               if (pixel_we = '1' and pixel_x = 0 and pixel_y = 150) then
                  if (inPause = '0' and y < 256) then
                     pauseState   <= WAIT_PAUSING;
                     vsyncwaitcnt <= 260 - y;
                     requestPause <= '1';
                  end if;
               end if;

            when WAIT_PAUSING =>
               if (inPause = '1') then
                  pauseState   <= WAIT_LINES;
                  requestPause <= '0';
                  allowUnpause <= '0';
               end if;

            when WAIT_LINES =>
               if (vsyncwaitcnt = 0) then
                  pauseState <= IDLE;
               else
                  -- x = 0 is read back on exactly one ce subtick per line, but
                  -- the y = 264 reset alternates which ce phase that is
                  if (x = 0 and (div = 0 or (dual = '1' and div = 4))) then
                     vsyncwaitcnt <= vsyncwaitcnt - 1;
                  end if;
               end if;

         end case;


      end if;
   end process;

end architecture;




