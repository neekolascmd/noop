# NOOP - Garmin Multi-Link v2 Protocol Notes

**Status:** Experimental implementation; software-tested, not hardware-qualified.
**Scope:** Direct, local Garmin Multi-Link v2 transport and conservative realtime decoding.
**Platforms:** Android transport; platform-pure Swift and Kotlin protocol cores. Apple app transport is
not implemented yet.

This lane is separate from Garmin **Broadcast Heart Rate**, which uses the standard Bluetooth Heart
Rate service and remains available as the stable live-HR option. Local sync does not require Garmin
Connect, a Garmin account, or Garmin servers. The watch still owns its firmware and recorded data.

## Product and licensing boundary

Garmin's official [Health SDK](https://developer.garmin.com/health-sdk/overview/) can provide direct
Android/iOS access without Garmin servers, including all-day and realtime streams, but it is a licensed
enterprise product. NOOP does not ship that SDK or claim its feature set. This implementation is an
independent interoperability client for factual BLE wire behavior.

Protocol facts were corroborated against
[Gadgetbridge's Garmin protocol notes](https://gadgetbridge.org/internals/specifics/garmin-protocol/),
the [current Gadgetbridge Codeberg source](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/commit/cc0b7700816cda6c408043b7ba9113445be55a78/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/), and
[garmin-bridge](https://github.com/wh1le/garmin-bridge). Those projects are AGPL-3.0. NOOP copies no
source, class structure, tests, or binaries from them. The code and synthetic vectors here were written
independently from the observed wire facts below.

## Implemented wire boundary

### GATT

- Multi-Link service: `6A4E2800-667B-11E3-949A-0800200C9A66`.
- Receive candidates: `6A4E2810…` through `6A4E2814…`.
- The corresponding send characteristic is `+0x10`: `6A4E2820…` through `6A4E2824…`.
- The client selects the first complete receive/send pair, enables the receive CCCD, and serializes all
  writes. Every notification and write begins with a one-byte logical service handle.
- Android requests MTU 247 and fragments application payloads to `MTU - 3 - 1` bytes after the handle.

The scanner accepts the exact advertised service or a Garmin-family device name because some firmware
does not advertise the proprietary service before pairing. It does not list unrelated nearby BLE
devices. Connecting is explicit and user-initiated; Android owns the visible secure-pairing prompt.

### Handle management

Handle `0` is management. The implemented request types are:

| Value | Meaning |
|---:|---|
| `0` | register request |
| `1` | register response |
| `2` | close handle request |
| `3` | close handle response |
| `4` | unknown/reserved |
| `5` | close all request |
| `6` | close all response |

The default observed client ID is the little-endian 64-bit value `2`; it is an identifier, not a secret.
After a close-all response, NOOP registers only the services it consumes:

| Service | Code | Current treatment |
|---|---:|---|
| GFDI | `1` | Session envelope and minimal replies |
| Realtime heart rate | `6` | `type:u8, hr:u8, resting:u8`; optional trailing `FF FF` only |
| Realtime steps | `7` | `steps:i32LE, goal:i32LE`; exact 8 bytes, nonnegative |
| Realtime HRV | `12` | `rr:i16LE, unknown:i32LE`; RR exposed only at 200–3000 ms |
| Realtime SpO₂ | `19` | signed value + Garmin timestamp; 1–100 percent only |
| Realtime respiration | `21` | signed byte; 1–120 breaths/min only |

Accelerometer (`16`) and Body Battery (`20`) decoders retain nonempty payloads as opaque bytes in the
pure protocol layer. The Android source does not register them, store them in an unrelated table, or
invent field meanings.

### COBS and GFDI

GFDI uses standard COBS content with both a leading and trailing `0x00`. The bounded streaming decoder
handles frames split or coalesced across BLE notifications and recovers after malformed or oversized
input.

Inside COBS, the GFDI envelope is:

```text
[length:u16LE][message id or compact id/sequence][payload][CRC16:u16LE]
```

CRC16 uses the reflected polynomial `0xA001`. A compact message header may encode IDs 5000–5255 and a
five-bit sequence. The golden vector `09 00 08 98 28 01 10 D7 F5` decodes as message 5008, sequence 24,
payload `28 01 10`.

The minimal session responder supports device information, configuration, authentication negotiation,
current time, and the Sync Ready event. It advertises zero phone capabilities unless a caller explicitly
supplies implemented ones. Notification-subscription and protobuf requests receive an honest
`unsupported` response. Unknown requests are retained only as bounded diagnostics; they are not ACKed
as if implemented.

## Persistence semantics

- HR is stored at receipt time only for 30–220 bpm.
- R-R is stored at receipt time only for 200–3000 ms. The live UI receives R-R only alongside a recent
  real HR sample; NOOP never injects a fake HR to make an R-R packet visible.
- Steps retain the watch's nonnegative cumulative count.
- SpO₂ uses the watch timestamp only when it falls between 2023-11-01 and one day ahead of the current
  time. It is stored explicitly as `tenths_percent`, not mislabeled as raw optical ADC.
- Respiration is kept as deterministic diagnostic event JSON because the existing respiration sample
  table is for a different raw waveform. It is not silently retyped.
- Invalid, unavailable, opaque, and unknown values remain absent. Diagnostics log a bounded first
  occurrence rather than personal raw payloads.

All rows are partitioned by the paired Garmin device ID in NOOP's local database. This source makes no
network request.

## Qualification gate

The implementation must remain Experimental until an owned watch records all applicable evidence:

1. Exact watch model, firmware, Android host/OS, NOOP commit/build, and verification date.
2. User-confirmed Android bond and a privacy-redacted GATT inventory proving the selected `281x/282x`
   pair.
3. Close-all response plus assigned GFDI and realtime handles for that exact tuple.
4. Minimal GFDI handshake completion after a fresh app process and after an ordinary reconnect.
5. Worn live HR and HRV compared with the watch display or a reference sensor.
6. Steps compared over a recorded interval without assuming day-reset or wrap behavior.
7. SpO₂ and respiration captured only when the watch actually emits them, with timestamps/ranges checked
   against an independent display or reference. A missing stream stays missing.
8. Out-of-range reconnect, 30-minute continuous run, and battery/power impact observation.
9. A separate tuple for each model/firmware family promoted in the hardware matrix.

Apple requires its own CoreBluetooth transport and physical iPhone/macOS qualification. Android proof
does not promote Apple support.

## Software verification

```bash
cd Packages/GarminProtocol
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test

cd ../../android
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
./gradlew :app:testFullDebugUnitTest --tests 'com.noop.garmin.*'
```

These checks prove deterministic framing, validation, mapping, and host compilation. They do not prove a
physical Garmin connection.
