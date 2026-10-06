# Roadmap: FS25_MarketDynamics

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.

## How to use this file
- Populate the milestones below from the audit baseline once it lands.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v1.2.0.9 (development); bedrock bridges + FarmTablet app shipped, plus the MP contract-admin exploit fix and the daily-timer 60x gremlin fix.
- Audit reference: ecosystem-dev-tracking Point 1-5 (FS25_MarketDynamics, 2026-06-29)
- Baseline date: 2026-06-29 (updated 2026-07-25)

## Near-term (next release cycle)
- [x] Calendar-paced quotes (MD-15 / RSF-F203, 2026-09-08): economic work is admitted from the canonical monotonic clock `(currentMonotonicDay-1)*86400000 + dayTime` instead of raw-dt timer accumulation. `MarketEngine:update(dt)` retired to an inert no-op; `applyHourlyMovement(n)` (one quote step per crossed whole farming hour, MD-15 equation with skipped-interval endpoint approximation), `appendDailyHistory()` (one endpoint-day sample), `refreshBasePrices(false)` (one seasonal refresh per new farming day). World events roll on an accumulated opportunity phase (one roll per whole `300000 * daysPerPeriod` interval) and expire by absolute canonical deadline; BC supply spikes expire on the canonical hour; RWE/CS checks run once per monotonic day. Serializer v3 (canonical fields + `lastHistoryDay` + `lastMonotonicTime`, v2 migration); wire format `MDM-CALENDAR/1` carries server base/current as `%.17g` strings so clients keep the exact received quote. TimeGuard ticks when present, else native environment messages, else per-frame poll. Spec suite 188 assertions green. Ships LOCKED; PR into development.
- [x] Organic market premium (OM-213, MDM half, 2026-08-05): `OrganicPremiumBridge` registers the reserved "OrganicPremium" price modifier (name-keyed registry, clobber-safe). The modifier reads SoilFertilizer's `getFarmOrganicFraction` for the SELLING farm, fed through a dedi-safe context MDM's own sellFillType hook sets from the engine-passed farmId (never `g_currentMission:getFarmId()`), and applies `1 + (P - 1) * frac` with P = 1.20 (named constant, AWAITING-SPINE for the Economy dial). Removes the stale PROVISIONAL comment from clamp B. MarketDynamics stays the sole price owner; no base-game sale path is patched. Ships LOCKED; unlock gated on the FarmTablet market-report line (Wizard lane). Built on development, PR open.
- [x] Release gate mechanism (2026-08-04): wired per Arissani's 2026-08-03 lock set (EMPTY for MDM - the price-modifier contract is inert, OM-213 is unbuilt and owed). `ReleaseGate.lua` with an empty registry, `experimentalSystems` opt-in (default false, orthogonal to difficulty) through settings/persistence/MP sync/SettingsHub/panel, and the `mdmRelease` status command. Nothing gated today.
- [x] Witcombe join load-phase guard (ad958a0): load-phase flag prevents expire/restore/price-shift logic during MP join. Pushed 2026-07-28.
- [~] Companion read API on `g_currentMission.MarketDynamics`: getActiveEvents() is live; getEligibleEvents() is still pending (ProStaff L20 early-warning). Price/trend reads to follow.
- [x] StateLedger migration: `MarketDynamics_State` bridge live (b740771); own XML kept as the safety copy. Shipped v1.2.0.9.
- [x] NetworkSync migration: fully bridged, contract action channel (3bd0255) + state-sync module (ad70e30), replacing the custom event classes. Shipped v1.2.0.9.
- [x] 2026-07-26 bug sweep: MDM auth gate, MDM persistence, MDM bcManaged bugs fixed and merged to main.

## Mid-term (this season)
- [x] MasterHUD: MDMHUD + settings panel bridged; own draw stands down when active. Shipped v1.2.0.9.
- [x] SettingsHub: `MarketDynamics` module bridged (selfPersisted). ESC-menu injection intentionally retained as the standalone fallback (delegate-when-present). Shipped v1.2.0.9.
- [x] FarmTablet MarketDynamicsApp wired app-side (FarmTablet v2.5.2.15); the handle is published.

## Long-term / aspirational
- [ ] Deeper market model (supply/demand curves, regional pricing) without breaking the read API.

## Cross-mod / ecosystem dependencies
- [ ] Reads SeasonalCropStress (`cropStressManager`). RandomWorldEvents is no longer read: since EC-6 it prices its own events through `registerPriceModifier`, gated on `rweConsumerContractVersion` and refreshed through `refreshConsumerPrices()`.
- [ ] Read by CropDisease (getActiveEvents) and ProStaff (trend + getEligibleEvents).
- [x] All four bedrock migrations DONE (StateLedger + NetworkSync + MasterHUD + SettingsHub), shipped v1.2.0.9. Whole-wave two-machine MP test still owed.

## Deferred / parked
- Event prediction / schedule API: parked by design. Events are probabilistic; peers poll active/eligible, they do not get a forecast.

## 2026-08-07 (Fred): module page dots always visible
- [x] The Esc RF module selector hid its page dots when Worker Costs or Market Dynamics was the active module. Soil and Crop Stress always showed theirs, so WC never read as the 3rd module and the left panel was inconsistent. All four RfPdaMenuPage copies now keep the dots visible (dots = N, chrome unchanged, per the esc-rf-pda umbrella brief). Built, deployed, PR open.

## 2026-10-04 (Fred): the shared RF Esc door at the suite's STOCK page set (Wizard, #164)

- [x] The four shared Esc door files (`xml/gui/RfPdaMenuPage.xml`, `src/gui/RfPdaMenuPage.lua`, `src/gui/RfEscModules.lua`, `xml/gui/rfEscProfiles.xml`) are at the set every door mod carries, byte-same in all ten (Wizard's STOCK page chain build, #164, merged at f46af88b): wider sheet cells, the explanation band at up to four lines, the ids and callbacks StockGuard's STOCK page uses (inert without StockGuard), the hidden ids and profiles of DairyCore's herd-advisory panel, ProStaff in the closed-module list, and Soil Fertilizer's AUTO target card kept.
- The door's in-game check is TESTING row 415. Docs by Fred's catch-up, on Tyson's word of 2026-10-04.

## 2026-10-05 (Fred): the Esc side panel's info box clear of the selected tab (Wizard, #166)

- [x] The shared Esc door file `xml/gui/RfPdaMenuPage.xml`, byte-same in all ten door mods (Wizard, #166, merged at d57859ce): the side info boxes (`rfSideInfoShell`, `wcSideInfoShell`, `mdSideInfoShell`, `csSideInfoShell`) take an explicit position and size, 16 px further right and 16 px narrower (384 to 368 px), so the dark box starts clear of the selected tab's lime edge and its right edge stays where it was. The side text bodies narrow by the same 16 px, to 352 px (the main side text, from 368) and 348 px (the Worker Costs and Market Dynamics side help, from 364), so the text starts 16 px further right and each line ends where it did.
- The change's in-game check is TESTING row 450. Docs by Fred's catch-up, on Tyson's word of 2026-10-05.

## 2026-10-06 (Fred): the English description readable again (MAINTENANCE row 226)

- [x] `modDesc.xml:9`, the English description: one em dash had been saved through two wrong code pages (UTF-8 read as cp1252, then as the DOS cp850 page), so the mod manager showed "system ├óÔé¼ÔÇØ lock in prices". It now reads "system - lock in prices": the text the file held before the damage (148be3c, 2026-08-08), its em dash written as a spaced hyphen by the house rule. No other line changes.
