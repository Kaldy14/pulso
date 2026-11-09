# Verification of the tailnet fork

Verified on 2026-11-09 with Xcode 27.2:

- Unsigned iOS device build succeeded (`generic/platform=iOS`).
- iOS 27.1 Simulator suite: 41 tests, zero failures.
- Tests cover internal serialization, HTTP export collections, tailnet endpoint validation, required X-Health-Key, deterministic idempotency keys, outbox ordering, failed-delivery retention, persisted queued checkpoints, corrupted queue handling and SDK registry coverage.
- `git diff --check` passed.
- No actual health records or authentication secrets were used in tests.

Not verified:

- Signing with the requested Apple developer account: the account is now signed in and Vosime.cz Holding s.r.o. (7DTQ6967VA) is selected. Xcode reports “Unable to process request - PLA Update available”: the account holder must accept the latest Program License Agreement before Apple can issue the provisioning profile. The command-line build also fails to obtain a profile.
- Installation and launch on the connected iPhone.
- Before/after screenshots and a flow recording: the device automation service returned no devices even though Xcode's device inventory showed the connected phone and a simulator runtime was available. The unsigned upstream simulator build was preserved separately before UI edits, but captures could not be made.
- Real permission grants, ECG/route/medication samples, background delivery after locking/unlocking, and end-to-end delivery to the user's receiver. No receiver URL or server deduplication contract has been supplied.
- Complete Health Auto Export interoperability for all generic identifiers; specialized mappings and extensions are documented in TAILNET-EXPORT.md.

These are local implementation checks, not device acceptance or deployed-receiver proof.
