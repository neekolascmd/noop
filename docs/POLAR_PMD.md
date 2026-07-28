# Polar PMD implementation and qualification

NOOP has an independent, account-free implementation of Polar Measurement Data (PMD), based on the
public wire behavior in the official
[`polarofficial/polar-ble-sdk`](https://github.com/polarofficial/polar-ble-sdk). NOOP does not link,
bundle, or copy the Polar SDK.

## Implemented boundary

The pure Swift `PolarProtocol` package and its Kotlin twin implement:

- PMD feature discovery, settings parsing, start/stop commands, multipart control responses, and
  strict one-command transactions;
- raw ECG type 0, raw and compressed PPG type 0, raw ACC types 0/1/2, compressed ACC types 0/1,
  PPI type 0, and bounded LSB-first delta decompression;
- sensor-to-host clock mapping with a guarded Polar-epoch path and a stable live-session fallback;
- fail-closed limits for malformed lengths, unsupported setting widths and frame types, excessive
  sample counts, timestamp errors, and delta overflows.

The Apple and Android app paths automatically detect PMD alongside standard heart rate. After both
PMD subscriptions succeed, NOOP reads capabilities and starts PPI and accelerometer when advertised.
All commands require both a matching control response and a successful write callback; either
callback order is accepted, and each transaction has a timeout.

PPI is accepted only when Polar marks the beat valid. It becomes an HR/R-R fallback after three
seconds without a standard `0x2A37` heart-rate notification, avoiding duplicate beats. Accelerometer
data is reduced to one vector per second for the existing motion store.

ECG and PPG packets are decoded but are not requested or persisted by the app yet. Their sample rates
need a bounded, sub-second waveform store rather than the current per-second gravity table.

PMD is additive and optional. A PMD subscription, read, write, response, or decode failure disables
deep streaming for that connection without interrupting standard HR or battery. Stop, disconnect,
and reconnect reset all PMD transport, transaction, decoder, and clock state.

## Automated evidence

- Swift and Kotlin use matching protocol vectors for features, settings, multipart responses,
  planner sequencing, callback-order races, ECG, PPG, ACC, PPI, delta compression, malformed input,
  and device-clock fallback.
- The package test suite and Android unit tests run in CI.
- macOS and iOS simulator app builds verify the Apple integration compiles; Android unit builds
  verify the Kotlin integration compiles.

This is software evidence, not a physical-hardware support claim.

## Physical-device qualification

Record a separate result for every model, firmware, host OS, and NOOP build:

1. Pair the device normally and confirm standard live HR, R-R, and battery continue before PMD setup.
2. Save a redacted log containing PMD service discovery, both subscription successes, advertised
   measurement types, selected settings, and successful stream starts.
3. Wear the device for at least 30 minutes. Confirm plausible PPI and motion rows, no duplicate beat
   cadence when standard HR is active, and no rejected-frame log flood.
4. Force-stop/quit NOOP, relaunch it, and confirm a clean PMD setup and live stream without stale
   callbacks or duplicated commands.
5. Move out of Bluetooth range and return. Confirm bounded reconnect, a fresh PMD session, and
   uninterrupted recovery after the link returns.
6. Disable or provoke failure in the PMD lane and confirm standard HR and battery remain live.
7. Compare HR and R-R against the vendor app or a reference sensor over the same interval.

For H10, additionally confirm ECG is advertised even though NOOP does not start it yet. For Verity
Sense and OH1, record whether PPG, PPI, ACC, and gyroscope are advertised. Do not infer one model's
status from another.

Move a model/host cell from **Implemented** to **Partial** only after the tuple and results are recorded
in [Hardware support](HARDWARE_SUPPORT.md). **Verified** requires a reproducible result another
maintainer can repeat and the still-missing waveform lane does not inherit verification from PPI/ACC.
