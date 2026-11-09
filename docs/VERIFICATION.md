# Verification of the tailnet fork

Initial installation verified on 2026-11-09 with Xcode 27.2:

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

## Sync recovery fix (2026-11-09)

Physical-device diagnostics found 1,035 pending files (118,576,238 bytes), no
successful delivery in the retained log, and an upload timeout. The configured
endpoint was the intended `/apple-health` URL. A HealthKit-triggered run was
cancelled during the first history import.

The old recovery code decoded the entire outbox once per enabled type. Recovery
now restores every type's checkpoint in one scan, then starts uploading existing
pages before querying more history. Upload triggers share one worker rather than
a retained task chain. Failures schedule an actual retry while iOS allows the app
to execute; a manual/foreground run bypasses backoff. Observer timeout cancellation
releases only its own waiter and cannot cancel a waiting foreground import.
Cancellation without remaining callers preserves queued pages for a fresh run.

- 50 simulator tests passed, including automatic network retry, unchanged retry
  body, FIFO delivery under concurrent producers, checkpoint restoration,
  corruption blocking, observer cancellation and foreground restart.
- Signed device build and strict codesign verification passed.
- Updated the installed app in place. All 1,035 original queue files and their
  total byte size were preserved; no re-import or app-data reset was performed.
- No screen layout or permission flow changed. Physical screen recording and
  before/after UI captures are unavailable because the device automation service
  exposes only the simulator. Runtime verification on the phone requires the
  user to reopen the app after installation.
- The receiver was still unreachable from this Mac during the fix. An earlier
  successful HEAD reported by the user is not proof of POST ingestion or UUID
  deduplication. Actual delivery of the queued health history remains to verify.
