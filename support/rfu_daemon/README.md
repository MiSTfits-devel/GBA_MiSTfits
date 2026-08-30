# rfu_daemon — GBA Wireless Adapter (AGB-015) emulation, ARM side

The Wireless Adapter emulation is split in two, the same way gpSP splits its
SPI transport from `rfu.c`:

| part | lives in | owns |
|------|----------|------|
| transport | `rtl/gba_wireless.vhd` (FPGA) | GPIO ping, the "NINTENDO" login, 0x9966 STWI framing, the per-word SO/SI handshake, clock reversal, the 100 ms word watchdog |
| semantics | this daemon (HPS) | device IDs, host slots, broadcast table, RF data queues, session timeouts, and the radio — which is a UDP socket |

The FPGA forwards each complete command packet over the framework UART and
takes the answer back the same way, so all RFU behaviour is plain C that can be
tested on a laptop. Protocol details: `docs/agb015_protocol.md`.

## The radio

Peers exchange **RFU1 packets — gpSP's own wire format**, byte for byte
(`gpsp/rfu.c`). Broadcasts announce a host, then connect/data/ack packets carry
the session. That means the format is already understood by a gpSP peer; only
the delivery differs (gpSP hands its packets to RetroArch's netpacket
interface, we send UDP datagrams).

Discovery: each daemon broadcasts a small HELLO on the local segment once a
second, so two MiSTers on the same LAN find each other with no configuration.
For play across the internet, name the other side explicitly with `-P` and
forward the UDP port.

## Building

```bash
make            # host binary, for tests
make mister     # static ARM binary (rfu_daemon.arm) via musl-cross
make check      # local command-layout checks + a real two-process session
```

`make mister` needs an ARM cross compiler; `arm-linux-musleabihf-gcc`
(`brew install musl-cross`) is the default and links statically, so the
resulting binary needs nothing from the MiSTer image.

## Running on a MiSTer

Copy the binary and start it once at boot:

```bash
scp rfu_daemon.arm root@mister:/media/fat/linux/rfu_daemon
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
| `-d dev` | link to the core (default `/dev/ttyS1`, `-` uses stdio) |
| `-p port` | UDP port for RFU1 traffic (default 55440) |
| `-P host[:port]` | add a peer explicitly; repeatable, for play over the internet |
| `-L` | disable LAN auto-discovery |
| `-v` | log every command, state change and injected event |

Two MiSTers on one LAN need no flags at all. Across the internet, one side
forwards udp/55440 and the other passes `-P their.address`.

## Status

Sim-proven on the FPGA side (`sim/run_wireless_tb.sh`: login keystream, Hello,
SystemStatus, and a full 0x27 wait → reversal → 0x28 notify → clock handback)
and test-proven on this side (`make check`). What has **not** happened yet is a
run against a real game on real hardware — that is the next step, and `-v` plus
the core's link debug overlay are the tools for it.
