-- =========================================================
-- FS25_MarketDynamics - Organic Market Premium Bridge (OM-213)
-- =========================================================
-- Registers the "OrganicPremium" consumer price modifier with MarketDynamics,
-- mirroring the FertilizerDepot bridge's registration lifecycle. The premium
-- reads SoilFertilizer's organic provenance (getFarmOrganicFraction) and applies
-- `1.0 + (P - 1.0) * frac` to the price, proportional to a farm's organic share
-- of the harvested supply of the sold fill type.
--
-- The modifier is a pure multiplier over the market price. Because the price is
-- market-wide but the premium is per-farm, the SELLING FARM is supplied to the
-- modifier through a dedi-safe context set by MDM's own price path (PriceHook's
-- sellFillType wrapper) around the sale: g_MarketDynamics._organicSellingFarmId.
-- MarketDynamics remains the sole price owner; no base-game sale path is patched
-- by this build.
--
-- Contract facts (MarketEngine.lua):
--   ctx            = { fillTypeIndex, basePrice, marketPrice }
--   registry is name-keyed and CLOBBERING (priceModifiers[name] = fn) - the name
--   "OrganicPremium" is reserved here so no other suite mod takes it.
--   Failure is silent by contract: a throwing or non-positive return is skipped.
-- =========================================================

OrganicPremiumBridge = {}

OrganicPremiumBridge.MODIFIER_NAME = "OrganicPremium"

-- The certified premium multiplier for a fully organic supply. A DIAL, currently
-- a named constant (one line to change, flagged for Tyson); recorded AWAITING-SPINE
-- for the unbuilt Economy dial, where it scales on economy strength.
OrganicPremiumBridge.ORGANIC_PREMIUM = { CERTIFIED = 1.20 }

---Resolve SoilFertilizer's organic provenance handle, dedi-safe.
---Returns the organic module or nil when SF is absent.
function OrganicPremiumBridge.getOrganicHandle()
    if g_SoilFertilityManager
       and g_SoilFertilityManager.organic
       and type(g_SoilFertilityManager.organic.getFarmOrganicFraction) == "function" then
        return g_SoilFertilityManager.organic
    end
    return nil
end

---The modifier. Returns the premium multiplier for the fill type, or nil to opt
---out (SF absent, no organic share, or no selling farm context).
---@param ctx table { fillTypeIndex, basePrice, marketPrice }
---@return number|nil multiplier (>= 1.0) or nil
function OrganicPremiumBridge.modifierFn(ctx)
    if ctx == nil or ctx.fillTypeIndex == nil then return nil end
    local md = g_MarketDynamics
    local farmId = md and md._organicSellingFarmId or 0
    if farmId == nil or farmId <= 0 then return nil end

    local organic = OrganicPremiumBridge.getOrganicHandle()
    if organic == nil then return nil end

    local frac = organic:getFarmOrganicFraction(farmId, ctx.fillTypeIndex)
    if frac == nil or frac <= 0 then return nil end

    local p = OrganicPremiumBridge.ORGANIC_PREMIUM.CERTIFIED
    return 1.0 + (p - 1.0) * math.max(0, math.min(1, frac))
end

---Register with MarketDynamics. Called from onMissionLoaded (pcall-wrapped).
function OrganicPremiumBridge.register()
    local md = g_MarketDynamics or (g_currentMission and g_currentMission.MarketDynamics)
    if md == nil or type(md.registerPriceModifier) ~= "function" then
        MDMLog.info("OrganicPremiumBridge: MarketDynamics not ready; skipping registration")
        return
    end
    local ok, err = pcall(md.registerPriceModifier, md,
        OrganicPremiumBridge.MODIFIER_NAME, OrganicPremiumBridge.modifierFn)
    if ok then
        MDMLog.info("OrganicPremiumBridge: registered '" .. OrganicPremiumBridge.MODIFIER_NAME
            .. "' price modifier (certified premium " .. OrganicPremiumBridge.ORGANIC_PREMIUM.CERTIFIED .. ")")
    else
        MDMLog.warn("OrganicPremiumBridge: registration failed: " .. tostring(err))
    end
end

---Unregister from MarketDynamics. Called from delete / cleanup.
function OrganicPremiumBridge.unregister()
    local md = g_MarketDynamics or (g_currentMission and g_currentMission.MarketDynamics)
    if md == nil or type(md.unregisterPriceModifier) ~= "function" then return end
    pcall(md.unregisterPriceModifier, md, OrganicPremiumBridge.MODIFIER_NAME)
    MDMLog.info("OrganicPremiumBridge: unregistered '" .. OrganicPremiumBridge.MODIFIER_NAME .. "'")
end
