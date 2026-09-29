# KeyStats Persistence and Release Repair Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Preserve statistics through migration failures, abnormal termination and day rollover; ship the current Helper source and replace the locally installed app safely.

**Architecture:** Retain the two-second current/hourly snapshot and infrequent daily-history writes. Extract a Foundation persistence/recovery component used by StatsManager and isolated SwiftPM tests; acknowledge writes only after success and retain a recoverable snapshot when archival fails. Bind the vendored Helper to a deterministic source fingerprint checked before packaging.

**Tech Stack:** Swift/Foundation, SwiftPM XCTest, Xcode Release universal archives, shell build scripts, macOS app bundles and launchd.

## Scope and priorities

P1: migration write failure must not delete the last persistent history copy; next-day startup must archive saved previous-day currentStats before replacing it; event-driven rollover must persist archives even if the midnight timer observes an already-reset day. History write failures must remain retryable without silently discarding previous days. Preserve on-disk compatibility and current imports, reset, export and sync semantics.

P1: DMG and ZIP release paths must reject a source-stale vendored Helper. Rebuild the universal Helper and update its source fingerprint and code-signature hash together.

Defer: UI scheduling redesign, additional micro-optimizations, CPU/I/O benchmarks and unverified performance claims. This work promises correctness, not a fixed speedup.

## Task 1: Persistence/recovery regression coverage and implementation

**Files:** Modify `KeyStats/StatsManager.swift`, `Package.swift`; create a focused Foundation persistence/recovery source in `KeyStats/` and corresponding tests in `KeyStatsTests/`.

1. Read storage, startup, import/reset and rollover call sites; reuse existing DailyStats serialization and normalization.
2. Add isolated tests using temporary directories and dedicated UserDefaults suites. Reproduce failed migration, next-day startup recovery, rollover archival with disk failure/retry, and successful migration/restart without double-counting. Record the initial failing result where feasible.
3. Make history writes throwing or explicitly successful. Delete legacy data only after confirmed durable file replacement. Preserve failed writes for retries. Recover a saved non-current day before replacing its current snapshot; prevent stale snapshots resurrecting intentional resets/imports.
4. Ensure all rollover paths schedule history persistence, not just the midnight timer. Serialize persistence bookkeeping and snapshots so older saves cannot overwrite newer ones. Keep full daily history out of ordinary two-second writes when it has not changed.
5. Run `swift test`, inspect changes and perform spec review followed by code-quality review. Fix findings; commit only verified task files.

## Task 2: Helper provenance and packaging

**Files:** `scripts/rebuild_vendored_helper.sh`, `scripts/check_vendored_helper.sh`, new fingerprint helper if needed, `vendor/KeyStatsHelper.sources.sha256`, vendored Helper and its cdhash.

1. Derive a deterministic digest of actual Helper build inputs (Swift, entitlements, plist, assets, relevant build settings); exclude main-app-only changes where possible.
2. Record this digest only with a successful rebuild. Make the shared pre-packaging check reject missing/mismatched fingerprints in addition to signature/hash problems.
3. Verify baseline acceptance and intentional stale-source rejection using temporary fixture copies, without mutating the user's installed helper or source during checks.
4. Rebuild universal Helper after final version settings. Validate signature and arm64/x86_64 slices; run the check. Spec review, then code-quality review, then commit verified files.

## Task 3: Integration, version and release validation

**Files:** `KeyStats.xcodeproj/project.pbxproj`, this plan's execution record.

1. Increment main app to 1.53.1 build 52 and Helper build 3 (keep protocol version unchanged); preserve the installed sync service configuration.
2. Run full SwiftPM suite, shell syntax checks, source freshness check and universal release archive through `scripts/build_dmg.sh`. Save logs outside deliverables.
3. Inspect final DMG app version, architecture, nested signatures and Helper hashes against vendor. Independent final integration review must resolve P1/P2 findings before replacement.
4. Commit verified source, tests, provenance and vendor changes; do not publish/push a remote release.

## Task 4: Back up, install and smoke-check

1. Back up the current app and Application Support/KeyStats data and export `com.keystats.app` preferences to a private workspace work directory. Avoid exposing keys or user statistics in outputs.
2. Ask the current app to quit normally (allowing flushPendingSave), refresh the data backup, then stage the verified app on the same filesystem and replace `/Applications/KeyStats.app` reversibly.
3. Launch the replacement and verify its process, version and launchd Helper, compare installed/bundled Helper hashes, and check that saved data remains parseable and existing history is retained.
4. If macOS requires renewed Accessibility permission because Helper changed, report the actual required user action; never alter TCC databases or falsely claim monitoring is active.
5. On startup/install failure, retain backups and restore the old app where safe; do not overwrite newer user data during rollback.
6. Copy the final DMG and a concise execution report/plan into the chat outputs directory and link them in the final response.

## Acceptance criteria

- Regression tests pass without touching production user data.
- Migration and rollover failures preserve a recovery path and log errors without aggregate contents.
- Source-stale Helper detection is exercised and final bundled Helper matches current source manifest/vendor hash.
- Universal Release build and final signatures verify.
- Installed app is the verified new version; launch and Helper status are reported honestly.
- A recoverable application/data backup exists and no remote publication occurs.

## Execution record

Pending.
