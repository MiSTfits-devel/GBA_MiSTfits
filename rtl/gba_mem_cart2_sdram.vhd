-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Cart channel for the second GBA core (2P profile). Serves core 2's gamepak
-- bus from the shared SDRAM port as a guest channel with the same
-- allow/active/busy handshake as gba_mem_ewram_sdram.
--
--   * ROM reads (0x8..0xC) hit one of two SDRAM windows selected by
--     rom_shared: core 1's ROM image (read-only, race free, no locking
--     needed) when shared, or this core's own independent
--     Softmap_GBA_Gamerom2_ADDR window when not. The caller (gba_wrap) holds
--     this core in reset for the duration of any copy that targets whichever
--     window it's currently pointed at, so there's no live read-during-write
--     hazard either way -- see gba_wrap's GBA_on1X_2 derivation.
--   * reads behind the cart data return the open bus pattern, mirroring
--     READAFTERPAK in memorymux_extern.
--   * EEPROM (0xD) reads answer "ready" (1); EEPROM writes still complete
--     immediately and are dropped -- core 2 has no EEPROM save emulation
--     yet, only Flash/SRAM (see below). Games that need EEPROM specifically
--     on the 2P slot are a known follow-up gap.
--   * Flash/SRAM (0xE/0xF): a real command-sequence state machine, ported
--     from memorymux_extern's FLASHSRAMWRITEDECIDE/FLASHWRITE/FLASHREAD
--     logic (same AMD-style unlock sequence, same autoselect/erase-complete
--     read behavior). Gated by SramFlashEnable exactly like memorymux_extern.
--     Shares one write-capable SDRAM window (Softmap_GBA_FLASH_ADDR2) for
--     both Flash and SRAM, same reasoning as core 1: a cart has one save type
--     or the other, never both, so they can safely alias.
--   * GPIO port (0x080000C4..0x080000C8, inside the 0x8 ROM window): ported
--     from memorymux_extern's specialmodule/READ_GPIO handling. Without this,
--     core 2 had no GPIO device at all -- reads/writes there just fell
--     through to the ordinary ROM path, so any RTC-using cart (Pokemon
--     Emerald/Ruby/Sapphire, Boktai, WarioWare Twisted) saw a device that
--     never responds and concluded its battery had died. The actual
--     gba_gpioRTCSolarGyro instance lives in gba_wrap (a second one,
--     alongside core 1's), matching the existing pattern where this module
--     stays a thin cart-bus decoder and defers the real device logic to a
--     shared, reusable entity -- this file only exports the same 6-wire
--     GPIO_readEna/done/Din/Dout/writeEna/addr bus that memorymux_extern
--     does.
--
--     Mirrors memorymux_extern's two-layer split, not a single state
--     variable: `state1x` is the CPU-facing handshake (only it ever touches
--     cart_done/cart_readdata), `innerState` is the flash/sram decoder,
--     which can take many clk1x cycles (a full chip erase is 131072 words)
--     without the CPU-facing side being involved until it's back at
--     INNER_IDLE. Collapsing these into one state machine would fire
--     cart_done after the FIRST unlock byte's single-cycle decode instead of
--     waiting for the real result, and would have no way to make a later
--     write block for the duration of an in-flight multi-word erase.
--
-- No prefetch cache: a single SDRAM roundtrip is well below the modeled cart
-- waitstates in gba_memorymux, so core 2 only stalls extra while the shared
-- port is contended. ROM reads always run the full 32bit burst (done32),
-- which keeps the channel free of burst tails that could alias into other
-- channels. Flash/SRAM ops are always 32bit-aligned single-word SDRAM
-- accesses too, same discipline.
entity gba_mem_cart2_sdram is
   generic
   (
      Softmap_GBA_Gamerom_ADDR  : integer; -- count: 8388608 -- 32 Mbyte Data for GameRom, shared with core 1
      Softmap_GBA_Gamerom2_ADDR : integer := 0; -- count: 8388608 -- core 2's own independent 32 Mbyte window (used when rom_shared='0')
      Softmap_GBA_FLASH_ADDR2   : integer := 0  -- core 2's own Flash/SRAM backup window
   );
   port
   (
      clk1x           : in  std_logic;
      clk6x           : in  std_logic;
      clk6xIndex      : in  unsigned(2 downto 0);
      reset           : in  std_logic;

      memory_remap    : in  std_logic;
      MaxPakAddr      : in  std_logic_vector(24 downto 0);
      rom_shared      : in  std_logic := '1'; -- 1 = read core 1's shared ROM window; 0 = this core's own independent window

      flash_1m        : in  std_logic := '0'; -- 1 when "FLASH1M_V" was found in core 2's cart
      SramFlashEnable : in  std_logic := '1'; -- 0 = pretend no Flash/SRAM chip at all (sram_quirk2 equivalent)
      save_flash      : out std_logic := '0';
      save_sram       : out std_logic := '0';

      -- GPIO port passthrough (0x080000C4..0x080000C8): same 6-wire bus
      -- memorymux_extern exposes, driving a second gba_gpioRTCSolarGyro
      -- instance in gba_wrap. specialmodule mirrors core 1's GPIO_HACK OSD
      -- bit and gpio_quirk (see GBA.sv's specialmodule2 port wiring).
      specialmodule   : in  std_logic := '0';
      GPIO_readEna    : out std_logic := '0';
      GPIO_done       : in  std_logic := '0';
      GPIO_Din        : in  std_logic_vector(3 downto 0) := (others => '0');
      GPIO_Dout       : out std_logic_vector(3 downto 0) := (others => '0');
      GPIO_writeEna   : out std_logic := '0';
      GPIO_addr       : out std_logic_vector(1 downto 0) := (others => '0');

      cart_ena        : in  std_logic;
      cart_32         : in  std_logic;
      cart_rnw        : in  std_logic;
      cart_addr       : in  std_logic_vector(27 downto 0);
      cart_writedata  : in  std_logic_vector(7 downto 0) := (others => '0');
      cart_done       : out std_logic := '0';
      cart_readdata   : out std_logic_vector(31 downto 0) := (others => '0');

      cart_allow      : in  std_logic; -- shared port idle, may start at clk6xIndex 0
      cart_active     : out std_logic; -- SDRAM request pending or in flight -> extern must not launch
      cart_busy       : out std_logic; -- SDRAM op in flight -> owns the request bus

      c2_sdram_ena    : out std_logic := '0';
      c2_sdram_rnw    : out std_logic := '1';
      c2_sdram_Adr    : out std_logic_vector(26 downto 0) := (others => '0');
      c2_sdram_Din    : out std_logic_vector(31 downto 0) := (others => '0');
      c2_sdram_be     : out std_logic_vector(3 downto 0)  := "1111";
      sdram_Dout      : in  std_logic_vector(31 downto 0);
      sdram_done32    : in  std_logic
   );
end entity;

architecture arch of gba_mem_cart2_sdram is

   -- outer, CPU-facing handshake -- only this layer touches cart_done/cart_readdata
   type tState1X is
   (
      IDLE1X,
      ANSWER,    -- request served without SDRAM, complete next cycle
      WAITDATA,  -- SDRAM round trip in flight for a plain read, answer with readdata_6x on completion
      WAITINNER, -- a flash/sram write is in flight; wait for innerState back to INNER_IDLE
      WAITGPIO   -- a GPIO read is in flight; wait for GPIO_done from the gba_gpioRTCSolarGyro instance
   );
   signal state1x : tState1X := IDLE1X;

   -- inner flash/sram command decoder, ported from memorymux_extern.vhd.
   -- Runs independently of state1x once kicked off -- can take many clk1x
   -- cycles (chip erase = 131072 words) with no CPU-facing signal touched
   -- until it's back at INNER_IDLE.
   type tInnerState is
   (
      INNER_IDLE,
      FLASHSRAMWRITEDECIDE1,
      FLASHSRAMWRITEDECIDE2,
      FLASHWRITE,
      FLASH_WRITEBLOCK,
      FLASH_BLOCKWAIT
   );
   signal innerState : tInnerState := INNER_IDLE;

   type tState6X is
   (
      C2_IDLE,
      C2_WAIT,
      C2_DONE
   );
   signal state6x : tState6X := C2_IDLE;

   signal req_pending : std_logic := '0';
   signal readdata_6x : std_logic_vector(31 downto 0) := (others => '0');

   signal addr1_1     : std_logic := '0';
   signal c32_1       : std_logic := '0';
   signal ansdata      : std_logic_vector(31 downto 0) := (others => '0');

   signal rom_base : unsigned(26 downto 0);

   -- latched write request, stable across the multi-cycle flash/sram decode
   -- (mirrors memorymux_extern's adr_save/Dout_save discipline: cart_addr/
   -- cart_writedata are only guaranteed valid the cycle cart_ena is seen)
   signal adr_save  : std_logic_vector(27 downto 0) := (others => '0');
   signal dout_save : std_logic_vector(7 downto 0)  := (others => '0');

   -- FLASH, ported from memorymux_extern.vhd
   type tFLASHSTATE is
   (
      FLASH_READ_ARRAY,
      FLASH_CMD_1,
      FLASH_CMD_2,
      FLASH_AUTOSELECT,
      FLASH_CMD_3,
      FLASH_CMD_4,
      FLASH_CMD_5,
      FLASH_ERASE_COMPLETE,
      FLASH_PROGRAM,
      FLASH_SETBANK
   );
   signal flashState      : tFLASHSTATE := FLASH_READ_ARRAY;
   signal flashReadState  : tFLASHSTATE := FLASH_READ_ARRAY;
   signal flashBank       : std_logic := '0';
   signal flashNotSRam    : std_logic := '0';
   signal flashSRamdecide : std_logic := '0';
   signal flashDeviceID       : std_logic_vector(7 downto 0);
   signal flashManufacturerID : std_logic_vector(7 downto 0);

   signal flash_saveaddr  : std_logic_vector(26 downto 0) := (others => '0');
   signal flash_savecount : integer range 0 to 131072 := 0;
   signal flash_savedata  : std_logic_vector(7 downto 0) := (others => '0');
   signal flash_issave    : std_logic := '0'; -- 1 = this WRITEBLOCK run is a save_flash pulse, 0 = save_sram

begin

   cart_active <= req_pending;
   cart_busy   <= '1' when (state6x = C2_WAIT) else '0';

   rom_base <= to_unsigned(Softmap_GBA_Gamerom_ADDR, 27) when (rom_shared = '1') else
               to_unsigned(Softmap_GBA_Gamerom2_ADDR, 27);

   flashDeviceID       <= x"13" when flash_1m = '1' else x"1B";
   flashManufacturerID <= x"62" when flash_1m = '1' else x"32";

   -- done/readdata are registered on clk1x before export, following the WP2
   -- discipline: the 6x->1x crossing must be a plain register capture.
   process (clk1x)
   begin
      if rising_edge(clk1x) then

         cart_done     <= '0';
         save_flash    <= '0';
         save_sram     <= '0';
         GPIO_readEna  <= '0';
         GPIO_writeEna <= '0';

         if (reset = '1') then
            state1x         <= IDLE1X;
            innerState      <= INNER_IDLE;
            req_pending     <= '0';
            flashState      <= FLASH_READ_ARRAY;
            flashReadState  <= FLASH_READ_ARRAY;
            flashBank       <= '0';
            flashNotSRam    <= '0';
            flashSRamdecide <= '0';
         else

            -- ===== outer: CPU-facing handshake =====
            case (state1x) is

               when IDLE1X =>
                  if (cart_ena = '1') then
                     addr1_1 <= cart_addr(1);
                     c32_1   <= cart_32;
                     if (cart_rnw = '0') then
                        case (cart_addr(27 downto 24)) is
                           when x"E" | x"F" =>
                              adr_save   <= cart_addr;
                              dout_save  <= cart_writedata;
                              state1x    <= WAITINNER;
                              innerState <= FLASHSRAMWRITEDECIDE1;
                           when x"8" =>
                              state1x <= ANSWER;
                              ansdata  <= (others => '0');
                              if (specialmodule = '1' and unsigned(cart_addr(27 downto 0)) >= 16#80000C4# and unsigned(cart_addr(27 downto 0)) <= 16#80000C8#) then
                                 GPIO_writeEna <= '1';
                                 GPIO_addr     <= std_logic_vector(to_unsigned(to_integer(unsigned(cart_addr(3 downto 1))) - 4 / 2, 2));
                                 GPIO_Dout     <= cart_writedata(3 downto 0);
                              end if;
                           when others =>
                              -- ROM/EEPROM writes: no save memory there (yet), dropped as before
                              state1x <= ANSWER;
                              ansdata  <= (others => '0');
                        end case;
                     else
                        case (cart_addr(27 downto 24)) is

                           when x"8" | x"9" | x"A" | x"B" | x"C" =>
                              if (specialmodule = '1' and unsigned(cart_addr(27 downto 0)) >= 16#80000C4# and unsigned(cart_addr(27 downto 0)) <= 16#80000C8#) then
                                 state1x      <= WAITGPIO;
                                 GPIO_readEna <= '1';
                                 GPIO_addr    <= std_logic_vector(to_unsigned(to_integer(unsigned(cart_addr(3 downto 1))) - 4 / 2, 2));
                              elsif (unsigned(cart_addr(24 downto 2)) >= unsigned(MaxPakAddr)) then
                                 -- open bus behind the cart data, like READAFTERPAK
                                 state1x <= ANSWER;
                                 ansdata  <= std_logic_vector(unsigned(cart_addr(16 downto 1)) + 1) & cart_addr(16 downto 1);
                              else
                                 state1x     <= WAITDATA;
                                 req_pending <= '1';
                                 c2_sdram_rnw <= '1';
                                 if (memory_remap = '1') then
                                    c2_sdram_Adr <= std_logic_vector(rom_base + unsigned(cart_addr(19 downto 0)));
                                 else
                                    c2_sdram_Adr <= std_logic_vector(rom_base + unsigned(cart_addr(24 downto 0)));
                                 end if;
                              end if;

                           when x"D" => -- EEPROM: always ready, reads back erased data
                              state1x <= ANSWER;
                              ansdata  <= x"00000001";

                           when x"E" | x"F" => -- Flash/SRAM
                              if (SramFlashEnable = '0') then
                                 state1x <= ANSWER;
                                 ansdata  <= (others => '1');
                              else
                                 case (flashReadState) is
                                    when FLASH_READ_ARRAY =>
                                       state1x      <= WAITDATA;
                                       req_pending  <= '1';
                                       c2_sdram_rnw <= '1';
                                       c2_sdram_Adr <= std_logic_vector(to_unsigned(Softmap_GBA_FLASH_ADDR2, 27) + resize(4 * unsigned((flashBank & cart_addr(15 downto 0))), 27));
                                    when FLASH_AUTOSELECT =>
                                       state1x <= ANSWER;
                                       if (cart_addr(7 downto 0) = x"00") then
                                          ansdata <= flashManufacturerID & flashManufacturerID & flashManufacturerID & flashManufacturerID;
                                       else
                                          ansdata <= flashDeviceID & flashDeviceID & flashDeviceID & flashDeviceID;
                                       end if;
                                    when FLASH_ERASE_COMPLETE =>
                                       flashState     <= FLASH_READ_ARRAY;
                                       flashReadState <= FLASH_READ_ARRAY;
                                       state1x        <= ANSWER;
                                       ansdata         <= (others => '1');
                                    when others =>
                                       state1x <= ANSWER;
                                       ansdata  <= (others => '1');
                                 end case;
                              end if;

                           when others =>
                              state1x <= ANSWER;
                              ansdata  <= (others => '0');

                        end case;
                     end if;
                  end if;

               when ANSWER =>
                  state1x   <= IDLE1X;
                  cart_done <= '1';
                  if (c32_1 = '0' and addr1_1 = '1') then
                     cart_readdata <= ansdata(15 downto 0) & ansdata(31 downto 16);
                  else
                     cart_readdata <= ansdata;
                  end if;

               when WAITDATA =>
                  if (req_pending = '1' and state6x = C2_DONE) then
                     req_pending <= '0';
                     state1x     <= IDLE1X;
                     cart_done   <= '1';
                     if (c32_1 = '1') then
                        cart_readdata <= readdata_6x;
                     elsif (addr1_1 = '1') then
                        cart_readdata <= readdata_6x(15 downto 0) & x"0000";
                     else
                        cart_readdata <= x"0000" & readdata_6x(15 downto 0);
                     end if;
                  end if;

               when WAITINNER =>
                  if (innerState = INNER_IDLE) then
                     state1x       <= IDLE1X;
                     cart_done     <= '1';
                     cart_readdata <= (others => '0'); -- write: CPU discards this
                  end if;

               when WAITGPIO =>
                  -- unconditional low-nibble readback, no addr1_1 halfword swap:
                  -- GPIO is only ever accessed 16bit, matching memorymux_extern's
                  -- READ_GPIO (see rtl/memorymux_extern.vhd).
                  if (GPIO_done = '1') then
                     state1x       <= IDLE1X;
                     cart_done     <= '1';
                     cart_readdata <= x"0000000" & GPIO_Din;
                  end if;

            end case;

            -- ===== inner: flash/sram command-sequence decode, ported from memorymux_extern =====
            case (innerState) is

               when INNER_IDLE => null;

               when FLASHSRAMWRITEDECIDE1 =>
                  if (SramFlashEnable = '0') then
                     innerState <= INNER_IDLE;
                  else
                     innerState      <= FLASHSRAMWRITEDECIDE2;
                     flashSRamdecide <= '1';
                     if (flashSRamdecide = '0' and adr_save = x"e005555") then
                        flashNotSRam <= '1';
                     end if;
                  end if;

               when FLASHSRAMWRITEDECIDE2 =>
                  if (flashNotSRam = '1') then
                     innerState <= FLASHWRITE;
                  else
                     -- SRAM: single byte write, shares the Flash window's base address
                     flash_saveaddr  <= std_logic_vector(to_unsigned(Softmap_GBA_FLASH_ADDR2, 27) + resize(4 * unsigned(adr_save(15 downto 0)), 27));
                     flash_savecount <= 1;
                     flash_savedata  <= dout_save;
                     flash_issave    <= '0';
                     innerState      <= FLASH_WRITEBLOCK;
                  end if;

               when FLASHWRITE =>
                  innerState <= INNER_IDLE;

                  case (flashState) is
                     when FLASH_READ_ARRAY =>
                        if (adr_save(15 downto 0) = x"5555" and dout_save = x"AA") then
                           flashState <= FLASH_CMD_1;
                        end if;

                     when FLASH_CMD_1 =>
                        if (adr_save(15 downto 0) = x"2AAA" and dout_save = x"55") then
                           flashState <= FLASH_CMD_2;
                        else
                           flashState <= FLASH_READ_ARRAY;
                        end if;

                     when FLASH_CMD_2 =>
                        if (adr_save(15 downto 0) = x"5555") then
                           if (dout_save = x"90") then
                              flashState     <= FLASH_AUTOSELECT;
                              flashReadState <= FLASH_AUTOSELECT;
                           elsif (dout_save = x"80") then
                              flashState <= FLASH_CMD_3;
                           elsif (dout_save = x"F0") then
                              flashState     <= FLASH_READ_ARRAY;
                              flashReadState <= FLASH_READ_ARRAY;
                           elsif (dout_save = x"A0") then
                              flashState <= FLASH_PROGRAM;
                           elsif (dout_save = x"B0" and flash_1m = '1') then
                              flashState <= FLASH_SETBANK;
                           else
                              flashState     <= FLASH_READ_ARRAY;
                              flashReadState <= FLASH_READ_ARRAY;
                           end if;
                        else
                           flashState     <= FLASH_READ_ARRAY;
                           flashReadState <= FLASH_READ_ARRAY;
                        end if;

                     when FLASH_CMD_3 =>
                        if (adr_save(15 downto 0) = x"5555" and dout_save = x"AA") then
                           flashState <= FLASH_CMD_4;
                        else
                           flashState     <= FLASH_READ_ARRAY;
                           flashReadState <= FLASH_READ_ARRAY;
                        end if;

                     when FLASH_CMD_4 =>
                        if (adr_save(15 downto 0) = x"2AAA" and dout_save = x"55") then
                           flashState <= FLASH_CMD_5;
                        else
                           flashState     <= FLASH_READ_ARRAY;
                           flashReadState <= FLASH_READ_ARRAY;
                        end if;

                     when FLASH_CMD_5 => -- SECTOR ERASE
                        if (dout_save = x"30") then
                           flash_saveaddr <= std_logic_vector(to_unsigned(Softmap_GBA_FLASH_ADDR2, 27));
                           flash_saveaddr(13 downto  0) <= 14x"0";
                           flash_saveaddr(17 downto 14) <= adr_save(15 downto 12);
                           flash_saveaddr(18) <= flashBank;
                           flash_savecount <= 4096;
                           flash_savedata  <= (others => '1');
                           flash_issave    <= '1';
                           innerState      <= FLASH_WRITEBLOCK;
                           flashReadState  <= FLASH_ERASE_COMPLETE;
                        elsif (dout_save = x"10") then -- CHIP ERASE
                           flash_saveaddr  <= std_logic_vector(to_unsigned(Softmap_GBA_FLASH_ADDR2, 27));
                           flash_savecount <= 131072;
                           flash_savedata  <= (others => '1');
                           flash_issave    <= '1';
                           innerState      <= FLASH_WRITEBLOCK;
                           flashReadState  <= FLASH_ERASE_COMPLETE;
                        else
                           flashState     <= FLASH_READ_ARRAY;
                           flashReadState <= FLASH_READ_ARRAY;
                        end if;

                     when FLASH_AUTOSELECT =>
                        if (dout_save = x"F0") then
                           flashState     <= FLASH_READ_ARRAY;
                           flashReadState <= FLASH_READ_ARRAY;
                        elsif (adr_save(15 downto 0) = x"5555" and dout_save = x"AA") then
                           flashState <= FLASH_CMD_1;
                        else
                           flashState     <= FLASH_READ_ARRAY;
                           flashReadState <= FLASH_READ_ARRAY;
                        end if;

                     when FLASH_PROGRAM =>
                        flash_saveaddr  <= std_logic_vector(to_unsigned(Softmap_GBA_FLASH_ADDR2, 27) + resize(4 * unsigned((flashBank & adr_save(15 downto 0))), 27));
                        flash_savecount <= 1;
                        flash_savedata  <= dout_save;
                        flash_issave    <= '1';
                        innerState      <= FLASH_WRITEBLOCK;
                        flashState      <= FLASH_READ_ARRAY;
                        flashReadState  <= FLASH_READ_ARRAY;

                     when FLASH_SETBANK =>
                        if (adr_save(15 downto 0) = x"0000") then
                           flashBank <= dout_save(0);
                        end if;
                        flashState     <= FLASH_READ_ARRAY;
                        flashReadState <= FLASH_READ_ARRAY;

                     when others => null;

                  end case;

               when FLASH_WRITEBLOCK =>
                  req_pending     <= '1';
                  c2_sdram_rnw    <= '0';
                  c2_sdram_Adr    <= flash_saveaddr;
                  c2_sdram_Din    <= x"000000" & flash_savedata;
                  c2_sdram_be     <= "0001";
                  save_flash      <= flash_issave;
                  save_sram       <= not flash_issave;
                  innerState      <= FLASH_BLOCKWAIT;
                  flash_saveaddr  <= std_logic_vector(unsigned(flash_saveaddr) + 4);
                  flash_savecount <= flash_savecount - 1;

               when FLASH_BLOCKWAIT =>
                  if (req_pending = '1' and state6x = C2_DONE) then
                     req_pending <= '0';
                     if (flash_savecount = 0) then
                        innerState <= INNER_IDLE;
                     else
                        innerState <= FLASH_WRITEBLOCK;
                     end if;
                  end if;

            end case;

         end if;

      end if;
   end process;

   process (clk6x)
   begin
      if rising_edge(clk6x) then

         c2_sdram_ena <= '0';

         case (state6x) is

            when C2_IDLE =>
               if (reset = '0' and req_pending = '1' and clk6xIndex = 0 and cart_allow = '1') then
                  state6x      <= C2_WAIT;
                  c2_sdram_ena <= '1';
               end if;

            -- drains even during reset: the request bus stays owned (cart_busy)
            -- until the controller has consumed the pending op
            when C2_WAIT =>
               if (sdram_done32 = '1') then
                  readdata_6x <= sdram_Dout;
                  if (reset = '1') then
                     state6x <= C2_IDLE;
                  else
                     state6x <= C2_DONE;
                  end if;
               end if;

            when C2_DONE =>
               if (reset = '1' or req_pending = '0') then
                  state6x <= C2_IDLE;
               end if;

         end case;

      end if;
   end process;

end architecture;
