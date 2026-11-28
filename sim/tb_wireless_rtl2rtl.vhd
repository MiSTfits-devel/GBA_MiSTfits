-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_wireless_rtl2rtl is
end entity;

architecture sim of tb_wireless_rtl2rtl is
   constant CLK_PERIOD : time := 59.6 ns;
   constant CLKSPEED   : integer := 16777216;
   constant IO_TIMEOUT : time := 3 ms;

   subtype byte_t is std_logic_vector(7 downto 0);
   subtype halfword_t is std_logic_vector(15 downto 0);
   subtype word_t is std_logic_vector(31 downto 0);
   type words_t is array (natural range <>) of word_t;
   type unit_t is (HOST, CHILD);
   type unit_bits_t is array (unit_t) of std_logic;
   type unit_bytes_t is array (unit_t) of byte_t;
   type unit_words_t is array (unit_t) of word_t;
   type unit_buses_t is array (unit_t) of proc_bus_gb_type;
   type unit_counts_t is array (unit_t) of natural;
   type unit_flags_t is array (unit_t) of boolean;

   constant SIODATA32 : natural := 16#120#;
   constant SIOCNT    : natural := 16#128#;
   constant RCNT      : natural := 16#134#;
   constant MASTER_256K : halfword_t := x"5001"; -- Normal-32, IRQ, internal clock
   constant MASTER_2M   : halfword_t := x"5003";
   constant SLAVE       : halfword_t := x"5000";
   constant START       : halfword_t := x"0080";
   constant SO_HIGH     : halfword_t := x"0008";
   constant DUMMY       : word_t := x"80000000";
   constant NO_WORDS    : words_t(1 to 0) := (others => (others => '0'));

   constant RFU_ID : halfword_t := x"8001";
   type nintendo_t is array (0 to 3) of halfword_t;
   constant NINTENDO : nintendo_t := (x"494E", x"544E", x"4E45", x"4F44");
   constant HOST_ID  : word_t := x"0000A415";
   constant CHILD_ID : word_t := x"0000B926"; -- slot and status both zero
   constant GAME_CONFIG : words_t(0 to 5) :=
      (x"41471234", x"4E414520", x"4C415245", x"0020204B", x"54534F48", x"32315442");

   -- DataTx and DataRx word counts include the byte-length word. The child
   -- sends 16 payload bytes (the slot limit), the host 76. Nonuniform bytes
   -- and unique words expose swaps, truncation and repeated buffers.
   constant HOST_FRAME : words_t(0 to 19) :=
      (x"0000004C", x"688F1302", x"D112B4C7", x"36002A7D", x"4E5FA8B1",
       x"E26C0D95", x"F011C43B", x"84657ABD", x"09DB273E", x"51C6F2A0",
       x"1CBA3749", x"702D08F5", x"0E4C9A62", x"B82F6305", x"47A5EB01",
       x"9D245E76", x"8A40CF16", x"3F74D802", x"C6031EB2", x"25EF9185");
   constant CHILD_FRAME : words_t(0 to 4) :=
      (x"00001000", x"5AC30718", x"E6249D80", x"B1603F2A", x"09947E5D");

   signal clk : std_logic := '0';
   signal bus_g : unit_buses_t := (others => ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0'));
   signal wired_g, wire_slave_word : unit_words_t;
   signal irq_events : unit_counts_t := (others => 0);
   signal adapter_master, wire_sd : unit_bits_t;
   signal hps_tx_valid, hps_rx_valid : unit_bits_t := (others => '0');
   signal hps_tx_data, hps_rx_data : unit_bytes_t := (others => (others => '0'));
   signal ping_events, login_events, reversal_events, notify_ack_events : unit_counts_t := (others => 0);

   function header(cmd : byte_t; length : natural) return word_t is
   begin
      return x"9966" & std_logic_vector(to_unsigned(length, 8)) & cmd;
   end function;

   function peer(unit : unit_t) return unit_t is
   begin
      if unit = HOST then return CHILD; end if;
      return HOST;
   end function;

begin
   clk <= not clk after CLK_PERIOD / 2;

   endpoints : for unit in unit_t generate
      signal g_sc, g_sc_oe, g_so, g_so_oe, g_sd, g_sd_oe : std_logic;
      signal g_sd_gpio_oe, sd_gpio_oe : std_logic := '0';
      signal adp_sd : std_logic := '1';
      signal lp_sc, lp_si, lp_sd, serial_irq : std_logic;
      signal a_sc, a_so, a_so_oe, sc_line, gba_si : std_logic;
      signal user_in, user_out : std_logic_vector(6 downto 0);
   begin
      -- Use the same open-drain SNAC mapping and input synchronizers as
      -- the hardware path: SC=0, GBA SO=1, GBA SI=2, SD=5 on each port.
      sc_line <= '0' when user_out(0) = '0' or
                          (adapter_master(unit) = '1' and a_sc = '0') else '1';
      gba_si <= '0' when a_so_oe = '1' and a_so = '0' else '1';
      wire_sd(unit) <= user_out(5);
      user_in <= (0 => sc_line, 1 => user_out(1), 2 => gba_si,
                  5 => wire_sd(unit), others => '1');

      process (clk)
      begin
         if rising_edge(clk) then
            adp_sd <= wire_sd(unit);
            sd_gpio_oe <= g_sd_gpio_oe;
         end if;
      end process;

      link_port : entity work.gba_linkport
         port map (clk => clk, port_enable => '1', user_in => user_in, user_out => user_out,
                   link_clk_out => g_sc, link_clk_oe => g_sc_oe, link_clk_in => lp_sc,
                   link_so_out => g_so, link_so_oe => g_so_oe, link_si_in => lp_si,
                   link_sd_out => g_sd, link_sd_oe => g_sd_oe, link_sd_in => lp_sd);

      serial : entity work.gba_serial
         port map (clk100 => clk, ce => '1', gb_bus => bus_g(unit),
                   wired_out => wired_g(unit), wired_done => open, link_enable => '1',
                   link_clk_out => g_sc, link_clk_oe => g_sc_oe, link_clk_in => lp_sc,
                   link_so_out => g_so, link_so_oe => g_so_oe, link_si_in => lp_si,
                   link_sd_out => g_sd, link_sd_oe => g_sd_oe, link_sd_in => lp_sd,
                   link_sd_gpio_oe => g_sd_gpio_oe,
                   IRP_Serial => serial_irq);

      adapter : entity work.gba_wireless
         generic map (CLKSPEED => CLKSPEED)
         port map (clk => clk, reset => '0', wireless_ena => '1',
                   link_sc_in => sc_line, link_sc_out => a_sc, link_sc_oe => adapter_master(unit),
                   link_si_in => user_out(1), link_so_out => a_so, link_so_oe => a_so_oe,
                   link_sd_in => adp_sd, link_sd_gpio_oe => sd_gpio_oe,
                   hps_tx_data => hps_tx_data(unit),
                   hps_tx_valid => hps_tx_valid(unit), hps_tx_ready => '1',
                   hps_rx_data => hps_rx_data(unit), hps_rx_valid => hps_rx_valid(unit));

      -- Capture slave replies on the actual pins, not just EV 03: the
      -- adapter's event has no payload to prove the GBA put an ACK on SO.
      monitor : process (clk)
         variable prev_sc : std_logic := '1';
         variable shifted : word_t := (others => '0');
         variable bit_index : natural range 0 to 31 := 0;
      begin
         if rising_edge(clk) then
            assert not (adapter_master(unit) = '1' and g_sc_oe = '1' and g_sc = '0')
               report unit_t'image(unit) & ": GBA started its clock before adapter released SC" severity failure;
            if serial_irq = '1' then
               irq_events(unit) <= irq_events(unit) + 1;
            end if;
            if adapter_master(unit) = '0' then
               bit_index := 0;
            elsif prev_sc = '0' and sc_line = '1' then
               shifted := shifted(30 downto 0) & user_out(1);
               if bit_index = 31 then
                  wire_slave_word(unit) <= shifted;
                  bit_index := 0;
               else
                  bit_index := bit_index + 1;
               end if;
            end if;
            prev_sc := sc_line;
         end if;
      end process;
   end generate;

   -- A deterministic, one-room RFU backend. It only learns game config,
   -- slot and traffic from adapter frames; neither CPU stimulus drives it.
   backend : process (clk)
      constant MAX_WORDS : positive := 32;
      constant QUEUE_DEPTH : positive := 4;
      constant RETRY_WINDOW : time := 750 us;
      constant WAIT_WINDOW  : time := 5 ms;
      type payload_t is record
         length : natural range 0 to MAX_WORDS;
         words  : words_t(0 to MAX_WORDS - 1);
      end record;
      type frame_t is record
         kind, code : byte_t;
         payload    : payload_t;
      end record;
      type unit_frames_t is array (unit_t) of frame_t;
      type unit_payloads_t is array (unit_t) of payload_t;
      type queues_t is array (unit_t, 0 to QUEUE_DEPTH - 1) of payload_t;
      type wait_state_t is (IDLE, ARMED, REVERSED, NOTIFIED);
      type unit_waits_t is array (unit_t) of wait_state_t;
      type unit_deadlines_t is array (unit_t) of time;

      variable incoming, outgoing : unit_frames_t;
      variable rx_pos, tx_pos : unit_counts_t := (others => 0);
      variable tx_busy : unit_flags_t := (others => false);
      variable inbox : queues_t;
      variable first, queued : unit_counts_t := (others => 0);
      variable staged : unit_payloads_t;
      variable wait_state : unit_waits_t := (others => IDLE);
      variable wait_cmd : unit_bytes_t;
      variable wait_deadline : unit_deadlines_t;
      variable reject_notify, retry_notify : boolean := false;
      variable hello_seen : unit_flags_t := (others => false);
      variable configured, hosting, slot0_joined : boolean := false;
      variable game_data : words_t(GAME_CONFIG'range);

      procedure send_frame(unit : unit_t; frame : frame_t) is
      begin
         assert not tx_busy(unit) report unit_t'image(unit) & ": overlapping HPS replies" severity failure;
         outgoing(unit) := frame;
         tx_pos(unit) := 0;
         tx_busy(unit) := true;
      end procedure;

      procedure deliver(sender : unit_t; payload : payload_t) is
         constant receiver : unit_t := peer(sender);
      begin
         assert queued(receiver) < QUEUE_DEPTH report "RFU data queue overflow" severity failure;
         inbox(receiver, (first(receiver) + queued(receiver)) mod QUEUE_DEPTH) := payload;
         queued(receiver) := queued(receiver) + 1;
      end procedure;

      procedure request(unit : unit_t; frame : frame_t) is
         constant length : natural := frame.payload.length;
         variable reply : frame_t;
         variable bytes_on_air : natural;
      begin
         assert login_events(unit) = 1 and wait_state(unit) = IDLE
            report unit_t'image(unit) & ": REQ before login or while reversed" severity failure;
         assert frame.code = x"10" or hello_seen(unit)
            report unit_t'image(unit) & ": REQ before Hello" severity failure;
         case frame.code is
            when x"16" =>
               assert unit = HOST and length = game_data'length report "invalid GameConfig REQ" severity failure;
            when x"1F" =>
               assert length = 1 report "invalid CP_Start REQ length" severity failure;
            when x"24" | x"25" =>
               assert length >= 2 report "missing DataTx payload" severity failure;
            when others =>
               assert length = 0 report "unexpected REQ payload for " & to_hstring(frame.code) severity failure;
         end case;

         reply.kind := x"02";
         reply.code := frame.code or x"80";
         reply.payload.length := 0;
         case frame.code is
            when x"10" =>
               hello_seen(unit) := true;
               slot0_joined := false;
               queued := (others => 0);
               staged(unit).length := 0;
               if unit = HOST then
                  configured := false;
                  hosting := false;
               end if;
            when x"16" =>
               game_data := frame.payload.words(game_data'range);
               configured := true;
            when x"19" =>
               assert unit = HOST and configured report "hosting without GameConfig" severity failure;
               hosting := true;
            when x"1D" =>
               assert unit = CHILD report "unexpected parent scan" severity failure;
               if hosting then
                  reply.payload.length := 1 + game_data'length;
                  reply.payload.words(0) := HOST_ID; -- EntrySlot 0
                  reply.payload.words(1 to game_data'length) := game_data;
               end if;
            when x"1F" =>
               assert unit = CHILD and hosting and not slot0_joined and frame.payload.words(0) = HOST_ID
                  report "CP_Start did not request the advertised slot-0 parent" severity failure;
               slot0_joined := true;
            when x"1A" =>
               assert unit = HOST and hosting report "SC_Polling without hosting" severity failure;
               if slot0_joined then
                  reply.payload.length := 1;
                  reply.payload.words(0) := CHILD_ID;
               end if;
            when x"11" =>
               reply.payload.length := 1;
               reply.payload.words(0) := x"00000000";
               if slot0_joined then reply.payload.words(0) := x"000000FF"; end if;
            when x"24" | x"25" =>
               assert slot0_joined report "DataTx without a connected peer" severity failure;
               if unit = HOST then
                  bytes_on_air := to_integer(unsigned(frame.payload.words(0)(6 downto 0)));
                  assert bytes_on_air <= 87 report "host DataTx exceeds RFU limit" severity failure;
               else
                  bytes_on_air := to_integer(unsigned(frame.payload.words(0)(12 downto 8)));
                  assert bytes_on_air <= 16 report "slot-0 DataTx exceeds RFU limit" severity failure;
               end if;
               assert bytes_on_air > 0 and length = 1 + (bytes_on_air + 3) / 4
                  report unit_t'image(unit) & ": DataTx byte/word lengths disagree" severity failure;
               staged(unit) := frame.payload;
               deliver(unit, staged(unit));
            when x"26" =>
               if queued(unit) /= 0 then
                  reply.payload := inbox(unit, first(unit));
                  first(unit) := (first(unit) + 1) mod QUEUE_DEPTH;
                  queued(unit) := queued(unit) - 1;
               end if;
            when x"27" =>
               null; -- only arms a wait; unlike 0x25/0x37 this transmits no data
            when x"35" =>
               reply.code := x"EE";
               reply.payload.length := 1;
               reply.payload.words(0) := x"00000001";
            when x"37" =>
               assert slot0_joined and staged(unit).length > 0
                  report "ResumeRetransmit without a staged frame" severity failure;
               deliver(unit, staged(unit));
            when others =>
               assert false report "unexpected REQ " & to_hstring(frame.code) severity failure;
         end case;
         if frame.code = x"25" or frame.code = x"27" or frame.code = x"37" then
            wait_state(unit) := ARMED;
            wait_cmd(unit) := frame.code;
         end if;
         send_frame(unit, reply);
      end procedure;

      procedure handle_frame(unit : unit_t; frame : frame_t) is
      begin
         if frame.kind = x"01" then
            request(unit, frame);
         else
            assert frame.kind = x"04" and frame.payload.length = 0
               report unit_t'image(unit) & ": malformed REQ/EV frame" severity failure;
            case frame.code is
               when x"00" =>
                  assert ping_events(unit) = 0
                     report unit_t'image(unit) & ": false GPIO ping reset after initial SD pulse" severity failure;
                  ping_events(unit) <= ping_events(unit) + 1;
               when x"01" =>
                  assert ping_events(unit) = 1 and login_events(unit) = 0
                     report unit_t'image(unit) & ": unexpected login-complete event" severity failure;
                  login_events(unit) <= login_events(unit) + 1;
               when x"02" =>
                  assert wait_state(unit) = ARMED report "unarmed clock reversal" severity failure;
                  wait_state(unit) := REVERSED;
                  if wait_cmd(unit) = x"37" then
                     wait_deadline(unit) := now + RETRY_WINDOW;
                  else
                     wait_deadline(unit) := now + WAIT_WINDOW;
                  end if;
                  reversal_events(unit) <= reversal_events(unit) + 1;
               when x"03" =>
                  assert wait_state(unit) = NOTIFIED report "ACK event without notify" severity failure;
                  if unit = HOST and reject_notify then
                     reject_notify := false;
                     retry_notify := true;
                     wait_state(unit) := REVERSED;
                     wait_deadline(unit) := now + 500 us; -- wait for the rejection payload
                  else
                     wait_state(unit) := IDLE;
                  end if;
                  notify_ack_events(unit) <= notify_ack_events(unit) + 1;
               when others =>
                  assert false report unit_t'image(unit) & ": unexpected EV " & to_hstring(frame.code) severity failure;
            end case;
         end if;
      end procedure;

      procedure parse_byte(unit : unit_t; data : byte_t) is
         variable offset, lo : natural;
      begin
         assert not is_x(data) report "undefined HPS TX byte" severity failure;
         case rx_pos(unit) is
            when 0 => incoming(unit).kind := data;
            when 1 => incoming(unit).code := data;
            when 2 =>
               assert unsigned(data) <= MAX_WORDS report "oversize HPS TX frame" severity failure;
               incoming(unit).payload.length := to_integer(unsigned(data));
            when others =>
               offset := rx_pos(unit) - 3;
               lo := 8 * (offset mod 4);
               incoming(unit).payload.words(offset / 4)(lo + 7 downto lo) := data;
         end case;
         rx_pos(unit) := rx_pos(unit) + 1;
         if rx_pos(unit) = 3 + 4 * incoming(unit).payload.length then
            rx_pos(unit) := 0;
            handle_frame(unit, incoming(unit));
         end if;
      end procedure;

      procedure maybe_notify(unit : unit_t) is
         variable frame : frame_t;
      begin
         if wait_state(unit) /= REVERSED then return; end if;
         frame.kind := x"03";
         frame.code := x"28";
         frame.payload.length := 0;
         if wait_cmd(unit) = x"37" then
            if now < wait_deadline(unit) then return; end if;
            -- Slot 0 remains active (byte 1), but did not ACK (byte 0).
            frame.payload.length := 1;
            frame.payload.words(0) := x"00000100";
         elsif unit = HOST and wait_cmd(unit) = x"27" then
            frame.code := x"27";
            if not retry_notify then
               -- librfu rejects MS_Change when it carries a parameter.
               reject_notify := true;
               frame.payload.length := 1;
               frame.payload.words(0) := x"00000001";
            elsif now < wait_deadline(unit) then
               return;
            end if;
         elsif queued(unit) = 0 then
            if now < wait_deadline(unit) then return; end if;
            frame.code := x"27"; -- MasterChangeTimer expiry
         end if;
         send_frame(unit, frame);
         wait_state(unit) := NOTIFIED;
      end procedure;

      function frame_byte(frame : frame_t; pos : natural) return byte_t is
         variable lo : natural;
      begin
         case pos is
            when 0 => return frame.kind;
            when 1 => return frame.code;
            when 2 => return std_logic_vector(to_unsigned(frame.payload.length, 8));
            when others =>
               lo := 8 * ((pos - 3) mod 4);
               return frame.payload.words((pos - 3) / 4)(lo + 7 downto lo);
         end case;
      end function;
   begin
      if rising_edge(clk) then
         for unit in unit_t loop
            if hps_tx_valid(unit) = '1' then parse_byte(unit, hps_tx_data(unit)); end if;
         end loop;
         for unit in unit_t loop
            maybe_notify(unit);
            hps_rx_valid(unit) <= '0';
            if tx_busy(unit) then
               hps_rx_data(unit) <= frame_byte(outgoing(unit), tx_pos(unit));
               hps_rx_valid(unit) <= '1';
               tx_pos(unit) := tx_pos(unit) + 1;
               tx_busy(unit) := tx_pos(unit) < 3 + 4 * outgoing(unit).payload.length;
            end if;
         end loop;
      end if;
   end process;

   stimulus : process
      variable scan : words_t(0 to GAME_CONFIG'length);
      variable host_ticket, child_ticket : natural;

      procedure check_word(actual, expected : word_t; detail : string) is
      begin
         assert actual = expected report detail & ": got " & to_hstring(actual) &
                                        ", expected " & to_hstring(expected) severity failure;
      end procedure;

      procedure await_count(signal observed : unit_counts_t; unit : unit_t;
                            expected : natural; detail : string) is
      begin
         if observed(unit) < expected then
            wait until observed(unit) >= expected for IO_TIMEOUT;
         end if;
         assert observed(unit) = expected report unit_t'image(unit) & ": missing or duplicate " & detail severity failure;
      end procedure;

      procedure write_reg(unit : unit_t; addr : natural; value : std_logic_vector) is
      begin
         wait until rising_edge(clk);
         bus_g(unit).Adr <= std_logic_vector(to_unsigned(addr, proc_busadr));
         bus_g(unit).rnw <= '0';
         bus_g(unit).ena <= '1';
         if value'length = 16 then
            bus_g(unit).acc  <= ACCESS_16BIT;
            bus_g(unit).bEna <= "0011";
            bus_g(unit).Din  <= x"0000" & value;
         else
            bus_g(unit).acc  <= ACCESS_32BIT;
            bus_g(unit).bEna <= "1111";
            bus_g(unit).Din  <= value;
         end if;
         wait until rising_edge(clk);
         bus_g(unit).ena <= '0';
         bus_g(unit).rnw <= '1';
      end procedure;

      procedure read_reg(unit : unit_t; addr : natural; variable value : out word_t) is
      begin
         wait until rising_edge(clk);
         bus_g(unit).Adr <= std_logic_vector(to_unsigned(addr, proc_busadr));
         wait until rising_edge(clk);
         wait for 1 ns;
         value := wired_g(unit);
      end procedure;

      procedure arm_transfer(unit : unit_t; mode : halfword_t; variable ticket : out natural) is
      begin
         ticket := irq_events(unit) + 1;
         write_reg(unit, SIOCNT, mode or START);
      end procedure;

      procedure collect_transfer(unit : unit_t; ticket : natural; variable received : out word_t) is
      begin
         await_count(irq_events, unit, ticket, "serial-completion IRQ");
         read_reg(unit, SIODATA32, received);
      end procedure;

      procedure transfer(unit : unit_t; mode : halfword_t; tx : word_t; variable rx : out word_t) is
         variable ticket : natural;
      begin
         write_reg(unit, SIODATA32, tx);
         arm_transfer(unit, mode, ticket);
         collect_transfer(unit, ticket, rx);
      end procedure;

      procedure wait_si(unit : unit_t; level : std_logic) is
         constant deadline : time := now + IO_TIMEOUT;
         variable result : word_t;
      begin
         loop
            read_reg(unit, SIOCNT, result);
            exit when result(2) = level;
            assert now < deadline report unit_t'image(unit) & ": SI handshake timeout waiting for " &
                                         std_logic'image(level) severity failure;
         end loop;
      end procedure;

      procedure handshake(unit : unit_t; mode : halfword_t; ready_level : std_logic) is
      begin
         wait_si(unit, ready_level);
         write_reg(unit, SIOCNT, mode or SO_HIGH);
         wait_si(unit, not ready_level);
         write_reg(unit, SIOCNT, mode);
      end procedure;

      procedure login(unit : unit_t) is
         variable result : word_t;
         variable adapter_hi, adapter_lo : halfword_t;
         variable send_id, recv_id, last_id : halfword_t := x"0000";
         variable count, ticket : natural := 0;
      begin
         -- librfu AgbRFU_SoftReset: SD high for the 18 timer ticks, then low.
         write_reg(unit, RCNT, x"8000");
         write_reg(unit, RCNT, x"80A0");
         wait for 4 * CLK_PERIOD;
         assert wire_sd(unit) = '0' report "GPIO failed to drive SD low" severity failure;
         write_reg(unit, RCNT, x"80A2");
         wait for 4 * CLK_PERIOD;
         assert wire_sd(unit) = '1' report "GPIO failed to release SD high" severity failure;
         wait for 1.13 ms;
         write_reg(unit, RCNT, x"80A0");
         await_count(ping_events, unit, 1, "GPIO ping event");
         write_reg(unit, RCNT, x"0000");
         wait for 50 us;

         -- librfu Sio32IDIntr, AGB_CLK_MASTER: input low half is the echo;
         -- output high half is its complement. No replayed login trace.
         for round in 1 to 48 loop
            if round = 1 then
               arm_transfer(unit, MASTER_256K, ticket); -- initial SIODATA32 is untouched
               collect_transfer(unit, ticket, result);
            else
               transfer(unit, MASTER_256K, recv_id & send_id, result);
            end if;
            adapter_lo := result(15 downto 0);
            adapter_hi := result(31 downto 16);
            if adapter_lo = recv_id then
               if count < NINTENDO'length then
                  if recv_id = not send_id and adapter_hi = not recv_id then count := count + 1; end if;
               else
                  last_id := adapter_hi;
               end if;
            else
               count := 0;
            end if;
            exit when last_id /= x"0000";
            if count < NINTENDO'length then send_id := NINTENDO(count); else send_id := RFU_ID; end if;
            recv_id := not adapter_hi;
            wait for 150 us;
         end loop;
         assert last_id = RFU_ID report unit_t'image(unit) & ": librfu expected RFU_ID 8001, got " &
                                        to_hstring(last_id) severity failure;
         await_count(login_events, unit, 1, "EV 04 01 00 login-complete event");
      end procedure;

      procedure command(unit : unit_t; cmd : byte_t; params : words_t;
                        variable reply : out words_t; rejected : boolean := false) is
         constant detail : string := unit_t'image(unit) & " REQ " & to_hstring(cmd);
         variable result : word_t;
      begin
         transfer(unit, MASTER_2M, header(cmd, params'length), result);
         check_word(result, DUMMY, detail & " header dummy");
         handshake(unit, MASTER_2M, '1');
         for i in params'range loop
            transfer(unit, MASTER_2M, params(i), result);
            check_word(result, DUMMY, detail & " parameter dummy " & natural'image(i));
            handshake(unit, MASTER_2M, '1');
         end loop;
         transfer(unit, MASTER_2M, DUMMY, result);
         if rejected then
            check_word(result, header(x"EE", reply'length), detail & " rejection header");
         else
            check_word(result, header(cmd or x"80", reply'length), detail & " ACK header");
         end if;
         handshake(unit, MASTER_2M, '1');
         for i in reply'range loop
            transfer(unit, MASTER_2M, DUMMY, reply(i));
            handshake(unit, MASTER_2M, '1');
         end loop;
      end procedure;

      procedure expect_command(unit : unit_t; cmd : byte_t;
                               params : words_t := NO_WORDS; expected : words_t := NO_WORDS;
                               rejected : boolean := false) is
         variable result : words_t(expected'range);
      begin
         command(unit, cmd, params, result, rejected);
         for i in expected'range loop
            check_word(result(i), expected(i), unit_t'image(unit) & " ACK " & to_hstring(cmd) &
                                               " word " & natural'image(i));
         end loop;
      end procedure;

      procedure begin_reversal(unit : unit_t; event_number : natural; variable ticket : out natural) is
      begin
         await_count(reversal_events, unit, event_number, "clock reversal event");
         assert adapter_master(unit) = '1' and wire_sd(unit) = '1'
            report unit_t'image(unit) & ": bad pin levels before becoming slave" severity failure;
         write_reg(unit, SIODATA32, DUMMY);
         arm_transfer(unit, SLAVE, ticket);
         wait for 4 * CLK_PERIOD;
         assert wire_sd(unit) = '0' report unit_t'image(unit) & ": SIO slave must pull SD low" severity failure;
      end procedure;

      procedure receive_notify(unit : unit_t; ticket : natural; params : words_t := NO_WORDS;
                               cmd : byte_t := x"28"; rejected : boolean := false) is
         constant detail : string := unit_t'image(unit) & " reverse notify";
         variable notify_ack : word_t;
         variable result : word_t;
      begin
         collect_transfer(unit, ticket, result);
         check_word(result, header(cmd, params'length), detail & " header");
         check_word(wire_slave_word(unit), DUMMY, detail & " header reply on SO");
         handshake(unit, SLAVE, '0');
         for i in params'range loop
            transfer(unit, SLAVE, DUMMY, result);
            check_word(result, params(i), detail & " parameter " & natural'image(i));
            check_word(wire_slave_word(unit), DUMMY, detail & " parameter reply on SO");
            handshake(unit, SLAVE, '0');
         end loop;
         if rejected then notify_ack := x"996601EE";
         else notify_ack := header(cmd or x"80", 0); end if;
         transfer(unit, SLAVE, notify_ack, result);
         check_word(result, DUMMY, detail & " ACK clock word");
         check_word(wire_slave_word(unit), notify_ack, detail & " ACK on SO");
         handshake(unit, SLAVE, '0');
         if rejected then
            assert adapter_master(unit) = '1' report "clock released before rejection reason" severity failure;
            transfer(unit, SLAVE, x"00000001", result);
            check_word(result, DUMMY, detail & " rejection reason clock word");
            check_word(wire_slave_word(unit), x"00000001", detail & " reason on SO");
            handshake(unit, SLAVE, '0');
            wait for 8 * CLK_PERIOD;
            assert adapter_master(unit) = '1' report "clock was released after rejection" severity failure;
         else
            -- Retail returns to master immediately; no extra transfer,
            -- UART event wait or inter-word gap before the next command.
            write_reg(unit, SIOCNT, MASTER_2M);
            wait for 1 ns; -- observe registered SC output at this edge
            assert adapter_master(unit) = '0' report detail & ": late clock handback" severity failure;
         end if;
      end procedure;
   begin
      wait for 20 * CLK_PERIOD;
      report "test 1: independent GPIO pings and librfu logins";
      login(HOST);
      assert ping_events(CHILD) = 0 and login_events(CHILD) = 0
         report "host login affected the child adapter" severity failure;
      login(CHILD);

      report "test 2: host broadcast, child scan/connect, slot-0 status";
      expect_command(HOST, x"10");
      -- afska reinitializes Normal-32 rather than changing only the speed.
      write_reg(HOST, SIOCNT, x"1000");
      write_reg(HOST, SIOCNT, x"1008");
      write_reg(HOST, SIOCNT, x"1009");
      write_reg(HOST, SIOCNT, x"100B");
      expect_command(HOST, x"16", GAME_CONFIG);
      expect_command(HOST, x"19");
      expect_command(HOST, x"1A"); -- no children yet
      expect_command(CHILD, x"10");
      command(CHILD, x"1D", NO_WORDS, scan);
      check_word(scan(0), HOST_ID, "advertised parent ID and entry slot");
      for i in GAME_CONFIG'range loop
         check_word(scan(i + 1), GAME_CONFIG(i), "broadcast word " & natural'image(i));
      end loop;
      expect_command(CHILD, x"1F", (0 => x"0000" & scan(0)(15 downto 0)));
      expect_command(HOST, x"1A", expected => (0 => CHILD_ID));
      expect_command(HOST, x"11", expected => (0 => x"000000FF"));

      report "test 3: bidirectional data, wait+TX reversal and handback";
      expect_command(HOST, x"25", HOST_FRAME);
      begin_reversal(HOST, 1, host_ticket);
      -- Host is already armed as clock slave. Only the child's actual TX
      -- creates its queued data and lets the backend inject the notify.
      expect_command(CHILD, x"24", CHILD_FRAME);
      receive_notify(HOST, host_ticket);
      expect_command(HOST, x"26", expected => CHILD_FRAME);
      await_count(notify_ack_events, HOST, 1, "notify ACK event");
      expect_command(CHILD, x"26", expected => HOST_FRAME);
      expect_command(HOST, x"26");
      expect_command(CHILD, x"26");

      report "test 4: retransmit, one-parameter notify and clean clock handback";
      -- Age SD high past the GPIO threshold before exercising the next
      -- external-clock handoff (which inevitably pulls SD back low).
      wait for 750 us;
      expect_command(HOST, x"37");
      begin_reversal(HOST, 2, host_ticket);
      receive_notify(HOST, host_ticket, (0 => x"00000100"));
      expect_command(HOST, x"11", expected => (0 => x"000000FF"));
      -- Prove retransmit actually requeued the old host frame, and exercise
      -- plain Wait as well as Wait+Tx: the child has data pending on entry.
      expect_command(CHILD, x"27");
      begin_reversal(CHILD, 1, child_ticket);
      receive_notify(CHILD, child_ticket);
      expect_command(CHILD, x"26", expected => HOST_FRAME);
      expect_command(CHILD, x"26");

      report "test 5: forward rejection keeps GBA master; reverse rejection keeps adapter master";
      expect_command(HOST, x"35", expected => (0 => x"00000001"), rejected => true);
      assert adapter_master(HOST) = '0' and reversal_events(HOST) = 2
         report "forward rejection reversed the clock" severity failure;
      expect_command(HOST, x"27");
      begin_reversal(HOST, 3, host_ticket);
      receive_notify(HOST, host_ticket, (0 => x"00000001"), cmd => x"27", rejected => true);
      arm_transfer(HOST, SLAVE, host_ticket);
      receive_notify(HOST, host_ticket, cmd => x"27");
      expect_command(HOST, x"26");
      await_count(notify_ack_events, HOST, 4, "including rejection ACK");
      await_count(notify_ack_events, CHILD, 1, "child notify ACK");
      for unit in unit_t loop
         assert ping_events(unit) = 1 report unit_t'image(unit) & ": false GPIO ping reset" severity failure;
      end loop;
      report "ALL WIRELESS RTL2RTL TESTS PASSED";
      std.env.finish;
      wait;
   end process;

   watchdog : process
   begin
      wait for 50 ms;
      assert false report "wireless RTL2RTL testbench timed out" severity failure;
      wait;
   end process;
end architecture;
