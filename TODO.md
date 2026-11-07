Prefix: MAC
Next: 16

### MAC-13 · P2 · Resuming from pause leaves an open panel's charts without history

- **Area:** Architecture
- **Where:** `Sources/mactop/Core/SystemMetricsCoordinator.swift:21`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:69`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:78`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:163`, `Sources/mactop/UI/MactopApp.swift:206`, `Sources/mactop/UI/MactopApp.swift:341`, `Sources/mactop/UI/MetricPopups.swift:666`
- **Problem:** Panel-history delivery is split between panel visibility in the app delegate and `historyEnabled` in the coordinator, and pause resets only the coordinator copy. Open a panel (`setHistoryEnabled(true)`, `MactopApp.swift:341`), then pause and resume from the panel's own button: `SystemMetricsCoordinator.setPaused` clears `historyEnabled` when pausing (`SystemMetricsCoordinator.swift:170`) and on resume only clears `isPaused` (`SystemMetricsCoordinator.swift:167`), and `MactopAppDelegate.setPaused` never re-enables history for the still-visible panel (`MactopApp.swift:206`). Every later tick therefore delivers `history: []` (`SystemMetricsCoordinator.swift:69`, `78`) while the readers keep appending internally, so the open panel's charts stay empty for the rest of that panel session; closing and reopening the panel is the only recovery. No test covers pause/resume. The same delivery gap shows on open: `refreshPopup(syncHistory: true)` passes a flag every popup update discards (`MetricPopups.swift:666` `syncHistory _:`), so the chart is blank until the next coordinator tick.
- **Recommendation:** On resume, re-enable history for the panels that are still visible (the app delegate owns `isVisible`), and make opening a panel deliver the existing history immediately instead of waiting for a tick.
- **Fix with:** lifecycle-concurrency
- **Effort:** S

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
