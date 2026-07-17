# NOOP - Oura Ring BLE Protocol Specification (Clean-Room)

**Status:** Implemented qualification candidate (2026-07-12). Promotion is generation- and
platform-specific; see the [hardware graduation gate](HARDWARE_SUPPORT.md#oura-graduation-gate).
**Scope:** Oura Ring Gen 3 (Horizon), Gen 4, Gen 5. Foundation for NOOP's own Swift (`StrandiOSShared` / `Strand`) and Kotlin decoders.
**Authorship:** This is NOOP's own original specification. Every protocol *fact* (UUID, opcode, byte layout, tag value) is cited to a reverse-engineering reference read for facts only. No source code was copied from any RE repo. NOOP decodes raw signals plus the ring's own HRV/sleep tags and runs NOOP's own scoring; NOOP never touches Oura's encrypted PyTorch scores.

**Citation keys used below:**
- **[open_ring]** - LogosIsLife/open_ring `PROTOCOL.md` (GPL-3.0; byte-for-byte verified vs ~953k records, Ring 4). Treat as the authoritative framing/layout source where repos conflict.
- **[ringverse]** - ringverse/protocol `oura/BLE.md`, `oura/events/EVENTS.md` (no-license; Ring 4 event-tag dictionary + layouts).
- **[open_oura-r3]** - Th0rgal/open_oura `docs/horizon-ring3-protocol-cheatsheet.md` (no-license; Ring 3).
- **[open_oura-r5]** - Th0rgal/open_oura `docs/ring-5-observations.md` (Ring 5).
- **[open_oura-feat]** - Th0rgal/open_oura `docs/ring-features.md` (feature gating).
- **[relue]** - relue/oura_ring_reverse `docs/.../heartbeat_replication_guide.md` and `heartbeat_complete_flow.md` (no-license; Ring 3 live-HR).
- **[oura-rs]** - Th0rgal/open_oura `crates/oura-protocol/src/events.rs` (no-license Rust clean-room decoder; facts cited only, no code copied). Its event tags marked `"_status": "unvalidated"` are treated the same as our Tier B - plausible, not ground-truth-confirmed.

> **CONFLICT NOTE (resolution rule):** The relue archive file `event_data_definition.md` describes events as **protobuf varint** records (e.g. `0x55` SLEEP_HR with field tags). This contradicts the **byte-for-byte verified TLV framing** in [open_ring] and [ringverse]. The TLV/bit-packed model from [open_ring]/[ringverse] is authoritative for our decoders; the protobuf description is treated as unverified/likely AI-fabricated and is NOT used. Where a layout is only attested by a single no-license, AI-generated doc, it is marked **(UNVERIFIED)** and our decoder must gate it behind a fixture test before trusting it.

---

## 1. GATT Layout

### 1.1 Base service (all generations)
- **Service UUID:** `98ED0001-A541-11E4-B6A0-0002A5D5C51B` [open_ring][ringverse][open_oura-r3]
- **Write characteristic (phone → ring):** `98ED0002-A541-11E4-B6A0-0002A5D5C51B`
  - ATT handle observed `0x0015`, **Write Without Response** (ATT op `0x12`) [open_ring][ringverse]
- **Notify characteristic (ring → phone):** `98ED0003-A541-11E4-B6A0-0002A5D5C51B`
  - ATT handle observed `0x0012`, notifications via Handle-Value-Notification (ATT op `0x1B`) [open_ring][ringverse]
- **GATT channel id:** `0x0004` [ringverse]

> Implementation note for NOOP: subscribe to `...0003` on Gen 3 and read-only to
> `...0003/0004/0005/0006` on Gen 4/5, then write commands only to `...0002` with
> `.withoutResponse`. Do **not** assume write-with-response and never write application commands to
> the extra inbound paths.

### 1.2 Per-generation GATT differences

| Aspect | Gen 3 (Horizon) | Gen 4 | Gen 5 |
|---|---|---|---|
| Service `…0001` | yes | yes | yes (same layout) [open_oura-r5] |
| Write `…0002` | yes | yes | yes |
| Notify `…0003` | yes | yes | yes |
| Extra char `…0004` | - | **present**: read, write, write-no-response, notify, indicate (Ring 4 hardware, 2026-07-12) | **present**: read,write,notify,indicate [open_oura-r5] |
| Extra char `…0005` | - | **present**: write-no-response, notify (Ring 4 hardware, 2026-07-12) | **present**: write,notify [open_oura-r5] |
| Extra char `…0006` | - | **present**: write-no-response, notify (Ring 4 hardware, 2026-07-12) | **present**: write,notify [open_oura-r5] |
| MTU | 203 [open_oura-r3] | 247 [open_ring] | 247 [open_oura-r5] |

- Ring 5 keeps "the **same** GATT layout, framing, and app-auth flow as the Ring 3/4 … no new opcodes, event tags, or fundamental framing changes." [open_oura-r5]
- Ring 4 firmware `2.12.3` requires both the tested Android and macOS transports to subscribe read-only to `…0003/0004/0005/0006` before the adopted session is driven. Their individual semantic roles remain **unconfirmed**; never write application commands to the extras (all commands still use `…0002`).

### 1.3 MTU negotiation
- Notifications stream up to the negotiated MTU (max payload = MTU − 3 ATT bytes). Default BlueZ MTU is 23 unless negotiated. [open_ring]
- **NOOP rule:** immediately after subscribing to `…0003`, request ATT MTU = **247** (Gen 4/5) or **203** (Gen 3). On iOS/CoreBluetooth the MTU is auto-negotiated; read `maximumWriteValueLength` and `CBPeripheral.maximumWriteValueLength(for: .withoutResponse)` and clamp writes. On Android, call `requestMtu(247)` before the first command.
- **Android write scheduling:** serialize Write Without Response commands with at least **350 ms** between starts on Ring 4. The tested Saga link negotiated interval 15 ms with slave latency 20 (a 315 ms worst-case receive window); immediate writes dropped later commands, while the 350 ms queue completed auth, live enable, and history (`2026-07-12`).
- **Apple write scheduling:** CoreBluetooth also serializes Ring 4 Write Without Response commands with
  the same 350 ms minimum spacing and waits for `canSendWriteWithoutResponse`; this completed key
  installation, fresh-session auth, live-mode enable, battery, and history on macOS 27.0 (`2026-07-12`).

---

## 2. Framing / Chunking

Two distinct layers ride on the same characteristics. The first byte disambiguates: a value present in the **opcode table (§4)** → outer command/response frame; otherwise → an inner event-record stream. [open_ring]

### 2.1 Outer frame (command + command-response)
All multi-byte integers are **little-endian**. [open_ring][ringverse]

```
+--------+--------+------------------------+
| op : 1 | len : 1| body : <len> bytes     |
+--------+--------+------------------------+
```
- `op` - opcode (§4)
- `len` - number of body bytes following
- Multiple outer frames may be packed into a single ATT notification value. **Consumer rule:** loop `consume(2 + len)` until the buffer is exhausted. [open_ring]

### 2.2 Extended / secure-session frame (opcode `0x2F`)
Opcode `0x2F` carries a sub-operation as the **first body byte**:
```
2F <len> <subop> <subop-body…>
```
Sub-op table in §4.2. [open_ring][open_oura-r3]

### 2.3 Inner event record (TLV) - the event stream
Returned during history fetch (`0x10`/`0x11`) and live streaming. Each record: [open_ring]
```
+--------+--------+--------+--------+--------+--------+------------------+
| type:1 | len:1  | ctr_lo | ctr_hi | ses_lo | ses_hi | payload: len-4   |
+--------+--------+--------+--------+--------+--------+------------------+
```
- `type` - event tag (≥ `0x41`, §6) [ringverse]
- `len` - body length, **`len ≥ 4`** (covers the 4 timestamp bytes + payload) [open_ring]
- `ctr` (u16 LE) + `ses` (u16 LE) → **`ringTimestamp = (session << 16) | counter`** [open_ring]
- payload length = `len − 4`

> [ringverse]'s EVENTS.md states the header as `type:1, len:1, ringTimestamp:u32 LE` (i.e. it treats the 4 counter/session bytes as one u32). These are two equivalent views of the same 4 bytes; NOOP stores `ringTimestamp` as a single u32 LE and derives counter/session only if a generation needs the split. [open_ring][ringverse]

- **Total record length = `len + 2`.** [ringverse]
- Several records may pack into one notification; consume `2 + len` per record and loop. [open_ring]

### 2.4 Multi-packet payloads
There is no application-level fragmentation header beyond the TLV `len`. A record never spans two notifications in the verified corpus; each notification contains whole frames/records. NOOP's parser must still be defensive: buffer partial trailing bytes across notifications and only emit complete `2+len` records.

---

## 3. Authentication Handshake

### 3.1 Key materials (three independent layers) [open_ring]

| Layer | Size | Purpose |
|---|---|---|
| Link-layer LTK | 16 B | BLE bond / link encryption (managed by OS pairing) |
| LE Privacy IRK | 16 B | resolves the ring's rotating private address |
| Application `auth_key` | 16 B (AES-128) | the app-level challenge key (§3.2–3.4) |

- On a **factory-reset** ring, BLE link encryption (OS-level pairing/bond) is **mandatory** before any protocol command can be written. [open_oura-r3]
- The application auth handshake is **session-scoped**: it must be re-run on every new BLE connection. [open_ring][open_oura-r3]

### 3.2 Install our own key (opcode `0x24`) - post-factory-reset only
Used once after a factory reset to provision NOOP's own 16-byte AES key into the ring: [ringverse][open_oura-r3]
```
phone → ring:  24 10 <16-byte key>          (SetAuthKey; 0x10 = 16-byte len)
ring  → phone: 25 01 00                       (status 0x00 = OK)
```
NOOP stores its 16-byte key locally (Keychain on iOS, EncryptedSharedPreferences/Keystore on Android). This key is required for every subsequent session's challenge.

On tested Ring 4 firmware `2.12.3`, persist the acknowledged key, disconnect, and authenticate on a **new** GATT session. A same-session nonce request after the `0x25` acknowledgment did not answer.

### 3.3 Get auth nonce (sub-op `0x01` → response `0x2C`)
```
phone → ring:  2f 01 2b                        (GetAuthNonce)
ring  → phone: 2f 10 2c <nonce: 15 bytes>      (18 B total)
```
[open_ring][ringverse][open_oura-r3]

**Ring 4 ordering:** never send `SetNotification` (`0x1C`) before authentication or as part of the
live-HR enable triplet. The byte-exact official history setup uses one post-auth, post-SyncTime state
pulse (`1c 01 bf`) immediately before the six event-category masks. On firmware `2.12.3`, tightly
spaced or misplaced `0x1C` writes stalled later control writes; NOOP therefore sends this exact pulse
only once per BLE session through the same serialized 350 ms command queue.

### 3.4 Compute proof (AES-128-ECB challenge)
[open_ring][ringverse]
- Plaintext = `nonce (15 B) ‖ 0x01 (1 B)` = 16 B, then **PKCS#5/PKCS#7 full-block padding** appends `0x10 × 16` → 32 B total.
- Cipher = **AES-128/ECB/PKCS5Padding** with our 16-byte `auth_key`.
- **proof = first 16 bytes of the ciphertext.**

> Padding detail per [open_ring]: `AES_128_ECB(auth_key, nonce ‖ 0x01 ‖ pad)[:16]`. The trailing `0x01` byte and full-block `0x10` padding are load-bearing - the ring computes the same and compares the first block. Implement this exactly; do not strip padding before encrypt.

### 3.5 Submit proof (sub-op `0x11` → response `0x2E`)
```
phone → ring:  2f 11 2d <proof: 16 bytes>      (19 B total)
ring  → phone: 2f 02 2e <status>
```
[open_ring][ringverse][open_oura-r3]

**Status byte (`0x2E`):** [ringverse]
| Value | Meaning |
|---|---|
| `0x00` | Success |
| `0x01` | Authentication error (wrong key) |
| `0x02` | In factory reset (need `0x24` key install first) |
| `0x03` | Not the original onboarded device |

### 3.6 Pre-auth readable / gated commands
Before app-auth, the ring answers a small set unauthenticated: firmware (`0x08`), product serial/hardware (`0x18`). Auth-required commands return `2f 02 2f 01` until authenticated: battery (`0x0c`), history events (`0x10`), feature status (`0x2f…0x20`), realtime/feature-latest. [open_oura-r3][open_oura-r5]

**NOOP qualification rule:** request firmware and the ProductInfo **hardware page** on every connection,
but never request the serial page. Decode/log the four version triplets and hardware-family token; discard
the firmware response's trailing Bluetooth-address bytes. This makes a test bundle reproducible without
persisting a ring serial or address.

---

## 4. Opcode Table

### 4.1 Top-level opcodes
Compiled from [ringverse] (BLE.md) and [open_ring] (PROTOCOL.md); examples are exact bytes from the sources.

| Op | Name | Dir | Example / form | Notes |
|---:|---|---|---|---|
| `0x06` | RealtimeMeas / identity_req | →ring | `06 04 <mode> <flags> 00 00` | realtime enable control; rare in pairing [open_ring][open_oura-r3] |
| `0x07` | identity_resp | ←ring | | [open_ring] |
| `0x08` | GetFirmwareVersion | →ring | `08 03 00 00 00` | pre-auth OK [ringverse][open_oura-r3] |
| `0x09` | FirmwareVersion resp | ←ring | `09 12 …` | API/FW/BL/BT/MAC (§4.3) [ringverse] |
| `0x0A` | RunSelfTest | →ring | `0a 04 ff ff ff ff` | [ringverse][open_oura-r3] |
| `0x0B` | SelfTest resp | ←ring | `0b 04 ff ff ff ff` | [ringverse] |
| `0x0C` | GetBattery | →ring | `0c 00` | auth-gated after key set [ringverse][open_oura-r3] |
| `0x0D` | Battery resp | ←ring | `0d 06 …` | §6.10 [ringverse][open_ring] |
| `0x0E` | StartFirmwareUpdate / soft_reset | →ring | `0e 01 ff` | reboot 22–35 s; DANGEROUS [open_ring] |
| `0x0F` | resp to `0x0E` | ←ring | status `0x00`=accept | [open_ring] |
| `0x10` | GetEvents (history fetch) | →ring | `10 09 <rt:4 LE> <max:1> <flags:4 LE>` | auth-gated; §5 [ringverse][open_ring] |
| `0x11` | GetEvents resp / summary | ←ring | `11 08 …` | §5.2 [ringverse][open_ring] |
| `0x12` | SyncTime | →ring | `12 09 <…> ` | §5.4 [ringverse][open_ring] |
| `0x13` | SyncTime resp | ←ring | `13 05 …` | [ringverse][open_ring] |
| `0x16` | SetBleMode / event-stream subscribe | →ring | `16 01 <mode>` | `00`=normal/disabled; `02` enables the Ring 4 event stream in open_ring's executable setup sequence [ringverse][open_ring] |
| `0x17` | SetBleMode resp | ←ring | `17 01 <mode>` | [ringverse] |
| `0x18` | GetProductInfo | →ring | `18 03 <offset> 00 10` | serial `08 00 10`; hw `18 00 10` [ringverse][open_oura-r3] |
| `0x19` | ProductInfo resp | ←ring | | [ringverse] |
| `0x1A` | FactoryReset | →ring | | DANGEROUS [ringverse] |
| `0x1B` | FactoryReset resp | ←ring | | [ringverse] |
| `0x1C` | SetNotification / state_cmd | →ring | `1c 01 <flags>` | `00`=none, `3f`/`bf`=all [ringverse][open_ring][open_oura-r3] |
| `0x1D` | SetNotification resp | ←ring | `1d 01 00` | [ringverse] |
| `0x1E` | state_query | →ring | | [open_ring] |
| `0x1F` | state_query resp | ←ring | | [open_ring] |
| `0x20` | SetUserInfo | →ring | `20 03 <type> …` | [ringverse][open_oura-r3] |
| `0x21` | SetUserInfo resp | ←ring | | [ringverse] |
| `0x24` | SetAuthKey | →ring | `24 10 <16-byte key>` | §3.2 [ringverse] |
| `0x25` | SetAuthKey resp | ←ring | `25 01 00` | [ringverse] |
| `0x26` | EnableFlightMode | →ring | `26 02 <…>` | [ringverse] |
| `0x28` | CheckSleepAnalysis / data_flush | →ring | `28 01 <force>` | `28 01 00` flush flash buffer [ringverse][open_ring][open_oura-r3] |
| `0x29` | resp to `0x28` | ←ring | `29 01 00` | [ringverse][open_ring] |
| `0x2B` | DFU / fw_progress | both | | OTA [ringverse][open_ring] |
| `0x2C` | fw_bulk | both | | OTA payload [open_ring] |
| `0x2F` | Extended / SecureSession | both | `2f <len> <subop> …` | §4.2 [ringverse][open_ring] |
| `0x31` | SetRingMode | →ring | `31 04 <4-byte mode> 00 00` | `00000000`=normal, `01000000`=fast-HR [open_oura-r3] |
| `0x32` | SetRingMode resp | ←ring | | [ringverse][open_oura-r3] |
| `0x37` | SetManufacturingInfo | →ring | | [ringverse] |
| `0x38` | resp to `0x37` | ←ring | | [ringverse] |
| `0x39` | SyncManufacturingInfo | →ring | `39 00` | [ringverse][open_oura-r3] |
| `0x3A` | resp to `0x39` | ←ring | | [ringverse] |

### 4.2 `0x2F` secure-session sub-ops

| Sub | Form | Meaning | Cite |
|---:|---|---|---|
| `0x01` | `2f 01 2b` | request nonce | [open_ring][open_oura-r3] |
| `0x02` | `2f 02 …` | sec_cfg / status / capability page (`2f 02 01 <page>`) | [open_ring][open_oura-r3] |
| `0x10` | `2f 10 2c <nonce:15>` | nonce response | [open_ring] |
| `0x11` | `2f 11 2d <proof:16>` | proof submission | [open_ring] |
| `0x20` | `2f 02 20 <feature>` | feature/param **read** | [open_ring][relue] |
| `0x21` | `2f 06 21 <feature> <mode> <status> <state> <sub>` | feature read **response** | [open_ring][open_oura-r3] |
| `0x22` | `2f 03 22 <feature> <value>` | param **write byte 0** (enable) | [open_ring][relue] |
| `0x23` | `2f 03 23 <feature> <status>` | ack to `0x22` | [relue] |
| `0x26` | `2f 03 26 <feature> <value>` | param **write byte 2** (subscribe) | [open_ring][relue] |
| `0x27` | `2f 03 27 <feature> <status>` | ack to `0x26` | [relue] |
| `0x28` | `2f 0f 28 …` | param **push notification** (carries live-HR samples) | [open_ring][relue] |
| `0x2C` | `2f 10 2c <nonce>` | nonce response (alias view) | [open_ring] |
| `0x2D` | `2f 11 2d <proof>` | proof submission (alias view) | [open_ring] |
| `0x2E` | `2f 02 2e <status>` | handshake completion | [open_ring][ringverse] |

### 4.3 Firmware response (`0x09`) decode
`09 12 <API:3> <FW:3> <BL:3> <BT:3> <MAC:6>` - e.g. API `2.0.0`, FW `3.4.3`, BL `1.0.1`, BT `5.0.12`, MAC little-endian last-6. [open_oura-r3][open_oura-r5]
Gen 5 example `0912 020100 020103 010001 090329 665544332211`. [open_oura-r5]
**NOOP uses byte[2] of the API triplet (generation marker via product info) to branch decoder behaviour - see §7.**

---

## 5. Event Fetch (Cursor) Protocol + Live HR

### 5.1 GetEvents request (`0x10`)
```
10 09 <ringTimestamp:4 LE> <max_events:1> <flags:4 LE>
```
[open_ring][ringverse]
- `ringTimestamp` - cursor; ring streams records with `rt > cursor`. `0x00000000` = full dump. [open_ring]
- `max_events` - up to 255 records to fetch; `0x00` = ack-only (advance cursor without data). [open_ring]
- `flags` - phone sends `0xFFFFFFFF`. [open_ring][open_oura-r3]
- Canonical example: `10 09 00 00 00 00 08 ff ff ff ff` (cursor 0, max 8). [open_oura-r3]

### 5.2 GetEvents response / summary (`0x11`)
```
11 08 <status:1> <sub_status:1> <last_ring_timestamp:4 LE> <pad:2>
```
[open_ring]
- `status` - `0x00` = empty/no more; `0xFF` = data follows (event records arrive as inner TLV stream, §2.3). [open_ring]
- `last_ring_timestamp` - batch metadata only. The durable ACK/save cursor is the maximum
  `ringTimestamp` across structurally-valid inner records in the batch. [open_ring]

### 5.3 Canonical fetch loop (NOOP)
1. Before authentication on Ring 4, preserve the official read-only order: firmware/hardware identity, session probes `2f 02 01 00` and `2f 02 01 01`, then the nonce request. After authentication, send event-stream enable (`16 01 02`), then SyncTime (§5.4). On the first pass of each BLE connection, follow it with the byte-exact post-sync state pulse (`1c 01 bf`), the six official `0x18` event-category masks (`14/18/28/34/04/08`), a battery read, and the official setup sweep: parameter reads `02/04`, the still-semantically-provisional session-state selector `2f 02 03 01`, then parameter reads `0b/0d/03/0b/10`. The selectors are session-scoped and are not used for reset, pairing, or biometric-data mutation. Keep all writes on the serialized 350 ms queue.
2. Treat any well-formed Ring 4 `0x13` as a one-way liveness acknowledgement while a request is active; tested firmware can return nonstandard status/echo fields. A one-second idempotent fallback still releases the fetch when no usable reply arrives. Neither path authorizes persistence: a correlated `0x42`, a qualified recent `0x85` RTC beacon, or a previously validated durable anchor whose ring clock proves monotonic continuity beyond both saved boundaries must establish the ring-time/UTC pair.
3. Only then send `28 01 00` to flush flash-buffered events followed by `0x10` with the stored cursor and `max=255`.
4. Receive the `0x11` summary and inner TLV records (§6). Some Ring 4 firmware banks the fresh correlated `0x42`; tested firmware 2.12.3 instead acknowledged SyncTime and returned recent `0x85` RTC beacons without any `0x42`. During the active fetch, an RTC beacon no older than 48 hours, no more than 15 minutes ahead of the request window, and at or beyond the durable cursor may establish a persistable 100 ms/tick mapping. A later correlated `0x42` still replaces it. The summary can precede its record notifications, so hold it until the TLV stream has been idle for 500 ms. If a page contains records but no anchor, keep its decoded events parked and issue only another `max=255` read from the actual record high-water: no `max=0` ACK, cursor save, flush, or persistence. Each in-memory window stops at 32 pages or 4,096 parked events. At that bound, discard provisional RAM only and continue from the record high-water for at most eight read-only bootstrap windows; the ring data remains unacknowledged. During that explicitly bounded bootstrap, a plausible historical `0x42` may establish the clock as open_ring does. No-progress or terminal responses still stop the scan.
5. If the anchor arrived after any window was skipped, discard the current provisional RAM and refetch from the unchanged durable cursor under that anchor. Resolve the complete refetch, await every SQLite stream/sleep insert, then atomically save its cumulative record high-water together with the durable anchor. A write failure leaves both local state and ring ACK unchanged, so natural-key inserts safely retry. If the bounded bootstrap finds no anchor, the cursor remains unchanged; one post-fetch SyncTime retry is allowed only when the in-memory bound was not exceeded.
6. Only after that commit send ack-fetch (`max=0`, cursor = the maximum structurally-valid inner-record `ringTimestamp`).
7. A fetch missing both a correlated `0x42` and a qualified recent `0x85` leaves ring history unacknowledged and the local cursor unchanged, so a later refetch cannot skip data. [open_ring]

### 5.4 SyncTime (`0x12`)
Ring 4:
```
12 09 <random_token:1> <counter:3 LE> 00 00 00 00 f6
```
where `counter = floor(unix_seconds / 256)`, the token is freshly random per request, and trailer `0xf6` is fixed. [open_ring]
Response: `13 05 <ack> <counter_echo:3 LE> 00`. [open_ring]
- The `0x13` body is an acknowledgement/echo only. It contains **no ring timestamp** and cannot anchor
  history by itself; the timestamped `0x42` event (§6.11) establishes the UTC anchor. [open_ring]
- NOOP accepts any well-formed `0x13` while a SyncTime request is active and releases flush/fetch only
  once; tested firmware can return nonstandard status/echo fields, matching the official transport's
  one-way treatment. A one-second idempotent fallback handles a missing/malformed reply. Both paths are
  transport liveness only. Normally a Ring 4 `0x42` must match the active random token and coarse counter.
  Only after the read-only scan crosses its bounded in-memory limit may a plausible backlog `0x42`
  bootstrap the clock; skipped pages are then refetched from the unchanged durable cursor before any ACK.
- Gen 3 captures use a different request body (`unix_seconds:u64 LE` plus timezone half-hours) and a
  generation-specific `0x13` response. Keep the two layouts separate. [open_oura-r3]
- Gen 5 SyncTime remains unverified on hardware.

### 5.5 Ring-time → UTC anchoring
- The ring clock is in **ticks**: default **100 ms/tick** (10 Hz); burst mode **1 ms/tick** (`factor_flag=1`). [open_ring]
- Anchor from event `0x42` (time-sync ind, §6.11): set `anchor.utc_ms` from the event's epoch and `anchor.ring_time` from current `ringTimestamp`.
- Conversion: `utc_ms = anchor.utc_ms + factor × (target_rt − anchor.ring_time)`, `factor ∈ {100,1}`. [open_ring]
- On `0x41` (ring start) with `rt` regression → invalidate anchor (zero it). [open_ring]
- Persist the validated reconnect anchor atomically with the history cursor and a save timestamp. This is
  normally a correlated primary `0x42`; on qualified Ring 4 firmware it may be the narrowly-gated recent
  `0x85` fallback described below.
  On reconnect it may translate timestamps immediately, but it is **mapping state only** until a
  structurally-valid record reaches both the durable cursor and anchor ring time with a plausible mapped
  epoch. Only then may the active fetch commit. A cursor/ring-start regression clears the anchor. Legacy
  cursor-only state migrates without inventing an anchor.
- `0x85` RTC beacon gives 1-second-granularity `unix_s` as a secondary source. Outside an active Ring 4
  fetch it remains session-only. During an active fetch, the §5.4 age/future/cursor gates may qualify it
  as a durable 100 ms/tick reconnect anchor when firmware omits `0x42`. [open_ring]

### 5.6 Live-HR realtime enable (Gen 3 verified; same path Gen 4/5)
Three writes to `…0002`, each gated on its ACK; daytime-HR feature id = `0x02`: [relue][open_oura-r3]
```
1) 2f 02 20 02      → ACK 2f 06 21 02 01 11 02 00     (read DHR feature status)
2) 2f 03 22 02 03   → ACK 2f 03 23 02 00              (enable: byte0 = 3)
3) 2f 03 26 02 02   → ACK 2f 03 27 02 00              (subscribe: byte2 = 2)
```
**HR/IBI then streams ~1 Hz** as `0x2F` sub-op `0x28` push notifications: [relue][open_ring]
```
2f 0f 28 02 XX 02 00 00 <IBI_L> <IBI_H> 00 00 00 00 YY ZZ 7f
```
- IBI at body bytes 8–9: **`ibi_ms = ((byte9 & 0x0F) << 8) | byte8`** (12-bit, LE-ish nibble) [relue]
- **`bpm = round(60000 / ibi_ms)`** [relue]
- Example `[08,09] = 01 04` → `ibi = 1025 ms` → ≈ 59 BPM. [relue]

**Disable:** `2f 03 22 02 01` → ACK `2f 03 23 02 00`. Stream stops on ACK. [relue][open_oura-r3]

> Behaviour caveat: [open_oura-r3] reports that on its Ring-3 unit, realtime `0x06`-based enabling ACK'd but emitted no stream within 60–90 s, whereas the `0x2F`/feature-`0x02` path above produced ~1 Hz IBI. **NOOP must use the feature-`0x02` (`0x2F`) path, not `0x06`,** and treat absence of `0x28` pushes within ~10 s as "not streaming → retry/reseat."

### 5.7 DHR auto-revert
Daytime-HR auto-reverts after ~20 s; NOOP re-engages every ~15 s while a live session is open. [open_ring]

---

## 6. Event / Record Byte Layouts

All records share the §2.3 TLV header (`type`, `len`, 4-byte `ringTimestamp`). Body offsets below are **relative to the start of the record** (offset 6 = first body byte). All multi-byte values **little-endian** unless stated. [ringverse]

### 6.1 IBI + amplitude - `0x60` `ibi_and_amplitude_event` (18 B)
- 6 IBI+amplitude pairs, **bit-packed** across body bytes 6–19. [ringverse]
- **Shift exponent** = low nibble `[3:0]` of last body byte; if `n=7` then `shift=0`, else `shift=n+1`. [ringverse]
- Each **IBI** = 11-bit value (1 LSB bit + an 8-bit byte shifted left 3 + a 2-bit high field) → milliseconds. [ringverse]
- Each **amplitude** = 7-bit mantissa (byte bits `[7:1]`) shifted left by the exponent. [ringverse]
- Per-sample timestamp: walk backward from event UTC by each IBI duration. [ringverse]

### 6.2 Green-LED IBI+amp - `0x71` `green_ibi_and_amp_event` (18 B)
- 5 IBI deltas + 6 amplitudes; shift from byte19 bits `[2:0]`; same 11-bit IBI / 7-bit amplitude structure. [ringverse]

### 6.3 SpO2 IBI+amp - `0x6E` `spo2_ibi_and_amplitude_event` (17 B)
- Byte 6: bits `[7:6]` = flag(1)+shift(3); bits `[3:0]` = mode(4). [ringverse]
- 5 IBIs as 8-bit counts ×8, read bytes 11→7 (reverse). [ringverse]
- 7 amplitudes: first `byte<<3`, rest `byte<<shift`. [ringverse]

### 6.4 Green IBI quality - `0x80` `green_ibi_quality_event` (4–18 B, 2 B/sample)
Per 16-bit LE sample: [open_ring][ringverse]
```
bits 0–10  : value_11bit  → IBI in ms
bits 11–13 : qual_a
bits 14–15 : qual_b
```
**NOOP filter:** accept sample only if `qual_a ≤ 1 && qual_b == 0`. [open_ring]
(7 samples per 14-byte record.) [open_ring]

### 6.5 SpO2 per-sample - `0x6F` `spo2_event` (5–18 B, 1 s spacing)
- Byte 6 is a status/header field; it is **not** added to the following values. [ringverse]
- One direct `uint8` SpO2 percentage per second from byte 7 onward; optional `0xFF` terminator. Values
  are oldest-to-newest and the record timestamp belongs to the newest value, so sample `i` is placed at
  `record_time - (count - 1 - i)` seconds. [ringverse]

### 6.6 SpO2 smoothed/stable - `0x70` `spo2_smoothed`/`spo2_stable` ; `0x7B` `spo2_stable_event` (6 B)
- `0x7B`: single **uint16 big-endian** at bytes 6–7. **(big-endian - exception to LE rule)** [ringverse]
- `0x70` present in tag dictionary as smoothed SpO2; layout **(UNVERIFIED)** - gate on fixtures. [ringverse]
- Neither `0x70` nor `0x7B` is in the pinned Ring 4 event enum; treat them as legacy/unqualified for
  Ring 4. Ring 4 percentage support rests on `0x6F`, while `0x77` remains raw optical DC.

### 6.7 SpO2 DC - `0x77` `spo2_dc_event` (variable)
- Byte 6: bit`[7]`=HDR low bit; bit`[6]`=`hasBase`; bits`[5:4]`=scale shift. [ringverse]
- If `hasBase`: bytes 7–9 = 24-bit LE base. [ringverse]
- Remaining: sign-magnitude int8 deltas; `v=(int8)raw; mag=|v|<<scale; out = v<0 ? -mag : mag`, accumulated. [ringverse]

### 6.8 Skin temperature
- **`0x46` `temp_event`** (10–18 B, even len): up to 7 samples, each **int16 LE ÷ 100 = °C**. [ringverse]
- **`0x69` `temp_period`** (6 B): single **int16 LE ÷ 100 = °C**. [ringverse]
- **`0x75` `sleep_temp_event`** (6–18 B, 30 s spacing): values **uint16 LE ÷ 100 = °C**, timestamps walk backward from event UTC. [ringverse]

### 6.9 HRV / RMSSD - `0x5D` `hrv_event` (6–16 B, 5-min spacing)
- Samples each with `time_ms` + two int8 fields (`b1`,`b2`); timestamps walk backward from event UTC. [ringverse]
- **NOOP note:** `0x5D` is the ring's own RMSSD-derived HRV tag; NOOP also reconstructs RMSSD/SDNN itself from the IBI streams (`0x60`/`0x80`) for our own scoring (we do not consume Oura's encrypted scores). [open_ring][ringverse]

### 6.10 Battery - `0x0D` response (8 B body)
- Layout: `percent, charging_progress, recommended_flag, 3 unknown bytes`. [open_oura-r3]
- Voltage as **uint16 LE at body offset [4..6]** per [open_ring]. **CONFLICT:** [open_oura-r3] reads percent at body[0]; [open_ring] reads voltage at [4]. **NOOP rule:** read percent at body[0]; derive a voltage-based estimate from [4..6] only as a fallback, fixture-validated per generation.

### 6.11 Time-sync ind - `0x42` (generation-specific)
- **Ring 4 (verified):** nine-byte payload
  `<token:1><time_counter:u24 LE><constant:5>`. UTC seconds are `time_counter × 256`; the record header's
  `ringTimestamp` is the matching ring-clock anchor. The clock factor is 1 ms/tick when `token == 0xfd`,
  otherwise 100 ms/tick. [open_ring]
- **Gen 3 (observed):** nine-byte payload `<unix_seconds:i64 LE><timezone_half_hours:i8>`. The unit is unix
  **seconds**, not milliseconds; treating it as milliseconds anchors history around 1970. [open_oura-r3]
- **Gen 5:** unverified; NOOP retains the legacy decoder as a fixture-gated fallback and must not claim
  hardware qualification until a capture confirms the layout.
- `OuraTimeSync.epochMs` retains its original source-compatible property name, but the decoded value is
  unix seconds on the verified Gen 3 and Ring 4 paths. The driver performs the bounded seconds-to-ms
  conversion when establishing the anchor.
- **CRASH-SAFETY RULE: bounds-check any multi-byte wire arithmetic before use.** A full cursor-0 history dump (a ring never synced before) can surface a `0x42` record deep in the backlog whose raw epoch value is wildly implausible (near `Int64.max`) - a misaligned/corrupt record rather than a real time-sync (§2.4: "each notification contains whole frames/records" is the verified-corpus norm, not a guarantee). A naive seconds→ms `× 1000` on such a value overflows `Int64` and traps. **Any arithmetic on a raw multi-byte wire field must be plausibility-checked before use, never trusted as automatically well-formed.** NOOP's driver gates the time-sync / RTC-beacon anchor to a 2020–2035 unix-seconds window before converting (`OuraDriver.plausibleAnchorMs`), rejecting anything outside it as an undecodable record rather than crashing or anchoring to garbage.
- This is the primary UTC anchor (§5.5). [open_ring][ringverse]

### 6.12 Sleep architecture
- **`0x4E` / `0x5A` `sleep_phase_details`** (≥19 B): byte6 = header; phase codes are **2-bit**, 4 per byte (bits `[7:6][5:4][3:2][1:0]`); codes **0=awake, 1=light, 2=deep, 3=REM**. [ringverse]
- **`0x6A` `sleep_period_info_2`** (10-byte body): average HR `uint8 × 0.5`, HR trend `int8 / 16`,
  two index bytes `/16`, breathing `uint8 / 8`, breathing variation `uint8 / 8`, motion count `0...120`,
  unnamed state `0...2`, and CV `uint16 LE / 65536`. The state codes are preserved raw and are **not**
  mapped to WHOOP sleep state or sleep stages until a fixture proves their semantics. [open_ring]
- **`0x72` `sleep_acm_period`** (16 B): values0–2 = `whole(8)+frac(8)/255`; values3–5 = `whole(4)+frac(12)/4095`. [ringverse]
- **`0x49` `sleep_summary_1`**: start/end as uint16 LE minutes-before-event. [ringverse]
- **`0x76` `bedtime_period`** (8-byte body): start/end as uint32 LE ringTimestamps → map to UTC
  (§5.5). NOOP persists plausible 15-minute...16-hour windows as stage-less sleep sessions. [open_ring]
- Tags `0x48,0x4A–0x4D,0x4F,0x57,0x58` are additional sleep summary/feature variants in the dictionary; layouts **(UNVERIFIED)** - decode only after fixtures. [ringverse]

### 6.13 Motion / activity
- **`0x47` `motion_events`** (variable): byte6 bits`[7:5]`=field_a, `[4:0]`=field_b; bytes7–9 = three **int8 × 8** axis magnitudes; optional bytes10–11. [ringverse]
- **`0x6B` `motion_period`** (19–31 B): 12-bit period `((b6<<8)|(b6>>6)) & 0xFFF`; byte6 bits`[5:4]`=leading-symbol count; then 2-bit codes, 4 per byte (MSB-first). MOTION_STATE enum: `0 NO_MOTION, 1 RESTLESS, 2 TOSSING, 3 ACTIVE`. [ringverse][open_ring]
- **`0x50` activity_info / `0x51`,`0x52` activity_summary**: activity category + intensity (MET-class). Layout **(UNVERIFIED - partial)**; [ringverse] notes real_steps/activity_info have unresolved constants. Gate on fixtures. [ringverse]
  - **`0x50` decode formula (PR #960 investigation, live Gen 3, 2026-07-02) [oura-rs]:** byte0 = a `state` code (activity-category, meaning unconfirmed); every following byte = one MET sample, `met = byte × 0.1` for `byte < 0x80`, else `met = 12.8 + (byte − 128) × 0.2` (two-slope: 0.1-MET resolution to 12.7, 0.2 steps above). **Plausible against six real Gen 3 captures** across two sessions - a full day from steady resting (0.9–1.1 MET) through a vigorous-activity burst (7.4 MET), everything physiologically sane, nothing negative or absurd - but **NOT ground-truth-validated** against the Oura app's own MET/step numbers. Stays Tier B: NOOP decodes it (`OuraDecoders.decodeActivityInfo` → `OuraEvent.activityInfo`, both platforms) but gates it behind `allowTierB`, logs it for investigation only, and never folds it into `OuraStreamMapping`/scoring - and NEVER derives a step count from it. `0x51`/`0x52` activity_summary stay fully undecoded (raw Tier-B bytes only).
  - **Real Steps (feature `0x0B`) server gating [open_oura-feat]:** real_steps is behind the server flag `activity/real_steps` (default **false**; `FeatureDefinitions.ActivityRealSteps`, Gen 3+), the same server-flag-off pattern as SpO2 (§7.1). This explains `0x7E`/`0x7F` never once appearing across the PR #960 live sessions - the ring isn't sending them, it is not a NOOP decode gap. `0x50` itself is an always-on base stream (not feature-gated), matching it appearing in every session.
- **`0x7E`/`0x7F` real_steps_features 1/2** (18 B each): bit-packed step features merged across the paired events. **(UNVERIFIED - partial)** [ringverse]

### 6.14 Raw PPG
- **`0x67` raw_ppg_summary** (12–13 B): start-UTC, type, scale, session header for following data. [ringverse]
- **`0x68` raw_ppg_data** (variable, delta-encoded): needs scale/accumulator from the paired `0x67`. [ringverse]
- **`0x81` cva_raw_ppg_data** (variable): delta + 24-bit absolute, session-stateful. Decode: byte `0x80` → next 3 bytes absolute u24; MSB-set byte → signed delta `b-0x100`; else signed 7-bit `+= b`. Reset on ring-reset ack or 60 s gap. [open_ring]

### 6.15 Lifecycle / state
- **`0x41` ring_start_ind** (18 B): bytes6–10 = 40-bit device id; bytes15–19 config; triggers anchor invalidation on rt regress. [ringverse][open_ring]
- **`0x43` debug_event**: ASCII text (state strings). [open_ring][open_oura-r3]
- **`0x45` state_change_ind / `0x53` wear_event**: byte6 = STATE_* enum; optional trailing UTF-8 string if payload>5. STATE enum: `0 unspecified,1 not_in_finger,2 finger_detection,3 user_active,4 user_in_rest,5 hr_user_active,6 hr_user_in_rest,7 out_of_power,8 charging,9 hibernate_low_power,20–22 production,30 hw_test`. [open_ring]
- **`0x85` rtc_beacon_ind** (10 B): `unix_s:u32 LE`, reserved 4 B, trailer u16 LE ∈ {`0x01F6`,`0x01F8`}. [open_ring]

---

## 7. Per-Generation Capability + Difference Matrix

### 7.1 Feature IDs (write target for `0x2F…0x20/0x22/0x26`) [ringverse][open_oura-feat]
| ID | Feature | Gating |
|---|---|---|
| `0x00` | Background DFU | - |
| `0x01` | Research Data (RData) | often server-blocked; returns idle status 3 [open_oura-r3] |
| `0x02` | Daytime HR | Gen3+; **live-HR path (§5.6)** |
| `0x03` | Exercise HR (AWHR) | Gen3+; cap version ≥ 2 |
| `0x04` | SpO2 | Gen3+; server-gated. `2f 02 20 04` is a read-only feature-status request; NOOP parses the `0x21` reply and reports whether automatic mode (`0x01`) is on. SpO2 never arrives as a live push; it arrives through history (§5), same as skin temp. Changing the sensor mode is an explicit device-setting mutation and is never silently bundled into connect/history setup. The Devices-screen confirmation is the only production entry point for `2f 03 22 04 01` (enable automatic), followed by a status re-read. |
| `0x05` | Bundling | - |
| `0x06` | Encrypted API | (Oura's encrypted channel - NOOP does NOT use) |
| `0x07` | Tap-to-tag | - |
| `0x08` | Resting HR | firmware-computed, no app toggle |
| `0x09` | App auth | the §3 handshake feature |
| `0x0A` | BLE mode | - |
| `0x0B` | Real steps | Gen3+; server-flag-gated |
| `0x0C` | Experimental | server-flag-gated |
| `0x0D` | CVA PPG sampler | Gen3+; server-flag-gated; feeds `0x81` |
| `0x10` | Ambient light | capability-dependent |

**Feature modes:** `0x00` off, `0x01` automatic, `0x02` requested, `0x03` requested-subscription. [ringverse]
**Feature status values:** `0x00` off, `0x01` on, `0x02` searching, `0x03` no-PPG, `0x04` cold, `0x05` movement, `0x06` identifying. [ringverse]
**Master gate:** `setFeatureMode` requires ring generation **> 2** (Gen 3+); Gen ≤2 reject all feature-mode changes. [open_oura-feat]

### 7.2 Generation differences

| Capability | Gen 3 (Horizon) | Gen 4 | Gen 5 |
|---|---|---|---|
| Service/char `…0001/2/3` | yes | yes | yes [open_oura-r5] |
| Extra chars `…0004/5/6` | no | **yes** (hardware-verified 2026-07-12; roles unconfirmed) | **yes** (roles unconfirmed) [open_oura-r5] |
| MTU | 203 [open_oura-r3] | 247 [open_ring] | 247 [open_oura-r5] |
| Framing (TLV §2) | same | same (verified vs ~953k records) [open_ring] | same [open_oura-r5] |
| Auth handshake (§3) | same | same | same; control cmds need per-conn auth, fw/serial read unauth [open_oura-r5] |
| Opcode/sub-op set | same | same | same - no new opcodes/tags [open_oura-r5] |
| Event-tag dictionary | same | reference set [ringverse] | same [open_oura-r5] |
| Live-HR feature `0x02` (§5.6) | **verified** [relue] | expected same | expected same |
| Feature-mode (`>Gen2`) | yes | yes | yes [open_oura-feat] |
| Firmware string fields | API/FW/BL/BT/MAC | same | same/extended [open_oura-r5] |
| Test firmware in corpus | FW 3.4.3 | FW 2.12.3 / hardware `ORE_06` (NOOP Android hardware, 2026-07-12) | FW 2.1.3 [open_oura-feat] |

### 7.3 NOOP decoder build guidance
1. **Single TLV parser** (§2.3) for all generations - the framing is generation-invariant. Branch only on: MTU clamp (203 vs 247) and Gen-4/5 extra-char presence (discover but ignore in v1).
2. **Generation detection:** read product info (`0x18 03 18 00 10`) → hardware id (`ORE_06` on the tested Ring 4), and firmware (`0x08`). Map to Gen 3/4/5 to set MTU and pick verified-vs-unverified layout confidence.
3. **Trust tiers in the decoder:** Tier A (verified, ship now) = TLV framing, auth, GetEvents cursor, live-HR `0x02`, `0x60`/`0x80` IBI, `0x46`/`0x69`/`0x75` temp, Ring 4 `0x6F` percentage SpO2 plus raw `0x77` DC, `0x6A` raw sleep-period measurements, `0x76` bedtime bounds, `0x42` time-sync, `0x0D` battery, `0x45`/`0x53` state, `0x6B` motion. Tier B (UNVERIFIED, fixture-gate before use) = sleep summaries/stage cadence, `0x50/0x51/0x52` activity-MET, `0x7E/0x7F` steps, legacy `0x70`/`0x7B` on Ring 4, the protobuf `0x55/0x59` interpretation (do **not** ship).
4. **HRV/sleep:** consume `0x5D` HRV, preserve `0x6A` without naming its states, and use `0x76` for stage-less sleep bounds. `0x4E` phase bits remain experimental until a real Ring 4 fixture proves cadence/direction; `0x5A` is not a canonical pinned Ring 4 tag. Never read Oura feature `0x06` (encrypted API).

---

## 8. Open Implementation Items (for the team)
- Confirm Ring-5 `…0004/0005/0006` roles before writing to them (currently unused).
- Resolve the `0x0D` battery percent-vs-voltage offset per generation via captured fixtures (§6.10).
- Validate all Tier-B sleep/activity/step layouts against real captures before enabling in scoring.
- Confirm live-HR `0x02` path on actual Gen-4/Gen-5 hardware (only Gen-3 is verified in the corpus).
