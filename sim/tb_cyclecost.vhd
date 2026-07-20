-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_cyclecost is
end entity;

architecture sim of tb_cyclecost is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal bus_Adr  : std_logic_vector(31 downto 0);
   signal bus_rnw  : std_logic;
   signal bus_ena  : std_logic;
   signal bus_seq  : std_logic;
   signal bus_code : std_logic;
   signal bus_acc  : std_logic_vector(1 downto 0);
   signal bus_dout : std_logic_vector(31 downto 0);
   signal bus_din  : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done : std_logic := '0';

   signal ss_bus : proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', "00", "0000", '0');

   constant K        : integer := 64;
   constant NSECTION : integer := 14;

   type t_names is array (0 to NSECTION-1) of string(1 to 12);
   constant sec_name : t_names := (
      "nop (ALU)   ",
      "ALU regshift",
      "MUL m=1     ",
      "MUL m=2     ",
      "MUL m=4     ",
      "MLA m=4     ",
      "UMULL m=4   ",
      "LDR         ",
      "STR         ",
      "LDRH        ",
      "LDM r0-r7   ",
      "STM r0-r7   ",
      "B taken     ",
      "SWP         ");

   type t_int_arr is array (0 to NSECTION-1) of integer;
   constant expected : t_int_arr := (1, 2, 2, 3, 5, 6, 6, 3, 2, 3, 10, 9, 3, 4);

   type t_ram is array (0 to 8191) of std_logic_vector(31 downto 0);

   impure function build_ram return t_ram is
      variable m : t_ram := (others => (others => '0'));
      variable p : integer := 0;

      procedure emit(w : std_logic_vector(31 downto 0)) is
      begin
         m(p) := w;
         p := p + 1;
      end procedure;

      procedure marker(idx : integer) is
         variable off : unsigned(11 downto 0);
      begin
         off := to_unsigned(idx * 4, 12);
         emit(x"E58CC" & std_logic_vector(off));
      end procedure;

      procedure section(sec : integer; instr : std_logic_vector(31 downto 0)) is
      begin
         marker(sec * 2);
         for i in 1 to K loop
            emit(instr);
         end loop;
         marker(sec * 2 + 1);
      end procedure;
   begin
      emit(x"E3A0BA01");
      emit(x"E3A0CA02");
      emit(x"E3A01003");

      section(0, x"E1A00000");

      emit(x"E3A02004");
      section(1, x"E1A03211");

      emit(x"E3A020FF");
      section(2, x"E0030291");

      emit(x"E3A02CFF");
      emit(x"E38220FF");
      section(3, x"E0030291");

      emit(x"E3E02102");
      section(4, x"E0030291");

      emit(x"E3A04005");
      section(5, x"E0234291");

      emit(x"E3E02000");
      section(6, x"E0843291");

      section(7, x"E59B3000");

      section(8, x"E58B3000");

      section(9, x"E1DB30B0");

      section(10, x"E89B00FF");

      section(11, x"E88B00FF");

      section(12, x"EAFFFFFF");

      emit(x"E3A01003");
      section(13, x"E10B3091");

      emit(x"EAFFFFFE");
      return m;
   end function;

   signal ram : t_ram := build_ram;

   signal cyc          : integer := 0;
   signal err          : std_logic;
   type t_stamp is array (0 to 2*NSECTION-1) of integer;
   signal stamps       : t_stamp := (others => -1);
   signal marker_count : integer := 0;
   signal done_seen    : std_logic := '0';

begin

   clk <= not clk after 5 ns;
   reset <= '0' after 100 ns;

   icpu : entity work.gba_cpu
   generic map (is_simu => '1')
   port map
   (
      clk           => clk,
      ce            => '1',
      reset         => reset,
      error_cpu     => err,
      savestate_bus => ss_bus,
      ss_wired_out  => open,
      ss_wired_done => open,
      gb_bus_Adr    => bus_Adr,
      gb_bus_rnw    => bus_rnw,
      gb_bus_ena    => bus_ena,
      gb_bus_seq    => bus_seq,
      gb_bus_code   => bus_code,
      gb_bus_acc    => bus_acc,
      gb_bus_dout   => bus_dout,
      gb_bus_din    => bus_din,
      gb_bus_done   => bus_done,
      bus_lowbits   => open,
      dma_on        => '0',
      done          => open,
      CPU_bus_idle  => open,
      PC_in_BIOS    => open,
      cpu_halt      => open,
      lastread      => open,
      jump_out      => open,
      IRQ_in        => '0',
      unhalt        => '0',
      new_halt      => '0'
   );

   mem : process (clk)
      variable idx  : integer;
      variable midx : integer;
   begin
      if rising_edge(clk) then
         cyc      <= cyc + 1;
         bus_done <= '0';
         if (bus_ena = '1') then
            bus_done <= '1';
            idx := to_integer(unsigned(bus_Adr(14 downto 2)));
            if (bus_Adr(31 downto 15) = (16 downto 0 => '0')) then
               if (bus_rnw = '1') then
                  bus_din <= ram(idx);
               else
                  if (bus_acc = "10") then
                     ram(idx) <= bus_dout;
                  end if;
                  if (bus_Adr(31 downto 8) = x"000020") then
                     midx := to_integer(unsigned(bus_Adr(7 downto 2)));
                     if (midx < 2*NSECTION) then
                        stamps(midx)  <= cyc;
                        marker_count  <= marker_count + 1;
                        if (midx = 2*NSECTION-1) then
                           done_seen <= '1';
                        end if;
                     end if;
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;

   check : process
      variable win      : t_int_arr;
      variable base     : integer;
      variable c100     : integer;
      variable gaps     : integer := 0;
   begin
      wait until done_seen = '1' for 3 ms;
      if (done_seen = '0') then
         report "CYCLECOST TIMEOUT: only " & integer'image(marker_count) &
                " of " & integer'image(2*NSECTION) & " markers seen" severity failure;
      end if;
      wait for 100 ns;

      for s in 0 to NSECTION-1 loop
         win(s) := stamps(2*s+1) - stamps(2*s);
      end loop;
      base := win(0);
      report "baseline window (K=" & integer'image(K) & " NOPs): " & integer'image(base) & " cycles";

      for s in 0 to NSECTION-1 loop
         c100 := 100 + ((win(s) - base) * 100) / K;
         if (c100 = expected(s) * 100) then
            report "CYCLE  " & sec_name(s) & " measured " & integer'image(c100) &
                   "  expected " & integer'image(expected(s)*100) & "  (x100)  OK";
         else
            report "CYCLE  " & sec_name(s) & " measured " & integer'image(c100) &
                   "  expected " & integer'image(expected(s)*100) & "  (x100)  GAP" severity warning;
            gaps := gaps + 1;
         end if;
      end loop;

      if (err = '1') then
         report "CPU error_cpu asserted during run" severity failure;
      end if;

      if (gaps = 0) then
         report "CYCLECOST: all " & integer'image(NSECTION) & " classes match ARM7TDMI" severity note;
      else
         report "CYCLECOST: " & integer'image(gaps) & " classes deviate from ARM7TDMI" severity warning;
      end if;
      stop;
   end process;

end architecture;
