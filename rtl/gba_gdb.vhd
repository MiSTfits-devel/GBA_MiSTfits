library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

-- DDR3 mailbox debugger. The engine runs on clk1x independently of the two
-- cores' clock enables. Stop matches only feed the pause controller's CE
-- register and the engine's stop bookkeeping, never the CPU pipeline.

entity gba_gdb is
   generic
   (
      -- 200 Mbyte. Above the multiboot image (192..192.25) and below the
      -- border (218), see the DDR3 map at the top of DDR3Mux.vhd.
      MAILBOX_ADDR : integer := 16#C800000#;
      BP_COUNT     : integer := 8;
      WP_COUNT     : integer := 4;
      DUAL_CORE    : std_logic := '0';
      HAS_DIRECT_REGRD : std_logic := '0'
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

      -- Active-core savestate bus
      ss_bus_out       : out proc_bus_gb_type := ((others => '0'), (others => '0'), '1', '0', ACCESS_32BIT, x"F", '0');
      ss_bus_req       : out std_logic := '0';
      ss_wired_out     : in  std_logic_vector(proc_buswidth-1 downto 0);
      ss_wired_done    : in  std_logic;

      -- Active-core GBA address space master
      GBA_BusAddr      : out std_logic_vector(27 downto 0) := (others => '0');
      GBA_BusRnW       : out std_logic := '1';
      GBA_BusACC       : out std_logic_vector(1 downto 0) := ACCESS_32BIT;
      GBA_BusWriteData : out std_logic_vector(31 downto 0) := (others => '0');
      GBA_Bus_written  : out std_logic := '0';
      GBA_BusReadData  : in  std_logic_vector(31 downto 0);
      GBA_BusReadDone  : in  std_logic;
      gdb_memaccess    : out std_logic := '0';
      mem_dbg_ready    : in  std_logic := '1';

      dbg_reg_wr       : out std_logic := '0';
      dbg_reg_idx      : out std_logic_vector(4 downto 0) := (others => '0');
      dbg_reg_data     : out std_logic_vector(31 downto 0) := (others => '0');

      dbg_hold         : out std_logic := '0';
      dbg_step         : out std_logic := '0';
      dbg_stop_now     : out std_logic := '0';
      dbg_reset_req    : out std_logic := '0';
      gdb_halted       : out std_logic := '0';
      active_core_out  : out std_logic := '0';

      joy_ov_mask_c0   : out std_logic_vector(9 downto 0) := (others => '0');
      joy_ov_val_c0    : out std_logic_vector(9 downto 0) := (others => '0');
      joy_ov_mask_c1   : out std_logic_vector(9 downto 0) := (others => '0');
      joy_ov_val_c1    : out std_logic_vector(9 downto 0) := (others => '0');

      c0_ce            : in std_logic := '0';
      c0_arch_pc       : in unsigned(31 downto 0) := (others => '0');
      c0_fetch_instr_pc: in unsigned(31 downto 0) := (others => '0');
      c0_stall_instr_pc: in unsigned(31 downto 0) := (others => '0');
      c0_decode_load   : in std_logic := '0';
      c0_execute_stall : in std_logic := '0';
      c0_decode_ready  : in std_logic := '0';
      c0_fetch_ready   : in std_logic := '0';
      c0_decode_opcode : in std_logic_vector(31 downto 0) := (others => '0');
      c0_bus_state     : in std_logic_vector(1 downto 0) := (others => '0');
      c0_thumbmode     : in std_logic := '0';
      c0_cpu_mode      : in std_logic_vector(3 downto 0) := (others => '0');
      c0_cpu_done      : in std_logic := '0';
      c0_cpu_halt      : in std_logic := '0';
      c0_cpu_bus_adr   : in std_logic_vector(31 downto 0) := (others => '0');
      c0_cpu_bus_ena   : in std_logic := '0';
      c0_cpu_bus_rnw   : in std_logic := '0';
      c0_cpu_bus_acc   : in std_logic_vector(1 downto 0) := (others => '0');
      c0_cpu_bus_seq   : in std_logic := '0';
      c0_cpu_bus_code  : in std_logic := '0';
      c0_dma_on        : in std_logic := '0';
      c0_vblank        : in std_logic := '0';
      c0_hblank        : in std_logic := '0';
      c0_line_trigger  : in std_logic := '0';
      c0_dispstat      : in std_logic_vector(31 downto 0) := (others => '0');
      c0_irq_if        : in std_logic_vector(15 downto 0) := (others => '0');
      c0_irq_ie        : in std_logic_vector(15 downto 0) := (others => '0');
      c0_irq_ime       : in std_logic := '0';
      c0_cpu_irq       : in std_logic := '0';
      c0_haltcnt       : in std_logic_vector(7 downto 0) := (others => '0');
      c0_mem_info      : in std_logic_vector(31 downto 0) := (others => '0');
      c0_link_state    : in std_logic_vector(70 downto 0) := (others => '0');
      c0_link_pins     : in std_logic_vector(7 downto 0) := (others => '0');

      c1_ce            : in std_logic := '0';
      c1_arch_pc       : in unsigned(31 downto 0) := (others => '0');
      c1_fetch_instr_pc: in unsigned(31 downto 0) := (others => '0');
      c1_stall_instr_pc: in unsigned(31 downto 0) := (others => '0');
      c1_decode_load   : in std_logic := '0';
      c1_execute_stall : in std_logic := '0';
      c1_decode_ready  : in std_logic := '0';
      c1_fetch_ready   : in std_logic := '0';
      c1_decode_opcode : in std_logic_vector(31 downto 0) := (others => '0');
      c1_bus_state     : in std_logic_vector(1 downto 0) := (others => '0');
      c1_thumbmode     : in std_logic := '0';
      c1_cpu_mode      : in std_logic_vector(3 downto 0) := (others => '0');
      c1_cpu_done      : in std_logic := '0';
      c1_cpu_halt      : in std_logic := '0';
      c1_cpu_bus_adr   : in std_logic_vector(31 downto 0) := (others => '0');
      c1_cpu_bus_ena   : in std_logic := '0';
      c1_cpu_bus_rnw   : in std_logic := '0';
      c1_cpu_bus_acc   : in std_logic_vector(1 downto 0) := (others => '0');
      c1_cpu_bus_seq   : in std_logic := '0';
      c1_cpu_bus_code  : in std_logic := '0';
      c1_dma_on        : in std_logic := '0';
      c1_vblank        : in std_logic := '0';
      c1_hblank        : in std_logic := '0';
      c1_line_trigger  : in std_logic := '0';
      c1_dispstat      : in std_logic_vector(31 downto 0) := (others => '0');
      c1_irq_if        : in std_logic_vector(15 downto 0) := (others => '0');
      c1_irq_ie        : in std_logic_vector(15 downto 0) := (others => '0');
      c1_irq_ime       : in std_logic := '0';
      c1_cpu_irq       : in std_logic := '0';
      c1_haltcnt       : in std_logic_vector(7 downto 0) := (others => '0');
      c1_mem_info      : in std_logic_vector(31 downto 0) := (others => '0');
      c1_link_state    : in std_logic_vector(70 downto 0) := (others => '0');
      c1_link_pins     : in std_logic_vector(7 downto 0) := (others => '0');

      wireless_debug_state : in std_logic_vector(7 downto 0) := (others => '0');
      dbg_reg_rd_idx       : out std_logic_vector(4 downto 0) := (others => '0');
      dbg_reg_rd_data      : in std_logic_vector(31 downto 0) := (others => '0')
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
   constant OFF_CYCLES: integer := 16#028#;
   constant OFF_DATA  : integer := 16#100#;
   constant DATA_MAX   : integer := 4096;
   constant SS_WORDS   : integer := 68;
   constant NUM_REGS   : integer := 17;
   constant TRACE_ENTRIES : integer := 64;

   constant MAGIC     : std_logic_vector(31 downto 0) := x"47424432";
   constant PROTO_VER : std_logic_vector(15 downto 0) := x"0002";

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
   constant CMD_STEP_CYCLES : std_logic_vector(7 downto 0) := x"0A";
   constant CMD_STEP_FRAMES : std_logic_vector(7 downto 0) := x"0B";
   constant CMD_STEP_LINE   : std_logic_vector(7 downto 0) := x"0C";
   constant CMD_BREAK_CYCLE : std_logic_vector(7 downto 0) := x"0D";
   constant CMD_BREAK_EVENT : std_logic_vector(7 downto 0) := x"0E";
   constant CMD_RDSTATE     : std_logic_vector(7 downto 0) := x"0F";
   constant CMD_SET_CORE    : std_logic_vector(7 downto 0) := x"10";
   constant CMD_SET_INPUT   : std_logic_vector(7 downto 0) := x"11";
   constant CMD_RESET       : std_logic_vector(7 downto 0) := x"12";
   constant CMD_RD_TRACE    : std_logic_vector(7 downto 0) := x"13";

   constant STATUS_OK      : std_logic_vector(7 downto 0) := x"00";
   constant STATUS_BUSY    : std_logic_vector(7 downto 0) := x"01";
   constant STATUS_BADCMD  : std_logic_vector(7 downto 0) := x"02";
   constant STATUS_BADARG  : std_logic_vector(7 downto 0) := x"03";

   -- stop reasons, mirrored in gdb_proto.h
   constant STOP_NONE   : std_logic_vector(3 downto 0) := x"0";
   constant STOP_HOST   : std_logic_vector(3 downto 0) := x"1";
   constant STOP_BP     : std_logic_vector(3 downto 0) := x"2";
   constant STOP_STEP   : std_logic_vector(3 downto 0) := x"3";
   constant STOP_WP     : std_logic_vector(3 downto 0) := x"4";
   constant STOP_STEP_CYCLE  : std_logic_vector(3 downto 0) := x"5";
   constant STOP_STEP_FRAME  : std_logic_vector(3 downto 0) := x"6";
   constant STOP_STEP_LINE   : std_logic_vector(3 downto 0) := x"7";
   constant STOP_BREAK_CYCLE : std_logic_vector(3 downto 0) := x"8";
   constant STOP_BREAK_EVENT : std_logic_vector(3 downto 0) := x"9";
   constant STOP_RESET_HALT  : std_logic_vector(3 downto 0) := x"A";

   -- how often the mailbox is polled. Running, this is the only DDR3 traffic
   -- the engine makes and it must stay out of the way of the drawer, so one
   -- qword read per 4096 cycles (244us at 16.78MHz). Halted, nothing else is
   -- competing and gdb wants to feel responsive, so poll hard.
   constant POLL_DIV_RUN  : integer := 4096;
   constant POLL_DIV_HALT : integer := 64;

   type tstate is
   (
      INIT_SYNC, INIT_WAIT, IDLE, POLL_WAIT, FETCH_ADDR_WAIT, FETCH_LEN_WAIT, DISPATCH,
      SINGLE_CYCLE_WAIT, RESET_WAIT, MEM_READY,
      MEMRD_BUS,  MEMRD_WAIT,  MEMRD_STORE, MEMRD_STORE_WAIT,
      MEMWR_LOAD, MEMWR_LOAD_WAIT, MEMWR_RMW, MEMWR_RMW_WAIT, MEMWR_BUS, MEMWR_BUS_WAIT,
      SS_READ, SS_WAIT, SS_STORE, SS_STORE_WAIT,
      TELEMETRY_STORE, TELEMETRY_WAIT,
      TRACE_HEAD, TRACE_HEAD_WAIT, TRACE_RD_FETCH, TRACE_RD_STORE, TRACE_STORE_WAIT,
      COMPLETE, PUB_CYCLES_WAIT, PUB_STATE_WAIT, ACK_WAIT
   );
   signal state : tstate := INIT_SYNC;

   subtype tcore_id is integer range 0 to 1;
   subtype tqword is std_logic_vector(63 downto 0);
   type tcore is record
      ce, decode_load, execute_stall, decode_ready, fetch_ready : std_logic;
      thumbmode, cpu_done, cpu_halt, bus_ena, bus_rnw : std_logic;
      bus_seq, bus_code, dma_on, vblank, hblank, line_trigger : std_logic;
      irq_ime, cpu_irq : std_logic;
      arch_pc, fetch_pc, stall_pc : unsigned(31 downto 0);
      opcode, bus_adr, dispstat, mem_info : std_logic_vector(31 downto 0);
      irq_if, irq_ie : std_logic_vector(15 downto 0);
      haltcnt, link_pins : std_logic_vector(7 downto 0);
      link_state : std_logic_vector(70 downto 0);
      cpu_mode : std_logic_vector(3 downto 0);
      bus_state, bus_acc : std_logic_vector(1 downto 0);
   end record;
   type tcores is array(tcore_id) of tcore;
   type tcore_pc is array(tcore_id) of unsigned(31 downto 0);
   type tcore_count is array(tcore_id) of unsigned(63 downto 0);
   type tinputs is array(tcore_id) of std_logic_vector(9 downto 0);
   type tevent_prev is array(tcore_id) of std_logic_vector(6 downto 0);
   type tqwords is array(natural range <>) of tqword;

   signal cores          : tcores;
   signal selected       : tcore;
   signal active_core    : tcore_id := 0;
   signal joy_mask       : tinputs := (others => (others => '0'));
   signal joy_val        : tinputs := (others => (others => '0'));
   signal event_prev     : tevent_prev := (others => (others => '0'));
   signal decode_pending : std_logic_vector(tcore_id) := (others => '0');
   signal decoded_pc     : tcore_pc := (others => (others => '0'));

   signal polldiv        : integer range 0 to POLL_DIV_RUN - 1 := 0;
   signal cmd_op         : std_logic_vector(7 downto 0) := CMD_NOP;
   signal cmd_seq        : std_logic_vector(7 downto 0) := (others => '0');
   signal cmd_arg        : std_logic_vector(31 downto 0) := (others => '0');
   signal last_seq       : std_logic_vector(7 downto 0) := (others => '0');
   signal status         : std_logic_vector(7 downto 0) := STATUS_OK;
   signal ack_pending    : std_logic := '0';
   signal ddr3_inflight  : std_logic := '0';

   signal req_addr       : unsigned(63 downto 0) := (others => '0');
   signal req_len        : unsigned(12 downto 0) := (others => '0');
   signal req_len_valid  : std_logic := '0';
   signal cur_addr       : unsigned(27 downto 0) := (others => '0');
   signal bytes_left     : unsigned(12 downto 0) := (others => '0');
   signal data_off       : unsigned(12 downto 0) := (others => '0');
   signal qw_half        : std_logic := '0';
   signal qw_buf         : tqword := (others => '0');
   signal wr_word        : std_logic_vector(31 downto 0) := (others => '0');
   signal wr_mask        : std_logic_vector(3 downto 0) := (others => '0');
   signal reg_idx        : integer range 0 to SS_WORDS := 0;
   signal telemetry_idx  : integer range 0 to 16 := 0;

   type trun_mode is (RUN_NORMAL, RUN_INSNS, RUN_CYCLES, RUN_FRAMES, RUN_LINE);
   signal run_mode       : trun_mode := RUN_NORMAL;
   signal step_rem       : unsigned(31 downto 0) := (others => '0');
   signal target_line    : std_logic_vector(7 downto 0) := (others => '0');
   signal line_at_hblank : std_logic := '0';
   signal reset_left     : integer range 0 to 16 := 0;
   signal halted         : std_logic := '0';
   signal stop_pending   : std_logic := '0';
   signal stop_reason    : std_logic_vector(3 downto 0) := STOP_NONE;
   signal stop_pc        : unsigned(31 downto 0) := (others => '0');
   signal stop_slot      : std_logic_vector(3 downto 0) := (others => '0');
   signal stop_core      : tcore_id := 0;
   signal wp_hit_addr    : std_logic_vector(31 downto 0) := (others => '0');
   signal state_dirty    : std_logic := '0';
   signal state_word     : tqword;
   signal state_publish  : tqword := (others => '0');
   signal telemetry      : tqwords(0 to 16);

   type tbpaddr is array(0 to BP_COUNT - 1) of unsigned(31 downto 0);
   type twpaddr is array(0 to WP_COUNT - 1) of unsigned(31 downto 2);
   type tbp_matches is array(tcore_id) of std_logic_vector(0 to BP_COUNT - 1);
   type twp_matches is array(tcore_id) of std_logic_vector(0 to WP_COUNT - 1);
   signal bp_addr        : tbpaddr := (others => (others => '0'));
   signal bp_en          : std_logic_vector(BP_COUNT - 1 downto 0) := (others => '0');
   signal bp_core        : std_logic_vector(BP_COUNT - 1 downto 0) := (others => '0');
   signal bp_both        : std_logic_vector(BP_COUNT - 1 downto 0) := (others => '0');
   signal wp_addr        : twpaddr := (others => (others => '0'));
   signal wp_en          : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal wp_core        : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal wp_both        : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal wp_rd          : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal wp_wr          : std_logic_vector(WP_COUNT - 1 downto 0) := (others => '0');
   signal bp_matches     : tbp_matches;
   signal wp_matches     : twp_matches;

   signal cycle_bp_en    : std_logic := '0';
   signal cycle_bp_before: unsigned(63 downto 0) := (others => '0');
   signal cycle_due      : std_logic;
   signal event_mask     : std_logic_vector(5 downto 0) := (others => '0');
   signal match_reason   : std_logic_vector(3 downto 0);
   signal match_core     : tcore_id;
   signal match_slot     : std_logic_vector(3 downto 0);

   signal total_cycles   : unsigned(63 downto 0) := (others => '0');
   signal total_insns    : tcore_count := (others => (others => '0'));
   signal total_frames   : unsigned(31 downto 0) := (others => '0');

   type t_trace_ring is array (0 to TRACE_ENTRIES - 1) of std_logic_vector(63 downto 0);
   signal trace_ring     : t_trace_ring;
   attribute ramstyle    : string;
   attribute ramstyle of trace_ring : signal is "M10K, no_rw_check";
   signal trace_wr_ptr   : unsigned(5 downto 0) := (others => '0');
   signal trace_count    : unsigned(6 downto 0) := (others => '0');
   signal trace_rd_ptr   : unsigned(5 downto 0) := (others => '0');
   signal trace_rd_data  : tqword;
   signal trace_delta    : unsigned(7 downto 0) := (others => '0');
   signal trace_delta_next : unsigned(7 downto 0);
   signal trace_idx      : integer range 0 to TRACE_ENTRIES - 1 := 0;
   signal trace_write    : std_logic;
   signal trace_pc       : unsigned(31 downto 0);

   function core_bit(id : tcore_id) return std_logic is
   begin
      if id = 0 then return '0'; else return '1'; end if;
   end function;

   function core_words(c : tcore; wireless : std_logic_vector(7 downto 0)) return tqwords is
      variable words : tqwords(0 to 5);
   begin
      words(0) := std_logic_vector(c.fetch_pc) & std_logic_vector(c.arch_pc);
      words(1) := c.opcode & std_logic_vector(c.stall_pc);
      words(2) := c.dispstat & c.bus_adr;
      words(3) := c.mem_info & c.irq_ie & c.irq_if;
      words(4) := c.link_state(63 downto 0);
      words(5) := "000000" & wireless & c.cpu_irq & c.irq_ime & c.line_trigger &
                  c.hblank & c.vblank & c.dma_on & c.bus_code & c.bus_seq &
                  c.bus_acc & c.bus_rnw & c.bus_ena & c.cpu_halt & c.cpu_done &
                  c.bus_state & c.cpu_mode & c.thumbmode & c.fetch_ready &
                  c.decode_ready & c.execute_stall & c.decode_load & c.ce &
                  c.haltcnt & c.link_pins & '0' & c.link_state(70 downto 64);
      return words;
   end function;

   function qw_of (byte_addr : integer) return unsigned is
   begin
      return to_unsigned(byte_addr, 28);
   end function;

begin

   cores(0) <= (
      c0_ce, c0_decode_load, c0_execute_stall, c0_decode_ready, c0_fetch_ready,
      c0_thumbmode, c0_cpu_done, c0_cpu_halt, c0_cpu_bus_ena, c0_cpu_bus_rnw,
      c0_cpu_bus_seq, c0_cpu_bus_code, c0_dma_on, c0_vblank, c0_hblank, c0_line_trigger,
      c0_irq_ime, c0_cpu_irq, c0_arch_pc, c0_fetch_instr_pc, c0_stall_instr_pc,
      c0_decode_opcode, c0_cpu_bus_adr, c0_dispstat, c0_mem_info, c0_irq_if, c0_irq_ie,
      c0_haltcnt, c0_link_pins, c0_link_state, c0_cpu_mode, c0_bus_state, c0_cpu_bus_acc
   );
   cores(1) <= (
      c1_ce, c1_decode_load, c1_execute_stall, c1_decode_ready, c1_fetch_ready,
      c1_thumbmode, c1_cpu_done, c1_cpu_halt, c1_cpu_bus_ena, c1_cpu_bus_rnw,
      c1_cpu_bus_seq, c1_cpu_bus_code, c1_dma_on, c1_vblank, c1_hblank, c1_line_trigger,
      c1_irq_ime, c1_cpu_irq, c1_arch_pc, c1_fetch_instr_pc, c1_stall_instr_pc,
      c1_decode_opcode, c1_cpu_bus_adr, c1_dispstat, c1_mem_info, c1_irq_if, c1_irq_ie,
      c1_haltcnt, c1_link_pins, c1_link_state, c1_cpu_mode, c1_bus_state, c1_cpu_bus_acc
   );
   selected <= cores(active_core) when DUAL_CORE = '1' else cores(0);
   active_core_out <= core_bit(active_core);
   joy_ov_mask_c0 <= joy_mask(0);
   joy_ov_val_c0  <= joy_val(0);
   joy_ov_mask_c1 <= joy_mask(1);
   joy_ov_val_c1  <= joy_val(1);

   dbg_reset_req <= '1' when reset_left /= 0 else '0';
   dbg_hold      <= halted or dbg_reset_req;
   gdb_halted    <= halted;
   ddr3_burstcount <= to_unsigned(1, ddr3_burstcount'length);

   state_word <= std_logic_vector(stop_pc) & (31 downto 13 => '0') &
                 core_bit(stop_core) & stop_slot & stop_reason &
                 '0' & DUAL_CORE & core_bit(active_core) & halted;
   telemetry(0) <= state_word;
   telemetry(1) <= std_logic_vector(total_cycles);
   telemetry(2) <= std_logic_vector(total_insns(0));
   telemetry(3) <= std_logic_vector(total_insns(1));
   telemetry(4) <= wp_hit_addr & std_logic_vector(total_frames);
   telemetry(5 to 10) <= core_words(cores(0), wireless_debug_state);
   telemetry(11 to 16) <= core_words(cores(1), x"00") when DUAL_CORE = '1' else (others => (others => '0'));

   -- Store target-1 when the command is accepted, not in the CE stop path.
   cycle_due <= '1' when cycle_bp_en = '1' and c0_ce = '1' and total_cycles = cycle_bp_before else '0';

   -- Each slot compares independently; the CE override uses a reduction of
   -- the hits, not the slot/core priority encoder used for stop reporting.
   comparators : for k in tcore_id generate
      present : if k = 0 or DUAL_CORE = '1' generate
         breakpoints : for i in 0 to BP_COUNT - 1 generate
            signal fetch_match, stall_match : std_logic;
         begin
            fetch_match <= '1' when bp_addr(i) = cores(k).fetch_pc else '0';
            stall_match <= '1' when bp_addr(i) = cores(k).stall_pc else '0';
            bp_matches(k)(i) <= '1' when bp_en(i) = '1' and
               (bp_both(i) = '1' or bp_core(i) = core_bit(k)) and
               cores(k).ce = '1' and cores(k).decode_load = '1' and
               ((cores(k).execute_stall = '0' and fetch_match = '1') or
                (cores(k).execute_stall = '1' and stall_match = '1')) else '0';
         end generate;

         watchpoints : for i in 0 to WP_COUNT - 1 generate
            wp_matches(k)(i) <= '1' when wp_en(i) = '1' and
               (wp_both(i) = '1' or wp_core(i) = core_bit(k)) and cores(k).ce = '1' and
               cores(k).bus_ena = '1' and cores(k).bus_code = '0' and
               wp_addr(i) = unsigned(cores(k).bus_adr(31 downto 2)) and
               ((cores(k).bus_rnw = '1' and wp_rd(i) = '1') or
                (cores(k).bus_rnw = '0' and wp_wr(i) = '1')) else '0';
         end generate;
      end generate;
      absent : if k = 1 and DUAL_CORE /= '1' generate
         bp_matches(k) <= (others => '0');
         wp_matches(k) <= (others => '0');
      end generate;
   end generate;

   process (all)
      variable reason : std_logic_vector(3 downto 0);
      variable core   : tcore_id;
      variable slot   : std_logic_vector(3 downto 0);
      variable events : std_logic_vector(5 downto 0);
   begin
      reason := STOP_NONE;
      core   := active_core;
      slot   := (others => '0');
      dbg_stop_now <= '0';
      if gdb_enable = '1' and reset = '0' and reset_left = 0 and halted = '0' then
         if state = DISPATCH and cmd_op = CMD_HALT then
            reason := STOP_HOST;
            dbg_stop_now <= '1';
         elsif state = DISPATCH and cmd_op = CMD_RESET then
            dbg_stop_now <= '1';
         else
            case run_mode is
               when RUN_INSNS =>
                  if selected.ce = '1' and
                     (selected.cpu_halt = '1' or
                      (selected.decode_load = '1' and
                       (step_rem = 0 or (step_rem = 1 and selected.cpu_done = '1')))) then
                     reason := STOP_STEP;
                  end if;
               when RUN_CYCLES =>
                  if c0_ce = '1' and step_rem = 1 then reason := STOP_STEP_CYCLE; end if;
               when RUN_FRAMES =>
                  if selected.ce = '1' and selected.vblank = '1' and step_rem = 1 then
                     reason := STOP_STEP_FRAME;
                  end if;
               when RUN_LINE =>
                  if selected.ce = '1' and selected.dispstat(23 downto 16) = target_line and
                     ((line_at_hblank = '1' and selected.hblank = '1') or
                      (line_at_hblank = '0' and (selected.line_trigger = '1' or selected.vblank = '1'))) then
                     reason := STOP_STEP_LINE;
                  end if;
               when RUN_NORMAL => null;
            end case;

            if reason = STOP_NONE and cycle_due = '1' then reason := STOP_BREAK_CYCLE; end if;
            if reason = STOP_NONE then
               events(0) := selected.cpu_irq and not event_prev(active_core)(6);
               events(1) := selected.irq_if(7) and not event_prev(active_core)(5);
               events(2) := selected.dma_on and not event_prev(active_core)(4);
               if selected.link_state(3 downto 0) /= event_prev(active_core)(3 downto 0) then
                  events(3) := '1';
               else
                  events(3) := '0';
               end if;
               events(4) := selected.vblank;
               events(5) := selected.hblank;
               if (events and event_mask) /= "000000" then reason := STOP_BREAK_EVENT; end if;
            end if;

            if reason /= STOP_NONE or
               bp_matches(0) /= (0 to BP_COUNT - 1 => '0') or
               bp_matches(1) /= (0 to BP_COUNT - 1 => '0') or
               wp_matches(0) /= (0 to WP_COUNT - 1 => '0') or
               wp_matches(1) /= (0 to WP_COUNT - 1 => '0') then
               dbg_stop_now <= '1';
            end if;

            for k in tcore_id loop
               for i in bp_matches(k)'range loop
                  if reason = STOP_NONE and bp_matches(k)(i) = '1' then
                     reason := STOP_BP;
                     core   := k;
                     slot   := std_logic_vector(to_unsigned(i, 4));
                  end if;
               end loop;
            end loop;

            for k in tcore_id loop
               for i in wp_matches(k)'range loop
                  if reason = STOP_NONE and wp_matches(k)(i) = '1' then
                     reason := STOP_WP;
                     core   := k;
                     slot   := std_logic_vector(to_unsigned(i, 4));
                  end if;
               end loop;
            end loop;
         end if;
      end if;
      match_reason <= reason;
      match_core   <= core;
      match_slot   <= slot;
   end process;

   trace_delta_next <= trace_delta + 1 when c0_ce = '1' and trace_delta /= 255 else trace_delta;
   -- c_arch_pc changes on the Decode load edge. Use that new tag on the
   -- following edge even if the new instruction already retires by then.
   trace_pc <= selected.arch_pc when decode_pending(active_core) = '1' else decoded_pc(active_core);
   trace_write <= '1' when gdb_enable = '1' and reset = '0' and reset_left = 0 and
                          selected.ce = '1' and selected.cpu_done = '1' else '0';

   -- Trace reads are consumed only while halted, so concurrent write data is irrelevant.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         trace_rd_data <= trace_ring(to_integer(trace_rd_ptr));
         if trace_write = '1' then
            trace_ring(to_integer(trace_wr_ptr)) <= selected.irq_if & selected.dispstat(23 downto 16) &
               std_logic_vector(trace_delta_next) & std_logic_vector(trace_pc);
         end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if reset = '1' or reset_left /= 0 then
            total_cycles <= (others => '0');
            total_insns  <= (others => (others => '0'));
            total_frames <= (others => '0');
            decoded_pc   <= (others => (others => '0'));
            decode_pending <= (others => '0');
            event_prev   <= (others => (others => '0'));
         else
            if c0_ce = '1' then
               total_cycles <= total_cycles + 1;
               if c0_vblank = '1' then total_frames <= total_frames + 1; end if;
            end if;
            for k in tcore_id loop
               if k = 0 or DUAL_CORE = '1' then
                  event_prev(k) <= cores(k).cpu_irq & cores(k).irq_if(7) &
                                   cores(k).dma_on & cores(k).link_state(3 downto 0);
                  if cores(k).ce = '1' and cores(k).cpu_done = '1' then
                     total_insns(k) <= total_insns(k) + 1;
                  end if;
                  decode_pending(k) <= cores(k).ce and cores(k).decode_load;
                  if decode_pending(k) = '1' then decoded_pc(k) <= cores(k).arch_pc; end if;
               end if;
            end loop;
         end if;

         if reset = '1' or reset_left /= 0 or gdb_enable = '0' then
            trace_wr_ptr <= (others => '0');
            trace_count  <= (others => '0');
            trace_delta  <= (others => '0');
         elsif trace_write = '1' then
            trace_wr_ptr <= trace_wr_ptr + 1;
            if trace_count < TRACE_ENTRIES then trace_count <= trace_count + 1; end if;
            trace_delta  <= (others => '0');
         else
            trace_delta  <= trace_delta_next;
         end if;
      end if;
   end process;

   ss_bus_out.acc  <= ACCESS_32BIT;
   ss_bus_out.bEna <= x"F";
   ss_bus_out.rst  <= '0';
   ss_bus_out.rnw  <= '1';
   ss_bus_out.Din  <= (others => '0');

   process (clk1x)
      variable nbytes : integer range 0 to 4;
      variable slot : integer range 0 to 15;
      variable read_word : std_logic_vector(31 downto 0);

      procedure read_qword(offset : natural) is
      begin
         ddr3_request <= '1';
         ddr3_rnw     <= '1';
         ddr3_address <= qw_of(MAILBOX_ADDR + offset);
      end procedure;

      procedure write_qword(offset : natural; data : tqword) is
      begin
         ddr3_request   <= '1';
         ddr3_rnw       <= '0';
         ddr3_address   <= qw_of(MAILBOX_ADDR + offset);
         ddr3_writeMask <= x"FF";
         ddr3_dataWrite <= data;
      end procedure;

      procedure run(mode : trun_mode) is
      begin
         run_mode    <= mode;
         halted      <= '0';
         stop_reason <= STOP_NONE;
         stop_pc     <= (others => '0');
         stop_slot   <= (others => '0');
         stop_core   <= 0;
         wp_hit_addr <= (others => '0');
         state_dirty <= '1';
      end procedure;

   begin
      if rising_edge(clk1x) then
         -- DDR3Mux latches a single-cycle request, including when busy.
         ddr3_request    <= '0';
         GBA_Bus_written <= '0';
         ss_bus_out.ena  <= '0';
         dbg_reg_wr      <= '0';
         dbg_step        <= '0';

         -- The mux does not reset with the GBA. An older transaction must
         -- drain before INIT_SYNC can associate a response with OFF_CMD.
         if ddr3_request = '1' then ddr3_inflight <= '1';
         elsif ddr3_done = '1' then ddr3_inflight <= '0'; end if;

         if reset = '1' or gdb_enable = '0' then
            state         <= INIT_SYNC;
            polldiv       <= 0;
            ack_pending   <= '0';
            state_dirty   <= '0';
            stop_pending  <= '0';
            stop_reason   <= STOP_NONE;
            stop_slot     <= (others => '0');
            stop_core     <= 0;
            stop_pc       <= (others => '0');
            wp_hit_addr   <= (others => '0');
            halted        <= '0';
            run_mode      <= RUN_NORMAL;
            step_rem      <= (others => '0');
            reset_left    <= 0;
            active_core   <= 0;
            joy_mask      <= (others => (others => '0'));
            joy_val       <= (others => (others => '0'));
            bp_en         <= (others => '0');
            wp_en         <= (others => '0');
            cycle_bp_en   <= '0';
            event_mask    <= (others => '0');
            ss_bus_req    <= '0';
            gdb_memaccess <= '0';
         else
            if cycle_due = '1' then cycle_bp_en <= '0'; end if;
            if halted = '0' and step_rem /= 0 then
               if (run_mode = RUN_CYCLES and c0_ce = '1') or
                  (run_mode = RUN_INSNS and selected.ce = '1' and selected.cpu_done = '1') or
                  (run_mode = RUN_FRAMES and selected.ce = '1' and selected.vblank = '1') then
                  step_rem <= step_rem - 1;
               end if;
            end if;

            case state is
               when INIT_SYNC =>
                  if ddr3_inflight = '0' then
                     read_qword(OFF_CMD);
                     state <= INIT_WAIT;
                  end if;

               when INIT_WAIT =>
                  if ddr3_done = '1' then
                     last_seq    <= ddr3_dataRead(15 downto 8);
                     cmd_seq     <= ddr3_dataRead(15 downto 8);
                     status      <= STATUS_OK;
                     ack_pending <= '1';
                     state_dirty <= '1';
                     state       <= IDLE;
                  end if;

               when IDLE =>
                  if stop_pending = '1' then
                     null; -- wait for the post-edge architectural PC
                  elsif state_dirty = '1' then
                     -- Commit cycle count before publishing the state word.
                     state_publish <= state_word;
                     write_qword(OFF_CYCLES, std_logic_vector(total_cycles));
                     state_dirty <= '0';
                     state <= PUB_CYCLES_WAIT;
                  elsif ack_pending = '1' then
                     write_qword(OFF_ACK, MAGIC & PROTO_VER & status & cmd_seq);
                     last_seq    <= cmd_seq;
                     ack_pending <= '0';
                     state       <= ACK_WAIT;
                  elsif polldiv /= 0 then
                     polldiv <= polldiv - 1;
                  else
                     if halted = '1' then polldiv <= POLL_DIV_HALT - 1;
                     else                 polldiv <= POLL_DIV_RUN - 1; end if;
                     read_qword(OFF_CMD);
                     state <= POLL_WAIT;
                  end if;

               when POLL_WAIT =>
                  if ddr3_done = '1' then
                     if ddr3_dataRead(15 downto 8) /= last_seq then
                        cmd_op  <= ddr3_dataRead(7 downto 0);
                        cmd_seq <= ddr3_dataRead(15 downto 8);
                        cmd_arg <= ddr3_dataRead(63 downto 32);
                        status  <= STATUS_OK;
                        case ddr3_dataRead(7 downto 0) is
                           when CMD_RDMEM | CMD_WRMEM | CMD_WRREG | CMD_SETBP | CMD_SETWP | CMD_BREAK_CYCLE =>
                              read_qword(OFF_ADDR);
                              state <= FETCH_ADDR_WAIT;
                           when others =>
                              state <= DISPATCH;
                        end case;
                     else
                        state <= IDLE;
                     end if;
                  end if;

               when FETCH_ADDR_WAIT =>
                  if ddr3_done = '1' then
                     req_addr <= unsigned(ddr3_dataRead);
                     if cmd_op = CMD_RDMEM or cmd_op = CMD_WRMEM then
                        read_qword(OFF_LEN);
                        state <= FETCH_LEN_WAIT;
                     else
                        state <= DISPATCH;
                     end if;
                  end if;

               when FETCH_LEN_WAIT =>
                  if ddr3_done = '1' then
                     req_len <= unsigned(ddr3_dataRead(req_len'range));
                     if unsigned(ddr3_dataRead) <= DATA_MAX then req_len_valid <= '1';
                     else                                       req_len_valid <= '0'; end if;
                     state   <= DISPATCH;
                  end if;

               when DISPATCH =>
                  state <= COMPLETE;
                  data_off <= (others => '0');
                  qw_half  <= '0';
                  qw_buf   <= (others => '0');
                  reg_idx  <= 0;
                  case cmd_op is
                     when CMD_NOP | CMD_HALT =>
                        null;
                     when CMD_CONT =>
                        run(RUN_NORMAL);
                     when CMD_STEP =>
                        if unsigned(cmd_arg) = 0 then step_rem <= to_unsigned(1, step_rem'length);
                        else                          step_rem <= unsigned(cmd_arg); end if;
                        run(RUN_INSNS);
                     when CMD_STEP_CYCLES =>
                        if unsigned(cmd_arg) = 0 then
                           status <= STATUS_BADARG;
                        elsif unsigned(cmd_arg) = 1 and halted = '1' then
                           dbg_step <= '1';
                           state <= SINGLE_CYCLE_WAIT;
                        else
                           step_rem <= unsigned(cmd_arg);
                           run(RUN_CYCLES);
                        end if;
                     when CMD_STEP_FRAMES =>
                        if unsigned(cmd_arg) = 0 then
                           status <= STATUS_BADARG;
                        else
                           step_rem <= unsigned(cmd_arg);
                           run(RUN_FRAMES);
                        end if;
                     when CMD_STEP_LINE =>
                        if unsigned(cmd_arg(7 downto 0)) >= 228 then
                           status <= STATUS_BADARG;
                        else
                           target_line    <= cmd_arg(7 downto 0);
                           line_at_hblank <= cmd_arg(8);
                           run(RUN_LINE);
                        end if;
                     when CMD_BREAK_CYCLE =>
                        if req_addr = 0 then
                           cycle_bp_en <= '0';
                        elsif req_addr <= total_cycles or
                              (c0_ce = '1' and req_addr - 1 = total_cycles) then
                           status <= STATUS_BADARG;
                        else
                           cycle_bp_before <= req_addr - 1;
                           cycle_bp_en <= '1';
                        end if;
                     when CMD_BREAK_EVENT =>
                        event_mask <= cmd_arg(5 downto 0);
                     when CMD_SET_CORE =>
                        if unsigned(cmd_arg) = 0 or (DUAL_CORE = '1' and unsigned(cmd_arg) = 1) then
                           active_core <= to_integer(unsigned(cmd_arg(0 downto 0)));
                           state_dirty <= '1';
                        else
                           status <= STATUS_BADARG;
                        end if;
                     when CMD_SET_INPUT =>
                        joy_val(active_core)  <= cmd_arg(9 downto 0);
                        joy_mask(active_core) <= cmd_arg(25 downto 16);
                     when CMD_RESET =>
                        reset_left <= 16;
                        run_mode   <= RUN_NORMAL;
                        halted     <= cmd_arg(0);
                        state      <= RESET_WAIT;
                     when CMD_RDMEM | CMD_WRMEM =>
                        if req_len_valid = '0' or req_addr(63 downto 28) /= 0 or
                           req_addr(1 downto 0) /= "00" or
                           resize(req_addr(27 downto 0), 29) + resize(req_len, 29) > 2**28 then
                           status <= STATUS_BADARG;
                        elsif req_len /= 0 then
                           if halted = '0' then
                              status <= STATUS_BUSY;
                           else
                              cur_addr   <= req_addr(27 downto 0);
                              bytes_left <= req_len;
                              state      <= MEM_READY;
                           end if;
                        end if;
                     when CMD_RDREGS =>
                        if HAS_DIRECT_REGRD = '0' then ss_bus_req <= '1'; end if;
                        state <= SS_READ;
                     when CMD_WRREG =>
                        if req_addr > 17 then
                           status <= STATUS_BADARG;
                        elsif halted = '0' then
                           status <= STATUS_BUSY;
                        else
                           dbg_reg_wr   <= '1';
                           dbg_reg_idx  <= std_logic_vector(req_addr(4 downto 0));
                           dbg_reg_data <= cmd_arg;
                        end if;
                     when CMD_SETBP =>
                        slot := to_integer(unsigned(cmd_arg(3 downto 0)));
                        if slot >= BP_COUNT or req_addr(63 downto 32) /= 0 or
                           (DUAL_CORE = '0' and cmd_arg(5) = '1' and cmd_arg(6) = '0') then
                           status <= STATUS_BADARG;
                        else
                           bp_addr(slot) <= req_addr(31 downto 0);
                           bp_en(slot)   <= cmd_arg(4);
                           bp_core(slot) <= cmd_arg(5);
                           bp_both(slot) <= cmd_arg(6);
                        end if;
                     when CMD_SETWP =>
                        slot := to_integer(unsigned(cmd_arg(3 downto 0)));
                        if slot >= WP_COUNT or req_addr(63 downto 32) /= 0 or
                           (DUAL_CORE = '0' and cmd_arg(7) = '1' and cmd_arg(8) = '0') then
                           status <= STATUS_BADARG;
                        else
                           wp_addr(slot) <= req_addr(31 downto 2);
                           wp_en(slot)   <= cmd_arg(4);
                           wp_rd(slot)   <= cmd_arg(5);
                           wp_wr(slot)   <= cmd_arg(6);
                           wp_core(slot) <= cmd_arg(7);
                           wp_both(slot) <= cmd_arg(8);
                        end if;
                     when CMD_RDSTATE =>
                        telemetry_idx <= 0;
                        state <= TELEMETRY_STORE;
                     when CMD_RD_TRACE =>
                        if halted = '0' then
                           status <= STATUS_BUSY;
                        else
                           trace_idx    <= 0;
                           trace_rd_ptr <= trace_wr_ptr - trace_count(5 downto 0);
                           state        <= TRACE_HEAD;
                        end if;
                     when others =>
                        status <= STATUS_BADCMD;
                  end case;

               when SINGLE_CYCLE_WAIT =>
                  -- dbg_hold never dropped: the pause FF admits only the
                  -- single edge injected by dbg_step.
                  if c0_ce = '1' then
                     stop_reason  <= STOP_STEP_CYCLE;
                     stop_core    <= active_core;
                     stop_slot    <= (others => '0');
                     wp_hit_addr  <= (others => '0');
                     stop_pending <= '1';
                     state        <= COMPLETE;
                  end if;

               when RESET_WAIT =>
                  reset_left <= reset_left - 1;
                  if reset_left = 1 then
                     if cmd_arg(0) = '1' then
                        halted       <= '1';
                        stop_reason  <= STOP_RESET_HALT;
                        stop_core    <= active_core;
                        stop_slot    <= (others => '0');
                        wp_hit_addr  <= (others => '0');
                        stop_pending <= '1';
                     else
                        run(RUN_NORMAL);
                     end if;
                     state <= COMPLETE;
                  end if;

               when MEM_READY =>
                  if mem_dbg_ready = '1' then
                     -- Allow a full entry clock for the mux to save the
                     -- suspended bus state before it sees the first pulse.
                     gdb_memaccess <= '1';
                     if cmd_op = CMD_RDMEM then state <= MEMRD_BUS;
                     else                       state <= MEMWR_LOAD; end if;
                  end if;

               ------------------------------------------------------
               -- memory read: 32bit bus reads packed 2 per DDR3 qword
               ------------------------------------------------------
               when MEMRD_BUS =>
                  if (bytes_left = 0) then
                     if (qw_half = '1') then
                        state <= MEMRD_STORE;  -- flush the odd trailing word
                     else
                        state <= COMPLETE;
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
                     if (bytes_left = 0) then state <= COMPLETE;
                     else                     state <= MEMRD_BUS; end if;
                  end if;

               ------------------------------------------------------
               -- memory write: one qword of payload at a time, each word
               -- written whole, or read-modify-written when partial
               ------------------------------------------------------
               when MEMWR_LOAD =>
                  if (bytes_left = 0) then
                     state <= COMPLETE;
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

               when SS_READ =>
                  if HAS_DIRECT_REGRD = '1' and cmd_op = CMD_RDREGS then
                     dbg_reg_rd_idx <= std_logic_vector(to_unsigned(reg_idx, dbg_reg_rd_idx'length));
                     state <= SS_WAIT;
                  elsif cmd_op = CMD_RDREGS and reg_idx = 15 then
                     qw_buf(63 downto 32) <= std_logic_vector(selected.arch_pc);
                     reg_idx <= reg_idx + 1;
                     state   <= SS_STORE;
                  else
                     if cmd_op = CMD_RDREGS then
                        ss_bus_out.adr <= std_logic_vector(to_unsigned(1 + reg_idx, proc_busadr));
                     else
                        ss_bus_out.adr <= std_logic_vector(to_unsigned(reg_idx, proc_busadr));
                     end if;
                     ss_bus_out.ena <= '1';
                     state <= SS_WAIT;
                  end if;

               when SS_WAIT =>
                  if (HAS_DIRECT_REGRD = '1' and cmd_op = CMD_RDREGS) or ss_wired_done = '1' then
                     if HAS_DIRECT_REGRD = '1' and cmd_op = CMD_RDREGS then
                        read_word := dbg_reg_rd_data;
                     else
                        read_word := ss_wired_out;
                     end if;
                     reg_idx <= reg_idx + 1;
                     if reg_idx mod 2 = 0 then
                        qw_buf(31 downto 0) <= read_word;
                        if cmd_op = CMD_RDREGS and reg_idx = NUM_REGS - 1 then
                           state <= SS_STORE;
                        else
                           state <= SS_READ;
                        end if;
                     else
                        qw_buf(63 downto 32) <= read_word;
                        state <= SS_STORE;
                     end if;
                  end if;

               when SS_STORE =>
                  write_qword(OFF_DATA + to_integer(data_off), qw_buf);
                  state <= SS_STORE_WAIT;

               when SS_STORE_WAIT =>
                  if ddr3_done = '1' then
                     data_off <= data_off + 8;
                     qw_buf   <= (others => '0');
                     if cmd_op = CMD_RDSTATE and reg_idx = SS_WORDS then
                        state_dirty <= '1';
                        state <= COMPLETE;
                     elsif cmd_op = CMD_RDREGS and reg_idx = NUM_REGS then
                        state <= COMPLETE;
                     else
                        state <= SS_READ;
                     end if;
                  end if;

               when TELEMETRY_STORE =>
                  write_qword(OFF_DATA + to_integer(data_off), telemetry(telemetry_idx));
                  state <= TELEMETRY_WAIT;

               when TELEMETRY_WAIT =>
                  if ddr3_done = '1' then
                     data_off <= data_off + 8;
                     if telemetry_idx = telemetry'high then
                        ss_bus_req <= '1';
                        state <= SS_READ;
                     else
                        telemetry_idx <= telemetry_idx + 1;
                        state <= TELEMETRY_STORE;
                     end if;
                  end if;

               when TRACE_HEAD =>
                  write_qword(OFF_DATA, (63 downto 14 => '0') & std_logic_vector(trace_wr_ptr) &
                                       '0' & std_logic_vector(trace_count));
                  state <= TRACE_HEAD_WAIT;

               when TRACE_HEAD_WAIT =>
                  if ddr3_done = '1' then state <= TRACE_RD_FETCH; end if;

               when TRACE_RD_FETCH =>
                  state <= TRACE_RD_STORE;

               when TRACE_RD_STORE =>
                  if trace_idx < to_integer(trace_count) then
                     write_qword(OFF_DATA + 8 * (1 + trace_idx), trace_rd_data);
                  else
                     write_qword(OFF_DATA + 8 * (1 + trace_idx), (others => '0'));
                  end if;
                  trace_rd_ptr <= trace_rd_ptr + 1;
                  state <= TRACE_STORE_WAIT;

               when TRACE_STORE_WAIT =>
                  if ddr3_done = '1' then
                     if trace_idx = TRACE_ENTRIES - 1 then
                        state <= COMPLETE;
                     else
                        trace_idx <= trace_idx + 1;
                        state <= TRACE_RD_FETCH;
                     end if;
                  end if;

               when COMPLETE =>
                  ss_bus_req    <= '0';
                  gdb_memaccess <= '0';
                  ack_pending   <= '1';
                  state         <= IDLE;

               when PUB_CYCLES_WAIT =>
                  if ddr3_done = '1' then
                     write_qword(OFF_STATE, state_publish);
                     state <= PUB_STATE_WAIT;
                  end if;

               when PUB_STATE_WAIT | ACK_WAIT =>
                  if ddr3_done = '1' then state <= IDLE; end if;
            end case;

            if stop_pending = '1' then
               stop_pc      <= cores(stop_core).arch_pc;
               stop_pending <= '0';
               state_dirty  <= '1';
               polldiv      <= 0;
            end if;

            if match_reason /= STOP_NONE then
               halted       <= '1';
               run_mode     <= RUN_NORMAL;
               stop_reason  <= match_reason;
               stop_slot    <= match_slot;
               stop_core    <= match_core;
               stop_pending <= '1';
               if match_reason = STOP_WP then wp_hit_addr <= cores(match_core).bus_adr;
               else                           wp_hit_addr <= (others => '0'); end if;
            end if;
         end if;
      end if;
   end process;

end architecture;
