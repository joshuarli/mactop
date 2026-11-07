Prefix: MAC
Next: 17

### MAC-16 · P4 · The syncHistory parameter is plumbed but ignored by every popup update

- **Area:** Navigability
- **Where:** `Sources/mactop/UI/MactopApp.swift:348`, `Sources/mactop/UI/MactopApp.swift:358`, `Sources/mactop/UI/MetricPopups.swift:666`, `Sources/mactop/UI/MetricPopups.swift:858`, `Sources/mactop/UI/MetricPopups.swift:1095`, `Sources/mactop/UI/MetricPopups.swift:1418`
- **Problem:** `refreshPopup(at:syncHistory:)` forwards a flag that all four popup `update` methods discard as `syncHistory _:`; the only caller passes `true`. Since MAC-13 made the coordinator refresh on history enable, opening a panel no longer depends on this flag, so it reads as a live control while doing nothing.
- **Recommendation:** Remove the parameter from `refreshPopup` and the four popup updates.
- **Fix with:** none
- **Effort:** S

