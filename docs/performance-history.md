# Historical performance measurements

> Historical record, superseded as an operating guide by [profiling](profiling.md), [power](power.md), and [aggregate metrics](metrics.md).
> The measurements below have not been rerun or validated in this refresh. The text below overstates GPU phase coverage and describes entirely opt-in power timing. Current phase coverage and instrumentation limits are documented in the profiling reference.

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


## September 2026 watch list

The following record is preserved from the earlier TODO. Its SDK and toolchain observations were not revalidated in this refresh.

### 6. Watch list (Swift 6.4 / macOS 27 era)

Re-check these on each macOS 27.x seed and each Swift toolchain upgrade. None is actionable today; each was investigated in September 2026 and found not-yet-usable or not-applicable.

1. **`HOST_CPU_COUNTERS_INFO` / `energy_nj`.** The macOS 27 SDK headers add a `host_info` flavor reporting per-host user/system/idle time plus cycles, instructions, and `energy_nj` — but the 27.0 seed kernel returns zero items for it (verified live with a C probe: `kr=0`, out-count 0). If a later 27.x kernel implements it, the public energy counter could validate, or partially replace, the private-IOReport CPU-energy path. Re-probe per OS update alongside `MACTOP_DEBUG_POWER=1` channel validation.
2. **Borrowing iteration (`Iterable`, SE-0516).** Advertised for 6.4 but implementation status pointed at Swift 6.5. Re-evaluate copy-free `Span`/`InlineArray` iteration after the next toolchain upgrade; only relevant if hot buffers migrate to those types (see 3).
3. **`NonisolatedNonsendingByDefault` still opt-in.** Still an upcoming feature flag in Swift 6.4 — keep it in `Package.swift`. Remove only when a future Swift makes it the default (removing early would silently change `nonisolated async` executor semantics).
4. **Neural Engine memory attribution.** On macOS 27, Neural Engine memory is attributed to the app process instead of the system. When local models run, expect shifted per-process vs system RAM attribution while reconciling mactop RAM totals. No code change; context for interpreting the RAM popup.
5. **`hw.perflevelN.sharesl2` sysctl.** New in the 27 SDK; a bitmap of perflevels sharing L2 cache. Could refine E/P cluster topology detection in `MachCPUPlatform.readCoreKinds` on future chips. Correctness, not performance.
6. **Re-run `make bench` on the Xcode GM.** The 6.4/27.0 baseline and A/B comparison were built with Xcode 27.0 beta (27A266a); confirm the numbers hold before treating them as settled.
