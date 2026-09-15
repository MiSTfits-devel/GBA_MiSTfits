-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- unit bench for the GBA Multiboot sender (gba_multiboot). A behavioural
-- model of a real GBA sitting in its BIOS multiboot slave loop answers on
-- the other end of the cable, through the real gba_linkport so the SNAC pin
-- mapping, open drain drive and input synchronizers are all in the path.
--
-- The slave model is a faithful mirror of the sender: it validates every
-- command word it receives, answers with the descending header index, picks
-- its own encryption seed byte, DECRYPTS every payload word and compares it
-- against the image, and computes its own CRC to hand back at the end. So a
-- passing run means the Kawasedo encryption and the CRC are both right, not
-- just that the handshake framing lines up.
--
-- Checks, in order:
--   1) an undersized image is rejected before anything is driven
--   2) no slave on the cable -> the handshake step times out
--   3) a wrong master-role answer -> failure reported at that step
--   4) full upload: every step passes, the slave's CRC matches ours
--   5) the slave really saw all 96 header halfwords and every payload word
--      decrypted back to the image
--
-- run: sim/run_multiboot_tb.sh
entity tb_multiboot is
end entity;

architecture sim of tb_multiboot is

   constant CLK_PERIOD : time    := 59.6 ns;
   constant CLKSPEED   : integer := 16777216;
   constant IMAGE_ADDR : integer := 16#C000000#;
   -- POLL_US and HS_TIMEOUT_MS are shrunk from their real 62500 us / 10 s so
   -- the polling paths are still exercised in a few ms of simulated time
   constant POLL_US    : integer := 2000;
   constant HS_TO_MS   : integer := 20;

   constant IMG_SIZE   : integer := 1024;  -- 0xC0 header + 208 payload words
   constant PAY_WORDS  : integer := (IMG_SIZE - 16#C0#) / 4;

   constant CRC_XX     : unsigned(31 downto 0) := x"0000C37B";
   constant MULK       : unsigned(31 downto 0) := x"6F646573";
   constant KK         : unsigned(31 downto 0) := x"43202F2F";
   constant SEED_BYTE  : std_logic_vector(7 downto 0) := x"AB"; -- the slave's choice
   constant RR_BYTE    : std_logic_vector(7 downto 0) := x"5C";

   signal clk  : std_logic := '0';
   signal done : boolean := false;

   -- sender pins
   signal mb_sc_out, mb_sc_oe, mb_so_out, mb_so_oe, mb_sd_out, mb_sd_oe : std_logic;
   signal lp_clk_in, lp_si_in, lp_sd_in : std_logic;
   signal user_in, user_out : std_logic_vector(6 downto 0);

   -- cable
   signal sc_line : std_logic;
   signal s_si    : std_logic;   -- our SO -> slave SI
   signal s_so    : std_logic := '1'; -- slave SO -> our SI

   -- DDR3 model
   signal ddr3_request  : std_logic;
   signal ddr3_address  : unsigned(27 downto 0);
   signal ddr3_granted  : std_logic := '0';
   signal ddr3_done     : std_logic := '0';
   signal ddr3_dataRead : std_logic_vector(63 downto 0) := (others => '0');

   -- sender control / status
   signal mb_enable  : std_logic := '1';
   signal mb_start   : std_logic := '0';
   signal mb_size    : unsigned(19 downto 0) := (others => '0');
   signal mb_busy    : std_logic;
   signal mb_done    : std_logic;
   signal mb_fail    : std_logic;
   signal mb_step    : std_logic_vector(3 downto 0);
   signal mb_percent : unsigned(6 downto 0);
   signal mb_lastrx  : std_logic_vector(15 downto 0);

   -- slave model
   signal slave_on  : std_logic := '0';
   signal bad_role  : std_logic := '0';
   signal sc_prev   : std_logic := '1';
   signal s_bit     : integer range 0 to 31 := 0;
   signal s_rx      : std_logic_vector(31 downto 0) := (others => '0');
   signal s_txs     : std_logic_vector(31 downto 0) := (others => '1');
   signal s_tx      : std_logic_vector(31 downto 0) := x"72026202";
   signal s_word    : std_logic_vector(31 downto 0) := (others => '0');
   signal s_wdone   : std_logic := '0';

   signal hdr_seen  : integer := 0;
   signal pay_seen  : integer := 0;
   signal crc_ok    : std_logic := '0';

   -- deterministic stand-in for a real multiboot image; both the DDR3 model
   -- and the slave derive their bytes from it
   function img_byte(a : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(((a * 37) + ((a / 4) * 11) + 83) mod 256, 8));
   end function;

   function img_hw(a : integer) return std_logic_vector is
   begin
      return img_byte(a + 1) & img_byte(a);
   end function;

   function img_word(a : integer) return std_logic_vector is
   begin
      return img_byte(a + 3) & img_byte(a + 2) & img_byte(a + 1) & img_byte(a);
   end function;

   -- GbaCrc::add, Normal mode
   procedure crc_add(variable c : inout unsigned(31 downto 0); dat : in unsigned(31 downto 0)) is
      variable d : unsigned(31 downto 0);
      variable t : unsigned(31 downto 0);
   begin
      d := dat;
      for i in 0 to 31 loop
         t := c xor d;
         c := '0' & c(31 downto 1);
         d := '0' & d(31 downto 1);
         if (t(0) = '1') then
            c := c xor CRC_XX;
         end if;
      end loop;
   end procedure;

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   ------------------------------------------------------------------
   -- real SNAC path plus the external cable: our SO crosses to the GBA's
   -- SI, its SO comes back on our SI, SC is shared, SD released
   ------------------------------------------------------------------
   ilinkport : entity work.gba_linkport
   port map
   (
      clk          => clk,
      port_enable  => '1',
      user_in      => user_in,
      user_out     => user_out,
      link_clk_out => mb_sc_out,
      link_clk_oe  => mb_sc_oe,
      link_clk_in  => lp_clk_in,
      link_so_out  => mb_so_out,
      link_so_oe   => mb_so_oe,
      link_si_in   => lp_si_in,
      link_sd_out  => mb_sd_out,
      link_sd_oe   => mb_sd_oe,
      link_sd_in   => lp_sd_in
   );

   sc_line <= '0' when user_out(0) = '0' else '1';
   s_si    <= user_out(1);

   user_in(0) <= sc_line;
   user_in(1) <= user_out(1);
   user_in(2) <= s_so;
   user_in(3) <= '1';
   user_in(4) <= '1';
   user_in(5) <= user_out(5);
   user_in(6) <= '1';

   idut : entity work.gba_multiboot
   generic map
   (
      CLKSPEED      => CLKSPEED,
      IMAGE_ADDR    => IMAGE_ADDR,
      SCK_HZ        => 256000,
      GAP_US        => 150,
      POLL_US       => POLL_US,
      HS_TIMEOUT_MS => HS_TO_MS
   )
   port map
   (
      clk           => clk,
      reset         => '0',
      mb_enable     => mb_enable,
      mb_start      => mb_start,
      mb_size       => mb_size,
      link_sc_out   => mb_sc_out,
      link_sc_oe    => mb_sc_oe,
      link_so_out   => mb_so_out,
      link_so_oe    => mb_so_oe,
      link_si_in    => lp_si_in,
      link_sd_out   => mb_sd_out,
      link_sd_oe    => mb_sd_oe,
      ddr3_request  => ddr3_request,
      ddr3_address  => ddr3_address,
      ddr3_granted  => ddr3_granted,
      ddr3_done     => ddr3_done,
      ddr3_dataRead => ddr3_dataRead,
      mb_busy       => mb_busy,
      mb_done       => mb_done,
      mb_fail       => mb_fail,
      mb_step       => mb_step,
      mb_percent    => mb_percent,
      mb_lastrx     => mb_lastrx
   );

   ------------------------------------------------------------------
   -- DDR3Mux stand-in: grant, then one 64bit beat of the 8 byte aligned
   -- line, exactly the handshake gba_mem_cart_ddr3 sees
   ------------------------------------------------------------------
   ddr3 : process (clk)
      variable dstate : integer range 0 to 2 := 0;
      variable dadr   : unsigned(27 downto 0) := (others => '0');
      variable base   : integer;
      variable dat    : std_logic_vector(63 downto 0);
   begin
      if rising_edge(clk) then
         ddr3_granted <= '0';
         ddr3_done    <= '0';
         case dstate is
            when 0 =>
               if (ddr3_request = '1') then
                  ddr3_granted <= '1';
                  dadr   := ddr3_address;
                  dstate := 1;
               end if;
            when 1 =>
               dstate := 2;
            when 2 =>
               base := ((to_integer(dadr) - IMAGE_ADDR) / 8) * 8;
               assert base >= 0 and base < IMAGE_ADDR
                  report "sender read outside the image window" severity failure;
               for i in 0 to 7 loop
                  dat(i * 8 + 7 downto i * 8) := img_byte(base + i);
               end loop;
               ddr3_dataRead <= dat;
               ddr3_done     <= '1';
               dstate := 0;
         end case;
      end if;
   end process;

   ------------------------------------------------------------------
   -- slave shift engine: Normal-32, MSB first, our data changes on SC
   -- falling and we sample the master's bit on SC rising
   ------------------------------------------------------------------
   shifter : process (clk)
   begin
      if rising_edge(clk) then
         s_wdone <= '0';
         sc_prev <= sc_line;
         if (slave_on = '1') then
            if (sc_prev = '1' and sc_line = '0') then
               if (s_bit = 0) then
                  s_so  <= s_tx(31);
                  s_txs <= s_tx(30 downto 0) & '1';
               else
                  s_so  <= s_txs(31);
                  s_txs <= s_txs(30 downto 0) & '1';
               end if;
            elsif (sc_prev = '0' and sc_line = '1') then
               s_rx <= s_rx(30 downto 0) & s_si;
               if (s_bit = 31) then
                  s_bit   <= 0;
                  s_word  <= s_rx(30 downto 0) & s_si;
                  s_wdone <= '1';
               else
                  s_bit <= s_bit + 1;
               end if;
            end if;
         else
            s_so  <= '1';
            s_bit <= 0;
         end if;
      end if;
   end process;

   ------------------------------------------------------------------
   -- slave protocol: the GBA BIOS multiboot loop, written behaviourally
   ------------------------------------------------------------------
   slave : process
      variable rx    : std_logic_vector(31 downto 0);
      variable seed  : unsigned(31 downto 0);
      variable crc   : unsigned(31 downto 0);
      variable ptr   : unsigned(31 downto 0);
      variable plain : std_logic_vector(31 downto 0);
      variable fin   : unsigned(31 downto 0);
      variable hh    : unsigned(7 downto 0);
      variable rr    : unsigned(7 downto 0);
      variable pal   : std_logic_vector(7 downto 0);
      variable off   : integer;

      procedure getword(variable r : out std_logic_vector(31 downto 0)) is
      begin
         loop
            wait until rising_edge(clk);
            exit when s_wdone = '1';
         end loop;
         r := s_word;
      end procedure;
   begin
      ------------------------------------------------------------------
      -- role handshake. 0x6202 and 0x6102 both get 0x7202 back; while
      -- bad_role is set the 0x6102 answer is deliberately garbage and we
      -- stay here so the sender can retry once it is cleared.
      loop
         getword(rx);
         if (rx(15 downto 0) = x"6202") then
            if (bad_role = '1') then
               s_tx <= x"12340000";
            else
               s_tx <= x"72020000";
            end if;
         elsif (rx(15 downto 0) = x"6102") then
            exit when bad_role = '0';
            s_tx <= x"72020000";
         end if;
      end loop;

      ------------------------------------------------------------------
      -- 0xC0 byte header as 96 halfwords, answered with a descending index
      s_tx <= std_logic_vector(to_unsigned(96, 8)) & x"02" & x"0000";
      for k in 0 to 95 loop
         getword(rx);
         assert rx(15 downto 0) = img_hw(k * 2)
            report "header halfword " & integer'image(k) & " wrong: got " &
                   to_hstring(rx(15 downto 0)) & " want " & to_hstring(img_hw(k * 2))
            severity failure;
         hdr_seen <= k + 1;
         if (k = 95) then
            s_tx <= x"0002" & x"0000";
         else
            s_tx <= std_logic_vector(to_unsigned(95 - k, 8)) & x"02" & x"0000";
         end if;
      end loop;

      getword(rx);
      assert rx(15 downto 0) = x"6200" report "header end word wrong: " & to_hstring(rx) severity failure;
      s_tx <= x"72020000";

      getword(rx);
      assert rx(15 downto 0) = x"6202" report "second role word wrong: " & to_hstring(rx) severity failure;
      s_tx <= x"73" & SEED_BYTE & x"0000";

      ------------------------------------------------------------------
      -- palette out, encryption seed byte back
      getword(rx);
      assert rx(15 downto 8) = x"63" report "palette word wrong: " & to_hstring(rx) severity failure;
      pal  := rx(7 downto 0);
      seed := unsigned(x"FFFF" & SEED_BYTE & pal);
      hh   := unsigned(SEED_BYTE) + 16#0F#;
      rr   := unsigned(RR_BYTE);
      s_tx <= x"7300" & x"0000";

      getword(rx);
      assert rx(15 downto 8) = x"64" report "crc seed word wrong: " & to_hstring(rx) severity failure;
      assert rx(7 downto 0) = std_logic_vector(hh)
         report "crc seed byte wrong: got " & to_hstring(rx(7 downto 0)) & " want " & to_hstring(hh)
         severity failure;
      s_tx <= x"73" & RR_BYTE & x"0000";

      getword(rx);
      assert rx(15 downto 0) = std_logic_vector(to_unsigned(PAY_WORDS - 16#34#, 16))
         report "length word wrong: got " & to_hstring(rx(15 downto 0)) severity failure;
      s_tx <= x"00C0" & x"0000";

      ------------------------------------------------------------------
      -- encrypted main block: decrypt, compare, accumulate our own CRC
      crc := x"0000C387";
      off := 16#C0#;
      while off < IMG_SIZE loop
         getword(rx);
         seed  := resize(seed * MULK, 32) + 1;
         ptr   := (not (to_unsigned(off, 32) + x"02000000")) + 1;
         plain := std_logic_vector((unsigned(rx) xor seed) xor (ptr xor KK));
         assert plain = img_word(off)
            report "payload word at 0x" & to_hstring(to_unsigned(off, 20)) & " decrypted to " &
                   to_hstring(plain) & " want " & to_hstring(img_word(off))
            severity failure;
         crc_add(crc, unsigned(plain));
         pay_seen <= ((off - 16#C0#) / 4) + 1;
         off := off + 4;
         s_tx <= std_logic_vector(to_unsigned(off mod 65536, 16)) & x"0000";
      end loop;

      ------------------------------------------------------------------
      -- size confirmation, then one busy answer before the CRC is ready
      getword(rx);
      assert rx(15 downto 0) = x"0065" report "size confirm word wrong: " & to_hstring(rx) severity failure;
      s_tx <= x"0074" & x"0000";

      getword(rx);
      assert rx(15 downto 0) = x"0065" report "crc poll word wrong: " & to_hstring(rx) severity failure;
      s_tx <= x"0075" & x"0000";

      getword(rx);
      assert rx(15 downto 0) = x"0065" report "crc poll word wrong: " & to_hstring(rx) severity failure;
      s_tx <= x"0075" & x"0000";

      getword(rx);
      assert rx(15 downto 0) = x"0066" report "crc request word wrong: " & to_hstring(rx) severity failure;

      -- GbaCrc::finalize with the 0x0075 we just answered
      fin := (shift_left(resize(to_unsigned(16#0075#, 16) and x"FF00", 32) + resize(rr, 32), 8) or x"FFFF0000") + resize(hh, 32);
      crc_add(crc, fin);
      s_tx <= std_logic_vector(crc(15 downto 0)) & x"0000";

      getword(rx);
      report "slave crc " & to_hstring(crc(15 downto 0)) & ", sender sent " & to_hstring(rx(15 downto 0));
      assert rx(15 downto 0) = std_logic_vector(crc(15 downto 0))
         report "checksum mismatch: sender " & to_hstring(rx(15 downto 0)) &
                " slave " & to_hstring(crc(15 downto 0)) severity failure;
      crc_ok <= '1';
      wait;
   end process;

   ------------------------------------------------------------------
   main : process
      procedure trigger is
      begin
         mb_start <= '1';
         wait for 20 * CLK_PERIOD;
         mb_start <= '0';
         wait for 20 * CLK_PERIOD;
      end procedure;
   begin
      wait for 20 * CLK_PERIOD;

      ------------------------------------------------------------------
      report "test 1: undersized image is rejected";
      mb_size <= to_unsigned(256, 20);
      trigger;
      assert mb_fail = '1' and mb_step = x"E"
         report "undersized image not rejected (fail=" & std_logic'image(mb_fail) &
                " step=" & to_hstring(mb_step) & ")" severity failure;
      assert mb_busy = '0' report "sender claimed the link for a bad image" severity failure;
      assert user_out(0) = '1' and user_out(1) = '1' and user_out(5) = '1'
         report "sender drove the link port while idle" severity failure;
      report "test 1 passed";

      ------------------------------------------------------------------
      report "test 2: no slave on the cable -> handshake timeout";
      mb_size  <= to_unsigned(IMG_SIZE, 20);
      slave_on <= '0';
      trigger;
      wait until mb_fail = '1' for 100 ms;
      assert mb_fail = '1' report "handshake never timed out" severity failure;
      assert mb_step = x"1"
         report "timeout reported at the wrong step: " & to_hstring(mb_step) severity failure;
      report "test 2 passed";

      ------------------------------------------------------------------
      report "test 3: wrong master role answer -> failure at that step";
      slave_on <= '1';
      bad_role <= '1';
      wait for 10 * CLK_PERIOD;
      trigger;
      wait until mb_fail = '1' for 100 ms;
      assert mb_fail = '1' report "bad role answer was not caught" severity failure;
      assert mb_step = x"2"
         report "role failure reported at the wrong step: " & to_hstring(mb_step) severity failure;
      assert mb_lastrx = x"1234"
         report "wrong response not captured for the overlay: " & to_hstring(mb_lastrx) severity failure;
      report "test 3 passed";

      ------------------------------------------------------------------
      report "test 4: full upload, checksum accepted";
      bad_role <= '0';
      wait for 10 * CLK_PERIOD;
      trigger;
      wait until mb_done = '1' for 300 ms;
      -- mb_step / mb_percent / mb_busy are concurrent assignments off internal
      -- registers, so they settle one delta after mb_done in simulation
      wait for 4 * CLK_PERIOD;
      assert mb_done = '1'
         report "upload never completed (step=" & to_hstring(mb_step) &
                " fail=" & std_logic'image(mb_fail) & " rx=" & to_hstring(mb_lastrx) & ")"
         severity failure;
      assert mb_fail = '0' report "upload completed but flagged failure" severity failure;
      assert mb_step = x"F" report "final step code wrong: " & to_hstring(mb_step) severity failure;
      assert mb_percent = 100
         report "progress did not reach 100: " & integer'image(to_integer(mb_percent)) severity failure;
      assert crc_ok = '1' report "slave never accepted the checksum" severity failure;
      assert mb_busy = '0' report "sender still holds the link after finishing" severity failure;
      assert user_out(0) = '1' and user_out(1) = '1'
         report "sender left the link port driven after finishing" severity failure;
      report "test 4 passed";

      ------------------------------------------------------------------
      report "test 5: slave saw the whole image";
      assert hdr_seen = 96
         report "slave saw " & integer'image(hdr_seen) & " header halfwords, want 96" severity failure;
      assert pay_seen = PAY_WORDS
         report "slave saw " & integer'image(pay_seen) & " payload words, want " &
                integer'image(PAY_WORDS) severity failure;
      report "test 5 passed";

      report "ALL MULTIBOOT TESTS PASSED";
      done <= true;
      wait;
   end process;

end architecture;
