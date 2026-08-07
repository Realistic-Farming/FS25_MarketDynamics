# Market Dynamics (MDM) - Custom Events API

This guide explains how third-party mods can register custom market events (e.g., weather anomalies, economic booms, crises) into the FS25 Market Dynamics engine.

## 1. Registration Pattern (Deferred Registration)

MDM uses a deferred registration pattern via the global `MDM_pendingRegistrations` table. This ensures your custom events are loaded securely regardless of mod load order.

Do not call the `MarketEngine` directly on script load. Instead, append your event definition to the pending table:

```lua
MDM_pendingRegistrations = MDM_pendingRegistrations or {}
table.insert(MDM_pendingRegistrations, {
    -- Event Definition Table (See Section 3)
})
2. The Event Lifecycle
​Every event must handle four core lifecycle phases. MDM passes an intensity float (0.0 to 1.0) to these functions, allowing you to scale the severity of your event.
​onFire(intensity): Triggered when the event starts. Use this to apply market modifiers.
​onExpire(intensity): Triggered when the event ends naturally or via console command. You must remove exactly the modifiers you applied.
​onLoad(intensity): Triggered when a savegame is loaded and this event was active.
​getExtraData(): Returns a string to be saved in the XML. Use this if your event has randomized state (e.g., affecting a random subset of crops) so the exact same state is restored on load.
​⚠️ Best Practices for onLoad & Save Completeness
​For purely deterministic events (where intensity dictates the exact same modifiers every time), you can safely alias onLoad = onFire and return an empty string for getExtraData().
​3. Event Definition Table
​Your event table must include the following fields:
Field Type Description
id string Unique identifier. Prefix with your mod name to avoid collisions.
nameKey string l10n key for the event name in the UI.
name string Fallback English name if the l10n key is missing.
probability float Chance to occur per tick (e.g., 0.03 for 3%).
minIntensity / maxIntensity float Bounds for the randomly generated intensity (0.0 to 1.0).
cooldownMs integer Minimum time (in in-game milliseconds) before this event can fire again.
minDurationMs / maxDurationMs integer Bounds for how long the event lasts (in in-game milliseconds).
onFire / onExpire function Lifecycle callbacks (see Section 2).
onLoad / getExtraData function Savegame persistence callbacks (see Section 2).
