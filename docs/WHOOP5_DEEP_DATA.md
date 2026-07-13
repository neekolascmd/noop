# WHOOP 5.0 / MG deep data — the "R22" unlock

**Status:** experimental, opt-in. The 15 writes have been acknowledged on hardware; they do not create a
separate live R22 stream. WHOOP 5/MG deep records arrive through the normal history offload.
**Tracking:** [#174](https://github.com/neekolascmd/noop/issues/174).

## The problem

A bond-free WHOOP 5.0 / MG connection exposes **only live heart rate** over standard `0x2A37`. A full
encrypted bond unlocks the proprietary command channels and normal history offload. NOOP now verifies
pairing, live HR/R-R and history, but some firmware returns sparse or no history and several bulk sensor
layouts still lack channel identity. That missing interpretation—not merely whether a flag was written—is
the largest remaining parity gap.

## Why — the feature-flag gate

The official app writes a short burst of **persistent feature-flag config values** after its hello
handshake. The most recognizable name is `enable_r22_packets`; "R22" is an optical/PPG data-product
format, not a hardware revision. A strap has acknowledged all 15 documented writes, but controlled
captures later established that the sequence does **not** start a separate live stream. Type `0x2F`
records are historical offload, including frames observed while another client is pulling the backlog.

This was reached independently three ways, which is why we trust it:

| Source | Method | What it gives |
|---|---|---|
| [judes.club — "Cracking the WHOOP 5 Bluetooth Protocol"](https://judes.club/writing/cracking-the-whoop-5-bluetooth-protocol/) + [interactive spec](https://judes.club/experiments/whoop5/) | iOS HCI capture of the official app | The full frame format + the exact 15-flag enable sequence **with values**. Our `Whoop5Config` golden test is validated byte-for-byte against its frame-builder. |
| [Asherlc/dofek](https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md) | Android APK decompilation | The config opcodes (`0x73 START_DEVICE_CONFIG_KEY_EXCHANGE`, `0x78 SET_FF_VALUE`) and the same key names/values. |
| A community BTSnoop capture (#174) | Bluetooth HCI log of the official app on a real strap | Independently surfaced the same `enable_r22_*` console report + the channel layout. |

## Channel layout (5.0 / MG)

| Channel (UUID suffix on `fd4b0001-…`) | Direction | Carries | NOOP |
|---|---|---|---|
| `0x2A37` standard HR | strap → app | live heart rate | subscribed ✅ |
| `fd4b0002` | app → strap | `0xAA`-framed commands | writes here ✅ |
| `fd4b0003/4/5/7` | strap → app | `0xAA`-framed responses + data + console | subscribes to all four ✅ |

NOOP writes commands and subscribes to every data channel. The remaining blocker is mapping and
qualifying the record layouts each firmware actually returns, not opening another notification channel.

## The frame format

Commands use the maverick/puffin envelope NOOP already implements
(`Framing.puffinCommandFrame` / `crc16Modbus` + `crc32`):

```
[0xAA][0x01][declLen u16 LE][field=0x0100][CRC16-MODBUS of the 6 header bytes]
  [inner: 0x23 type][seq][cmd][b3][payload…]
[CRC32 of inner, u32 LE]
```

- **`b3` (4th inner byte)** matters: GET_HELLO / SET_CONFIG want `0x01`; GET_DATA_RANGE /
  SEND_HISTORICAL want `0x00`. NOOP carries `b3` as the first payload byte (so `sendHistoricalData`
  with `[0x00]` is correct).
- **Write WITH RESPONSE** — write-no-response is silently dropped by the strap.

## The enable sequence (`Whoop5Config`)

One `SET_CONFIG` (cmd `0x78`) per flag; the 40-byte body is the flag name as ASCII NUL-padded to 32
bytes, the value byte (an ASCII `'1'`/`'2'`) at offset 32, then 7 zeros. The exact ordered set, with
values, is in [`Whoop5Config.swift`](../Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift)
and [`Whoop5Config.kt`](../android/app/src/main/java/com/noop/protocol/Whoop5Config.kt), golden-tested on
both platforms. `enable_r22_packets` names the type-`0x2F` history product; controlled observations do
not show it opening a separate live stream. The other keys appear to tune channel selection, wear
detection and sleep behaviour, but those effects still require controlled before/after qualification.

## How NOOP uses it (opt-in, reversible)

- A **default-off** Settings → Experimental toggle, separate from the read-only probes because this one
  *writes* to the strap.
- A manual **"Send R22 configuration"** button (not auto-run on connect), enabled only when a
  5/MG is **bonded and worn** (the R22 stream is on-wrist gated).
- The 15 flags are written with-response, ~80 ms apart. NOOP disables repeat taps while the attempt is
  active and counts only unique, CRC-valid responses correlated to sequences it actually sent.
- It's **reversible** — it only changes which data the strap chooses to emit — and is the same thing the
  official app does on every connect.
- **iOS / Android only on real hardware:** macOS CoreBluetooth can't complete the authenticated SMP bond
  the command characteristic requires, so the write path is unavailable on Mac.

## Honest limits

- **No cloud scores.** Recovery/strain/sleep *scores* are computed in WHOOP's cloud and no public
  project has reproduced them. What the unlock buys is the **raw inputs** (high-rate HR, motion, fuller
  history) — which is exactly what NOOP needs, since NOOP computes its own scores on-device.
- **The sequence is not required for every firmware.** Normal `get_data_range` / `send_historical_data`
  already returns type-47 history on verified WHOOP 5 hardware. Keep the configuration opt-in until a
  controlled before/after capture proves which record families it changes on each firmware.
- **The remaining decode work is layout-specific.** v18 supplies per-second HR/R-R, gravity, temperature,
  steps and status fields; v26 supplies a 24 Hz PPG waveform. v20/v21 bulk channels and type-52 historical
  IMU are preserved but intentionally have no invented sensor identity or unit yet.

## How to help (5.0 / MG owners)

1. Turn on **Test Centre → Record puffin frames to a file** before connecting.
2. With the strap worn and fully bonded, let one normal history sync finish before changing R22 flags.
3. On iPhone/Android, optionally send **WHOOP 5/MG R22 configuration**, then repeat the same labelled
   movement/rest/off-wrist sequence and sync again.
4. Export the matched raw capture and strap log. Raw captures contain personal biometric history; share
   them privately or minimize them before posting publicly.
5. Use `whoop-decode capture.jsonl` (Apple/Android JSONL or a fixture array) to summarize packet type, layout version,
   frame size and characteristic before promoting any inferred field into scoring.

Credit to **judes.club**, **Asherlc/dofek**, and **b-nnett/goose** for the public protocol work this
builds on.
