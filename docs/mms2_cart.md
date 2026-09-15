# Physical GBA cartridges on the Heber Multisystem2

The `GBA_MMS2` Quartus revision plays a **real Game Pak** plugged into the
[Heber GB/GBC/GBA cartridge adapter](https://github.com/Heber-co-uk/MMS2-Gameboy-Cart-Adapter)
for the Multisystem2. There is no dumping step: the emulated CPU's cartridge
window is wired straight through to the connector, so the cartridge's ROM, its
SRAM/FLASH saves, its EEPROM and its GPIO devices (RTC, solar, gyro, rumble)
are all the genuine article rather than emulations of one.

The adapter has had GBA support in hardware since day one; its readme says so
and says why it was never used:

> Hardware support for GBA cartridges but not currently supported by core. We
> will wait until Robert finishes the 'Accuracy' version of his GBA core as the
> current core does not closely resemble the real hardware

That is the missing piece this revision supplies. The Game Pak bus is specified
in cycles of the 16.777216 MHz system clock, and this core runs the whole design
at literally that rate, so those cycles are real. `clk6x` (100.663296 MHz,
exactly 6x) sequences the bus, which puts every edge on a ~10 ns grid.

## Using it

1. Flash `GBA_MMS2.rbf`. **Do not** use it on anything but a Multisystem2 —
   see [Why a separate revision](#why-a-separate-revision).
2. Hold the yellow front button, insert the cartridge, release it. While the
   button is held the shifters are off and the cartridge is unpowered, so
   swapping is safe.
3. OSD → **Hardware → MMS2 Cartridge → On**. Toggling it resets the core.
4. If the game does not boot, try **Hardware → Cart Bus Timing → Safe** and
   reseat the cartridge.

Saves stay on the cartridge, so the SD-card backup-RAM menu entries are hidden
while the cartridge is in use. Save states are unavailable for the same reason
the Game Boy core cannot offer them with a physical cartridge: the mapper and
save chip state live in silicon this core cannot snapshot.

Cartridge mode claims `USER_IO[4..6]`, two of which are the level-shifter
direction controls, so the **SNAC link port is unavailable while it is on**.

## The bus

From GBATEK's *AUX GBA Game Pak Bus*, cross-checked against Lesserkuma's
FlashGBX LK firmware, which drives the same silicon:

* **ROM.** A 24-bit *halfword* address goes out on AD0-15 + A16-23 and is
  latched in the cartridge on the falling edge of `/CS`. AD0-15 then turns
  around and each `/RD` pulse returns one halfword. The cartridge increments
  its own latched address on every rising `/RD` edge, so a burst needs no
  further address phase — but only A0..A15 are latched, so that counter wraps
  every 64K halfwords (128 KB) and the burst has to restart there. This core
  tracks the wrap and issues a fresh address phase across it, exactly as real
  hardware does.
* **SRAM/FLASH.** A 16-bit address goes out on AD0-15 and is *held* for the
  whole cycle; the eight bits of data travel on **A16-23**, not on AD0-7, and
  `/CS2` selects instead of `/CS`.
* **EEPROM** hangs off `ROMCS`/`RD`/`WR`/`AD0` with `A23` as its select, so
  every bit of it travels as an ordinary ROM-window access — but there is a
  *serial* device on the far end, and it counts. A read request is 9 bits, a
  write is 73, and the whole command has to arrive inside **one** `/CS`
  assertion or the chip discards it. So `/CS` is held low across a sequential
  run of writes exactly as it is across a run of reads, which is also what a
  real AGB does when DMA3 walks up `0x0DFFFF00`.

  This is what was wrong in the first cut of this core, and it is why a
  tester saw ROM boot off a real Game Pak but no save. `/CS` went high after
  every write beat, so a 73-bit EEPROM command reached the cartridge as 73
  aborted 1-bit commands. `sim/tb_cart_phys.vhd` now models an EEPROM that
  aborts on a mid-command `/CS` the way the silicon does, and counts it.
* **PHI** follows `WAITCNT[12:11]` (off / 4.19 / 8.38 / 16.78 MHz) like real
  hardware. It is off at boot, which is where nearly every game leaves it.

`/CS` and `/CS2` are never asserted together, and the FPGA's tristates track
the shifter direction exactly, so neither end ever drives into the other.
`sim/tb_cart_phys.vhd` asserts all three of those continuously.

## Pin map

Traced from the adapter's own KiCad netlist (board 23467) and cross-checked
against Heber's published expansion-header pinout
(`expansion-header.png` in [Template_MiSTer_Multisystem2](https://github.com/Heber-co-uk/Template_MiSTer_Multisystem2)),
which names every header pin. Every `MMS_BUS` pin is a stock DE10-Nano
function that the Multisystem2 routes to its expansion header instead.

| Cart pin | Signal | MMS_BUS | Stock function | Shifter / direction |
|---|---|---|---|---|
| 6-13   | AD0-AD7   | `[7:0]`   | SD_SPI_MISO/CLK/MOSI, IO_SCL, IO_SDA, SDRAM_CKE, SDRAM_DQMH, SDRAM_DQML | U3, DIR1 |
| 14-21  | AD8-AD15  | `[19:12]` | LED[0..7]      | U4, DIR1 |
| 22-23  | A16-A17   | `[21:20]` | KEY[0], KEY[1] | U5, DIR2 |
| 24-29  | A18-A23   | `[28:23]` | SDIO_DAT/CMD/CLK | U5, DIR2 |
| 2      | PHI       | `[8]`     | ADC_CONVST     | U2, fixed out |
| 3      | /WR       | `[9]`     | ADC_SDO        | U2, fixed out |
| 4      | /RD       | `[10]`    | ADC_SCK        | U2, fixed out |
| 5      | /CS       | `[11]`    | ADC_SDI        | U2, fixed out |
| —      | shifter `/OE` | `[22]` | SDCD_SPDIF    | also gates cartridge power via D4/Q5 |
| 30     | /CS2      | `USER_IO[4]` | — | open drain via a BSS138, 10k pull-up to VCART |
| —      | DIR2 (A16-23) | `USER_IO[5]` | — | 1 = FPGA drives |
| —      | DIR1 (AD0-15) | `USER_IO[6]` | — | 1 = FPGA drives |

**The netlist calls cartridge pin 30 `~{MCLR}`, and that is a trap.** The
adapter was built for the Game Boy core, where pin 30 is the cartridge
`/RESET`; on a GBA Game Pak the very same pin is `/CS2`, the select for the
SRAM and FLASH save chips. Heber's Game Boy core drives it as a reset pulse
(`USER_DIR[4] = real_cart & reset_to_cart_extended`), this core drives it as a
chip select. There is no reset line to a GBA cartridge and nothing is missing:
the pin is doing its GBA job. Anyone re-tracing this from the netlist will
meet the same name and should not go looking for a mapping that does not
exist.

`/CS2` only pulls down actively and RC-rises through its 10k pull-up, which is
why the sequencer waits out a recovery window after every save access.

Cartridge voltage (5 V for Game Boy carts, 3.3 V for GBA) is picked by the
adapter's own notch-detect switch through a TPS2116 power mux. It is not
readable by the FPGA, so the core cannot tell which kind of cartridge is
inserted.

## Timing

`Cart Bus Timing` scales every phase. Measured in `sim/tb_cart_phys.vhd` as
emulated 16.78 MHz cycles of CPU stall per access:

| Preset | Random ROM read | Burst ROM read |
|---|---|---|
| Fast   | 5 | 4 |
| Normal | 7 | 4 |
| Safe   | 10 | 5 |

A real AGB does 3 and 1 at a typical `WAITCNT`. The emulated wait state runs
*concurrently* with the physical access — `gba_memorymux` asserts `cart_ena`
and counts down at the same time — so anything that finishes inside its wait
state costs nothing at all, and anything slower just stalls the CPU. Data is
never wrong either way, so the presets are purely a speed/margin trade.

`Normal` is sized to give the cartridge about the access time a real AGB gives
it, plus headroom for the two LVC8T245 crossings (~6.5 ns each way) that a real
AGB does not have. Start there, drop to `Safe` if a cartridge misbehaves.

The `/CS2` save window deliberately does **not** follow that ladder. FlashGBX's
LK firmware, which is tested against a very large pile of real cartridges,
holds `/RD` or `/WR` low for 400 ns on every SRAM access and 500 ns on a flash
write, and says plainly that FRAM needs it — and FRAM is what many repro carts
and battery-free save replacements use. Every preset here clears 400 ns for
that reason. A save is a few thousand bytes now and then, so nobody can feel
the difference, whereas a chip that answers late returns a wrong save byte in
silence.

**Four cycles is the floor for a burst read, and it is not the bus that sets
it.** Roughly half of those 238 ns is handshake: the request has to cross into
the clk6x domain, the answer has to cross back, and the answer has to be
*registered* on clk1x rather than handed over combinationally. Returning it
combinationally does save a whole cycle, and an earlier revision did exactly
that — but it puts the whole of `gba_memorymux`'s read path behind a
clk6x → clk1x transfer, which has only one clk6x period of setup, and the
fitter measured that at **-4.3 ns**. Getting a burst read down to three cycles
would need the cartridge to answer within ~15 ns of real access time after the
level shifters take their cut, which no Game Pak does. So expect ROM-resident
code to run slower than a real AGB; code the game copies into IWRAM or EWRAM
is unaffected, because none of it touches this bus.

## Known limitations

* **Open-bus reads past the end of the ROM.** A real AGB returns the stale
  address left on the multiplexed AD bus. Here the bus goes through level
  shifters with 100k pull-ups on both sides, so what a floating read returns
  is decided by how fast those pull-ups win against bus capacitance rather
  than by the address. Games that deliberately read past their own ROM (Minish
  Cap is the usual example) may behave differently than on hardware. Nothing
  in the core can fix this - the cartridge has to drive that bus for us to
  read anything real.
* **No save states in cartridge mode**, for the same reason the Game Boy core
  cannot offer them: the mapper and save-chip state live in silicon that
  cannot be snapshotted or restored.
* **No SNAC link port in cartridge mode** - two of its pins are the level
  shifter direction controls.
* **GBA cartridges only.** The adapter takes Game Boy and Game Boy Color
  cartridges too, but this is a GBA core; use the Gameboy core's own
  cartridge build for those.
* **The core cannot tell what kind of cartridge is inserted.** Voltage
  selection is done entirely by the adapter's notch-detect switch and is not
  routed to the FPGA.
* **Saves are fixed, but not yet confirmed on silicon.** The cartridge that
  turned this up was *Phantasy Star Collection* (`AGB-AYCP`, Europe), which
  carries a ROHM 9854 — a 64 Kbit EEPROM, confirmed both from the board's own
  markings and from FlashGBX's cartridge database. ROM booted off it and the
  save would not load, which is precisely the `/CS` bug above and precisely
  the save type it destroys. The testbench now covers both EEPROM widths, the
  6-bit-address 4 Kbit part and the 14-bit-address 64 Kbit part that cart
  actually has. Nobody has yet watched a real cartridge commit a real save
  with the fix in, though. SRAM and FLASH carts were never affected by this
  bug, so if one of those still will not save it is something else — try
  **Safe** first.

## Why a separate revision

`MISTER_MMS2` takes 29 FPGA pins away from their stock functions. On a
Multisystem2 those pins genuinely go to the expansion header; on a plain
DE10-Nano or any other I/O board they are the mainboard LEDs and keys, the ADC,
the Arduino header, the second SD slot, and three SDRAM strobes. The plain
`GBA`, `GBA2P` and `GBA2P_MEMTEST` revisions are bit-for-bit unaffected.

The SDRAM is not harmed by losing those three strobes. `rtl/sdram.sv` drives
`CKE` to a constant and drives `{DQMH,DQML}` from `SDRAM_A[12:11]` - the byte
mask travels on the address lines, which is the route the SDRAM module
actually uses. The separate `SDRAM_DQML`/`SDRAM_DQMH`/`SDRAM_CKE` pins are the
duplicate Arduino-header path for an alternate 8-bit wiring, and nothing here
depends on them.

The revision also switches `USER_IO` from the framework's open-drain-only
convention to an explicit per-pin direction (`USER_DIR`), because the two
shifter direction controls need real push-pull drivers. The link port keeps
open-drain behaviour by driving `USER_DIR = ~USER_OUT`, and the `SW[1]`
HDMI-I2S overlay on the SNAC pins is dropped — those pins belong to the
expansion header here.

## Building and testing

```bash
REVISION=GBA_MMS2 build/remote-build.sh
```

```bash
./sim/run_cart_phys_tb.sh
```

`DIRTY=1` builds the working tree instead of a committed ref, which is useful
while iterating. The expansion-bus pin constraints live in
`sys/mms2_pins.tcl`, sourced from `GBA_MMS2.qsf` - they are in a `.tcl`
because Quartus 17 silently discards per-index `IO_STANDARD` instance
assignments written inline in a `.qsf`, and this is the route the framework's
own pin constraints already take.

The testbench drives `gba_cart_phys` against a behavioural Game Pak that
implements only what GBATEK specifies — the `/CS` address latch, the 16-bit
auto-increment counter and its wrap, and the `/CS2` save window — so it fails
the design rather than covering for it.
