# Deployed tailnet relay

Snapshot of the Lenovo service source, including the connection-reuse update.
No key or health payload is checked in. The key stays in the existing private
file on the host; this source must not be used as a public Internet service.

The forwarder sends spool files in FIFO order through one HTTPSConnection,
consumes response bodies for connection reuse, and reconnects after transport
failure. A file is removed only after a complete 2xx response and directory
fsync. New arrivals are picked up without an extra sleep after a successful
pass. There is still a 30-second delay after failure or an empty queue.

Run `python3 ops/health-relay/test_relay.py` for synthetic transport tests.
The service was updated in place and only health-relay-forwarder restarted.
A backup of the previous script remains on the host as
`relay.py.before-connection-reuse`. Existing spool files were not migrated or
cleared. Live forwarding throughput after this update has not been measured:
the destination was timing out during verification.
