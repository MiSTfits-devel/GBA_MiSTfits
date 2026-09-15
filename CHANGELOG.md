# Changelog

## 2026-09-15

### Saves on a physical Game Pak

- **Fixed: no EEPROM game could save.** The first cut raised `/CS` at the end
  of every cartridge write. EEPROM is a serial device on the ROM bus that
  counts bits and needs its whole command - 9 bits for a read request, 73 for
  a write - inside a single `/CS` assertion, so every command reached the
  cartridge as a string of aborted 1-bit commands. Writes now burst the way
  reads already did: `/CS` stays low across a sequential run and only goes
  high for a non-sequential access or a `/CS2` one, which is what a real AGB
  does when DMA3 walks up `0x0DFFFF00`. This is what a tester was seeing as
  "ROM boots but saves don't work" on *Phantasy Star Collection* (`AGB-AYCP`),
  whose board carries a ROHM 9854 64 Kbit EEPROM; SRAM and FLASH carts were
  not affected.
- `sim/tb_cart_phys.vhd` grew the two save devices it was missing: an EEPROM
  that aborts a command when `/CS` rises part way through, exactly like the
  chip, and counts those aborts; and a FLASH chip with the 5555/2AAA/5555
  unlock, the autoselect ID a save library reads before it will save at all,
  and byte program. The EEPROM model is parameterised by address width and is
  exercised at both of them - the 6-bit/4 Kbit part and the 14-bit/64 Kbit
  part that the reporting cartridge carries. The EEPROM test fails the old
  design 73 times over.
- `/CS2` accesses no longer follow the Fast/Normal/Safe ladder. Every preset
  now holds `/RD` or `/WR` low for at least 400 ns, which is what FlashGBX's
  LK firmware uses against real cartridges and explicitly attributes to FRAM -
  the save chip in many repro carts and battery-free replacements. Saves are a
  few thousand bytes now and then, so the time is not felt; a chip that
  answers late corrupts a save silently.
- The pin map is now cross-checked against Heber's published expansion-header
  pinout rather than only traced from the adapter netlist, which confirms
  `USER_IO[6]` = DIR1, `USER_IO[5]` = DIR2 and `USER_IO[4]` = cartridge pin 30.
  `docs/mms2_cart.md` records why that netlist calls pin 30 `~{MCLR}`: it is
  the Game Boy `/RESET` pin, and on a GBA Game Pak the same pin is `/CS2`.
  Nothing about a reset line is missing - there isn't one on a GBA cartridge.

### Physical GBA cartridges on the Multisystem2 (`GBA_MMS2` revision)

- New Quartus revision `GBA_MMS2` plays a **real Game Pak** plugged into the
  Heber GB/GBC/GBA cartridge adapter. No dumping: the emulated CPU's whole
  cartridge window (0x8..0xF) is wired to the connector, so the cartridge's
  ROM, its SRAM/FLASH saves, its EEPROM and its GPIO devices (RTC, solar,
  gyro, rumble) are the real thing rather than emulations of one.
- The adapter has had GBA support in hardware all along and was waiting on an
  accuracy-grade core: the Game Pak bus is specified in 16.777216 MHz cycles,
  and only now does the core run at literally that rate. `clk6x` (exactly 6x)
  sequences the bus, putting every edge on a ~10 ns grid.
- `rtl/gba_cart_phys.vhd` implements the bus: the `/CS` address latch, the
  cartridge's own 16-bit auto-increment counter (so bursts skip the address
  phase, and restart across the 128 KB wrap where the counter runs out), the
  `/CS2` save window with its data on A16-23, and the `WAITCNT`-driven PHI
  terminal.
- New **Hardware → MMS2 Cartridge** toggle, and a **Cart Bus Timing**
  preset (Normal/Safe/Fast) to trade margin against speed on tired connectors
  and slow repro carts. The emulated wait state runs concurrently with the
  physical access, so an access that fits inside it costs nothing.
- Cartridge reads cost 7 emulated cycles random / 4 burst at Normal, against
  3 and 1 on a real AGB, so ROM-resident code runs slower than hardware (code
  the game copies into IWRAM or EWRAM is untouched). About half of that is the
  clk1x/clk6x handshake rather than the bus - see `docs/mms2_cart.md`.
- Backup-RAM menu entries are hidden while the cartridge is in use - the saves
  live on the cartridge. The SNAC link port is unavailable in cartridge mode,
  which needs two of its pins for the level shifter direction controls.
- `sim/tb_cart_phys.vhd` drives the design against a behavioural Game Pak that
  implements only what GBATEK specifies, and asserts continuously that `/CS`
  and `/CS2` are never both low and that neither end ever drives into the
  other.
- See `docs/mms2_cart.md` for the pin map (traced from the adapter's netlist),
  the bus protocol and the measured timing.
- `MISTER_MMS2` moves 29 FPGA pins to the expansion header, which is correct
  only on a Multisystem2 - hence a separate revision. `GBA`, `GBA2P` and
  `GBA2P_MEMTEST` are unaffected.

## 2026-09-04

### 90 degree video rotation

- New **Video & Audio > Rotate Video** option: *Off*, *90 CW*, *90 CCW*, for
  playing on a physically rotated monitor. 1P scanout becomes 160x240 and
  "Original" aspect becomes 2:3.
- The 2P profile rotates into a **stack**: the 480x160 side-by-side pair
  becomes 160x480 with player 1 above player 2, which is what a quarter turn
  of the side-by-side frame naturally gives and what fills a portrait screen
  best (each player gets 640x960 of a portrait 1080p panel, against 540x810
  if the rotated pair were left side by side). The 2P Separator Line becomes
  a horizontal seam, and the single-player views line double instead of
  pixel doubling. "Original" aspect is 1:3 stacked, 2:3 single player.
- The rotated 2P raster is 399 x 530 pixel clocks against 798 x 265 - the
  same 211470 ticks per frame, halved line length for twice the lines - so
  the frame period, and everything paced off it, is unchanged there too.
- Core 2's frame buffer channel now carries one pixel per entry with byte
  enables when rotated (4x the entries, same bytes) and its FIFO is 512 deep
  instead of 256, for the same reason as core 1's.
- Rotation is applied where GPU pixels enter the DDR3 frame buffers, by
  remapping the (row, column) of each pixel, so it costs no extra frame of
  latency and no extra copy of the frame. The frame buffer's fixed 256 pixel
  row stride means a rotated 240x160 frame still fits the 128k reserved per
  buffer.
- DDR3Mux writes rotated frames one pixel at a time with byte enables: under
  rotation the four pixels of a 64 bit word come from four different GBA
  scanlines, so the usual write combining cannot be used.
- The frame period is unchanged (399 x 265 pixel clocks), so core-to-video
  pacing, pause and rewind behave exactly as before; only the active window
  moves.
- Borders and CRT V-Sync Adjust are hidden and inactive while rotated - the
  border image is a 320x240 landscape frame, and a rotated frame leaves only
  3 blank lines below the image. The 2P profile cannot rotate: it scans out a
  480 wide side-by-side frame.

## 2026-07-11

### Real link timing and physical AGB-015 path

- Multiplayer starts SD with SIOCNT d07 instead of one baud-scaled bit later.
  Missing-unit timeout is now 18 bit periods per transmitted frame plus the
  fixed ~520-clock hardware quiet window at every baud.
- First-frame detection accepts simultaneous SC/SYNC and SD/start assertion;
  synchronizers no longer hide a real transfer's only falling edge.
- Normal internal-clock masters release SD per the AGB manual. This unblocks
  physical AGB-015 reset/login; external-clock receivers still output LO.
- Wireless regression now traverses the exact SNAC USER_IO mapping
  (SC=0, SD=5, SI=2, SO=1), including GPIO reset, 256 kHz login, 2 MHz STWI,
  reversal, notification, and clock handback.
- Link timing regression covers all four multiplayer bauds and 9600-baud 2P.
  Full dual-CPU Afska demo test now has a real pass/fail gate and passes after
  both cores complete three exchanges; simulator stop-time alone is no longer
  considered success.
- OSD names physical mode **SNAC Link Port**. Real cable and real AGB-015 use
  this mode; **Wireless (Emulated)** keeps SNAC released.

## 2026-07-06

### Link engine: roles come from the cable now (like a real GBA)

The `Link Role: Parent/Child` OSD option is gone -- it never existed on
real hardware. The link cable's 1P plug grounds that unit's SI terminal,
and that is the whole master-election mechanism (AGBProgrammingManual
p.113, Figure 101). `gba_serial` now latches its multiplayer role from the
live SI level, exactly like the real SIO unit; the internal 2P cable puts
core 1 in the 1P plug position. Alongside that, the multiplayer engine was
made spec-faithful in the ways that were provably blocking real-GBA
interop:

- **SO daisy chain implemented**: after sending its frame each unit pulls
  SO low -- the next unit's go-ahead to answer -- and releases it when the
  master ends the exchange. This is why a real GBA child never answered a
  MiSTer master before: it was (correctly) waiting for its SI to drop, and
  we never dropped it.
- **Real Multi-Player IDs** (SIOCNT d5:4): assigned by bus position per
  exchange. Both sides used to read back ID 0, so games like Pokemon
  Emerald concluded both units were player 1 and threw "Link error" at
  connection confirm.
- **SIOMULTI0-3 all live**: each slot's frame lands in its own register
  (4-player capable); absent slots keep the FFFF written at exchange
  start. The old hardcoded-FFFF MULTI2/3 readbacks are gone.
- **Slave busy/interrupt semantics per manual**: a slave's d07 is a pure
  busy status (its own start-bit writes are ignored, and can no longer
  corrupt an in-flight reception); busy holds and the IRQ fires when the
  master releases SC -- a level check with a bounded safety timeout, so
  the old waitmasterend-style freeze cannot recur.
- **SD direction follows Normal-mode clock role** (manual p.108/111/113): an
  external-clock receiver outputs LO; an internal-clock sender leaves SD in
  pull-up input status. Multiplayer mode also leaves SD pulled up while idle,
  which is what the other side's allReady/SD-status checks gate on. Forcing
  every Normal-mode unit low prevented a physical AGB-015 from operating.

Sim-proven at two levels: `sim/run_link_tb.sh` (5 unit scenarios incl. the
LinkCable.hpp register choreography, IDs asserted) and the full dual-CPU
`sim/run_gba2p_sdram_tb.sh` linktest2 run (interrupt-driven, Apotris-style
Timer1): both directions carry incrementing counters, core 2 reads back
player ID 1, MULTI2/3 stay FFFF.

### Wireless Adapter groundwork

An AGB-015 Wireless Adapter is a real device that speaks Normal mode with
the GBA as master, so most of what it needs is correctness we now have:

- **RCNT general-purpose (GPIO) mode drives the pins**: the adapter's
  reset ping (SD/SO as outputs, SD pulsed high) used to be silently
  ignored -- the adapter never even reset. Input-direction pins read back
  live levels.
- **SIOCNT d02 reads the live SI terminal in Normal mode** (manual p.111):
  the adapter-ready line every RFU driver polls.
- **SO shows d03 between Normal-mode transfers for the master too**: the
  login sequence wiggles it as a handshake.

For a physical dongle choose **Multiplayer → SNAC Link Port**. The separate
**Wireless (Emulated)** option routes the core to its internal adapter model
and releases SNAC pins. Hardware validation against a real dongle remains.

### Wireless Adapter emulation (Multiplayer = "Wireless (Emulated)")

A full AGB-015 transport now lives in the core (`rtl/gba_wireless.vhd`,
protocol spec in `docs/agb015_protocol.md`, derived from LinkRawWireless,
pret's librfu, and Nintendo's AGB Wireless Controller manual Appendix B):
GPIO ping detection, the 10-word "NINTENDO" keystream login, 0x9966 STWI
command framing with the per-word SO/SI handshake, the clock-reversal
phase where the adapter masters the bus to inject 0x27/0x28/0x29 events,
and the 100 ms word watchdog. Command *semantics* live on the ARM side:
packets cross the framework UART (the MidiLink pattern) to
`support/rfu_daemon/`, which implements the RFU state machine -- the same
transport/logic split RetroArch's gpSP uses, so its RFU1 room protocol
(over RetroArch netpacket sessions) is the intended network backend.
Unit-proven end to end in `sim/run_wireless_tb.sh` with a real gba_serial
driven exactly like an RFU driver drives the GBA: login, Hello,
SystemStatus payload, wait -> reversal -> adapter-initiated notify ->
clock handback. Networking hooks in the daemon are stubs so far: games
can boot wireless menus, host, and scan an empty airspace; joining
gpSP/RetroArch rooms is the next milestone.

The bench also flushed out a latent gba_serial bug affecting any real
dongle: Normal-32 receive updated SIODATA32 but not SIOMULTI1 (the same
architectural register), so the wired-or readback returned stale bits on
every 32-bit read. Fixed in both master and slave paths.

## 2026-07-05/06

### Split 2P core sides (GBA2P build)

Loading a ROM used to always boot both cores simultaneously with the
identical image, which broke games that need the second side inactive at
boot (e.g. Kirby and the Amazing Mirror). Both sides can now be loaded,
powered, and reset independently:

- **`Load Target` selector** (`1P` / `2P` / `1P+2P`): picks which side the
  next Load goes to. `1P+2P` is the default and matches the old behavior
  exactly (single copy, both sides share it). `1P` leaves the other side
  completely untouched. `2P` writes into its own independent 32MB ROM
  window and un-shares it from core 1.
- **`Player 1/2 Power`**: independently power either side off.
- **`Reset Player 1/2`**: independently reset either side.
- A side with nothing ever loaded into it boots cartless, which is exactly
  the state needed for GBA multiboot testing over the link cable.

### Rewind Capture restored

The rewind capture/playback engine was fully intact in the RTL but
disconnected at the top level during an earlier rewrite. Reconnected:
`Rewind Capture` OSD toggle, a dedicated Rewind controller button, and the
pause-suppression that lets capture keep running while the OSD is open.

### Fast Forward / Turbo restored

Same situation as Rewind — restored the tap-to-latch/hold-to-boost
FastForward button, the `Turbo` OSD toggle, and the `Fast Forward Sound`
toggle.

### GBA Video ("Matrix" mapper) cart support (1P build only)

Adds support for >32MB GBA Video cartridges (Shrek, Shrek 2, Shark Tale,
and the Shrek+Shark Tale combo disc are the only ones in circulation that
actually exceed the normal 32MB cart size). Two parts:

- Linear addressing up to 64MB, by repurposing what's normally a redundant
  wait-state-mirror address bit as a real extra address bit — exactly what
  the real hardware does.
- The mapper's own 8KB bank-switch window at the start of cart space,
  ported register-for-register from mGBA's reference implementation.

Detection is automatic (file size and a header byte), no OSD option needed.
1P-only — the 2P build is untouched by this feature.

### Known limitations / follow-ups

- **TATE mode** (rotate video output for a sideways monitor): scoped but not
  implemented. Doing this properly requires switching to MiSTer's
  framebuffer-mode output path (this core's current line-buffered video
  pipeline can't cheaply support arbitrary rotation), which is a real
  architecture change, not a quick option add.
- **Multiboot file support** (loading `.gba` files built to run from EWRAM
  instead of cartridge space): detection is straightforward, but actually
  booting one requires new CPU-boot-vector-injection or EWRAM-preload
  hardware that doesn't exist yet. Not implemented this round.
- SDRAM requirement: normal play fits in 64MB. Using `Load Target: 2P` in
  the 2P build, or loading a 64MB GBA Video cart in the 1P build, needs a
  128MB SDRAM module (peaks at ~65MB and ~96MB respectively).
