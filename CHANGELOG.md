# Changelog

All notable changes to FS25_MarketDynamics will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.3.0.0] - 2026-08-04

### Added
- **Release gate.** Market Dynamics now carries a lock registry that keeps experimental systems off until they are deliberately released. The gate is an explicit opt-in, independent of the difficulty setting. No systems are gated yet - this release wires the mechanism only.

---

## [1.2.0.1] - 2026-05-25

### Fixed
- Swapped out the ▲/▼ indicators since FS25 does not like it
- Fixed `nill` error from missing l10n string
- Updated all translation files (new keys have been added)

---

## [1.2.0.0] - 2026-05-24

### Added
- **Commodity list sorting** — Click the Crop, Price, or Change column header in the Prices tab to sort the list by that field. Click again to reverse the sort direction. An ▲/▼ indicator shows the active sort column and direction. Default remains alphabetical by name.

### Fixed
- **Realistic Economy Mod compatibility** — MDM now uses the live `EconomyManager.getPricePerLiter` at mission load time (not a source-time snapshot), so economy mods that adjust base prices after MDM loads are automatically picked up as MDM's price base. MDM's own volatility, world events, and futures contracts then apply on top.

---

## [1.1.9.3] - 2026-05-05

### Fixed
- Added a new HUD for when there is a active contract
- Added a dialog that shows up when a event has started
- Added new strings to all 25 translation files

---

## [1.1.9.2] - 2026-05-05

### Fixed
- Added missing deliveryStartTime and bcManaged fields to MarketSerializer and network sync (#64)
- Fixed BCIntegration deadline offset to use daysPerPeriod (#64)
- Added UPIntegration hooks and fixed modifier removal keys (#64)
- Added onLoad and getExtraData fallbacks to all stateless events for save load safety (#64)
- Fixed TradeDisruptionEvent duplicate extra filltype application (#64)
- Added session start grace period to MarketDynamics to prevent immediate contract defaults on server restart (#63, #60)
- Implemented MDMMarketSyncEvent to sync server prices and active events to clients, fixing desyncs (#62)
- Added deterministic oldest-first contract fulfillment logic
- Registered missing dialogs and added nil guards across core systems

---

## [1.1.9.1] - 2026-05-02

### Added
- **Browse Types (extended)** — You can now add individual fill types directly to events via the browser UI

### Changed
- Commodity handling expanded — events now support **all fill types**, not just crops
- Multiplayer / dedicated server event settings improved for better consistency and reliability

### Fixed
- Contract completion issue that could prevent contracts from finishing correctly

---

## [1.1.9.0] - 2026-05-02

### Added
- **Browse Fill Types Dialog** — New scrollable list in the Event Settings UI that shows all currently tracked fill types. Players can now browse valid crop names and click to automatically populate the "Add Fill Type" input field, eliminating manual typing errors.
- **Interactive Browsing** — Browse rows now feature hover highlighting and a selection callback system for seamless integration with the Event Fill Type editor.

### Fixed
- Resolved `attempt to index nil with 'new'` crash when attempting to open the Browse Types dialog due to missing source registration in `modDesc.xml`.
- Fixed a `GuiOverlay.renderOverlay` crash caused by assigning nil to element overlays; now using transparent color tables to safely bypass engine rendering.
- Fixed a "white box" visual glitch in the browse dialog by disabling default `ButtonElement` background overlays.
- Corrected profile property naming (`textFocusedColor`) to ensure automatic text highlighting works as expected in the Giants Engine.

---

## [1.1.5.1] - 2026-04-29

### Fixed
- Custom input dialog text field Y-position corrected (was clipping outside container on some resolutions)
- Admin commands reworked for reliability and cleaner output formatting
- Time unit toggle moved into the contract dialog for better UX flow

---

## [1.1.5.0] - 2026-04-29

### Added
- Custom contract quantity — new text-input dialog lets you enter any amount instead of being limited to presets
- Custom delivery window — type any number of in-game or real-world days for contract deadlines
- MDM Settings Panel — new in-game settings UI accessible from the server settings screen

### Fixed
- Save file moved from `savegameDirectory/modSettings/` to `savegameDirectory/` directly, preventing dedicated servers from rejecting uploaded savegames that contain subfolders (#47)
- Existing saves from v1.1.4.x are automatically migrated to the new path on first load
- Qty preset buttons in the contract dialog no longer overflow outside the dialog visual boundary (#46)
- Custom input dialog height increased so hint text is fully visible

---

## [1.1.4.1] - 2026-04-28

### Fixed
- Contract list no longer duplicates or desyncs on dedicated servers
- Contracts now correctly sync to all clients after server load (#43)

---

## [1.1.4.0] - 2026-04-26

### Fixed
- MDM settings tab no longer overwrites the MP Server Settings tab in the ESC menu

---

## [1.1.3.0] - 2026-04-26

### Fixed
- Multiplayer contract sync reliability improvements
- KingMods escape key conflict resolved (#33)
- Comprehensive README added with feature overview and keyboard shortcuts (#32)
- German translation updated

---

## [1.1.2.0] - 2026-04-22

### Added
- Three new world events: **ColdSnap**, **FinancialPanic**, and **ProteinPremium**

---

## [1.1.1.0] - 2026-04-09

### Changed
- BetterContracts integration renamed to **FuturesMission** throughout — no functional change, aligns with the correct mod name

### Fixed
- Multiplayer futures contract network sync (#31)
- Network sync and delivery time calculation edge cases
- Duplicate BC contracts no longer created in `onBCContractCreated`
- Game time now uses `MDMUtil.getGameTime` (absolute) instead of `g_currentMission.time`

---

## [1.1.0.0] - 2026-03-29

### Added
- **BetterContracts integration** — full BC↔MDM handshake; futures contracts exposed to the BC UI
- `BCIntegration.getContractsForFarm` for savegame migration support
- 4 new API functions exposed for BetterContracts cross-mod use
- InfoDialog shown when New Contract is pressed with BetterContracts active

### Fixed
- Price display $0 bug on first load
- Contract click not registering in some UI states
- Volatility calculation edge cases
- Delivery lockout not correctly enforced
- Game freeze prevented when pressing New Contract with BetterContracts active

---

## [1.0.9.2] - 2026-04-22 *(pre-release tag)*

### Added
- ColdSnap, FinancialPanic, ProteinPremium world events

---

## [1.0.0.0] - 2026-03-24

### Added
- **Futures contract system** — lock in a price for a future harvest; penalty applies for missed delivery
- **Contract admin dialog** — server admins can view, manage, and delete contracts in-game
- **World Events system** — randomized global events (trade disruption, drought, bumper harvest, etc.) that shift crop prices
- **Market Settings** — dedicated ESC > Settings tab for event frequency, futures penalty, volatility scale, and price toggle
- **UsedPlus integration** — futures contract payouts credit the UsedPlus market API when detected
- **25-language localization** — full translations shipped at launch
- Contract creation dialog with quantity presets and delivery window selection
- Price history graph per crop on the Market Screen
- HUD settlement notifications when a contract pays out or expires
- Cross-mod API via `g_currentMission.MarketDynamics`

### Fixed
- 7-bug audit pass covering tab UX, N key inputEvent, setTextColor crash
- Native `fs25_dialogButtonBox` used for all dialogs (correct FS25 button bar pattern)
- Dedicated server support — simulation runs headless with no GUI dependencies
- Settings tab no longer conflicts with the vanilla settings screen

---

## [0.1.0] - 2026-03-19 *(pre-release)*

### Added
- Initial public pre-release
- MarketEngine with daily + intraday price volatility
- WorldEventSystem with 4 starter events
- FuturesMarket with contract creation and delivery tracking
- MarketSerializer (save/load per savegame)
- Market Screen UI with price graph and contract list tab
- SellingStation hook for automatic futures delivery tracking
- Build script for packaging and deployment
