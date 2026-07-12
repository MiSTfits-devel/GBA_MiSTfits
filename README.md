# [Gameboy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

## Funky New Mode!
This fork from [MiSTfits](https://github.com/MiSTfits-devel/) is based off the "old new" `accuracy` port and includes both 1P
and 2P builds in line with configuration targets and macros.

## HW Requirements/Features
Using SDRAM with your MiSTer is highly recommended, as some games may run poorly when using just DDR-RAM as a fallback.

When using SDRAM, the core requires 32MB SDRAM for games less than 32MB. 32MB games require either a 64MB or 128MB module.
SDRAM will be automatically used when available and size is sufficient.

Running two different games on either side of the new GBA2P core may require a 128MB module.

Running GBA Video ROMs such as Shrek 1 & 2 requires a 128MB module.

## BootROM (BIOS)
An Opensource GBA BootROM (also known as a GBA BIOS) from Normmatt is included. It has issues with some games.

Any original GBA BIOS can be placed in the `/media/fat/games/GBA/` folder with the filename `boot.rom` to load automatically.

An Analogue Pocket BIOS dump may also be used in place of an original GBA BIOS and will still function for all typical features.

You can read more about legal ways to dump your authentic GBA BIOS/BootROMs on the [DS Homebrew Wiki](https://wiki.ds-homebrew.com/gbarunner2/bios-dump).

Per their docs:
> There are two distinct ways to achieve this, using:
> - a 3DS with custom firmware, OR
> - a GBA/DS/DS Lite with a GBA-mode flashcart

## A note on homebrew
Homebrew games are sometimes not supported by the official BIOS, 
because the BIOS checks for Nintendo Logo included in the ROM, 
which was an old and no-longer-valid copyright protection.

### A temp workaround
To use these ROMs without renaming or removing the boot.rom, 
you can activate the "Homebrew BIOS" settings in OSD.

As the BIOS is already replaced at boot time, you must save these 
settings and hard reset/reload the GBA core.

### How to patch your old ROMs
As part of FOSS toolchains, `gbafix.exe` and similar programs can be found free of charge with valid legal 
provenance in 2026 (at the time of writing).

Simply run `gbafix` on these ROMs from either Wonderful Toolchain, meson-gba, or DevKitPro to patch them.

## Compatibility
Given the exceptional retail compatibility of the original core, compatibility with modern GBA homebrew
is the goal for this core's dev team.

Some decisions have been made to maximize compatibility out of the box for users running newer GBA titles at home.

Titles restored in 1P or 2P:
- Modern "Pokemon Emerald" or Pokemon-Expansion based ROMhacks post-2023
  - PokeScape
  - Moemon post-2023
  - Pokemon Lazarus, Emerald Seaglass
  - Super Mariomon
  - ...and any other decomp-based hacks
- Apotris
- Pump It Up GBA!
- ...and many more!

## Features

### From the original GBA_MiSTer core
- saving as in GBA
- Savestates
- Flickerblend - set to blend or 30Hz mode for games like F-Zero, Mario Kart or NES Classics to prevent flickering effects
- Cheats - not working yet
- Color optimizations: shader colors and desaturate
- Tilt: use analog stick (map stick in Mister Main before)
- Solar Sensor: Set brightness in OSD
- Gyro: use analog stick (map stick in Mister Main before)
- RTC: automatically used, works with RTC board or internet connection
- Rumble: for Drill Dozer, Wario Ware Twisted and some romhacks

### Funky new modes for GBA_MiSTfits
- **GBA2P core full rewrite**
  - new multiplayer improvements over old GBA2P core/branch
    - **Supports many more games than the original core**
    - Supports homebrew titles at the highest speeds
    - For core developers:
      - pin/state machine readouts
      - overlay toggles
  - backported fixes from GBA_MiSTer `accuracy` branch
  - solved memory issues
    - 1P and 2P consoles both load cart(s) from SDRAM if possible
  - *WIP: support for SNAC GB EXT adapter to trade with real hardware*
    - Choose **Multiplayer → SNAC Link Port** for either a physical GBA link
      cable or a physical AGB-015 Wireless Adapter. Plug position determines
      cable master/slave role; no software role selector exists on real GBA.
    - **Wireless (Emulated)** selects the core's internal AGB-015 emulation and
      intentionally releases SNAC pins. Do not select it for a real adapter.
    - Set the DE10-Nano `SW[1]` switch low when using SNAC. The MiSTer
      framework otherwise assigns HDMI I2S/LRCLK to USER_IO pins 2 and 5,
      which are the adapter's SI and SD signals.
    - SNAC GB EXT wiring: SC=USER_IO[0], SD=USER_IO[5], SI=USER_IO[2],
      SO=USER_IO[1].
  - *WIP: GBA Wireless Adapter emulation and ARM-hosted networking for RetroArch online crossplay*
- **GBA1P(+2P) core** reorganization and **accuracy fixes**
  - **RTC/Clock fixes**
    - *now fixed in most Pokemon ROMhacks*
  - **video glitches**
    - mosaic misapplication of BG3 to BG2, dropping BG3
    - **TL;DR:** mimicks the sound of an original GBA console
    - authentic `SOUNDBIAS PWM` output stage
      - bias & clipping, 32–262 kHz sample & hold, etc.
    - fixes missing/muted noise-channel percussion
      - Sonic Advance 2
      - Pokemon RSE/FRLG
  - solved timing issues
  - tweaked some overzealous, rare patches to be disabled by default
    - these automatically re-enable on the game(s) they were designed for when detected
  - *WIP: "Shrek" cart mapper for exotic GBA video titles*
- *WIP: Rewind support*
- *WIP: Fast-forward support*

## Savestates
Core provides 4 slots to save and restore the state. 
Those can be saved to SDCard or reside only in memory for temporary use(OSD Option). 
Usage with either Keyboard, Gamepad mappable button or OSD.

### Keyboard Hotkeys
- Alt-F1..F4 - save the state
- F1...F4 - restore

### Gamepad Hotkeys
- Savestatebutton+Left or Right switches the savestate slot
- Savestatebutton+Down saves to the selected slot
- Savestatebutton+Up loads from the selected slot

## Future work:
- E-Reader support
## On the backburner:
- Gameboy Player features
