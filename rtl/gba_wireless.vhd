-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- AGB-015 Wireless Adapter emulation: transport layer.
--
-- Sits on the core's link lines in place of a cable (the GBA is the SIO
-- Normal-32 master, we are the device). Implements everything with
-- microsecond-scale timing per docs/agb015_protocol.md:
--
--   * GPIO ping detection (SD pulsed high then low -> hard reset out of
--     power-save, spec section 1)
--   * the "NINTENDO" keystream login at 256 kbps (section 2)
--   * 0x9966 STWI command framing with the per-word SO/SI handshake
--     (section 3), returning 0x80000000 dummy words while receiving
--   * clock reversal: adapter-as-master command injection with the
--     reversed handshake and the >= 40us inter-word gap (section 5)
--   * the 100 ms word watchdog that re-arms header state (section 3.2)
--
-- It implements NO command semantics: every completed REQ packet is
-- forwarded over the byte stream ports (hps_*) and the ACK payload comes
-- back the same way -- the ARM-side daemon owns the RFU state machine
-- (rooms, slots, data buffers), mirroring how gpSP splits rfu.c from its
-- transport. The manual's 64.8 ms REQ<->ACK budget (section 6) leaves
-- ample time for a UART round trip.
--
-- Byte stream framing (both directions, see support/rfu_daemon):
--   0x01 CC LL  <LL words LE>   FPGA->HPS: REQ packet received from GBA
--   0x02 CC LL  <LL words LE>   HPS->FPGA: ACK to answer with (CC already
--                               includes |0x80, or 0xEE for rejection)
--   0x03 CC PP  <PP words LE>   HPS->FPGA: adapter-initiated command to
--                               inject while reversed (0x27/0x28/0x29)
--   0x04 EV 00                  FPGA->HPS: event. EV: 0=ping reset,
--                               1=login complete, 2=reversal entered,
--                               3=GBA acked notify, 4=word watchdog fired
--
-- The link_* ports follow the core's open drain (value, oe) convention;
-- inputs must be pre-synchronized (gba_wrap does this).
entity gba_wireless is
   generic
   (
      CLKSPEED : integer := 16777216 -- clk rate, for the us/ms timers
   );
   port
   (
      clk            : in  std_logic;
      reset          : in  std_logic;
      wireless_ena   : in  std_logic; -- OSD gate; '0' holds everything in reset

      -- link lines, adapter side: sc/si/sd are the GBA's outputs (sensed),
      -- so/sc_out are ours
      link_sc_in     : in  std_logic; -- GBA SC (its clock when master)
      link_sc_out    : out std_logic := '1';
      link_sc_oe     : out std_logic := '0'; -- driven only while reversed
      link_si_in     : in  std_logic; -- GBA SO: data to us + its handshake line
      link_so_out    : out std_logic := '1'; -- our data out -> GBA SI
      link_so_oe     : out std_logic := '0';
      link_sd_in     : in  std_logic; -- GBA SD: ping detection

      -- byte stream to/from the HPS bridge (gba_wireless_uart)
      hps_tx_data    : out std_logic_vector(7 downto 0) := (others => '0');
      hps_tx_valid   : out std_logic := '0';
      hps_tx_ready   : in  std_logic;
      hps_rx_data    : in  std_logic_vector(7 downto 0);
      hps_rx_valid   : in  std_logic;

      debug_state    : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of gba_wireless is

   constant TICKS_1US   : integer := CLKSPEED / 1000000;
   constant TICKS_40US  : integer := 40 * TICKS_1US;
   constant TICKS_1MS   : integer := CLKSPEED / 1000;
   constant TICKS_100MS : integer := 100 * TICKS_1MS;
   -- half period of our 256 kHz clock while reversed
   constant TICKS_HALFBIT : integer := CLKSPEED / 512000;

   type tState is
   (
      PWRSAVE,     -- waiting for the GPIO ping
      LOGIN,       -- keystream exchanges
      CMD_IDLE,    -- expect a 0x9966 REQ header word
      CMD_PARAMS,  -- collecting LL parameter words
      CMD_WAITACK, -- packet sent to HPS, waiting for the daemon's ACK
      CMD_RESP,    -- clocking out the ACK payload
      HSHAKE,      -- forward handshake after a word (GBA master)
      REV_IDLE,    -- reversed: waiting for a daemon notify packet
      REV_SEND,    -- reversed: clocking our command out
      REV_HSHAKE   -- reversed handshake between our words
   );
   signal state       : tState := PWRSAVE;
   signal after_hs    : tState := CMD_IDLE; -- where HSHAKE returns to

   -- SPI slave engine (GBA master)
   signal sc_prev     : std_logic := '1';
   signal si_prev     : std_logic := '1';
   signal bitcnt      : integer range 0 to 32 := 0;
   signal rx_shift    : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_shift    : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_next     : std_logic_vector(31 downto 0) := x"80000000";
   signal word_done   : std_logic := '0';
   signal rx_word     : std_logic_vector(31 downto 0) := (others => '0');
   signal gap_timer   : integer range 0 to 16383 := 0; -- bit realign on idle

   -- ping detect
   signal sd_high_cnt : integer range 0 to 262143 := 0;

   -- login
   type tKeystream is array(0 to 9) of std_logic_vector(15 downto 0);
   constant P : tKeystream := (x"494E", x"494E", x"494E", x"544E", x"544E",
                               x"4E45", x"4E45", x"4F44", x"4F44", x"8001");
   signal login_j     : integer range 0 to 10 := 0;
   signal sent_hi      : std_logic_vector(15 downto 0) := x"8000";
   signal sent_hi_prev : std_logic_vector(15 downto 0) := x"8000";

   -- command engine
   signal cmd_id      : std_logic_vector(7 downto 0)  := (others => '0');
   signal cmd_len     : unsigned(7 downto 0) := (others => '0');
   signal cmd_pos     : unsigned(7 downto 0) := (others => '0');
   type tWordBuf is array(0 to 31) of std_logic_vector(31 downto 0);
   signal pktbuf      : tWordBuf; -- shared: rx params, then daemon response
   signal resp_len    : unsigned(7 downto 0) := (others => '0');
   signal resp_is_rev : std_logic := '0'; -- command triggers clock reversal
   signal watchdog    : integer range 0 to TICKS_100MS := 0;
   signal wd_armed    : std_logic := '0';

   -- handshake engine (forward: raise SO, wait SI high, drop SO, wait SI low)
   type tHsPhase is (HS_WAITREADY, HS_RAISED, HS_DROPPED);
   signal hs_phase    : tHsPhase := HS_WAITREADY;
   signal hs_ready    : std_logic := '0'; -- gate: response data prepared

   -- reversed master engine
   signal rev_halfbit : integer range 0 to 1023 := 0;
   signal rev_bitcnt  : integer range 0 to 32 := 0;
   signal rev_wordidx : unsigned(7 downto 0) := (others => '0');
   signal rev_total   : unsigned(7 downto 0) := (others => '0');
   signal rev_gap     : integer range 0 to 8191 := 0;
   type tRevHs is (RHS_SOLOW, RHS_WAIT_HI, RHS_SOHIGH, RHS_WAIT_LO, RHS_GAP);
   signal rev_hs      : tRevHs := RHS_SOLOW;
   signal gba_ack     : std_logic_vector(31 downto 0) := (others => '0');

   -- HPS packet interfaces
   -- tx: small fsm serializing (type, b1, b2, words)
   type tHpsTx is (TXS_IDLE, TXS_B1, TXS_B2, TXS_WORDS);
   signal htx_state   : tHpsTx := TXS_IDLE;
   signal htx_type    : std_logic_vector(7 downto 0) := (others => '0');
   signal htx_b1      : std_logic_vector(7 downto 0) := (others => '0');
   signal htx_b2      : std_logic_vector(7 downto 0) := (others => '0');
   signal htx_words   : unsigned(7 downto 0) := (others => '0');
   signal htx_widx    : unsigned(7 downto 0) := (others => '0');
   signal htx_bidx    : integer range 0 to 3 := 0;
   signal htx_req     : std_logic := '0'; -- pulse: start a tx (params below)
   -- rx: parse (type, b1, b2, words) from daemon
   type tHpsRx is (RXS_TYPE, RXS_B1, RXS_B2, RXS_WORDS);
   signal hrx_state   : tHpsRx := RXS_TYPE;
   signal hrx_type    : std_logic_vector(7 downto 0) := (others => '0');
   signal hrx_b1      : std_logic_vector(7 downto 0) := (others => '0');
   signal hrx_b2      : unsigned(7 downto 0) := (others => '0');
   signal hrx_widx    : unsigned(7 downto 0) := (others => '0');
   signal hrx_bidx    : integer range 0 to 3 := 0;
   signal hrx_word    : std_logic_vector(31 downto 0) := (others => '0');
   signal hrx_pkt     : std_logic := '0'; -- pulse: full packet in
   signal ack_pending : std_logic := '0'; -- daemon ACK parked in pktbuf
   signal ntf_pending : std_logic := '0'; -- daemon notify parked in pktbuf

   signal so_level    : std_logic := '1';

begin

   -- our SO is a real push-pull output through the wired mux (driving '1'
   -- with oe simply releases the line to its pull-up -- same level)
   link_so_out <= so_level;
   link_so_oe  <= '1';

   debug_state <= std_logic_vector(to_unsigned(tState'pos(state), 4)) &
                  std_logic_vector(to_unsigned(login_j, 4));

   process (clk)
      variable rx_now : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then

         word_done  <= '0';
         hrx_pkt    <= '0';

         sc_prev <= link_sc_in;
         si_prev <= link_si_in;

         ----------------------------------------------------------------
         -- SPI slave engine: shift on the GBA's SC. MSB first; our data
         -- bit changes on SC falling, theirs is sampled on SC rising.
         -- A long idle gap (>64 us) realigns the bit counter.
         ----------------------------------------------------------------
         if (state = LOGIN or state = CMD_IDLE or state = CMD_PARAMS or state = CMD_WAITACK or state = CMD_RESP) then
            if (link_sc_in = sc_prev) then
               if (gap_timer < 64 * TICKS_1US) then
                  gap_timer <= gap_timer + 1;
               elsif (bitcnt /= 0) then
                  bitcnt   <= 0;
                  tx_shift <= tx_next;
               end if;
            else
               gap_timer <= 0;
            end if;

            if (sc_prev = '1' and link_sc_in = '0') then
               -- falling edge: present next bit
               if (bitcnt = 0) then
                  so_level    <= tx_next(31);
                  tx_shift    <= tx_next(30 downto 0) & '1';
                  sent_hi_prev <= sent_hi;         -- login validation history
                  sent_hi      <= tx_next(31 downto 16);
               else
                  so_level <= tx_shift(31);
                  tx_shift <= tx_shift(30 downto 0) & '1';
               end if;
            elsif (sc_prev = '0' and link_sc_in = '1') then
               -- rising edge: sample their bit
               rx_shift <= rx_shift(30 downto 0) & link_si_in;
               if (bitcnt = 31) then
                  bitcnt    <= 0;
                  rx_now    := rx_shift(30 downto 0) & link_si_in;
                  rx_word   <= rx_now;
                  word_done <= '1';
                  so_level  <= '0'; -- idle low until handshake raises it
               else
                  bitcnt <= bitcnt + 1;
               end if;
            end if;
         end if;

         ----------------------------------------------------------------
         -- Ping detection: SD high >= 0.5 ms then falling. Ignore SD while
         -- clock direction is reversed: the GBA becomes an external-clock
         -- receiver there, which legitimately drives SD low (Programming
         -- Manual p.111). Treating that role change as a reset destroys every
         -- adapter-initiated notification on real SIO electrical behavior.
         ----------------------------------------------------------------
         if (state = REV_IDLE or state = REV_SEND or state = REV_HSHAKE) then
            sd_high_cnt <= 0;
         elsif (link_sd_in = '1') then
            if (sd_high_cnt /= 262143) then
               sd_high_cnt <= sd_high_cnt + 1;
            end if;
         else
            if (sd_high_cnt >= TICKS_1MS / 2) then
               -- hard reset out of power-save
               state       <= LOGIN;
               login_j     <= 0;
               sent_hi     <= x"8000";
               sent_hi_prev<= x"8000";
               tx_next     <= P(0) & x"0000"; -- ~0xFFFF = 0x0000
               bitcnt      <= 0;
               wd_armed    <= '0';
               so_level    <= '0';
               link_sc_oe  <= '0';
               ack_pending <= '0';
               ntf_pending <= '0';
               htx_req     <= '1';
               htx_type    <= x"04"; htx_b1 <= x"00"; htx_b2 <= x"00";
               htx_words   <= (others => '0');
            end if;
            sd_high_cnt <= 0;
         end if;

         ----------------------------------------------------------------
         -- word watchdog (command phases, GBA master): 100 ms without a
         -- completed word re-arms header state (spec 3.2)
         ----------------------------------------------------------------
         if (wd_armed = '1') then
            if (word_done = '1') then
               watchdog <= 0;
            elsif (watchdog = TICKS_100MS) then
               watchdog <= 0;
               wd_armed <= '0';
               state    <= CMD_IDLE;
               tx_next  <= x"80000000";
               htx_req  <= '1';
               htx_type <= x"04"; htx_b1 <= x"04"; htx_b2 <= x"00";
               htx_words <= (others => '0');
            else
               watchdog <= watchdog + 1;
            end if;
         else
            watchdog <= 0;
         end if;

         ----------------------------------------------------------------
         -- main state machine
         ----------------------------------------------------------------
         case (state) is

            when PWRSAVE => null; -- only the ping wakes us

            when LOGIN =>
               if (word_done = '1') then
                  -- synthesis translate_off
                  report "wireless login: j=" & integer'image(login_j) &
                         " rx=" & to_hstring(rx_word) &
                         " sent_hi_prev=" & to_hstring(sent_hi_prev) &
                         " sent_hi=" & to_hstring(sent_hi) &
                         " tx_next=" & to_hstring(tx_next);
                  -- synthesis translate_on
                  -- validate: their low half = P(j), their high half =
                  -- the complement of the hi half we transmitted in the
                  -- PREVIOUS exchange (full duplex, spec section 2)
                  if (rx_word(15 downto 0) = P(login_j) and
                      rx_word(31 downto 16) = not sent_hi_prev) then
                     if (login_j = 9) then
                        state    <= CMD_IDLE;
                        wd_armed <= '0';
                        tx_next  <= x"80000000";
                        htx_req  <= '1';
                        htx_type <= x"04"; htx_b1 <= x"01"; htx_b2 <= x"00";
                        htx_words <= (others => '0');
                     else
                        login_j <= login_j + 1;
                        tx_next <= P(login_j + 1) & (not rx_word(15 downto 0));
                     end if;
                  else
                     login_j <= 0;
                     tx_next <= P(0) & (not rx_word(15 downto 0));
                  end if;
               end if;
               -- no inter-word handshake during login (plain SPI)

            when CMD_IDLE =>
               if (word_done = '1') then
                  wd_armed <= '1';
                  if (rx_word(31 downto 16) = x"9966") then
                     cmd_id  <= rx_word(7 downto 0);
                     cmd_len <= unsigned(rx_word(15 downto 8));
                     cmd_pos <= (others => '0');
                     tx_next <= x"80000000";
                     if (unsigned(rx_word(15 downto 8)) = 0) then
                        -- no params: forward immediately, ACK header must
                        -- be ready before the response-request word
                        htx_req   <= '1';
                        htx_type  <= x"01"; htx_b1 <= rx_word(7 downto 0);
                        htx_b2    <= x"00";
                        htx_words <= (others => '0');
                        hs_ready  <= '0';
                        state     <= HSHAKE;
                        after_hs  <= CMD_WAITACK;
                        hs_phase  <= HS_WAITREADY;
                     else
                        hs_ready <= '1';
                        state    <= HSHAKE;
                        after_hs <= CMD_PARAMS;
                        hs_phase <= HS_WAITREADY;
                     end if;
                  else
                     -- not a header: stay here (drift; watchdog covers us)
                     tx_next <= x"80000000";
                  end if;
               end if;

            when CMD_PARAMS =>
               if (word_done = '1') then
                  pktbuf(to_integer(cmd_pos)) <= rx_word;
                  tx_next <= x"80000000";
                  if (cmd_pos + 1 = cmd_len) then
                     htx_req   <= '1';
                     htx_type  <= x"01"; htx_b1 <= cmd_id;
                     htx_b2    <= std_logic_vector(cmd_len);
                     htx_words <= cmd_len;
                     hs_ready  <= '0'; -- hold handshake until daemon ACKs
                     state     <= HSHAKE;
                     after_hs  <= CMD_WAITACK;
                     hs_phase  <= HS_WAITREADY;
                  else
                     cmd_pos  <= cmd_pos + 1;
                     hs_ready <= '1';
                     state    <= HSHAKE;
                     after_hs <= CMD_PARAMS;
                     hs_phase <= HS_WAITREADY;
                  end if;
               end if;

            when CMD_WAITACK =>
               -- HSHAKE already ran with hs_ready gated on ack_pending;
               -- here the GBA clocks the response-request word, and our
               -- preloaded tx_next is the ACK header.
               if (word_done = '1') then
                  cmd_pos <= (others => '0');
                  if (resp_len = 0) then
                     if (resp_is_rev = '1') then
                        -- the GBA still runs the final forward handshake
                        -- after this ACK before becoming slave (LRW wait())
                        state    <= HSHAKE;
                        after_hs <= REV_IDLE;
                        hs_phase <= HS_WAITREADY;
                        hs_ready <= '1';
                     else
                        state    <= HSHAKE;
                        after_hs <= CMD_IDLE;
                        hs_phase <= HS_WAITREADY;
                        hs_ready <= '1';
                        tx_next  <= x"80000000";
                     end if;
                  else
                     tx_next  <= pktbuf(0);
                     state    <= HSHAKE;
                     after_hs <= CMD_RESP;
                     hs_phase <= HS_WAITREADY;
                     hs_ready <= '1';
                  end if;
               end if;

            when CMD_RESP =>
               if (word_done = '1') then
                  if (cmd_pos + 1 = resp_len) then
                     if (resp_is_rev = '1') then
                        state    <= HSHAKE;
                        after_hs <= REV_IDLE;
                        hs_phase <= HS_WAITREADY;
                        hs_ready <= '1';
                     else
                        tx_next  <= x"80000000";
                        state    <= HSHAKE;
                        after_hs <= CMD_IDLE;
                        hs_phase <= HS_WAITREADY;
                        hs_ready <= '1';
                     end if;
                  else
                     cmd_pos  <= cmd_pos + 1;
                     tx_next  <= pktbuf(to_integer(cmd_pos) + 1);
                     state    <= HSHAKE;
                     after_hs <= CMD_RESP;
                     hs_phase <= HS_WAITREADY;
                     hs_ready <= '1';
                  end if;
               end if;

            when HSHAKE =>
               -- forward handshake (spec 3.2): raise SO when the next
               -- word's data is staged, wait for GBA SO high, drop, wait
               -- for GBA SO low, then the GBA clocks the next word.
               case (hs_phase) is
                  when HS_WAITREADY =>
                     if (hs_ready = '1' or (after_hs = CMD_WAITACK and ack_pending = '1')) then
                        if (after_hs = CMD_WAITACK and ack_pending = '1') then
                           -- stage the ACK header now, before raising SO
                           tx_next     <= x"9966" & std_logic_vector(resp_len) & cmd_id;
                           ack_pending <= '0';
                        end if;
                        so_level <= '1';
                        hs_phase <= HS_RAISED;
                     end if;
                  when HS_RAISED =>
                     if (link_si_in = '1') then
                        so_level <= '0';
                        hs_phase <= HS_DROPPED;
                     end if;
                  when HS_DROPPED =>
                     if (link_si_in = '0') then
                        state <= after_hs;
                        if (after_hs = REV_IDLE) then
                           -- flip to clock master now that the GBA has
                           -- finished its side of the handshake
                           wd_armed    <= '0';
                           link_sc_oe  <= '1';
                           link_sc_out <= '1';
                           htx_req     <= '1';
                           htx_type    <= x"04"; htx_b1 <= x"02"; htx_b2 <= x"00";
                           htx_words   <= (others => '0');
                        end if;
                     end if;
               end case;

            when REV_IDLE =>
               -- adapter is clock master; wait for a daemon notify
               if (ntf_pending = '1') then
                  ntf_pending <= '0';
                  -- frame: header + PP params + 0x80000000 (collect GBA
                  -- ACK) + 0x80000000 final
                  rev_total  <= hrx_b2 + 3;
                  rev_wordidx<= (others => '0');
                  tx_shift   <= x"9966" & std_logic_vector(hrx_b2) & hrx_b1;
                  rev_bitcnt <= 0;
                  rev_halfbit<= 0;
                  rev_gap    <= 3 * TICKS_40US; -- let the GBA arm its slave transfer
                  state      <= REV_SEND;
               end if;

            when REV_SEND =>
               -- generate ~256 kHz on SC; change data on falling, GBA
               -- samples on rising; we sample GBA's SO on rising too
               if (rev_gap /= 0) then
                  rev_gap <= rev_gap - 1;
               elsif (rev_halfbit /= TICKS_HALFBIT) then
                  rev_halfbit <= rev_halfbit + 1;
               else
                  rev_halfbit <= 0;
                  if (link_sc_out = '1') then
                     link_sc_out <= '0';
                     so_level    <= tx_shift(31);
                     tx_shift    <= tx_shift(30 downto 0) & '0';
                  else
                     link_sc_out <= '1';
                     rx_shift    <= rx_shift(30 downto 0) & link_si_in;
                     if (rev_bitcnt = 31) then
                        rev_bitcnt <= 0;
                        rx_word    <= rx_shift(30 downto 0) & link_si_in;
                        -- word finished: reversed handshake
                        state   <= REV_HSHAKE;
                        rev_hs  <= RHS_SOLOW;
                        so_level<= '0';
                     else
                        rev_bitcnt <= rev_bitcnt + 1;
                     end if;
                  end if;
               end if;

            when REV_HSHAKE =>
               -- spec 5.1: SO low -> GBA SO high -> our SO high ->
               -- GBA SO low -> wait >= 40us -> next word
               case (rev_hs) is
                  when RHS_SOLOW =>
                     if (link_si_in = '1') then
                        so_level <= '1';
                        rev_hs   <= RHS_SOHIGH;
                     end if;
                  when RHS_SOHIGH =>
                     if (link_si_in = '0') then
                        rev_hs  <= RHS_GAP;
                        rev_gap <= 3 * TICKS_40US; -- afska waits ~120us here
                     end if;
                  when RHS_GAP =>
                     if (rev_gap = 0) then
                        if (rev_wordidx + 2 = rev_total) then
                           -- word just finished was our 0x80000000 that
                           -- collected the GBA's ACK header
                           gba_ack   <= rx_word;
                           htx_req   <= '1';
                           htx_type  <= x"04"; htx_b1 <= x"03";
                           htx_b2    <= x"00"; -- events carry no payload
                           htx_words <= (others => '0');
                        end if;
                        if (rev_wordidx + 1 = rev_total) then
                           -- final word done: hand the clock back
                           link_sc_oe <= '0';
                           link_sc_out<= '1';
                           state      <= CMD_IDLE;
                           tx_next    <= x"80000000";
                           bitcnt     <= 0;
                           wd_armed   <= '0';
                        else
                           rev_wordidx <= rev_wordidx + 1;
                           if (rev_wordidx + 3 <= rev_total and rev_wordidx < hrx_b2) then
                              tx_shift <= pktbuf(to_integer(rev_wordidx));
                           else
                              tx_shift <= x"80000000";
                           end if;
                           state <= REV_SEND;
                        end if;
                     else
                        rev_gap <= rev_gap - 1;
                     end if;
                  when others =>
                     rev_hs <= RHS_SOLOW;
               end case;

         end case;

         ----------------------------------------------------------------
         -- HPS tx serializer
         ----------------------------------------------------------------
         hps_tx_valid <= '0';
         case (htx_state) is
            when TXS_IDLE =>
               if (htx_req = '1' and hps_tx_ready = '1') then
                  htx_req      <= '0';
                  hps_tx_data  <= htx_type;
                  hps_tx_valid <= '1';
                  htx_state    <= TXS_B1;
               end if;
            when TXS_B1 =>
               if (hps_tx_ready = '1') then
                  hps_tx_data  <= htx_b1;
                  hps_tx_valid <= '1';
                  htx_state    <= TXS_B2;
               end if;
            when TXS_B2 =>
               if (hps_tx_ready = '1') then
                  hps_tx_data  <= htx_b2;
                  hps_tx_valid <= '1';
                  htx_widx     <= (others => '0');
                  htx_bidx     <= 0;
                  if (htx_words = 0) then
                     htx_state <= TXS_IDLE;
                  else
                     htx_state <= TXS_WORDS;
                  end if;
               end if;
            when TXS_WORDS =>
               if (hps_tx_ready = '1') then
                  hps_tx_data  <= pktbuf(to_integer(htx_widx))(htx_bidx*8+7 downto htx_bidx*8);
                  hps_tx_valid <= '1';
                  if (htx_bidx = 3) then
                     htx_bidx <= 0;
                     if (htx_widx + 1 = htx_words) then
                        htx_state <= TXS_IDLE;
                     else
                        htx_widx <= htx_widx + 1;
                     end if;
                  else
                     htx_bidx <= htx_bidx + 1;
                  end if;
               end if;
         end case;

         ----------------------------------------------------------------
         -- HPS rx parser
         ----------------------------------------------------------------
         if (hps_rx_valid = '1') then
            case (hrx_state) is
               when RXS_TYPE =>
                  hrx_type  <= hps_rx_data;
                  hrx_state <= RXS_B1;
               when RXS_B1 =>
                  hrx_b1    <= hps_rx_data;
                  hrx_state <= RXS_B2;
               when RXS_B2 =>
                  hrx_b2    <= unsigned(hps_rx_data);
                  hrx_widx  <= (others => '0');
                  hrx_bidx  <= 0;
                  if (unsigned(hps_rx_data) = 0) then
                     hrx_pkt   <= '1';
                     hrx_state <= RXS_TYPE;
                  else
                     hrx_state <= RXS_WORDS;
                  end if;
               when RXS_WORDS =>
                  hrx_word(hrx_bidx*8+7 downto hrx_bidx*8) <= hps_rx_data;
                  if (hrx_bidx = 3) then
                     hrx_bidx <= 0;
                     -- bytes arrive little endian: byte3 is bits 31:24
                     pktbuf(to_integer(hrx_widx)) <= hps_rx_data & hrx_word(23 downto 0);
                     if (hrx_widx + 1 = hrx_b2) then
                        hrx_pkt   <= '1';
                        hrx_state <= RXS_TYPE;
                     else
                        hrx_widx <= hrx_widx + 1;
                     end if;
                  else
                     hrx_bidx <= hrx_bidx + 1;
                  end if;
            end case;
         end if;

         if (hrx_pkt = '1') then
            if (hrx_type = x"02") then
               -- daemon ACK: CC (with |0x80 or EE), length
               resp_len    <= hrx_b2;
               cmd_id      <= hrx_b1; -- ACK header low byte comes back verbatim
               ack_pending <= '1';
               if (cmd_id = x"25" or cmd_id = x"27" or cmd_id = x"37") then
                  resp_is_rev <= '1';
               else
                  resp_is_rev <= '0';
               end if;
            elsif (hrx_type = x"03") then
               ntf_pending <= '1';
            end if;
         end if;

         if (reset = '1' or wireless_ena = '0') then
            state       <= PWRSAVE;
            wd_armed    <= '0';
            link_sc_oe  <= '0';
            link_sc_out <= '1';
            so_level    <= '1';
            bitcnt      <= 0;
            htx_state   <= TXS_IDLE;
            htx_req     <= '0';
            hrx_state   <= RXS_TYPE;
            ack_pending <= '0';
            ntf_pending <= '0';
            sd_high_cnt <= 0;
         end if;

      end if;
   end process;

end architecture;
