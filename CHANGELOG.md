# Changelog

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
- **SD low outside multiplayer mode** (manual p.108/111/113): the real
  "this unit is not in multiplayer mode yet" announcement, which is what
  the other side's allReady/SD-status checks actually gate on. Replaces
  the reversed sd_ready_pulse/sd_wait_rendezvous experiments.

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

Untested against a real dongle so far.

### Wireless Adapter emulation (new: Multiplayer = "Wireless Adapter")

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
