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
--                               inject while reversed (0x27/0x28/0x29/0x36)
--   0x04 EV 00                  FPGA->HPS: event. EV: 0=ping reset,
--                               1=login complete, 2=reversal entered,
--                               3=GBA ACK header received, 4=word watchdog
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

      debug_state    : out std_logic_vector(7 downto 0) := (others => '0');
      dbg_freeze     : in  std_logic := '0'
   );
end entity;

architecture arch of gba_wireless is

   constant TICKS_1US   : integer := CLKSPEED / 1000000;
   constant TICKS_40US  : integer := 40 * TICKS_1US;
   constant TICKS_1MS   : integer := CLKSPEED / 1000;
   constant TICKS_100MS : integer := 100 * TICKS_1MS;
   constant TICKS_UART_TIMEOUT : integer := 25 * TICKS_1MS;
   constant MAX_WORDS : natural := 32;
   constant MAX_REV_ACK_PARAMS : natural := 4;
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
   constant DUMMY : std_logic_vector(31 downto 0) := x"80000000";
   signal bitcnt      : integer range 0 to 32 := 0;
   signal rx_shift    : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_shift    : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_next     : std_logic_vector(31 downto 0) := x"80000000";
   signal word_done   : std_logic := '0';
   signal rx_word     : std_logic_vector(31 downto 0) := (others => '0');
   signal gap_timer   : integer range 0 to 16383 := 0; -- bit realign on idle

   -- ping detect
   signal sd_high_cnt : integer range 0 to 262143 := 0;

   -- login: the adapter runs Nintendo's own complement-echo ID protocol,
   -- mirrored. This is Sio32IDIntr() (pret/pokeemerald librfu_sio32id.c)
   -- with MS_mode = AGB_CLK_SLAVE, i.e. the adapter's half of the exchange:
   --
   --   slave halves:  received hi = peer's recv_id, received lo = peer's send_id
   --                  transmitted  hi = our send_id, lo = our recv_id
   --
   --   if hi_rx = recv_id then                       -- peer echoed us correctly
   --      if count < 4 then
   --         if recv_id = not send_id and lo_rx = not recv_id then count++
   --      else lastId := lo_rx
   --   else count := 0                               -- resync
   --   send_id := count < 4 ? NINTENDO(count) : RFU_ID
   --   recv_id := not lo_rx                          -- sent NEXT exchange
   --
   -- Implementing the ALGORITHM rather than a captured transcript is what
   -- makes both clients work: librfu advances `count` only on a fully
   -- matching round, while afska's LinkRawWireless hardcodes the resulting
   -- wire trace {494E,494E,494E,544E,544E,4E45,4E45,4F44,4F44,8001} -- which
   -- is exactly this algorithm's output including its retry rounds. A fixed
   -- table cannot serve librfu: it walks its own script and desynchronises
   -- permanently the first time librfu advances, livelocking both sides.
   type tNintendo is array(0 to 3) of std_logic_vector(15 downto 0);
   constant NINTENDO : tNintendo := (x"494E", x"544E", x"4E45", x"4F44");
   constant RFU_ID   : std_logic_vector(15 downto 0) := x"8001";
   signal login_count : integer range 0 to 4 := 0;
   signal send_id     : std_logic_vector(15 downto 0) := (others => '0');
   signal recv_id     : std_logic_vector(15 downto 0) := (others => '0');
   signal login_done  : std_logic := '0';

   -- command engine
   signal cmd_id      : std_logic_vector(7 downto 0)  := (others => '0');
   signal cmd_len     : unsigned(7 downto 0) := (others => '0');
   signal cmd_pos     : unsigned(7 downto 0) := (others => '0');
   type tWordBuf is array(0 to MAX_WORDS - 1) of std_logic_vector(31 downto 0);
   signal pktbuf      : tWordBuf; -- shared: rx params, then daemon response
   signal resp_len    : unsigned(7 downto 0) := (others => '0');
   signal resp_id     : std_logic_vector(7 downto 0) := (others => '0');
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
   type tRevHs is (RHS_ENDWORD, RHS_WAIT_HI, RHS_SOHIGH);
   signal rev_hs      : tRevHs := RHS_ENDWORD;
   signal gba_ack     : std_logic_vector(31 downto 0) := (others => '0');
   signal ntf_cmd     : std_logic_vector(7 downto 0) := (others => '0');
   signal ntf_len     : unsigned(7 downto 0) := (others => '0');

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
   signal htx_req     : std_logic := '0'; -- complete GBA REQ waiting for serializer
   signal events_pending : std_logic_vector(0 to 4) := (others => '0');
   signal htx_busy    : boolean;
   signal htx_owns_payload : boolean;
   -- rx: parse (type, b1, b2, words) from daemon
   type tHpsRx is (RXS_TYPE, RXS_B1, RXS_B2, RXS_WORDS);
   signal hrx_state   : tHpsRx := RXS_TYPE;
   signal hrx_type    : std_logic_vector(7 downto 0) := (others => '0');
   signal hrx_b1      : std_logic_vector(7 downto 0) := (others => '0');
   signal hrx_b2      : unsigned(7 downto 0) := (others => '0');
   signal hrx_widx    : unsigned(7 downto 0) := (others => '0');
   signal hrx_bidx    : integer range 0 to 3 := 0;
   signal hrx_word    : std_logic_vector(31 downto 0) := (others => '0');
   signal hrx_timer   : integer range 0 to TICKS_UART_TIMEOUT := 0;
   signal hrx_accept  : boolean := false; -- frame was in phase at its header
   signal hrx_pkt     : std_logic := '0'; -- pulse: full packet in
   signal ack_pending : std_logic := '0'; -- daemon ACK parked in pktbuf
   signal ntf_pending : std_logic := '0'; -- daemon notify parked in pktbuf
   signal ack_rx_open, ntf_rx_open : boolean;

   signal so_level    : std_logic := '1';

begin

   -- our SO is a real push-pull output through the wired mux (driving '1'
   -- with oe simply releases the line to its pull-up -- same level)
   link_so_out <= so_level;
   link_so_oe  <= '1';

   debug_state <= std_logic_vector(to_unsigned(tState'pos(state), 4)) &
                  std_logic_vector(to_unsigned(login_count, 4));

   htx_busy <= htx_state /= TXS_IDLE or hps_tx_valid = '1';
   htx_owns_payload <= htx_req = '1' or (htx_busy and htx_words /= 0);
   ack_rx_open <= state = HSHAKE and after_hs = CMD_WAITACK and hs_phase = HS_WAITREADY and
                  ack_pending = '0' and htx_req = '0' and not (htx_busy and htx_type = x"01");
   ntf_rx_open <= (state = REV_IDLE or (state = HSHAKE and after_hs = REV_IDLE)) and ntf_pending = '0';

   process (clk)
      variable rx_now : std_logic_vector(31 downto 0);
      variable events : std_logic_vector(events_pending'range);
      variable ping, timeout, reverse_wait, accept_frame : boolean;
      variable ack_now : std_logic_vector(gba_ack'range);
      variable ack_params : natural range 0 to MAX_REV_ACK_PARAMS;
   begin
      if rising_edge(clk) then

         events := events_pending;
         ping := false;
         timeout := false;

         hrx_pkt <= '0';

         -- Pause the link clock domain's emulated time, not the HPS
         -- byte stream. Retain unconsumed SPI edges and completed words.
         if (dbg_freeze = '0') then
            word_done <= '0';
            sc_prev   <= link_sc_in;
            reverse_wait := state = REV_HSHAKE;

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
            if state = REV_IDLE or state = REV_SEND or state = REV_HSHAKE or
               (state = HSHAKE and after_hs = REV_IDLE) then
               sd_high_cnt <= 0;
            elsif (link_sd_in = '1') then
               if (sd_high_cnt /= 262143) then
                  sd_high_cnt <= sd_high_cnt + 1;
               end if;
            else
               ping := sd_high_cnt >= TICKS_1MS / 2;
               sd_high_cnt <= 0;
            end if;

            ----------------------------------------------------------------
            -- Limit forward word waits and stalls in either reverse handshake
            -- phase. REV_IDLE has its own (daemon-controlled) RF wait timer.
            if wd_armed = '1' or reverse_wait then
               if word_done = '1' or (reverse_wait and rev_hs = RHS_SOHIGH and link_si_in = '0') then
                  watchdog <= 0;
               elsif watchdog = TICKS_100MS then
                  timeout := true;
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
                     report "wireless login: count=" & integer'image(login_count) &
                            " rx=" & to_hstring(rx_word) &
                            " send_id=" & to_hstring(send_id) &
                            " recv_id=" & to_hstring(recv_id);
                     -- synthesis translate_on
                     -- Sio32IDIntr(), MS_mode = AGB_CLK_SLAVE, transcribed
                     -- literally. hi_rx is the peer's complement echo of us,
                     -- lo_rx is the peer's NINTENDO word. Note send_id/recv_id
                     -- are recomputed on EVERY exchange (as librfu does), not
                     -- only when a round is accepted.
                     if (rx_word(31 downto 16) = recv_id) then
                        if (login_count < 4) then
                           if (recv_id = not send_id and
                               rx_word(15 downto 0) = not recv_id) then
                              -- round accepted: advance to the next word
                              login_count <= login_count + 1;
                              if (login_count + 1 < 4) then
                                 send_id <= NINTENDO(login_count + 1);
                                 tx_next <= NINTENDO(login_count + 1) &
                                            (not rx_word(15 downto 0));
                              else
                                 send_id <= RFU_ID;
                                 tx_next <= RFU_ID & (not rx_word(15 downto 0));
                              end if;
                           else
                              -- echo not valid yet: resend the same word
                              send_id <= NINTENDO(login_count);
                              tx_next <= NINTENDO(login_count) &
                                         (not rx_word(15 downto 0));
                           end if;
                        else
                           -- count = 4: we transmitted RFU_ID this exchange and
                           -- the peer echoed us correctly, so it has now latched
                           -- our ID. Login is complete.
                           send_id <= RFU_ID;
                           if (login_done = '0') then
                              login_done <= '1';
                              state      <= CMD_IDLE;
                              wd_armed   <= '0';
                              tx_next    <= x"80000000";
                              events(1) := '1';
                           else
                              tx_next <= RFU_ID & (not rx_word(15 downto 0));
                           end if;
                        end if;
                     else
                        -- peer's echo does not match what we sent: resync
                        login_count <= 0;
                        send_id     <= NINTENDO(0);
                        tx_next     <= NINTENDO(0) & (not rx_word(15 downto 0));
                     end if;
                     recv_id <= not rx_word(15 downto 0);
                  end if;
                  -- no inter-word handshake during login (plain SPI)

               when CMD_IDLE =>
                  if (word_done = '1') then
                     wd_armed <= '1';
                     if rx_word(31 downto 16) = x"9966" and
                        unsigned(rx_word(15 downto 8)) <= MAX_WORDS and not htx_owns_payload then
                        cmd_id  <= rx_word(7 downto 0);
                        cmd_len <= unsigned(rx_word(15 downto 8));
                        cmd_pos <= (others => '0');
                        tx_next <= x"80000000";
                        if (unsigned(rx_word(15 downto 8)) = 0) then
                           -- no params: forward immediately, ACK header must
                           -- be ready before the response-request word
                           htx_req   <= '1';
                           -- cmd_id/cmd_len are latched by the serializer.
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
                              tx_next     <= x"9966" & std_logic_vector(resp_len) & resp_id;
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
                           -- Only incomplete transactions have a word deadline.
                           if (after_hs = CMD_IDLE or after_hs = REV_IDLE) then
                              wd_armed <= '0';
                           end if;
                           if (after_hs = REV_IDLE) then
                              -- flip to clock master now that the GBA has
                              -- finished its side of the handshake
                              link_sc_oe  <= '1';
                              link_sc_out <= '1';
                              events(2) := '1';
                           end if;
                        end if;
                  end case;

               when REV_IDLE =>
                  -- adapter is clock master; wait for a daemon notify
                  if (ntf_pending = '1') then
                     ntf_pending <= '0';
                     -- The GBA returns its ACK header during our dummy
                     -- word. A successful empty ACK ends the transaction.
                     rev_total   <= ntf_len + 2;
                     rev_wordidx <= (others => '0');
                     gba_ack     <= (others => '0');
                     tx_shift    <= x"9966" & std_logic_vector(ntf_len) & ntf_cmd;
                     rev_bitcnt  <= 0;
                     rev_halfbit <= 0;
                     rev_gap     <= 3 * TICKS_40US; -- let the GBA arm its slave transfer
                     state       <= REV_SEND;
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
                           rev_hs  <= RHS_ENDWORD;
                        else
                           rev_bitcnt <= rev_bitcnt + 1;
                        end if;
                     end if;
                  end if;

               when REV_HSHAKE =>
                  case rev_hs is
                     when RHS_ENDWORD =>
                        -- Hold the last bit across the SC rising edge, then
                        -- start the handshake. A high final slave bit is
                        -- data, not the GBA's handshake assertion.
                        so_level <= '0';
                        if link_si_in = '0' then
                           rev_hs <= RHS_WAIT_HI;
                        end if;
                     when RHS_WAIT_HI =>
                        if link_si_in = '1' then
                           so_level <= '1';
                           rev_hs   <= RHS_SOHIGH;
                        end if;
                     when RHS_SOHIGH =>
                        if link_si_in = '0' then
                           ack_now := gba_ack;
                           ack_params := 0;
                           if rev_wordidx = ntf_len + 1 then
                              -- First ACK word; optional ACK parameters
                              -- follow it, not an extra trailing dummy.
                              ack_now := rx_word;
                              gba_ack <= rx_word;
                              if rx_word(31 downto 16) = x"9966" and
                                 (rx_word(7 downto 0) = (ntf_cmd or x"80") or rx_word(7 downto 0) = x"EE") then
                                 events(3) := '1';
                                 if unsigned(rx_word(15 downto 8)) > MAX_REV_ACK_PARAMS then
                                    ack_params := MAX_REV_ACK_PARAMS;
                                 else
                                    ack_params := to_integer(unsigned(rx_word(15 downto 8)));
                                 end if;
                                 rev_total <= rev_total + ack_params;
                              else
                                 events(4) := '1';
                              end if;
                           end if;
                           if rev_wordidx + 1 = rev_total and ack_params = 0 then
                              -- librfu returns to master in this ISR and
                              -- can start DataRx immediately. No gap here.
                              link_sc_out <= '1';
                              if ack_now(31 downto 16) = x"9966" and ack_now(7 downto 0) = x"EE" then
                                 state <= REV_IDLE; -- STWI_init_slave()
                              else
                                 link_sc_oe <= '0';
                                 state      <= CMD_IDLE;
                                 tx_next    <= DUMMY;
                                 bitcnt     <= 0;
                                 wd_armed   <= '0';
                              end if;
                           else
                              rev_wordidx <= rev_wordidx + 1;
                              if rev_wordidx < ntf_len then
                                 tx_shift <= pktbuf(to_integer(rev_wordidx));
                              else
                                 tx_shift <= DUMMY;
                              end if;
                              rev_gap <= 3 * TICKS_40US; -- >= 40 us before the next word
                              state   <= REV_SEND;
                           end if;
                        end if;
                  end case;

            end case;
         end if;

         ----------------------------------------------------------------
         -- HPS tx serializer
         ----------------------------------------------------------------
         -- Byte-wise valid/ready to gba_wireless_uart.  The UART latches a
         -- byte on an edge where tx_ready='1' AND tx_valid='1', and drops
         -- tx_ready to '0' on that same edge; it stays low for the whole
         -- byte, then returns high once the byte is fully shifted out.
         -- Producer contract below:
         --   * a byte is presented by setting valid and keeping data stable;
         --   * valid is deasserted on the edge where the byte was accepted
         --     (ready was high), so the UART never re-latches it;
         --   * state advances only on that same acceptance edge, and the
         --     next byte is presented only after the UART is idle again.
         case (htx_state) is
            when TXS_IDLE =>
               if hps_tx_valid = '1' then
                  if hps_tx_ready = '1' then
                     hps_tx_valid <= '0';
                     htx_state    <= TXS_B1;
                  end if;
               elsif wireless_ena = '1' and not ping and not timeout then
                  -- Events can be posted while a frame is stalled, but the
                  -- serializer owns its header and payload until it drains.
                  for ev in events'range loop
                     if events(ev) = '1' then
                        events(ev)   := '0';
                        htx_type     <= x"04";
                        htx_b1       <= std_logic_vector(to_unsigned(ev, 8));
                        htx_b2       <= x"00";
                        htx_words    <= (others => '0');
                        hps_tx_data  <= x"04";
                        hps_tx_valid <= '1';
                        exit;
                     elsif ev = events'high and htx_req = '1' then
                        htx_req      <= '0';
                        htx_type     <= x"01";
                        htx_b1       <= cmd_id;
                        htx_b2       <= std_logic_vector(cmd_len);
                        htx_words    <= cmd_len;
                        hps_tx_data  <= x"01";
                        hps_tx_valid <= '1';
                     end if;
                  end loop;
               end if;
            when TXS_B1 =>
               if (hps_tx_valid = '0' and hps_tx_ready = '1') then
                  hps_tx_data  <= htx_b1;
                  hps_tx_valid <= '1';
               elsif (hps_tx_valid = '1' and hps_tx_ready = '1') then
                  hps_tx_valid <= '0';
                  htx_state    <= TXS_B2;
               end if;
            when TXS_B2 =>
               if (hps_tx_valid = '0' and hps_tx_ready = '1') then
                  hps_tx_data  <= htx_b2;
                  hps_tx_valid <= '1';
               elsif (hps_tx_valid = '1' and hps_tx_ready = '1') then
                  hps_tx_valid <= '0';
                  htx_widx     <= (others => '0');
                  htx_bidx     <= 0;
                  if (htx_words = 0) then
                     htx_state <= TXS_IDLE;
                  else
                     htx_state <= TXS_WORDS;
                  end if;
               end if;
            when TXS_WORDS =>
               if (hps_tx_valid = '0' and hps_tx_ready = '1') then
                  hps_tx_data  <= pktbuf(to_integer(htx_widx))(htx_bidx*8+7 downto htx_bidx*8);
                  hps_tx_valid <= '1';
               elsif (hps_tx_valid = '1' and hps_tx_ready = '1') then
                  hps_tx_valid <= '0';
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
         if hrx_state /= RXS_TYPE and hrx_timer = TICKS_UART_TIMEOUT then
            hrx_state <= RXS_TYPE;
         elsif hps_rx_valid = '1' then
            case hrx_state is
               when RXS_TYPE =>
                  if hps_rx_data = x"02" or hps_rx_data = x"03" then
                     hrx_type  <= hps_rx_data;
                     hrx_state <= RXS_B1;
                     hrx_timer <= 0;
                  end if;
               when RXS_B1 =>
                  hrx_b1    <= hps_rx_data;
                  hrx_state <= RXS_B2;
               when RXS_B2 =>
                  hrx_b2    <= unsigned(hps_rx_data);
                  hrx_widx  <= (others => '0');
                  hrx_bidx  <= 0;
                  accept_frame := unsigned(hps_rx_data) <= MAX_WORDS and
                     ((hrx_type = x"02" and ack_rx_open and
                       (hrx_b1 = (cmd_id or x"80") or (hrx_b1 = x"EE" and hps_rx_data = x"01"))) or
                      (hrx_type = x"03" and ntf_rx_open and
                       (hrx_b1 = x"27" or hrx_b1 = x"28" or hrx_b1 = x"29" or hrx_b1 = x"36")));
                  hrx_accept <= accept_frame;
                  if unsigned(hps_rx_data) = 0 then
                     if accept_frame then hrx_pkt <= '1'; end if;
                     hrx_state <= RXS_TYPE;
                  else
                     hrx_state <= RXS_WORDS;
                  end if;
               when RXS_WORDS =>
                  hrx_word(hrx_bidx*8+7 downto hrx_bidx*8) <= hps_rx_data;
                  if hrx_bidx = 3 then
                     hrx_bidx <= 0;
                     -- Drain invalid frames without writing their payload.
                     -- Accepted frames are at most MAX_WORDS long.
                     accept_frame := hrx_accept and
                        ((hrx_type = x"02" and ack_rx_open) or (hrx_type = x"03" and ntf_rx_open));
                     if accept_frame then
                        pktbuf(to_integer(hrx_widx)) <= hps_rx_data & hrx_word(23 downto 0);
                     else
                        hrx_accept <= false;
                     end if;
                     if hrx_widx + 1 = hrx_b2 then
                        if accept_frame then hrx_pkt <= '1'; end if;
                        hrx_state <= RXS_TYPE;
                     else
                        hrx_widx <= hrx_widx + 1;
                     end if;
                  else
                     hrx_bidx <= hrx_bidx + 1;
                  end if;
            end case;
         end if;
         if hrx_state /= RXS_TYPE and hrx_timer < TICKS_UART_TIMEOUT then
            hrx_timer <= hrx_timer + 1;
         end if;

         if hrx_pkt = '1' then
            if hrx_type = x"02" and ack_rx_open then
               resp_len    <= hrx_b2;
               resp_id     <= hrx_b1;
               ack_pending <= '1';
               if hrx_b1 = (cmd_id or x"80") and
                  (cmd_id = x"25" or cmd_id = x"27" or cmd_id = x"35" or cmd_id = x"37") then
                  resp_is_rev <= '1';
               else
                  resp_is_rev <= '0';
               end if;
            elsif hrx_type = x"03" and ntf_rx_open then
               ntf_cmd     <= hrx_b1;
               ntf_len     <= hrx_b2;
               ntf_pending <= '1';
            end if;
         end if;

         -- Recovery has priority over the FSM and RX commit, but leaves a
         -- UART frame that is already being serialized intact.
         if ping or timeout or reset = '1' or wireless_ena = '0' then
            watchdog     <= 0;
            wd_armed     <= '0';
            link_sc_oe   <= '0';
            link_sc_out  <= '1';
            bitcnt       <= 0;
            rev_gap      <= 0;
            htx_req      <= '0';
            hrx_state    <= RXS_TYPE;
            hrx_pkt      <= '0';
            ack_pending  <= '0';
            ntf_pending  <= '0';
            sd_high_cnt  <= 0;
            if reset = '1' or wireless_ena = '0' then
               state    <= PWRSAVE;
               so_level <= '1';
               events   := (others => '0');
               if reset = '1' then -- the UART bridge is also reset
                  htx_state    <= TXS_IDLE;
                  hps_tx_valid <= '0';
               end if;
            elsif ping then
               state       <= LOGIN;
               login_count <= 0;
               login_done  <= '0';
               -- Match the stale SIODATA32 before the first ID ISR.
               send_id     <= (others => '0');
               recv_id     <= (others => '0');
               tx_next     <= (others => '0');
               so_level    <= '0';
               events      := (0 => '1', others => '0');
            else
               state    <= CMD_IDLE;
               tx_next  <= DUMMY;
               so_level <= '0';
               events(4) := '1';
            end if;
         end if;
         events_pending <= events;

      end if;
   end process;

end architecture;
