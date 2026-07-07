# AGB-015 Wireless Adapter — link-port protocol spec (adapter side)

Implementation spec for emulating the Wireless Adapter (RFU) in the FPGA. The GBA is
normally the SPI (Normal-32) clock master; we are the slave that must respond, except
during "clock reversal" phases where we become the master.

Sources (all statements traceable to one of these):

- **[LRW]** `~/sources/apotris/subprojects/gba-link-connection/lib/LinkRawWireless.hpp` (v8.0.3, hw-verified homebrew driver)
- **[SPI]** `.../lib/LinkSPI.hpp`
- **[LW]** `.../lib/LinkWireless.hpp`
- **[RFU]** pokeemerald-expansion `src/librfu_stwi.c`, `librfu_intr.c`, `librfu_sio32id.c`, `librfu_rfu.c`, `src/link_rfu_2.c` (decompiled official Nintendo librfu)
- **[MAN]** `AGB_Wireless_Controller.pdf`, esp. Appendix B "STWI Command Specifications" v1.2 (AGB-06-0306-001-A2) — authoritative per-command byte layouts.

Nintendo's name for this protocol is **STWI** ("Serial Three-Wired communication
Interface"): a REQ packet from the clock master answered by an ACK packet from the
clock slave, with a per-word SO/SI handshake between 32-bit words. [MAN C-1]

Terminology: all "words" are 32-bit SIO Normal-32 transfers, **MSB first** on the wire.
"GBA SO" = adapter's SI input; "adapter SO" = GBA's SI input.

---

## 1. Reset / detection (GPIO ping)

Before login the GBA pulses **SD** while in general-purpose (GPIO) mode:

- afska [LRW `pingAdapter`]: RCNT → GPIO mode, SO and SD configured as outputs
  (SO value left low), **SD driven HIGH for 50 scanlines ≈ 3.1 ms, then LOW**.
- librfu [RFU `AgbRFU_SoftReset`]: `RCNT=0x8000` (GPIO, all inputs), then
  `RCNT=0x80A0` (SD & SO outputs, both low), then `RCNT=0x80A2` (**SD HIGH**) held
  in a loop for 18 ticks of a 1024-cycle timer ≈ **1.10 ms**, then `RCNT=0x80A0`
  (SD LOW). Then it immediately switches to Normal-32.

**Adapter requirement:** treat a rising-then-falling edge on SD (high ≥ ~1 ms) while
in GPIO mode as a hard reset out of power-save: clear all session state, reset the
login state machine, RFU_State → N (Neutral). No response is required on SO during
the ping; the adapter's idle SO level is don't-care here (GBA reconfigures to SPI
right after). Duration varies (1 ms librfu / 3 ms afska) — trigger on the falling
edge, don't require an exact width.

The manual confirms the adapter powers on in "power conservation mode" and needs
this soft reset before accepting commands. [MAN C-5 §3.4]

---

## 2. Login ("NINTENDO" keystream) at 256 kbps Normal-32

After the ping, the GBA switches to Normal-32 **master, 256 kbps internal clock**
(SIOCNT bit0=1, bit1=0) and performs 10 blocking 32-bit exchanges, each preceded by
a ~15-scanline (~1 ms) pause, **without** the per-word SO/SI handshake of §3
(plain SPI, GBA SO low during transfer). [LRW `login` / `transfer(data,false)`]

GBA transmit word *i* (i = 0..9):

```
GBA_word[i]  = (~prev_adapter_hi16) << 16 | P[i]
P[] = {0x494E, 0x494E, 0x494E, 0x544E, 0x544E,
       0x4E45, 0x4E45, 0x4F44, 0x4F44, 0x8001}
```

(P spells "NI NI NI TN TN EN EN OD OD" + device-ID 0x8001; `prev_adapter_hi16`
starts as **0x8000**, so GBA_word[0] = `0x7FFF494E`.)

Required adapter response word *i* (this is what [LRW] verifies):

```
ADP_word[i] = (P[i] << 16) | (~GBA_prev_lo16)
```

where `GBA_prev_lo16` = low half of the *previous* GBA word (assumed 0xFFFF before
the first exchange, so ADP_word[0] low half = 0x0000). The first **two** exchanges
(i = 0, 1) are not validated by the GBA ("junk steps"); from i = 2 onward both
halves must match exactly or the GBA aborts and restarts the whole sequence
(ping + login).

**Adapter state machine (recommended implementation).** Because the response is
clocked *simultaneously* with the GBA's word (full duplex, MSB first), the adapter
cannot echo the current word; it must track its position `j` in `P[]`:

- Response to every transfer: `hi16 = P[j]`, `lo16 = ~last_received_lo16`.
- After a transfer where `received_lo16 == P[j]` **and** `received_hi16 ==
  ~previous_adapter_hi16_output` (with the initial "previous output" = 0x8000),
  advance `j`. On mismatch reset `j = 0` (and reset `last_received_lo16 = 0xFFFF`).
- Login complete when the 0x8001/0x8001 exchange succeeds (j walks 0→9). The
  duplicated keywords in `P[]` are exactly what makes this tracking scheme line up
  with what the GBA checks.

*Confidence note:* the exchanged-word values and validation are directly from
[LRW]; the *advance rule* is an inference (the only rule consistent with all 10
expected words) — the manual does not document login at all, and librfu's
`Sio32IDIntr` [RFU] implements the symmetric GBA↔GBA variant (with halves swapped),
not the adapter side. See §8.

librfu drives the same exchange via `AgbRFU_checkID` (keywords `0x494E 0x544E
0x4E45 0x4F44` then `0x8001` = `RFU_ID`), also at 256 kbps (`SIO_38400_BPS`=1 ⇒
SIOCNT bits[1:0]=01), retrying with ~2 ms gaps up to 8×/30× before giving up. The
adapter must therefore tolerate the sequence restarting at any point.

**After login:** afska sends the first command (Hello, 0x10) **still at 256 kbps**,
then switches to 2 Mbps for everything else [LRW `start`]. librfu switches to 2 Mbps
(`SIO_115200_BPS`=3 ⇒ SIOCNT bits[1:0]=11) immediately and sends Reset (0x10) there,
after a ~16 ms post-login delay [RFU `rfu_REQ_stopMode` timer 262 ticks]. As SPI
slave the adapter shouldn't care about the master's clock rate — accept command
framing at both speeds.

---

## 3. Command framing (GBA = clock master) and the per-word handshake

### 3.1 Packet format [MAN B-3, LRW]

A REQ packet from the GBA:

```
word 0:  0x9966_LLCC      LL = number of parameter words, CC = command ID
word 1..LL:  parameter words (little-endian byte order within word:
             byte0 = bits7:0 ... byte3 = bits31:24)
```

While the GBA clocks REQ words out, **the adapter must reply 0x80000000 to every
word** ("dummy code"; the GBA verifies this and aborts/retries the command
otherwise). [MAN B-3: "The receiving side continues to return 80000000h. This value
is used to find clock drift."; LRW `sendCommand` checks `!= DATA_REQUEST_VALUE`]

After the last parameter, the GBA clocks one more word sending `0x80000000`
(response request). **In that same transfer** the adapter must return the ACK
header:

```
ACK word 0:  0x9966_LL(CC+0x80)    LL = response-payload words, low byte = cmd|0x80
ACK word 1..LL: response payload   (GBA sends 0x80000000 in each of these)
```

So from the adapter's viewpoint the ACK header must be pre-loaded into its shift
register *before* the GBA starts the response-request transfer — i.e. immediately
after receiving the last parameter word (during the handshake gap).

**Error / rejection:** if the command is invalid, reply with
`0x9966_01EE` followed by one payload word: `1` = command valid (0x10..0x3D) but
illegal in the current state, `2` = unknown command. [RFU `sio32intr_clock_slave`,
MAN B-45 "AcknowledgementRejection (eeh)", LRW error path]

### 3.2 Handshake between words (adapter = slave)

Both drivers do the identical dance after **every** 32-bit transfer (REQ words,
response request, and every ACK payload word) [LRW `acknowledge`, RFU
`sio32intr_clock_master` `handshake_wait`]:

```
(GBA has SO low during/after the transfer)
1. ADAPTER: when the word is processed and the next word's reply data is
   loaded, drive SO HIGH.          ("ready / word consumed")
2. GBA: sees SI high → drives its SO HIGH.
3. ADAPTER: sees SI high → drive SO LOW.
4. GBA: sees SI low → drives SO LOW and starts clocking the next word.
```

Adapter rule of thumb: **raise SO when ready, drop SO when the GBA's SO goes high,
then expect clocks while both lines are low.** The GBA times out each wait after
~15 scanlines (afska, ≈1 ms) or 80 ms (librfu, then retries the whole REQ after
130 ms, max 2 retries, then fatal). The manual requires word-interval and REQ↔ACK
interval **< 64.8 ms** [MAN B-5]; the adapter's own clock-drift timeout is
**100 ms** [MAN B-7] — if the GBA goes silent longer, a real adapter resets its
packet state machine and waits for a fresh REQ header (it does NOT reset the
session). Implement the same: a per-word timeout (~100 ms) that re-arms the
"expect 0x9966 header" state.

---

## 4. Command set

IDs, parameter and response layouts. "afska" = used by LinkRawWireless/LinkWireless;
"librfu" = used by official games (Pokémon Emerald etc. via link_rfu_2.c/LMAN).
ACK ID is always `cmd|0x80`. Payload byte order: byte0 is bits7:0 of the word.

| ID | Nintendo name | afska name | Params | Resp | Used by |
|----|---------------|-----------|--------|------|---------|
| 0x10 | Reset | hello | 0 | 0 | both (first cmd after login) |
| 0x11 | LinkStatus | getSignalLevel | 0 | 1 | both |
| 0x12 | VersionStatus | — | 0 | 1 | neither (exists) |
| 0x13 | SystemStatus | getSystemStatus | 0 | 1 | afska; librfu rarely |
| 0x14 | SlotStatus | getSlotStatus | 0 | 1+n | both |
| 0x15 | ConfigStatus | — | 0 | 8 | neither |
| 0x16 | GameConfig | broadcast | 6 | 0 | both |
| 0x17 | SystemConfig | setup | 1 | 0 | both |
| 0x18 | KeySetConfig | — | 1 | 0 | key-sharing (prohibited by Nintendo; skip) |
| 0x19 | SC_Start | startHost | 0 | 0 | both |
| 0x1A | SC_Polling | pollConnections | 0 | n | both |
| 0x1B | SC_End | endHost | 0 | n | both |
| 0x1C | SP_Start | broadcastReadStart | 0 | 0 | both |
| 0x1D | SP_Polling | broadcastReadPoll | 0 | 7·k | both |
| 0x1E | SP_End | broadcastReadEnd | 0 | 7·k | both (librfu reads resp) |
| 0x1F | CP_Start | connect | 1 | 0 | both |
| 0x20 | CP_Polling | keepConnecting | 0 | 1 | both |
| 0x21 | CP_End | finishConnection | 0 | 1 | both |
| 0x24 | DataTx | sendData | 1+d | 0 | both |
| 0x25 | DataTx&Change | sendDataAndWait | 1+d | 0, then reversal | both |
| 0x26 | DataRx | receiveData | 0 | 0 or 1+d | both |
| 0x27 | MS_Change | wait | 0 | 0, then reversal | both |
| 0x28 | DataReady&Change | (event 0x28) | — | — | **adapter→GBA only** |
| 0x29 | Disconnected&Change | (event 0x29) | — | — | **adapter→GBA only** |
| 0x30 | Disconnect | disconnectClient | 1 | 0 | both |
| 0x31 | TestMode | — | 1 | ? | neither |
| 0x32/33/34 | CPR_Start/Polling/End | — | 2/0/0 | 0/1/1 | librfu (link recovery) |
| 0x35/36/38/39 | KeySet* | — | | | key-sharing; skip |
| 0x37 | ResumeRetransmit&Change | — | 0 | 0, reversal | librfu (rare) |
| 0x3D | StopMode | bye | 0 | 0 | both |

Details for the ones that matter:

### 0x11 LinkStatus → 1 word
`byte0..3 = link quality slot0..slot3`, 0x00 = no link, 0xFF = perfect. Parent view:
all in-use slots; child view: only its own secured slot. Return 0xFF for connected
slots.

### 0x13 SystemStatus → 1 word
```
byte0-1: own device ID (16 bit; 0 in states N/CSP)
byte2:   ChildUsingSlot bitmap (only meaningful in C states; used by [LRW] as
         "currentPlayerId": 0001→P1, 0010→P2, 0100→P3, 1000→P4, else host/P0)
byte3:   RFU_State: 0=N 1=P 2=P-PSC 3=CSP 4=CCP 5=C 6=C-CCP 7=CPR 8=TEST
```
Note [LRW] maps state 1 to "SERVING, server closed" and 2 to "SERVING (open)",
3 SEARCHING, 4 CONNECTING, 5 CONNECTED.

### 0x14 SlotStatus → 1 + n words
Word0 byte0 = EntrySlot (next free slot 0..3, 0xFF = entry forbidden/full). Then one
word per connected child: `byte0-1 = child ID, byte2 = slot number (0-3), byte3 = 0`.

### 0x16 GameConfig — 6 param words, no response
24 bytes = `serialNo(2) | gameName(14) | userName(8)`, packed little-endian
(word0 = serial | gname[0]<<16 | gname[1]<<24, etc.). This is the broadcast data.
librfu layout of the 16-byte "GameName" field [RFU `rfu_REQ_configGameData`]:
`serial_lo, serial_hi (|0x80 if multiboot), gname[13 bytes], ~checksum` where the
checksum byte sums gname+uname. afska treats it as gameId(15 bit) + 14-char name.
The adapter just stores the 24 bytes verbatim and broadcasts them.

### 0x17 SystemConfig — 1 param word, no response
```
byte0: mcTimer / waitTimeout — MasterChangeTimer: max time the AGB may stay clock
       slave; 0 = no limit, else n×16.6 ms, after which the ADAPTER itself issues
       MS_Change... actually issues the reversal to give the clock back (see §5).
byte1: maxMFrame / maxTransmissions — retransmission count per Tx datum; 0 = keep
       retransmitting until next DataTx.
byte2: bit1-0 AvailableSlot: 00=4 clients, 01=3, 10=2, 11=1
       bit2   DebugMode, bit4-3 LinkTimer (link-loss timeout 1..4 s, default 1 s),
       bit6-5 FD, (bit7 in byte3) ...
byte3: bit0 ClockSpeed (0=1.19 MHz, 1=2.38 MHz — RF-side serial),
       bit3 SegmentRestructure (0=ON). afska magic 0x003C0000 = AvailableSlot per
       maxPlayers + 0x3C pattern; Emerald sends (availSlotFlag&1)|0x3C too.
```
afska builds `magic | ((5-maxPlayers)&3)<<16 | maxTransmissions<<8 | waitTimeout`
with defaults maxTransmissions=4, waitTimeout=32 (≈531 ms). Emerald calls
`rfu_REQ_configSystem(avail, maxMFrame, mcTimer)`.

### 0x19/0x1A/0x1B host (SC = Search Child)
SC_Start: adapter enters P-PSC, begins broadcasting GameConfig data and accepting
children. SC_Polling / SC_End: response = one word per **newly** connected child
since SC_Start: `byte0-1 = CID, byte2 = slot`, same layout as SlotStatus minus the
header word. SC_End stops accepting (server "closed", state P).

### 0x1C/0x1D/0x1E search (SP = Search Parent)
SP_Start: state CSP, scan for broadcasts. SP_Polling response: 7 words per found
parent (max 4): `word0: byte0-1 = PID, byte2 = EntrySlot (0xFF = refusing)`,
then 4 words GameName[16] and 2 words UserName[8] — i.e. the 24 broadcast bytes
prefixed by ID+slot. SP_End same response format, ends scanning.

### 0x1F/0x20/0x21 connect (CP = Connect Parent)
CP_Start param: `word0 = PID` (low 16 bits). CP_Polling response word:
`byte0-1 = assigned CID, byte2 = slot number (= client number 0..3),
byte3 = status: 0 done, 1 in process, 2 entry slot closed, 3 parent not found`.
afska treats the full word `0x01000000` as "still connecting" and
`byte2 (msB) + 1` as the assigned player ID. CP_End response: same layout,
status 0 = success (final CID/slot), bit0 of byte3 set = failure. After success
adapter state = C (Connected); the GBA's player ID = slot + 1.

### 0x24 DataTx / 0x25 DataTx&Change — 1 header + d data words
Header word (also used in DataRx responses):
```
bits 6:0    P_DataLength  (bytes, 0..87)  — set when sender is the parent
bits 12:8   S0_DataLength (bytes, 0..16)  — set when sender is child in slot 0
bits 17:13  S1_DataLength     "     slot 1
bits 22:18  S2_DataLength     "     slot 2
bits 27:23  S3_DataLength     "     slot 3
```
([LRW `getSendDataHeaderFor`]: host uses `bytes`, client k (playerId=k) uses
`bytes << (3+5k)` — same encoding.) Data words follow, up to 22 (host, 87 B) or
4 (client, 16 B). ACK has no payload. The adapter queues this for RF transmission
to the peer(s). 0x25 additionally performs the §5 role reversal after the ACK.

### 0x26 DataRx — 0 params
Response: empty (0 words) if nothing received, else the same header word (length
fields describe *who sent what*: P_DataLength for data from the parent, Sn for data
from child n) followed by the payload words packed in order P, S0, S1, S2, S3.
Reading clears the receive buffer.

### 0x27 MS_Change — 0 params, ACK, then role reversal (§5)

### 0x30 Disconnect — 1 param: `bit n of byte0` = disconnect child in slot n.

### 0x3D StopMode — ACK, then adapter returns to power-save; next contact is a new
ping + login. Emerald calls this (`rfu_REQ_stopMode`) when shutting the link down.

### 0x32/0x33/0x34 CPR (Connect Parent Recovery) — child-side link recovery.
CPR_Start params: `word0 = PID<<16 | CID`, `word1 = slot bitmap`. CPR_Polling
response byte0: 0 = restored, 1 = CID erased (unrecoverable), 2 = parent not found.
CPR_End response byte0: 0 = success, 1 = fail. Emerald's link manager uses these
after link loss; a first implementation can reply "fail" (or Done if the session
still exists) — but Emerald will then drop to a link error rather than resume.

---

## 5. Clock reversal (adapter becomes SPI master)

Commands **0x25 (DataTx&Change), 0x27 (MS_Change), 0x37** ACK normally, and then
the roles flip: the GBA reconfigures as SIO slave (external clock) with
`SIODATA32 = 0x80000000` armed and SO low; the adapter must now generate the clock
and issue its own REQ packet when it has something to report. [MAN B-31/§3.3,
LRW `wait`/`sendDataAndWait` + `receiveCommandFromAdapter`, RFU clock-slave ISR]

Adapter-issued commands (same 0x9966 framing, directions swapped):

- **0x28 DataReady&Change** — new data arrived (or send verified). 0 params
  normally; 1 param when MaxMframe retransmissions expired without all children
  ACKing: `byte0 = ACKinfo bitmap (slots that ACKed), byte2 = ActiveSlot bitmap
  (slots still being retried; a child silent > 1 s is dropped from ActiveSlot)`.
- **0x29 Disconnected&Change** — connection lost (child side). 1 param:
  `byte0 = reason (0 = own CID erased by parent, 1 = link lost),
  byte2 = bitmap of disconnected slots`.
- **0x27 MS_Change** — issued by the adapter only when SystemConfig's
  MasterChangeTimer expires (deadline for the GBA being clock slave); afska calls
  this outcome "EVENT_WAIT_TIMEOUT". 0 params.
- (0x36 KeySetReady&Change — key-sharing only.)

Wire sequence, adapter as master (each word followed by the reversed handshake in
§5.1):

```
adapter clocks:  0x9966_PPCC      (PP params, CC ∈ {0x27,0x28,0x29})   GBA returns 0x80000000
adapter clocks:  param words       (GBA returns 0x80000000 each)
adapter clocks:  0x80000000        ← GBA returns 0x9966_00(CC+0x80)  (the GBA's ACK)
adapter clocks:  0x80000000        ← GBA returns 0x80000000  (final; then GBA
                                      switches back to master 2 Mbps)
```

The GBA validates the header (must be 0x9966), collects params, replies with the
ACK packet, and expects the adapter's final word to be exactly `0x80000000`
[LRW `receiveCommandFromAdapter`]. After this exchange **the GBA is clock master
again** and continues issuing commands (typically 0x26 DataRx right away).

librfu behaves identically but accepts only 0x27/0x28/0x29/0x36 as remote commands
(anything else gets the 0x9966_01EE rejection, sent by the GBA as slave!) [RFU
`sio32intr_clock_slave`]. It also accepts a remote 0x28 with parameters (1 param
case above).

### 5.1 Reversed handshake (adapter = master, GBA = slave)

After each adapter-clocked word [LRW `reverseAcknowledge`, RFU slave ISR]:

```
1. ADAPTER: drive SO LOW after the word completes.
2. GBA: sees SI low → drives SO HIGH ("word consumed, processing").
3. ADAPTER: sees SI high → drive SO HIGH.
4. GBA: sees SI high → waits ≥ 40 µs, loads its reply data, drives SO LOW
   and arms the slave transfer.
5. ADAPTER: sees SI low → may start clocking the next word, but MUST wait
   ≥ 40 µs after step 3/4 (GBA IRQ latency; afska waits ~2 scanlines ≈ 120 µs
   and marks this wait "VERY important to avoid desyncs").
```

Between role flip and the adapter's first word there is no upper time bound from
the GBA (afska waits forever; librfu arms a 100 ms clock-drift timer per word —
see §6 timeouts: the adapter should send *something* (0x27 timeout event) within
SystemConfig's waitTimeout if configured, and Emerald's LinkManager additionally
runs a ~360-frame watchdog). The adapter's master clock rate is not documented;
the GBA as slave accepts any rate ≤ 2 MHz — use 256 kHz to be conservative (§8).

---

## 6. IDs, broadcast layout, timing summary

- **Device IDs (PID/CID):** 16-bit, nonzero, assigned by the adapter itself
  (host gets an ID when SC_Start puts it in P state; the parent assigns each child
  a CID at entry). SystemStatus/SlotStatus/SP_Polling expose them. Any nonzero
  scheme works; real adapters look random-ish.
- **Player numbering:** host = player 0; child's player ID = its slot number + 1
  (slot from CP_Polling/CP_End byte2, or infer from SystemStatus ChildUsingSlot
  bitmap). Max 5 players (1 parent + 4 slots).
- **Broadcast payload:** 24 bytes (serial/gameId 2B + game name 14B + user name 8B),
  set with 0x16, seen by scanners via 0x1D/0x1E prefixed with `PID | EntrySlot`.
- **Data sizes:** parent → children max 87 bytes/frame; child → parent max
  16 bytes/frame. Command packets: ≤ 23 param words, responses ≤ 30 words
  (afska caps; SlotStatus/SP responses fit under this).
- **Timing:**
  - Word interval and REQ↔ACK interval < **64.8 ms** [MAN B-5].
  - Adapter clock-drift timeout **100 ms** (≈ 6 frames); GBA master detects drift at
    80 ms and retries the REQ after **133.6 ms** (≈ 8 frames), max 3 attempts, then
    the GBA gives up (librfu: stops clock, becomes slave, unrecoverable without
    power cycle / new login) [MAN B-7, RFU timers 50/80/100/130 ms].
  - Radio link loss timeout: **LinkTimer** in SystemConfig, 1–4 s (default 1 s).
  - MasterChangeTimer (mcTimer/waitTimeout): n × 16.6 ms limit on clock-slave
    periods; Emerald uses it and derives `linkEmergencyLimit = 600/mcTimer`.
  - afska LinkWireless transfers every ~4.6 ms (interval 75 × 1024 cyc) and
    treats a configurable frame-count without data as disconnect.
  - Handshake gap before adapter clocks next word (reversed mode): ≥ 40 µs.

### Minimal subset for Pokémon Emerald 2-player link

Login (§2) + handshakes (§3.2/§5.1) plus: **0x10, 0x16, 0x17, 0x11, 0x14,
0x19/0x1A/0x1B, 0x1C/0x1D/0x1E, 0x1F/0x20/0x21, 0x24, 0x25, 0x26, 0x27, 0x30,
0x3D**, and adapter-initiated **0x28, 0x29**. CPR (0x32–0x34) only for link
recovery (can stub as fail). KeySet/TestMode/VersionStatus/ConfigStatus unused.
afska (Apotris, LinkUniversal) needs the same set plus **0x13** SystemStatus.

---

## 7. Suggested adapter-side state machine (informative)

```
GPIO ping ─→ LOGIN(j=0..9) ─→ IDLE/N ──0x19──→ P-PSC (broadcasting, accepting)
                    │                     │ 0x1B → P (closed)
                    │                     │ children connect → slots fill
                    │
                    └──0x1C──→ CSP (scanning) ──0x1F──→ CCP ──entry ok──→ C
Any state: 0x10 → back to N (keep login). 0x3D → power-save (needs ping+login).
Per-command engine: HEADER → PARAMS×LL → RESPREQ(load ACK) → RESP×LL,
with the §3.2 handshake around every word and a 100 ms wordwatchdog that
re-arms HEADER. 0x25/0x27/0x37 ACK then flip to master engine (§5).
```

---

## 8. Disagreements and unknowns

1. **Login response generation rule.** The exact adapter algorithm for advancing
   through the NINTENDO keystream is inferred (§2), not documented. [LRW] gives the
   exact expected words (authoritative for what we must output); [RFU sio32id] is
   the GBA↔GBA variant and swaps which halfword carries the key. Mismatch handling
   on the real adapter (full reset vs. index reset) is unknown — index reset is safe
   because both drivers restart the entire ping+login on failure.
2. **First command speed.** afska sends Hello(0x10) at 256 kbps then switches to
   2 Mbps; librfu sends Reset(0x10) at 2 Mbps. Adapter must accept commands at both
   rates (slave: just sample on clocks; only matters if the FPGA oversamples).
3. **Adapter-as-master SIO clock rate**: undocumented. SystemConfig "ClockSpeed
   1.19/2.38 MHz" appears to be RF-side. GBATEK-era emulators use 256 kHz; the GBA
   slave doesn't care. Recommend 256 kHz (≈2 µs/bit) for timing margin.
4. **SystemConfig magic 0x003C0000**: afska calls it un-reverse-engineered magic;
   the manual decodes those bits as DebugMode/FD/LinkTimer/ClockSpeed etc.
   (0x3C ⇒ LinkTimer=4 s? bits4-3=11 — decode carefully; Emerald sends the same
   0x3C pattern). Store and ignore except AvailableSlot, maxMFrame, mcTimer.
5. **SystemStatus response**: [MAN] documents byte layout (ID, ChildUsingSlot,
   RFU_State); [LRW] additionally interprets state 1 vs 2 as closed/open server —
   consistent, but "isServerClosed" for state P (after SC_End) is afska's reading.
6. **0x1E SP_End response**: [MAN] says it returns found-parents like 0x1D; [LRW]
   ignores any payload (`broadcastReadEnd` reads nothing but tolerates it). Return
   the parent list (librfu reads it).
7. **Wait command numbering**: afska names 0x27 "wait" GBA→adapter and expects
   remote events 0x27/0x28/0x29; the manual says a remote 0x27 only happens on
   MasterChangeTimer expiry. Consistent, just note a remote 0x27 must be supported
   even if mcTimer = 0 was configured (afska treats it as a benign timeout event).
8. **ACK to adapter-initiated commands**: [LRW] replies `0x9966_00(cmd+0x80)`
   with LL=00 always; [RFU] does the same for known commands but replies
   `0x9966_01EE` + status for unknown ones. The adapter should treat any
   `0x9966_xx(cmd|0x80)` from the GBA as acceptance and 0xEE as rejection.
9. **Login junk steps**: afska doesn't validate exchanges 0/1 but librfu's
   symmetric algorithm validates everything with retry-forever; the duplicated
   keywords make both pass. No conflict in practice.
10. **Handshake polarity idle levels**: between commands (GBA master, idle) the
    GBA leaves SO low ([LRW] ends `acknowledge()` with SO low) but plain-SPI mode
    idles SO high ([SPI] `disableTransfer`). The adapter must not interpret idle
    SO levels as handshake edges until a transfer actually completes.
