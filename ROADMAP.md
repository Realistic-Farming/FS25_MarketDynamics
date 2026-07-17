# Roadmap: FS25_MarketDynamics

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v1.2.0.8
- Audit reference: ecosystem-dev-tracking Point 1-5 (FS25_MarketDynamics, 2026-06-29)
- Baseline date: 2026-06-29

## Near-term (next release cycle)
- [~] Companion read API on `g_currentMission.MarketDynamics`: getActiveEvents() is live; getEligibleEvents() is still pending (ProStaff L20 early-warning). Price/trend reads to follow.
- [x] StateLedger migration: `MarketDynamics_State` bridge live (b740771); own XML kept as the safety copy. Shipped v1.2.0.9.
- [x] NetworkSync migration: fully bridged, contract action channel (3bd0255) + state-sync module (ad70e30), replacing the custom event classes. Shipped v1.2.0.9.

## Mid-term (this season)
- [x] MasterHUD: MDMHUD + settings panel bridged; own draw stands down when active. Shipped v1.2.0.9.
- [x] SettingsHub: `MarketDynamics` module bridged (selfPersisted). ESC-menu injection intentionally retained as the standalone fallback (delegate-when-present). Shipped v1.2.0.9.
- [x] FarmTablet MarketDynamicsApp wired app-side (FarmTablet v2.5.2.15); the handle is published.

## Long-term / aspirational
- [ ] Deeper market model (supply/demand curves, regional pricing) without breaking the read API.

## Cross-mod / ecosystem dependencies
- [ ] Reads RandomWorldEvents `getPriceModifier` and SeasonalCropStress (`cropStressManager`).
- [ ] Read by CropDisease (getActiveEvents) and ProStaff (trend + getEligibleEvents).
- [x] All four bedrock migrations DONE (StateLedger + NetworkSync + MasterHUD + SettingsHub), shipped v1.2.0.9. Whole-wave two-machine MP test still owed.

## Deferred / parked
- Event prediction / schedule API: parked by design. Events are probabilistic; peers poll active/eligible, they do not get a forecast.
