-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use STD.env.all;
use IEEE.std_logic_textio.all;

use work.pProc_bus_gba.all;

entity tb_ssspeed is
end entity;

architecture sim of tb_ssspeed is

   constant CLK_PERIOD : time := 10 ns;

   constant LAT_DDR3_WACK : integer := 3;
   constant LAT_DDR3_READ : integer := 8;
   constant PAUSE_SETTLE  : integer := 300;

   signal clk  : std_logic := '0';
   signal done : boolean := false;

   signal save              : std_logic := '0';
   signal load              : std_logic := '0';
   signal savestate_busy    : std_logic;
   signal internal_bus_out  : proc_bus_gb_type;
   signal wired_out         : std_logic_vector(31 downto 0) := (others => '0');
   signal wired_done        : std_logic := '0';
   signal sleep_savestate   : std_logic;
   signal pause_active      : std_logic := '0';
   signal gb_bus            : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');
   signal reset_out         : std_logic;
   signal load_done         : std_logic;

   signal SAVE_BusAddr      : std_logic_vector(27 downto 0);
   signal SAVE_BusRnW       : std_logic;
   signal SAVE_BusACC       : std_logic_vector(1 downto 0);
   signal SAVE_BusWriteData : std_logic_vector(31 downto 0);
   signal SAVE_Bus_ena      : std_logic;
   signal SAVE_BusReadData  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVE_BusReadDone  : std_logic := '0';

   signal bus_out_Din       : std_logic_vector(63 downto 0);
   signal bus_out_Dout      : std_logic_vector(63 downto 0) := (others => '0');
   signal bus_out_Adr       : std_logic_vector(25 downto 0);
   signal bus_out_rnw       : std_logic;
   signal bus_out_ena       : std_logic;
   signal bus_out_active    : std_logic;
   signal bus_out_be        : std_logic_vector(7 downto 0);
   signal bus_out_done      : std_logic := '0';
   signal bus_out_burstcnt  : std_logic_vector(7 downto 0);
   signal fifo_Din          : std_logic_vector(63 downto 0);
   signal fifo_Wr           : std_logic;
   signal fifo_NearFull     : std_logic := '0';

   constant MEM_QWORDS : integer := 65536;
   type t_mem is array (0 to MEM_QWORDS - 1) of std_logic_vector(63 downto 0);
   shared variable ddr3mem : t_mem := (others => (others => '0'));

   constant STATESIZE_DW : integer := 16#18346#;

   function memword(addr : std_logic_vector(27 downto 0)) return std_logic_vector is
   begin
      return (x"C" & addr) xor x"5EEDBEEF";
   end function;

   signal cyc            : integer := 0;
   signal load_done_seen : std_logic := '0';
   signal queue_check    : std_logic := '0';
   signal save_cycles    : integer := 0;
   signal load_cycles    : integer := 0;
   signal save_wr_count  : integer := 0;
   signal load_chk_count : integer := 0;
   signal region_mark    : std_logic_vector(3 downto 0) := x"0";

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   idut : entity work.gba_savestates
   generic map
   (
      Softmap_GBA_FLASH_ADDR  => 0,
      Softmap_GBA_EEPROM_ADDR => 0,
      is_simu                 => '1'
   )
   port map
   (
      clk                   => clk,
      gb_on                 => '1',
      reset                 => reset_out,
      register_reset        => open,
      load_done             => load_done,
      increaseSSHeaderCount => '1',
      save                  => save,
      load                  => load,
      savestate_address     => 0,
      savestate_busy        => savestate_busy,
      internal_bus_out      => internal_bus_out,
      wired_out             => wired_out,
      wired_done            => wired_done,
      loading_savestate     => open,
      saving_savestate      => open,
      sleep_savestate       => sleep_savestate,
      pause_active          => pause_active,
      gb_bus                => gb_bus,
      SAVE_BusAddr          => SAVE_BusAddr,
      SAVE_BusRnW           => SAVE_BusRnW,
      SAVE_BusACC           => SAVE_BusACC,
      SAVE_BusWriteData     => SAVE_BusWriteData,
      SAVE_Bus_ena          => SAVE_Bus_ena,
      SAVE_BusReadData      => SAVE_BusReadData,
      SAVE_BusReadDone      => SAVE_BusReadDone,
      bus_out_Din           => bus_out_Din,
      bus_out_Dout          => bus_out_Dout,
      bus_out_Adr           => bus_out_Adr,
      bus_out_rnw           => bus_out_rnw,
      bus_out_ena           => bus_out_ena,
      bus_out_active        => bus_out_active,
      bus_out_be            => bus_out_be,
      bus_out_done          => bus_out_done,
      bus_out_burstcnt      => bus_out_burstcnt,
      fifo_Din              => fifo_Din,
      fifo_Wr               => fifo_Wr,
      fifo_NearFull         => fifo_NearFull
   );

   cyc <= cyc + 1 when rising_edge(clk);

   process (clk)
   begin
      if rising_edge(clk) then
         if (load_done = '1') then load_done_seen <= '1'; end if;
      end if;
   end process;

   pausemodel : process (clk)
      variable cnt : integer := 0;
   begin
      if rising_edge(clk) then
         if (sleep_savestate = '1') then
            if (cnt < PAUSE_SETTLE) then
               cnt := cnt + 1;
            else
               pause_active <= '1';
            end if;
         else
            cnt := 0;
            pause_active <= '0';
         end if;
      end if;
   end process;

   wired_done <= '1';
   wired_out  <= x"A" & internal_bus_out.Adr;

   savebus : process (clk)
      variable p1_valid, p2_valid : std_logic := '0';
      variable p1_addr,  p2_addr  : std_logic_vector(27 downto 0);
      variable wrdone             : std_logic_vector(2 downto 0) := (others => '0');
   begin
      if rising_edge(clk) then
         SAVE_BusReadDone <= wrdone(2);
         wrdone := wrdone(1 downto 0) & '0';

         if (p2_valid = '1') then
            SAVE_BusReadData <= memword(p2_addr);
            SAVE_BusReadDone <= '1';
         end if;
         p2_valid := p1_valid;
         p2_addr  := p1_addr;
         p1_valid := '0';

         if (SAVE_Bus_ena = '1') then
            if (SAVE_BusRnW = '1') then
               p1_valid := '1';
               p1_addr  := SAVE_BusAddr;
            else
               if (SAVE_BusAddr(27 downto 24) = x"2" or
                   SAVE_BusAddr(27 downto 24) = x"3" or
                   SAVE_BusAddr(27 downto 24) = x"5" or
                   SAVE_BusAddr(27 downto 24) = x"6" or
                   SAVE_BusAddr(27 downto 24) = x"7") then
                  assert SAVE_BusWriteData = memword(SAVE_BusAddr)
                     report "load data mismatch at " & to_hstring(SAVE_BusAddr) &
                            " got " & to_hstring(SAVE_BusWriteData) &
                            " want " & to_hstring(memword(SAVE_BusAddr))
                     severity failure;
                  load_chk_count <= load_chk_count + 1;
               end if;
               wrdone(0) := '1';
            end if;
         end if;
      end if;
   end process;

   ddr3 : process (clk)
      variable queue   : t_mem;
      variable q_wr    : integer := 0;
      variable q_rd    : integer := 0;
      variable lat     : integer := 0;
      variable pending : std_logic := '0';
      variable qidx    : integer;
      variable n       : integer;
   begin
      if rising_edge(clk) then
         bus_out_done <= '0';

         if (fifo_Wr = '1') then
            queue(q_wr mod MEM_QWORDS) := fifo_Din;
            q_wr := q_wr + 1;
         end if;
         if (q_wr - q_rd >= 40) then
            fifo_NearFull <= '1';
         else
            fifo_NearFull <= '0';
         end if;

         if (pending = '1') then
            if (lat > 1) then
               lat := lat - 1;
            else
               pending      := '0';
               bus_out_done <= '1';
            end if;
         end if;

         if (bus_out_ena = '1') then
            assert pending = '0' report "bus_out request while previous in flight" severity failure;
            qidx := to_integer(unsigned(bus_out_Adr(25 downto 1)));
            assert qidx < MEM_QWORDS report "bus_out addr out of model range" severity failure;
            if (bus_out_rnw = '0') then
               n := to_integer(unsigned(bus_out_burstcnt));
               assert n >= 1 report "write burstcnt 0" severity failure;
               if (n = 1) then
                  for b in 0 to 7 loop
                     if (bus_out_be(b) = '1') then
                        ddr3mem(qidx)(b*8 + 7 downto b*8) := bus_out_Din(b*8 + 7 downto b*8);
                     end if;
                  end loop;
               else
                  assert bus_out_be = x"FF" report "burst write with partial BE" severity failure;
                  assert q_wr - q_rd >= n
                     report "burst requests " & integer'image(n) & " beats, FIFO holds " &
                            integer'image(q_wr - q_rd) severity failure;
                  for b in 0 to n - 1 loop
                     ddr3mem(qidx + b) := queue(q_rd mod MEM_QWORDS);
                     q_rd := q_rd + 1;
                  end loop;
               end if;
               save_wr_count <= save_wr_count + n;
               pending := '1';
               lat     := LAT_DDR3_WACK + n - 1;
            else
               assert unsigned(bus_out_burstcnt) = 1 report "read burstcnt must be 1" severity failure;
               bus_out_Dout <= ddr3mem(qidx);
               pending := '1';
               lat     := LAT_DDR3_READ;
            end if;
         end if;

         if (queue_check = '1') then
            assert q_wr = q_rd report "staging FIFO not empty at end of save: " &
                   integer'image(q_wr - q_rd) severity failure;
         end if;
      end if;
   end process;

   region_mark <= SAVE_BusAddr(27 downto 24);

   control : process
      variable t0, t1        : integer;
      variable mark_cyc      : integer;
      variable last_region   : std_logic_vector(3 downto 0) := x"F";
      file     fout          : text;
      variable ln            : line;
   begin
      wait for 200 ns;
      wait until savestate_busy = '0' for 1 ms;
      assert savestate_busy = '0' report "never reached IDLE after reset" severity failure;
      wait until rising_edge(clk);

      save <= '1';
      wait until rising_edge(clk);
      save <= '0';

      wait until sleep_savestate = '1' for 1 ms;
      assert sleep_savestate = '1' report "save never started" severity failure;
      t0 := cyc;
      mark_cyc    := cyc;
      last_region := x"F";

      while sleep_savestate = '1' loop
         wait until rising_edge(clk);
         if (SAVE_Bus_ena = '1' and SAVE_BusRnW = '1' and region_mark /= last_region) then
            if (last_region /= x"F") then
               report "region 0x" & to_hstring(last_region) & " took " &
                      integer'image(cyc - mark_cyc) & " cycles";
            else
               report "internals+register phase took " &
                      integer'image(cyc - t0) & " cycles";
            end if;
            last_region := region_mark;
            mark_cyc    := cyc;
         end if;
      end loop;
      report "region 0x" & to_hstring(last_region) & " took " &
             integer'image(cyc - mark_cyc) & " cycles (incl. size/header tail)";
      t1 := cyc;
      save_cycles <= t1 - t0;
      wait until rising_edge(clk);

      queue_check <= '1';
      wait until rising_edge(clk);
      queue_check <= '0';

      report "SSSPEED SAVE sleep_savestate held " & integer'image(save_cycles) &
             " cycles (" & integer'image(save_cycles / 16777) & " ms at 16.777 MHz, model: 2-deep read pipe, ddr3wack=" &
             integer'image(LAT_DDR3_WACK) & ")";
      report "SSSPEED SAVE bus_out writes: " & integer'image(save_wr_count);

      assert save_wr_count = 49571
         report "expected 49571 ddr3 writes (49570 body qwords + size header), got " &
                integer'image(save_wr_count) severity failure;

      file_open(fout, "sim/tests/ssspeed_image.hex", write_mode);
      for i in 0 to (STATESIZE_DW / 2) loop
         hwrite(ln, ddr3mem(i));
         writeline(fout, ln);
      end loop;
      file_close(fout);
      report "image dumped: sim/tests/ssspeed_image.hex (" &
             integer'image(STATESIZE_DW / 2 + 1) & " qwords)";

      wait for 1 us;
      wait until rising_edge(clk);
      load <= '1';
      wait until rising_edge(clk);
      load <= '0';

      wait until sleep_savestate = '1' for 1 ms;
      assert sleep_savestate = '1' report "load never started" severity failure;
      t0 := cyc;
      wait until sleep_savestate = '0' for 100 ms;
      assert sleep_savestate = '0' report "load never finished" severity failure;
      t1 := cyc;
      load_cycles <= t1 - t0;

      if (load_done_seen = '0') then
         wait until load_done_seen = '1' for 1 ms;
      end if;
      assert load_done_seen = '1' report "load_done never pulsed" severity failure;
      wait until savestate_busy = '0' for 1 ms;
      assert savestate_busy = '0' report "never returned to IDLE after load" severity failure;
      wait until rising_edge(clk);

      report "SSSPEED LOAD sleep_savestate held " & integer'image(load_cycles) &
             " cycles (" & integer'image(load_cycles / 16777) & " ms at 16.777 MHz)";
      report "SSSPEED LOAD memory writes checked: " & integer'image(load_chk_count);

      assert load_chk_count = 98816
         report "expected 98816 checked load writes, got " & integer'image(load_chk_count)
         severity failure;

      report "SSSPEED: PASS";
      done <= true;
      stop;
   end process;

end architecture;
