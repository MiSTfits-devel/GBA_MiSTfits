-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Physical GBA Game Pak bus master for the Heber Multisystem2 cartridge
-- adapter (MMS2-Gameboy-Cart-Adapter, board 23467).
--
-- This is a drop-in alternative to memorymux_extern for the whole cart window
-- (0x8xxxxxx..0xFxxxxxx): same cart_ena / cart_done handshake, but instead of
-- serving the request out of SDRAM it drives the real 32 pin cartridge.
-- Everything that lives on the cart therefore works natively and needs no
-- emulation at all - SRAM and FLASH saves, EEPROM, and the GPIO devices
-- (RTC / solar / gyro / rumble).
--
-- Why this only became possible now: the bus protocol below is defined in
-- cycles of the 16.777216 MHz system clock, and the core only runs at that
-- rate since the accuracy rewrite. clk6x (100.663296 MHz, exactly 6x) is used
-- as the sequencing clock so each phase can be shaped to ~10 ns.
--
-- Bus protocol (GBATEK "AUX GBA Game Pak Bus", cross checked against
-- Lesserkuma's FlashGBX LK firmware, which drives the same silicon):
--
--   ROM   a 24 bit HALFWORD address is driven on AD0-15 + A16-23, latched in
--         the cartridge on the falling edge of /CS. AD0-15 then turns around
--         and each /RD pulse returns one halfword. The cartridge increments
--         its own latched address on every rising /RD edge, so a burst needs
--         no further address phase - but only A0..A15 are latched, so the
--         counter wraps every 64K halfwords (128 KB) and the burst has to be
--         restarted there. That wrap is real hardware behaviour, not a
--         limitation of this module.
--         WRITES burst the same way, and /CS stays low across a sequential
--         run of them. That is not an optimisation: EEPROM is a serial device
--         hanging off this bus, and its entire 73 bit command has to arrive
--         inside ONE /CS assertion or the chip discards it. Raising /CS per
--         beat costs nothing on ROM or GPIO writes and breaks every EEPROM
--         save there is.
--   SRAM  a 16 bit address is driven on AD0-15 and held for the whole cycle;
--         the 8 bits of data travel on A16-23 (NOT on AD0-7), selected with
--         /CS2 instead of /CS.
--
-- Pin group / direction mapping, taken from the adapter netlist:
--   AD0-15  MMS_BUS[7:0] + MMS_BUS[19:12], direction = DIR1 (USER_IO[6])
--   A16-23  MMS_BUS[21:20] + MMS_BUS[28:23], direction = DIR2 (USER_IO[5])
--   PHI /WR /RD /CS  MMS_BUS[8..11], always driven towards the cartridge
--   /CS2    USER_IO[4], open drain through a BSS138 with a 10k pull up - it
--           can be pulled down hard but only RC-rises, hence t_cs2_rec below.
--
-- Direction convention: drive='1' means the FPGA drives the cartridge.

entity gba_cart_phys is
   port
   (
      clk1x            : in     std_logic;
      clk6x            : in     std_logic;
      reset            : in     std_logic;

      enable           : in     std_logic;                     -- physical cart selected
      timing_sel       : in     std_logic_vector(1 downto 0);  -- 0 = accurate, 1 = tolerant

      -- request side, identical to memorymux_extern
      cart_ena         : in     std_logic;
      cart_32          : in     std_logic;
      cart_rnw         : in     std_logic;
      cart_addr        : in     std_logic_vector(27 downto 0);
      cart_writedata   : in     std_logic_vector(7 downto 0);
      cart_writedata32 : in     std_logic_vector(31 downto 0);
      cart_be32        : in     std_logic_vector(3 downto 0);
      cart_done        : out    std_logic := '0';
      cart_readdata    : out    std_logic_vector(31 downto 0) := (others => '0');

      cart_waitcnt     : in     std_logic_vector(15 downto 0); -- REG_WAITCNT, for the PHI terminal

      -- physical pins
      pin_ad_out       : out    std_logic_vector(15 downto 0) := (others => '0');
      pin_ad_in        : in     std_logic_vector(15 downto 0);
      pin_ad_drive     : out    std_logic := '0';   -- DIR1
      pin_a_out        : out    std_logic_vector(7 downto 0) := (others => '0');
      pin_a_in         : in     std_logic_vector(7 downto 0);
      pin_a_drive      : out    std_logic := '0';   -- DIR2
      pin_cs_n         : out    std_logic := '1';
      pin_cs2_n        : out    std_logic := '1';
      pin_rd_n         : out    std_logic := '1';
      pin_wr_n         : out    std_logic := '1';
      pin_phi          : out    std_logic := '0'
   );
end entity;

architecture arch of gba_cart_phys is

   -- Phase lengths in clk6x ticks (9.934 ns each, 6 per emulated cycle).
   --
   -- There is no "go faster than hardware" setting here, and there should not
   -- be one. A Game Pak is specified to answer within the windows a real AGB
   -- gives it; anything quicker is not an optimisation, it is a bet that this
   -- particular cartridge happens to beat its own spec, and losing that bet
   -- returns a wrong byte in silence rather than failing loudly. There is also
   -- nothing to win: a burst read cannot go below four emulated cycles no
   -- matter how short these windows get, because half of that is the
   -- clk1x/clk6x handshake rather than the bus, and code the game copies into
   -- IWRAM or EWRAM never touches this bus at all.
   --
   -- ACCURATE is therefore the default and matches a real AGB at its power-on
   -- WAITCNT (WS0 N=4,S=2): ~308 ns from address to data, ~179 ns per
   -- sequential beat. That is also comfortably above the fastest a game can
   -- ever configure (~238/119 ns), so every cartridge sees at least the time
   -- it was designed for, plus headroom for the two LVC8T245 crossings
   -- (~6.5 ns each way) that a real AGB does not have in the path.
   --
   -- TOLERANT is the only other setting: everything stretched roughly 1.7x for
   -- tired connectors, dirty contacts and slow reproduction cartridges. It
   -- costs a little emulated speed and nothing else.
   type t_timing is record
      t_as      : integer range 0 to 63;   -- address setup before /CS falls
      t_ah      : integer range 0 to 63;   -- address hold after /CS falls
      t_tz      : integer range 0 to 63;   -- AD0-15 turnaround to input
      t_rdacc_n : integer range 0 to 63;   -- /RD low until sampled, random access
      t_rdacc_s : integer range 0 to 63;   -- /RD low until sampled, burst beat
      t_rdh     : integer range 0 to 63;   -- /RD high between burst beats
      t_csh     : integer range 0 to 63;   -- /CS high before restarting a burst
      t_wrs     : integer range 0 to 63;   -- write data setup before /WR falls
      t_wr      : integer range 0 to 63;   -- /WR low width
      t_wrh     : integer range 0 to 63;   -- /WR high recovery
      t_s2s     : integer range 0 to 63;   -- address/data setup around /CS2
      t_s2a     : integer range 0 to 127;  -- SRAM /RD or /WR low width
      t_s2rec   : integer range 0 to 127;  -- /CS2 RC rise after release
   end record;

   -- The /CS2 numbers do NOT follow the preset ladder the way the ROM ones do.
   -- Lesserkuma's LK firmware, which is tested against a very large pile of
   -- real cartridges, holds /RD or /WR low for 400 ns on every SRAM access and
   -- 500 ns on a flash write, and says in as many words that FRAM needs it -
   -- and FRAM is what a lot of repro carts and battery-free replacement saves
   -- use. So every preset clears 400 ns here, because a save is a few thousand
   -- bytes once in a while and nobody can feel the difference, whereas a cart
   -- that answers too late silently returns the wrong save.
   --
   -- t_s2rec is the other half of that: /CS2 is open drain through a BSS138 and
   -- only RC-rises through its 10k pull up, so starting the next access before
   -- it has got back up means the chip sees one long select with the address
   -- changing underneath it - which on a write corrupts the neighbouring byte.

   --                                      as ah tz rdN rdS rdh csh  wrs wr wrh  s2s s2a s2rec
   constant TIMING_ACCURATE : t_timing := ( 5, 5, 3, 18, 14,  4,  4,   4, 24,  4,   5, 84,   80);
   constant TIMING_TOLERANT : t_timing := ( 8, 8, 5, 30, 24,  6,  6,   6, 36,  6,   8,120,  120);

   signal tm : t_timing := TIMING_ACCURATE;

   type t_state is
   (
      ST_IDLE,
      ST_CSH, ST_ADDR, ST_CSL, ST_TURN, ST_RDL, ST_RDH,
      ST_WDATA, ST_WRL, ST_WRH,
      ST_S2ADDR, ST_S2SEL, ST_S2ACC, ST_S2END, ST_S2REC,
      ST_ACKWAIT
   );
   signal state : t_state := ST_IDLE;

   signal delay          : integer range 0 to 127 := 0;

   -- clk1x side of the handshake
   signal req_active     : std_logic := '0';
   signal req_addr       : std_logic_vector(27 downto 0) := (others => '0');
   signal req_rnw        : std_logic := '0';
   signal req_32         : std_logic := '0';
   signal req_wdata32    : std_logic_vector(31 downto 0) := (others => '0');
   signal req_wbyte      : std_logic_vector(7 downto 0) := (others => '0');

   -- clk6x side
   signal req_active_6x  : std_logic := '0';
   signal resp_ready     : std_logic := '0';
   signal resp_data      : std_logic_vector(31 downto 0) := (others => '0');

   -- The sequencer's own copy of the request. It must not read req_* after it
   -- has answered: the answer frees the CPU to latch the NEXT request into
   -- req_*, and states that still had work to do (burst bookkeeping, /CS2
   -- recovery) would then be looking at the wrong access.
   signal s_addr         : std_logic_vector(27 downto 0) := (others => '0');
   signal s_rnw          : std_logic := '0';
   signal s_32           : std_logic := '0';
   signal s_wdata32      : std_logic_vector(31 downto 0) := (others => '0');
   signal s_wbyte        : std_logic_vector(7 downto 0) := (others => '0');

   signal beat_second    : std_logic := '0';   -- working on the upper halfword of a 32 bit access
   signal data_lo        : std_logic_vector(15 downto 0) := (others => '0');
   signal cur_ha         : unsigned(23 downto 0) := (others => '0');  -- halfword the cartridge is on

   -- burst tracking: the cartridge's own address counter, when we believe it
   -- is still valid (/CS held low since the last beat). burst_rnw is the
   -- direction of that run - a read cannot continue a write burst or the other
   -- way round, because the AD0-15 turnaround needs a fresh address phase.
   signal burst_valid    : std_logic := '0';
   signal burst_rnw      : std_logic := '0';
   signal burst_next     : unsigned(23 downto 0) := (others => '0');

   signal is_sram        : std_logic;
   signal rom_ha         : unsigned(23 downto 0);
   signal wr_half        : std_logic_vector(15 downto 0);

   -- PHI terminal output (WAITCNT bits 12:11: off / 4.19 / 8.38 / 16.78 MHz).
   -- Expressed as "clk6x ticks per half period" so it is a compare against a
   -- small constant rather than a modulo, which would infer a divider.
   signal phi_half       : integer range 3 to 12 := 12;
   signal phi_cnt        : integer range 0 to 11 := 0;
   signal phi_r          : std_logic := '0';

begin

   tm <= TIMING_TOLERANT when timing_sel(0) = '1' else TIMING_ACCURATE;

   -- 0xE/0xF is the /CS2 (SRAM/FLASH) window, everything below it is /CS ROM.
   -- Decoded off req_addr because ST_IDLE needs it to pick a branch, before
   -- the snapshot exists.
   is_sram <= '1' when req_addr(27 downto 25) = "111" else '0';

   -- byte address -> halfword address; bit 24 of the offset becomes A23, which
   -- is what selects the EEPROM on carts that have one
   rom_ha  <= unsigned(s_addr(24 downto 1)) + 1 when beat_second = '1' else
              unsigned(s_addr(24 downto 1));

   wr_half <= s_wdata32(31 downto 16) when (beat_second = '1' or (s_32 = '0' and s_addr(1) = '1')) else
              s_wdata32(15 downto 0);

   ----------------------------------------------------------------------------
   -- request / response handshake, CPU side
   ----------------------------------------------------------------------------
   -- Registered on clk1x, which costs one emulated cycle per access and is
   -- worth it. Returning the answer combinationally saves that cycle but puts
   -- the whole of gba_memorymux's read path (cart_readdata -> readback mux ->
   -- rotate) behind a clk6x -> clk1x transfer, and those two clocks only have
   -- one clk6x period of setup between them: measured at -4.3 ns on Cyclone V.
   -- memorymux_extern registers its own response here for the same reason.
   process (clk1x)
   begin
      if rising_edge(clk1x) then

         cart_done <= '0';

         if (reset = '1' or enable = '0') then
            req_active <= '0';
         elsif (req_active = '0') then
            if (cart_ena = '1') then
               req_addr    <= cart_addr;
               req_rnw     <= cart_rnw;
               req_32      <= cart_32;
               req_wdata32 <= cart_writedata32;
               req_wbyte   <= cart_writedata;
               req_active  <= '1';
            end if;
         elsif (resp_ready = '1') then
            req_active    <= '0';
            cart_done     <= '1';
            cart_readdata <= resp_data;
         end if;

      end if;
   end process;

   ----------------------------------------------------------------------------
   -- bus sequencer
   ----------------------------------------------------------------------------
   process (clk6x)
   begin
      if rising_edge(clk6x) then

         req_active_6x <= req_active;

         if (reset = '1' or enable = '0') then
            state        <= ST_IDLE;
            resp_ready   <= '0';
            burst_valid  <= '0';
            beat_second  <= '0';
            pin_cs_n     <= '1';
            pin_cs2_n    <= '1';
            pin_rd_n     <= '1';
            pin_wr_n     <= '1';
            pin_ad_drive <= '0';
            pin_a_drive  <= '0';
         else

            if (delay > 0) then
               delay <= delay - 1;
            end if;

            -- The CPU drops req_active on the clk1x edge where it takes our
            -- answer. Retire resp_ready here rather than in ST_ACKWAIT, so a
            -- long tail (the /CS2 recovery is ~0.5 us) cannot miss the window
            -- and hang waiting for a level that has already come and gone.
            if (resp_ready = '1' and req_active_6x = '0') then
               resp_ready <= '0';
            end if;

            case (state) is

               when ST_IDLE =>
                  if (req_active_6x = '1' and resp_ready = '0') then
                     beat_second <= '0';
                     s_addr      <= req_addr;
                     s_rnw       <= req_rnw;
                     s_32        <= req_32;
                     s_wdata32   <= req_wdata32;
                     s_wbyte     <= req_wbyte;
                     if (is_sram = '1') then
                        -- /CS and /CS2 must never be low together, so a live
                        -- ROM burst is torn down before touching the SRAM
                        pin_cs_n    <= '1';
                        burst_valid <= '0';
                        state       <= ST_S2ADDR;
                        delay       <= tm.t_s2s;
                     elsif (burst_valid = '1' and req_rnw = burst_rnw
                            and unsigned(req_addr(24 downto 1)) = burst_next) then
                        -- sequential: the cartridge already holds the address
                        -- and /CS has stayed low, so skip the address phase
                        cur_ha <= burst_next;
                        if (req_rnw = '1') then
                           state    <= ST_RDL;
                           delay    <= tm.t_rdacc_s;
                           pin_rd_n <= '0';
                        else
                           state <= ST_WDATA;
                           delay <= tm.t_wrs;
                        end if;
                     else
                        pin_cs_n    <= '1';
                        burst_valid <= '0';
                        state       <= ST_CSH;
                        delay       <= tm.t_csh;
                     end if;
                  end if;

               -- ---------------- ROM, address phase ----------------
               when ST_CSH =>
                  if (delay = 0) then
                     pin_ad_out   <= std_logic_vector(rom_ha(15 downto 0));
                     pin_a_out    <= std_logic_vector(rom_ha(23 downto 16));
                     pin_ad_drive <= '1';
                     pin_a_drive  <= '1';
                     cur_ha       <= rom_ha;
                     state        <= ST_ADDR;
                     delay        <= tm.t_as;
                  end if;

               when ST_ADDR =>
                  if (delay = 0) then
                     pin_cs_n <= '0';          -- A0..A15 latch here
                     state    <= ST_CSL;
                     delay    <= tm.t_ah;
                  end if;

               when ST_CSL =>
                  if (delay = 0) then
                     if (s_rnw = '1') then
                        pin_ad_drive <= '0';   -- turn AD0-15 around for the data
                        state        <= ST_TURN;
                        delay        <= tm.t_tz;
                     else
                        state <= ST_WDATA;
                        delay <= tm.t_wrs;
                     end if;
                  end if;

               when ST_TURN =>
                  if (delay = 0) then
                     pin_rd_n <= '0';
                     state    <= ST_RDL;
                     delay    <= tm.t_rdacc_n;
                  end if;

               -- ---------------- ROM, read beats ----------------
               when ST_RDL =>
                  if (delay = 0) then
                     if (beat_second = '1' or s_32 = '0') then
                        if (s_32 = '1') then
                           resp_data <= pin_ad_in & data_lo;
                        else
                           -- the consumer only looks at bits 15:0 for a 16 bit
                           -- access; mirroring keeps a byte read correct
                           -- whichever half the rotate stage picks
                           resp_data <= pin_ad_in & pin_ad_in;
                        end if;
                        resp_ready <= '1';
                     else
                        data_lo <= pin_ad_in;
                     end if;
                     pin_rd_n <= '1';          -- cartridge increments here
                     state    <= ST_RDH;
                     delay    <= tm.t_rdh;
                  end if;

               when ST_RDH =>
                  if (delay = 0) then
                     -- the latched counter is only 16 bits wide
                     if (cur_ha(15 downto 0) = x"FFFF") then
                        burst_valid <= '0';
                     else
                        burst_valid <= '1';
                        burst_next  <= cur_ha + 1;
                        burst_rnw   <= '1';
                     end if;

                     if (s_32 = '1' and beat_second = '0') then
                        beat_second <= '1';
                        cur_ha      <= cur_ha + 1;
                        pin_rd_n    <= '0';
                        state       <= ST_RDL;
                        delay       <= tm.t_rdacc_s;
                     else
                        state <= ST_ACKWAIT;
                     end if;
                  end if;

               -- ---------------- ROM, write beats ----------------
               when ST_WDATA =>
                  if (delay = 0) then
                     pin_ad_out <= wr_half;    -- AD0-15 stays driven for writes
                     pin_wr_n   <= '0';
                     state      <= ST_WRL;
                     delay      <= tm.t_wr;
                  end if;

               when ST_WRL =>
                  if (delay = 0) then
                     pin_wr_n <= '1';          -- cartridge increments here too
                     state    <= ST_WRH;
                     delay    <= tm.t_wrh;
                  end if;

               when ST_WRH =>
                  if (delay = 0) then
                     -- the cartridge advanced its own counter on the /WR rising
                     -- edge, exactly as it does on /RD, so leave /CS low and let
                     -- the next sequential beat use it. ST_IDLE raises /CS again
                     -- for anything non-sequential or for a /CS2 access.
                     if (cur_ha(15 downto 0) = x"FFFF") then
                        burst_valid <= '0';
                     else
                        burst_valid <= '1';
                        burst_next  <= cur_ha + 1;
                        burst_rnw   <= '0';
                     end if;

                     if (s_32 = '1' and beat_second = '0') then
                        beat_second <= '1';
                        cur_ha      <= cur_ha + 1;
                        state       <= ST_WDATA;
                        delay       <= tm.t_wrs;
                     else
                        resp_data  <= (others => '0');
                        resp_ready <= '1';
                        state      <= ST_ACKWAIT;
                     end if;
                  end if;

               -- ---------------- SRAM / FLASH via /CS2 ----------------
               when ST_S2ADDR =>
                  if (delay = 0) then
                     pin_ad_out   <= s_addr(15 downto 0);   -- held all cycle
                     pin_ad_drive <= '1';
                     if (s_rnw = '1') then
                        pin_a_drive <= '0';
                     else
                        pin_a_out   <= s_wbyte;
                        pin_a_drive <= '1';
                     end if;
                     state <= ST_S2SEL;
                     delay <= tm.t_s2s;
                  end if;

               when ST_S2SEL =>
                  if (delay = 0) then
                     pin_cs2_n <= '0';
                     if (s_rnw = '1') then
                        pin_rd_n <= '0';
                     else
                        pin_wr_n <= '0';
                     end if;
                     state <= ST_S2ACC;
                     delay <= tm.t_s2a;
                  end if;

               when ST_S2ACC =>
                  if (delay = 0) then
                     if (s_rnw = '1') then
                        resp_data <= x"000000" & pin_a_in;
                        pin_rd_n  <= '1';
                     else
                        resp_data <= (others => '0');
                        pin_wr_n  <= '1';
                     end if;
                     resp_ready <= '1';
                     state <= ST_S2END;
                     delay <= tm.t_s2s;
                  end if;

               when ST_S2END =>
                  if (delay = 0) then
                     pin_cs2_n <= '1';         -- only RC-rises, wait it out
                     state     <= ST_S2REC;
                     delay     <= tm.t_s2rec;
                  end if;

               when ST_S2REC =>
                  if (delay = 0) then
                     state <= ST_ACKWAIT;
                  end if;

               -- ---------------- handshake back ----------------
               when ST_ACKWAIT =>
                  if (resp_ready = '0') then
                     state <= ST_IDLE;
                  end if;

            end case;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------------
   -- PHI terminal. Off at boot (WAITCNT = 0), which is what almost every game
   -- leaves it at; a handful of carts do ask for it.
   ----------------------------------------------------------------------------
   pin_phi  <= phi_r;

   phi_half <= 3  when cart_waitcnt(12 downto 11) = "11" else   -- 16.78 MHz
               6  when cart_waitcnt(12 downto 11) = "10" else   --  8.38 MHz
               12;                                              --  4.19 MHz

   process (clk6x)
   begin
      if rising_edge(clk6x) then
         if (enable = '0' or cart_waitcnt(12 downto 11) = "00") then
            phi_cnt <= 0;
            phi_r   <= '0';
         elsif (phi_cnt >= phi_half - 1) then
            phi_cnt <= 0;
            phi_r   <= not phi_r;
         else
            phi_cnt <= phi_cnt + 1;
         end if;
      end if;
   end process;

end architecture;
