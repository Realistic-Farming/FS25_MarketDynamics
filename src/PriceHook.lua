-- PriceHook.lua
-- Hooks SellingStation to route sell prices through MDM's modifier stack and
-- to track crop deliveries against active futures contracts.
--
-- Installed at source() time. Uses a sentinel (_G.MDM_PriceHook_installed) so
-- re-sourcing is idempotent.
--
-- Why SellingStation, not EconomyManager:
--   SellingStation caches its fillTypeInfos at map load and then calls its own
--   getPricePerLiter() at sell time — it never calls back into EconomyManager
--   during gameplay.  Hooking EconomyManager.getPricePerLiter therefore has no
--   effect on prices the player actually sees at a selling station.
--
-- Price hook (SellingStation.getEffectiveFillTypePrice):
--   Dormant until g_MarketDynamics.isActive = true.
--   If coordinator.settings.pricesEnabled = false, passes through to vanilla.
--
-- Delivery hook (SellingStation.sellFillType):
--   On every accepted crop delivery, notifies FuturesMarket so partial/full
--   contract fulfillment is tracked without a separate polling loop.
--   Server-only; no-op on pure clients.
--
-- Public helper:
--   MDMGetVanillaPrice(economyManager, fillTypeIndex) → number | nil
--     Returns the vanilla sell price at neutral supply/demand (pressure = 0).
--     Used by MarketEngine:init() for base price snapshotting.
--     Reads directly from EconomyManager (never patched) so it is always safe.
--
-- Author: tison (dev-1)

if _G.MDM_PriceHook_installed then
    MDMLog.info("PriceHook: already installed, skipping")
    return
end
_G.MDM_PriceHook_installed = true

-- Re-entrancy guard to prevent double-counting if sellFillType calls addFillLevelFromTool
local MDM_isInsideSellHook = false

-- ---------------------------------------------------------------------------
-- EconomyManager reference — used only for MDMGetVanillaPrice, never patched.
-- ---------------------------------------------------------------------------

-- We intentionally do NOT capture EconomyManager.getPricePerLiter at source time.
-- Economy mods (e.g. Realistic Economy) hook getPricePerLiter after MDM sources,
-- so a source-time capture would always return vanilla prices regardless of those mods.
-- By calling the live method at init() time we automatically pick up whatever base
-- prices any economy mod has installed.

if EconomyManager and EconomyManager.getPricePerLiter then
    MDMLog.info("PriceHook: EconomyManager.getPricePerLiter available for base price snapshots")
else
    MDMLog.warn("PriceHook: EconomyManager.getPricePerLiter not found — MDMGetVanillaPrice will return nil")
end

-- ---------------------------------------------------------------------------
-- SellingStation price hook
-- ---------------------------------------------------------------------------

if SellingStation and SellingStation.getEffectiveFillTypePrice then
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(
        SellingStation.getEffectiveFillTypePrice,
        function(self, superFunc, fillTypeIndex)
            local price = superFunc(self, fillTypeIndex)
            if type(price) ~= "number" or price <= 0 then return price end

            -- Dormant until MDM is fully initialized
            if not g_MarketDynamics or not g_MarketDynamics.isActive then
                return price
            end

            -- Respect the "Dynamic Prices" setting (ESC > Settings > Market Dynamics)
            if g_MarketDynamics.settings and not g_MarketDynamics.settings.pricesEnabled then
                return price
            end

            local mdmPrice = g_MarketDynamics.marketEngine:getPrice(fillTypeIndex)
            if mdmPrice and mdmPrice > 0 then
                return mdmPrice
            end

            -- Fallback: fillType not tracked by MDM (e.g. added by another mod)
            return price
        end
    )

    MDMLog.info("PriceHook: SellingStation.getEffectiveFillTypePrice hooked")
else
    MDMLog.warn("PriceHook: SellingStation.getEffectiveFillTypePrice not found — price hook disabled")
end

-- ---------------------------------------------------------------------------
-- SellingStation delivery hook (futures contract tracking)
-- ---------------------------------------------------------------------------

if SellingStation and SellingStation.sellFillType then
    SellingStation.sellFillType = Utils.overwrittenFunction(
        SellingStation.sellFillType,
        function(self, superFunc, farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)
            local wasInside = MDM_isInsideSellHook
            MDM_isInsideSellHook = true

            local result = superFunc(self, farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)

            -- Only track on server; only when MDM is active with a futures market.
            -- Use the re-entrancy guard to avoid double-counting if sellFillType calls addFillLevelFromTool.
            if not wasInside and g_server ~= nil
                and g_MarketDynamics and g_MarketDynamics.isActive
                and g_MarketDynamics.futuresMarket then

                MDMLog.debug(string.format("PriceHook: SellingStation.sellFillType(farmId=%s, delta=%.1f, ft=%s)",
                    tostring(farmId), tostring(fillDelta), tostring(fillTypeIndex)))

                -- In FS25, we use fillDelta (requested) because result (accepted) can be 
                -- unreliable in some selling station configurations.
                if fillDelta and fillDelta > 0 then
                    local pricePerLiter = self:getEffectiveFillTypePrice(fillTypeIndex)
                    g_MarketDynamics.futuresMarket:onCropDelivered(farmId, fillTypeIndex, fillDelta, pricePerLiter)
                end
            end

            MDM_isInsideSellHook = wasInside
            return result
        end
    )

    MDMLog.info("PriceHook: SellingStation.sellFillType hooked for futures tracking")
else
    MDMLog.warn("PriceHook: SellingStation.sellFillType not found — futures delivery tracking disabled")
end

-- Fallback hook for addFillLevelFromTool which some selling stations use directly (e.g. trains)
if SellingStation and SellingStation.addFillLevelFromTool then
    SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(
        SellingStation.addFillLevelFromTool,
        function(self, superFunc, farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)
            local wasInside = MDM_isInsideSellHook
            MDM_isInsideSellHook = true

            local result = superFunc(self, farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)
            
            -- Some selling stations (trains, certain placeables) call addFillLevelFromTool
            -- directly without going through sellFillType, so we must track here too.
            -- We use the re-entrancy guard to avoid double-counting.
            if not wasInside and g_server ~= nil
                and g_MarketDynamics and g_MarketDynamics.isActive
                and g_MarketDynamics.futuresMarket then

                if result and result > 0 then
                    MDMLog.debug(string.format("PriceHook: SellingStation.addFillLevelFromTool(farmId=%s, accepted=%.1f, ft=%s)",
                        tostring(farmId), tostring(result), tostring(fillTypeIndex)))
                    local pricePerLiter = self:getEffectiveFillTypePrice(fillTypeIndex)
                    g_MarketDynamics.futuresMarket:onCropDelivered(farmId, fillTypeIndex, result, pricePerLiter)
                end
            end
            
            MDM_isInsideSellHook = wasInside
            return result
        end
    )
    MDMLog.info("PriceHook: SellingStation.addFillLevelFromTool hooked as fallback")
end

-- ---------------------------------------------------------------------------
-- Public helper: vanilla price snapshot for MarketEngine:init()
-- ---------------------------------------------------------------------------

-- Returns the base sell price for a fillType at neutral supply/demand (pressure = 0).
-- Calls the live getPricePerLiter so economy mods (e.g. Realistic Economy) that hook
-- it after PriceHook sources are automatically used as MDM's price base.
function MDMGetVanillaPrice(economyManager, fillTypeIndex)
    if economyManager and type(economyManager.getPricePerLiter) == "function" then
        return economyManager:getPricePerLiter(fillTypeIndex, 0)
    end
    return nil
end
