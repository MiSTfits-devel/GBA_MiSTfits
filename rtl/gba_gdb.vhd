library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- GDB debug engine.
--
-- Serves a command mailbox in DDR3 that a userspace daemon on the HPS drives
-- (support/gdb_daemon), which in turn speaks the GDB remote serial protocol to
-- a real gdb over TCP. DDR3 is used rather than the UART because the link port
-- is already spoken for by the serial/wireless engines, and because a mailbox
-- costs no pins: the DDR3Mux hardwires ddr3_ADDR(28..25)="0011", so a core byte
-- address X is HPS physical 0x30000000+X and the daemon can just mmap it.
--
-- The three things a debugger needs already exist in the core and are reused
-- rather than rebuilt:
--
--   registers -- every ARM register is already a readable proc-bus register on
--                savestate_bus (REG_SAVESTATE_REGS, r0..r15 at adr 1..16 and
--                CPSR at 17). No new export out of gba_cpu.
--   memory    -- gba_top's debug bus already carries an external master port
--                (GBA_Bus*) that outranks the savestate master. All accesses
--                here are 32bit, partial writes become read-modify-write, so
--                the 16bit-only regions (VRAM/PAL/OAM) behave correctly instead
--                of silently dropping sub-halfword writes like real hardware.
--   halt      -- the CPU's own HALTCNT path (new_halt/unhalt). Asserting it
--                stops the pipeline BEFORE the decoded instruction executes, so
--                regs(15) is left pointing at the instruction gdb should show
--                as current. new_halt is registered, so a breakpoint would
--                otherwise let one more instruction retire; cpu_inhibit is the
--                combinational half that closes that one-cycle window.
--
-- Halting is two stage. First the CPU is stopped as above, which is a clean
-- architectural boundary with nothing in flight. Only then is the whole core
-- frozen through gba_ctrl_pause, which needs a safe point anyway. Resume runs
-- the same sequence backwards. This engine itself is clocked on clk1x with no
-- ce gating, so it keeps serving the mailbox while the core it froze is dead.
--
-- Breakpoints and watchpoints are real comparators, not trap opcodes patched
-- into memory, so they work in ROM where a software breakpoint cannot.

entity gba_gdb is
   generic
   (
      -- 200 Mbyte. Above the multiboot image (192..192.25) and below the
      -- border (218), see the DDR3 map at the top of DDR3Mux.vhd.
      MAILBOX_ADDR : integer := 16#C800000#;
      BP_COUNT     : integer := 8;
      WP_COUNT     : integer := 4
   );
   port
   (
      clk1x            : in  std_logic;
      reset            : in  std_logic;
      gdb_enable       : in  std_logic;

      -- DDR3Mux client, same shape as the other single beat clients
      ddr3_request     : out std_logic := '0';
      ddr3_rnw         : out std_logic := '1';
      ddr3_address     : out unsigned(27 downto 0) := (others => '0');
      ddr3_burstcount  : out unsigned(9 downto 0) := to_unsigned(1, 10);
      ddr3_writeMask   : out std_logic_vector(7 downto 0) := (others => '1');
      ddr3_dataWrite   : out std_logic_vector(63 downto 0) := (others => '0');
      ddr3_granted     : in  std_logic;
      ddr3_done        : in  std_logic;
      ddr3_dataRead    : in  std_logic_vector(63 downto 0);

      -- register file access, muxed onto savestate_bus in gba_top
      ss_bus_out       : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', ACCESS_32BIT, x"F", '0');
      ss_bus_req       : out std_logic := '0';
      ss_wired_out     : in  std_logic_vector(proc_buswidth-1 downto 0);
      ss_wired_done    : in  std_logic;

      -- GBA address space master (gba_top debug bus)
      GBA_BusAddr      : out std_logic_vector(27 downto 0) := (others => '0');
      GBA_BusRnW       : out std_logic := '1';
      GBA_BusACC       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      GBA_BusWriteData : out std_logic_vector(31 downto 0) := (others => '0');
      GBA_Bus_written  : out std_logic := '0';
      GBA_BusReadData  : in  std_logic_vector(31 downto 0);
      GBA_BusReadDone  : in  std_logic;
      -- bypasses the memorymux ce-stopped deferral for the duration of a debug
      -- access, exactly as saving_savestate does for savestate capture
      gdb_memaccess    : out std_logic := '0';

      -- CPU control
      cpu_PC           : in  unsigned(31 downto 0);
      cpu_decode_ready : in  std_logic;
      cpu_halt         : in  std_logic;
      cpu_done         : in  std_logic;
      cpu_inhibit      : out std_logic := '0';
      cpu_new_halt     : out std_logic := '0';
      cpu_unhalt       : out std_logic := '0';

      -- watchpoint source: the CPU's own memory bus
      cpu_bus_Adr      : in  std_logic_vector(31 downto 0);
      cpu_bus_ena      : in  std_logic;
      cpu_bus_rnw      : in  std_logic;

      -- whole core freeze through gba_ctrl_pause
      gdb_pause        : out std_logic := '0';
      pause_active     : in  std_logic;

      gdb_halted       : out std_logic := '0'
   );
end entity;

architecture arch of gba_gdb is

   -- mailbox layout, byte offsets. Everything is 8 byte aligned because DDR3
   -- is accessed a qword at a time.
   constant OFF_CMD   : integer := 16#000#;
   constant OFF_ADDR  : integer := 16#008#;
   constant OFF_LEN   : integer := 16#010#;
   constant OFF_ACK   : integer := 16#018#;
   constant OFF_STATE : integer := 16#020#;
   constant OFF_DATA  : integer := 16#100#;

   constant CMD_NOP    : std_logic_vector(7 downto 0) := x"00";
   constant CMD_HALT   : std_logic_vector(7 downto 0) := x"01";
   constant CMD_CONT   : std_logic_vector(7 downto 0) := x"02";
   constant CMD_STEP   : std_logic_vector(7 downto 0) := x"03";
   constant CMD_RDMEM  : std_logic_vector(7 downto 0) := x"04";
   constant CMD_WRMEM  : std_logic_vector(7 downto 0) := x"05";
   constant CMD_RDREGS : std_logic_vector(7 downto 0) := x"06";
   constant CMD_WRREG  : std_logic_vector(7 downto 0) := x"07";
   constant CMD_SETBP  : std_logic_vector(7 downto 0) := x"08";
   constant CMD_SETWP  : std_logic_vector(7 downto 0) := x"09";

   constant STATUS_OK      : std_logic_vector(7 downto 0) := x"00";
   constant STATUS_BADCMD  : std_logic_vector(7 downto 0) := x"02";

   -- stop reasons, mirrored in gdb_proto.h
   constant STOP_NONE   : std_logic_vector(3 downto 0) := x"0";
   constant STOP_HOST   : std_logic_vector(3 downto 0) := x"1";
   constant STOP_BP     : std_logic_vector(3 downto 0) := x"2";
   constant STOP_STEP   : std_logic_vector(3 downto 0) := x"3";
   constant STOP_WP     : std_logic_vector(3 downto 0) := x"4";

   -- how often the mailbox is polled. Running, this is the only DDR3 traffic
   -- the engine makes and it must stay out of the way of the drawer, so one
   -- qword read per 4096 cycles (244us at 16.78MHz). Halted, nothing else is
   -- competing and gdb wants to feel responsive, so poll hard.
   constant POLL_DIV_RUN  : integer := 4096;
   constant POLL_DIV_HALT : integer := 64;

   type tstate is
   (
      IDLE,
      POLL_WAIT,
      FETCH_ADDR_WAIT,
      FETCH_LEN_WAIT,
      DISPATCH,
      MEMRD_BUS,  MEMRD_WAIT,  MEMRD_STORE, MEMRD_STORE_WAIT,
      MEMWR_LOAD, MEMWR_LOAD_WAIT, MEMWR_RMW, MEMWR_RMW_WAIT, MEMWR_BUS, MEMWR_BUS_WAIT,
      REGRD,      REGRD_WAIT,  REGRD_STORE, REGRD_STORE_WAIT,
      REGWR,
      PUBSTATE,   PUBSTATE_WAIT,
      ACK,        ACK_WAIT
   );
   signal state : tstate := IDLE;

   signal polldiv     : integer range 0 to POLL_DIV_RUN - 1 := 0;

   signal cmd_op      : std_logic_vector(7 downto 0) := (others => '0');
   signal cmd_seq     : std_logic_vector(7 downto 0) := (others => '0');
   signal cmd_arg     : std_logic_vector(31 downto 0) := (others => '0');
   signal last_seq    : std_logic_vector(7 downto 0) := (others => '0');
   signal status      : std_logic_vector(7 downto 0) := STATUS_OK;

   signal req_addr    : unsigned(27 downto 0) := (others => '0');
   signal req_len     : unsigned(15 downto 0) := (others => '0');

   signal cur_addr    : unsigned(27 downto 0) := (others => '0');
   signal bytes_left  : unsigned(16 downto 0) := (others => '0');
   signal data_off    : unsigned(12 downto 0) := (others => '0');
   signal qw_half     : std_logic := '0';
   signal qw_buf      : std_logic_vector(63 downto 0) := (others => '0');
   signal wr_word     : std_logic_vector(31 downto 0) := (others => '0');
   signal wr_mask     : std_logic_vector(3 downto 0) := (others => '0');

   signal reg_idx     : integer range 0 to 17 := 0;

   -- halt / run control
   signal halt_req    : std_logic := '0';
   signal step_req    : std_logic := '0';
   signal halted      : std_logic := '0';
   signal stop_reason : std_logic_vector(3 downto 0) := STOP_NONE;
   signal stop_pc     : unsigned(31 downto 0) := (others => '0');
   signal state_dirty : std_logic := '0';
   -- suppresses breakpoint matching for the first instruction after a resume,
   -- otherwise the breakpoint we are sitting on rematches immediately and gdb
   -- can never step off it
   signal bp_armed    : std_logic := '1';
   signal resuming    : std_logic := '0';

   type tbpaddr is array(0 to BP_COUNT - 1) of unsigned(31 downto 0);
   type twpaddr is array(0 to WP_COUNT - 1) of unsigned(31 downto 0);
   signal bp_addr     : tbpaddr := (others => (others => '0'));
   signal bp_en       : std_logic_vector(BP_COUNT - 1 downto 0) := (others => '0');
   signal wp_addr     : twpaddr := (others => (others => '0'));
   signal wp_en       : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal wp_rd       : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal wp_wr       : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');

   signal bp_hit      : std_logic;
   signal wp_hit      : std_logic;

   -- handshakes between the mailbox FSM and the run control process
   signal cmd_apply   : std_logic := '0';
   signal state_pub   : std_logic := '0';

   function qw_of (byte_addr : integer) return unsigned is
   begin
      return to_unsigned(byte_addr, 28);
   end function;

begin

   gdb_halted <= halted;

   ------------------------------------------------------------------
   -- breakpoint / watchpoint comparators
   ------------------------------------------------------------------

   -- matched against the instruction sitting in decode, i.e. the one about to
   -- execute, which is what "break at X" means to gdb
   process (all)
      variable hit : std_logic;
   begin
      hit := '0';
      if (gdb_enable = '1' and bp_armed = '1' and halted = '0' and cpu_decode_ready = '1') then
         for i in 0 to BP_COUNT - 1 loop
            if (bp_en(i) = '1' and bp_addr(i) = cpu_PC) then
               hit := '1';
            end if;
         end loop;
      end if;
      bp_hit <= hit;
   end process;

   process (all)
      variable hit : std_logic;
   begin
      hit := '0';
      if (gdb_enable = '1' and halted = '0' and cpu_bus_ena = '1') then
         for i in 0 to WP_COUNT - 1 loop
            if (wp_en(i) = '1' and wp_addr(i)(31 downto 2) = unsigned(cpu_bus_Adr(31 downto 2))) then
               if ((cpu_bus_rnw = '1' and wp_rd(i) = '1') or (cpu_bus_rnw = '0' and wp_wr(i) = '1')) then
                  hit := '1';
               end if;
            end if;
         end loop;
      end if;
      wp_hit <= hit;
   end process;

   -- combinational half of the halt: new_halt only takes effect on the next
   -- edge, by which time the breakpointed instruction would already have run
   cpu_inhibit <= bp_hit or halt_req when gdb_enable = '1' else '0';

   ------------------------------------------------------------------
   -- run control
   ------------------------------------------------------------------

   process (clk1x)
   begin
      if rising_edge(clk1x) then

         cpu_new_halt <= '0';
         cpu_unhalt   <= '0';

         if (reset = '1' or gdb_enable = '0') then

            halt_req    <= '0';
            step_req    <= '0';
            halted      <= '0';
            gdb_pause   <= '0';
            bp_armed    <= '1';
            resuming    <= '0';
            stop_reason <= STOP_NONE;

         else

            -- re-arm breakpoints once the instruction we resumed onto has
            -- retired, so we stop on the next hit but not on this one
            if (resuming = '1' and cpu_done = '1') then
               resuming <= '0';
               bp_armed <= '1';
            end if;

            if (halted = '0') then

               -- Only latch a reason while no stop is already pending, so a
               -- comparator firing between the request and the freeze cannot
               -- rewrite what gdb is told about the stop it already has.
               -- A step ends on the FIRST retire after the resume, which is
               -- also the retire that re-arms the breakpoints -- the two share
               -- a cycle and must not be sequenced against each other.
               if (halt_req = '0') then
                  if (step_req = '1' and cpu_done = '1') then
                     halt_req    <= '1';
                     step_req    <= '0';
                     stop_reason <= STOP_STEP;
                  elsif (bp_hit = '1') then
                     halt_req    <= '1';
                     stop_reason <= STOP_BP;
                  elsif (wp_hit = '1') then
                     halt_req    <= '1';
                     stop_reason <= STOP_WP;
                  end if;
               end if;

               -- stage 1: stop the CPU at an architectural boundary
               if (halt_req = '1') then
                  cpu_new_halt <= '1';
                  -- stage 2: once nothing is in flight, freeze the whole core
                  if (cpu_halt = '1') then
                     gdb_pause <= '1';
                     if (pause_active = '1') then
                        halted      <= '1';
                        stop_pc     <= cpu_PC;
                        state_dirty <= '1';
                     end if;
                  end if;
               end if;

            else

               -- resume: unfreeze the core first, then let the CPU go
               if (halt_req = '0') then
                  gdb_pause <= '0';
                  if (pause_active = '0') then
                     cpu_unhalt  <= '1';
                     halted      <= '0';
                     bp_armed    <= '0';
                     resuming    <= '1';
                     stop_reason <= STOP_NONE;
                     state_dirty <= '1';
                  end if;
               end if;

            end if;

         end if;

         -- the mailbox FSM below sets these; kept in the same process so the
         -- two writers to halt_req/step_req/state_dirty stay in one place
         if (cmd_apply = '1') then
            case (cmd_op) is
               when CMD_HALT =>
                  halt_req    <= '1';
                  stop_reason <= STOP_HOST;
               when CMD_CONT =>
                  halt_req    <= '0';
               when CMD_STEP =>
                  halt_req    <= '0';
                  step_req    <= '1';
               when others => null;
            end case;
         end if;

         if (state_pub = '1') then
            state_dirty <= '0';
         end if;

      end if;
   end process;

   ------------------------------------------------------------------
   -- mailbox FSM
   ------------------------------------------------------------------

   ss_bus_out.acc  <= ACCESS_32BIT;
   ss_bus_out.bEna <= x"F";
   ss_bus_out.rst  <= '0';

   process (clk1x)
      variable nbytes : integer range 0 to 4;
   begin
      if rising_edge(clk1x) then

         ddr3_request    <= '0';
         GBA_Bus_written <= '0';
         ss_bus_out.ena  <= '0';
         cmd_apply       <= '0';
         state_pub       <= '0';

         if (reset = '1' or gdb_enable = '0') then

            state         <= IDLE;
            polldiv       <= 0;
            last_seq      <= (others => '0');
            ss_bus_req    <= '0';
            gdb_memaccess <= '0';

         else

            case (state) is

               when IDLE =>
                  ss_bus_req    <= '0';
                  gdb_memaccess <= '0';
                  if (state_dirty = '1') then
                     state <= PUBSTATE;
                  else
                     if (polldiv > 0) then
                        polldiv <= polldiv - 1;
                     else
                        if (halted = '1') then polldiv <= POLL_DIV_HALT - 1;
                        else                   polldiv <= POLL_DIV_RUN - 1; end if;
                        ddr3_request <= '1';
                        ddr3_rnw     <= '1';
                        ddr3_address <= qw_of(MAILBOX_ADDR + OFF_CMD);
                        state        <= POLL_WAIT;
                     end if;
                  end if;

               when POLL_WAIT =>
                  if (ddr3_done = '1') then
                     if (ddr3_dataRead(15 downto 8) /= last_seq and ddr3_dataRead(7 downto 0) /= CMD_NOP) then
                        cmd_op       <= ddr3_dataRead(7 downto 0);
                        cmd_seq      <= ddr3_dataRead(15 downto 8);
                        cmd_arg      <= ddr3_dataRead(63 downto 32);
                        status       <= STATUS_OK;
                        ddr3_request <= '1';
                        ddr3_rnw     <= '1';
                        ddr3_address <= qw_of(MAILBOX_ADDR + OFF_ADDR);
                        state        <= FETCH_ADDR_WAIT;
                     else
                        state <= IDLE;
                     end if;
                  end if;

               when FETCH_ADDR_WAIT =>
                  if (ddr3_done = '1') then
                     req_addr     <= unsigned(ddr3_dataRead(27 downto 0));
                     ddr3_request <= '1';
                     ddr3_rnw     <= '1';
                     ddr3_address <= qw_of(MAILBOX_ADDR + OFF_LEN);
                     state        <= FETCH_LEN_WAIT;
                  end if;

               when FETCH_LEN_WAIT =>
                  if (ddr3_done = '1') then
                     req_len <= unsigned(ddr3_dataRead(15 downto 0));
                     state   <= DISPATCH;
                  end if;

               when DISPATCH =>
                  cur_addr   <= req_addr;
                  bytes_left <= resize(req_len, 17);
                  data_off   <= (others => '0');
                  qw_half    <= '0';
                  reg_idx    <= 0;
                  case (cmd_op) is
                     when CMD_HALT | CMD_CONT | CMD_STEP =>
                        cmd_apply <= '1';
                        state     <= ACK;
                     when CMD_RDMEM =>
                        gdb_memaccess <= '1';
                        state         <= MEMRD_BUS;
                     when CMD_WRMEM =>
                        gdb_memaccess <= '1';
                        state         <= MEMWR_LOAD;
                     when CMD_RDREGS =>
                        ss_bus_req <= '1';
                        state      <= REGRD;
                     when CMD_WRREG =>
                        ss_bus_req <= '1';
                        state      <= REGWR;
                     when CMD_SETBP =>
                        if (to_integer(unsigned(cmd_arg(3 downto 0))) < BP_COUNT) then
                           bp_addr(to_integer(unsigned(cmd_arg(3 downto 0)))) <= resize(req_addr, 32);
                           bp_en(to_integer(unsigned(cmd_arg(3 downto 0))))   <= cmd_arg(4);
                        else
                           status <= STATUS_BADCMD;
                        end if;
                        state <= ACK;
                     when CMD_SETWP =>
                        if (to_integer(unsigned(cmd_arg(3 downto 0))) < WP_COUNT) then
                           wp_addr(to_integer(unsigned(cmd_arg(3 downto 0)))) <= resize(req_addr, 32);
                           wp_en(to_integer(unsigned(cmd_arg(3 downto 0))))   <= cmd_arg(4);
                           wp_rd(to_integer(unsigned(cmd_arg(3 downto 0))))   <= cmd_arg(5);
                           wp_wr(to_integer(unsigned(cmd_arg(3 downto 0))))   <= cmd_arg(6);
                        else
                           status <= STATUS_BADCMD;
                        end if;
                        state <= ACK;
                     when others =>
                        status <= STATUS_BADCMD;
                        state  <= ACK;
                  end case;

               ------------------------------------------------------
               -- memory read: 32bit bus reads packed 2 per DDR3 qword
               ------------------------------------------------------
               when MEMRD_BUS =>
                  if (bytes_left = 0) then
                     if (qw_half = '1') then
                        state <= MEMRD_STORE;  -- flush the odd trailing word
                     else
                        state <= ACK;
                     end if;
                  else
                     GBA_BusAddr     <= std_logic_vector(cur_addr);
                     GBA_BusRnW      <= '1';
                     GBA_BusACC      <= ACCESS_32BIT;
                     GBA_Bus_written <= '1';
                     state           <= MEMRD_WAIT;
                  end if;

               when MEMRD_WAIT =>
                  if (GBA_BusReadDone = '1') then
                     if (qw_half = '0') then
                        qw_buf(31 downto 0) <= GBA_BusReadData;
                        qw_half             <= '1';
                        cur_addr            <= cur_addr + 4;
                        if (bytes_left > 4) then bytes_left <= bytes_left - 4;
                        else                     bytes_left <= (others => '0'); end if;
                        state <= MEMRD_BUS;
                     else
                        qw_buf(63 downto 32) <= GBA_BusReadData;
                        qw_half              <= '0';
                        cur_addr             <= cur_addr + 4;
                        if (bytes_left > 4) then bytes_left <= bytes_left - 4;
                        else                     bytes_left <= (others => '0'); end if;
                        state <= MEMRD_STORE;
                     end if;
                  end if;

               when MEMRD_STORE =>
                  ddr3_request   <= '1';
                  ddr3_rnw       <= '0';
                  ddr3_writeMask <= x"FF";
                  ddr3_dataWrite <= qw_buf;
                  ddr3_address   <= qw_of(MAILBOX_ADDR + OFF_DATA) + resize(data_off, 28);
                  state          <= MEMRD_STORE_WAIT;

               when MEMRD_STORE_WAIT =>
                  if (ddr3_done = '1') then
                     data_off <= data_off + 8;
                     qw_buf   <= (others => '0');
                     if (bytes_left = 0) then state <= ACK;
                     else                     state <= MEMRD_BUS; end if;
                  end if;

               ------------------------------------------------------
               -- memory write: one qword of payload at a time, each word
               -- written whole, or read-modify-written when partial
               ------------------------------------------------------
               when MEMWR_LOAD =>
                  if (bytes_left = 0) then
                     state <= ACK;
                  else
                     ddr3_request <= '1';
                     ddr3_rnw     <= '1';
                     ddr3_address <= qw_of(MAILBOX_ADDR + OFF_DATA) + resize(data_off, 28);
                     state        <= MEMWR_LOAD_WAIT;
                  end if;

               when MEMWR_LOAD_WAIT =>
                  if (ddr3_done = '1') then
                     qw_buf   <= ddr3_dataRead;
                     qw_half  <= '0';
                     data_off <= data_off + 8;
                     state    <= MEMWR_RMW;
                  end if;

               when MEMWR_RMW =>
                  -- how many bytes of this word are actually in range
                  if (bytes_left >= 4) then nbytes := 4;
                  else                      nbytes := to_integer(bytes_left(2 downto 0)); end if;
                  if (qw_half = '0') then wr_word <= qw_buf(31 downto 0);
                  else                    wr_word <= qw_buf(63 downto 32); end if;
                  case (nbytes) is
                     when 4      => wr_mask <= "1111";
                     when 3      => wr_mask <= "0111";
                     when 2      => wr_mask <= "0011";
                     when 1      => wr_mask <= "0001";
                     when others => wr_mask <= "0000";
                  end case;
                  if (nbytes = 4) then
                     state <= MEMWR_BUS;
                  else
                     -- partial word: pull the original so the untouched bytes
                     -- survive, since the bus only carries whole words here
                     GBA_BusAddr     <= std_logic_vector(cur_addr);
                     GBA_BusRnW      <= '1';
                     GBA_BusACC      <= ACCESS_32BIT;
                     GBA_Bus_written <= '1';
                     state           <= MEMWR_RMW_WAIT;
                  end if;

               when MEMWR_RMW_WAIT =>
                  if (GBA_BusReadDone = '1') then
                     for b in 0 to 3 loop
                        if (wr_mask(b) = '0') then
                           wr_word(b*8+7 downto b*8) <= GBA_BusReadData(b*8+7 downto b*8);
                        end if;
                     end loop;
                     state <= MEMWR_BUS;
                  end if;

               when MEMWR_BUS =>
                  GBA_BusAddr      <= std_logic_vector(cur_addr);
                  GBA_BusRnW       <= '0';
                  GBA_BusACC       <= ACCESS_32BIT;
                  GBA_BusWriteData <= wr_word;
                  GBA_Bus_written  <= '1';
                  state            <= MEMWR_BUS_WAIT;

               when MEMWR_BUS_WAIT =>
                  if (GBA_BusReadDone = '1') then
                     cur_addr <= cur_addr + 4;
                     if (bytes_left > 4) then bytes_left <= bytes_left - 4;
                     else                     bytes_left <= (others => '0'); end if;
                     if (qw_half = '0' and bytes_left > 4) then
                        qw_half <= '1';
                        state   <= MEMWR_RMW;
                     else
                        state <= MEMWR_LOAD;
                     end if;
                  end if;

               ------------------------------------------------------
               -- register file, r0..r15 then CPSR, packed 2 per qword
               ------------------------------------------------------
               when REGRD =>
                  if (reg_idx > 16) then
                     if (qw_half = '1') then
                        state <= REGRD_STORE;
                     else
                        state <= ACK;
                     end if;
                  else
                     -- REG_SAVESTATE_REGS sits at adr 1, index i at 1+i
                     ss_bus_out.adr <= std_logic_vector(to_unsigned(1 + reg_idx, proc_busadr));
                     ss_bus_out.rnw <= '1';
                     ss_bus_out.ena <= '1';
                     state          <= REGRD_WAIT;
                  end if;

               when REGRD_WAIT =>
                  if (ss_wired_done = '1') then
                     if (qw_half = '0') then
                        qw_buf(31 downto 0) <= ss_wired_out;
                        qw_half             <= '1';
                        reg_idx             <= reg_idx + 1;
                        state               <= REGRD;
                     else
                        qw_buf(63 downto 32) <= ss_wired_out;
                        qw_half              <= '0';
                        reg_idx              <= reg_idx + 1;
                        state                <= REGRD_STORE;
                     end if;
                  end if;

               when REGRD_STORE =>
                  ddr3_request   <= '1';
                  ddr3_rnw       <= '0';
                  ddr3_writeMask <= x"FF";
                  ddr3_dataWrite <= qw_buf;
                  ddr3_address   <= qw_of(MAILBOX_ADDR + OFF_DATA) + resize(data_off, 28);
                  state          <= REGRD_STORE_WAIT;

               when REGRD_STORE_WAIT =>
                  if (ddr3_done = '1') then
                     data_off <= data_off + 8;
                     qw_buf   <= (others => '0');
                     if (reg_idx > 16) then state <= ACK;
                     else                   state <= REGRD; end if;
                  end if;

               when REGWR =>
                  if (to_integer(req_addr) <= 16) then
                     ss_bus_out.adr <= std_logic_vector(resize(req_addr + 1, proc_busadr));
                     ss_bus_out.Din <= cmd_arg;
                     ss_bus_out.rnw <= '0';
                     ss_bus_out.ena <= '1';
                  else
                     status <= STATUS_BADCMD;
                  end if;
                  state <= ACK;

               ------------------------------------------------------
               -- publish state, then acknowledge
               ------------------------------------------------------
               when PUBSTATE =>
                  ddr3_request   <= '1';
                  ddr3_rnw       <= '0';
                  ddr3_writeMask <= x"FF";
                  -- [0] halted, [7:4] stop reason, [63:32] stop PC
                  ddr3_dataWrite <= std_logic_vector(stop_pc) & x"000000" & stop_reason & "000" & halted;
                  ddr3_address   <= qw_of(MAILBOX_ADDR + OFF_STATE);
                  state          <= PUBSTATE_WAIT;

               when PUBSTATE_WAIT =>
                  if (ddr3_done = '1') then
                     state_pub <= '1';
                     state     <= IDLE;
                  end if;

               when ACK =>
                  ss_bus_req    <= '0';
                  gdb_memaccess <= '0';
                  last_seq      <= cmd_seq;
                  ddr3_request   <= '1';
                  ddr3_rnw       <= '0';
                  ddr3_writeMask <= x"FF";
                  ddr3_dataWrite <= (63 downto 16 => '0') & status & cmd_seq;
                  ddr3_address   <= qw_of(MAILBOX_ADDR + OFF_ACK);
                  state          <= ACK_WAIT;

               when ACK_WAIT =>
                  if (ddr3_done = '1') then
                     state <= IDLE;
                  end if;

            end case;

         end if;

         if (ddr3_granted = '1') then
            ddr3_request <= '0';
         end if;

      end if;
   end process;

end architecture;
