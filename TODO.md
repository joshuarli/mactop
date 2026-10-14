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

### MAC-10 · P3 · Coordinator benchmark peak columns contain endpoint deltas

- **Area:** Performance
- **Where:** `Sources/mactopBench/main.swift:279`, `Sources/mactopBench/main.swift:288`, `Sources/mactopBench/main.swift:160`
- **Problem:** Coordinator measurement samples memory only before and after its run-loop window, then labels the differences as peaks. Temporary allocations and footprints released before the endpoint cannot appear. Reader scenarios sample after each read, so the identically named columns have different coverage. The refreshed profiling doc states the limitation, but the executable report still hides it.
- **Recommendation:** Sample coordinator memory during its run loop, or label endpoint deltas distinctly. Add a controlled allocation scenario that rises and falls during the window.
- **Fix with:** benchmark-checklist, isolate-effects
- **Effort:** S
