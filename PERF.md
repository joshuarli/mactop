# Performance Plan

This document records the next performance work for `mactop`. The project previously migrated to **macOS 26.5.2** and **Swift 6.3.3** (commit 8a4df3e), which unblocked the deferred optimizations below; the power and GPU optimizations are both complete. It has since upgraded to **Swift 6.4 with macOS 27.0+ only** (`// swift-tools-version: 6.4`, `platforms: [.macOS("27.0")]`), built with the macOS 27.0 SDK. That upgrade is performance-neutral (see baseline below).

## Current Baseline

The baseline comes from the concurrent headless benchmark in `Sources/mactopBench/main.swift`, run through `make bench`:

- Nine isolated child processes run concurrently: CPU, RAM, GPU, power, network interface, CPU processes, RAM processes, network processes, and `SystemMetricsCoordinator`.
- Each child warms up for two ticks, then reads once per second (default 5 s; 20 s for the comparison runs below).
- The benchmark links only `mactopCore`; it does not start AppKit or the menu-bar application. The coordinator scenario uses a headless Foundation run loop and callback sinks.
- `includeHistory` is enabled, so this is a conservative core-read baseline.
- The network-interface reader performs no external network requests. The network-process reader exercises the private NetworkStatistics callback path in isolation.
- `make bench` builds `mactopBench` with `-c release` and runs `.build/release/mactopBench`. Baselines must come from release builds: a debug build measured ~2–3x higher per-tick CPU on the same machine (CPU 2.52 ms/tick debug vs ~1.0 release; coordinator 16.6 vs ~13).

Representative release run (Swift 6.4, macOS 27.0 SDK, 20 s / 20 ticks):

| Subsystem | CPU total | CPU per tick | Peak live allocations | Peak live bytes |
| --- | ---: | ---: | ---: | ---: |
| CPU | 11.33 ms | 0.567 ms | 2 | 1.1K |
| RAM | 0.44 ms | 0.022 ms | 0 | 0 B |
| GPU | 2.10 ms | 0.105 ms | 0 | 0 B |
| Power | 9.98 ms | 0.499 ms | 1 | 32 B |
| Network | 4.32 ms | 0.216 ms | 1 | 32 B |
| CPU processes | 20.07 ms | 1.004 ms | 86 | 6.9K |
| RAM processes | 2.66 ms | 0.133 ms | 2 | 128 B |
| Network processes | 1.53 ms | 0.076 ms | 206 | 14.2K |
| Coordinator | 101.23 ms | 5.061 ms | 3351 | 218.4K |

Steady-state power phases over those 20 ticks (`io_report.sample` runs on its 2-second cadence, 7 samples): `io_report.sample` 21.83 ms total / 1.091 ms per tick; `io_report.delta` 0.07 / 0.004; `io_report.parse` 0.02 / 0.001; `battery.read` 1.68 / 0.084. GPU `ioaccelerator.properties`: 1.98 / 0.099.

### Swift 6.4 / macOS 27 upgrade comparison

Before (Swift 6.3.3, macOS 26.5.2 target) vs after (Swift 6.4, macOS 27.0 target + SDK 27.0), paired 20-second release runs back-to-back on the same machine and power state, 30 s cooldown between runs:

| Subsystem | Before (6.3.3) | After (6.4) | Delta per tick |
| --- | ---: | ---: | ---: |
| CPU | 0.482 ms | 0.567 ms | +0.085 ms |
| RAM | 0.016 ms | 0.022 ms | +0.006 ms |
| GPU | 0.118 ms | 0.105 ms | −0.013 ms |
| Power | 0.600 ms | 0.499 ms | −0.101 ms |
| Network | 0.161 ms | 0.216 ms | +0.055 ms |
| CPU processes | 1.017 ms | 1.004 ms | −0.013 ms |
| RAM processes | 0.144 ms | 0.133 ms | −0.011 ms |
| Network processes | 0.079 ms | 0.076 ms | −0.003 ms |
| Coordinator | 5.366 ms | 5.061 ms | −0.305 ms |

Interleaved 5-second A/B rounds under shared load showed the same picture: deltas flip sign run to run and stay smaller than round-to-round drift. Verdict: the upgrade is performance-neutral; no systematic increase or decrease is attributable to it. An early post-upgrade run that looked slower was load contamination (`speechmaintenanced` at ~90% CPU), confirmed by re-measuring the old binary under the same load.

Methodology notes for future comparisons:

- Compare like-for-like runs on the same machine and power state, interleaved (alternate order per round) with a cooldown between runs; back-to-back runs without cooldown read hotter.
- Coordinator `cpu_ms/tick` amortizes a large fixed cost (~75 ms setup) over the run, so only compare equal durations.
- Per-tick heap scratch buffers in the platform readers (`allProcessIDs`, `allDecayCPUPercentages`, per-process `proc_name`/`proc_pidpath`, `loadAverage`, `brand_string`, `inet_ntop`) now use stack temporaries (`withUnsafeTemporaryAllocation`). This cut per-tick malloc churn by construction but did not move allocator high-water or `cpu_ms/tick`: peak is dominated by result structures (dictionaries, strings, ranked rows), and a 20 s post-change run measured flat allocator columns with CPU deltas fully explained by machine load (the untouched power reader tripled in the same run).
- This comparison was built with Xcode 27.0 beta (27A266a). Re-run `make bench` after moving to the Xcode GM and re-validate before claiming the numbers held.

The diagnostic phase recorder adds small timing and dictionary overhead, so phase values are for ranking bottlenecks, not for exact production CPU accounting. The normal app path leaves the recorder disabled.

## Power Bottlenecks

The phase timings are recorded by `CoreReadPhaseRecorder` in `Sources/mactop/Core/MetricReadPhaseRecorder.swift` and attached to `PowerTelemetryReader` in `Sources/mactop/Core/Power/PowerTelemetryReader.swift`.

The subscription filtering optimization (below) cut power from ~31.0 ms CPU total / 6.20 ms per tick to ~11.3 ms / 2.27 ms per tick, and the ID-cache parse cut `io_report.parse` from ~1.24 ms per tick to ~0.02 ms. The remaining cost was dominated by the fixed DCP display-power sample floor (~1.1 ms kernel round trip + ~1.2 ms DCP inherent, regardless of channel count). A cadence change (sampling the subscription every 2 s instead of every tick and holding the last computed sample in between) then cut the per-tick sample cost roughly in half, and single-key `AppleSmartBattery` reads replaced the full property-tree read. Power is now ~0.5–1.0 ms CPU per tick, dominated by `io_report.sample`; `io_report.sample` wall time still varies run to run (~3 ms when it runs), but it only runs every other tick. `cpu_ms/tick` is the stable comparison metric.

Representative steady-state power phases over five ticks after both power optimizations:

| Phase | Total wall time | Per tick |
| --- | ---: | ---: |
| `io_report.sample` | 3.0–6.5 ms | 0.6–1.3 ms |
| `io_report.parse` | 0.04–0.11 ms | 0.008–0.022 ms |
| `io_report.delta` | 0.07–0.13 ms | 0.013–0.026 ms |
| `battery.read` | 0.38–0.58 ms | 0.076–0.115 ms |
| `history.append` + `history.snapshot` | 0.04–0.10 ms | 0.008–0.021 ms |

`io_report.sample` runs on a 2-second cadence, so in a 5-tick window it appears 1–2 times and `battery.read` is cached every 2 s, matching the modeled-sample cadence.

### Power optimization status

1. **Investigate IOReport sampling cost.** Done. The old subscription included all 591 channels in the `Energy Model` (162), `DCP` (143), `DCPEXT0` (143), and `DCPEXT1` (143) groups; only ~18 matched `classifyChannel`. `copyPowerChannels` now filters the subscription to the classified set, so the kernel samples ~18 channels instead of 591, cutting `io_report.sample` from ~4.7 ms per tick to ~2.9 ms.
2. **Reduce channel parsing work.** Done. `buildChannelCache` precomputes bucket and unit divisor per channel keyed on `(driverID, channelID)`, and `classifiedChannel`/`parsePower` use that cache with a string-classification fallback. `io_report.parse` dropped from ~1.27 ms per tick to ~0.02 ms. The cache never reorders channels; a renamed channel silently falls back to the old string path.
3. **Preserve dynamic channel matching.** Done. The filtered set is derived from the same `classifyChannel` rule the parser uses, DCPEXT display-power channels are deliberately kept (pruning them saves no sample time — 1 or 3 DCP channels cost the same), and the cache keeps the string fallback. Validate with `MACTOP_DEBUG_POWER=1` after every channel-parser change or macOS/chip update.
4. **Reduce sample cadence.** Done. Sampling the filtered subscription every tick cost ~3 ms of kernel time per tick. `ModeledPowerReader.readModeledPowerSample()` now samples at a 2-second interval and returns the last computed sample in between. IOReport counters are accumulated energy, so a 2-second delta is as accurate as a 1-second delta, and the reader's existing `maximumSampleInterval` guard already tolerated 5-second gaps. The System total still updates every tick from `AppleSmartBattery`; only the component breakdown refreshes on the slower cadence.
5. **Reduce battery work.** Done. `BatteryPowerReader` read the entire `AppleSmartBattery` property tree (~60 keys, ~0.6 ms) every read. It now does single-key `IORegistryEntryCreateCFProperty` reads for just the keys it uses (~0.1 ms total, values verified identical). `battery.read` dropped from ~0.16 ms to ~0.08 ms per tick (it is also already cached every 2 s).

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

- The one-second default cadence unless an explicit product decision changes it. The power reader's internal 2-second IOReport sample cadence is an explicit exception: the menu-bar System total still updates every tick via `AppleSmartBattery`, and only the modeled component breakdown refreshes on the slower cadence.
- System power versus modeled component power semantics, including the visible system-minus-modeled baseline.
- GPU total, renderer, and tiler values on supported Intel and Apple Silicon systems.
- Dynamic power-channel matching and `MACTOP_DEBUG_POWER=1` diagnostics.
- Headless benchmark isolation: no AppKit, `NSStatusItem`, popup, or `SystemMetricsCoordinator` work.

## Validation After Migration

After migrating to macOS 27.0+ and Swift 6.4 (done — see baseline above):

1. ~~Record a fresh unmodified baseline with `make bench`.~~ Done: release baseline + paired 6.3.3/6.4 A/B, verdict performance-neutral.
2. ~~Run at least three comparable benchmark samples on the same power state.~~ Done: three 5 s release runs pre-upgrade, three interleaved 5 s A/B rounds, one paired 20 s A/B.
3. ~~Compare `cpu_ms`, `cpu_ms/tick`, phase wall time, peak live allocations, and peak footprint.~~ Done, see table.
4. ~~Run `swift build` and `swift test`.~~ Done: `swift build -c release` clean, 25/25 tests pass under Xcode 27 Swift 6.4.
5. Run the app and verify power/GPU values visually and with `MACTOP_DEBUG_POWER=1` where relevant.
6. Keep an optimization only when it improves steady-state cost without changing the supported metric contract.
