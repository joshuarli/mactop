# Performance Plan

This document records the next performance work for `mactop`. The project has migrated to **macOS 26.5.2** and **Swift 6.3.3** (commit 8a4df3e), so the deferred optimizations below are unblocked. The power and GPU optimizations are both complete.

## Current Baseline

The baseline comes from the concurrent headless benchmark in `Sources/mactopBench/main.swift`, run through `make bench`:

- Five isolated child processes run concurrently: CPU, RAM, GPU, power, and network.
- Each child warms up for two ticks, then reads once per second for five seconds.
- The benchmark links only `mactopCore`; it does not start AppKit or the menu-bar application.
- `includeHistory` is enabled, so this is a conservative core-read baseline.
- The network reader performs no external network requests.

Representative diagnostic run:

| Subsystem | CPU total | CPU per tick | Peak live allocations | Peak live bytes |
| --- | ---: | ---: | ---: | ---: |
| CPU | 0.35 ms | 0.070 ms | 0 | 80 B |
| RAM | 0.14 ms | 0.029 ms | 0 | 16 B |
| GPU | 0.69 ms | 0.139 ms | 0 | 16 B |
| Power | 11.33 ms | 2.266 ms | 0 | 16 B |
| Network | 0.36 ms | 0.072 ms | 0 | 16 B |

The diagnostic phase recorder adds small timing and dictionary overhead, so phase values are for ranking bottlenecks, not for exact production CPU accounting. The normal app path leaves the recorder disabled.

## Power Bottlenecks

The phase timings are recorded by `CoreReadPhaseRecorder` in `Sources/mactop/Core/MetricReadPhaseRecorder.swift` and attached to `PowerTelemetryReader` in `Sources/mactop/Core/Power/PowerTelemetryReader.swift`.

The subscription filtering optimization (below) cut power from ~31.0 ms CPU total / 6.20 ms per tick to ~11.3 ms / 2.27 ms per tick, and the ID-cache parse cut `io_report.parse` from ~1.24 ms per tick to ~0.02 ms. The remaining cost is dominated by the fixed DCP display-power sample floor (~1.1 ms kernel round trip + ~1.2 ms DCP inherent, regardless of channel count). `io_report.sample` wall time varies run to run (2.9–3.4 ms per tick); `cpu_ms/tick` is the stable comparison metric.

Representative steady-state power phases over five ticks after the optimization:

| Phase | Total wall time | Per tick |
| --- | ---: | ---: |
| `io_report.sample` | 14.5–17.0 ms | 2.9–3.4 ms |
| `io_report.parse` | 0.11 ms | 0.02 ms |
| `io_report.delta` | 0.16 ms | 0.03 ms |
| `battery.read` | 0.82 ms | 0.16 ms |
| `history.append` + `history.snapshot` | 0.06 ms | 0.01 ms |

### Power optimization status

1. **Investigate IOReport sampling cost.** Done. The old subscription included all 591 channels in the `Energy Model` (162), `DCP` (143), `DCPEXT0` (143), and `DCPEXT1` (143) groups; only ~18 matched `classifyChannel`. `copyPowerChannels` now filters the subscription to the classified set, so the kernel samples ~18 channels instead of 591, cutting `io_report.sample` from ~4.7 ms per tick to ~2.9 ms.
2. **Reduce channel parsing work.** Done. `buildChannelCache` precomputes bucket and unit divisor per channel keyed on `(driverID, channelID)`, and `classifiedChannel`/`parsePower` use that cache with a string-classification fallback. `io_report.parse` dropped from ~1.27 ms per tick to ~0.02 ms. The cache never reorders channels; a renamed channel silently falls back to the old string path.
3. **Preserve dynamic channel matching.** The filtered set is derived from the same `classifyChannel` rule the parser uses, DCPEXT display-power channels are deliberately kept (pruning them saves no sample time — 1 or 3 DCP channels cost the same), and the cache keeps the string fallback. Validate with `MACTOP_DEBUG_POWER=1` after every channel-parser change or macOS/chip update.
4. **Leave history and battery work alone.** Confirmed: combined cost is ~0.17 ms per tick, not worth complexity.

## GPU Bottlenecks

`GPUUsageReader.readGPUUsageDetail()` in `Sources/mactop/Core/GPU/GPUUsageReader.swift` was dominated by the steady-state `ioaccelerator.properties` phase:

- Before: `IORegistryEntryCreateCFProperties(...)` plus the `PerformanceStatistics` dictionary bridge cost approximately `2.46 ms` per tick (GPU ~2.5 ms CPU per tick total).
- After: reading only the `PerformanceStatistics` property with `IORegistryEntryCreateCFProperty(...)` and extracting values via `CFDictionaryGetValue`/`CFNumberGetValue` costs approximately `0.12 ms` per tick (GPU ~0.14 ms CPU per tick total). Full-properties read remains as a fallback.
- History append and history snapshots are negligible.
- IOAccelerator service discovery is a warm-up-only cost in the current benchmark.

### GPU optimization status

1. **Avoid broad Swift dictionary bridging.** Done. `readSingleKeyPerformanceStatistics` reads just the `PerformanceStatistics` property and the three numeric fields at the CF level, skipping the full `[String: Any]` bridge of the entire property tree. Verified identical live values at the one-second cadence.
2. **Compare equivalent IOKit access paths.** Done, with an important caveat: `IORegistryEntrySearchCFProperty` returns a different (stale) snapshot than the full-properties read — do not use it. `IORegistryEntryCreateCFProperty` (single key, no recursion) returns the same live dict as `IORegistryEntryCreateCFProperties` at the one-second cadence and is ~20x cheaper. Also more robust under competition: when another tool (Activity Monitor, Stats) polls the same service, the full-properties path degrades to zeros while the single-key path stays live.
3. **Consider cadence only after access-path work.** Not needed; the access-path work removed the bottleneck without touching the one-second cadence.

## Guardrails

Every optimization must preserve:

- The one-second default cadence unless an explicit product decision changes it.
- System power versus modeled component power semantics, including the visible system-minus-modeled baseline.
- GPU total, renderer, and tiler values on supported Intel and Apple Silicon systems.
- Dynamic power-channel matching and `MACTOP_DEBUG_POWER=1` diagnostics.
- Headless benchmark isolation: no AppKit, `NSStatusItem`, popup, or `SystemMetricsCoordinator` work.

## Validation After Migration

After migrating to macOS 26.5.2+ and Swift 6.3.3+:

1. Record a fresh unmodified baseline with `make bench`.
2. Run at least three comparable benchmark samples on the same power state.
3. Compare `cpu_ms`, `cpu_ms/tick`, phase wall time, peak live allocations, and peak footprint.
4. Run `swift build` and `swift test`.
5. Run the app and verify power/GPU values visually and with `MACTOP_DEBUG_POWER=1` where relevant.
6. Keep an optimization only when it improves steady-state cost without changing the supported metric contract.
