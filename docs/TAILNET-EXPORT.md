# Tailnet export contract

POST the exact URL configured in Settings. Headers:

- `Content-Type: application/json`
- `X-Health-Key: <device key>`
- `Idempotency-Key: <SHA-256 of the exact JSON request body>`

No Bearer header, gzip requirement, `/latest` request or appended `/ingest` path. No redirects are followed. Only 2xx acknowledges a batch; other responses preserve it for retry. Response bodies are not logged because a receiver may echo sensitive records.

```json
{"data":{"metrics":[{"name":"step_count","units":"count","data":[{"id":"healthkit-uuid","date":"2026-11-09 10:00:00 +0100","start":"2026-11-09 10:00:00 +0100","end":"2026-11-09 10:01:00 +0100","qty":100,"source":"Apple Watch"}]}],"deleted":["deleted-healthkit-uuid"]}}
```

The receiver must authenticate before parsing/importing, persist transactionally before responding, and deduplicate sample IDs in addition to request keys. A partial local enqueue interrupted by process termination may retry records in a differently sized request; batch-key deduplication alone is insufficient. Persist deletion tombstones as well so an old retried sample cannot resurrect a deleted record. Do not deduplicate by timestamp: independent devices/sources can legitimately record at the same time.

Workouts use `id`, `name`, `start`, `end`, duration in seconds, quantity/unit pairs for distance and energy, raw `heartRateData`, recorded `heartRateRecovery`, `splits` (recorded lap/segment events), elevation metadata and route points. Routes are also exported separately, with their own `id` and `workoutIds`. Merge late routes by route UUID. HealthKit route coordinates contain timestamps, latitude, longitude, altitude, speed, course and accuracy. No calculated kilometer splits or synthetic recovery values are substituted for unavailable recorded values.

ECG exports include original voltage measurements (microvolts and epoch seconds), classification and sampling frequency. State of Mind uses documented enum labels. Medications include dose event identity, dosage, schedule, status and authorized medication metadata. Symptoms preserve both severity labels and raw enum values. Blood pressure includes systolic and diastolic values from the original correlation.

HAE references:

- https://help.healthyapps.dev/en/health-auto-export/export-format/health-metrics/
- https://help.healthyapps.dev/en/health-auto-export/export-format/workouts/
- https://help.healthyapps.dev/en/health-auto-export/export-format/ecg/
- https://help.healthyapps.dev/en/health-auto-export/export-format/medications/
- https://help.healthyapps.dev/en/health-auto-export/export-format/state-of-mind/
- https://help.healthyapps.dev/en/health-auto-export/export-format/symptoms/

`docs/PROTOCOL.md` describes the **upstream legacy protocol**, not this export. The internal durable batch format still uses the original SampleDTO schema; the HTTP encoder translates it at send time.
