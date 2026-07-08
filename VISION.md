# Vision: FS25_MarketDynamics

> Ecosystem role: **Markets and Economy** · Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit (Point 1-5, ecosystem-map, notes).
> Last updated: 2026-07-08

## 1. One-line purpose
A living crop market: prices move over time, world events swing them, and a futures market lets you hedge, so when and what you sell becomes a real decision.

## 2. Problem it solves
FS25 prices are largely static with only seasonal drift and no volatility or hedging. There is no market to read or play. MarketDynamics adds a dynamic price engine, market-moving world events, and a futures market so selling timing and risk management matter.

## 3. Design pillars
- **Server-authoritative market.** Market state lives on the server and syncs to clients; no client invents prices.
- **Right price hook.** Prices are applied at `SellingStation.getEffectiveFillTypePrice`, not EconomyManager, because SellingStation caches fill type infos at map load and never calls back into EconomyManager during gameplay.
- **Event-driven volatility.** Ten world events (biofuel_initiative, bumper_harvest, cold_snap, drought, financial_panic, geopolitical, livestock_boom, pest_outbreak, protein_premium, trade_disruption) swing the market probabilistically.
- **Stable companion API.** Peers read a defined function surface, never internal tables (marketEngine/worldEvents/futuresMarket).

## 4. Role in the ecosystem
- Public handle: `g_currentMission.MarketDynamics` (capital M, confirmed from source). The module global `g_MarketDynamics` is getfenv-scoped and not cross-mod accessible.
- Reads from (consumes): RandomWorldEvents `getPriceModifier` (via its economic subsystem), SeasonalCropStress (`g_currentMission.cropStressManager`). Third-party optional bridges: FS25_FuturesMission (BetterContracts) and FS25_UsedPlus, runtime-detected.
- Read by (consumers): CropDisease (polls `getActiveEvents()`, matches by id e.g. pest_outbreak/drought), ProStaff (price trend + `getEligibleEvents()` for early warning), FarmTablet MarketDynamicsApp (currently a stub; the handle is published, so finishing it is app-side work).
- Core-API registration status (specced in Point 1-5, not yet wired):
  - StateLedger (save/load): planned, replacing `FS25_MarketDynamics.xml` (schema v2).
  - NetworkSync (MP state): planned, replacing the 5 custom event classes.
  - MasterHUD (overlays): planned, MDMHUD price ticker + MDMMarketScreen (price chart / futures / admin tabs).
  - SettingsHub (admin settings): planned, replacing the ESC-menu settings injection.

## 5. Explicit non-goals
- No event prediction or schedule API. Events are probabilistic rolls every 5 in-game minutes; peers poll active/eligible events, they do not get a calendar.
- Does not hook EconomyManager (deliberate; SellingStation is the live path).
- Companions must not read internal tables; the read API is the contract.

## 6. Success criteria
- Prices move believably, events visibly swing the market, and the futures market is usable.
- Market state is identical on server and clients, on join and on change.
- Companion mods (CropDisease, ProStaff) read only the stable API, insulated from internal renames.

## 7. Open questions for the audit
- MasterHUD: the admin tab is gated internally by `g_currentMission.isMasterUser`. Is that sufficient, or should the MasterHUD panel carry an `adminOnly` flag?
- ProStaff early-warning framing (L20): should `getEligibleEvents()` also apply a minimum probability threshold filter?
