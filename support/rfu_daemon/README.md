# rfu_daemon — GBA Wireless Adapter (AGB-015) emulation, ARM side

The Wireless Adapter emulation is split in two, the same way gpSP splits its
SPI transport from `rfu.c`:

| part | lives in | owns |
|------|----------|------|
| transport | `rtl/gba_wireless.vhd` (FPGA) | GPIO ping, the "NINTENDO" login, `0x9966` STWI framing, per-word SO/SI handshake, clock reversal, and a 100 ms watchdog for incomplete transfers |
| semantics and radio | this daemon (HPS) | device IDs, host slots, broadcasts, RF data queues, session timeouts, and RFU1 over UDP or RetroArch netplay TCP |

The FPGA forwards each complete command packet over the framework UART and
takes the answer back the same way, so all RFU behaviour is plain C that can be
tested on a laptop. See the [AGB-015 protocol notes](../../docs/agb015_protocol.md).

## The radio

Peers exchange **RFU1 packets — gpSP's own wire format**, byte for byte
(`gpsp/rfu.c`). Broadcasts announce a host, then connect/data/ack packets carry
the session. MiSTer-to-MiSTer links send RFU1 directly over UDP. With `-N`,
the daemon can also host a RetroArch netplay session and carry the same RFU1
packets over TCP using gpSP's netpacket interface.

Discovery: each daemon broadcasts a small HELLO on the local segment once a
second, so two MiSTers on the same LAN find each other with no configuration.
For play across the internet, name the other side explicitly with `-P` and
forward the UDP port.

## Building

```bash
make            # host binary, for tests
make mister     # static ARM binary (rfu_daemon.arm) via musl-cross
make check      # RFU commands, UDP/TCP interop, and UART PTY tests (Python 3)
```

`make mister` needs an ARM cross compiler; `arm-linux-musleabihf-gcc`
(`brew install musl-cross`) is the default and links statically, so the
resulting binary needs nothing from the MiSTer image.

## Running on a MiSTer

Copy the binary and start it once at boot:

```bash
scp -O rfu_daemon.arm root@mister:/media/fat/linux/rfu_daemon
```

Then add the launcher to `/media/fat/linux/user-startup.sh` (see
`mister/user-startup-snippet.sh` in this directory):

```sh
/media/fat/linux/rfu_daemon -d /dev/ttyS1 >/dev/null 2>&1 &
```

In the core, set **Hardware → Multiplayer → Wireless (Emulated)**. The daemon
can stay resident: with the OSD option anywhere else the FPGA holds the
adapter in reset and never sends it anything.

### Options

| flag | meaning |
|------|---------|
| `-d dev` | UART device path (default `/dev/ttyS1`) |
| `-p port` | UDP port for RFU1 traffic (default 55440) |
| `-P host[:port]` | add a peer explicitly; repeatable, for play over the internet |
| `-N port` | Listen for RetroArch 1.22.2 + gpSP netplay clients on this TCP port; disabled by default |
| `-L` | disable LAN auto-discovery |
| `-v` | Log to stderr with monotonic `t_ms`, command hex, payload counts/first words, and `0x28` parameters plus active/ACKed slot masks |

Two MiSTers on one LAN need no flags at all. Across the internet, one side
forwards udp/55440 and the other passes `-P their.address`.

### Joining from RetroArch + gpSP

Run the daemon on MiSTer with `-d /dev/ttyS1 -N 55435 -v`. In RetroArch
1.22.2, load the same game in gpSP, select the RFU serial mode
(`gpsp_serial = "rfu"`), and connect as a netplay client to MiSTer's address
on TCP `55435`. The compatibility handshake targets RetroArch 1.22.2.

### Timing and compatibility

* UART and netplay TCP are nonblocking. A partial UART RX frame expires after
  25 ms. Pending UART output and per-client TCP output resume on `POLLOUT`;
  a peer that fills its bounded TCP output queue is disconnected instead of
  blocking STWI or other peers.
* Retail Emerald's parent keepalive uses `0x24` or `0x25` with the single
  parameter `0x00000001` and no payload word. The daemon reconstructs the
  `0xFF` null frame and still rejects malformed ordinary payload lengths.
* `0x28` reports actual transport ACKs: a one-word notification has ACKinfo
  in bits `3:0` and ActiveSlot in bits `11:8`. An ACK received immediately
  before an explicit child disconnect is reported once, without keeping that
  child active or retransmitting to it.

## Verification

The simulation benches cover login, command framing, clock reversal and
handback, and idle versus stalled-transfer watchdog behavior. `make check`
covers RFU commands, the netplay handshake, teardown ordering, and UART
framing. In a live MiSTer ↔ gpSP Pokémon Emerald wireless trade, both trainers
exchanged Pokémon, saved, and returned cleanly to the Union Room with zero
word watchdog events and zero command rejections. The final `0x28` preserved
the departing child's ACK (`ActiveSlot=0x0`, `ACKinfo=0x1`), and the parent
followed with `0x30 Disconnect`.
