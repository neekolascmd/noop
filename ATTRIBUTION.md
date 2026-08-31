# Attribution

NOOP is an independent, unofficial, local-first app for macOS, Android and iOS. It is not affiliated
with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used nominatively only to
identify the hardware the app interoperates with.

NOOP builds on prior community reverse-engineering and interoperability work:

## WHOOP 4.0 protocol + Swift packages
- **`johnmiddleton12/my-whoop`** — the `WhoopProtocol` and `WhoopStore` Swift packages
  (vendored under `Packages/`), the WHOOP 4.0 BLE framing/command/decode work, and the
  iOS collection logic that NOOP's `WhoopBLE`/`Collect` layers are adapted from.
  See `DISCLAIMER.md` (carried over from that project).

## WHOOP 5.0 / MG protocol
- **`b-nnett/goose`** — the WHOOP 5.0 BLE reverse-engineering (service UUID family
  `fd4b0001-…`, CRC16-Modbus header, CLIENT_HELLO, and the "puffin" packet types)
  that NOOP's `DeviceFamily` Whoop-5 path and `whoop5_protocol.json` are ported from.

## Xiaomi Smart Band (Mi Band) import
- **`artyomxx/xiaomi-band-ios-export`** — documented the Mi Fitness iOS app's on-device
  SQLite layout (`DataBase/<user_id>/de/<user_id>.db`, JSON `value` columns, the `*_day`
  rollups and the `sleep` table's `items[]` hypnogram with state codes). NOOP's
  `XiaomiBandImporter` is **re-derived** from those findings and verified against a real
  Mi Band 10 export; **no code is copied** (the reference tool is AGPL, NOOP is not).
- **Gadgetbridge** (`Freeyourgadget/Gadgetbridge`) — referenced only for *protocol facts*
  about the live Mi-protobuf BLE stack in the roadmap's research notes. GPLv3; NOOP copies
  **none** of its code and has not built the live lane.

## Oura ring (gen 3/4/5) protocol
Most of NOOP's Oura code is **original clean-room** work. The local BLE source
(`Strand/BLE/OuraLiveSource.swift` + `android/.../ble/OuraLiveSource.kt`) and the JVM/Swift-pure
`OuraProtocol` package (`Packages/OuraProtocol/`, `android/.../com/noop/oura/`) were written from
**documented protocol facts only**, cited tersely in `docs/OURA_PROTOCOL.md`. The community
reverse-engineering resources below were consulted as **facts-only references** (byte layouts,
service/characteristic UUIDs, framing and auth shapes); **no GPL or unlicensed RE source code is
copied** into NOOP. The SleepNet increment's compatible-NOOP provenance is called out separately.
- **`open_ring`**: consulted for protocol facts only. Licensed **GPL-3.0**; NOOP copies none of
  its code and is not a derivative work of it.
- **`open_oura`**: consulted for protocol facts only. Its workspace `Cargo.toml` metadata declares
  **MIT**, but the repository has no standalone license file; NOOP therefore cites exact factual
  sources and copies no code from it.
- **`ringverse`**, **`relue`**: consulted for protocol facts only. These carry **no license**, so
  NOOP treats them as reference documentation of observed behaviour only and copies no code from them.
- **`ryanbr/noop` SleepNet lineage**: the revision-8 whole-archive reconstruction is adapted from
  a NOOP fork under the same PolyForm Noncommercial License 1.0.0:
  [PR #773](https://github.com/ryanbr/noop/pull/773) (30-second SleepNet burst assembly and `0x49`
  refinement), with correctness evidence from
  [`2f2bce5`](https://github.com/ryanbr/noop/commit/2f2bce598f190057c1843b26661ee6d51c8a7802)
  (whole erased-`0xFF` gaps),
  [`f5e5b15`](https://github.com/ryanbr/noop/commit/f5e5b15d33d4dce47114d4931806ca8de706d00e)
  (a trailing-`0xFF` floor that cannot consume a lone awake byte),
  [`23a08f9`](https://github.com/ryanbr/noop/commit/23a08f9a681e007bf4dc2cc8174af8bc05eb4ac5)
  (default-off stable `0x49`-onset identity and duplicate-session completeness design), and
  [`def4627`](https://github.com/ryanbr/noop/commit/def46278de08bd86c059f9ecc99c91ca2cd56eb6)
  (incomplete hypnogram coverage must not rank as a complete night). This fork adapts those principles
  as a nearest-minute `0x49` onset key, a structural requirement that all 30-second code slots span the
  raw anchored window, and a separate 95% observed-coverage quality threshold. A structurally complete
  night below that threshold still persists its honest gaps but omits efficiency. The core prior art is
  reworked into insertion-ordered, cross-page archive replay with no write-time fallback, pairing that
  requires both ring-clock and envelope Unix-time proximity, a per-run archive high-water that protects
  concurrently appended rows, and automatic replay after terminal caught-up history. Later non-SleepNet
  anchor evidence reopens previously withheld SleepNet rows. Its Ring 4 status remains Partial because
  the cited stage/padding evidence is external Gen 3 evidence.

NOOP reads only the ring's own decoded raw signals and its own open event tags, computes NOOP's
own Charge/Rest, and **never** reads or displays Oura's encrypted readiness or sleep scores. The
documented Oura file-import lane (`Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift`)
remains available as a fallback.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).
- **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) — renders the AI Coach's Markdown
  replies (via Swift Package Manager).

NOOP contains no WHOOP proprietary code, binaries, firmware, logos, or assets, and
performs no DRM circumvention. It operates only with the user's own device and data.
NOOP is **not a medical device**; all metrics (HR, HRV, recovery, strain, sleep,
SpO₂, temperature) are approximations and not clinically validated.
