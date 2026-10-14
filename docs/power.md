# Power telemetry

[PowerTelemetryReader.swift](../Sources/mactop/Core/Power/PowerTelemetryReader.swift) reconciles system consumption with modeled component energy.
[PowerTelemetryPlatform.swift](../Sources/mactop/Platform/PowerTelemetryPlatform.swift) owns AppleSmartBattery and private IOReport access, including exact symbols and property keys.

## System consumption and charging

AppleSmartBattery reads use individual `IORegistryEntryCreateCFProperty` lookups. Battery telemetry is cached for two seconds.
The core prefers `SystemEnergyConsumed` for system consumption, then the platform's input-power estimate.
The input estimate tries `SystemPowerIn`, `SystemCurrentIn * SystemVoltageIn`, `SystemLoad`, `BatteryPower`, then raw voltage and amperage.
Missing keys select the next source. A present but invalid preferred value can return unavailable before later fallbacks are tried.

Adapter watts are the negotiated maximum. Battery watts describe charge/discharge. Input power and system consumption remain distinct.
System consumption can include display, radios, storage, conversion losses, and other board loads absent from the modeled subtotal.

When raw system consumption changes, the reader records a nonnegative system-minus-modeled baseline.
Between changes, the live modeled subtotal moves within that baseline so the displayed System total can follow faster component changes.
Without system telemetry, PWR falls back to modeled power. Without either source, the value is unavailable.
The chart keeps System as the outer total, with separate component bands inside it, including Display and Media.

## Modeled components

IOReport loads dynamically, trying `/usr/lib/libIOReport.dylib`, `libIOReport.dylib`, the old private framework path, then `IOReport`.
It is not linked in the package manifest. Missing required symbols or a failed subscription disable modeled power.
The image remains loaded because private subscription lifetime does not provide a public shutdown guarantee.

Subscriptions merge Energy Model, DCP, DCPEXT0, and DCPEXT1 groups, then retain channels recognized by `classifyChannel`.
Using only the DCP `display stats` subgroup has historically yielded zero power deltas. Subscribe to the group and filter while parsing.

Energy Model mapping is defined in the platform classifier:

| Channel name | Component |
| --- | --- |
| `GPU Energy` | GPU |
| Ends in `CPU Energy` | CPU |
| Starts with `ANE` | ANE |
| Starts with `DRAM`, `AMCC`, or `GPU SRAM` | Memory |
| Starts with `DCS` | Display fallback |
| Starts with `AVE`, `ISP`, or `MSR` | Media |
| Contains `PCIe` or starts with `apciec` | Other SoC |

Positive DCP `display stats/power` deltas take precedence over DCS display energy.
Detailed CPU/GPU rails overlap aggregate channels and are excluded to avoid double counting.
Unrecognized names or energy units are ignored, so Apple changes can remove individual components.

The classification cache uses `(driverID, channelID)` because channel IDs are shared across providers.
A cache miss falls back to string classification for subscribed delta channels. That fallback cannot restore channels excluded during subscription filtering.
Modeled samples use accumulated energy and real elapsed time, with a two-second sampling interval and the last computed sample between reads.
The first sample establishes a baseline. A gap beyond `max(5, updateInterval * 2)` seconds rejects the delta.

## Diagnostics

Set `MACTOP_DEBUG_POWER=1` when launching to log matched channels once after the first valid delta.
Set `MACTOP_DEBUG_BATTERY=1` to log battery telemetry once.
Recheck channel coverage after macOS or chip changes. These undocumented interfaces have no stability guarantee.
Platform IOReport phase timing currently runs even without a core phase recorder. See [open findings](../TODO.md).
