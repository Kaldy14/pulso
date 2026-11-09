# Pulso · Kaldy14 tailnet fork

A native SwiftUI app that reads Apple Health with permission and exports to **one configured tailnet URL**. No analytics, advertising SDKs, cloud accounts or third-party transport dependencies.

## Install

Open `Pulso.xcodeproj` in Xcode 26+ (built here with Xcode 27.2). Select the development team belonging to `it@vosime.cz`, enable automatic signing and run on a trusted iPhone with Developer Mode enabled. Bundle identifier: `cz.vosime.pulso.kaldy14`. No signing identity or health key is committed.

Settings accepts the **complete POST URL**, including path, and a required `X-Health-Key` stored in the device-only Keychain. Use a Tailscale IPv4 address (`100.64.0.0/10`), Tailscale IPv6 address, or a `.ts.net` hostname. Tailscale must be connected on the phone. HTTPS is recommended; HTTP is supported inside the encrypted tailnet. Redirects are always refused. Test Connection issues HEAD to that exact URL; a receiver that only implements POST may return 405.

Grant Health Access, then Sync Now. The first import includes the complete accessible history. Keep the phone unlocked and app open for that import. The Status tab shows last successful delivery, pending batches and errors.

## Coverage and platform limits

The checked-in catalogue is generated from Apple's public SDK, rather than the original hand-maintained 58-type list:

```sh
python3 scripts/generate-health-types.py
```

It contains all 192 public quantity/category identifiers present in the SDK used here, with runtime OS-version gates. New SDK types require regeneration and an app update: HealthKit has no public API that enumerates future types or reveals which read permissions were granted. Unsupported, denied and empty data cannot always be distinguished.

Specialized readers add workouts, workout routes, ECG voltage series, blood-pressure correlations, State of Mind (iOS 18+) and medication dose events with medication names/codings (iOS 26+). Workout exports include recorded lap/segment events, elevation metadata, heart-rate samples and recorded heart-rate recovery. Missing measurements are not invented. Routes also have an independent anchored stream so routes arriving after their workout are not lost. Independent heart-rate and recovery streams preserve late arrivals too.

This is **not every HealthKit object class**: clinical/FHIR records, characteristics (birth date etc.), activity summaries, audiograms, heartbeat series, vision prescriptions and scored questionnaires still need dedicated readers. Clinical records also need additional entitlements. Quantity/category coverage does not imply support for those distinct APIs.

## Delivery contract

See [docs/TAILNET-EXPORT.md](docs/TAILNET-EXPORT.md). The JSON uses Health Auto Export's `data.metrics` and `data.workouts` envelope and separate `ecg`, `symptoms`, `stateOfMind`, `medications` arrays, extended with stable sample `id`, raw categories, `routes` and deletion UUIDs. Generic types without a dedicated HAE mapping use their snake_case HealthKit name. This is a raw-sample export, not daily aggregated HAE data; validate the mapping against your receiver before importing real history.

**The upstream Rust receiver in `server/` implements the old Pulso protocol and is not compatible with this fork's new export.** It is retained as upstream reference; do not use its original deployment instructions with this app. No receiver is deployed by this change.

HealthKit observers, background delivery, opportunistic background refresh, foreground entry and the protected-data-available callback trigger incremental anchored queries. iOS controls when background execution is granted. Neither instant delivery on unlock nor execution after force-quitting the app can be guaranteed.

Delivery is at-least-once. Retry requests carry a stable SHA-256 `Idempotency-Key`; records carry HealthKit UUIDs. The receiver must atomically deduplicate/upsert by record identity and acknowledge only after durable storage. A network retry after a lost response is unavoidable. Local anchors and queued pages survive process restarts; corrupted pending files stop delivery rather than silently skipping health data.

## Verification

```sh
xcodebuild -project Pulso.xcodeproj -scheme Pulso -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Pulso.xcodeproj -scheme Pulso -destination 'platform=iOS Simulator,name=<your simulator>' CODE_SIGNING_ALLOWED=NO test
```

A simulator test or unsigned build does not verify real HealthKit permissions, locked-device wake timing, tailnet delivery or installation with a developer account. Those require a signed build and the target iPhone.

MIT; see [LICENSE](LICENSE).
