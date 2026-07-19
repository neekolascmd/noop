<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP" width="72">
</p>

<h1 align="center">NOOP</h1>

<p align="center"><b>Your strap. Your data. Your machine. Offline, on-device, no cloud.</b></p>

<p align="center">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Android%20%C2%B7%20iOS-E8B84B?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/local-first-E8B84B?style=flat-square">
  <img alt="Account free" src="https://img.shields.io/badge/account-free-C8902F?style=flat-square">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-6B737B?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://github.com/neekolascmd/noop/actions/workflows/android.yml"><img alt="Android CI" src="https://github.com/neekolascmd/noop/actions/workflows/android.yml/badge.svg"></a>
  <a href="https://github.com/neekolascmd/noop/actions/workflows/swift-packages.yml"><img alt="Swift Packages CI" src="https://github.com/neekolascmd/noop/actions/workflows/swift-packages.yml/badge.svg"></a>
  <a href="https://github.com/neekolascmd/noop/actions/workflows/app-build.yml"><img alt="Apple app CI" src="https://github.com/neekolascmd/noop/actions/workflows/app-build.yml/badge.svg"></a>
  <a href="https://github.com/neekolascmd/noop/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/neekolascmd/noop?style=flat-square"></a>
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#features">Features</a> ·
  <a href="#hardware">Hardware</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="docs/PROTOCOL.md">Protocol</a> ·
  <a href="https://github.com/neekolascmd/noop/wiki/FAQ">FAQ</a> ·
  <a href="https://github.com/neekolascmd/noop/issues">Issues</a>
</p>

<p align="center">
  <a href="https://github.com/neekolascmd/noop/releases/latest"><img src="docs/assets/hero-v8.jpg" alt="NOOP on iPhone, Mac and Android" width="820"></a>
</p>

<p align="center">
  <img src="docs/assets/shot-ios-today.png" alt="Today on iPhone" width="218">
  &nbsp;&nbsp;
  <img src="docs/assets/shot-android-today.png" alt="Today on Android" width="218">
  &nbsp;&nbsp;
  <img src="docs/assets/shot-android-trend.png" alt="Trend view on Android" width="218">
</p>

---

NOOP is a standalone, fully **offline** companion app for WHOOP straps and other wearables. It pairs directly with the strap over Bluetooth, stores everything on your own device in SQLite, and computes recovery, strain, HRV, and sleep **locally** — no WHOOP account, no cloud.

**Not affiliated with WHOOP.** NOOP is an independent, unofficial interoperability project. It is not endorsed by or connected to WHOOP, Inc. **NOOP is not a medical device** — every metric is an approximation, not clinical data. See [`DISCLAIMER.md`](DISCLAIMER.md).

> This is the actively maintained community continuation. After the original project was discontinued, this repository preserves the recovered history while accepting fixes, tests, documentation, and carefully scoped features. See [`ROADMAP.md`](ROADMAP.md) for current priorities and [open issues](https://github.com/neekolascmd/noop/issues) for what's being worked on.

---

## Download

Every release includes SHA-256 checksums. Build from source with [`docs/BUILD.md`](docs/BUILD.md).

| Platform | Install | Notes |
|---|---|---|
| **macOS** | `NOOP-vX-macos.zip` from [Releases](https://github.com/neekolascmd/noop/releases) | Apple Silicon + Intel. Not notarized — use `xattr -dr com.apple.quarantine /Applications/NOOP.app` on first launch, or build from source. |
| **Android** | `NOOP-vX.apk` from [Releases](https://github.com/neekolascmd/noop/releases) | Android 8+. Sideload — enable "install unknown apps." Same signing key from v8.2.1 onward. |
| **iOS** | `NOOP-vX-ios.ipa` from [Releases](https://github.com/neekolascmd/noop/releases) | Sideload with AltStore/SideStore using your own Apple ID. Newer than macOS/Android — live BLE still being validated. |

Everything runs **offline**. The only feature that ever uses the network is the optional **AI Coach**, and only with your own API key.

---

## Hardware

### Supported

| Device | Live HR | Recovery / Strain / Sleep | History offload | Notes |
|---|---|---|---|---|
| **WHOOP 4.0** | ✅ | ✅ | ✅ | The tested, supported path. v1.95+ handles both v24 and v25 firmware layouts. |
| **WHOOP 5.0 / MG** | ✅ | 🧪 In progress | ✅ | Live HR confirmed on hardware. Deeper metrics (sleep staging, recovery, SpO₂) still being mapped. Opt in via Settings → Experimental. |

[Full hardware matrix](docs/HARDWARE_SUPPORT.md) with per-firmware evidence.

### Experimental

| Device | What works | What's next |
|---|---|---|
| **Oura Ring 4** | Stored-key BLE auth, live HR + R-R, history/skin-temp fetch, overnight sleep windows — on macOS and Android (hardware-recorded, [qualification data](docs/HARDWARE_SUPPORT.md)) | Reference sensor, out-of-range reconnect, full 24 h run; sleep stages and SpO₂ still experimental. Ring 3, iOS not yet recorded. |
| **Standard BLE HR devices** (Polar, Wahoo, Garmin HRM, Coospo, Amazfit broadcast) | Live HR + R-R via standard `0x180D` / `0x2A37` since v3.8.0 | No per-model firmware matrix recorded. Report each model. |
| **Xiaomi Smart Band 8 / 9 / 10** | Offline Mi Fitness SQLite import (one real Band 10 export verified) | Bands 8/9 need own exports; live BLE sync planned. |
| **Oura / Fitbit / Garmin exports** | Offline wellness-export import with shared Swift/Kotlin fixtures | Capture fresh exports per vendor app version. |

### Planned

| Device | Status |
|---|---|
| **Polar H10 / Verity Sense / OH1 deep BLE** (PMD ECG / PPG / ACC / PPI) | Protocol documented, production decoder not built |
| **Garmin / Amazfit deep BLE** | Needs owned hardware and clean-room captures |
| **Fitbit / Google** Google Health import | Needs registered API path |

See [`docs/DEVICE_SUPPORT_ROADMAP.md`](docs/DEVICE_SUPPORT_ROADMAP.md) for protocol research and future lanes.

---

## Features

| Screen | What it does |
|---|---|
| **Today** | Home dashboard: recovery ring, stat tiles (recovery, strain, sleep, HRV, RHR, SpO₂, respiratory, steps, weight, calories) with 14-day sparklines, live strap battery and HR trend, recent workouts. |
| **Readiness** | On-device "should you push today?" — synthesizes HRV vs baseline, resting-HR drift, respiratory-rate drift, training-load balance, and monotony into a headline (Primed / Balanced / Strained / Run down). |
| **Live** | Real-time heart rate and frame stream from the connected strap. |
| **Breathe** | HRV haptic breathing biofeedback — the strap buzzes inhale/exhale cues while NOOP shows live RMSSD responding as the session deepens. |
| **Intervals** | Silent haptic HIIT timer — the strap buzzes every transition so you train hands-free. |
| **Explore** | Interrogate any single metric over time from the metric catalog. |
| **Compare** | Plot two metrics together over a shared timeline. |
| **Insights** | Behavioral correlations from your own data — including Activity Cost, which learns what each activity type costs your next-morning recovery. |
| **Sleep** | Sleep sessions with hypnogram, stage breakdown, efficiency, resting HR, and HRV. Browse past nights, not just last night. |
| **Trends** | Long-range trends across recovery, strain, sleep, and biometrics — plus a shareable one-page PDF rendered on-device. |
| **Workouts** | Detected and manual exercise sessions with HR curve, zone breakdown, duration, and Effort. |
| **Health** | Biometric overview (HR, HRV, SpO₂, skin temperature, respiratory rate, etc.). |
| **Stress** | Day-level stress / autonomic load visualization. |
| **Mind** | Daily mood check-in correlated against your own recovery, sleep, and HRV over time. |
| **Apple Health** | Browse and reconcile data from your Apple Health export. |
| **Data Sources** | One-tap import: WHOOP CSV, Apple Health export, nutrition CSV (Cronometer / MacroFactor), plus live-strap status. |
| **Automations** | Double-tap the strap to lock your Mac, run a Shortcut, or mark a moment. Wear detection, inactivity reminders, smart alarm that arms the strap's firmware alarm. |
| **Coach** | Optional AI Coach with your own key (Anthropic, OpenAI, or local model via Ollama/LM Studio). Sends only a short text summary of recent metrics plus your question — never raw streams or identifiers. |
| **Settings** | Profile, preferences, step calibration, unit choices, What's New changelog, Experimental section for WHOOP 5/MG probes. iOS: Export for Shortcuts. |

Plus a menu-bar extra with glanceable live HR, a first-run onboarding wizard, and an in-app What's New changelog after each update.

---

## Platform status

| Platform | Status |
|---|---|
| **macOS** | ✅ Full app (SwiftUI, macOS 13+). Pairs over BLE, offloads history, scores on-device. The complete feature set. |
| **Android** | ✅ Full app (Jetpack Compose, Android 8+). Pairs over BLE, persists and scores on-device, imports WHOOP / Apple Health / Health Connect. APK on Releases. |
| **iOS** | 📲 Direct download as unsigned `.ipa` — sideload with AltStore/SideStore using your own Apple ID. Shares the cross-platform Swift packages, so scoring matches macOS. Newer and less battle-tested than macOS/Android. |

---

## Architecture

Platform-pure Swift packages plus a macOS app target. All packages declare `.iOS(.v16)` and `.macOS(.v13)`.

```
Strand/                  macOS SwiftUI reference app
Packages/
  WhoopProtocol/         BLE frame parsing, CRC, command/event/packet decode
  WhoopStore/            GRDB/SQLite persistence (v22 migration)
  StrandAnalytics/       HRV / recovery / strain / sleep / correlation math
  StrandImport/          WHOOP CSV + Apple Health + nutrition importers
  StrandDesign/          SwiftUI design system (palette, components, charts)
android/                 Kotlin + Jetpack Compose (ports protocol/storage/analytics)
```

### WhoopProtocol

Platform-pure (no CoreBluetooth). Implements the on-wire frame format for both strap generations:

```swift
public enum DeviceFamily: String, Sendable, CaseIterable {
    case whoop4   // CRC8 (poly 0x07), service 61080001-…
    case whoop5   // CRC16-Modbus, "puffin" packets, service fd4b0001-…
}
```

Decoding is schema-driven (`Resources/whoop_protocol.json`) with CRC8, CRC16-Modbus, and zlib CRC-32 implementations.

### StrandAnalytics

Pure, database-free analyzers grounded in published methods:

| Analyzer | Computes |
|---|---|
| `HRVAnalyzer` | RMSSD + SDNN from R-R intervals (Task Force 1996), with Malik ectopic filtering |
| `RecoveryScorer` | 0–100 recovery score: HRV-dominant z-score + logistic composite vs personal baselines |
| `StrainScorer` | 0–21 logarithmic strain from %HRR (Karvonen) and Edwards / Banister TRIMP |
| `SleepStager` | Sleep/wake detection + approximate 4-class staging from cardiorespiratory + gravity features |
| `CorrelationEngine` | Pearson r, OLS regression, day-aligned and lagged correlations |

---

## Quickstart (macOS)

**Requirements:** macOS 13+, Xcode 15+ (Swift 5.9), Bluetooth. Need a WHOOP strap to pair live, or import CSV/Apple Health to explore.

```bash
git clone https://github.com/neekolascmd/noop.git
cd NOOP
brew install xcodegen   # if needed
xcodegen generate
open Strand.xcodeproj   # Strand scheme → Run (⌘R)
```

Run tests from Xcode or per-package:

```bash
cd Packages/WhoopProtocol && swift build && swift test
```

---

## Data flow

```
WHOOP strap ──BLE──▶ Strand/BLE + Strand/Collect ──▶ WhoopProtocol (decode)
                                                        │
WHOOP CSV   ─┐                                            ▼
Apple Health ├─▶ StrandImport (parse) ──────────▶ WhoopStore (local SQLite)
Nutrition CSV┘                                            │
                                                          ▼
                                            StrandAnalytics (recovery/strain/
                                            HRV/sleep, on-device)
                                                          │
                                                          ▼
                                          Strand (SwiftUI) + StrandDesign
```

Every arrow stays on your machine.

---

## Privacy

**Offline by design.** NOOP has no server, no telemetry, and no account. Your strap data, imports, and computed metrics live in a local SQLite database on your device and never leave it.

---

## Attribution

NOOP stands on community interoperability work:

- **`johnmiddleton12/my-whoop`** — WHOOP 4.0 BLE protocol
- **`b-nnett/goose`** — WHOOP 5.0 / MG BLE protocol
- **`groue/GRDB.swift`** — SQLite persistence
- **`weichsel/ZIPFoundation`** — export unzipping

NOOP contains no WHOOP proprietary code, firmware, logos, or assets. Full detail in [`ATTRIBUTION.md`](ATTRIBUTION.md).

---

## License

Source-available under [PolyForm Noncommercial License 1.0.0](LICENSE) — free for personal and non-commercial use. Protocol facts (frame layouts, command numbers, byte offsets) are uncopyrightable and free to reuse. Bundled dependencies keep their own licenses (GRDB.swift and ZIPFoundation are MIT — see [`NOTICE`](NOTICE)).

By opening a pull request you agree your contribution is licensed under the same terms — see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

---

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) — release history (also in-app under What's New)
- [`ROADMAP.md`](ROADMAP.md) — maintenance priorities and open [issues](https://github.com/neekolascmd/noop/issues)
- [`HARDWARE_SUPPORT.md`](docs/HARDWARE_SUPPORT.md) — per-device, per-firmware verification matrix
- [`DEVICE_SUPPORT_ROADMAP.md`](docs/DEVICE_SUPPORT_ROADMAP.md) — protocol research and future devices
- [`DISCLAIMER.md`](DISCLAIMER.md) — legal and medical notice
- [`ATTRIBUTION.md`](ATTRIBUTION.md) — full credits

---

> **Bug reports:** [GitHub Issues](https://github.com/neekolascmd/noop/issues). **Hardware verification:** use the [hardware verification form](https://github.com/neekolascmd/noop/issues/new?template=hardware-verification.yml).
