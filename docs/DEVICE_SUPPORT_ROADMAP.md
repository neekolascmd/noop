# Device support — roadmap & protocol notes

NOOP's north star is **WHOOP**, fully supported. Everything else is an opportunistic, easy-first
expansion that must never regress the WHOOP experience. This file records where each additional
source stands and the protocol facts we've verified, so the next build can pick up cleanly.

Roadmap status means a code lane is shipped, researched, or planned; it is not a physical-hardware
claim. Exact device, firmware, host, build, and capability evidence belongs in the
[hardware support matrix](HARDWARE_SUPPORT.md).

| Source | Status | How |
|--------|--------|-----|
| **WHOOP 4 / 5 / MG** | ✅ Shipped, primary | Local BLE decode |
| **Generic BLE heart-rate straps** (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio HR-broadcast) | ✅ Shipped (v3.8.0), live HR + RR | Standard HR service `0x180D` / `0x2A37` |
| **Fitness Age / Vitality / Body Age** | ✅ Shipped (v4.0.0) | On-device, from the data above |
| **Xiaomi Smart Band 8 / 9 / 10** (Mi Band) | ✅ Shipped, **import lane** | Read the Mi Fitness iOS app's own SQLite, on-device (below) |
| **Xiaomi Smart Band — live BLE sync** | 🔬 Protocol researched, decoder not built | Mi protobuf-v2 over BLE GATT + `encryptKey` handshake (below) — hardware-gated |
| **Polar deep streams** (ECG / PPG / ACC / PPI) | 🧪 Implemented, hardware-unverified | Cross-platform PMD control/data decoders; opt-in PPI + ACC live lane (below) |
| **Garmin** (sleep / HRV / Body Battery / SpO₂ / FIT) | 📋 Researched, not built | Local BLE re-derive (Gadgetbridge-informed, **never** GPLv3 copy) |
| **Amazfit / Zepp** (incl. Helio deep) | 📋 Researched, not built | Encrypted Huami BLE — needs a one-time **user-pasted** vendor key (NOOP never logs into the vendor cloud) |
| **Oura** | 🧪 Experimental; Ring 4 partially qualified on Android and macOS | Local BLE protocol package and platform sources; see the per-host graduation matrix before making a support claim |
| **Fitbit / Google** | 📋 Researched, not built | Build against **Google Health** API (Fitbit Web API sunsets Sept 2026) — off-by-default import |

## Polar Measurement Data (PMD) — verified protocol

Source: the official [`polarofficial/polar-ble-sdk`](https://github.com/polarofficial/polar-ble-sdk)
was used as a wire-behavior reference. NOOP independently implements the protocol and does not bundle
Polar's SDK. This can read ECG/PPG/ACC/PPI from a Polar H10 / Verity Sense / OH1 the user owns,
account-free, on top of the standard HR service.

- **Service UUID:** `FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8`
  - **Control Point char:** `FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8` (write + indicate)
  - **Data (MTU) char:** `FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8` (notify)
- **Measurement-type codes (u8):** ECG `0`, PPG `1`, ACC `2`, PPI `3`, GYRO `5`, MAGNETOMETER `6` (mask `0x3F`).
- **Control-Point opcodes:** GET_MEASUREMENT_SETTINGS `1`, REQUEST_MEASUREMENT_START `2`, STOP_MEASUREMENT `3`.
  Online start requests use the measurement byte followed by `[SettingType, valueCount, values…]`
  blocks, where SampleRate is `0x00`, Resolution `0x01`, and Range is `0x02`. `valueCount` is a count
  of fixed-width values, not a byte length.
- **Data frame:** `data[0]` = measurement type; `data[1..8]` = 64-bit little-endian timestamp (ns since
  2000-01-01 UTC); `data[9]` = frame type (`& 0x7F` = type, `& 0x80` = delta-compressed); payload from `data[10]`.
  - **ECG** type-0: 24-bit signed µV samples.
  - **ACC** type-0/1/2: 8/16/24-bit signed X/Y/Z (milli-g).
  - **PPI** type-0: `byte0` HR, `bytes1-2` peak-to-peak interval (ms), `bytes3-4` error estimate (ms),
    `byte5` flags (bit0 invalid, bit1 poor/no skin contact, bit2 contact unsupported).
  - **PPG** type-0: three 24-bit channels + ambient.
- **Per-model streams:** **H10** = ECG (130 Hz) + ACC + HR + RR (no PPG); **Verity Sense / OH1** =
  PPG + PPI + ACC + GYRO + HR (no ECG).

**Current implementation:** Swift and Kotlin now have strict feature/settings/control parsing,
multipart control responses, sensor-clock mapping, raw and delta ACC/PPG decoding, ECG, PPI, and a
serial settings/start planner. On Apple and Android, the isolated standard-HR source always reads PMD
capabilities when present. A default-off Settings switch starts PPI + ACC; PPI is used only if the
standard `0x2A37` stream is quiet for three seconds, and ACC is downsampled into the existing
one-vector-per-second motion lane. Android serializes all CCCD writes and reads to respect the
one-operation-at-a-time GATT rule. ECG/PPG decode is covered by fixtures but is not recorded yet:
NOOP needs a bounded waveform capture/store before enabling high-rate streams continuously.

This is **Implemented**, not hardware-verified. Issue `#421` and each Polar model/firmware still need
a current physical run before the support matrix can move to Partial or Verified. See
[Polar PMD implementation and qualification](POLAR_PMD.md).

## Xiaomi Smart Band (Mi Band) — shipped import lane

NOOP imports a Mi Band's full history **without Bluetooth, a Xiaomi account, or any
cloud** by reading the data the **Mi Fitness iOS app already stored on the phone**. This
is the same "import data you already own" model as the WHOOP-CSV and Apple-Health lanes,
and it's fully offline.

- **What the user does:** on the iPhone, *Files → On My iPhone → Mi Fitness*, long-press
  the folder → *Compress*, then bring that `.zip` to NOOP (*Data Sources → Xiaomi Smart
  Band*). The bare `<user_id>.db` or an unzipped folder (macOS) also work.
- **Where the data is:** `DataBase/<user_id>/de/<user_id>.db` — one SQLite row per sample
  with a JSON `value` column. NOOP opens it **read-only** (GRDB) and never writes to it.
- **Tables read** (`deleted = 0` only):
  - Day rollups → `dailyMetric` + `metricSeries`: `steps_day` (steps, distance),
    `calories_day` (active kcal), `heart_rate_day` (`avg_rhr` resting, avg/min/max + HR
    zones), `sleep_day` (total/deep/light/rem minutes, `sleep_score`), `stress_day`
    (`avg_stress`, 0–100), `spo2_day` (`avg_spo2`), `intensity_day`, `valid_stand_day`,
    `vitality` (`latest_accumulated_vitality`).
  - `sleep` (interval) → `sleepSession`: each row's `items[]` is the **real per-epoch
    hypnogram** (`{start_time, end_time, state}`), giving NOOP a native
    `[{start,end,stage}]` timeline rather than just stage totals.
- **Sleep-stage codes** (verified against a real Mi Band 10 export):
  `1 = awake, 2 = light, 3 = deep, 4 = REM, 5 = awake-in-bed` → NOOP `wake/light/deep/rem`.
- **Not present in the export** (left `nil`, NOOP derives what it can): HRV, recovery,
  respiration rate, skin temperature.
- **Partition:** all rows land under `deviceId = "xiaomi-band"`, so it appears as its own
  Data Source for the per-source pages and cross-source consensus/compare views.

**Code:** parser `Packages/StrandImport/Sources/StrandImport/XiaomiBandImporter.swift`
(pure, re-derived from the public `artyomxx/xiaomi-band-ios-export` tool — **not** copied
from any GPL source); app glue `Strand/Data/XiaomiImporter.swift`; detection in
`ImportCoordinator`. Verified end-to-end against a real **450-day / 545-sleep** export.

## Xiaomi Smart Band — live BLE sync (researched, not built)

The chosen-but-deferred path. The band **is** reachable over BLE (Gadgetbridge supports
Smart Band 8/9/10 this way, no Classic-SPP/MFi needed), so a CoreBluetooth implementation
is feasible *in principle* on iOS — but it's a Gadgetbridge-scale reverse-engineer that
must be **re-derived, never GPL-copied**, and can only be built/verified with the physical
band in an iterative BLE test loop. Verified facts to pick up from:

- **Stack:** "Xiaomi protobuf v2" — length-prefixed, chunked **protobuf** command/response
  frames over a vendor GATT service (the Mi ecosystem service is `0xFE95`; the data
  channel is a custom 128-bit service with write + notify characteristics — confirm the
  exact UUIDs by a GATT dump of *this* band).
- **Auth:** the per-device **`encryptKey`** (32 hex chars) the vendor app holds — the user
  already extracts it as `auth.key` via the same Mi Fitness export. Pairing is a
  nonce-exchange handshake (send phone nonce → receive watch nonce → derive session keys),
  after which traffic is **AES-CCM** encrypted with **HMAC** integrity. NOOP would take the
  key as a one-time **user-pasted value** (same stance as the Amazfit/Zepp lane) and never
  log into the Xiaomi cloud.
- **Data fetch:** once authenticated, request **activity sync** — the watch streams the same
  per-minute samples and sleep/stage records that the import lane reads from the DB, so the
  decode target (and the `xiaomi-band` store shape) is **already built and verified**. Live
  sync is "only" the transport + crypto + protobuf layer in front of it.
- **iOS caveat:** background BLE sync under a free signing identity is limited; treat live
  sync as a foreground "Sync now" action first.

This earns its place only if it stays tractable and never threatens WHOOP stability — it
will not ship blind.

## Notes on the deep-band lanes (Garmin / Amazfit / cloud)

These "earn their place" — pursue only while tractable, defer/drop if they threaten WHOOP stability or
become a time-sink. Garmin/Amazfit decode is genuinely L-effort and best done with a device to capture
against; the cloud lanes need registered OAuth apps + real accounts to verify. None will ship "blind."
