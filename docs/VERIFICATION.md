# Verification of the tailnet fork

Verified on 2026-11-09 with Xcode 27.2:

- Signed iOS device build succeeded with team Vosime.cz Holding s.r.o. (`7DTQ6967VA`) and the development identity associated with the configured `it@vosime.cz` account.
- `codesign --verify --deep --strict` passed. The signed app contains HealthKit and HealthKit background-delivery entitlements.
- Installation of the final corrected build onto the connected iPhone succeeded. The device app inventory confirms `cz.vosime.pulso.kaldy14`, version 0.1.0 (1).
- iOS 27.1 Simulator suite: 42 tests, zero failures. Includes a regression test that keeps per-object medication authorization and inherited dose-event permissions out of the ordinary HealthKit authorization API.
- A real simulator launch exposed an Objective-C HealthKit exception that unit tests had not previously exercised. Medication permissions now use a separate per-object request; dose events inherit the medication grant.
- Final simulator app launch, Status screen, opening the native Medications Access sheet and cancelling back to Status were verified. The simulator had no medication records. Before/after screenshots and a recording were captured, inspected and supplied separately in the task conversation.
- `git diff --check` passed.
- No actual health records or user authentication secrets were used in tests or exported.

Not verified:

- Physical iPhone launch/UI, actual permission grants, real ECG/route/medication samples and locked/unlocked background behavior. The device automation service only exposes the simulator; physical installation was performed and verified through Apple's device CLI.
- End-to-end delivery to the user's receiver: no target URL or receiver deduplication contract has been supplied.
- Complete Health Auto Export interoperability for every generic identifier; specialized mappings and extensions are documented in TAILNET-EXPORT.md.

The Apple license agreement and initial device-registration blockers were resolved. The signing certificate was not revoked; the newly available matching local identity and Xcode-managed profile signed the app successfully.

These are implementation, simulator and physical-installation checks, not real-health-data export acceptance or deployed-receiver proof.
