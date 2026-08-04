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
