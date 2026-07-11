# NOOP maintenance roadmap

This fork continues NOOP as a community-maintained, local-first project. The roadmap deliberately
puts reliability and user trust ahead of expanding the feature list.

## Phase 1 — establish a trustworthy baseline

- Keep Android, macOS, iOS, watchOS, and all reusable packages building in CI.
- Run application and package tests on every relevant pull request.
- Document supported devices and distinguish verified support from experiments.
- Produce releases from reviewed tags with checksums and clear release notes.
- Keep contribution, security, build, and installation documentation current.

## Phase 2 — protect data and cross-platform behavior

- Add shared golden fixtures for recovery, strain, HRV, sleep, and imports so Swift and Kotlin
  implementations produce equivalent results.
- Expand migration, backup, restore, and malformed-import regression coverage.
- Maintain a real-hardware test matrix for supported WHOOP models and experimental sources.
- Review local data-at-rest protection and optional network features against the privacy promise.

## Phase 3 — improve distribution and product quality

- Establish repeatable signing and notarization where maintainer identities and platform policies
  allow it.
- Publish artifact provenance and software bills of materials.
- Improve accessibility, localization, performance, and onboarding from reproducible bug reports.
- Consider new devices only when maintainers have hardware and can add protocol fixtures.

## How work is prioritized

1. Data loss, unsafe device commands, privacy regressions, and security issues.
2. Connection, synchronization, migration, and release failures.
3. Cross-platform inconsistencies and accessibility defects.
4. Small product improvements with tests and a clear maintenance cost.
5. New hardware and broad feature work.

Open an issue before starting a large change so scope, hardware access, and test expectations are
clear. NOOP is not a medical device; analytics changes must remain transparent, cited, and tested.
