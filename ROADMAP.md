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
- [ ] Companion read API on `g_currentMission.MarketDynamics`: getActiveEvents(), getEligibleEvents(), price/trend reads, so CropDisease and ProStaff stop reaching into internal tables (marketEngine/worldEvents/futuresMarket).
- [ ] StateLedger migration: replace `FS25_MarketDynamics.xml` (schema v2) as the save surface.
- [ ] NetworkSync migration: replace the 5 custom event classes.

## Mid-term (this season)
- [ ] MasterHUD: MDMHUD ticker + MDMMarketScreen (price chart / futures / admin tabs).
- [ ] SettingsHub: remove the ESC-menu settings injection.
- [ ] Finish the FarmTablet MarketDynamicsApp (app-side; the handle is already published).

## Long-term / aspirational
- [ ] Deeper market model (supply/demand curves, regional pricing) without breaking the read API.

## Cross-mod / ecosystem dependencies
- [ ] Reads RandomWorldEvents `getPriceModifier` and SeasonalCropStress (`cropStressManager`).
- [ ] Read by CropDisease (getActiveEvents) and ProStaff (trend + getEligibleEvents).
- [ ] All four bedrock migrations (blocks on: StateLedger, NetworkSync, MasterHUD, SettingsHub).

## Deferred / parked
- Event prediction / schedule API: parked by design. Events are probabilistic; peers poll active/eligible, they do not get a forecast.
