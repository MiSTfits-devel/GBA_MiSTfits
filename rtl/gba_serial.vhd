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

   -- Multiplayer roles come from the cable, exactly like real hardware
   -- (AGBProgrammingManual p.113 / Figure 101): the link cable's 1P-position
   -- plug grounds that unit's SI terminal, every other unit's SI hangs off
   -- the previous unit's SO. The unit whose SI reads LO is the master; there
   -- is no software- or OSD-selectable role on a real GBA. role_master is
   -- latched from the sensed SI level while the bus is idle (a slave's SI
   -- legitimately toggles mid-exchange -- that's the SO daisy chain -- so
   -- it must never be re-evaluated during one).
   signal role_master     : std_logic := '0';

   -- child-side exchange framing: engaged spans from the first start bit of
   -- an exchange until the master releases SC (the SYNC signal) -- that
   -- release is a LEVEL check on the synchronized wire, so unlike the old
   -- waitmasterend edge-wait it cannot be "missed"; eng_timeout is a pure
   -- safety net so a master dying mid-exchange can never wedge the child.
   signal engaged         : std_logic := '0';
   signal frames_rx       : unsigned(1 downto 0) := (others => '0');
   signal sent_this_ex    : std_logic := '0';
   signal eng_timeout     : unsigned(20 downto 0) := (others => '0');

   -- SO daisy chain (manual p.113): each unit pulls its SO low once its own
   -- frame is sent -- that is the next unit's go-ahead to answer -- and
   -- releases it when the exchange concludes.
   signal so_drive_low    : std_logic := '0';

   -- Multi-Player ID (SIOCNT d5:4): assigned by bus position at each
   -- exchange -- 0 for the master, the number of frames that preceded a
   -- slave's own. Persists between exchanges like real hardware.
   signal multi_id        : std_logic_vector(1 downto 0) := "00";

   -- SIOMULTI2/3 receive very real data on a 3/4-unit cable; these replace
   -- the old hardcoded-FFFF readbacks (init FFFF per exchange, per manual).
   signal SIOMULTI2_link  : std_logic_vector(15 downto 0) := (others => '1');
   signal SIOMULTI3_link  : std_logic_vector(15 downto 0) := (others => '1');

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

   -- a slave in a multiplayer exchange runs without a local start bit (its
   -- d07 is a pure busy status, manual p.117), so busy must cover the
   -- externally triggered phases as well
   exchange_busy <= (multisendmode or startbitreceived or engaged) when (engineMode = ENGINE_MULTI and role_master = '0') else
                    SIO_start;

   -- Normal mode d02 is the LIVE SI terminal level (manual p.111) -- e.g.
   -- the Wireless Adapter's software polls it as the adapter-ready line.
   -- Multiplayer d05:4 is the position-assigned Multi-Player ID, d03/d02 the
   -- live SD/SI terminal levels (manual p.117-118), d06 error unimplemented.
   SIOCNT_READBACK <= REG_SIOCNT(15 downto 8) & exchange_busy & REG_SIOCNT(6 downto 3) & link_si_in & REG_SIOCNT(1 downto 0) when (engineMode = ENGINE_NORMAL and link_enable = '1') else
                      REG_SIOCNT(15 downto 8) & exchange_busy & REG_SIOCNT(6 downto 0)                                       when engineMode /= ENGINE_MULTI else
                      REG_SIOCNT(15 downto 8) & exchange_busy & '0' & multi_id & link_sd_in & link_si_in & REG_SIOCNT(1 downto 0);

   -- RCNT: multiplayer mode mirrors the live terminals; general-purpose
   -- (GPIO) mode reads input-direction pins live and output-direction pins
   -- as written -- the Wireless Adapter's reset ping runs in this mode.
   process (engineMode, REG_RCNT, link_enable, link_si_in, link_sd_in, link_clk_in)
   begin
      if (engineMode = ENGINE_MULTI) then
         RCNT_READBACK <= REG_RCNT(15 downto 4) & '1' & link_si_in & link_sd_in & link_clk_in;
      elsif (link_enable = '1' and REG_RCNT(15 downto 14) = "10") then
         RCNT_READBACK <= REG_RCNT;
         if (REG_RCNT(4) = '0') then RCNT_READBACK(0) <= link_clk_in; end if;
         if (REG_RCNT(5) = '0') then RCNT_READBACK(1) <= link_sd_in;  end if;
         if (REG_RCNT(6) = '0') then RCNT_READBACK(2) <= link_si_in;  end if;
         if (REG_RCNT(7) = '0') then RCNT_READBACK(3) <= '1';         end if; -- SO: nothing else ever drives it
      else
         RCNT_READBACK <= REG_RCNT;
      end if;
   end process;

   SIOMULTI2_RB    <= REG_SIOMULTI2 when link_enable = '0' else SIOMULTI2_link;
   SIOMULTI3_RB    <= REG_SIOMULTI3 when link_enable = '0' else SIOMULTI3_link;

   process (clk100)
      variable rx_slot : unsigned(1 downto 0);
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
               -- RCNT general-purpose (GPIO) mode: software bit-bangs the
               -- pins directly, direction bits 7:4 (SO/SI/SD/SC), data bits
               -- 3:0. The Wireless Adapter's reset ping (SD held high then
               -- low with SO as output) runs here. Note the physical port
               -- is open drain: "driving high" releases the line, which
               -- reads high through the pull-up -- same net effect.
               if (link_enable = '1' and REG_RCNT(15 downto 14) = "10") then
                  if (REG_RCNT(4) = '1') then
                     link_clk_oe  <= '1';
                     link_clk_out <= REG_RCNT(0);
                  end if;
                  if (REG_RCNT(5) = '1') then
                     link_sd_oe  <= '1';
                     link_sd_out <= REG_RCNT(1);
                  end if;
                  -- SI has no output driver on this port (receive only)
                  if (REG_RCNT(7) = '1') then
                     link_so_oe  <= '1';
                     link_so_out <= REG_RCNT(3);
                  end if;
               end if;

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

               -- Normal mode outputs LO from the SD terminal, master and
               -- slave alike (manual p.108/111). This doubles as the real
               -- "not in multiplayer mode yet" announcement: a peer already
               -- in multiplayer mode reads SD (SIOCNT d03) LO until we
               -- switch modes too -- the rendezvous real software gates on.
               link_sd_oe  <= '1';
               link_sd_out <= '0';

               -- SO is always an output; between transfers it shows the
               -- "Transfer Enable Flag Send" bit d03 (manual p.111: "output
               -- from the SO terminal until the start of a transfer") --
               -- for the master too, e.g. the Wireless Adapter login
               -- wiggles it as a handshake line.
               link_so_oe <= '1';
               if (SIO_start = '0') then
                  link_so_out <= REG_SIOCNT(3);
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
                           -- SIODATA32_H IS SIOMULTI1 (same architectural
                           -- register) and reads are a wired-or of both
                           -- readbacks -- receive must update both or the
                           -- stale one ORs garbage into every 32-bit read
                           SIOMULTI1_RB <= SIODATA32_RB(30 downto 15);
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
                              -- see the slave path: SIODATA32_H is SIOMULTI1
                              SIOMULTI1_RB <= SIODATA32_RB(30 downto 15);
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
               -- baud rate. The cable-designated master (SI grounded by the
               -- 1P plug) holds SC low (the SYNC signal) for the whole
               -- exchange and sends its frame first; each unit then pulls
               -- its own SO low once its frame is out -- the go-ahead for
               -- the unit hanging off its SO->SI cross to take the next
               -- slot (manual p.113, Figures 101/102).

               if (role_master = '1') then
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

               if (so_drive_low = '1') then
                  link_so_oe  <= '1';
                  link_so_out <= '0';
               end if;

               -- NOTE: ce is the core's run/pause gate, not a divided bit
               -- clock -- it reads as constantly '1' while running (see
               -- gba_ctrl_pause's RUNNING state). The send/receive timing
               -- below must therefore run inside the same ce='1' step as the
               -- cycles counter it depends on, checking cycles+1 since the
               -- increment hasn't landed yet.
               if (ce = '1') then
                  cycles <= cycles + 1;

                  -- role follows the sensed SI level whenever the bus is
                  -- idle (see role_master's declaration for why never
                  -- mid-exchange)
                  if (SIO_start = '0' and multisendmode = '0' and startbitreceived = '0' and engaged = '0') then
                     role_master <= not link_si_in;
                  end if;

                  if (multisendmode = '1') then
                     -- sending our frame
                     if (cycles + 1 >= multispeed) then
                        cycles       <= cycles + 1 - multispeed;
                        link_sd_out  <= multidataout(17);
                        multidataout <= multidataout(16 downto 0) & '1';

                        if (bitcount = 17) then
                           bitcount      <= 0;
                           multisendmode <= '0';
                           so_drive_low  <= '1'; -- the next unit's go-ahead
                           if (role_master = '1') then
                              -- the master's own frame lands in SIOMULTI0
                              -- on every unit, including itself
                              SIODATA32_RB(15 downto 0) <= REG_SIODATA8;
                              waitchild <= (others => '0');   -- now wait for the answers
                           else
                              justsent_guard <= '1';
                           end if;
                        else
                           bitcount <= bitcount + 1;
                        end if;
                     end if;

                  elsif (justsent_guard = '1') then
                     justsent_guard <= '0';

                  elsif (role_master = '0' or SIO_start = '1') then
                     -- receiving a frame; slaves listen even without a local
                     -- start bit, real slave units are started by the master
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
                           eng_timeout      <= (others => '0');
                           if (role_master = '0' and engaged = '0') then
                              -- SYNC + first start bit = a new exchange:
                              -- slaves initialize all data registers to
                              -- FFFF, like real ones do (manual p.113)
                              engaged        <= '1';
                              frames_rx      <= (others => '0');
                              sent_this_ex   <= '0';
                              SIODATA32_RB   <= (others => '1');
                              SIOMULTI1_RB   <= (others => '1');
                              SIOMULTI2_link <= (others => '1');
                              SIOMULTI3_link <= (others => '1');
                           end if;
                        elsif (role_master = '1' and SIO_start = '1' and waitchild >= to_unsigned(multispeed, 12) * 64) then
                           -- This slot's wait expired with no start bit. Per
                           -- AGBProgrammingManual p.113-114 the master always
                           -- sequentially polls up to 3 slave slots -- even
                           -- on a 2-unit cable it must still time out on the
                           -- phantom 2nd (and 3rd) slot before the exchange
                           -- is really over, not just after slot 1. Absent
                           -- units simply keep the FFFF written at start.
                           waitchild <= (others => '0');
                           if (slave_slot = 2) then
                              slave_slot   <= (others => '0');
                              SIO_start    <= '0';
                              so_drive_low <= '0';
                              multi_id     <= "00";
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                           else
                              slave_slot <= slave_slot + 1;
                           end if;
                        elsif (role_master = '1') then
                           if (SIO_start = '1') then
                              waitchild <= waitchild + 1;
                           end if;
                        elsif (engaged = '1') then
                           if (sent_this_ex = '0' and frames_rx /= 0 and link_si_in = '0') then
                              -- our turn: the unit before us pulled our SI
                              -- low. Our slot index (and Multi-Player ID) is
                              -- the number of frames that came before us.
                              multisendmode <= '1';
                              multidataout  <= '0' & bitswap16(REG_SIODATA8) & '1';
                              cycles        <= (others => '0');
                              bitcount      <= 0;
                              sent_this_ex  <= '1';
                              multi_id      <= std_logic_vector(frames_rx);
                              case (frames_rx) is
                                 when "01"   => SIOMULTI1_RB <= REG_SIODATA8;
                                                SIODATA32_RB(31 downto 16) <= REG_SIODATA8;
                                 when "10"   => SIOMULTI2_link <= REG_SIODATA8;
                                 when others => SIOMULTI3_link <= REG_SIODATA8;
                              end case;
                           elsif (link_clk_in = '1' or eng_timeout >= to_unsigned(multispeed, 12) * 256) then
                              -- SC released: the master concluded the whole
                              -- exchange. This is a level check on the
                              -- synchronized wire -- it cannot be "missed"
                              -- the way an edge could (see the waitmasterend
                              -- regression history); the timeout is a pure
                              -- safety net against a master dying mid-
                              -- exchange with SC held low.
                              engaged      <= '0';
                              sent_this_ex <= '0';
                              frames_rx    <= (others => '0');
                              so_drive_low <= '0';
                              SIO_start    <= '0';
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                           else
                              eng_timeout <= eng_timeout + 1;
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
                        eng_timeout      <= (others => '0');
                        if (role_master = '1') then
                           -- master got a real answer for this slot -- still
                           -- has to poll the remaining slots (see above)
                           -- before the exchange is really done. Each slot's
                           -- frame lands in its own register (manual p.114).
                           case (slave_slot) is
                              when "00"   => SIOMULTI1_RB <= bitswap16(multidatain(15 downto 0));
                                             SIODATA32_RB(31 downto 16) <= bitswap16(multidatain(15 downto 0));
                              when "01"   => SIOMULTI2_link <= bitswap16(multidatain(15 downto 0));
                              when others => SIOMULTI3_link <= bitswap16(multidatain(15 downto 0));
                           end case;
                           waitchild    <= (others => '0');
                           if (slave_slot = 2) then
                              slave_slot   <= (others => '0');
                              SIO_start    <= '0';
                              so_drive_low <= '0';
                              multi_id     <= "00";
                              if (REG_SIOCNT(14) = '1') then
                                 IRP_Serial <= '1';
                              end if;
                           else
                              slave_slot <= slave_slot + 1;
                           end if;
                        else
                           -- slave got a frame: its slot index is the count
                           -- of frames seen so far, including our own sent
                           -- one if we already had our turn
                           rx_slot := frames_rx;
                           if (sent_this_ex = '1') then
                              rx_slot := frames_rx + 1;
                           end if;
                           case (rx_slot) is
                              when "00"   => SIODATA32_RB(15 downto 0) <= bitswap16(multidatain(15 downto 0));
                              when "01"   => SIOMULTI1_RB <= bitswap16(multidatain(15 downto 0));
                                             SIODATA32_RB(31 downto 16) <= bitswap16(multidatain(15 downto 0));
                              when "10"   => SIOMULTI2_link <= bitswap16(multidatain(15 downto 0));
                              when others => SIOMULTI3_link <= bitswap16(multidatain(15 downto 0));
                           end case;
                           if (frames_rx /= 3) then
                              frames_rx <= frames_rx + 1;
                           end if;
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
               if (engineMode = ENGINE_MULTI) then
                  -- only the cable-designated master can start an exchange;
                  -- a slave's d07 write is ignored (its d07 is a read-only
                  -- busy status, manual p.117) -- crucially it must NOT
                  -- reset an in-flight reception.
                  if (link_si_in = '0') then
                     role_master      <= '1';
                     SIO_start        <= '1';
                     bitcount         <= 0;
                     cycles           <= (others => '0');
                     waitchild        <= (others => '0');
                     startbitreceived <= '0';
                     slave_slot       <= (others => '0');
                     justsent_guard   <= '0';
                     so_drive_low     <= '0';
                     multisendmode    <= '1';
                     multidataout     <= '0' & bitswap16(REG_SIODATA8) & '1';
                     -- all data registers initialize to FFFF at exchange
                     -- start (manual p.113); own/received frames overwrite
                     -- their slots as the exchange progresses
                     SIODATA32_RB     <= (others => '1');
                     SIOMULTI1_RB     <= (others => '1');
                     SIOMULTI2_link   <= (others => '1');
                     SIOMULTI3_link   <= (others => '1');
                  end if;
               else
                  SIO_start        <= '1';
                  bitcount         <= 0;
                  cycles           <= (others => '0');
                  waitchild        <= (others => '0');
                  startbitreceived <= '0';
                  slave_slot       <= (others => '0');
                  justsent_guard   <= '0';
                  multisendmode    <= '0';
               end if;
            elsif (engineMode /= ENGINE_STUB) then
               -- clearing the start bit cancels a running transfer
               SIO_start          <= '0';
               multisendmode      <= '0';
               startbitreceived   <= '0';
               slave_slot         <= (others => '0');
               justsent_guard     <= '0';
               engaged            <= '0';
               sent_this_ex       <= '0';
               frames_rx          <= (others => '0');
               so_drive_low       <= '0';
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
            role_master      <= '0';
            engaged          <= '0';
            sent_this_ex     <= '0';
            frames_rx        <= (others => '0');
            eng_timeout      <= (others => '0');
            so_drive_low     <= '0';
            multi_id         <= "00";
            SIOMULTI2_link   <= (others => '1');
            SIOMULTI3_link   <= (others => '1');
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
                      " master=" & std_logic'image(role_master) &
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
