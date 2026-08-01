# Performance Plan

This document records the next performance work for `mactop`. The work is intentionally deferred until the project migrates to **macOS 26.5.2 or newer** and **Swift 6.3.3 or newer**. Do not begin the optimization work below before that migration unless a production regression requires it.

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
| GPU | 13.30 ms | 2.660 ms | 0 | 16 B |
| Power | 32.40 ms | 6.480 ms | 0 | 0 B |
| Network | 0.36 ms | 0.072 ms | 0 | 16 B |

The diagnostic phase recorder adds small timing and dictionary overhead, so phase values are for ranking bottlenecks, not for exact production CPU accounting. The normal app path leaves the recorder disabled.

## Power Bottlenecks

The phase timings are recorded by `CoreReadPhaseRecorder` in `Sources/mactop/Core/MetricReadPhaseRecorder.swift` and attached to `PowerTelemetryReader` in `Sources/mactop/Core/Power/PowerTelemetryReader.swift`.

Representative steady-state power phases over five ticks:

| Phase | Total wall time | Per tick |
| --- | ---: | ---: |
| `io_report.sample` | 23.60 ms | 4.72 ms |
| `io_report.parse` | 6.37 ms | 1.27 ms |
| `io_report.delta` | 4.85 ms | 0.97 ms |
| `battery.read` | 1.92 ms | 0.38 ms |
| `history.append` + `history.snapshot` | 0.04 ms | 0.01 ms |

### Power optimization order

1. **Investigate IOReport sampling cost.** The `api.createSamples(...)` call in `PowerTelemetryReader.ModeledPowerReader.rawSample()` is the dominant phase. Check whether macOS 26.5.2/IOReport provides a lighter sample path, a reusable sample object, or a safe lower-frequency cadence.
2. **Reduce channel parsing work.** `PowerTelemetryReader.ModeledPowerReader.parsePower()` repeatedly converts group, subgroup, channel, and unit values to Swift strings for every channel. Cache stable channel classification and unit metadata where the private ABI makes that safe.
3. **Preserve dynamic channel matching.** Any cache must continue to support Apple changing channel names, DCP/DCPEXT display groups, and the existing aggregate-versus-detail-channel exclusions. Validate with `MACTOP_DEBUG_POWER=1` after every channel-parser change.
4. **Leave history and battery work alone initially.** Their measured cost is too small to justify complexity before the IOReport path is addressed.

## GPU Bottlenecks

`GPUUsageReader.readGPUUsageDetail()` in `Sources/mactop/Core/GPU/GPUUsageReader.swift` is dominated by the steady-state `ioaccelerator.properties` phase:

- `IORegistryEntryCreateCFProperties(...)` and the `PerformanceStatistics` dictionary bridge account for approximately `2.67 ms` per tick.
- History append and history snapshots are negligible.
- IOAccelerator service discovery is a warm-up-only cost in the current benchmark.

### GPU optimization order

1. **Avoid broad Swift dictionary bridging.** Test direct Core Foundation lookups for `PerformanceStatistics` and its numeric fields instead of converting the full property tree to `[String: Any]`.
2. **Compare equivalent IOKit access paths.** Measure `IORegistryEntrySearchCFProperty` or another supported property lookup only if it preserves Intel and Apple Silicon key behavior.
3. **Consider cadence only after access-path work.** Lowering GPU polling frequency may reduce overhead, but it changes menu-bar freshness and should be a product decision rather than a hidden optimization.

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
