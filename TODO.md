### 1. Make power phase timing genuinely opt-in

This is the clearest low-risk improvement.

`PlatformModeledPowerReader` currently maintains `phaseTotals` and calls `measurePhase(...)` even when no `CoreReadPhaseRecorder` is attached. `PowerTelemetryReader` only consumes those timings when benchmarking, but the timing dictionary and `DispatchTime` calls still occur in the normal app path.

That overhead is likely small because modeled power samples only occur every two seconds, but it contradicts the intended âopt-in phase timingâ design. We could add a `recordPhases` flag and make production power reads skip:

- `DispatchTime.now()` timing calls
- phase dictionary updates
- phase dictionary clearing

This is worth doing for cleanliness and marginal runtime overhead.

### 2. Avoid resolving RAM process names before ranking

`RAMProcessMemoryReader` currently does this for every process:

```swift
RankedProcessMetric(pid: pid, name: processName(pid: pid), value: Double(mem))
```

That means process display-name/path/bundle resolution happens before the reader knows whether the process is in the top eight.

A better flow is:

1. Rank `(pid, memory)` pairs.
2. Resolve names only for the final top eight.

This may reduce work on systems with many processes, although the current benchmark says the reader is already only about 0.5â0.6 ms per read.

The same pattern exists in the native CPU path, but the common CPU path is `/bin/ps`, which already returns only the requested top rows, so the CPU case is less important.

### 3. Potentially batch coordinator deliveries

Each aggregate metric currently does:

```text
reader queue
  -> coordinator queue
    -> main queue callback
```

five separate times per interval.

A future batch API could deliver one aggregate snapshot:

```swift
MetricsSnapshot(cpu: ..., ram: ..., gpu: ..., power: ..., network: ...)
```

with one main-queue hop instead of five. This could reduce dispatch overhead and simplify synchronization, but it would be an API/state-flow change rather than an obvious necessity.

I would not do this unless UI responsiveness or coordinator CPU becomes measurable on slower Macs.

### 4. UI process icon work is not covered

The headless benchmark does not exercise:

```swift
NSRunningApplication(processIdentifier:)
NSWorkspace.shared.runningApplications
```

in `RankedProcessListView.iconForProcess`.

That work is cached and only occurs for visible popups, so it is probably fine. But if profiling the actual app shows main-thread spikes while opening or refreshing a process popup, icon resolution is the first UI area I would investigate.

### 5. Keep process readers visible-only

This is already the right design. Running the process readers every second while the popups are hidden would be a needless cost increase. The current three-second visible-only refresh policy is appropriate.

## Recommendation

I would not pursue broad optimization or architectural changes right now.

Priority order:

1. **Gate power phase instrumentation in production.**
2. **Defer RAM process name resolution until after ranking.**
3. Leave coordinator batching and queue consolidation alone unless real UI profiling identifies a problem.
4. Use Instruments on the actual AppKit app only if popup interaction feels slow; the core benchmark already indicates the readers are not a concern.

So: yes, the utility is currently lean, and there is no obvious memory leak or high-cost subsystem demanding immediate work.

### 6. Watch list (Swift 6.4 / macOS 27 era)

Re-check these on each macOS 27.x seed and each Swift toolchain upgrade. None is actionable today; each was investigated in September 2026 and found not-yet-usable or not-applicable.

1. **`HOST_CPU_COUNTERS_INFO` / `energy_nj`.** The macOS 27 SDK headers add a `host_info` flavor reporting per-host user/system/idle time plus cycles, instructions, and `energy_nj` — but the 27.0 seed kernel returns zero items for it (verified live with a C probe: `kr=0`, out-count 0). If a later 27.x kernel implements it, the public energy counter could validate, or partially replace, the private-IOReport CPU-energy path. Re-probe per OS update alongside `MACTOP_DEBUG_POWER=1` channel validation.
2. **Borrowing iteration (`Iterable`, SE-0516).** Advertised for 6.4 but implementation status pointed at Swift 6.5. Re-evaluate copy-free `Span`/`InlineArray` iteration after the next toolchain upgrade; only relevant if hot buffers migrate to those types (see 3).
3. **`NonisolatedNonsendingByDefault` still opt-in.** Still an upcoming feature flag in Swift 6.4 — keep it in `Package.swift`. Remove only when a future Swift makes it the default (removing early would silently change `nonisolated async` executor semantics).
4. **Neural Engine memory attribution.** On macOS 27, Neural Engine memory is attributed to the app process instead of the system. When local models run, expect shifted per-process vs system RAM attribution while reconciling mactop RAM totals. No code change; context for interpreting the RAM popup.
5. **`hw.perflevelN.sharesl2` sysctl.** New in the 27 SDK; a bitmap of perflevels sharing L2 cache. Could refine E/P cluster topology detection in `MachCPUPlatform.readCoreKinds` on future chips. Correctness, not performance.
6. **Re-run `make bench` on the Xcode GM.** The 6.4/27.0 baseline and A/B comparison were built with Xcode 27.0 beta (27A266a); confirm the numbers hold before treating them as settled.
