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
- [x] StateLedger: `MarketDynamics_State` bridge live (Phase 1, delegate-when-present; own XML kept as the safety copy). Commit b740771.
- [x] NetworkSync FULLY bridged. (1) Contract ACTION channel via NS Path 3 (`MarketDynamics_Contract`, anti-spoof + ownership preserved; commit 3bd0255). (2) STATE-sync module (id `FS25_MarketDynamics`, channel `MarketDynamics_Sync`; commit ad70e30): one FULL-snapshot carrying all contracts + market prices + active events, onWriteState/onReadState reuse the hardened MDMContractSyncEvent.execute + MDMMarketSyncEvent.applyState paths (no apply rewrite); sendToClients delegate to markStateDirty, join request skipped when NS active. Serialization round-trip verified. Owed: two-machine MP test.
- [x] MasterHUD: MDMHUD + settings panel bridged (Phase 1); own draw stands down when active.
- [x] SettingsHub: `MarketDynamics` module bridged (Phase 1, selfPersisted). ESC-menu injection retained as the standalone fallback (delegate-when-present).
- [ ] Reads: RandomWorldEvents `getPriceModifier`, SeasonalCropStress `cropStressManager`. Read by: CropDisease, ProStaff.

## Docs / localization
- [ ] Keep all 26 languages in step for any new setting.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] MasterHUD admin-tab guard decision (waits on: audit answer, internal `isMasterUser` check vs a panel `adminOnly` flag).
- [!] ProStaff early-warning threshold (waits on: Arissani, whether getEligibleEvents applies a minimum probability filter).
- [x] Bedrock migrations: ALL FOUR bridges DONE (StateLedger + MasterHUD + SettingsHub + NetworkSync action channel AND state-sync). Only the whole-wave two-machine MP test remains.
