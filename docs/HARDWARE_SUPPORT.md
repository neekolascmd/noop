# Hardware support and verification matrix

This page separates code that exists from behavior that has been reproduced on a named device. A
Verified label applies only to the model and capability recorded below; missing tuple fields are
called out explicitly, and the label is not a
promise that every firmware revision behaves the same way.

Status key:

- **Verified** — reproduced on physical hardware with enough evidence to identify the test tuple.
- **Partial** — some capabilities were reproduced, but the full row or current app build was not.
- **Implemented** — code and automated tests exist; current physical-hardware evidence is missing.
- **Planned** — researched or documented, but the production lane is not built.
- **Unknown** — the repository has no model-specific evidence. Unknown is not a failure.

## WHOOP capability matrix

| Device | Pairing | Live HR / R-R | History sync | Sleep | Workouts | Haptics / alarms |
|---|---|---|---|---|---|---|
| **WHOOP 4.0 / 4C** | **Verified** — 4.0 handshake | **Verified** | **Verified** — v24 and v25 layouts are supported | **Verified** on the supported layouts; stages remain NOOP estimates | **Partial** — detected from decoded HR/motion; NOOP does not import a firmware workout object | **Partial** — haptic preset and clock behavior are hardware-backed; a complete scheduled-alarm lifecycle is not recorded |
| **WHOOP 5.0** | **Verified** — encrypted just-works bond plus `CLIENT_HELLO` | **Verified** | **Verified** — progress requires per-chunk history acknowledgements | **Partial** — duration and stages remain experimental when overnight inputs are sparse | **Partial** — derived from decoded HR/motion, not a firmware workout object | **Partial** — the Maverick buzz command is hardware-verified; a complete scheduled-alarm lifecycle is not recorded |
| **WHOOP MG** | **Unknown** model-specific result | **Partial** — documented together with 5.0, without a complete MG test tuple | **Unknown** model-specific result | **Implemented / unverified** — uses the 5/MG path and retains the same analysis limits | **Implemented / unverified** | **Partial** — a real-MG capture identified the Maverick opcode, but firmware, host, app build, and full alarm flow were not recorded |

Firmware-sensitive behavior matters here:

- WHOOP 4.0 history records can be v5/7/9/12, v24, or v25. Decode by the record version, never only
  by the strap generation. Firmware `41.17.6.0` also needs the 9-byte `SET_CLOCK` body; the newer
  8-byte form did not latch on that device.
- WHOOP 5.0 firmware `50.38.1.0` reports its version through `GET_HELLO` and uses direct-percent
  battery command responses. Recorded 5/MG-family captures include v18/v26 and, on separately
  documented newer firmware, v20/v21 records; do not assume one firmware emits every layout.
- WHOOP 5/MG encrypted features need the strap's single BLE bond. Bond-free standard heart rate can
  work while history, events, and haptics remain unavailable, so live HR alone does not prove pairing.

## Recorded physical-hardware evidence

An unrecorded field stays unrecorded. The app/build column names the artifact actually exercised; it
does not substitute today's version for an older capture.

| Device / evidence | Firmware or record layout | Host | App or tool build | Most recent recorded verification | Tester and current hardware availability |
|---|---|---|---|---|---|
| WHOOP 4C clock | `41.17.6.0`; 9-byte `SET_CLOCK` latched where the 8-byte form did not | Linux / BlueZ capture host | `tools/linux-capture` from the pre-handoff repository; exact commit and released app version not recorded | **2026-06-12** | Recorded by prior maintainer documentation; capture operator not separately named. Device availability after handoff: **unknown** |
| WHOOP 4C v24 offload | `41.17.6.0`; 1,704 CRC-valid v24 frames | Linux / BlueZ capture host | `tools/linux-capture` from the pre-handoff repository; exact commit and released app version not recorded | Date not recorded | Recorded by prior maintainer documentation; capture operator not separately named. Device availability after handoff: **unknown** |
| WHOOP 4.0 v25 decode | v25, exact firmware not recorded | Apple app path; exact host version not recorded | NOOP **v1.95** | Date not recorded | Community report provenance is referenced as issue `#30`; current device availability: **unknown** |
| WHOOP 5.0 pairing, live data, history, and command responses | `50.38.1.0` command responses; v18/v26 on the recorded 5.0, with v20/v21 documented separately for newer 5/MG firmware | Linux / BlueZ capture host; Apple pairing path also documented | Linux capture tools, exact commit not recorded; Apple `CLIENT_HELLO` pairing behavior documented from **v1.5**. Current 8.2.x app not yet re-verified in a recorded run | Date not recorded | Recorded by prior maintainer documentation; capture operator not separately named. Device availability after handoff: **unknown** |
| WHOOP 5.0 Maverick haptic | Firmware not recorded in the haptic result | Linux / BlueZ capture host | `tools/linux-capture`, exact commit and released app version not recorded | **2026-06-12** | Recorded by prior maintainer documentation; capture operator not separately named. Device availability after handoff: **unknown** |
| WHOOP MG Maverick haptic command | Firmware not recorded | Host not recorded | Build not recorded | Date not recorded | Real-MG capture documented; tester and current device availability: **unknown** |
| Oura Ring 4 advertisement, GATT, bond, and identity | FW `2.12.3`; API `2.1.0`; bootloader `1.0.1`; Bluetooth `5.0.15`; hardware `ORE_06` | Solana Mobile Saga, Android 16 | nRF Connect **4.29.1** plus NOOP **8.2.1-debug**, qualification commit `8de785e` | **2026-07-12** | Recorded by the current maintainer; ring remains available. Standard BLE bond, direct reconnect, MTU 247, and both privacy-safe identity reads passed. No reset, NOOP key install, application auth, live stream, or history test completed |

Evidence details live in [BLE reverse engineering](BLE_REVERSE_ENGINEERING.md), including the
[5.0 bond and session](BLE_REVERSE_ENGINEERING.md#bonding-and-the-puffin-session-hardware-verified),
[5.0 history flow](BLE_REVERSE_ENGINEERING.md#whoop-50-historical-offload-hardware-verified),
[4.0 firmware check](BLE_REVERSE_ENGINEERING.md#whoop-4-firmware-drift-check--this-device-showed-no-drift),
and [haptic and clock results](BLE_REVERSE_ENGINEERING.md#6-haptic-preset-discovery-get_all_haptics_pattern).

## Other device and import sources

These lanes must not inherit a green status from the WHOOP rows. Automated parser tests prove stable
software behavior; they are not physical-device verification.

| Source | Lane | Current evidence | Hardware availability / next verification |
|---|---|---|---|
| Generic BLE heart-rate devices (Polar, Wahoo, Coospo, Garmin HRM, Amazfit HR broadcast) | Standard `0x180D` / `0x2A37` live HR and R-R | **Implemented** since v3.8.0; no per-model firmware matrix is recorded | Devices not inventoried. Report each model separately before calling it verified |
| Xiaomi Smart Band 8 / 9 / 10 | Offline Mi Fitness SQLite import | **Partial** — one real Mi Band 10 export (450 days / 545 sleeps) verified the import and stage mapping; exact firmware, host, build, date, and tester were not recorded | Current Band 10 availability: **unknown**; Bands 8 and 9 need their own real exports |
| Xiaomi Smart Band live BLE | Encrypted protobuf-v2 BLE sync | **Planned** — protocol researched, decoder not built | Requires a physical band, GATT dump, firmware, and iterative foreground sync testing |
| Oura | Local BLE | **Partial / experimental** — Ring 4 on Android now has a recorded advertisement, standard bond, direct reconnect, MTU 247, service/characteristic discovery, and firmware/hardware identity | Ring 4 is currently available on a Solana Mobile Saga. Application auth, live HR/R-R, reconnect, and history still require either the existing Oura application key or a separately authorized reset/adopt test |
| Oura / Fitbit / Garmin | Offline wellness-export import | **Implemented** with shared Swift/Kotlin golden fixtures; this verifies parsers, not current vendor hardware or export apps | Capture fresh, privacy-redacted exports and record vendor app/export versions |
| Polar H10 / Verity Sense / OH1 deep streams | PMD ECG / PPG / ACC / PPI | **Planned** — protocol documented, production decoder not built; H10 issue `#421` remains hardware-gated | No maintainer device inventory recorded |
| Garmin and Amazfit / Zepp deep BLE | Vendor BLE history and sensors | **Planned** | Needs owned hardware and clean-room captures; no current device inventory recorded |
| Fitbit / Google | Google Health import | **Planned** | Needs a registered API path and real-account verification; no hardware claim |

See [Device support roadmap](DEVICE_SUPPORT_ROADMAP.md) for protocol research and future lanes. See
[Analytics golden fixtures](ANALYTICS_FIXTURES.md) for cross-platform software parity.

## Oura graduation gate

Oura support graduates per **ring generation + host platform**, not as one blanket claim. A Ring 3
result does not make Ring 4/5 supported, and an Apple result does not prove Android. Starting with the
qualification build, each connection safely requests the pre-auth firmware and hardware pages and adds
lines like these to the exportable strap log:

```text
Oura: identity selected=Oura Ring 4 firmware=2.12.3 api=2.1.0 bootloader=1.0.1 bluetooth=5.0.15
Oura: identity hardware=ORE_06
```

NOOP never requests the ProductInfo serial page for this diagnostic, and the firmware decoder discards
the response's Bluetooth-address bytes. A generation/platform cell can move from Experimental to
Supported only after all of the following are recorded on a current release:

1. Two reproducible reports from independent rings, with exact firmware, hardware family, host, OS,
   NOOP build, date, and privacy-redacted evidence. At least one reporter must be available to retest.
2. Factory-reset adoption **and** a later reconnect with the stored key pass without another reset.
3. Live HR and R-R remain active through a 30-minute worn session, an out-of-range reconnect, and an app
   relaunch. Values are compared with a simultaneous reference sensor or the ring's own visible reading.
4. An overnight/24-hour run resumes history after reconnect and records plausible UTC timestamps for the
   available HRV, sleep-phase, temperature, and SpO2 events. Missing capabilities are reported, not inferred.
5. Wrong-key, missing-key, unavailable-ring, and interrupted-adoption paths fail visibly and never claim
   streaming or persist a key before the ring acknowledges it.
6. The Swift and Kotlin protocol suites pass, and the tested host app builds in CI.

Tier-B activity, step, and sleep-summary layouts may remain experimental after a live/history transport
cell graduates; they are separately fixture-gated and cannot feed scoring until validated.

## Reproducible verification report

Use the [hardware verification issue form](https://github.com/neekolascmd/noop/issues/new?template=hardware-verification.yml).
One report should cover one model + firmware + host + app build. Repeat a report after any of those
four fields changes.

Every report must include:

1. Exact device model and firmware; say how the firmware was read.
2. Host hardware, OS version, BLE adapter or phone model, and install method.
3. Exact NOOP release or commit SHA. “Latest” is not reproducible.
4. Pairing preconditions, including whether another phone/app still held the bond.
5. A result for pairing, live HR/R-R, history sync, sleep, workouts, haptics, and alarms: `PASS`,
   `FAIL`, or `NOT RUN` with a reason.
6. Reproduction steps and privacy-safe evidence: timestamps/counts, redacted strap log, and any
   firmware-sensitive response. Never attach a serial, session token, account export, or raw personal
   biometric history.
7. Verification date, tester attribution, and whether maintainers can retest with that hardware.

For Oura, copy the `Oura: identity ...` lines from the redacted strap log and include the adoption,
reconnect, relaunch, 30-minute live session, and overnight/24-hour results required by the graduation gate.

Maintainers should update this matrix only after reading the evidence. A community report may move a
cell from Unknown to Partial; Verified requires a reproducible tuple and a result another maintainer
or independent reporter can repeat.
