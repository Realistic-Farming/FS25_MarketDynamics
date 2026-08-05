# TODO: FS25_MarketDynamics

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.

## From the ecosystem audit (Arissani)
- [x] Organic market premium (OM-213, MDM half, 2026-08-05): `OrganicPremiumBridge` registers the reserved "OrganicPremium" consumer modifier, reads SF's `getFarmOrganicFraction` for the selling farm (dedi-safe context from MDM's own sellFillType hook), applies `1 + (P - 1) * frac` with P = 1.20 (AWAITING-SPINE Economy dial). Removed the stale PROVISIONAL clamp-B comment. Ships LOCKED; unlock gated on the FarmTablet market-report line. Built on development, PR open.
- [ ] Expose a stable companion read API so peers stop reading internal tables (`marketEngine.prices`, `worldEvents.active`, `futuresMarket`).
- [ ] Handle capitalization is `g_currentMission.MarketDynamics` (capital M); ensure CropDisease and ProStaff briefs use it, and poll `getActiveEvents()` matching by id string.

## Bugs
- [x] Witcombe join load-gates: expire/restore/price-shift fired during MP join before saved state was settled. Added `_loadPhase` flag in MarketDynamics.lua — zeroes timers and skips all subsystems until onStartMission completes. Commit ad958a0, pushed 2026-07-28.
- [x] MP contract-admin exploit (f15715b): contract admin actions now require an actual admin, not just ownership. Closes a multiplayer path where a non-admin farm owner could trigger admin-only contract actions.
- [x] Daily price shift ran 60x too often (6c54f8c): the daily market price shift fired every 24 in-game minutes instead of once per in-game day. Now fires once per in-game day. This is the ledger's MDM `DAILY_INTERVAL` 60x gremlin (MarketEngine.lua), closed.
- [x] Money-authority (F15-class futures settlement): VERIFIED server-gated in live source. Both settlement paths bail on pure clients before `addMoney` (FuturesMarket.lua:217 `_fulfillContract`, :287 `_defaultContract`, via `if g_currentMission.isClient and not g_currentMission.isServer then return`), plus a double-pay guard (:210). The 2026-07-09 money-authority sweep flagged this as ungated, but it grepped `getIsServer` and missed the valid `.isServer`/`.isClient` field guard. Not a bug.
- [x] 2026-07-26 bug sweep: MDM auth gate, MDM persistence, MDM bcManaged bugs fixed and merged to main. All closed.

## Features / enhancements
- [x] Release gate mechanism (2026-08-04): `ReleaseGate.lua` with an EMPTY registry (Arissani 2026-08-03). `experimentalSystems` opt-in (default false, orthogonal to difficulty) through the coordinator settings, `MarketSerializer` save/load, the MP `MDMSettingsSyncEvent`, the SettingsHub mirror and a settings-panel row. `mdmRelease` status command. Nothing gated; a row drops in the moment a system needs locking.
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
