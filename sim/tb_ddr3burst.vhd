-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.env.all;

library mem;
use work.pDDR3.all;

entity tb_ddr3burst is
end entity;

architecture sim of tb_ddr3burst is

   constant CLK_PERIOD : time := 10 ns;

   signal clk  : std_logic := '0';
   signal done : boolean := false;

   signal ddr3_BUSY       : std_logic := '0';
   signal ddr3_DOUT       : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr3_DOUT_READY : std_logic := '0';
   signal ddr3_BURSTCNT   : std_logic_vector(7 downto 0);
   signal ddr3_ADDR       : std_logic_vector(28 downto 0);
   signal ddr3_DIN        : std_logic_vector(63 downto 0);
   signal ddr3_BE         : std_logic_vector(7 downto 0);
   signal ddr3_WE         : std_logic;
   signal ddr3_RD         : std_logic;

   signal rdram_request    : tDDDR3Single     := (others => '0');
   signal rdram_rnw        : tDDDR3Single     := (others => '0');
   signal rdram_address    : tDDDR3ReqAddr    := (others => (others => '0'));
   signal rdram_burstcount : tDDDR3Burstcount := (others => (others => '0'));
   signal rdram_writeMask  : tDDDR3BwriteMask := (others => (others => '0'));
   signal rdram_dataWrite  : tDDDR3BwriteData := (others => (others => '0'));
   signal rdram_granted    : tDDDR3Single;
   signal rdram_done       : tDDDR3Single;
   signal rdram_ready      : tDDDR3Single;
   signal rdram_dataRead   : std_logic_vector(63 downto 0);

   signal fifo_Din   : std_logic_vector(63 downto 0) := (others => '0');
   signal fifo_Wr    : std_logic := '0';
   signal fifo_Dout  : std_logic_vector(63 downto 0);
   signal fifo_Rd    : std_logic;
   signal fifo_Empty : std_logic;

   constant MEM_QWORDS : integer := 4096;
   type t_mem is array (0 to MEM_QWORDS - 1) of std_logic_vector(63 downto 0);
   shared variable avmem     : t_mem := (others => (others => '0'));
   type t_int is array (0 to MEM_QWORDS - 1) of integer;
   shared variable wrhits    : t_int := (others => 0);

   signal pop_count  : integer := 0;
   signal done_count : integer := 0;

   signal lfsr : unsigned(15 downto 0) := x"ACE1";

   function qpattern(i : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(i, 32)) & std_logic_vector(to_unsigned(i * 7 + 3, 32));
   end function;

begin

   clk <= not clk after CLK_PERIOD / 2 when not done else '0';

   ififo : entity mem.SyncFifoFallThrough
   generic map (SIZE => 64, DATAWIDTH => 64, NEARFULLDISTANCE => 40)
   port map
   (
      clk => clk, reset => '0',
      Din => fifo_Din, Wr => fifo_Wr, Full => open, NearFull => open,
      Dout => fifo_Dout, Rd => fifo_Rd, Empty => fifo_Empty
   );

   idut : entity work.DDR3Mux
   generic map (gpufifo2_en => '0')
   port map
   (
      clk1x            => clk,
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
      gpufifo_reset    => '0',
      gpufifo_Din      => (others => '0'),
      gpufifo_Wr       => '0',
      gpufifo_nearfull => open,
      gpufifo_empty    => open,
      ssw_fifo_Dout    => fifo_Dout,
      ssw_fifo_Rd      => fifo_Rd
   );

   process (clk)
   begin
      if rising_edge(clk) then
         lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
         ddr3_BUSY <= '1' when (lfsr(2 downto 0) = "000" or lfsr(5 downto 4) = "11") else '0';
      end if;
   end process;

   avalon : process (clk)
      variable wr_remain : integer := 0;
      variable wr_addr   : integer := 0;
      variable rd_remain : integer := 0;
      variable rd_addr   : integer := 0;
      variable rd_delay  : integer := 0;
   begin
      if rising_edge(clk) then
         ddr3_DOUT_READY <= '0';

         if (ddr3_BUSY = '0') then
            if (ddr3_WE = '1') then
               if (wr_remain = 0) then
                  wr_addr   := to_integer(unsigned(ddr3_ADDR(11 downto 0)));
                  wr_remain := to_integer(unsigned(ddr3_BURSTCNT));
               end if;
               for b in 0 to 7 loop
                  if (ddr3_BE(b) = '1') then
                     avmem(wr_addr)(b*8 + 7 downto b*8) := ddr3_DIN(b*8 + 7 downto b*8);
                  end if;
               end loop;
               wrhits(wr_addr) := wrhits(wr_addr) + 1;
               wr_addr   := wr_addr + 1;
               wr_remain := wr_remain - 1;
            elsif (ddr3_RD = '1' and rd_remain = 0) then
               rd_addr   := to_integer(unsigned(ddr3_ADDR(11 downto 0)));
               rd_remain := to_integer(unsigned(ddr3_BURSTCNT));
               rd_delay  := 6;
            end if;
         end if;

         if (rd_remain > 0) then
            if (rd_delay > 0) then
               rd_delay := rd_delay - 1;
            elsif (lfsr(1) = '1') then
               ddr3_DOUT       <= avmem(rd_addr);
               ddr3_DOUT_READY <= '1';
               rd_addr   := rd_addr + 1;
               rd_remain := rd_remain - 1;
            end if;
         end if;
      end if;
   end process;

   pop_count  <= pop_count  + 1 when rising_edge(clk) and fifo_Rd = '1' and fifo_Empty = '0';
   done_count <= done_count + 1 when rising_edge(clk) and rdram_done(DDR3MUX_SS) = '1';

   control : process
      variable pat : integer := 0;

      procedure push(n : integer) is
      begin
         for i in 0 to n - 1 loop
            fifo_Din <= qpattern(pat);
            fifo_Wr  <= '1';
            pat      := pat + 1;
            wait until rising_edge(clk);
         end loop;
         fifo_Wr <= '0';
      end procedure;

      procedure burst_write(addr_qw : integer; n : integer) is
      begin
         rdram_request(DDR3MUX_SS)    <= '1';
         rdram_rnw(DDR3MUX_SS)        <= '0';
         rdram_address(DDR3MUX_SS)    <= to_unsigned(addr_qw * 8, 28);
         rdram_burstcount(DDR3MUX_SS) <= to_unsigned(n, 10);
         rdram_writeMask(DDR3MUX_SS)  <= x"FF";
         wait until rising_edge(clk);
         rdram_request(DDR3MUX_SS)    <= '0';
         wait until rising_edge(clk) and rdram_done(DDR3MUX_SS) = '1' for 100 us;
      end procedure;
   begin
      wait for 100 ns;
      wait until rising_edge(clk);

      for k in 0 to 7 loop
         push(16);
         burst_write(k * 16, 16);
      end loop;

      push(2);  burst_write(128, 2);
      push(5);  burst_write(130, 5);
      push(3);  burst_write(135, 3);

      rdram_dataWrite(DDR3MUX_SS) <= x"DEADBEEF00C0FFEE";
      avmem(200) := x"1111111122222222";
      rdram_request(DDR3MUX_SS)    <= '1';
      rdram_rnw(DDR3MUX_SS)        <= '0';
      rdram_address(DDR3MUX_SS)    <= to_unsigned(200 * 8, 28);
      rdram_burstcount(DDR3MUX_SS) <= to_unsigned(1, 10);
      rdram_writeMask(DDR3MUX_SS)  <= x"F0";
      wait until rising_edge(clk);
      rdram_request(DDR3MUX_SS)    <= '0';
      wait until rising_edge(clk) and rdram_done(DDR3MUX_SS) = '1' for 100 us;

      rdram_request(DDR3MUX_SS)    <= '1';
      rdram_rnw(DDR3MUX_SS)        <= '1';
      rdram_address(DDR3MUX_SS)    <= to_unsigned(3 * 8, 28);
      rdram_burstcount(DDR3MUX_SS) <= to_unsigned(1, 10);
      wait until rising_edge(clk);
      rdram_request(DDR3MUX_SS)    <= '0';
      wait until rising_edge(clk) and rdram_ready(DDR3MUX_SS) = '1' for 100 us;
      wait until rising_edge(clk);
      assert rdram_dataRead = qpattern(3)
         report "readback mismatch: got " & to_hstring(rdram_dataRead) &
                " want " & to_hstring(qpattern(3)) severity failure;

      wait for 1 us;

      for i in 0 to 137 loop
         assert wrhits(i) = 1
            report "qword " & integer'image(i) & " written " & integer'image(wrhits(i)) & " times"
            severity failure;
         assert avmem(i) = qpattern(i)
            report "qword " & integer'image(i) & " data mismatch: got " & to_hstring(avmem(i)) &
                   " want " & to_hstring(qpattern(i)) severity failure;
      end loop;
      assert avmem(200) = x"DEADBEEF22222222"
         report "partial-BE single write wrong: " & to_hstring(avmem(200)) severity failure;
      assert pop_count = 138
         report "fifo popped " & integer'image(pop_count) & " times, expected 138" severity failure;
      assert fifo_Empty = '1' report "fifo not empty at end" severity failure;
      assert done_count = 13
         report "done pulsed " & integer'image(done_count) & " times, expected 13" severity failure;

      report "DDR3BURST: PASS (138 beats, random waitrequest, all landed exactly once)";
      done <= true;
      stop;
   end process;

end architecture;
