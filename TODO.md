Prefix: MAC
Next: 16

### MAC-15 · P3 · Subsystem identity is a bare Int repeated across parallel arrays

- **Area:** Types
- **Where:** `Sources/mactop/Core/SystemMetricsCoordinator.swift:21`, `Sources/mactop/Core/SystemMetricsCoordinator.swift:78`, `Sources/mactop/UI/MactopApp.swift:44`, `Sources/mactop/UI/MactopApp.swift:78`, `Sources/mactop/UI/MactopApp.swift:174`, `Sources/mactop/UI/MactopApp.swift:242`, `Sources/mactop/UI/MactopApp.swift:352`, `Sources/mactopBench/main.swift:257`
- **Problem:** Which subsystem an index means (`0`=network, `1`=CPU, `2`=RAM, `3`=GPU) is written down independently at six sites: the coordinator's `historyEnabled[4]` unpacking, the app delegate's `statusPanels` order, its process-refresh timer and switches, its popup-refresh switch, and the benchmark's `0..<4` loop. Nothing rejects a mismatch, and `refreshProcesses` silently ignores index 3 via `default: break`. The values agree today, so this is guard tax: reordering the entry list (whose network-first order is load-bearing per `docs/architecture.md`) or adding a subsystem silently misroutes history and process refreshes.
- **Recommendation:** Introduce one subsystem enum and key `historyEnabled`, the coordinator API, and the app delegate's routing by it, so an unmapped subsystem cannot be represented.
- **Fix with:** make-invalid-states-unrepresentable
- **Effort:** M
