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
      -- 90 degree scanout: the frames in DDR3 are already stored transposed
      -- (see gpufifo address mapping in gba_wrap), so this only switches the
      -- scanout geometry: 240x160 becomes 160x240, and the 2P profile's
      -- 480x160 side by side pair becomes 160x480 with player 1 stacked on
      -- top of player 2. Direction lives on the write side, both directions
      -- scan out identically.
      rotate_on               : in  std_logic := '0';
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
   signal y                : unsigned(9 downto 0) := (others => '0'); -- up to 530 lines when 2P is rotated

   signal lineInNew        : std_logic := '0';
   signal lineInNew_1      : std_logic := '0';
   signal vpos             : unsigned(8 downto 0) := (others => '0'); -- output line, 0..479 when 2P is rotated

   signal borderEff        : std_logic;

   -- Runtime scanout geometry. Rotation keeps the frame period identical and
   -- only reshapes the raster, so all of the frame pacing below stays valid:
   --   1P        240x160 of 399 x 265 ce ticks at clk3x/8
   --   1P rot    160x240 of 399 x 265 ce ticks at clk3x/8
   --   2P        480x160 of 798 x 265 ce ticks at clk3x/4
   --   2P rot    160x480 of 399 x 530 ce ticks at clk3x/4
   -- 399 x 530 and 798 x 265 are the same 211470 ticks, so the 2P rotated
   -- raster is the 2P raster with half the line length and twice the lines.
   signal rot              : std_logic;
   signal rot_dual         : std_logic;
   signal hact_s           : integer range 0 to 1023;
   signal htotal_s         : integer range 0 to 1023;
   signal hsync_st_s       : integer range 0 to 1023;
   signal hsync_end_s      : integer range 0 to 1023;
   signal yreset_s         : integer range 0 to 1023;
   signal vact_start       : integer range 0 to 1023;
   signal vact_end         : integer range 0 to 1023;
   signal vpos_base        : integer range 0 to 1023;
   signal fetch_start      : integer range 0 to 1023;
   signal fetch_end        : integer range 0 to 1023;
   signal sep_line         : integer range 0 to 1023;
   signal burstlen         : unsigned(9 downto 0);
   signal vshift_eff       : signed(2 downto 0);
   signal pause_ymax       : integer range 0 to 1023;
   signal pause_target     : integer range 0 to 1023;

   -- 2P rotated: each output line comes from one core only, the top 240 from
   -- player 1 and the bottom 240 from player 2 (or one core line doubled when
   -- a single player view is selected)
   signal fetch_core2      : std_logic;
   signal fetch_row        : unsigned(7 downto 0);
   signal fetchFrame       : unsigned(1 downto 0);
   signal fetchFramePrev   : unsigned(1 downto 0);

   type tPauseState is
   (
      IDLE,
      WAIT_PAUSING,
      WAIT_LINES
   );
   signal pauseState       : tPauseState := IDLE;
   signal vsyncwaitcnt     : unsigned(9 downto 0) := (others => '0');

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

   -- dual has no border framebuffer (it would need a 960 wide image), and a
   -- rotated frame has nowhere to put a 320x240 landscape border either
   rot       <= rotate_on;
   rot_dual  <= rotate_on and dual;
   borderEff <= borderOn and (not dual) and (not rot);

   hact_s      <= 160 when rot = '1' else HACT;
   htotal_s    <= 398 when (rot = '1' or dual = '0') else HTOTAL;
   hsync_st_s  <= 293 when (rot = '1' or dual = '0') else HSYNC_ST;
   hsync_end_s <= 325 when (rot = '1' or dual = '0') else HSYNC_ST + HSYNC_LEN;

   yreset_s    <= 529 when rot_dual = '1' else 264;
   vact_start  <=  25 when rot_dual = '1' else  22 when rot = '1' else  62;
   vact_end    <= 505 when rot_dual = '1' else 262 when rot = '1' else 222;
   vpos_base   <=  24 when rot_dual = '1' else  21 when rot = '1' else  61;
   fetch_start <=  24 when rot_dual = '1' else  21 when rot = '1' else  61;
   fetch_end   <= 504 when rot_dual = '1' else 261 when rot = '1' else 222;
   sep_line    <= vact_start + 239; -- 2P rotated seam, the last player 1 line
   pause_ymax   <= yreset_s - 8;
   pause_target <= yreset_s - 4;
   burstlen    <= to_unsigned( 40, 10) when rot = '1' else to_unsigned( 60, 10); -- 64bit words per line
   -- only 3 blank lines are left below the rotated 1P image, so the V-Sync
   -- adjust range no longer fits; hold it at 0 while rotated
   vshift_eff  <= (others => '0') when rot = '1' else videoVshift;

   -- 2P rotated line source: both = player 1 on top, player 2 below; a single
   -- player view line doubles that core to fill the same 480 lines
   fetch_core2 <= '0'                                     when rot_dual = '0' else
                  '0'                                     when display_select = "01" else
                  '1'                                     when display_select = "10" else
                  '1'                                     when vpos >= 240 else
                  '0';

   fetch_row   <= vpos(7 downto 0)                        when rot_dual = '0' else
                  resize(vpos(8 downto 1), 8)             when display_select /= "00" else
                  resize(vpos - 240, 8)                   when vpos >= 240 else
                  vpos(7 downto 0);

   fetchFrame     <= currFrame2_scan when fetch_core2 = '1' else currFrame;
   fetchFramePrev <= prevFrame2_scan when fetch_core2 = '1' else prevFrame;

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

         -- latch core 2's buffer pair once per scanout frame, above the
         -- active area, so the right/bottom half never switches mid frame
         if (dual = '1' and lineInNew /= lineInNew_1 and y < vpos_base) then
            currFrame2_scan <= currFrame2;
            prevFrame2_scan <= prevFrame2;
         end if;

         if (dual = '1' and pixel2_we = '1' and pixel2_x = 239 and pixel2_y = 159) then
            nextFrame2 <= nextFrame2 + 1;
            currFrame2 <= nextFrame2;
            prevFrame2 <= currFrame2;
         end if;

         if (dual = '1' and rot = '0') then

            -- per line: core 1 into words 0..59, core 2 into words 60..119,
            -- with blend the same again from the previous frames into lineram2

            if (y >= 61 and y < 62+160) then
               if (lineInNew /= lineInNew_1) then
                  ddr3_request  <= '1';
                  ddr3_address  <= '1' & 8x"0" & currFrame & fetch_row & 6x"0" & "000";
                  ddr3_burstcnt <= 10x"3C"; -- 60 * 64bit = 240 * 16 bit
                  lineWriteAddr <= vpos(0) & 7x"0";
                  secondFrame   <= '0';
                  fetchPhase    <= "00";
               elsif (ddr3_done = '1') then
                  case (fetchPhase) is
                     when "00" =>
                        ddr3_request  <= '1';
                        ddr3_address  <= '1' & 7x"0" & '1' & currFrame2_scan & fetch_row & 6x"0" & "000";
                        ddr3_burstcnt <= 10x"3C";
                        lineWriteAddr <= vpos(0) & to_unsigned(60, 7);
                        fetchPhase    <= "01";
                     when "01" =>
                        if (blend = '1') then
                           ddr3_request  <= '1';
                           ddr3_address  <= '1' & 8x"0" & prevFrame & fetch_row & 6x"0" & "000";
                           ddr3_burstcnt <= 10x"3C";
                           lineWriteAddr <= vpos(0) & 7x"0";
                           secondFrame   <= '1';
                           fetchPhase    <= "10";
                        end if;
                     when "10" =>
                        ddr3_request  <= '1';
                        ddr3_address  <= '1' & 7x"0" & '1' & prevFrame2_scan & fetch_row & 6x"0" & "000";
                        ddr3_burstcnt <= 10x"3C";
                        lineWriteAddr <= vpos(0) & to_unsigned(60, 7);
                        fetchPhase    <= "11";
                     when others => null;
                  end case;
               end if;
            end if;

         else

            if (lineInNew /= lineInNew_1 and borderEff = '1') then
               borderReadOn   <= '1';
               ddr3_request   <= '1';
               ddr3_address   <= x"D" & to_unsigned(1280 * to_integer(y - 21), 24);
               ddr3_burstcnt <= 10x"A0"; -- 160 * 64bit = 320 * 32 bit
               blineWriteAddr <= vpos(0) & 8x"0";
            elsif (y >= fetch_start and y < fetch_end) then
               if ((lineInNew /= lineInNew_1 and borderEff = '0') or (ddr3_done = '1' and borderReadOn = '1')) then
                  borderReadOn <= '0';
                  ddr3_request  <= '1';
                  -- bit 19 picks core 2's frame buffer bank at byte 0x8080000
                  ddr3_address  <= '1' & 7x"0" & fetch_core2 & fetchFrame & fetch_row & 6x"0" & "000";
                  ddr3_burstcnt <= burstlen; -- 60 words = 240 px, rotated 40 words = 160 px
                  lineWriteAddr <= '0' & vpos(0) & 6x"0";
                  secondFrame   <= '0';
               elsif (ddr3_done = '1' and secondFrame = '0' and blend = '1' ) then
                  secondFrame                <= '1';
                  ddr3_request               <= '1';
                  ddr3_address(18 downto 17) <= fetchFramePrev;
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

            if (x < hact_s and y >= vact_start and y < vact_end) then
               if (dual = '1' and separator_on = '1' and display_select = "00" and
                   ((rot = '0' and (x = 239 or x = 240)) or
                    (rot = '1' and (y = sep_line or y = sep_line + 1)))) then
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
               if (x = hact_s)      then videoout_hblank <= '1'; end if;
               if (x =    0)        then videoout_hblank <= '0'; end if;
               if (y  = vact_start) then videoout_vblank <= '0'; end if;
               if (y >= vact_end)   then videoout_vblank <= '1'; end if;
            end if;

            if(x = hsync_st_s + to_integer(videoHshift)) then
               videoout_hsync <= '1';
               if (vshift_eff < -1) then
                  if (y = yreset_s + 1 + to_integer(vshift_eff)) then videoout_vsync <= '1'; end if;
               else
                  if (y = 1 + to_integer(vshift_eff)) then videoout_vsync <= '1'; end if;
               end if;
               if (y = 4 + to_integer(vshift_eff)) then videoout_vsync <= '0'; end if;
            end if;

            if(x = hsync_end_s + to_integer(videoHshift)) then videoout_hsync <= '0'; end if;

            if (x = 0) then
               -- 21 rather than fetch_start: the border prefetch starts early
               if (y >= 21 and y < fetch_end) then
                  lineInNew <= not lineInNew;
                  vpos      <= resize(y - vpos_base, vpos'length);
               end if;
            end if;
         end if;

         if(videoout_ce = '1') then
            if(videoout_hblank = '1') then
               if (dual = '1' and rot = '0') then
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
               if (x < hact_s) then
                  if (dual = '1' and rot = '0' and display_select /= "00") then
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
            if(x = htotal_s) then
               x <= (others => '0');
               if (y < 1023) then y <= y + 1; end if;
            end if;
         end if;

         -- fractional frame reset, must hit between two ce ticks: div = 5 is
         -- one of 8 subticks at ce = clk3x/8, one of the two "01" subticks
         -- falls inside the 4 subtick window at ce = clk3x/4
         if (x = 0 and y = yreset_s and ((dual = '0' and div = 5) or (dual = '1' and div(1 downto 0) = "01"))) then
            x  <= (others => '0');
            y  <= (others => '0');
         end if;

         case (pauseState) is
            when IDLE =>
               allowUnpause <= '1';
               if (pixel_we = '1' and pixel_x = 0 and pixel_y = 150) then
                  if (inPause = '0' and y < pause_ymax) then
                     pauseState   <= WAIT_PAUSING;
                     vsyncwaitcnt <= pause_target - y;
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




