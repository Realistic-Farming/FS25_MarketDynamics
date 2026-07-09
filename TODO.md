# TODO: FS25_MarketDynamics

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [ ] Expose a stable companion read API so peers stop reading internal tables (`marketEngine.prices`, `worldEvents.active`, `futuresMarket`).
- [ ] Handle capitalization is `g_currentMission.MarketDynamics` (capital M); ensure CropDisease and ProStaff briefs use it, and poll `getActiveEvents()` matching by id string.

## Bugs
- [x] Money-authority (F15-class futures settlement): VERIFIED server-gated in live source. Both settlement paths bail on pure clients before `addMoney` (FuturesMarket.lua:217 `_fulfillContract`, :287 `_defaultContract`, via `if g_currentMission.isClient and not g_currentMission.isServer then return`), plus a double-pay guard (:210). The 2026-07-09 money-authority sweep flagged this as ungated, but it grepped `getIsServer` and missed the valid `.isServer`/`.isClient` field guard. Not a bug.

## Features / enhancements
- [ ] `getEligibleEvents()` to unblock ProStaff L20 early-warning (off-cooldown, not-active events).

## Cross-mod integration
- [ ] StateLedger: migrate off `FS25_MarketDynamics.xml` (schema v2).
- [ ] NetworkSync: replace the 5 custom event classes.
- [ ] MasterHUD: MDMHUD ticker + MDMMarketScreen; the admin tab stays gated by `isMasterUser`.
- [ ] SettingsHub: remove the ESC-menu injection.
- [ ] Reads: RandomWorldEvents `getPriceModifier`, SeasonalCropStress `cropStressManager`. Read by: CropDisease, ProStaff.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] MasterHUD admin-tab guard decision (waits on: audit answer, internal `isMasterUser` check vs a panel `adminOnly` flag).
- [!] ProStaff early-warning threshold (waits on: Arissani, whether getEligibleEvents applies a minimum probability filter).
- [!] Bedrock migrations (waits on: adopting the four engines).
