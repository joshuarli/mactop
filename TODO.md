Prefix: MAC
Next: 11

Priorities are assumed from review impact and likelihood. Findings are open; no behavior changes were made.

### MAC-2 · P1 · Network process ranking overwrites sockets sharing a PID

- **Area:** Data
- **Where:** `Sources/mactop/Core/Processes/NetworkProcessReader.swift:17`, `Sources/mactop/Platform/NetworkStatisticsPlatform.swift:143`
- **Problem:** The platform returns one counter per source. The core reducer assigns one tuple per PID and overwrites earlier sockets. Multi-connection processes report one arbitrary socket, and source-order changes compare unrelated cumulative counters. A probe compiled the real core reader against a fixture platform: two sockets with deltas of 1,000,000 and 1 byte produced only the latter socket's rate.
- **Recommendation:** Keep source identity through delta calculation, then sum source deltas by PID. Cover multiple sockets, ordering changes, removal, resets, and source reuse.
- **Fix with:** make-invalid-states-unrepresentable, lifecycle-concurrency
- **Effort:** M
- **Design:** [Source-level network accounting](docs/rfc/MAC-2-network-source-accounting.md)

