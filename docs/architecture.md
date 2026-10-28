# Architecture

[Package.swift](../Package.swift) separates four targets: the unsafe macOS boundary `mactopPlatform`, typed readers in `mactopCore`, AppKit executable `mactop`, and headless `mactopBench`.
The core depends on the platform target. Both executables depend on the core. There are no package dependencies.
[MactopFormat.swift](../Sources/mactop/Core/MactopFormat.swift) provides string formatting for both executables.

## Source map

The reader and platform files own each subsystem:

| Topic | Reader | Platform |
| --- | --- | --- |
| CPU | [CPUUsageReader.swift](../Sources/mactop/Core/CPU/CPUUsageReader.swift) | [MachCPUPlatform.swift](../Sources/mactop/Platform/MachCPUPlatform.swift) |
| RAM | [RAMUsageReader.swift](../Sources/mactop/Core/RAM/RAMUsageReader.swift) | [MachRAMPlatform.swift](../Sources/mactop/Platform/MachRAMPlatform.swift) |
| GPU | [GPUUsageReader.swift](../Sources/mactop/Core/GPU/GPUUsageReader.swift) | [IOAcceleratorPlatform.swift](../Sources/mactop/Platform/IOAcceleratorPlatform.swift) |
| Power | [PowerTelemetryReader.swift](../Sources/mactop/Core/Power/PowerTelemetryReader.swift) | [PowerTelemetryPlatform.swift](../Sources/mactop/Platform/PowerTelemetryPlatform.swift) |
| Network | [NetworkInterfaceReader.swift](../Sources/mactop/Core/Network/NetworkInterfaceReader.swift) | [NetworkInterfacePlatform.swift](../Sources/mactop/Platform/NetworkInterfacePlatform.swift) |

Process rankings have [their own readers and shared support](processes.md).
[MactopApp.swift](../Sources/mactop/UI/MactopApp.swift) owns lifecycle and popup routing.
[StatusItemViews.swift](../Sources/mactop/UI/StatusItemViews.swift), [MetricPopups.swift](../Sources/mactop/UI/MetricPopups.swift), and [MetricCharts.swift](../Sources/mactop/UI/MetricCharts.swift) own presentation.

## Runtime and ownership

`MactopAppDelegate` registers network, CPU, RAM, GPU, and PWR status items from one list of view/panel entries.
Network is registered first to reduce the chance macOS hides it when menu-bar space is tight.

[SystemMetricsCoordinator.swift](../Sources/mactop/Core/SystemMetricsCoordinator.swift) uses one interval timer on a serial coordinator queue.
Each reader runs on its own utility queue, with an in-flight flag preventing overlapping reads.
Results return through the coordinator queue and then the main queue.
Readers and the coordinator guard mutable state with a `Synchronization.Mutex` on top of queue confinement, so the types are strictly `Sendable`.
The private-framework bindings stay outside that rule: [NetworkStatisticsPlatform.swift](../Sources/mactop/Platform/NetworkStatisticsPlatform.swift) and [PowerTelemetryPlatform.swift](../Sources/mactop/Platform/PowerTelemetryPlatform.swift) hold `dlopen` handles, retained C blocks, and CF containers that Swift 6 cannot prove safe, and [PowerTelemetryReader.swift](../Sources/mactop/Core/Power/PowerTelemetryReader.swift) owns the modeled-power reader. Those three files are exempt from the unchecked-concurrency rule; everything else must stay strictly `Sendable`.
History snapshots are delivered for visible popups. Readers continue collecting history while popups are hidden.

Process lists refresh on opening a matching popup and every three seconds while visible.
CPU also gets one startup read. NetworkStatistics initialization is lazy.
Pausing clears aggregate history and displayed values. Sleep stops scheduled reads. Wake resets power sampling while preserving chart history.

## History

[MetricHistory.swift](../Sources/mactop/Core/MetricHistory.swift) stores bounded, timestamped samples for a five-minute window.
Charts use timestamps to leave gaps across unavailable spans rather than allocating placeholders for every missed tick.
Smoothing applies to chart samples. Current metric values remain separate from the smoothed history.
