# Polar PMD implementation and qualification

NOOP implements Polar Measurement Data (PMD) without an account, cloud service, or Polar SDK
dependency. This page separates software coverage from physical-device evidence. Until a named
model, firmware, host, and NOOP build complete the procedure below, Polar deep streams remain
**Implemented / unverified**.

## What is built

- Swift and Kotlin feature-bit, setting, command, multipart control-response, and serial session
  planners.
- Bounds-checked ECG type-0, PPG type-0 raw/delta, ACC 8/16/24-bit raw plus 16-bit delta,
  and PPI type-0 decoders with matching tests on both platforms.
- Polar's nanosecond sensor clock mapped to Unix time, with a stable receive-time anchor for stale
  clocks and receive-relative backfilling for PPI frames that legitimately report timestamp zero.
- Apple CoreBluetooth and Android GATT integration inside the existing isolated generic-HR source.
- A default-off **Capture Polar PPI + motion** switch under Settings → Advanced. A reconnect is
  required after changing it.
- Standard `0x180D` HR/R-R and `0x180F` battery remain the default. With PMD enabled, PPI is only
  used after standard HR has been quiet for three seconds. ACC is stored at one vector per second.
- Android notification descriptors, battery read, and PMD feature read are serialized; Android
  GATT permits only one such operation in flight.

The wire behavior was independently implemented from Polar's official
[`BlePMDClient.kt`](https://github.com/polarofficial/polar-ble-sdk/blob/ccff6812c40fff1753c72385387d1877ca9b27b4/sources/Android/android-communications/library/src/main/java/com/polar/androidcommunications/api/ble/model/gatt/client/pmd/BlePMDClient.kt),
[`BlePmdClient.swift`](https://github.com/polarofficial/polar-ble-sdk/blob/ccff6812c40fff1753c72385387d1877ca9b27b4/sources/iOS/ios-communications/Sources/iOSCommunications/ble/api/model/gatt/client/pmd/BlePmdClient.swift),
and [time-system documentation](https://github.com/polarofficial/polar-ble-sdk/blob/ccff6812c40fff1753c72385387d1877ca9b27b4/documentation/TimeSystemExplained.md).

## Deliberate limits

ECG and PPG packets are decoded and fixture-tested, but NOOP does not start or durably record those
high-rate streams yet. Writing 130–200 samples per second into the current per-second health store
would either discard data or grow it by hundreds of megabytes per day. The next safe step is a
bounded, user-started waveform capture with a duration/storage cap and an explicit export/delete UI.

Gyroscope, magnetometer, skin-temperature, offline recording, and SDK-mode data frames are
capability-recognized but not decoded. Unsupported frames fail closed and are logged; they never
become fabricated health values.

## Hardware qualification

Record one result per model + firmware + host:

1. Confirm standard HR, R-R, and battery with **Capture Polar PPI + motion** off.
2. Turn the switch on, reconnect, and export the strap log. It must list PMD capabilities and
   successful starts for every advertised requested stream without interrupting standard HR.
3. Wear the device for 30 minutes. Confirm plausible live HR/R-R and that the gravity table advances
   at no more than one row per second.
4. Temporarily exercise the standard-HR-silent fallback in a controlled debug run and confirm PPI
   supplies plausible HR/R-R without duplicates when standard HR resumes.
5. Move out of range and back, then force-stop/relaunch. Both standard and opted-in PMD streams must
   recover without resetting or re-pairing the device.
6. Compare HR/R-R with Polar's visible reading or a reference sensor. Record exact model, firmware,
   phone/Mac, OS, NOOP commit/build, date, counts, and a privacy-redacted log.
7. Run the Swift `PolarPMDTests`, Android `PolarPmdTest`, app builds, and hosted CI for the exact
   tested commit.

H10, Verity Sense, and OH1 are separate qualification rows: one passing model does not verify the
others or a different firmware family.
