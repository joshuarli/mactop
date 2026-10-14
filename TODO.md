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

### MAC-6 · P2 · Power validation tests exercise an unused production copy

- **Area:** Tests
- **Where:** `Tests/mactopTests/ProcessReadersTests.swift:106`, `Sources/mactop/Core/Power/PowerTelemetryReader.swift:22`, `Sources/mactop/Platform/PowerTelemetryPlatform.swift:36`
- **Problem:** The passing validation tests call `validatedPowerReadingWatts`, which has no production callers. Actual power parsing calls the separate private `platformValidatedPower`, with its own 2,000 W limit. Removing or changing the real guard leaves these tests green. A source-wide caller search confirms the split.
- **Recommendation:** Give power validation one production owner and exercise that owner from the tests. Remove the test-only copy and cover invalid values at the reader boundary.
- **Fix with:** test-audit, single-source-of-truth
- **Effort:** S

### MAC-7 · P2 · The release workflow publishes without running tests

- **Area:** Build
- **Where:** `.github/workflows/release.yml:28`, `.github/workflows/release.yml:39`
- **Problem:** The manually dispatched workflow compiles mactop, uploads the binary, and creates a pre-release. It has no test step or dependency on a test job. A compile-successful regression can ship without executing the existing core tests. The local focused tests pass, so adding a gate does not require fixing a failing baseline first.
- **Recommendation:** Run the existing core test suite before artifact upload, and make release creation depend on its success. Keep release packaging separate from optional benchmarks.
- **Fix with:** none
- **Effort:** S

### MAC-8 · P3 · Modeled power phase timing runs in production

- **Area:** Performance
- **Where:** `Sources/mactop/Platform/PowerTelemetryPlatform.swift:175`, `Sources/mactop/Platform/PowerTelemetryPlatform.swift:220`
- **Problem:** `readModeledPowerSample()` clears `phaseTotals` and calls `measurePhase` for samples, deltas, and parsing even when no core recorder is attached. Timing calls and dictionary updates remain on the normal app path. This re-verifies the earlier TODO. The runtime cost has not been measured.
- **Recommendation:** Pass the instrumentation requirement into the platform reader and skip timing and dictionary work when absent. Measure comparable runs before claiming a speedup.
- **Fix with:** make-it-fast, benchmark-checklist
- **Effort:** S

### MAC-9 · P3 · RAM ranking resolves names before selecting retained rows

- **Area:** Performance
- **Where:** `Sources/mactop/Core/Processes/RAMProcessMemoryReader.swift:26`
- **Problem:** Each readable PID resolves a process name before sorted insertion discards rows below the limit. Name/path/bundle lookup is unnecessary for rows that never reach the UI. This re-verifies the earlier TODO. No speedup or runtime regression is established, and enumeration correctness must be fixed first.
- **Recommendation:** Rank PID and memory values first, then resolve only retained names. Verify ranking parity and measure before reporting savings.
- **Fix with:** make-it-fast, reference-parity
- **Effort:** S

### MAC-10 · P3 · Coordinator benchmark peak columns contain endpoint deltas

- **Area:** Performance
- **Where:** `Sources/mactopBench/main.swift:279`, `Sources/mactopBench/main.swift:288`, `Sources/mactopBench/main.swift:160`
- **Problem:** Coordinator measurement samples memory only before and after its run-loop window, then labels the differences as peaks. Temporary allocations and footprints released before the endpoint cannot appear. Reader scenarios sample after each read, so the identically named columns have different coverage. The refreshed profiling doc states the limitation, but the executable report still hides it.
- **Recommendation:** Sample coordinator memory during its run loop, or label endpoint deltas distinctly. Add a controlled allocation scenario that rises and falls during the window.
- **Fix with:** benchmark-checklist, isolate-effects
- **Effort:** S
