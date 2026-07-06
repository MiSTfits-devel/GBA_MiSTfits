library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

library MEM;
use work.pProc_bus_gba.all;
use work.pReg_savestates.all;
use work.pDDR3.all;

entity gba_wrap is
   generic
   (
      Softmap_GBA_Gamerom_ADDR : integer; -- count: 8388608    -- 32 Mbyte Data for GameRom
      Softmap_GBA_FLASH_ADDR   : integer; -- count:  131072    -- 128/512 Kbyte Data for GBA Flash
      Softmap_GBA_EEPROM_ADDR  : integer; -- count:    8192    -- 8/32 Kbyte Data for GBA EEProm
      Softmap_GBA_EWRAM_ADDR   : integer := 0; -- count: 262144 -- 256 Kbyte Data for EWRAM core 1 (2P profile)
      Softmap_GBA_EWRAM2_ADDR  : integer := 0; -- count: 262144 -- 256 Kbyte Data for EWRAM core 2 (2P profile)
      Softmap_GBA_Gamerom2_ADDR: integer := 0; -- count: 8388608 -- 32 Mbyte independent ROM for core 2 (2P profile, LOAD_2P only)
      Softmap_GBA_Gamerom_Ext_ADDR: integer := 0; -- count: 8388608 -- second 32 Mbyte half for >32MB "Matrix"-mapper carts (GBA Video/Shrek); 1P (single-core) build only
      Softmap_SaveState_ADDR   : integer; -- count:  524288    -- 512 Kbyte Data for Savestate
      Softmap_Rewind_ADDR      : integer; -- count:  524288*64 -- 64*512 Kbyte Data for Savestates
      is_simu                  : std_logic := '0';
      strip_savestates         : std_logic := '0'; -- 1 = no savestates/rewind (2P profile)
      strip_cheats             : std_logic := '0'; -- 1 = no cheat engine (2P profile)
      ewram_in_sdram           : std_logic := '0'; -- 1 = EWRAM lives in SDRAM instead of BRAM (2P profile)
      second_core              : std_logic := '0'; -- 1 = instantiate a second GBA core, link cables crosswired (2P profile, requires ewram_in_sdram)
      turbosound               : std_logic  -- sound buffer to play sound in turbo mode without sound pitched up
   );
   port 
   (
      clk1x                 : in     std_logic;  
      clk3x                 : in     std_logic;  
      clk6x                 : in     std_logic;  
      -- settings                 
      GBA_on                : in     std_logic;  -- switching from off to on = reset
      pause                 : in     std_logic;
      inPause               : out    std_logic;
      -- per-core power/reset (2P profile): independent of the shared GBA_on/pause
      -- above, which still gate both cores together (e.g. during any HPS download).
      -- These add finer-grained per-core control on top of that shared base.
      core1_power           : in     std_logic := '1';
      core2_power           : in     std_logic := '1';
      core1_reset           : in     std_logic := '0'; -- momentary, same idiom as the shared reset trigger
      core2_reset           : in     std_logic := '0';
      rom_shared            : in     std_logic := '1'; -- 1 = core 2 reads core 1's ROM window; 0 = core 2's own independent window
      big_rom_active        : in     std_logic := '0'; -- 1 = core 1's cart is a >32MB Matrix-mapper cart (GBA Video/Shrek); 1P build only
      GBA_lockspeed         : in     std_logic;  -- 1 = 100% speed, 0 = max speed
      GBA_cputurbo          : in     std_logic;  -- 1 = cpu free running, all other 16 mhz
      GBA_flash_1m          : in     std_logic;  -- 1 when string "FLASH1M_V" is anywhere in gamepak
      Underclock            : in     std_logic_vector(1 downto 0);
      MaxPakAddr            : in     std_logic_vector(24 downto 0); -- max byte address that will contain data, required for buggy games that read behind their own memory, e.g. zelda minish cap
      MaxPakAddr2           : in     std_logic_vector(24 downto 0) := (others => '0'); -- core 2's own MaxPakAddr (2P profile): mirrors MaxPakAddr when rom_shared='1', independent otherwise
      CyclesMissing         : out    std_logic_vector(31 downto 0); -- debug only for speed measurement, keep open
      CyclesVsyncSpeed      : out    std_logic_vector(31 downto 0); -- debug only for speed measurement, keep open
      SramFlashEnable       : in     std_logic;
      memory_remap          : in     std_logic;
      increaseSSHeaderCount : in     std_logic;
      save_state            : in     std_logic;
      load_state            : in     std_logic;
      interframe_blend      : in     std_logic_vector(1 downto 0); -- 0 = off, 1 = blend, 2 = 30hz
      shade_mode            : in     std_logic_vector(2 downto 0);
      borderOn              : in     std_logic;     
      videoHshift           : in     signed(3 downto 0);      
      videoVshift           : in     signed(2 downto 0);      
      specialmodule         : in     std_logic;                    -- 0 = off, 1 = use gamepak GPIO Port at address 0x080000C4..0x080000C8
      -- Sennen Kazoku is the one known cart whose own GPIO driver never
      -- writes the RTC device-select bit (selected(2)) before talking to
      -- the RTC, so gba_gpioRTCSolarGyro.vhd used to skip that check for
      -- everyone -- breaking real hardware-accurate RTC selection for
      -- every other GPIO game (Pokemon, Boktai, etc, see
      -- github.com/MiSTer-devel/GBA_MiSTer/issues/150). Restoring the real
      -- check by default and only bypassing it for this one cart id.
      rtc_noselect_quirk    : in     std_logic;
      solar_in              : in     std_logic_vector(2 downto 0);
      tilt                  : in     std_logic;                    -- 0 = off, 1 = use tilt at address 0x0E008200, 0x0E008300, 0x0E008400, 0x0E008500
      overlay_error_on      : in     std_logic;
      overlay_link_on       : in     std_logic := '0';
      rewind_on             : in     std_logic;
      rewind_active         : in     std_logic;
      savestate_number      : in     integer;
      -- RTC
      RTC_timestampNew      : in     std_logic;                     -- new current timestamp from system
      RTC_timestampIn       : in     std_logic_vector(31 downto 0); -- timestamp in seconds, current time
      RTC_timestampSaved    : in     std_logic_vector(31 downto 0); -- timestamp in seconds, saved time
      RTC_savedtimeIn       : in     std_logic_vector(41 downto 0); -- time structure, loaded
      RTC_saveLoaded        : in     std_logic;                     -- must be 0 when loading new game, should go and stay 1 when RTC was loaded and values are valid
      RTC_timestampOut      : out    std_logic_vector(31 downto 0); -- timestamp to be saved
      RTC_savedtimeOut      : out    std_logic_vector(41 downto 0); -- time structure to be saved
      RTC_inuse             : out    std_logic := '0';              -- will indicate that RTC is in use and should be saved on next saving
      -- cheats
      cheat_clear           : in     std_logic;
      cheats_enabled        : in     std_logic;
      cheat_on              : in     std_logic;
      cheat_in              : in     std_logic_vector(127 downto 0);
      cheats_active         : out    std_logic := '0';
      -- SDRAM
      sdram_Din             : out    std_logic_vector(31 downto 0);
      sdram_Adr             : out    std_logic_vector(26 downto 0);
      sdram_rnw             : out    std_logic;
      sdram_ena             : out    std_logic;
      sdram_be              : out    std_logic_vector(3 downto 0); -- byte enables for writes, "1111" outside EWRAM ops
      sdram_cancel          : out    std_logic;              
      sdram_refresh         : out    std_logic;              
      sdram_Dout            : in     std_logic_vector(31 downto 0);      
      sdram_done16          : in     std_logic;                     
      sdram_done32          : in     std_logic;  
      -- DDR3 
      ddr3_BUSY             : in     std_logic;                    
      ddr3_DOUT             : in     std_logic_vector(63 downto 0);
      ddr3_DOUT_READY       : in     std_logic;
      ddr3_BURSTCNT         : out    std_logic_vector(7 downto 0) := (others => '0'); 
      ddr3_ADDR             : out    std_logic_vector(28 downto 0) := (others => '0');                       
      ddr3_DIN              : out    std_logic_vector(63 downto 0) := (others => '0');
      ddr3_BE               : out    std_logic_vector(7 downto 0) := (others => '0'); 
      ddr3_WE               : out    std_logic := '0';
      ddr3_RD               : out    std_logic := '0';   
      -- romcopy
      romcopy_start         : in     std_logic;
      romcopy_size          : in     unsigned(26 downto 0);
      romcopy_dest_is_core2 : in     std_logic := '0'; -- latched at romcopy_start: copy targets core 2's independent window instead of core 1's
      rom_addr              : out    std_logic_vector(26 downto 0);
      rom_dout              : out    std_logic_vector(15 downto 0);
      rom_wr                : out    std_logic := '0';
      rom_copy              : out    std_logic := '0';
      romcopy_req           : out    std_logic := '0';
      romcopy_data          : out    std_logic_vector(31 downto 0);
      romcopy_writepos      : out    std_logic_vector(26 downto 0);
      -- Write to BIOS
      bios_wraddr           : in     std_logic_vector(11 downto 0) := (others => '0');
      bios_wrdata           : in     std_logic_vector(31 downto 0) := (others => '0');
      bios_wr               : in     std_logic := '0';
      -- save memory used
      save_eeprom           : out    std_logic;
      save_sram             : out    std_logic;
      save_flash            : out    std_logic;
      load_done             : out    std_logic;                     -- savestate successfully loaded
      -- Keys - all active high   
      KeyA                  : in     std_logic; 
      KeyB                  : in     std_logic;
      KeySelect             : in     std_logic;
      KeyStart              : in     std_logic;
      KeyRight              : in     std_logic;
      KeyLeft               : in     std_logic;
      KeyUp                 : in     std_logic;
      KeyDown               : in     std_logic;
      KeyR                  : in     std_logic;
      KeyL                  : in     std_logic;
      AnalogTiltX           : in     signed(7 downto 0);
      AnalogTiltY           : in     signed(7 downto 0);
      Rumble                : out    std_logic;
      KeyPause              : in     std_logic;
      -- link port (open drain (value, oe) pairs, inputs must be synchronized)
      link_enable           : in     std_logic := '0';
      link_role_parent      : in     std_logic := '1';
      link_clk_out          : out    std_logic := '1';
      link_clk_oe           : out    std_logic := '0';
      link_clk_in           : in     std_logic := '1';
      link_so_out           : out    std_logic := '1';
      link_so_oe            : out    std_logic := '0';
      link_si_in            : in     std_logic := '1';
      link_sd_out           : out    std_logic := '1';
      link_sd_oe            : out    std_logic := '0';
      link_sd_in            : in     std_logic := '1';
      -- second core (2P profile): internal link + player 2 keys
      link_2p               : in     std_logic := '0'; -- 1 = core 1 link lines come from the internal core<->core cable, core 1 is parent
      Key2A                 : in     std_logic := '0';
      Key2B                 : in     std_logic := '0';
      Key2Select            : in     std_logic := '0';
      Key2Start             : in     std_logic := '0';
      Key2Right             : in     std_logic := '0';
      Key2Left              : in     std_logic := '0';
      Key2Up                : in     std_logic := '0';
      Key2Down              : in     std_logic := '0';
      Key2R                 : in     std_logic := '0';
      Key2L                 : in     std_logic := '0';
      sound2_select         : in     std_logic_vector(1 downto 0) := "00"; -- 0 = core 1, 1 = core 2, 2 = 50/50 mix, 3 = split (P1 left / P2 right)
      display2p_select      : in     std_logic_vector(1 downto 0) := "00"; -- 0 = both side by side, 1 = player 1 only, 2 = player 2 only (2P profile, view only)
      separator_line        : in     std_logic := '0'; -- 1 = draw a thin line at the x=239/240 seam ("both" display mode only)
      -- debug interface
      GBA_BusAddr           : in     std_logic_vector(27 downto 0);
      GBA_BusRnW            : in     std_logic;
      GBA_BusACC            : in     std_logic_vector(1 downto 0);
      GBA_BusWriteData      : in     std_logic_vector(31 downto 0);
      GBA_BusReadData       : out    std_logic_vector(31 downto 0);
      GBA_Bus_written       : in     std_logic;
      -- display data
      pixel_out_x           : buffer integer range 0 to 239;
      pixel_out_y           : buffer integer range 0 to 159;
      pixel_out_data        : buffer std_logic_vector(14 downto 0);  -- RGB data for framebuffer 
      pixel_out_we          : buffer std_logic;                      -- new pixel for framebuffer 
      
      videoout_hsync        : out    std_logic := '0';
      videoout_vsync        : out    std_logic := '0';
      videoout_hblank       : out    std_logic := '0';
      videoout_vblank       : out    std_logic := '0';
      videoout_ce           : out    std_logic;
      videoout_interlace    : out    std_logic;
      videoout_r            : out    std_logic_vector(7 downto 0);
      videoout_g            : out    std_logic_vector(7 downto 0);
      videoout_b            : out    std_logic_vector(7 downto 0);
      -- sound                             
      sound_out_left        : out    std_logic_vector(15 downto 0) := (others => '0');
      sound_out_right       : out    std_logic_vector(15 downto 0) := (others => '0');
      -- debug                    
      debug_cpu_pc          : out    std_logic_vector(31 downto 0);
      debug_cpu_mixed       : out    std_logic_vector(31 downto 0);
      debug_irq             : out    std_logic_vector(31 downto 0);
      debug_dma             : out    std_logic_vector(31 downto 0);
      debug_mem             : out    std_logic_vector(31 downto 0)  
   );
end entity;

architecture arch of gba_wrap is

   signal clk1xToggle       : std_logic := '0';

   signal clk1xToggle6X     : std_logic := '0';
   signal clk1xToggle6X_1   : std_logic := '0';
   signal clk6xIndex        : unsigned(2 downto 0) := (others => '0');
   
   signal vblank_trigger    : std_logic;
   signal inPauseCore       : std_logic;
   signal requestPause      : std_logic;
   signal allowUnpause      : std_logic;
   
   signal cart_ena          : std_logic;
   signal cart_idle         : std_logic;
   signal cart_32           : std_logic;
   signal cart_rnw          : std_logic;
   signal cart_addr         : std_logic_vector(27 downto 0);
   signal cart_writedata    : std_logic_vector(7 downto 0);
   signal cart_writedata32  : std_logic_vector(31 downto 0);
   signal cart_be32         : std_logic_vector(3 downto 0);
   signal matrix_remap_hit  : std_logic;
   signal matrix_remap_addr : std_logic_vector(26 downto 0);
   signal cart_done         : std_logic;
   signal cart_readdata     : std_logic_vector(31 downto 0);
   signal cart_waitcnt      : std_logic_vector(15 downto 0);
   signal dma_eepromcount   : unsigned(16 downto 0);
   signal cart_reset        : std_logic; 
   
   signal MaxPakAddr_modified  : std_logic_vector(24 downto 0);
   signal MaxPakAddr2_modified : std_logic_vector(24 downto 0);

   -- EWRAM in SDRAM (2P profile): mux between the extern scheduler and the EWRAM channel
   signal mmx_sdram_Din     : std_logic_vector(31 downto 0);
   signal mmx_sdram_Adr     : std_logic_vector(26 downto 0);
   signal mmx_sdram_rnw     : std_logic;
   signal mmx_sdram_ena     : std_logic;

   signal ewram_ena         : std_logic;
   signal ewram_rnw         : std_logic;
   signal ewram_addr        : std_logic_vector(15 downto 0);
   signal ewram_be          : std_logic_vector(3 downto 0);
   signal ewram_writedata   : std_logic_vector(31 downto 0);
   signal ewram_done        : std_logic;
   signal ewram_readdata    : std_logic_vector(31 downto 0);

   signal ewram_active      : std_logic;
   signal ewram_busy        : std_logic;

   signal ew_sdram_ena      : std_logic;
   signal ew_sdram_rnw      : std_logic;
   signal ew_sdram_Adr      : std_logic_vector(26 downto 0);
   signal ew_sdram_Din      : std_logic_vector(31 downto 0);
   signal ew_sdram_be       : std_logic_vector(3 downto 0);

   -- guest channel arbitration on the shared SDRAM port (2P profile).
   -- memorymux_extern (core 1 cart) is the default owner; the guest channels
   -- launch only at clk6xIndex 0 when the extern scheduler grants extern_allow.
   -- Fixed priority core1-EWRAM > core2-EWRAM > core2-cart: a guest may launch
   -- when no higher priority guest has a request pending (active) and no lower
   -- priority guest op is in flight (busy). Mutual exclusion at the launch
   -- edge comes from the active flags, which are registered on clk1x and
   -- therefore stable before the shared clk6xIndex 0 slot.
   signal extern_allow      : std_logic;
   signal ew1_allow         : std_logic;
   signal guests_active     : std_logic;
   signal guests_busy       : std_logic;

   -- core 2 EWRAM channel
   signal ew2_ena           : std_logic;
   signal ew2_rnw           : std_logic;
   signal ew2_addr          : std_logic_vector(15 downto 0);
   signal ew2_be            : std_logic_vector(3 downto 0);
   signal ew2_writedata     : std_logic_vector(31 downto 0);
   signal ew2_done          : std_logic;
   signal ew2_readdata      : std_logic_vector(31 downto 0);
   signal ew2_allow         : std_logic;
   signal ew2_active        : std_logic;
   signal ew2_busy          : std_logic;
   signal ew2_sdram_ena     : std_logic;
   signal ew2_sdram_rnw     : std_logic;
   signal ew2_sdram_Adr     : std_logic_vector(26 downto 0);
   signal ew2_sdram_Din     : std_logic_vector(31 downto 0);
   signal ew2_sdram_be      : std_logic_vector(3 downto 0);

   -- core 2 cart channel
   signal c2_cart_ena       : std_logic;
   signal c2_cart_32        : std_logic;
   signal c2_cart_rnw       : std_logic;
   signal c2_cart_addr      : std_logic_vector(27 downto 0);
   signal c2_cart_done      : std_logic;
   signal c2_cart_readdata  : std_logic_vector(31 downto 0);
   signal c2_cart_reset     : std_logic;
   signal cart2_allow       : std_logic;
   signal cart2_active      : std_logic;
   signal cart2_busy        : std_logic;
   signal c2_sdram_ena      : std_logic;
   signal c2_sdram_Adr      : std_logic_vector(26 downto 0);

   -- core 1 link lines (to/from gba_top), muxed between the external SNAC
   -- port and the internal core<->core cable
   signal c1_link_clk_out   : std_logic;
   signal c1_link_clk_oe    : std_logic;
   signal c1_link_clk_in    : std_logic;
   signal c1_link_so_out    : std_logic;
   signal c1_link_so_oe     : std_logic;
   signal c1_link_si_in     : std_logic;
   signal c1_link_sd_out    : std_logic;
   signal c1_link_sd_oe     : std_logic;
   signal c1_link_sd_in     : std_logic;

   -- core 2 link lines
   signal c2_link_clk_out   : std_logic;
   signal c2_link_clk_oe    : std_logic;
   signal c2_link_clk_in    : std_logic := '1'; -- idle-high; only driven inside gSecondCore, read by the debug overlay unconditionally
   signal c2_link_so_out    : std_logic;
   signal c2_link_so_oe     : std_logic;
   signal c2_link_si_in     : std_logic;
   signal c2_link_sd_out    : std_logic;
   signal c2_link_sd_oe     : std_logic;
   signal c2_link_sd_in     : std_logic := '1'; -- idle-high; only driven inside gSecondCore, read by the debug overlay unconditionally
   
   signal SAVE_out_Din      : std_logic_vector(63 downto 0);
   signal SAVE_out_Dout     : std_logic_vector(63 downto 0);
   signal SAVE_out_Adr      : std_logic_vector(25 downto 0);
   signal SAVE_out_rnw      : std_logic;                    
   signal SAVE_out_ena      : std_logic;                                
   signal SAVE_out_be       : std_logic_vector(7 downto 0);
   signal SAVE_out_done     : std_logic;                    
   
   signal GPIO_done         : std_logic;
   signal GPIO_readEna      : std_logic;
   signal GPIO_Din          : std_logic_vector(3 downto 0);
   signal GPIO_Dout         : std_logic_vector(3 downto 0);
   signal GPIO_writeEna     : std_logic;
   signal GPIO_addr         : std_logic_vector(1 downto 0);
   
   signal savestate_bus_ext : proc_bus_gb_type;
   signal ss_wired_out_ext  : std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
   signal ss_wired_done_ext : std_logic;
   
   type t_ss_wired_or is array(0 to 1) of std_logic_vector(31 downto 0);
   signal save_wired_or        : t_ss_wired_or;   
   signal save_wired_done      : unsigned(0 to 1);

   signal rdram_request    : tDDDR3Single;
   signal rdram_rnw        : tDDDR3Single;    
   signal rdram_address    : tDDDR3ReqAddr;
   signal rdram_burstcount : tDDDR3Burstcount;  
   signal rdram_writeMask  : tDDDR3BwriteMask;  
   signal rdram_dataWrite  : tDDDR3BwriteData;
   signal rdram_granted    : tDDDR3Single;
   signal rdram_done       : tDDDR3Single;
   signal rdram_ready      : tDDDR3Single;
   signal rdram_dataRead   : std_logic_vector(63 downto 0);
   
   signal gpufifo_reset    : std_logic;
   signal gpufifo_Din      : std_logic_vector(33 downto 0); -- 16bit data + 18 bit address
   signal gpufifo_Wr       : std_logic;
   signal gpufifo_nearfull : std_logic;
   signal gpufifo_empty    : std_logic;
   signal gpufifo_Frame    : std_logic_vector(1 downto 0);

   -- core 2 write channel (2P profile): whole 64bit words, tied off otherwise
   signal gpufifo2_Din     : std_logic_vector(79 downto 0);
   signal gpufifo2_Wr      : std_logic;
   signal gpufifo2_Frame   : std_logic_vector(1 downto 0);

   signal pixel_core_x           : integer range 0 to 239;
   signal pixel_core_y           : integer range 0 to 159;
   signal pixel_core_data        : std_logic_vector(14 downto 0);
   signal pixel_core_we          : std_logic := '0';

   signal shader_mode            : std_logic_vector(2 downto 0);
   signal pixel_shade_x          : integer range 0 to 239;
   signal pixel_shade_y          : integer range 0 to 159;
   signal pixel_shade_data       : std_logic_vector(17 downto 0);
   signal pixel_shade_we         : std_logic := '0';

   signal pixel2_shade_x         : integer range 0 to 239;
   signal pixel2_shade_y         : integer range 0 to 159;
   signal pixel2_shade_data      : std_logic_vector(17 downto 0);
   signal pixel2_shade_we        : std_logic := '0';

   signal c1_sound_left          : std_logic_vector(15 downto 0);
   signal c1_sound_right         : std_logic_vector(15 downto 0);
   
   signal colorR                 : unsigned(7 downto 0);
   signal colorG                 : unsigned(7 downto 0);
   signal colorB                 : unsigned(7 downto 0);
   signal luma                   : unsigned(7 downto 0);
   signal colorRdesat            : unsigned(7 downto 0);
   signal colorGdesat            : unsigned(7 downto 0);
   signal colorBdesat            : unsigned(7 downto 0);
   
   signal pixel_data             : std_logic_vector(14 downto 0);
   signal errortext              : unsigned(31 downto 0);
   signal overlay_error_data     : std_logic_vector(14 downto 0);
   signal overlay_error_ena      : std_logic;   
      
   signal errorEna               : std_logic;
   signal errorCode              : unsigned(15 downto 0) := (others => '0');

   -- Temporary hardware diagnostic: on-screen link debug overlay, see
   -- gba_serial.vhd's debug_link_state. Remove once the real-hardware
   -- link-establishment bug is root-caused.
   signal c1_debug_link_state    : std_logic_vector(70 downto 0);
   signal c2_debug_link_state    : std_logic_vector(70 downto 0) := (others => '0');
   signal c1_linktext            : unsigned(20*8-1 downto 0);
   signal c2_linktext            : unsigned(20*8-1 downto 0);
   signal c1_datatext            : unsigned(13*8-1 downto 0);
   signal c2_datatext            : unsigned(13*8-1 downto 0);
   signal c1_multitext           : unsigned(13*8-1 downto 0);
   signal c2_multitext           : unsigned(13*8-1 downto 0);
   signal c1_ch_S, c1_ch_M, c1_ch_B, c1_ch_E, c1_ch_D, c1_ch_K : unsigned(7 downto 0);
   signal c2_ch_S, c2_ch_M, c2_ch_B, c2_ch_E, c2_ch_D, c2_ch_K : unsigned(7 downto 0);
   signal c1_ch_T3, c1_ch_T2, c1_ch_T1, c1_ch_T0 : unsigned(7 downto 0);
   signal c1_ch_R3, c1_ch_R2, c1_ch_R1, c1_ch_R0 : unsigned(7 downto 0);
   signal c2_ch_T3, c2_ch_T2, c2_ch_T1, c2_ch_T0 : unsigned(7 downto 0);
   signal c2_ch_R3, c2_ch_R2, c2_ch_R1, c2_ch_R0 : unsigned(7 downto 0);
   signal c1_ch_M23, c1_ch_M22, c1_ch_M21, c1_ch_M20 : unsigned(7 downto 0);
   signal c1_ch_M33, c1_ch_M32, c1_ch_M31, c1_ch_M30 : unsigned(7 downto 0);
   signal c2_ch_M23, c2_ch_M22, c2_ch_M21, c2_ch_M20 : unsigned(7 downto 0);
   signal c2_ch_M33, c2_ch_M32, c2_ch_M31, c2_ch_M30 : unsigned(7 downto 0);
   signal linkdebugEna           : std_logic;
   signal overlay_link1_data     : std_logic_vector(14 downto 0);
   signal overlay_link1_ena      : std_logic;
   signal overlay_link2_data     : std_logic_vector(14 downto 0);
   signal overlay_link2_ena      : std_logic;
   signal overlay_data1_data     : std_logic_vector(14 downto 0);
   signal overlay_data1_ena      : std_logic;
   signal overlay_data2_data     : std_logic_vector(14 downto 0);
   signal overlay_data2_ena      : std_logic;
   signal overlay_multi1_data    : std_logic_vector(14 downto 0);
   signal overlay_multi1_ena     : std_logic;
   signal overlay_multi2_data    : std_logic_vector(14 downto 0);
   signal overlay_multi2_ena     : std_logic;
   signal error_cpu              : std_logic;
   signal error_memRequ_timeout  : std_logic;
   signal error_memResp_timeout  : std_logic;
   signal error_refresh          : std_logic;
   
   signal flash_busy             : std_logic;
  
   -- romcopy
   type tROMCOPYSTATE is
   (
      ROMCOPY_IDLE,
      ROMCOPY_CLEANSAVERAM,
      ROMCOPY_READDDR3,
      ROMCOPY_WRITESDRAM1,
      ROMCOPY_WRITESDRAM2,
      ROMCOPY_WRITESDRAM3,
      ROMCOPY_WRITESDRAM4,
      ROMCOPY_NEXT
   );
   signal ROMCOPYSTATE : tROMCOPYSTATE := ROMCOPY_IDLE;
   
   signal romcopy_writedata : std_logic_vector(63 downto 0);
   
   signal GBA_on1X_1 : std_logic := '0';
   signal GBA_on1X_2 : std_logic := '0';
   signal romcopy_target_core2 : std_logic := '0'; -- latched at romcopy_start: this copy is destined for core 2's independent window

   -- Temporary hardware diagnostic: hex nibble -> ASCII, see the link debug
   -- overlay below. Remove once the real-hardware link-establishment bug
   -- is root-caused.
   function hexchar(nibble : std_logic_vector(3 downto 0)) return unsigned is
   begin
      if (unsigned(nibble) < 10) then
         return resize(unsigned(nibble), 8) + 16#30#;
      else
         return resize(unsigned(nibble), 8) + 16#37#;
      end if;
   end function;

begin

   igba_top : entity work.gba_top
   generic map
   (
      Softmap_GBA_Gamerom_ADDR => Softmap_GBA_Gamerom_ADDR,
      Softmap_GBA_FLASH_ADDR   => Softmap_GBA_FLASH_ADDR  ,
      Softmap_GBA_EEPROM_ADDR  => Softmap_GBA_EEPROM_ADDR ,
      Softmap_SaveState_ADDR   => Softmap_SaveState_ADDR  ,
      Softmap_Rewind_ADDR      => Softmap_Rewind_ADDR     ,
      is_simu                  => is_simu                 ,
      strip_savestates         => strip_savestates        ,
      strip_cheats             => strip_cheats            ,
      ewram_in_sdram           => ewram_in_sdram          ,
      turbosound               => turbosound
   )
   port map
   (
      clk1x                 => clk1x                ,       
      -- settings                                   
      GBA_on                => GBA_on1X_1           ,
      pause                 => pause or (requestPause and (not is_simu)),
      allowUnpause          => allowUnpause         ,
      inPause               => inPauseCore          ,
      GBA_lockspeed         => GBA_lockspeed        ,
      GBA_cputurbo          => GBA_cputurbo         ,
      GBA_flash_1m          => GBA_flash_1m         ,
      Underclock            => Underclock           ,
      CyclesMissing         => CyclesMissing        ,
      CyclesVsyncSpeed      => CyclesVsyncSpeed     ,
      increaseSSHeaderCount => increaseSSHeaderCount,
      save_state            => save_state           ,
      load_state            => load_state           ,
      interframe_blend      => interframe_blend     ,
      shade_mode            => shade_mode           ,
      rewind_on             => rewind_on            ,
      rewind_active         => rewind_active        ,
      savestate_number      => savestate_number     ,
      -- errors
      error_cpu             => error_cpu,
      error_memRequ_timeout => error_memRequ_timeout,
      error_memResp_timeout => error_memResp_timeout,
      flash_busy            => flash_busy,
      -- cheats                                     
      cheat_clear           => cheat_clear          ,
      cheats_enabled        => cheats_enabled       ,
      cheat_on              => cheat_on             ,
      cheat_in              => cheat_in             ,
      cheats_active         => cheats_active        ,
      -- cart interface                            
      cart_ena              => cart_ena,      
      cart_idle             => cart_idle,      
      cart_32               => cart_32,      
      cart_rnw              => cart_rnw,      
      cart_addr             => cart_addr,
      cart_writedata        => cart_writedata,
      cart_writedata32      => cart_writedata32,
      cart_be32             => cart_be32,
      cart_done             => cart_done,
      cart_readdata         => cart_readdata, 
      cart_waitcnt          => cart_waitcnt,
      dma_eepromcount       => dma_eepromcount,
      cart_reset            => cart_reset,
      -- EWRAM in SDRAM
      ewram_ena             => ewram_ena,
      ewram_rnw             => ewram_rnw,
      ewram_addr            => ewram_addr,
      ewram_be              => ewram_be,
      ewram_writedata       => ewram_writedata,
      ewram_done            => ewram_done,
      ewram_readdata        => ewram_readdata,
      -- savestate                                  
      SAVE_out_Din          => SAVE_out_Din         ,
      SAVE_out_Dout         => SAVE_out_Dout        ,
      SAVE_out_Adr          => SAVE_out_Adr         ,
      SAVE_out_rnw          => SAVE_out_rnw         ,
      SAVE_out_ena          => SAVE_out_ena         ,
      SAVE_out_active       => open      ,
      SAVE_out_be           => SAVE_out_be          ,
      SAVE_out_done         => SAVE_out_done        ,
      
      savestate_bus_ext     => savestate_bus_ext    ,
      ss_wired_out_ext      => ss_wired_out_ext     , 
      ss_wired_done_ext     => ss_wired_done_ext    ,
      -- Write to BIOS                              
      bios_wraddr           => bios_wraddr          ,
      bios_wrdata           => bios_wrdata          ,
      bios_wr               => bios_wr              ,
      -- save memory used                           
      load_done             => load_done            ,
      -- Keys                                       
      KeyA                  => KeyA                 ,
      KeyB                  => KeyB                 ,
      KeySelect             => KeySelect            ,
      KeyStart              => KeyStart             ,
      KeyRight              => KeyRight             ,
      KeyLeft               => KeyLeft              ,
      KeyUp                 => KeyUp                ,
      KeyDown               => KeyDown              ,
      KeyR                  => KeyR                 ,
      KeyL                  => KeyL                 ,
      KeyPause              => KeyPause             ,
      -- link port
      link_enable           => link_enable          ,
      link_role_parent      => link_role_parent     ,
      link_clk_out          => c1_link_clk_out      ,
      link_clk_oe           => c1_link_clk_oe       ,
      link_clk_in           => c1_link_clk_in       ,
      link_so_out           => c1_link_so_out       ,
      link_so_oe            => c1_link_so_oe        ,
      link_si_in            => c1_link_si_in        ,
      link_sd_out           => c1_link_sd_out       ,
      link_sd_oe            => c1_link_sd_oe        ,
      link_sd_in            => c1_link_sd_in        ,
      debug_link_state      => c1_debug_link_state  ,
      -- debug interface
      GBA_BusAddr           => GBA_BusAddr          ,
      GBA_BusRnW            => GBA_BusRnW           ,
      GBA_BusACC            => GBA_BusACC           ,
      GBA_BusWriteData      => GBA_BusWriteData     ,
      GBA_BusReadData       => GBA_BusReadData      ,
      GBA_Bus_written       => GBA_Bus_written      ,
      -- display data                               
      pixel_out_x           => pixel_core_x         ,
      pixel_out_y           => pixel_core_y         ,
      pixel_out_data        => pixel_core_data      ,
      pixel_out_we          => pixel_core_we        ,
      vblank_trigger        => vblank_trigger       ,
      -- sound
      sound_out_left        => c1_sound_left        ,
      sound_out_right       => c1_sound_right       ,
      -- debug                                      
      debug_cpu_pc          => debug_cpu_pc         ,
      debug_cpu_mixed       => debug_cpu_mixed      ,
      debug_irq             => debug_irq            ,
      debug_dma             => debug_dma            ,
      debug_mem             => debug_mem            
   );

   process (save_wired_or)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := save_wired_or(0);
      for i in 1 to (save_wired_or'length - 1) loop
         wired_or := wired_or or save_wired_or(i);
      end loop;
      ss_wired_out_ext <= wired_or;
   end process;
   ss_wired_done_ext <= '0' when (save_wired_done = 0) else '1';

   -- clock index
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;
   
   process (clk6x)
   begin
      if rising_edge(clk6x) then
         clk1xToggle6x   <= clk1xToggle;
         clk1xToggle6X_1 <= clk1xToggle6X;
         
         if (clk1xToggle6x = '1' and clk1xToggle6X_1 = '0') then
            clk6xIndex <= "010";
         elsif (clk6xIndex = 5) then
            clk6xIndex <= (others => '0');
         else
            clk6xIndex <= clk6xIndex + 1;
         end if;
      end if;
   end process;
   
   process (clk6x)
   begin
      if rising_edge(clk6x) then
   
         if (memory_remap = '1') then
            MaxPakAddr_modified  <= (others => '1');
            MaxPakAddr2_modified <= (others => '1');
         else
            MaxPakAddr_modified  <= MaxPakAddr;
            MaxPakAddr2_modified <= MaxPakAddr2;
         end if;

      end if;
   end process;

   igba_mem_matrix : entity work.gba_mem_matrix
   generic map
   (
      Softmap_GBA_Gamerom_ADDR     => Softmap_GBA_Gamerom_ADDR,
      Softmap_GBA_Gamerom_Ext_ADDR => Softmap_GBA_Gamerom_Ext_ADDR
   )
   port map
   (
      clk1x            => clk1x,
      reset            => cart_reset,
      active           => big_rom_active,

      cart_ena         => cart_ena,
      cart_rnw         => cart_rnw,
      cart_addr        => cart_addr,
      cart_writedata32 => cart_writedata32,
      cart_be32        => cart_be32,

      remap_hit        => matrix_remap_hit,
      remap_sdram_addr => matrix_remap_addr
   );

   imemorymux_extern : entity work.memorymux_extern
   generic map
   (
      is_simu                  => is_simu,
      Softmap_GBA_Gamerom_ADDR => Softmap_GBA_Gamerom_ADDR,
      Softmap_GBA_Gamerom_Ext_ADDR => Softmap_GBA_Gamerom_Ext_ADDR,
      Softmap_GBA_FLASH_ADDR   => Softmap_GBA_FLASH_ADDR,
      Softmap_GBA_EEPROM_ADDR  => Softmap_GBA_EEPROM_ADDR
   )
   port map
   (
      clk1x                => clk1x,          
      clk6x                => clk6x,          
      clk6xIndex           => clk6xIndex,     
      reset                => cart_reset,     

      SramFlashEnable      => SramFlashEnable,

      error_refresh        => error_refresh,
      flash_busy           => flash_busy,
                                               
      savestate_bus        => savestate_bus_ext,  
      ss_wired_out         => save_wired_or(0),   
      ss_wired_done        => save_wired_done(0),  
                    
      cart_ena             => cart_ena,      
      cart_idle            => cart_idle,      
      cart_32              => cart_32,          
      cart_rnw             => cart_rnw,      
      cart_addr            => cart_addr,     
      cart_writedata       => cart_writedata,
      cart_done            => cart_done,     
      cart_readdata        => cart_readdata, 
      
      cart_waitcnt         => cart_waitcnt,

      ewram_active         => guests_active,
      ewram_allow          => extern_allow,
      hold_ena             => guests_busy,

      sdram_Din            => mmx_sdram_Din,
      sdram_Adr            => mmx_sdram_Adr,
      sdram_rnw            => mmx_sdram_rnw,
      sdram_ena            => mmx_sdram_ena,
      sdram_cancel         => sdram_cancel,
      sdram_refresh        => sdram_refresh,
      sdram_Dout           => sdram_Dout,
      sdram_done16         => sdram_done16,
      sdram_done32         => sdram_done32,
                                             
      specialmodule        => specialmodule,  
      GPIO_readEna         => GPIO_readEna,   
      GPIO_done            => GPIO_done,      
      GPIO_Din             => GPIO_Din,       
      GPIO_Dout            => GPIO_Dout,      
      GPIO_writeEna        => GPIO_writeEna,  
      GPIO_addr            => GPIO_addr,      
                                             
      dma_eepromcount      => dma_eepromcount,
      flash_1m             => GBA_flash_1m,       
      MaxPakAddr           => MaxPakAddr_modified,
      memory_remap         => memory_remap,
      big_rom_active       => big_rom_active,
      matrix_remap_hit     => matrix_remap_hit,
      matrix_remap_addr    => matrix_remap_addr,

      save_eeprom          => save_eeprom,
      save_sram            => save_sram,      
      save_flash           => save_flash,     
                                             
      tilt                 => tilt,
      AnalogTiltX          => AnalogTiltX,
      AnalogTiltY          => AnalogTiltY
   );

   -- guest channel arbitration (see the signal block comment). In the full
   -- profile all guest signals are tied off and this collapses to constants.
   guests_active <= ewram_active or ew2_active or cart2_active;
   guests_busy   <= ewram_busy   or ew2_busy   or cart2_busy;

   ew1_allow     <= extern_allow and (not ew2_busy)     and (not cart2_busy);
   ew2_allow     <= extern_allow and (not ewram_active) and (not cart2_busy);
   cart2_allow   <= extern_allow and (not ewram_active) and (not ew2_active);

   -- core 1 link lines always drive the external port; in internal 2P mode the
   -- top level keeps the SNAC pins released, so this only feeds the OSD path
   link_clk_out <= c1_link_clk_out;
   link_clk_oe  <= c1_link_clk_oe;
   link_so_out  <= c1_link_so_out;
   link_so_oe   <= c1_link_so_oe;
   link_sd_out  <= c1_link_sd_out;
   link_sd_oe   <= c1_link_sd_oe;

   -- paired if generates, not else generate: Quartus 17 VHDL-2008 support is patchy
   gEwramSdram : if (ewram_in_sdram = '1') generate
   begin

      iewram_sdram : entity work.gba_mem_ewram_sdram
      generic map
      (
         Softmap_GBA_EWRAM_ADDR => Softmap_GBA_EWRAM_ADDR
      )
      port map
      (
         clk1x           => clk1x,
         clk6x           => clk6x,
         clk6xIndex      => clk6xIndex,
         reset           => cart_reset,

         ewram_ena       => ewram_ena,
         ewram_rnw       => ewram_rnw,
         ewram_addr      => ewram_addr,
         ewram_be        => ewram_be,
         ewram_writedata => ewram_writedata,
         ewram_done      => ewram_done,
         ewram_readdata  => ewram_readdata,

         ewram_allow     => ew1_allow,
         ewram_active    => ewram_active,
         ewram_busy      => ewram_busy,

         ew_sdram_ena    => ew_sdram_ena,
         ew_sdram_rnw    => ew_sdram_rnw,
         ew_sdram_Adr    => ew_sdram_Adr,
         ew_sdram_Din    => ew_sdram_Din,
         ew_sdram_be     => ew_sdram_be,
         sdram_Dout      => sdram_Dout,
         sdram_done32    => sdram_done32
      );

      -- exactly one channel owns the bus at any time: extern never launches
      -- while a guest op is in flight (hold_ena) and the guests' busy flags
      -- are mutually exclusive by the arbitration above
      sdram_ena <= mmx_sdram_ena or ew_sdram_ena or ew2_sdram_ena or c2_sdram_ena;
      sdram_rnw <= ew_sdram_rnw  when (ewram_busy = '1') else
                   ew2_sdram_rnw when (ew2_busy   = '1') else
                   '1'           when (cart2_busy = '1') else
                   mmx_sdram_rnw;
      sdram_Adr <= ew_sdram_Adr  when (ewram_busy = '1') else
                   ew2_sdram_Adr when (ew2_busy   = '1') else
                   c2_sdram_Adr  when (cart2_busy = '1') else
                   mmx_sdram_Adr;
      sdram_Din <= ew_sdram_Din  when (ewram_busy = '1') else
                   ew2_sdram_Din when (ew2_busy   = '1') else
                   mmx_sdram_Din;
      sdram_be  <= ew_sdram_be   when (ewram_busy = '1') else
                   ew2_sdram_be  when (ew2_busy   = '1') else
                   "1111";

   end generate gEwramSdram;

   gEwramBram : if (ewram_in_sdram = '0') generate
   begin

      sdram_ena <= mmx_sdram_ena;
      sdram_rnw <= mmx_sdram_rnw;
      sdram_Adr <= mmx_sdram_Adr;
      sdram_Din <= mmx_sdram_Din;
      sdram_be  <= "1111";

      ewram_active   <= '0';
      ewram_busy     <= '0';
      ewram_done     <= '0';
      ewram_readdata <= (others => '0');

   end generate gEwramBram;

   gSecondCore : if (second_core = '1') generate
      signal c2_pixel_x       : integer range 0 to 239;
      signal c2_pixel_y       : integer range 0 to 159;
      signal c2_pixel_data    : std_logic_vector(14 downto 0);
      signal c2_pixel_we      : std_logic;
      signal c2_vblank        : std_logic;
      signal c2_sound_left    : std_logic_vector(15 downto 0);
      signal c2_sound_right   : std_logic_vector(15 downto 0);
      signal c2_word          : std_logic_vector(47 downto 0) := (others => '0'); -- pixels 0..2 of the 64bit word in flight
      signal c2_data16        : std_logic_vector(15 downto 0);
      signal c2_xu            : unsigned(7 downto 0);
      -- internal link cable: wired AND of both open drain ends, registered on
      -- clk1x (both cores share the domain; gba_serial wants registered inputs)
      signal l2_sc            : std_logic := '1'; -- SC bus, both ends
      signal l2_sd            : std_logic := '1'; -- SD bus, both ends
      signal l2_si_c1         : std_logic := '1'; -- core 2 SO -> core 1 SI (cable crosses SO/SI)
      signal l2_si_c2         : std_logic := '1'; -- core 1 SO -> core 2 SI
      constant zero_pbus      : std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
   begin

      igba_top2 : entity work.gba_top
      generic map
      (
         Softmap_GBA_Gamerom_ADDR => Softmap_GBA_Gamerom_ADDR,
         Softmap_GBA_FLASH_ADDR   => Softmap_GBA_FLASH_ADDR  ,
         Softmap_GBA_EEPROM_ADDR  => Softmap_GBA_EEPROM_ADDR ,
         Softmap_SaveState_ADDR   => Softmap_SaveState_ADDR  ,
         Softmap_Rewind_ADDR      => Softmap_Rewind_ADDR     ,
         is_simu                  => is_simu                 ,
         strip_savestates         => strip_savestates        ,
         strip_cheats             => strip_cheats            ,
         ewram_in_sdram           => ewram_in_sdram          ,
         turbosound               => turbosound
      )
      port map
      (
         clk1x                 => clk1x                ,
         GBA_on                => GBA_on1X_2           ,
         pause                 => pause or (requestPause and (not is_simu)),
         allowUnpause          => allowUnpause         ,
         inPause               => open                 ,
         GBA_lockspeed         => GBA_lockspeed        ,
         GBA_cputurbo          => GBA_cputurbo         ,
         GBA_flash_1m          => GBA_flash_1m         ,
         Underclock            => Underclock           ,
         CyclesMissing         => open                 ,
         CyclesVsyncSpeed      => open                 ,
         increaseSSHeaderCount => '0'                  ,
         save_state            => '0'                  ,
         load_state            => '0'                  ,
         interframe_blend      => "00"                 ,
         shade_mode            => "000"                ,
         rewind_on             => '0'                  ,
         rewind_active         => '0'                  ,
         savestate_number      => 0                    ,
         -- errors
         error_cpu             => open,
         error_memRequ_timeout => open,
         error_memResp_timeout => open,
         flash_busy            => '0',
         -- cheats
         cheat_clear           => '0',
         cheats_enabled        => '0',
         cheat_on              => '0',
         cheat_in              => 128x"0",
         cheats_active         => open,
         -- cart interface (served by the cart2 guest channel)
         cart_ena              => c2_cart_ena,
         cart_idle             => open,
         cart_32               => c2_cart_32,
         cart_rnw              => c2_cart_rnw,
         cart_addr             => c2_cart_addr,
         cart_writedata        => open,
         cart_done             => c2_cart_done,
         cart_readdata         => c2_cart_readdata,
         cart_waitcnt          => open,
         dma_eepromcount       => open,
         cart_reset            => c2_cart_reset,
         -- EWRAM in SDRAM
         ewram_ena             => ew2_ena,
         ewram_rnw             => ew2_rnw,
         ewram_addr            => ew2_addr,
         ewram_be              => ew2_be,
         ewram_writedata       => ew2_writedata,
         ewram_done            => ew2_done,
         ewram_readdata        => ew2_readdata,
         -- savestate: stripped, only the reset controller remains
         SAVE_out_Din          => open,
         SAVE_out_Dout         => 64x"0",
         SAVE_out_Adr          => open,
         SAVE_out_rnw          => open,
         SAVE_out_ena          => open,
         SAVE_out_active       => open,
         SAVE_out_be           => open,
         SAVE_out_done         => '0',
         savestate_bus_ext     => open,
         ss_wired_out_ext      => zero_pbus,
         ss_wired_done_ext     => '0',
         -- Write to BIOS: same download as core 1, BIOS is duplicated for now
         bios_wraddr           => bios_wraddr,
         bios_wrdata           => bios_wrdata,
         bios_wr               => bios_wr,
         load_done             => open,
         -- Keys: player 2
         KeyA                  => Key2A,
         KeyB                  => Key2B,
         KeySelect             => Key2Select,
         KeyStart              => Key2Start,
         KeyRight              => Key2Right,
         KeyLeft               => Key2Left,
         KeyUp                 => Key2Up,
         KeyDown               => Key2Down,
         KeyR                  => Key2R,
         KeyL                  => Key2L,
         KeyPause              => '0',
         -- link port: internal cable only, core 2 is always the child
         link_enable           => link_2p,
         link_role_parent      => '0',
         link_clk_out          => c2_link_clk_out,
         link_clk_oe           => c2_link_clk_oe,
         link_clk_in           => c2_link_clk_in,
         link_so_out           => c2_link_so_out,
         link_so_oe            => c2_link_so_oe,
         link_si_in            => c2_link_si_in,
         link_sd_out           => c2_link_sd_out,
         link_sd_oe            => c2_link_sd_oe,
         link_sd_in            => c2_link_sd_in,
         debug_link_state      => c2_debug_link_state,
         -- debug interface
         GBA_BusAddr           => 28x"0",
         GBA_BusRnW            => '1',
         GBA_BusACC            => "00",
         GBA_BusWriteData      => 32x"0",
         GBA_BusReadData       => open,
         GBA_Bus_written       => '0',
         -- display data: composed onto the right half of the shared screen
         pixel_out_x           => c2_pixel_x,
         pixel_out_y           => c2_pixel_y,
         pixel_out_data        => c2_pixel_data,
         pixel_out_we          => c2_pixel_we,
         vblank_trigger        => c2_vblank,
         -- sound
         sound_out_left        => c2_sound_left,
         sound_out_right       => c2_sound_right,
         -- debug
         debug_cpu_pc          => open,
         debug_cpu_mixed       => open,
         debug_irq             => open,
         debug_dma             => open,
         debug_mem             => open
      );

      iewram2_sdram : entity work.gba_mem_ewram_sdram
      generic map
      (
         Softmap_GBA_EWRAM_ADDR => Softmap_GBA_EWRAM2_ADDR
      )
      port map
      (
         clk1x           => clk1x,
         clk6x           => clk6x,
         clk6xIndex      => clk6xIndex,
         reset           => c2_cart_reset,

         ewram_ena       => ew2_ena,
         ewram_rnw       => ew2_rnw,
         ewram_addr      => ew2_addr,
         ewram_be        => ew2_be,
         ewram_writedata => ew2_writedata,
         ewram_done      => ew2_done,
         ewram_readdata  => ew2_readdata,

         ewram_allow     => ew2_allow,
         ewram_active    => ew2_active,
         ewram_busy      => ew2_busy,

         ew_sdram_ena    => ew2_sdram_ena,
         ew_sdram_rnw    => ew2_sdram_rnw,
         ew_sdram_Adr    => ew2_sdram_Adr,
         ew_sdram_Din    => ew2_sdram_Din,
         ew_sdram_be     => ew2_sdram_be,
         sdram_Dout      => sdram_Dout,
         sdram_done32    => sdram_done32
      );

      icart2_sdram : entity work.gba_mem_cart2_sdram
      generic map
      (
         Softmap_GBA_Gamerom_ADDR  => Softmap_GBA_Gamerom_ADDR,
         Softmap_GBA_Gamerom2_ADDR => Softmap_GBA_Gamerom2_ADDR
      )
      port map
      (
         clk1x           => clk1x,
         clk6x           => clk6x,
         clk6xIndex      => clk6xIndex,
         reset           => c2_cart_reset,

         memory_remap    => memory_remap,
         MaxPakAddr      => MaxPakAddr2_modified,
         rom_shared      => rom_shared,

         cart_ena        => c2_cart_ena,
         cart_32         => c2_cart_32,
         cart_rnw        => c2_cart_rnw,
         cart_addr       => c2_cart_addr,
         cart_done       => c2_cart_done,
         cart_readdata   => c2_cart_readdata,

         cart_allow      => cart2_allow,
         cart_active     => cart2_active,
         cart_busy       => cart2_busy,

         c2_sdram_ena    => c2_sdram_ena,
         c2_sdram_Adr    => c2_sdram_Adr,
         sdram_Dout      => sdram_Dout,
         sdram_done32    => sdram_done32
      );

      -- internal link cable: open drain wired AND of both ends. SO/SI cross
      -- over like a real cable, SC and SD are shared bus lines. Registered on
      -- clk1x as the synchronizer stage gba_serial expects.
      process (clk1x)
      begin
         if rising_edge(clk1x) then
            l2_sc    <= (c1_link_clk_out or not c1_link_clk_oe) and (c2_link_clk_out or not c2_link_clk_oe);
            l2_sd    <= (c1_link_sd_out  or not c1_link_sd_oe ) and (c2_link_sd_out  or not c2_link_sd_oe );
            l2_si_c1 <= (c2_link_so_out  or not c2_link_so_oe );
            l2_si_c2 <= (c1_link_so_out  or not c1_link_so_oe );
         end if;
      end process;

      c1_link_clk_in <= l2_sc    when (link_2p = '1') else link_clk_in;
      c1_link_si_in  <= l2_si_c1 when (link_2p = '1') else link_si_in;
      c1_link_sd_in  <= l2_sd    when (link_2p = '1') else link_sd_in;

      c2_link_clk_in <= l2_sc;
      c2_link_si_in  <= l2_si_c2;
      c2_link_sd_in  <= l2_sd;

      -- core 2 pixels get the same shading as core 1 and go to their own
      -- framebuffer set at byte 0x8080000 via the second GPU write channel
      igba_gpu_colorshade2 : entity work.gba_gpu_colorshade
      port map
      (
         clk                  => clk1x,

         shade_mode           => shader_mode,

         pixel_in_x           => c2_pixel_x,
         pixel_in_y           => c2_pixel_y,
         pixel_in_data        => c2_pixel_data,
         pixel_in_we          => c2_pixel_we,

         pixel_out_x          => pixel2_shade_x,
         pixel_out_y          => pixel2_shade_y,
         pixel_out_data       => pixel2_shade_data,
         pixel_out_we         => pixel2_shade_we
      );

      -- pack 4 pixels into one fifo entry: the GPU rasters x = 0..239 in
      -- order, so pixels 0..2 of each word are collected and pixel 3 pushes
      -- the whole word combinationally - the frame index must be sampled in
      -- the same cycle the last pixel of a frame flips it (core 1 idiom)
      c2_xu     <= to_unsigned(pixel2_shade_x, 8);
      c2_data16 <= '0' & pixel2_shade_data(17 downto 13) & pixel2_shade_data(11 downto 7) & pixel2_shade_data(5 downto 1);

      process (clk1x)
      begin
         if rising_edge(clk1x) then
            if (pixel2_shade_we = '1') then
               case (c2_xu(1 downto 0)) is
                  when "00"   => c2_word(15 downto  0) <= c2_data16;
                  when "01"   => c2_word(31 downto 16) <= c2_data16;
                  when "10"   => c2_word(47 downto 32) <= c2_data16;
                  when others => null;
               end case;
            end if;
         end if;
      end process;

      gpufifo2_Din <= gpufifo2_Frame & std_logic_vector(to_unsigned(pixel2_shade_y, 8)) & std_logic_vector(c2_xu(7 downto 2)) & c2_data16 & c2_word;
      gpufifo2_Wr  <= pixel2_shade_we when (c2_xu(1 downto 0) = "11") else '0';

      -- audio select, registered: sources are independent free running cores
      process (clk1x)
      begin
         if rising_edge(clk1x) then
            case (sound2_select) is
               when "01" =>
                  sound_out_left  <= c2_sound_left;
                  sound_out_right <= c2_sound_right;
               when "10" =>
                  sound_out_left  <= std_logic_vector(signed(c1_sound_left(15)  & c1_sound_left(15 downto 1))  + signed(c2_sound_left(15)  & c2_sound_left(15 downto 1)));
                  sound_out_right <= std_logic_vector(signed(c1_sound_right(15) & c1_sound_right(15 downto 1)) + signed(c2_sound_right(15) & c2_sound_right(15 downto 1)));
               when "11" =>
                  -- stereo split: each core downmixed to mono, P1 in the
                  -- left ear, P2 in the right
                  sound_out_left  <= std_logic_vector(signed(c1_sound_left(15)  & c1_sound_left(15 downto 1))  + signed(c1_sound_right(15) & c1_sound_right(15 downto 1)));
                  sound_out_right <= std_logic_vector(signed(c2_sound_left(15)  & c2_sound_left(15 downto 1))  + signed(c2_sound_right(15) & c2_sound_right(15 downto 1)));
               when others =>
                  sound_out_left  <= c1_sound_left;
                  sound_out_right <= c1_sound_right;
            end case;
         end if;
      end process;

   end generate gSecondCore;

   gNoSecondCore : if (second_core = '0') generate
   begin

      c1_link_clk_in <= link_clk_in;
      c1_link_si_in  <= link_si_in;
      c1_link_sd_in  <= link_sd_in;

      ew2_active    <= '0';
      ew2_busy      <= '0';
      ew2_sdram_ena <= '0';
      ew2_sdram_rnw <= '0';
      ew2_sdram_Adr <= (others => '0');
      ew2_sdram_Din <= (others => '0');
      ew2_sdram_be  <= (others => '0');
      ew2_done      <= '0';
      ew2_readdata  <= (others => '0');

      cart2_active  <= '0';
      cart2_busy    <= '0';
      c2_sdram_ena  <= '0';
      c2_sdram_Adr  <= (others => '0');
      c2_cart_done  <= '0';
      c2_cart_readdata <= (others => '0');

      pixel2_shade_x    <= 0;
      pixel2_shade_y    <= 0;
      pixel2_shade_data <= (others => '0');
      pixel2_shade_we   <= '0';
      gpufifo2_Din      <= (others => '0');
      gpufifo2_Wr       <= '0';

      sound_out_left  <= c1_sound_left;
      sound_out_right <= c1_sound_right;

   end generate gNoSecondCore;

   igba_gpioRTCSolarGyro : entity work.gba_gpioRTCSolarGyro
   port map
   (
      clk1x                => clk1x,
      reset                => cart_reset,
      GBA_on               => GBA_on,
      rtc_noselect_quirk   => rtc_noselect_quirk,

      savestate_bus        => savestate_bus_ext,
      ss_wired_out         => save_wired_or(1),
      ss_wired_done        => save_wired_done(1),
                                         
      GPIO_readEna         => GPIO_readEna, 
      GPIO_done            => GPIO_done,   
      GPIO_Din             => GPIO_Din,     
      GPIO_Dout            => GPIO_Dout,    
      GPIO_writeEna        => GPIO_writeEna,
      GPIO_addr            => GPIO_addr,
      
      RTC_timestampNew     => RTC_timestampNew,
      RTC_timestampIn      => RTC_timestampIn,   
      RTC_timestampSaved   => RTC_timestampSaved,
      RTC_savedtimeIn      => RTC_savedtimeIn,   
      RTC_saveLoaded       => RTC_saveLoaded,    
      RTC_timestampOut     => RTC_timestampOut,  
      RTC_savedtimeOut     => RTC_savedtimeOut,  
      RTC_inuse            => RTC_inuse,         

      rumble               => Rumble,
      AnalogX              => AnalogTiltX,
      solar_in             => solar_in
   );
   
   shader_mode <= shade_mode when (unsigned(shade_mode) < 5) else "000";
   igba_gpu_colorshade : entity work.gba_gpu_colorshade
   port map
   (
      clk                  => clk1x,
                           
      shade_mode           => shader_mode,
                           
      pixel_in_x           => pixel_core_x,   
      pixel_in_y           => pixel_core_y,   
      pixel_in_data        => pixel_core_data,
      pixel_in_we          => pixel_core_we,
                  
      pixel_out_x          => pixel_shade_x,     
      pixel_out_y          => pixel_shade_y,  
      pixel_out_data       => pixel_shade_data,
      pixel_out_we         => pixel_shade_we  
   );   
   
   inPause <= inPauseCore;
   
   ivideoout160 : entity work.videoout160
   generic map
   (
      dual                    => second_core
   )
   port map
   (
      clk1x                   => clk1x,
      clk3x                   => clk3x,

      blend                   => interframe_blend(0),
      borderOn                => borderOn,
      videoHshift             => videoHshift,
      videoVshift             => videoVshift,

      pixel_x                 => pixel_shade_x,
      pixel_y                 => pixel_shade_y,
      pixel_we                => pixel_shade_we,
      vblank_trigger          => vblank_trigger,

      pixel2_x                => pixel2_shade_x,
      pixel2_y                => pixel2_shade_y,
      pixel2_we               => pixel2_shade_we,

      display_select          => display2p_select,
      separator_on            => separator_line,

      nextFrame_out           => gpufifo_Frame,
      nextFrame2_out          => gpufifo2_Frame,

      inPause                 => inPauseCore,
      requestPause            => requestPause,
      allowUnpause            => allowUnpause,

      ddr3_request            => rdram_request(DDR3MUX_VIDEOOUT),
      ddr3_address            => rdram_address(DDR3MUX_VIDEOOUT),
      ddr3_burstcnt           => rdram_burstcount(DDR3MUX_VIDEOOUT),
      ddr3_ready              => rdram_ready(DDR3MUX_VIDEOOUT),
      ddr3_done               => rdram_done(DDR3MUX_VIDEOOUT),
      ddr3_data               => ddr3_DOUT,
      
      videoout_hsync          => videoout_hsync,    
      videoout_vsync          => videoout_vsync,    
      videoout_hblank         => videoout_hblank,   
      videoout_vblank         => videoout_vblank,   
      videoout_ce             => videoout_ce,       
      videoout_interlace      => videoout_interlace,
      videoout_r              => colorR,        
      videoout_g              => colorG,        
      videoout_b              => colorB        
   );

   luma   <= "00" & colorR(7 downto 2) + colorG(7 downto 1) + colorG(7 downto 3) + colorB(7 downto 3);
   
   colorRdesat <= '0' & colorR(7 downto 1) + colorR(7 downto 2) +   luma(7 downto 2) when (shade_mode = "101") else 
                  '0' & colorR(7 downto 1) +   luma(7 downto 1)                      when (shade_mode = "110") else 
                  '0' &   luma(7 downto 1) +   luma(7 downto 2) + colorR(7 downto 2) when (shade_mode = "111") else 
                  colorR;
  
   colorGdesat <= '0' & colorG(7 downto 1) + colorG(7 downto 2) +   luma(7 downto 2) when (shade_mode = "101") else 
                  '0' & colorG(7 downto 1) +   luma(7 downto 1)                      when (shade_mode = "110") else 
                  '0' &   luma(7 downto 1) +   luma(7 downto 2) + colorG(7 downto 2) when (shade_mode = "111") else 
                  colorG;

   colorBdesat <= '0' & colorB(7 downto 1) + colorB(7 downto 2) +   luma(7 downto 2) when (shade_mode = "101") else 
                  '0' & colorB(7 downto 1) +   luma(7 downto 1)                      when (shade_mode = "110") else 
                  '0' &   luma(7 downto 1) +   luma(7 downto 2) + colorB(7 downto 2) when (shade_mode = "111") else 
                  colorB;                 
   
   videoout_r <= std_logic_vector(colorRdesat);
   videoout_g <= std_logic_vector(colorGdesat);
   videoout_b <= std_logic_vector(colorBdesat);
   
   
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (cart_reset = '1') then
            errorCode <= (others => '0');
         else
            if (error_cpu = '1')             then errorCode(0) <= '1'; end if;
            if (error_memRequ_timeout = '1') then errorCode(1) <= '1'; end if;
            if (error_memResp_timeout = '1') then errorCode(2) <= '1'; end if;
            if (error_refresh = '1')         then errorCode(3) <= '1'; end if;
         end if;
      end if;
   end process;
   
   errortext( 7 downto  0) <= resize(errorCode( 3 downto  0), 8) + 16#30# when (errorCode( 3 downto  0) < 10) else resize(errorCode( 3 downto  0), 8) + 16#37#;
   errortext(15 downto  8) <= resize(errorCode( 7 downto  4), 8) + 16#30# when (errorCode( 7 downto  4) < 10) else resize(errorCode( 7 downto  4), 8) + 16#37#;
   errortext(23 downto 16) <= resize(errorCode(11 downto  8), 8) + 16#30# when (errorCode(11 downto  8) < 10) else resize(errorCode(11 downto  8), 8) + 16#37#;
   errortext(31 downto 24) <= resize(errorCode(15 downto 12), 8) + 16#30# when (errorCode(15 downto 12) < 10) else resize(errorCode(15 downto 12), 8) + 16#37#;
   
   errorEna <= '1' when (errorCode /= x"0000" and overlay_error_on = '1') else '0';
   
   ioverlayError : entity work.overlay generic map (5, 2, 2, 15x"7C00", 15x"7FFF")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => errorEna,                    
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_error_data,
      o_pixel_out_ena        => overlay_error_ena,
      textstring             => x"45" & errortext
   );

   -- Temporary hardware diagnostic: on-screen link debug overlay, showing
   -- both cores' ENGINE_MULTI state ("Cn S<SIO_start> M<multisendmode>
   -- B<startbitreceived> E<hex exchange count> D<SD wire> K<SC wire>") so
   -- the real-hardware link-establishment bug can be diagnosed by
   -- photographing the screen. Remove once root-caused.
   linkdebugEna <= link_enable and overlay_link_on;

   c1_ch_S <= x"31" when c1_debug_link_state(6) = '1' else x"30";
   c1_ch_M <= x"31" when c1_debug_link_state(5) = '1' else x"30";
   c1_ch_B <= x"31" when c1_debug_link_state(4) = '1' else x"30";
   c1_ch_E <= hexchar(c1_debug_link_state(3 downto 0));
   c1_ch_D <= x"31" when c1_link_sd_in  = '1' else x"30";
   c1_ch_K <= x"31" when c1_link_clk_in = '1' else x"30";
   c1_ch_R3 <= hexchar(c1_debug_link_state(22 downto 19));
   c1_ch_R2 <= hexchar(c1_debug_link_state(18 downto 15));
   c1_ch_R1 <= hexchar(c1_debug_link_state(14 downto 11));
   c1_ch_R0 <= hexchar(c1_debug_link_state(10 downto  7));
   c1_ch_T3 <= hexchar(c1_debug_link_state(38 downto 35));
   c1_ch_T2 <= hexchar(c1_debug_link_state(34 downto 31));
   c1_ch_T1 <= hexchar(c1_debug_link_state(30 downto 27));
   c1_ch_T0 <= hexchar(c1_debug_link_state(26 downto 23));
   c1_ch_M23 <= hexchar(c1_debug_link_state(54 downto 51));
   c1_ch_M22 <= hexchar(c1_debug_link_state(50 downto 47));
   c1_ch_M21 <= hexchar(c1_debug_link_state(46 downto 43));
   c1_ch_M20 <= hexchar(c1_debug_link_state(42 downto 39));
   c1_ch_M33 <= hexchar(c1_debug_link_state(70 downto 67));
   c1_ch_M32 <= hexchar(c1_debug_link_state(66 downto 63));
   c1_ch_M31 <= hexchar(c1_debug_link_state(62 downto 59));
   c1_ch_M30 <= hexchar(c1_debug_link_state(58 downto 55));

   c2_ch_S <= x"31" when c2_debug_link_state(6) = '1' else x"30";
   c2_ch_M <= x"31" when c2_debug_link_state(5) = '1' else x"30";
   c2_ch_B <= x"31" when c2_debug_link_state(4) = '1' else x"30";
   c2_ch_E <= hexchar(c2_debug_link_state(3 downto 0));
   c2_ch_D <= x"31" when c2_link_sd_in  = '1' else x"30";
   c2_ch_K <= x"31" when c2_link_clk_in = '1' else x"30";
   c2_ch_R3 <= hexchar(c2_debug_link_state(22 downto 19));
   c2_ch_R2 <= hexchar(c2_debug_link_state(18 downto 15));
   c2_ch_R1 <= hexchar(c2_debug_link_state(14 downto 11));
   c2_ch_R0 <= hexchar(c2_debug_link_state(10 downto  7));
   c2_ch_T3 <= hexchar(c2_debug_link_state(38 downto 35));
   c2_ch_T2 <= hexchar(c2_debug_link_state(34 downto 31));
   c2_ch_T1 <= hexchar(c2_debug_link_state(30 downto 27));
   c2_ch_T0 <= hexchar(c2_debug_link_state(26 downto 23));
   c2_ch_M23 <= hexchar(c2_debug_link_state(54 downto 51));
   c2_ch_M22 <= hexchar(c2_debug_link_state(50 downto 47));
   c2_ch_M21 <= hexchar(c2_debug_link_state(46 downto 43));
   c2_ch_M20 <= hexchar(c2_debug_link_state(42 downto 39));
   c2_ch_M33 <= hexchar(c2_debug_link_state(70 downto 67));
   c2_ch_M32 <= hexchar(c2_debug_link_state(66 downto 63));
   c2_ch_M31 <= hexchar(c2_debug_link_state(62 downto 59));
   c2_ch_M30 <= hexchar(c2_debug_link_state(58 downto 55));

   -- Split across two short rows per core -- overlay.vhd's char renderer
   -- spends 10 pixel columns per character (7 glyph + 2 wait + 1 advance),
   -- and there are only ~237 usable columns after OFFSETX=2, capping any
   -- single row at ~23 characters. A single 29-char row silently truncated
   -- mid-line; each row here is well under that limit.
   -- Row A: "Cn S. M. B. E. D. K." (handshake state + wire levels)
   -- Row B: "T:xxxx R:xxxx" -- T is what this core intends to send
   -- (REG_SIODATA8), R is the last value actually received (SIOMULTI1_RB).
   -- Row C: "2:xxxx 3:xxxx" -- live SIOMULTI2_RB/SIOMULTI3_RB readback.
   -- Both must show FFFF in 2P link mode (units 2/3 don't exist on the
   -- cable); anything else means the game counts phantom players and the
   -- bug is on the RTL side rather than in the CPU's bus decode.
   c1_linktext <= x"43" & x"31" & x"20" &
                  x"53" & c1_ch_S & x"20" &
                  x"4D" & c1_ch_M & x"20" &
                  x"42" & c1_ch_B & x"20" &
                  x"45" & c1_ch_E & x"20" &
                  x"44" & c1_ch_D & x"20" &
                  x"4B" & c1_ch_K;
   c1_datatext <= x"54" & x"3A" & c1_ch_T3 & c1_ch_T2 & c1_ch_T1 & c1_ch_T0 & x"20" &
                  x"52" & x"3A" & c1_ch_R3 & c1_ch_R2 & c1_ch_R1 & c1_ch_R0;
   c1_multitext <= x"32" & x"3A" & c1_ch_M23 & c1_ch_M22 & c1_ch_M21 & c1_ch_M20 & x"20" &
                   x"33" & x"3A" & c1_ch_M33 & c1_ch_M32 & c1_ch_M31 & c1_ch_M30;

   c2_linktext <= x"43" & x"32" & x"20" &
                  x"53" & c2_ch_S & x"20" &
                  x"4D" & c2_ch_M & x"20" &
                  x"42" & c2_ch_B & x"20" &
                  x"45" & c2_ch_E & x"20" &
                  x"44" & c2_ch_D & x"20" &
                  x"4B" & c2_ch_K;
   c2_datatext <= x"54" & x"3A" & c2_ch_T3 & c2_ch_T2 & c2_ch_T1 & c2_ch_T0 & x"20" &
                  x"52" & x"3A" & c2_ch_R3 & c2_ch_R2 & c2_ch_R1 & c2_ch_R0;
   c2_multitext <= x"32" & x"3A" & c2_ch_M23 & c2_ch_M22 & c2_ch_M21 & c2_ch_M20 & x"20" &
                   x"33" & x"3A" & c2_ch_M33 & c2_ch_M32 & c2_ch_M31 & c2_ch_M30;

   ioverlayLink1 : entity work.overlay generic map (20, 2, 20, 15x"03E0", 15x"0000")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => linkdebugEna,
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_link1_data,
      o_pixel_out_ena        => overlay_link1_ena,
      textstring             => c1_linktext
   );

   ioverlayLinkData1 : entity work.overlay generic map (13, 2, 40, 15x"03E0", 15x"0000")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => linkdebugEna,
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_data1_data,
      o_pixel_out_ena        => overlay_data1_ena,
      textstring             => c1_datatext
   );

   ioverlayMulti1 : entity work.overlay generic map (13, 2, 60, 15x"03E0", 15x"0000")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => linkdebugEna,
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_multi1_data,
      o_pixel_out_ena        => overlay_multi1_ena,
      textstring             => c1_multitext
   );

   ioverlayLink2 : entity work.overlay generic map (20, 2, 80, 15x"7FE0", 15x"0000")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => linkdebugEna,
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_link2_data,
      o_pixel_out_ena        => overlay_link2_ena,
      textstring             => c2_linktext
   );

   ioverlayLinkData2 : entity work.overlay generic map (13, 2, 100, 15x"7FE0", 15x"0000")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => linkdebugEna,
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_data2_data,
      o_pixel_out_ena        => overlay_data2_ena,
      textstring             => c2_datatext
   );

   ioverlayMulti2 : entity work.overlay generic map (13, 2, 120, 15x"7FE0", 15x"0000")
   port map
   (
      clk                    => clk1x,
      ce                     => '1',
      ena                    => linkdebugEna,
      i_pixel_out_x          => pixel_out_x,
      i_pixel_out_y          => pixel_out_y,
      o_pixel_out_data       => overlay_multi2_data,
      o_pixel_out_ena        => overlay_multi2_ena,
      textstring             => c2_multitext
   );

   pixel_out_x    <= pixel_shade_x;
   pixel_out_y    <= pixel_shade_y;
   pixel_out_we   <= pixel_shade_we;
   pixel_out_data <= overlay_error_data  when (overlay_error_ena = '1')  else
                     overlay_link1_data  when (overlay_link1_ena = '1')  else
                     overlay_data1_data  when (overlay_data1_ena = '1')  else
                     overlay_multi1_data when (overlay_multi1_ena = '1') else
                     overlay_link2_data  when (overlay_link2_ena = '1')  else
                     overlay_data2_data  when (overlay_data2_ena = '1')  else
                     overlay_multi2_data when (overlay_multi2_ena = '1') else
                     pixel_shade_data(17 downto 13) & pixel_shade_data(11 downto 7) & pixel_shade_data(5 downto 1);
   
   rdram_rnw(DDR3MUX_VIDEOOUT)        <= '1';
   rdram_writeMask(DDR3MUX_VIDEOOUT)  <= x"FF";
   rdram_dataWrite(DDR3MUX_VIDEOOUT)  <= 64x"0";
   
   rdram_request(DDR3MUX_SS)    <= SAVE_out_ena;
   rdram_rnw(DDR3MUX_SS)        <= SAVE_out_rnw;
   rdram_address(DDR3MUX_SS)    <= unsigned(SAVE_out_Adr) & "00";
   rdram_burstcount(DDR3MUX_SS) <= 10x"01";
   rdram_writeMask(DDR3MUX_SS)  <= SAVE_out_be;
   rdram_dataWrite(DDR3MUX_SS)  <= SAVE_out_Din;
   SAVE_out_done                <= rdram_ready(DDR3MUX_SS) when (SAVE_out_rnw = '1') else rdram_done(DDR3MUX_SS);
   SAVE_out_Dout                <= ddr3_DOUT;
   
   gpufifo_reset  <= '0';
   gpufifo_Din    <= gpufifo_Frame & std_logic_vector(to_unsigned(pixel_out_y,8)) & std_logic_vector(to_unsigned(pixel_out_x,8)) & '0' & pixel_out_data;
   gpufifo_Wr     <= pixel_out_we;
   
   iDDR3Mux : entity work.DDR3Mux
   generic map
   (
      gpufifo2_en      => second_core
   )
   port map
   (
      clk1x            => clk1x,
      
      error            => open,
      error_fifo       => open,

      ddr3_BUSY        => ddr3_BUSY,       
      ddr3_DOUT        => ddr3_DOUT,       
      ddr3_DOUT_READY  => ddr3_DOUT_READY, 
      ddr3_BURSTCNT    => ddr3_BURSTCNT,   
      ddr3_ADDR        => ddr3_ADDR,       
      ddr3_DIN         => ddr3_DIN,        
      ddr3_BE          => ddr3_BE,         
      ddr3_WE          => ddr3_WE,         
      ddr3_RD          => ddr3_RD,         
                       
      rdram_request    => rdram_request,   
      rdram_rnw        => rdram_rnw,       
      rdram_address    => rdram_address,   
      rdram_burstcount => rdram_burstcount,
      rdram_writeMask  => rdram_writeMask, 
      rdram_dataWrite  => rdram_dataWrite, 
      rdram_granted    => rdram_granted,   
      rdram_done       => rdram_done,      
      rdram_ready      => rdram_ready,      
      rdram_dataRead   => rdram_dataRead,  
                       
      gpufifo_reset    => gpufifo_reset,
      gpufifo_Din      => gpufifo_Din,
      gpufifo_Wr       => gpufifo_Wr,
      gpufifo_nearfull => gpufifo_nearfull,
      gpufifo_empty    => gpufifo_empty,

      gpufifo2_Din     => gpufifo2_Din,
      gpufifo2_Wr      => gpufifo2_Wr,
      gpufifo2_empty   => open
   );
   
   rdram_rnw(DDR3MUX_ROMCOPY)        <= '1';
   rdram_burstcount(DDR3MUX_ROMCOPY) <= 10x"01";
   rdram_writeMask(DDR3MUX_ROMCOPY)  <= x"FF";
   rdram_dataWrite(DDR3MUX_ROMCOPY)  <= 64x"0";

   -- Per-core power-on derivation. Both still gate off the shared GBA_on (any
   -- HPS download/reset holds both off, as before). On top of that:
   -- core 1 rides through a copy only if that copy doesn't target its own
   -- window (i.e. a LOAD_2P-only copy never touches core 1);
   -- core 2 rides through a copy only if it's independent (rom_shared='0')
   -- AND the copy is a LOAD_1P one that doesn't target its window either --
   -- every other combination means core 2's window is either being written
   -- right now or about to be viewed through a freshly-flipped rom_shared,
   -- so it needs to reboot too. Both terms key off the FSM's own
   -- ROMCOPYSTATE=IDLE check (unchanged, still correct: no outstanding
   -- unacked write when IDLE is reached, see ROMCOPY_WRITESDRAM4).
   process (clk1x)
   begin
      if (rising_edge(clk1x)) then

         GBA_on1X_1 <= '0';
         if (GBA_on = '1' and core1_power = '1' and core1_reset = '0' and
             (ROMCOPYSTATE = ROMCOPY_IDLE or romcopy_target_core2 = '1')) then
            GBA_on1X_1 <= '1';
         end if;

         GBA_on1X_2 <= '0';
         if (GBA_on = '1' and core2_power = '1' and core2_reset = '0' and
             (ROMCOPYSTATE = ROMCOPY_IDLE or (rom_shared = '0' and romcopy_target_core2 = '0'))) then
            GBA_on1X_2 <= '1';
         end if;

      end if;
   end process;

   process (clk6x)
   begin
      if (rising_edge(clk6x)) then
      
         if (clk6xIndex = 5) then
            rdram_request(DDR3MUX_ROMCOPY) <= '0'; 
         end if;
         rom_wr      <= '0';
         romcopy_req <= '0';
         
         case (ROMCOPYSTATE) is
         
            when ROMCOPY_IDLE =>
               rom_copy <= '0';
               rdram_address(DDR3MUX_ROMCOPY) <= x"0080000";
               rom_addr                       <= (others => '0');
               romcopy_writepos               <= 27x"0000000";
               if (romcopy_start = '1') then
                  rom_copy             <= '1';
                  romcopy_target_core2 <= romcopy_dest_is_core2;
                  if (romcopy_dest_is_core2 = '1') then
                     -- core 2's independent window has no save-staging area
                     -- to clear (core 2 has no save memory) -- skip straight
                     -- to the DDR3-read/SDRAM-write loop at its own base.
                     romcopy_writepos               <= std_logic_vector(to_unsigned(Softmap_GBA_Gamerom2_ADDR, 27));
                     ROMCOPYSTATE                   <= ROMCOPY_READDDR3;
                     rdram_request(DDR3MUX_ROMCOPY) <= '1';
                  else
                     ROMCOPYSTATE <= ROMCOPY_CLEANSAVERAM;
                     romcopy_req  <= '1';
                     romcopy_data <= (others => '1');
                  end if;
               end if;
               
            when ROMCOPY_CLEANSAVERAM =>
               if (sdram_done16 = '1') then
                  romcopy_writepos <= std_logic_vector(unsigned(romcopy_writepos) + 4);
                  if (romcopy_writepos = 27x"007FFFC") then
                     ROMCOPYSTATE                   <= ROMCOPY_READDDR3;
                     rdram_request(DDR3MUX_ROMCOPY) <= '1';
                  else
                     romcopy_req      <= '1';
                  end if;
               end if;

            when ROMCOPY_READDDR3 => 
               if (rdram_done(DDR3MUX_ROMCOPY) = '1') then
                  ROMCOPYSTATE      <= ROMCOPY_WRITESDRAM1;
                  romcopy_writedata <= rdram_dataRead;
                  rdram_address(DDR3MUX_ROMCOPY) <= rdram_address(DDR3MUX_ROMCOPY) + 8;
               end if;
               
            when ROMCOPY_WRITESDRAM1 => 
               ROMCOPYSTATE <= ROMCOPY_WRITESDRAM2; 
               rom_wr       <= '1';
               rom_dout     <= romcopy_writedata(15 downto 0); 
               romcopy_writedata(47 downto 0) <= romcopy_writedata(63 downto 16);
               romcopy_req  <= '1';
               romcopy_data <= romcopy_writedata(31 downto 0); 
            
            when ROMCOPY_WRITESDRAM2 =>   
               if (sdram_done16 = '1') then
                  ROMCOPYSTATE     <= ROMCOPY_WRITESDRAM3; 
                  rom_wr           <= '1';
                  rom_dout         <= romcopy_writedata(15 downto 0);
                  rom_addr         <= std_logic_vector(unsigned(rom_addr) + 2);      
                  romcopy_writepos <= std_logic_vector(unsigned(romcopy_writepos) + 4);      
                  romcopy_writedata(47 downto 0) <= romcopy_writedata(63 downto 16);
               end if;
               
            when ROMCOPY_WRITESDRAM3 =>   
               ROMCOPYSTATE <= ROMCOPY_WRITESDRAM4; 
               rom_wr       <= '1';
               rom_dout     <= romcopy_writedata(15 downto 0);
               rom_addr     <= std_logic_vector(unsigned(rom_addr) + 2);      
               romcopy_writedata(47 downto 0) <= romcopy_writedata(63 downto 16);
               romcopy_req  <= '1';
               romcopy_data <= romcopy_writedata(31 downto 0);
               
            when ROMCOPY_WRITESDRAM4 =>   
               if (sdram_done16 = '1') then
                  ROMCOPYSTATE <= ROMCOPY_NEXT; 
                  rom_wr       <= '1';
                  rom_dout     <= romcopy_writedata(15 downto 0);
                  rom_addr     <= std_logic_vector(unsigned(rom_addr) + 2); 
                                
               end if;
            
            when ROMCOPY_NEXT =>
               rom_addr         <= std_logic_vector(unsigned(rom_addr) + 2);
               -- >32MB Matrix carts (Shrek etc): the source file is a single contiguous
               -- stream, but its second 32MB half lands in the separate
               -- Softmap_GBA_Gamerom_Ext_ADDR window (chosen to sit after Rewind's buffer,
               -- not contiguous with Gamerom_ADDR+32MB -- see that generic's comment in
               -- gba_wrap's port list). Without this jump, everything past 32MB would keep
               -- streaming into whatever lives right after the first 32MB (EWRAM/SaveState/
               -- Rewind), and the Ext window big_rom_active reads from would stay unwritten.
               if (Softmap_GBA_Gamerom_Ext_ADDR /= 0 and romcopy_target_core2 = '0' and
                   (unsigned(rom_addr) + 2) = 33554432) then
                  romcopy_writepos <= std_logic_vector(to_unsigned(Softmap_GBA_Gamerom_Ext_ADDR, 27));
               else
                  romcopy_writepos <= std_logic_vector(unsigned(romcopy_writepos) + 4);
               end if;
               if (unsigned(rom_addr) + 2 < unsigned(romcopy_size)) then
                  ROMCOPYSTATE <= ROMCOPY_READDDR3; 
                  rdram_request(DDR3MUX_ROMCOPY) <= '1';   
               else
                  ROMCOPYSTATE <= ROMCOPY_IDLE;
               end if;
               
         end case;
      
      end if;
   end process;

end architecture;





