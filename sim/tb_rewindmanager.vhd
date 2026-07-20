-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;


entity tb_rewindmanager is
end entity;

architecture sim of tb_rewindmanager is

   constant CLK_PERIOD : time := 10 ns;

   constant TIME_CAPTURE : integer := 2000;
   constant TIME_REWIND  : integer := 700;

   constant SAVE_ADDR    : integer := 58720256;
   constant REWIND_ADDR  : integer := 33554432;
   constant SLOT_SIZE    : integer := 16#20000#;

   signal clk1x             : std_logic := '0';
   signal gb_on             : std_logic := '0';
   signal rewind_on         : std_logic := '0';
   signal rewind_active     : std_logic := '0';
   signal savestate_number  : integer := 0;
   signal save              : std_logic := '0';
   signal load              : std_logic := '0';
   signal sleep_rewind      : std_logic;
   signal vsync             : std_logic := '0';
   signal request_savestate : std_logic;
   signal request_loadstate : std_logic;
   signal request_address   : integer;
   signal request_busy      : std_logic := '0';

   signal running : boolean := true;

   type tReqKind is (SAVE_REQ, LOAD_REQ);
   type tReqEntry is record
      kind : tReqKind;
      addr : integer;
   end record;
   type tReqLog is array (0 to 63) of tReqEntry;
   signal req_log   : tReqLog;
   signal req_count : integer := 0;

begin

   clk1x <= not clk1x after CLK_PERIOD / 2 when running else '0';

   uut : entity work.gba_statemanager
   generic map
   (
      Softmap_SaveState_ADDR => SAVE_ADDR,
      Softmap_Rewind_ADDR    => REWIND_ADDR,
      TIME_CAPTURE           => TIME_CAPTURE,
      TIME_REWIND            => TIME_REWIND
   )
   port map
   (
      clk1x             => clk1x,
      gb_on             => gb_on,
      rewind_on         => rewind_on,
      rewind_active     => rewind_active,
      savestate_number  => savestate_number,
      save              => save,
      load              => load,
      sleep_rewind      => sleep_rewind,
      vsync             => vsync,
      request_savestate => request_savestate,
      request_loadstate => request_loadstate,
      request_address   => request_address,
      request_busy      => request_busy
   );

   monitor : process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (request_savestate = '1') then
            req_log(req_count) <= (kind => SAVE_REQ, addr => request_address);
            req_count          <= req_count + 1;
         elsif (request_loadstate = '1') then
            req_log(req_count) <= (kind => LOAD_REQ, addr => request_address);
            req_count          <= req_count + 1;
         end if;
         assert not (request_savestate = '1' and request_loadstate = '1')
            report "save and load requested in the same cycle" severity failure;
      end if;
   end process;

   process
      procedure clkcycles(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk1x);
         end loop;
      end procedure;

      procedure expect_req(idx : integer; kind : tReqKind; addr : integer; what : string) is
      begin
         assert req_count > idx
            report what & ": request " & integer'image(idx) & " never issued (count=" & integer'image(req_count) & ")" severity failure;
         assert req_log(idx).kind = kind
            report what & ": request " & integer'image(idx) & " wrong kind" severity failure;
         assert req_log(idx).addr = addr
            report what & ": request " & integer'image(idx) & " addr=" & integer'image(req_log(idx).addr) & " expected " & integer'image(addr) severity failure;
      end procedure;

      variable n_before : integer;
   begin
      gb_on <= '1';
      clkcycles(10);

      rewind_on <= '1';
      clkcycles(10);
      expect_req(0, SAVE_REQ, REWIND_ADDR, "initial capture");

      clkcycles(TIME_CAPTURE + 10);
      expect_req(1, SAVE_REQ, REWIND_ADDR + 1 * SLOT_SIZE, "second capture");

      clkcycles(TIME_CAPTURE + 10);
      expect_req(2, SAVE_REQ, REWIND_ADDR + 2 * SLOT_SIZE, "third capture");
      assert req_count = 3 report "unexpected extra requests during capture" severity failure;

      request_busy <= '1';
      clkcycles(TIME_CAPTURE + 200);
      assert req_count = 3 report "request issued while busy" severity failure;
      request_busy <= '0';
      clkcycles(10);
      expect_req(3, SAVE_REQ, REWIND_ADDR + 3 * SLOT_SIZE, "deferred capture");

      n_before := req_count;
      rewind_active <= '1';
      clkcycles(TIME_REWIND + 10);
      expect_req(n_before + 0, LOAD_REQ, REWIND_ADDR + 3 * SLOT_SIZE, "rewind step 1");
      clkcycles(TIME_REWIND + 10);
      expect_req(n_before + 1, LOAD_REQ, REWIND_ADDR + 2 * SLOT_SIZE, "rewind step 2");
      clkcycles(TIME_REWIND + 10);
      expect_req(n_before + 2, LOAD_REQ, REWIND_ADDR + 1 * SLOT_SIZE, "rewind step 3");

      clkcycles(3 * TIME_REWIND + 3 * TIME_CAPTURE);
      assert req_count = n_before + 3
         report "rewind stepped past the oldest snapshot or captured while rewinding" severity failure;

      assert sleep_rewind = '0' report "sleeping before two vsyncs elapsed" severity failure;
      for i in 1 to 2 loop
         vsync <= '1'; clkcycles(1); vsync <= '0'; clkcycles(5);
      end loop;
      clkcycles(5);
      assert sleep_rewind = '1' report "no sleep two vsyncs after rewind load" severity failure;

      rewind_active <= '0';
      clkcycles(5);
      assert sleep_rewind = '0' report "still sleeping after rewind released" severity failure;

      n_before := req_count;
      clkcycles(TIME_CAPTURE + 10);
      expect_req(n_before, SAVE_REQ, REWIND_ADDR + 1 * SLOT_SIZE, "post-rewind capture");

      n_before := req_count;
      savestate_number <= 2;
      save <= '1'; clkcycles(2); save <= '0'; clkcycles(5);
      expect_req(n_before, SAVE_REQ, SAVE_ADDR + 2 * SLOT_SIZE, "manual save slot 2");

      n_before := req_count;
      savestate_number <= 3;
      load <= '1'; clkcycles(2); load <= '0'; clkcycles(5);
      expect_req(n_before, LOAD_REQ, SAVE_ADDR + 3 * SLOT_SIZE, "manual load slot 3");

      report "tb_rewindmanager: all checks passed" severity note;
      running <= false;
      wait;
   end process;

end architecture;
