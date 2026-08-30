# Direction B — RetroArch-netplay-compatible host in rfu_daemon

Goal: let a stock laptop RetroArch (1.17+) running the gpSP core join the
MiSTer's emulated Union Room as a second (or Nth) player, exactly as if it
were another MiSTer. The laptop does not need any custom software — it is the
"client" and the MiSTer `rfu_daemon` becomes a RetroArch-netplay **host**.

## Why this works

gpSP already emulates the AGB-015 adapter in software (`rfu.c`) and tunnels
its "RFU1" radio packets over RetroArch's **netpacket** multi-device interface
(`RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE`, env 78). RetroArch netplay
carries those packets between instances. Our `rfu_daemon` likewise speaks the
identical RFU1 packet format (see `rfu_proto.h`) between daemons.

So the MiSTer side already produces the same payload bytes gpSP produces. What
is missing is that we currently deliver RFU1 over plain UDP between daemons,
whereas the laptop client expects RFU1 wrapped in RetroArch netplay commands on
TCP, with a host doing the handshake and packet relay.

## What a host must do (validated against netplay_frontend.c)

Transport: TCP, network byte order for all multi-byte fields.

Handshake (both sides, server and client):
1. Send a 6-word connection header:
   - [0] NETPLAY_MAGIC            = 0x52414E50  "RANP"
   - [1] NETPLAY_PLATFORM_MAGIC   (endianness + sizeof(size_t)<<15 + sizeof(long))
   - [2] NETPLAY_COMPRESSION_SUPPORTED (0: no zlib in our impl)
   - [3] server: salt if password configured, else 0
   - [4] protocol version
   - [5] netplay_impl_magic() = XOR-hash of PACKAGE_VERSION + protocol version
2. Both verify the header (magic + platform + impl magic).
3. Each sends NICK (0x0020), payload = char nick[NETPLAY_NICK_LEN=32].

Then for the client (server receives):
- client sends INFO (0x0022), server validates, server sends INFO,
- server sends SYNC (0x0023) {frames, paused, players, flip,
  controller_devices[16], nick, sram}; client returns to sync.

In netpacket mode most replay/sync machinery is skipped (SRAM ignored, device
assignment unused, slave mode unused), so after handshake the real traffic is:

Command envelope (all commands): [uint32 cmd][uint32 size] [payload],
network byte order.

NETPACKET (0x0048):
- payload = [uint32 client_id][packet bytes]
- server relays: broadcast (0xFFFF / pkt_client_id==0 and it came from a
  client) to everyone except the sender; directed to one client. On receive,
  the payload is handed to the RFU core as RFU1 bytes addressed by a local
  peer index.

Server role notes:
- `retro_netpacket_start(client_id=0)` = we are host.
- client_id in netplay is 1-based per connection; RFU uses 0-based peers.
- The netpacket `pkt_client_id` tracks the *recipient* (host=0) or 0xFFFF
  broadcast; the source is the incoming connection id.

## Files

- `support/rfu_daemon/netplay_host.c`  — TCP listener, handshake, netpacket relay
- `support/rfu_daemon/netplay_proto.h` — constants + framing helpers
- `support/rfu_daemon/tests/tb_netplay_host.c` — wire oracle
- wire into `rfu_daemon.c` via an opt-in `-host <port>` mode and/or OSD later.

## Open items / pinned by the laptop

- `PACKAGE_VERSION` string used by `netplay_impl_magic()`. Ask the user for the
  laptop RetroArch version (Main Menu → Information → About). The host must
  present the *same* magic the client's build computes, or RetroArch refuses
  the connection ("incompatible impl"). The laptop's connected client hands its
  own version; the host can echo it.
- `HIGH_NETPLAY_PROTOCOL_VERSION` (5..7). gpsp needs 1.17+.
- Same LAN is confirmed; direct TCP to 192.168.1.243:<port>.