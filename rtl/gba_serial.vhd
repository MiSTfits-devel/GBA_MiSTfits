library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;
use work.pReg_gba_serial.all;

-- GBA Serial/SIO unit with an optional real link port.
--
-- link_enable = '0' : standalone model. Transfers complete on schedule without
--                     any pins involved, exactly as the core always behaved in
--                     single player.
-- link_enable = '1' : Normal (8/32 bit) and Multiplayer mode are bit-banged on
--                     the link_* lines. Every line is a (value, oe) pair meant
--                     for an open drain pin: value '0' with oe '1' pulls the
--                     line low, anything else releases it. The pins are owned
--                     by gba_linkport (or wired core to core for a dual core
--                     setup); all link_*_in inputs must already be
--                     synchronized, this unit never sees a raw pin.
--
-- Bit timing for both modes is ported from the GBA2P branch. UART and JoyBus
-- mode fall back to the standalone model so games never hang on them.

entity gba_serial is
   port
   (
      clk100            : in    std_logic;
      ce                : in    std_logic;
      gb_bus            : in    proc_bus_gb_type;
      wired_out         : out   std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
      wired_done        : out   std_logic;

      link_enable       : in    std_logic := '0';  -- 1 = SIO modes operate the link lines
      link_role_parent  : in    std_logic := '1';  -- 1 = this unit is parent/master on the cable
      link_clk_out      : out   std_logic := '1';  -- SC
      link_clk_oe       : out   std_logic := '0';
      link_clk_in       : in    std_logic := '1';
      link_so_out       : out   std_logic := '1';  -- SO
      link_so_oe        : out   std_logic := '0';
      link_si_in        : in    std_logic := '1';  -- SI
      link_sd_out       : out   std_logic := '1';  -- SD
      link_sd_oe        : out   std_logic := '0';
      link_sd_in        : in    std_logic := '1';

      IRP_Serial        : out std_logic := '0';

      -- Temporary hardware diagnostic: live ENGINE_MULTI state for the
      -- on-screen link debug overlay in gba_wrap.vhd. Bits 6 downto 0 are
      -- SIO_start & multisendmode & startbitreceived & a 4 bit exchange
      -- counter that increments once per completed transfer; bits 22
      -- downto 7 are the last received SIOMULTI1_RB value (what the other
      -- unit sent us); bits 38 downto 23 are REG_SIODATA8 (what we intend
      -- to send -- despite the name this register is 16 bits wide, see
      -- reggba_serial.vhd); bits 54 downto 39 are SIOMULTI2_RB and bits 70
      -- downto 55 are SIOMULTI3_RB -- the exact values the CPU reads back
      -- for the nonexistent units 2/3, which must be xFFFF in 2P link mode
      -- or the game counts a phantom third/fourth player. Remove once the
      -- real-hardware link-establishment bug is root-caused.
      debug_link_state  : out std_logic_vector(70 downto 0) := (others => '0')
   );
end entity;

architecture arch of gba_serial is

   signal REG_SIODATA32   : std_logic_vector(SIODATA32  .upper downto SIODATA32  .lower) := (others => '0');
   signal REG_SIOMULTI0   : std_logic_vector(SIOMULTI0  .upper downto SIOMULTI0  .lower) := (others => '0');
   signal REG_SIOMULTI1   : std_logic_vector(SIOMULTI1  .upper downto SIOMULTI1  .lower) := (others => '0');
   signal REG_SIOMULTI2   : std_logic_vector(SIOMULTI2  .upper downto SIOMULTI2  .lower) := (others => '0');
   signal REG_SIOMULTI3   : std_logic_vector(SIOMULTI3  .upper downto SIOMULTI3  .lower) := (others => '0');
   signal REG_SIOCNT      : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal REG_SIOMLT_SEND : std_logic_vector(SIOMLT_SEND.upper downto SIOMLT_SEND.lower) := (others => '0');
   signal REG_SIODATA8    : std_logic_vector(SIODATA8   .upper downto SIODATA8   .lower) := (others => '0');
   signal REG_RCNT        : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');
   signal REG_IR          : std_logic_vector(IR         .upper downto IR         .lower) := (others => '0');
   signal REG_JOYCNT      : std_logic_vector(JOYCNT     .upper downto JOYCNT     .lower) := (others => '0');
   signal REG_JOY_RECV    : std_logic_vector(JOY_RECV   .upper downto JOY_RECV   .lower) := (others => '0');
   signal REG_JOY_TRANS   : std_logic_vector(JOY_TRANS  .upper downto JOY_TRANS  .lower) := (others => '0');
   signal REG_JOYSTAT     : std_logic_vector(JOYSTAT    .upper downto JOYSTAT    .lower) := (others => '0');

   signal SIOCNT_READBACK : std_logic_vector(SIOCNT     .upper downto SIOCNT     .lower) := (others => '0');
   signal RCNT_READBACK   : std_logic_vector(RCNT       .upper downto RCNT       .lower) := (others => '0');

   signal SIOCNT_written    : std_logic;
   signal SIODATA32_written : std_logic;
   signal SIODATA8_written  : std_logic;
   signal SIOMULTI1_written : std_logic;

   -- readback values: what the CPU sees. The write registers above always keep
   -- the written value, received data only ever lands here.
   signal SIODATA32_RB    : std_logic_vector(31 downto 0) := (others => '0'); -- also SIOMULTI0 (15..0)
   signal SIOMULTI1_RB    : std_logic_vector(15 downto 0) := (others => '0');
   signal SIOMULTI2_RB    : std_logic_vector(15 downto 0);
   signal SIOMULTI3_RB    : std_logic_vector(15 downto 0);
   signal SIODATA8_RB     : std_logic_vector(15 downto 0) := (others => '0');

   type t_reg_wired_or is array(0 to 13) of std_logic_vector(31 downto 0);
   signal reg_wired_or    : t_reg_wired_or;
   signal reg_wired_done  : unsigned(0 to 13);

   type tEngineMode is
   (
      ENGINE_STUB,   -- no cable, or a mode the link engine doesn't cover
      ENGINE_NORMAL, -- Normal 8/32 bit on SC/SO/SI
      ENGINE_MULTI   -- Multiplayer frames on SD, SC as busy line
   );
   signal engineMode      : tEngineMode;

   signal SIO_start       : std_logic := '0';
   signal exchange_busy   : std_logic;
   signal cycles          : unsigned(11 downto 0) := (others => '0');
   signal bitcount        : integer range 0 to 31 := 0;

   signal clockin_1       : std_logic := '1';

   -- The parent's own bit sampling is deliberately offset half a bit period
   -- from the sender's clock (cycles <= multispeed/2 at start-bit detection,
   -- for midpoint sampling), so the parent's completion (its own bitcount
   -- reaching 18) can land slightly BEFORE the far end has physically
   -- finished driving its last real bit. Re-arming the start-bit detector
   -- immediately afterward can then catch the tail of that still-ongoing
   -- real transmission as a fresh "start bit" for a phantom slave slot,
   -- corrupting the just-captured good data before software ever reads it.
   -- Requiring a genuine falling edge (link_sd_in was high last cycle, not
   -- just low this cycle) rejects that, since the wire was already low
   -- continuously through the tail end, not freshly transitioning.
   signal sd_in_prev      : std_logic := '1';

   signal multispeed       : integer range 145 to 1747 := 1747;
   signal multidataout     : std_logic_vector(17 downto 0) := (others => '1');
   signal multidatain      : std_logic_vector(17 downto 0) := (others => '1');
   signal multisendmode    : std_logic := '0';
   signal startbitreceived : std_logic := '0';
   signal waitchild        : unsigned(16 downto 0) := (others => '0');

   -- Per AGBProgrammingManual p.113-114: a real exchange always sequentially
   -- polls up to 3 slave slots (transmission only ends after a stop bit is
   -- received from the 2nd slave, or a start bit fails to arrive, for the
   -- 2nd slot) even when fewer real units are connected -- slave_slot tracks
   -- which of the (up to 3) slave slots the parent is currently waiting on
   -- or has just finished, so a 2-unit cable still burns through the same
   -- extra timeout windows real hardware would.
   signal slave_slot       : unsigned(1 downto 0) := (others => '0');

   -- The child<->child wired-AND link (gba_wrap.vhd) synchronizes link_sd_in
   -- through one registered stage, so the cycle right after the child stops
   -- driving SD still echoes back the PREVIOUS bit it was driving, not the
   -- just-sent stop bit. The child's own start-bit detector re-arms the
   -- instant multisendmode clears, samples that stale echo, and mistakes it
   -- for a fresh start bit -- self-retriggering. This was always latent but
   -- harmless before (SC released again almost immediately), and became a
   -- real bug once slave_slot above keeps SC low much longer (polling
   -- phantom slave2/slave3). justsent_guard skips exactly one cycle of
   -- start-bit evaluation after finishing a send so the synchronizer catches
   -- up first.
   signal justsent_guard   : std_logic := '0';

   -- Temporary hardware diagnostic: see debug_link_state above.
   signal debug_exchange_count : unsigned(3 downto 0) := (others => '0');

   -- real hardware sends multiplayer data LSB first on the wire; the shift
   -- engine runs MSB first, so wire-crossing values are bit swapped at the
   -- frame load and capture points
   function bitswap16(v : std_logic_vector(15 downto 0)) return std_logic_vector is
      variable r : std_logic_vector(15 downto 0);
   begin
      for i in 0 to 15 loop
         r(i) := v(15 - i);
      end loop;
      return r;
   end function;

begin

   iSIODATA32   : entity work.eProcReg_gba generic map (SIODATA32  ) port map  (clk100, gb_bus, reg_wired_or(0 ), reg_wired_done(0 ), SIODATA32_RB               , REG_SIODATA32  , SIODATA32_written);
   iSIOMULTI0   : entity work.eProcReg_gba generic map (SIOMULTI0  ) port map  (clk100, gb_bus, reg_wired_or(1 ), reg_wired_done(1 ), SIODATA32_RB(15 downto 0)  , REG_SIOMULTI0  );
   iSIOMULTI1   : entity work.eProcReg_gba generic map (SIOMULTI1  ) port map  (clk100, gb_bus, reg_wired_or(2 ), reg_wired_done(2 ), SIOMULTI1_RB               , REG_SIOMULTI1  , SIOMULTI1_written);
   iSIOMULTI2   : entity work.eProcReg_gba generic map (SIOMULTI2  ) port map  (clk100, gb_bus, reg_wired_or(3 ), reg_wired_done(3 ), SIOMULTI2_RB               , REG_SIOMULTI2  );
   iSIOMULTI3   : entity work.eProcReg_gba generic map (SIOMULTI3  ) port map  (clk100, gb_bus, reg_wired_or(4 ), reg_wired_done(4 ), SIOMULTI3_RB               , REG_SIOMULTI3  );
   iSIOCNT      : entity work.eProcReg_gba generic map (SIOCNT     ) port map  (clk100, gb_bus, reg_wired_or(5 ), reg_wired_done(5 ), SIOCNT_READBACK            , REG_SIOCNT     , SIOCNT_written);
   iSIOMLT_SEND : entity work.eProcReg_gba generic map (SIOMLT_SEND) port map  (clk100, gb_bus, reg_wired_or(6 ), reg_wired_done(6 ), SIODATA8_RB                , REG_SIOMLT_SEND);
   iSIODATA8    : entity work.eProcReg_gba generic map (SIODATA8   ) port map  (clk100, gb_bus, reg_wired_or(7 ), reg_wired_done(7 ), SIODATA8_RB                , REG_SIODATA8   , SIODATA8_written);
   iRCNT        : entity work.eProcReg_gba generic map (RCNT       ) port map  (clk100, gb_bus, reg_wired_or(8 ), reg_wired_done(8 ), RCNT_READBACK              , REG_RCNT       );
   iIR          : entity work.eProcReg_gba generic map (IR         ) port map  (clk100, gb_bus, reg_wired_or(9 ), reg_wired_done(9 ), REG_IR                     , REG_IR         );
   iJOYCNT      : entity work.eProcReg_gba generic map (JOYCNT     ) port map  (clk100, gb_bus, reg_wired_or(10), reg_wired_done(10), REG_JOYCNT                 , REG_JOYCNT     );
   iJOY_RECV    : entity work.eProcReg_gba generic map (JOY_RECV   ) port map  (clk100, gb_bus, reg_wired_or(11), reg_wired_done(11), REG_JOY_RECV               , REG_JOY_RECV   );
   iJOY_TRANS   : entity work.eProcReg_gba generic map (JOY_TRANS  ) port map  (clk100, gb_bus, reg_wired_or(12), reg_wired_done(12), REG_JOY_TRANS              , REG_JOY_TRANS  );
   iJOYSTAT     : entity work.eProcReg_gba generic map (JOYSTAT    ) port map  (clk100, gb_bus, reg_wired_or(13), reg_wired_done(13), REG_JOYSTAT                , REG_JOYSTAT    );

   process (reg_wired_or)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := reg_wired_or(0);
      for i in 1 to (reg_wired_or'length - 1) loop
         wired_or := wired_or or reg_wired_or(i);
      end loop;
      wired_out <= wired_or;
   end process;
   wired_done <= '0' when (reg_wired_done = 0) else '1';

   engineMode <= ENGINE_STUB   when link_enable = '0' or REG_RCNT(15) = '1'  else -- general purpose / JoyBus: not driven by this engine
                 ENGINE_MULTI  when REG_SIOCNT(13 downto 12) = "10"          else
                 ENGINE_STUB   when REG_SIOCNT(13 downto 12) = "11"          else -- UART: not implemented
                 ENGINE_NORMAL;

   -- the child side of a multiplayer exchange runs without a local start bit,
   -- so busy must cover the externally triggered phases as well
   exchange_busy <= (SIO_start or multisendmode or startbitreceived) when (engineMode = ENGINE_MULTI and link_role_parent = '0') else
                    SIO_start;

   SIOCNT_READBACK <= REG_SIOCNT(15 downto 8) & exchange_busy & REG_SIOCNT(6 downto 0) when engineMode /= ENGINE_MULTI else
                      REG_SIOCNT(15 downto 8) & exchange_busy & "00" & (not link_role_parent) & link_sd_in & (not link_role_parent) & REG_SIOCNT(1 downto 0);

   RCNT_READBACK   <= REG_RCNT when engineMode /= ENGINE_MULTI else
                      REG_RCNT(15 downto 4) & '1' & (not link_role_parent) & link_sd_in & link_clk_in;

   SIOMULTI2_RB    <= REG_SIOMULTI2 when link_enable = '0' else x"FFFF"; -- units 2/3 don't exist on a 2 player cable
   SIOMULTI3_RB    <= REG_SIOMULTI3 when link_enable = '0' else x"FFFF";

   process (clk100)
   begin
      if rising_edge(clk100) then

         IRP_Serial <= '0';

         -- open drain defaults: all lines released unless a mode below claims them
         link_clk_oe <= '0';
         link_so_oe  <= '0';
         link_sd_oe  <= '0';

         clockin_1 <= link_clk_in;

         -- track the SD wire in every mode (not just ENGINE_MULTI) so a
         -- mode exit/re-entry can't leave a stale '1' here that the start-
         -- bit detector would mistake for a fresh falling edge when SD
         -- happens to be mid-frame low at re-entry. ce-gated to advance at
         -- the same rate the detector consumes it (see the detector note).
         if (ce = '1') then
            sd_in_prev <= link_sd_in;
         end if;

         case (REG_SIOCNT(1 downto 0)) is
            when "00"   => multispeed <= 1747; -- 9600 baud
            when "01"   => multispeed <=  436; -- 38400 baud
            when "10"   => multispeed <=  291; -- 57600 baud
            when "11"   => multispeed <=  145; -- 115200 baud
            when others => null;
         end case;

         case (engineMode) is

            when ENGINE_STUB =>
               -- transfers complete on schedule, data is left untouched
               if (SIO_start = '1') then
                  if (ce = '1') then
                     cycles <= cycles + 1;

                     if ((REG_SIOCNT(1) = '0' and cycles >= 63) or (REG_SIOCNT(1) = '1' and cycles >= 7)) then
                        if (REG_SIOCNT(1) = '1') then
                           cycles <= cycles - 7;
                        else
                           cycles <= cycles - 63;
                        end if;

                        if ((REG_SIOCNT(12) = '0' and bitcount = 7) or (REG_SIOCNT(12) = '1' and bitcount = 31)) then
                           if (REG_SIOCNT(14) = '1') then
                              IRP_Serial <= '1';
                           end if;
                           SIO_start <= '0';
                        else
                           bitcount <= bitcount + 1;
                        end if;
                     end if;
                  end if;
               end if;

            when ENGINE_NORMAL =>

               if (REG_SIOCNT(0) = '0') then
                  -- slave: SO is always an output; between transfers it shows
                  -- the "SO during inactivity" bit, games use it as a ready line
                  link_so_oe <= '1';
                  if (SIO_start = '0') then
                     link_so_out <= REG_SIOCNT(3);
                  end if;
               end if;

               if (SIO_start = '1') then
                  if (REG_SIOCNT(0) = '0') then
                     -- slave: shift on the clock the master drives on SC
                     if (clockin_1 = '1' and link_clk_in = '0') then
                        if (REG_SIOCNT(12) = '1') then
                           link_so_out <= SIODATA32_RB(31);
                        else
                           link_so_out <= SIODATA8_RB(7);
                        end if;
                     end if;

                     if (clockin_1 = '0' and link_clk_in = '1') then
                        if (REG_SIOCNT(12) = '1') then
                           SIODATA32_RB <= SIODATA32_RB(30 downto 0) & link_si_in;
                        else
                           SIODATA8_RB <= x"00" & SIODATA8_RB(6 downto 0) & link_si_in;
                        end if;

                        if ((REG_SIOCNT(12) = '0' and bitcount = 7) or (REG_SIOCNT(12) = '1' and bitcount = 31)) then
                           if (REG_SIOCNT(14) = '1') then
                              IRP_Serial <= '1';
                           end if;
                           SIO_start <= '0';
                        else
                           bitcount <= bitcount + 1;
                        end if;
                     end if;

                  else
                     -- master: drive SC, present data on the falling edge,
                     -- sample SI on the rising edge
                     link_clk_oe <= '1';
                     link_so_oe  <= '1';

                     -- NOTE: ce is the core's run/pause gate, not a divided
                     -- bit clock -- it reads as constantly '1' while running
                     -- (see gba_ctrl_pause's RUNNING state). Both halves of
                     -- the bit period must therefore be checked in the same
                     -- ce='1' step, using cycles+1 since the increment below
                     -- hasn't landed yet.
                     if (ce = '1') then
                        cycles <= cycles + 1;
                        if ((REG_SIOCNT(1) = '0' and cycles + 1 = 32) or (REG_SIOCNT(1) = '1' and cycles + 1 = 4)) then
                           link_clk_out <= '0';
                           if (REG_SIOCNT(12) = '1') then
                              link_so_out <= SIODATA32_RB(31);
                           else
                              link_so_out <= SIODATA8_RB(7);
                           end if;
                        end if;
                        if ((REG_SIOCNT(1) = '0' and cycles + 1 = 64) or (REG_SIOCNT(1) = '1' and cycles + 1 = 8)) then
                           link_clk_out <= '1';
                           if (REG_SIOCNT(12) = '1') then
                              SIODATA32_RB <= SIODATA32_RB(30 downto 0) & link_si_in;
                           else
                              SIODATA8_RB <= x"00" & SIODATA8_RB(6 downto 0) & link_si_in;
                           end if;

                           if (REG_SIOCNT(1) = '1') then
                              cycles <= cycles + 1 - 8;
                           else
                              cycles <= cycles + 1 - 64;
                           end if;

                           if ((REG_SIOCNT(12) = '0' and bitcount = 7) or (REG_SIOCNT(12) = '1' and bitcount = 31)) then
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                              SIO_start <= '0';
                           else
                              bitcount <= bitcount + 1;
                           end if;
                        end if;
                     end if;
                  end if;
               end if;

            when ENGINE_MULTI =>
               -- 18 bit frames (start + 16 data + stop) on SD at the selected
               -- baud rate: the parent sends first, the child answers. The
               -- parent holds SC low while the exchange runs.

               if (link_role_parent = '1') then
                  if (SIO_start = '1') then
                     link_clk_oe  <= '1';
                     link_clk_out <= '0';
                  else
                     link_clk_out <= '1';
                  end if;
               end if;

               if (multisendmode = '1') then
                  link_sd_oe <= '1';
               else
                  link_sd_out <= '1';
               end if;

               -- NOTE: ce is the core's run/pause gate, not a divided bit
               -- clock -- it reads as constantly '1' while running (see
               -- gba_ctrl_pause's RUNNING state). The send/receive timing
               -- below must therefore run inside the same ce='1' step as the
               -- cycles counter it depends on, checking cycles+1 since the
               -- increment hasn't landed yet.
               if (ce = '1') then
                  cycles <= cycles + 1;

                  if (multisendmode = '1') then
                     -- sending our frame
                     if (cycles + 1 >= multispeed) then
                        cycles       <= cycles + 1 - multispeed;
                        link_sd_out  <= multidataout(17);
                        multidataout <= multidataout(16 downto 0) & '1';

                        if (bitcount = 17) then
                           bitcount      <= 0;
                           multisendmode <= '0';
                           if (link_role_parent = '1') then
                              waitchild <= (others => '0');   -- now wait for the answer
                           else
                              -- NOTE: AGBProgrammingManual p.113-114 implies a
                              -- slave's busy flag should stay set until the
                              -- master concludes the WHOLE exchange (it may
                              -- still be polling phantom slave2/slave3 slots),
                              -- not clear the instant it finishes sending. A
                              -- prior attempt at this (wait for link_clk_in to
                              -- release before completing) caused the child to
                              -- get permanently stuck on real hardware -- the
                              -- release was evidently not observed reliably.
                              -- Reverted to completing immediately; the data
                              -- registers are already correct at this point
                              -- regardless, so no data is lost by clearing
                              -- busy early.
                              SIO_start      <= '0';
                              justsent_guard <= '1';
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                           end if;
                        else
                           bitcount <= bitcount + 1;
                        end if;
                     end if;

                  elsif (justsent_guard = '1') then
                     justsent_guard <= '0';

                  elsif (link_role_parent = '0' or SIO_start = '1') then
                     -- receiving a frame; the child listens even without a local
                     -- start bit, real child units are started by the parent
                     if (startbitreceived = '0') then
                        -- Per AGBProgrammingManual p.113, SC going low is the
                        -- SYNC signal that marks a transfer window; SD only
                        -- carries data inside it. Qualifying on link_clk_in
                        -- here (not just SD alone) stops a lone SD glitch
                        -- from being mistaken for a fresh start bit once the
                        -- real exchange is over and SC has released. Requiring
                        -- a genuine falling edge (sd_in_prev='1') rather than
                        -- just a level check rejects the case where SD was
                        -- already low continuously -- see sd_in_prev's
                        -- declaration above for why that happens.
                        if (link_sd_in = '0' and sd_in_prev = '1' and link_clk_in = '0') then
                           cycles           <= to_unsigned(multispeed / 2, cycles'length);
                           bitcount         <= 1;
                           startbitreceived <= '1';
                        elsif (link_role_parent = '1' and waitchild >= to_unsigned(multispeed, 12) * 64) then
                           -- This slot's wait expired with no start bit. Per
                           -- AGBProgrammingManual p.113-114 the master always
                           -- sequentially polls up to 3 slave slots -- even
                           -- on a 2-unit cable it must still time out on the
                           -- phantom 2nd (and 3rd) slot before the exchange
                           -- is really over, not just after slot 1.
                           if (slave_slot = 0) then
                              -- no slave1 answered either: open-bus fallback
                              -- like real hardware does for absent units
                              SIODATA32_RB <= x"FFFF" & REG_SIODATA8;
                              SIOMULTI1_RB <= x"FFFF";
                           end if;
                           waitchild <= (others => '0');
                           if (slave_slot = 2) then
                              slave_slot <= (others => '0');
                              SIO_start  <= '0';
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                           else
                              slave_slot <= slave_slot + 1;
                           end if;
                        else
                           if (link_role_parent = '1') then
                              waitchild <= waitchild + 1;
                           end if;
                        end if;
                     elsif (cycles + 1 >= multispeed) then
                        cycles      <= cycles + 1 - multispeed;
                        multidatain <= multidatain(16 downto 0) & link_sd_in;

                     if (bitcount = 18) then
                        -- multidatain still holds the pre-shift value here
                        -- (17 shifts done). Static timing of the detector:
                        -- cycles is preset to multispeed/2 on the start-bit
                        -- falling edge, so the FIRST shift lands mid-START-bit
                        -- and shifts 1..17 capture start,d1..d16 -- start at
                        -- position 16, data at (15 downto 0). The stop bit is
                        -- never shifted in (completion fires instead on shift
                        -- 18). A previous session "fixed" this window to
                        -- (16 downto 1) reasoning the first shift sampled d1;
                        -- that dropped d16 and injected the constant start
                        -- bit as the received LSB (post-bitswap), i.e. it
                        -- returned (sent << 1). The sim run that validated it
                        -- used payload 0x0000, which is invariant under the
                        -- shift; tb_link's CAFE/BEEF payloads discriminate
                        -- and confirm (15 downto 0) is correct.
                        bitcount         <= 0;
                        startbitreceived <= '0';
                        if (link_role_parent = '1') then
                           -- parent got a real answer for this slot -- still
                           -- has to poll the remaining phantom slots (see
                           -- above) before the exchange is really done.
                           -- Only slot 0 may land in SIOMULTI1: a frame
                           -- "received" during a phantom slot 1/2 window
                           -- (glitch, stale echo) must not clobber the good
                           -- slot-0 data captured moments earlier -- the
                           -- timeout path above already guards its FFFF
                           -- fallback the same way.
                           if (slave_slot = 0) then
                              SIODATA32_RB <= bitswap16(multidatain(15 downto 0)) & REG_SIODATA8;
                              SIOMULTI1_RB <= bitswap16(multidatain(15 downto 0));
                           end if;
                           waitchild    <= (others => '0');
                           if (slave_slot = 2) then
                              slave_slot <= (others => '0');
                              SIO_start  <= '0';
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                           else
                              slave_slot <= slave_slot + 1;
                           end if;
                        else
                           -- child got the parent frame and answers with its own
                           SIODATA32_RB  <= REG_SIODATA8 & bitswap16(multidatain(15 downto 0));
                           SIOMULTI1_RB  <= REG_SIODATA8;
                           multisendmode <= '1';
                           multidataout  <= '0' & bitswap16(REG_SIODATA8) & '1';
                           cycles        <= (others => '0');
                        end if;
                     else
                        bitcount <= bitcount + 1;
                     end if;
                  end if;
               end if;
               end if;

         end case;

         if (SIOCNT_written = '1') then
            if (REG_SIOCNT(7) = '1') then
               SIO_start        <= '1';
               bitcount         <= 0;
               cycles           <= (others => '0');
               waitchild        <= (others => '0');
               startbitreceived <= '0';
               slave_slot       <= (others => '0');
               justsent_guard   <= '0';
               if (engineMode = ENGINE_MULTI) then
                  if (link_role_parent = '1') then
                     multisendmode <= '1';
                     multidataout  <= '0' & bitswap16(REG_SIODATA8) & '1';
                  end if;
                  SIODATA32_RB <= (others => '1');
                  SIOMULTI1_RB <= (others => '1');
               else
                  multisendmode <= '0';
               end if;
            elsif (engineMode /= ENGINE_STUB) then
               -- clearing the start bit cancels a running transfer
               SIO_start        <= '0';
               multisendmode    <= '0';
               startbitreceived <= '0';
               slave_slot       <= (others => '0');
               justsent_guard   <= '0';
            end if;
         end if;

         -- CPU writes always land in the readback values too. SIODATA32's
         -- upper half and SIOMULTI1 are the same architectural register
         -- (both read back through bits 31:16 of the 0x120 word), so both
         -- write paths must update both readbacks or the wired-or of the
         -- two diverged values garbles reads.
         if (SIODATA32_written = '1') then
            SIODATA32_RB <= REG_SIODATA32;
            SIOMULTI1_RB <= REG_SIODATA32(31 downto 16);
         end if;
         if (SIODATA8_written = '1') then
            SIODATA8_RB <= REG_SIODATA8;
         end if;
         if (SIOMULTI1_written = '1') then
            SIOMULTI1_RB <= REG_SIOMULTI1;
            SIODATA32_RB(31 downto 16) <= REG_SIOMULTI1;
         end if;

         if (gb_bus.rst = '1') then
            SIO_start        <= '0';
            multisendmode    <= '0';
            startbitreceived <= '0';
            sd_in_prev       <= '1';
            slave_slot       <= (others => '0');
            justsent_guard   <= '0';
            bitcount         <= 0;
            cycles           <= (others => '0');
            waitchild        <= (others => '0');
            IRP_Serial       <= '0';
            link_clk_out     <= '1';
            link_so_out      <= '1';
            link_sd_out      <= '1';
            SIODATA32_RB     <= (others => '0');
            SIODATA8_RB      <= (others => '0');
            SIOMULTI1_RB     <= (others => '0');
         end if;

      end if;
   end process;

   -- Temporary hardware diagnostic (real synthesized logic, not sim-only):
   -- counts completed ENGINE_MULTI transfers so the on-screen link debug
   -- overlay (gba_wrap.vhd) can show whether exchanges are progressing.
   -- Remove once the real-hardware link-establishment bug is root-caused.
   process (clk100)
   begin
      if rising_edge(clk100) then
         if (gb_bus.rst = '1') then
            debug_exchange_count <= (others => '0');
         elsif (IRP_Serial = '1' and engineMode = ENGINE_MULTI) then
            debug_exchange_count <= debug_exchange_count + 1;
         end if;
      end if;
   end process;

   debug_link_state <= SIOMULTI3_RB & SIOMULTI2_RB & REG_SIODATA8 & SIOMULTI1_RB & SIO_start & multisendmode & startbitreceived & std_logic_vector(debug_exchange_count);

   -- synthesis translate_off
   -- Temporary diagnostic: trace every CPU READ of the SIO data/control
   -- registers with the exact merged wired-or value returned -- this is
   -- precisely what software (e.g. LinkCable's _onSerial) observes, so a
   -- "phantom player" seen by a game can be matched against RTL state with
   -- no interpretation gap. Remove once the 2P bug is root-caused.
   debug_sio_read_mon : process (clk100)
      variable adr_i : integer;
   begin
      if rising_edge(clk100) then
         if (gb_bus.ena = '1' and gb_bus.rnw = '1') then
            adr_i := to_integer(unsigned(gb_bus.Adr));
            if (adr_i >= 16#120# and adr_i <= 16#12A#) then
               report clk100'instance_name &
                      " SIOread adr=0x" & to_hstring(gb_bus.Adr) &
                      " val=0x" & to_hstring(wired_out);
            end if;
         end if;
      end if;
   end process;

   -- Temporary diagnostic: trace ENGINE_MULTI's internal state on every
   -- change, tagged per-instance so core1/core2 are distinguishable in the
   -- log. Remove once the 2P multiplayer hang is root-caused.
   debug_multi_mon : process (clk100)
      variable last_start   : std_logic := 'U';
      variable last_multi   : std_logic := 'U';
      variable last_bitcnt  : integer := -1;
      variable last_startbr : std_logic := 'U';
      variable last_sd_in   : std_logic := 'U';
      variable last_sd_oe   : std_logic := 'U';
      variable last_clk_out : std_logic := 'U';
      variable last_clk_oe  : std_logic := 'U';
      variable last_multi1  : std_logic_vector(15 downto 0) := (others => 'U');
   begin
      if rising_edge(clk100) then
         if (link_enable = '1' and engineMode = ENGINE_MULTI) then
            if (SIO_start /= last_start or multisendmode /= last_multi or
                bitcount /= last_bitcnt or startbitreceived /= last_startbr or
                link_sd_in /= last_sd_in or link_sd_oe /= last_sd_oe or
                link_clk_out /= last_clk_out or link_clk_oe /= last_clk_oe or
                SIOMULTI1_RB /= last_multi1) then
               report clk100'instance_name &
                      " parent=" & std_logic'image(link_role_parent) &
                      " SIO_start=" & std_logic'image(SIO_start) &
                      " multisend=" & std_logic'image(multisendmode) &
                      " bitcount=" & integer'image(bitcount) &
                      " startbitrx=" & std_logic'image(startbitreceived) &
                      " cycles=" & integer'image(to_integer(cycles)) &
                      " waitchild=" & integer'image(to_integer(waitchild)) &
                      " clk_oe=" & std_logic'image(link_clk_oe) &
                      " clk_out=" & std_logic'image(link_clk_out) &
                      " sd_oe=" & std_logic'image(link_sd_oe) &
                      " sd_out=" & std_logic'image(link_sd_out) &
                      " sd_in=" & std_logic'image(link_sd_in) &
                      " multi1=" & to_hstring(SIOMULTI1_RB);
               last_start   := SIO_start;
               last_multi   := multisendmode;
               last_bitcnt  := bitcount;
               last_startbr := startbitreceived;
               last_sd_in   := link_sd_in;
               last_sd_oe   := link_sd_oe;
               last_clk_out := link_clk_out;
               last_clk_oe  := link_clk_oe;
               last_multi1  := SIOMULTI1_RB;
            end if;
         end if;
      end if;
   end process;
   -- synthesis translate_on

end architecture;
