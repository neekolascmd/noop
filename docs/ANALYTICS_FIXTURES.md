# Shared analytics golden fixtures

`shared-fixtures/analytics/v1/golden.json` is the platform-neutral parity contract for NOOP's Swift and
Kotlin health analytics. The same versioned file is read by both test suites; platform-specific copies
are deliberately not allowed.

The v1 fixture covers recovery (Charge), strain (Effort), HRV summaries, sleep stages/totals, and
wearable imports. Each area includes representative normal data plus a boundary or malformed input.
Expected values describe observable production behavior, not a second implementation of the algorithm.

## Numeric tolerances

The fixture declares tolerances alongside its schema version:

- `score`: `0.01`, matching the public two-decimal score precision.
- `metric`: `0.000001` for HRV statistics, ratios, and imported measurements.
- `sleepMinutes`: `0.000001` for stage-duration arithmetic.

Integers, counts, strings, and nullability must match exactly. A tolerance change is a contract change
and should be reviewed with the fixture case that requires it.

## Test runners and CI

- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SharedAnalyticsGoldenTests.swift` runs the
  recovery, strain, HRV, and sleep sections.
- `Packages/StrandImport/Tests/StrandImportTests/SharedWearableImportGoldenTests.swift` runs wearable
  imports through the Swift importers.
- `android/app/src/test/java/com/noop/analytics/SharedAnalyticsGoldenTest.kt` runs every section through
  the Kotlin implementations.

Swift Packages CI executes both Swift runners. Android CI executes the Kotlin runner and is also
triggered by fixture-only pull requests, so a one-platform result change is visible before merge.

## Adding a case

Add the input and expected observable output to the existing v1 section, then run:

```sh
swift test --package-path Packages/StrandAnalytics
swift test --package-path Packages/StrandImport
cd android && ./gradlew testFullDebugUnitTest
```

Create `v2` only when the fixture shape itself must break compatibility. Keep prior versions while any
supported client still consumes them.
