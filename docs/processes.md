# Process ranking

Process rows represent individual PIDs. Children are not grouped under a responsible parent.

[ProcessReaderSupport.swift](../Sources/mactop/Core/Processes/ProcessReaderSupport.swift) owns ranked rows, CPU delta calculation, sorted insertion, and ps parsing.
[ProcessDisplayName.swift](../Sources/mactop/Core/Processes/ProcessDisplayName.swift) resolves names and app bundles for CPU and RAM readers.
[ProcessPlatform.swift](../Sources/mactop/Platform/ProcessPlatform.swift) owns libproc access.

## CPU

[CPUProcessUsageReader.swift](../Sources/mactop/Core/Processes/CPUProcessUsageReader.swift) probes PID 1 telemetry once at initialization.
When that succeeds, readable processes use `proc_pid_rusage` nanosecond deltas. Other processes use `KERN_PROC_ALL` decay-average percentages.
Without root-process telemetry, the reader runs `/bin/ps -Aceo pid,pcpu,comm -r` and parses its decay-average values.
Resolved process names fall back to ps command names.

Cross-user instantaneous telemetry is restricted by macOS permissions and entitlements.
The application does not install a privileged helper. The checked-in entitlement file is not passed to the current signing commands.
Self-signing an Apple-private entitlement is not a supported way to obtain cross-user access.

## RAM

[RAMProcessMemoryReader.swift](../Sources/mactop/Core/Processes/RAMProcessMemoryReader.swift) prefers `ri_phys_footprint`, then falls back to resident memory from `proc_pidinfo`.
Physical footprint corresponds to Activity Monitor's memory metric. Resident memory has different semantics.
Cross-user visibility depends on the caller's access to those APIs. A process with neither readable value is skipped.

## NetworkStatistics

[NetworkProcessReader.swift](../Sources/mactop/Core/Processes/NetworkProcessReader.swift) reads private framework counters through [NetworkStatisticsPlatform.swift](../Sources/mactop/Platform/NetworkStatisticsPlatform.swift).
It loads `/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics` lazily with `RTLD_NOW`. It never invokes nettop.
Missing symbols, manager creation failure, or failed source registration leave ranking empty.

The platform file owns the exact `NStat*` symbols and `kNStatSrcKey*` keys loaded with `dlsym`.
Description and count callbacks can arrive separately or omit PID/name. The platform merges dictionaries by source pointer.
TCP and UDP registration accept nonnegative return values, including positive success values.
The dynamically loaded image stays resident because no documented manager-destroy API guarantees callbacks have stopped.

A refresh waits up to 750 ms, then reads stored counters even if completion timed out.
Current ranking has correctness defects tracked in [TODO.md](../TODO.md).
