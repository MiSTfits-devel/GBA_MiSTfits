-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- GBA Multiboot sender: uploads a multiboot image (<= 256 KB, linked to run
-- from EWRAM at 0x020000C0) into a real cartless GBA that is sitting in its
-- BIOS multiboot slave loop, over the SNAC link port.
--
-- We are the SIO Normal-32 MASTER here -- the opposite role from
-- gba_wireless, which is a device hanging off the core's own link lines.
-- Everything below is a hardware transliteration of the author's own
-- gbasend-rs (gbasend-lib/src/multiboot.rs), which is hardware-proven
-- against real GBAs: the step order, every expected response byte, the
-- Kawasedo encryption seeds and the CRC polynomial all come from there.
--
-- Wire format: every exchange is one 32-bit Normal-32 word, MSB first, our
-- data changing on SC falling and the slave sampling it on SC rising (SPI
-- mode 3, SC idle high). Our command payload rides in the LOW halfword of
-- the word we send, and the slave's answer arrives in the HIGH halfword of
-- what we receive. The encrypted main block is the one exception: there all
-- 32 bits we send are payload.
--
-- Sequence:
--   0x6202 polled until the slave answers 0x7202     (slave present)
--   0x6102 -> 0x7202                                 (master role re-affirm)
--   96 header halfwords; each answer carries a descending index (0xC0-i)/2
--     in its top byte and 0x02 below it
--   0x6200 -> 0x0002, then 0x6202 -> 0x7202
--   0x63PP -> 0x73hh    logo palette out, encryption seed byte hh back
--   0x64<hh+0x0F> -> 0x73xx
--   length word -> 0x73rr
--   encrypted payload words, each answered with the slave's EWRAM pointer
--   0x0065 -> total size; 0x0065 polled while it answers 0x0074 (CRC busy)
--   0x0066 -> 0x0075, then our CRC, which the slave echoes on a match
--
-- Timing is the measured one from gbasend-pico: 256 kHz SC with a 150 us gap
-- between words (its empirical table is 100 us at >= 1.25 MHz, 125 us at
-- 1..1.25 MHz, 150 us below 1 MHz) and 62.5 ms between polling attempts.
-- Both are generics; do not raise the clock without re-measuring against
-- real hardware, and note that the logo palette's flash speed field encodes
-- the clock rate too (see PALETTE below).
--
-- The image is streamed back out of the DDR3 window the HPS loaded it into,
-- one 64-bit line cached so two consecutive payload words cost a single DDR3
-- access. There is deliberately no transfer timeout: we own the clock, so a
-- word always completes -- only the three polling steps can time out.
--
-- The link lines follow the core's open drain (value, oe) convention and all
-- *_in inputs must already be synchronized (gba_wrap/gba_linkport do that).
entity gba_multiboot is
   generic
   (
      CLKSPEED      : integer := 16777216; -- clk rate, for the us/ms timers
      IMAGE_ADDR    : integer := 0;        -- DDR3 byte base the HPS loaded the image to
      SCK_HZ        : integer := 256000;   -- SC rate we generate
      GAP_US        : integer := 150;      -- inter-word gap (gbasend-pico table)
      POLL_US       : integer := 62500;    -- retry interval of the polling steps
      HS_TIMEOUT_MS : integer := 10000     -- give up looking for a slave
   );
   port
   (
      clk           : in  std_logic;
      reset         : in  std_logic;
      mb_enable     : in  std_logic;                     -- OSD gate; '0' holds everything in reset
      mb_start      : in  std_logic;                     -- momentary OSD trigger, rising edge starts an upload
      mb_size       : in  unsigned(19 downto 0);         -- loaded image size in bytes

      -- link lines, master side: SC and SO are ours, SI is the slave's SO.
      -- SD stays released, exactly like gba_serial leaves it for a Normal
      -- mode internal-clock master.
      link_sc_out   : out std_logic := '1';
      link_sc_oe    : out std_logic := '0';
      link_so_out   : out std_logic := '1';
      link_so_oe    : out std_logic := '0';
      link_si_in    : in  std_logic;
      link_sd_out   : out std_logic := '1';
      link_sd_oe    : out std_logic := '0';

      -- DDR3Mux read channel (single 64bit beat), same shape as gba_mem_cart_ddr3
      ddr3_request  : out std_logic := '0';
      ddr3_address  : out unsigned(27 downto 0) := (others => '0');
      ddr3_granted  : in  std_logic;
      ddr3_done     : in  std_logic;
      ddr3_dataRead : in  std_logic_vector(63 downto 0);

      -- status for the on screen overlay: a photo of the screen must be
      -- enough to tell which step failed
      mb_busy       : out std_logic := '0';
      mb_done       : out std_logic := '0';
      mb_fail       : out std_logic := '0';
      mb_step       : out std_logic_vector(3 downto 0) := (others => '0');
      mb_percent    : out unsigned(6 downto 0) := (others => '0');
      mb_lastrx     : out std_logic_vector(15 downto 0) := (others => '0')
   );
end entity;

architecture arch of gba_multiboot is

   constant TICKS_1US     : integer := CLKSPEED / 1000000;
   constant TICKS_1MS     : integer := CLKSPEED / 1000;
   -- rounded up, so the generated SC never exceeds SCK_HZ (the gbasend delay
   -- table and the palette's flash-speed field are both keyed off bands of it)
   constant TICKS_HALFBIT : integer := (CLKSPEED + 2 * SCK_HZ - 1) / (2 * SCK_HZ);
   constant TICKS_GAP     : integer := GAP_US * TICKS_1US;
   -- multiboot.rs ONE_SIXTEENTH_SEC. Two step divisions to keep the product
   -- inside a 32 bit integer at the default 62500 us.
   constant TICKS_POLL    : integer := (CLKSPEED / 1000) * POLL_US / 1000;
   -- upper bound for the shared gap counter, never reached
   constant TICKS_MAXGAP  : integer := TICKS_POLL + TICKS_GAP;

   -- Kawasedo constants: the BIOS' "// Coded by Kawasedo" string read as
   -- little endian u32s at byte 0 (xor key) and byte 16 (seed multiplier)
   constant KK       : unsigned(31 downto 0) := x"43202F2F"; -- "// C"
   constant MULK     : unsigned(31 downto 0) := x"6F646573"; -- "sedo"
   constant EWRAMBASE : unsigned(31 downto 0) := x"02000000";
   constant CRC_XX   : unsigned(31 downto 0) := x"0000C37B"; -- Normal mode pair
   constant CRC_INIT : unsigned(31 downto 0) := x"0000C387";

   -- Flashing logo palette: 0x81 + colour*0x10 + reverse*0x08 + speed*0x02
   -- (multiboot_flashing_palette). Colour 4, forward, speed 0 -- gbasend maps
   -- speed 0 to <= 256 kbps, which is the SCK_HZ default here.
   constant PALETTE  : std_logic_vector(7 downto 0) := x"C1";

   constant HDR_HW   : integer := 96;        -- 0xC0 header bytes = 96 halfwords
   -- the length word is (((size - 0xC0) >> 2) - 0x34), so anything at or
   -- below 0x194 bytes would underflow it
   constant MB_MIN   : integer := 16#1A0#;
   constant MB_MAX   : integer := 262144;

   -- step codes, surfaced on mb_step and frozen on failure
   constant C_IDLE    : std_logic_vector(3 downto 0) := x"0";
   constant C_HS      : std_logic_vector(3 downto 0) := x"1";
   constant C_ROLE    : std_logic_vector(3 downto 0) := x"2";
   constant C_HDR     : std_logic_vector(3 downto 0) := x"3";
   constant C_HDREND  : std_logic_vector(3 downto 0) := x"4";
   constant C_ROLE2   : std_logic_vector(3 downto 0) := x"5";
   constant C_PAL     : std_logic_vector(3 downto 0) := x"6";
   constant C_CRCA    : std_logic_vector(3 downto 0) := x"7";
   constant C_LEN     : std_logic_vector(3 downto 0) := x"8";
   constant C_MAIN    : std_logic_vector(3 downto 0) := x"9";
   constant C_ENDPTR  : std_logic_vector(3 downto 0) := x"A";
   constant C_CRCWAIT : std_logic_vector(3 downto 0) := x"B";
   constant C_CRCREQ  : std_logic_vector(3 downto 0) := x"C";
   constant C_CRCSEND : std_logic_vector(3 downto 0) := x"D";
   constant C_BADSIZE : std_logic_vector(3 downto 0) := x"E";
   constant C_OK      : std_logic_vector(3 downto 0) := x"F";

   type tState is
   (
      S_IDLE,
      S_HS,       -- poll 0x6202 for a slave
      S_ROLE,     -- 0x6102
      S_HDR,      -- 96 header halfwords
      S_HDREND,   -- 0x6200
      S_ROLE2,    -- 0x6202
      S_PAL,      -- poll 0x63PP, collect the seed byte
      S_CRCA,     -- 0x64hh
      S_LEN,      -- length word, collect rr
      S_MAIN,     -- encrypted payload
      S_ENDPTR,   -- 0x0065, size echo
      S_CRCWAIT,  -- poll 0x0065 while the slave computes its CRC
      S_CRCREQ,   -- 0x0066
      S_CRCFIN,   -- fold the final word into our CRC
      S_CRCSEND,  -- our CRC, echoed back on a match
      S_OK,
      S_FAIL
   );
   signal state : tState := S_IDLE;
   signal ph    : integer range 0 to 3 := 0;

   -- word engine: one 32bit Normal transfer plus its trailing gap
   signal xfer_req   : std_logic := '0';
   signal xfer_run   : std_logic := '0';
   signal xfer_done  : std_logic := '0';
   signal in_gap     : std_logic := '0';
   signal gap_len    : integer range 0 to TICKS_MAXGAP := TICKS_GAP;
   signal gap_cnt    : integer range 0 to TICKS_MAXGAP := 0;
   signal tx_word    : std_logic_vector(31 downto 0) := (others => '0');
   signal rx_word    : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_shift   : std_logic_vector(31 downto 0) := (others => '1');
   signal rx_shift   : std_logic_vector(31 downto 0) := (others => '0');
   signal bitcnt     : integer range 0 to 31 := 0;
   signal halfcnt    : integer range 0 to TICKS_HALFBIT := 0;
   signal sck        : std_logic := '1';
   signal so_level   : std_logic := '1';

   -- millisecond timeout for the three polling steps
   signal to_run     : std_logic := '0';
   signal to_tick    : integer range 0 to TICKS_1MS := 0;
   signal to_ms      : integer range 0 to 65535 := 0;
   signal to_limit   : integer range 0 to 65535 := 0;

   -- image fetch with a one line cache
   type tFetch is (F_IDLE, F_REQ, F_WAIT);
   signal fstate     : tFetch := F_IDLE;
   signal fetch_req  : std_logic := '0';
   signal fetch_done : std_logic := '0';
   signal fetch_addr : unsigned(19 downto 0) := (others => '0');
   signal ddr3_adr_r : unsigned(27 downto 0) := (others => '0');
   signal line_data  : std_logic_vector(63 downto 0) := (others => '0');
   signal line_tag   : unsigned(27 downto 3) := (others => '1');
   signal line_valid : std_logic := '0';
   signal fsel       : std_logic_vector(1 downto 0) := "00";
   signal fetch_data : std_logic_vector(31 downto 0);
   signal fetch_hw   : std_logic_vector(15 downto 0);

   -- crc / seed engine: crc.add() and seed = seed*MULK + 1 both run as 32
   -- single bit steps, which is free next to a 275 us per word wire rate and
   -- keeps a 32x32 multiplier out of the timing report
   signal calc_req   : std_logic := '0';
   signal calc_run   : std_logic := '0';
   signal calc_done  : std_logic := '0';
   signal calc_mul   : std_logic := '0';
   signal calc_din   : unsigned(31 downto 0) := (others => '0');
   signal calc_step  : integer range 0 to 32 := 0;
   signal crc        : unsigned(31 downto 0) := CRC_INIT;
   signal crc_data   : unsigned(31 downto 0) := (others => '0');
   signal seed       : unsigned(31 downto 0) := (others => '0');
   signal mul_a      : unsigned(31 downto 0) := (others => '0');
   signal mul_b      : unsigned(31 downto 0) := (others => '0');
   signal mul_acc    : unsigned(31 downto 0) := (others => '0');

   -- protocol state carried between steps
   signal size_al    : unsigned(19 downto 0) := (others => '0'); -- 16 byte aligned image size
   signal words_tot  : unsigned(17 downto 0) := (others => '0'); -- payload words
   signal offs       : unsigned(19 downto 0) := (others => '0'); -- current byte offset
   signal hdr_idx    : integer range 0 to HDR_HW := 0;
   signal crc_hh     : unsigned(7 downto 0) := (others => '0');
   signal crc_rr     : unsigned(7 downto 0) := (others => '0');
   signal fin_rx     : std_logic_vector(15 downto 0) := (others => '0');

   -- progress: a running remainder, so no divider is needed
   signal pct_bump   : std_logic := '0';
   signal pct_acc    : unsigned(17 downto 0) := (others => '0');
   signal pct        : unsigned(6 downto 0) := (others => '0');

   signal start_1    : std_logic := '0';
   signal step_code  : std_logic_vector(3 downto 0) := C_IDLE;
   signal active     : std_logic := '0';

begin

   -- open drain: driving '1' with oe set simply releases the line to its
   -- pull-up, so oe can stay asserted for the whole session
   link_sc_out <= sck;
   link_sc_oe  <= active;
   link_so_out <= so_level;
   link_so_oe  <= active;
   link_sd_out <= '1';
   link_sd_oe  <= '0';

   ddr3_address <= ddr3_adr_r;

   -- little endian selects out of the cached 64bit line
   fetch_data <= line_data(63 downto 32) when fsel(1) = '1' else line_data(31 downto 0);
   fetch_hw   <= line_data(15 downto  0) when fsel = "00" else
                 line_data(31 downto 16) when fsel = "01" else
                 line_data(47 downto 32) when fsel = "10" else
                 line_data(63 downto 48);

   mb_busy    <= active;
   mb_step    <= step_code;
   mb_percent <= pct;

   process (clk)
      variable v_ddr3 : unsigned(27 downto 0);
      variable v_ptr  : unsigned(31 downto 0);
      variable v_fin  : unsigned(31 downto 0);
      variable v_size : unsigned(19 downto 0);
      variable v_idx  : unsigned(7 downto 0);
   begin
      if rising_edge(clk) then

         xfer_done  <= '0';
         fetch_done <= '0';
         calc_done  <= '0';
         pct_bump   <= '0';
         start_1    <= mb_start;

         ----------------------------------------------------------------
         -- word engine: 32 bits at SCK_HZ, then the inter-word gap. Data
         -- changes on SC falling, the slave's bit is sampled on SC rising.
         ----------------------------------------------------------------
         if (xfer_run = '1') then
            if (halfcnt < TICKS_HALFBIT - 1) then
               halfcnt <= halfcnt + 1;
            else
               halfcnt <= 0;
               if (sck = '1') then
                  sck      <= '0';
                  so_level <= tx_shift(31);
                  tx_shift <= tx_shift(30 downto 0) & '1';
               else
                  sck <= '1';
                  rx_shift <= rx_shift(30 downto 0) & link_si_in;
                  if (bitcnt = 31) then
                     -- SO deliberately keeps holding the last bit through the
                     -- gap: the slave latches it on this very rising edge, and
                     -- it only sees the edge a clock later through its own
                     -- synchronizer, so releasing SO here would corrupt bit 0
                     bitcnt   <= 0;
                     rx_word  <= rx_shift(30 downto 0) & link_si_in;
                     xfer_run <= '0';
                     in_gap   <= '1';
                     gap_cnt  <= 0;
                  else
                     bitcnt <= bitcnt + 1;
                  end if;
               end if;
            end if;
         elsif (in_gap = '1') then
            if (gap_cnt < gap_len) then
               gap_cnt <= gap_cnt + 1;
            else
               in_gap    <= '0';
               xfer_done <= '1';
            end if;
         elsif (xfer_req = '1') then
            xfer_req <= '0';
            tx_shift <= tx_word;
            bitcnt   <= 0;
            halfcnt  <= 0;
            sck      <= '1';
            xfer_run <= '1';
         end if;

         ----------------------------------------------------------------
         -- millisecond timeout, armed by the polling steps
         ----------------------------------------------------------------
         if (to_run = '1') then
            if (to_tick < TICKS_1MS - 1) then
               to_tick <= to_tick + 1;
            else
               to_tick <= 0;
               if (to_ms < 65535) then
                  to_ms <= to_ms + 1;
               end if;
            end if;
         end if;

         ----------------------------------------------------------------
         -- image fetch (64bit line cache)
         ----------------------------------------------------------------
         case (fstate) is
            when F_IDLE =>
               if (fetch_req = '1') then
                  fetch_req <= '0';
                  v_ddr3 := to_unsigned(IMAGE_ADDR, 28) + resize(fetch_addr, 28);
                  ddr3_adr_r <= v_ddr3;
                  fsel       <= std_logic_vector(fetch_addr(2 downto 1));
                  if (line_valid = '1' and line_tag = v_ddr3(27 downto 3)) then
                     fetch_done <= '1';
                  else
                     ddr3_request <= '1';
                     fstate       <= F_REQ;
                  end if;
               end if;

            when F_REQ =>
               if (ddr3_granted = '1') then
                  ddr3_request <= '0';
                  fstate       <= F_WAIT;
               end if;

            when F_WAIT =>
               if (ddr3_done = '1') then
                  line_data  <= ddr3_dataRead;
                  line_tag   <= ddr3_adr_r(27 downto 3);
                  line_valid <= '1';
                  fetch_done <= '1';
                  fstate     <= F_IDLE;
               end if;
         end case;

         ----------------------------------------------------------------
         -- crc / seed engine
         ----------------------------------------------------------------
         if (calc_run = '1') then
            if (calc_step < 32) then
               -- crc.add(): tmp = crc xor data; crc >>= 1; if tmp(0) then crc xor= xx
               if ((crc(0) xor crc_data(0)) = '1') then
                  crc <= ('0' & crc(31 downto 1)) xor CRC_XX;
               else
                  crc <= '0' & crc(31 downto 1);
               end if;
               crc_data <= '0' & crc_data(31 downto 1);
               if (calc_mul = '1') then
                  if (mul_a(0) = '1') then
                     mul_acc <= mul_acc + mul_b;
                  end if;
                  mul_a <= '0' & mul_a(31 downto 1);
                  mul_b <= mul_b(30 downto 0) & '0';
               end if;
               calc_step <= calc_step + 1;
            else
               calc_run  <= '0';
               calc_done <= '1';
               if (calc_mul = '1') then
                  seed <= mul_acc + 1;
               end if;
            end if;
         elsif (calc_req = '1') then
            calc_req  <= '0';
            crc_data  <= calc_din;
            mul_a     <= seed;
            mul_b     <= MULK;
            mul_acc   <= (others => '0');
            calc_step <= 0;
            calc_run  <= '1';
         end if;

         ----------------------------------------------------------------
         -- progress remainder
         ----------------------------------------------------------------
         if (pct_bump = '1') then
            pct_acc <= pct_acc + 100;
         elsif (words_tot /= 0 and pct_acc >= resize(words_tot, 18)) then
            pct_acc <= pct_acc - resize(words_tot, 18);
            if (pct < 100) then
               pct <= pct + 1;
            end if;
         end if;

         ----------------------------------------------------------------
         -- protocol sequencer
         ----------------------------------------------------------------
         case (state) is

            when S_IDLE =>
               if (mb_start = '1' and start_1 = '0') then
                  -- round up to the 16 byte granularity the BIOS expects; the
                  -- few bytes past the file end are read from DDR3 as they
                  -- lie and get both encrypted and CRC'd, so the slave's CRC
                  -- still agrees with ours
                  v_size := (mb_size + 15) and not to_unsigned(15, 20);
                  mb_done <= '0';
                  mb_fail <= '0';
                  pct     <= (others => '0');
                  pct_acc <= (others => '0');
                  line_valid <= '0';
                  mb_lastrx  <= (others => '0');
                  -- bound the raw size, not the rounded one: rounding up a
                  -- near-full 20 bit value would wrap
                  if (mb_size < MB_MIN or mb_size > MB_MAX) then
                     step_code <= C_BADSIZE;
                     mb_fail   <= '1';
                     state     <= S_FAIL;
                  else
                     size_al   <= v_size;
                     words_tot <= resize(shift_right(v_size - 16#C0#, 2), 18);
                     active    <= '1';
                     step_code <= C_HS;
                     to_ms     <= 0;
                     to_tick   <= 0;
                     to_limit  <= HS_TIMEOUT_MS;
                     to_run    <= '1';
                     ph        <= 0;
                     state     <= S_HS;
                  end if;
               end if;

            -- poll for a slave. The 62.5 ms gap on every attempt doubles as
            -- multiboot.rs' delay after a successful detection.
            when S_HS =>
               if (ph = 0) then
                  gap_len <= TICKS_POLL;
                  tx_word <= x"00006202";
                  xfer_req <= '1';
                  ph <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = x"7202") then
                     gap_len   <= TICKS_GAP;
                     to_run    <= '0';
                     step_code <= C_ROLE;
                     ph        <= 0;
                     state     <= S_ROLE;
                  elsif (to_ms >= to_limit) then
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  else
                     ph <= 0;
                  end if;
               end if;

            when S_ROLE =>
               if (ph = 0) then
                  tx_word  <= x"00006102";
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = x"7202") then
                     hdr_idx   <= 0;
                     step_code <= C_HDR;
                     ph        <= 0;
                     state     <= S_HDR;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            -- header: 96 halfwords, answers count down (0xC0 - i) / 2
            when S_HDR =>
               if (ph = 0) then
                  fetch_addr <= to_unsigned(hdr_idx * 2, 20);
                  fetch_req  <= '1';
                  ph         <= 1;
               elsif (ph = 1) then
                  if (fetch_done = '1') then
                     tx_word  <= x"0000" & fetch_hw;
                     xfer_req <= '1';
                     ph       <= 2;
                  end if;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  v_idx := to_unsigned(HDR_HW - hdr_idx, 8);
                  if (rx_word(31 downto 24) = std_logic_vector(v_idx) and
                      rx_word(23 downto 16) = x"02") then
                     if (hdr_idx = HDR_HW - 1) then
                        step_code <= C_HDREND;
                        ph        <= 0;
                        state     <= S_HDREND;
                     else
                        hdr_idx <= hdr_idx + 1;
                        ph      <= 0;
                     end if;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            when S_HDREND =>
               if (ph = 0) then
                  tx_word  <= x"00006200";
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = x"0002") then
                     step_code <= C_ROLE2;
                     ph        <= 0;
                     state     <= S_ROLE2;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            when S_ROLE2 =>
               if (ph = 0) then
                  tx_word  <= x"00006202";
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = x"7202") then
                     step_code <= C_PAL;
                     to_ms     <= 0;
                     to_tick   <= 0;
                     to_limit  <= 1000;
                     to_run    <= '1';
                     ph        <= 0;
                     state     <= S_PAL;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            -- palette out, encryption seed byte back
            when S_PAL =>
               if (ph = 0) then
                  gap_len  <= TICKS_POLL;
                  tx_word  <= x"0000" & x"63" & PALETTE;
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 24) = x"73") then
                     crc_hh <= unsigned(rx_word(23 downto 16)) + 16#0F#;
                     seed   <= unsigned(x"FFFF" & rx_word(23 downto 16) & PALETTE);
                     -- the 62.5 ms gap after this one is multiboot.rs' delay
                     -- between the encryption confirmation and the length word
                     to_run    <= '0';
                     step_code <= C_CRCA;
                     ph        <= 0;
                     state     <= S_CRCA;
                  elsif (to_ms >= to_limit) then
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  else
                     ph <= 0;
                  end if;
               end if;

            when S_CRCA =>
               if (ph = 0) then
                  gap_len  <= TICKS_POLL;
                  tx_word  <= x"0000" & x"64" & std_logic_vector(crc_hh);
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 24) = x"73") then
                     gap_len   <= TICKS_GAP;
                     step_code <= C_LEN;
                     ph        <= 0;
                     state     <= S_LEN;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            when S_LEN =>
               if (ph = 0) then
                  tx_word  <= x"0000" & std_logic_vector(resize(words_tot - 16#34#, 16));
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 24) = x"73") then
                     crc_rr    <= unsigned(rx_word(23 downto 16));
                     crc       <= CRC_INIT;
                     offs      <= to_unsigned(16#C0#, 20);
                     step_code <= C_MAIN;
                     ph        <= 0;
                     state     <= S_MAIN;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            -- encrypted payload. Per word: fetch, fold into the CRC while the
            -- seed advances, then xor the encrypted word out and check the
            -- slave echoes the EWRAM pointer we are writing.
            when S_MAIN =>
               if (ph = 0) then
                  fetch_addr <= offs;
                  fetch_req  <= '1';
                  ph         <= 1;
               elsif (ph = 1) then
                  if (fetch_done = '1') then
                     calc_din <= unsigned(fetch_data);
                     calc_mul <= '1';
                     calc_req <= '1';
                     ph       <= 2;
                  end if;
               elsif (ph = 2) then
                  if (calc_done = '1') then
                     v_ptr := (not (resize(offs, 32) + EWRAMBASE)) + 1;
                     tx_word  <= std_logic_vector((seed xor unsigned(fetch_data)) xor (v_ptr xor KK));
                     xfer_req <= '1';
                     ph       <= 3;
                  end if;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = std_logic_vector(resize(offs, 16))) then
                     pct_bump <= '1';
                     if (offs + 4 = size_al) then
                        step_code <= C_ENDPTR;
                        ph        <= 0;
                        state     <= S_ENDPTR;
                     else
                        offs <= offs + 4;
                        ph   <= 0;
                     end if;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            when S_ENDPTR =>
               if (ph = 0) then
                  tx_word  <= x"00000065";
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = std_logic_vector(resize(size_al, 16))) then
                     step_code <= C_CRCWAIT;
                     to_ms     <= 0;
                     to_tick   <= 0;
                     to_limit  <= 2000;
                     to_run    <= '1';
                     ph        <= 0;
                     state     <= S_CRCWAIT;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            -- 0x0074 means the slave is still computing its own CRC
            when S_CRCWAIT =>
               if (ph = 0) then
                  gap_len  <= TICKS_POLL;
                  tx_word  <= x"00000065";
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = x"0075") then
                     gap_len   <= TICKS_GAP;
                     to_run    <= '0';
                     step_code <= C_CRCREQ;
                     ph        <= 0;
                     state     <= S_CRCREQ;
                  elsif (rx_word(31 downto 16) /= x"0074") then
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  elsif (to_ms >= to_limit) then
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  else
                     ph <= 0;
                  end if;
               end if;

            when S_CRCREQ =>
               if (ph = 0) then
                  tx_word  <= x"00000066";
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = x"0075") then
                     fin_rx    <= rx_word(31 downto 16);
                     step_code <= C_CRCSEND;
                     ph        <= 0;
                     state     <= S_CRCFIN;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            -- crc.finalize(): fold ((((rx & 0xFF00) + rr) << 8) | 0xFFFF0000) + hh
            when S_CRCFIN =>
               if (ph = 0) then
                  v_fin := (shift_left(resize(unsigned(fin_rx) and x"FF00", 32) + resize(crc_rr, 32), 8) or x"FFFF0000") + resize(crc_hh, 32);
                  calc_din <= v_fin;
                  calc_mul <= '0';
                  calc_req <= '1';
                  ph       <= 1;
               elsif (calc_done = '1') then
                  ph    <= 0;
                  state <= S_CRCSEND;
               end if;

            when S_CRCSEND =>
               if (ph = 0) then
                  tx_word  <= x"0000" & std_logic_vector(crc(15 downto 0));
                  xfer_req <= '1';
                  ph       <= 1;
               elsif (xfer_done = '1') then
                  mb_lastrx <= rx_word(31 downto 16);
                  if (rx_word(31 downto 16) = std_logic_vector(crc(15 downto 0))) then
                     pct       <= to_unsigned(100, 7);
                     step_code <= C_OK;
                     mb_done   <= '1';
                     active    <= '0';
                     state     <= S_OK;
                  else
                     mb_fail <= '1';
                     state   <= S_FAIL;
                  end if;
               end if;

            -- Both terminal states fall straight back to S_IDLE and wait for
            -- a fresh OSD trigger there. step_code / mb_done / mb_fail are
            -- only ever written on a step entry or at the next start, so they
            -- stay frozen for the overlay meanwhile.
            when S_OK | S_FAIL =>
               active <= '0';
               to_run <= '0';
               state  <= S_IDLE;

         end case;

         if (reset = '1' or mb_enable = '0') then
            state        <= S_IDLE;
            ph           <= 0;
            active       <= '0';
            xfer_req     <= '0';
            xfer_run     <= '0';
            in_gap       <= '0';
            gap_len      <= TICKS_GAP;
            sck          <= '1';
            so_level     <= '1';
            bitcnt       <= 0;
            fetch_req    <= '0';
            fstate       <= F_IDLE;
            ddr3_request <= '0';
            line_valid   <= '0';
            calc_req     <= '0';
            calc_run     <= '0';
            to_run       <= '0';
            mb_done      <= '0';
            mb_fail      <= '0';
            step_code    <= C_IDLE;
            pct          <= (others => '0');
            pct_acc      <= (others => '0');
         end if;

      end if;
   end process;

end architecture;
