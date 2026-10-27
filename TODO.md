Prefix: MAC
Next: 13

### MAC-11 · P2 · Network totals add the absolute counter before a baseline exists

- **Area:** Data
- **Where:** `Sources/mactop/Core/Network/NetworkInterfaceReader.swift:22`, `Sources/mactop/Core/Network/NetworkInterfaceReader.swift:52`, `Sources/mactop/Core/Network/NetworkInterfaceReader.swift:78`, `Sources/mactop/UI/MetricPopups.swift:1324`, `Sources/mactop/Platform/NetworkInterfacePlatform.swift:55`
- **Problem:** `networkCounterRate` returns 0 when `previous` is 0, so the first sample is only a baseline. The session totals do not. `previousUp` and `previousDown` start at 0, and `clearNetworkUsageHistory` sets them back to 0 on pause. The next read adds `snapshot.uploadBytes - 0` into `totalUp` (and the same for download). The snapshot is the sum of `en*` `ifi_obytes` / `ifi_ibytes` since boot, not traffic since mactop started. The popup labels that value "Total upload" and "Total download", and pause is supposed to clear it. The same jump happens after a real counter reset to 0, because the following sample is again differenced against 0. `NetworkCounterRateTests` covers the rate baseline and does not cover this sum.
- **Recommendation:** When the stored previous counter is 0, store the current absolute counter and add nothing, matching `networkCounterRate`. Add a test that a first sample, a post-clear sample, and a sample after a reset to 0 leave the session total unchanged, and that the following sample adds only the new delta.
- **Fix with:** none
- **Effort:** S

### MAC-12 · P2 · Menu-bar network counters are the low 32 bits of the interface totals

- **Area:** Data
- **Where:** `Sources/mactop/Platform/NetworkInterfacePlatform.swift:54`, `Sources/mactop/Core/Network/NetworkInterfaceReader.swift:78`
- **Problem:** `getifaddrs` `AF_LINK` `ifa_data` is `struct if_data`. In the macOS 27 SDK, `ifi_ibytes` and `ifi_obytes` are `u_int32_t` (if_var.h). Current xnu `if_data_internal_to_if_data` stores those fields with a `(uint32_t)` truncation of the 64-bit counter (`COPYFIELD32_ATOMIC`). `NET_RT_IFLIST2` exposes the full `if_data64` counters. On this machine both views still match because `en0` is under 4 GiB (about 775 MiB in, 907 MiB out, probed 2026-10-27). After a counter passes 2^32, the value mactop reads wraps. `networkCounterRate` treats `current < previous` as a reset and shows a 0 rate for that tick, and the session total drops the bytes across the wrap. `ifi_baudrate` is the same 32-bit struct and is saturated to `0xFFFFFFFF` in that copy, so the displayed link rate is wrong above about 4.29 Gbit/s. A wrap was not reproduced here.
- **Recommendation:** Read byte counters and baudrate from `if_msghdr2.ifm_data` (`NET_RT_IFLIST2`), not from `getifaddrs` `struct if_data`. Keep the existing reset behavior for a true decrease of the 64-bit counter. Add a test with a counter that crosses 2^32 and one baudrate above 2^32.
- **Fix with:** os-boundaries
- **Effort:** S
