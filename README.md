# [Gameboy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance) for [MiSTer Platform](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

## Funky New Mode!
This fork from [MiSTfits](https://github.com/MiSTfits-devel/) is based off the old new `accuracy` port and includes both 1P
and 2P builds inline with configuration targets and macros.

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
To use these ROMs without renaming or removing the the boot.rom, 
you can activate the "Homebrew BIOS" settings in OSD.
As the BIOS is already replaced at boot time, you must save this settings and hard reset/reload the GBA core.

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
  - *WIP: support for SNAC GB EXT adapter to trade with real hardware*
  - *WIP: GBA Wireless Adapter emulation and ARM-hosted networking for RetroArch online crossplay*
- **GBA1P(+2P) core** reorganization and **accuracy fixes**
  - **RTC/Clock fixes**
    - *now fixed in most Pokemon ROMhacks*
  - **video glitches**
    - mosaic misapplication of BG3 to BG2, dropping BG3
  - memory issues
  - timing issues
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
