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

## Progress screen A and safe full-history restart (2026-11-09)

- Approved variant A implemented with separate HealthKit reading and server
  delivery sections. Type completion, current type, records read this pass,
  lifetime acknowledgments since reset, queued batches/bytes, retry time and
  last acknowledgment use actual engine/outbox events. There is no invented
  percentage of all health records. Server acknowledgment is explicitly distinct
  from downstream forwarding.
- Full re-import suspends new sync triggers, cancels and joins the current
  reader/uploader, then resets the queue and anchors before resuming. A durable
  preparation flag makes interrupted preparation repeat on next app launch.
- Manual upload retry is independent of history reading. Queue sizes are cached
  and updated on disk mutations rather than statting every file per update.
- 52 simulator tests passed. Added a blocked-upload regression proving an old
  acknowledgment cannot advance anchors after cancellation/reset, and progress
  tests distinguishing failed types from successful completion.
- Signed device and simulator builds succeeded. The update was installed over
  the existing physical app without uninstalling or initiating re-import.
- Simulator before/after captures and a recording of the confirmation flow are
  supplied in the conversation. Simulator counters include synthetic unit-test
  data; these captures do not demonstrate a real health-history upload.

## Export throughput (2026-11-10)

- Metric query pages increased from 100 to 1,000 records. This applies to new
  reads, not already queued files. Workouts, ECG and routes remain one per page;
  the existing byte-size splitter remains active.
- Export timestamp parsers/formatters are reused within each request. Mixed
  offsets and retry determinism are covered by a regression. A release-optimized
  standalone Swift benchmark encoding 20 batches of 100 synthetic samples took
  1.7476 seconds before and 0.3029 seconds after; output bytes matched exactly.
  This measures encoding, not end-to-end sync or network throughput.
- FIFO iteration no longer repeatedly shifts the entire pending-file array.
- 53 iOS tests passed; signed device build and codesign verification passed.
- Lenovo forwarder now reuses its HTTPS connection and drains responses before
  reuse. Three synthetic tests cover shared-connection FIFO, non-2xx retention
  and connection-loss retention. Source and tests are in ops/health-relay.
- The downstream receiver was timing out during this check. Connection reuse
  cannot remove server outages, and total completion time is not established.
