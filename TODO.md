Prefix: MAC
Next: 16

### MAC-14 · P3 · Sleeping is checked only when kicking reads, not when deliveries land

- **Area:** Concurrency
- **Where:** `Sources/mactop/Core/SystemMetricsCoordinator.swift:68`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:91`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:186`, `Sources/mactop/UI/MactopApp.swift:170`, `Sources/mactop/UI/MactopApp.swift:242`
- **Problem:** The running/paused/sleeping lifecycle is three booleans (`isPaused`, `isSleeping`, `dataEpoch`, `SystemMetricsCoordinator.swift:22`) plus a second paused/epoch pair in the app delegate (`MactopApp.swift:56`), guarded at 11 sites for paused but only 1 site for sleeping: the kick guard (`SystemMetricsCoordinator.swift:68`) checks sleeping, the four delivery guards (`SystemMetricsCoordinator.swift:91`, `106`, `121`, `137`) do not, and the app delegate has no sleeping flag at all, so its 3-second process timer (`MactopApp.swift:170`) and `refreshProcesses` (`MactopApp.swift:242`) run from the will-sleep window onward. A read kicked just before sleep is delivered after wake as if current, and the first post-wake process/network rates span the sleep interval. Chart timestamp gaps mask most of it, so this is guard tax, not a demonstrated wrong display.
- **Recommendation:** Bump `dataEpoch` in `systemWillSleep` so the existing delivery guards drop pre-sleep reads, and gate the app delegate's process timer and `refreshProcesses` on the same sleeping state.
- **Fix with:** lifecycle-concurrency
- **Effort:** S

### MAC-15 · P3 · Subsystem identity is a bare Int repeated across parallel arrays

- **Area:** Types
- **Where:** `Sources/mactop/Core/SystemMetricsCoordinator.swift:21`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:78`, `Sources/mactop/UI/MactopApp.swift:44`, `Sources/mactop/UI/MactopApp.swift:78`, `Sources/mactop/UI/MactopApp.swift:174`, `Sources/mactop/UI/MactopApp.swift:242`, `Sources/mactop/UI/MactopApp.swift:352`, `Sources/mactopBench/main.swift:257`
- **Problem:** Which subsystem an index means (`0`=network, `1`=CPU, `2`=RAM, `3`=GPU) is written down independently at six sites: the coordinator's `historyEnabled[4]` unpacking, the app delegate's `statusPanels` order, its process-refresh timer and switches, its popup-refresh switch, and the benchmark's `0..<4` loop. Nothing rejects a mismatch, and `refreshProcesses` silently ignores index 3 via `default: break`. The values agree today, so this is guard tax: reordering the entry list (whose network-first order is load-bearing per `docs/architecture.md`) or adding a subsystem silently misroutes history and process refreshes.
- **Recommendation:** Introduce one subsystem enum and key `historyEnabled`, the coordinator API, and the app delegate's routing by it, so an unmapped subsystem cannot be represented.
- **Fix with:** make-invalid-states-unrepresentable
- **Effort:** M
