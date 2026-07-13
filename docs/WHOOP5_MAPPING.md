# WHOOP 5 / MG protocol mapping status

This is the evidence ledger for finishing WHOOP 5/MG support. “Mapped” means a field has an on-wire
offset, type and hardware-backed meaning. “Preserved” means NOOP retains the bytes but does not assign a
health meaning yet. Proprietary WHOOP cloud scores are out of scope; NOOP computes its own metrics from
raw signals.

## Current coverage

| Surface | Status | Evidence / remaining work |
|---|---|---|
| Puffin framing and CRC | Mapped | CRC16-Modbus header, CRC32 body, fragmentation and packet aliases are fixture-tested. |
| Pairing / `CLIENT_HELLO` | Mapped for WHOOP 5 | Re-qualify current app builds; MG still needs a complete model-specific run. |
| Live HR / R-R | Mapped | Standard `0x2A37` is the authoritative persisted live stream. |
| Battery | Mapped | Standard 0x2A19 plus captured command/event payloads. |
| History range / chunk ACK | Mapped | Cursor-bearing offload and per-chunk acknowledgements are hardware-backed. |
| v18 per-second summary | Partially mapped | HR, R-R, gravity, dynamic acceleration, skin temperature, step counter, activity class and raw status fields. Several status/optical fields remain neutral. |
| v26 optical history | Partially mapped | Unix timestamp and 24 Hz signed PPG waveform are proven; surrounding bytes and optical channel identity remain neutral. |
| v20 / v21 bulk history | Preserved | Header and channel arrays decode on Swift and Kotlin. Channel-to-sensor identity and scale require labelled captures. |
| Type 52 historical IMU | Preserved | Apple and Android retain one CRC-valid safety sample per session before trim; opt-in capture retains the complete corpus. Layout is not assigned yet. |
| Types 51 / 53 / 54 / 55 | Raw | Need characteristic-labelled real frames and request/response context. |
| R22 configuration | Transaction observed | Fifteen documented writes receive responses, but no separate live stream exists. Controlled before/after firmware comparisons remain. |
| Sleep / workouts | Partial | v18 motion supports local analysis; sparse/unknown bulk records prevent WHOOP 4-equivalent consistency. |
| Alarms / haptics | Partial | Maverick buzz is hardware-backed; scheduled fire and MG lifecycle still need captures. |

## Capture requirements

A useful capture must retain:

- full inbound and outbound proprietary frames;
- source characteristic and direction;
- one connection/session identifier;
- offload versus live phase;
- firmware, wear state, battery, wall time and simultaneous standard-profile HR;
- a matched strap log describing the actions performed.

Apple capture schema 2 records that context in append-only JSONL. Apple and Android now use a separate
reassembler per notify characteristic, capture the session hello and later command writes, and accept both
fixture-array JSON and JSONL imports. All capture files contain personal biometric history and should be
handled as sensitive data.

## Labelled hardware sequence

Run each phase long enough to cover several records and write down exact wall-clock start/end times:

1. Worn and motionless for five minutes.
2. Walk at a steady pace for five minutes.
3. Move only the strap arm for two minutes.
4. Remove the strap and leave it still for five minutes.
5. Put it back on and remain still for five minutes.
6. Let history sync completely.

Repeat the identical sequence before and after the optional R22 configuration. Do not infer a field from
one changing byte: require repeatability across at least two devices or firmware versions, physical-range
checks, and a committed real-frame fixture before the field can feed `Streams` or scoring.

## Analysis

```sh
swift run --package-path Packages/WhoopProtocol whoop-decode --family whoop5 capture.json
```

The decoder accepts Apple JSON arrays and Android JSONL. Its summary groups frames by decoded packet type,
historical layout version, byte length and characteristic—the minimum worklist for an unmapped capture.
