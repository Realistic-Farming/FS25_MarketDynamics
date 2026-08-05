-- =========================================================
-- FS25_MarketDynamics - Organic Market Premium Bridge (OM-213)
-- =========================================================
-- Registers the "OrganicPremium" consumer price modifier with MarketDynamics,
-- mirroring the FertilizerDepot bridge's registration lifecycle. The premium
-- reads SoilFertilizer's organic provenance (getFarmOrganicFraction) and applies
-- `1.0 + (P - 1.0) * frac` to the market price, proportional to a farm's organic
-- share of the harvested supply of the sold fill type.
--
-- STRICT MARKET-WIDE READING (Tyson ruling 2026-08-05): the modifier never
-- touches PriceHook or SellingStation, so it cannot resolve a per-sale selling
-- farm. The premium is therefore market-wide: it reflects the LOCAL/server farm's
-- organic share. On a dedicated server g_currentMission:getFarmId() is nil, so
-- the modifier opts out and the market price stays vanilla - the per-farm premium
-- is not representable in a global modifier without a sale-path context. The
-- per-farm mechanic (the original brief's intent) can only return with a
-- dedicated-server-safe farm context, which is a design decision for Arissani.
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
---out (SF absent, no organic share, or no farm to resolve on a dedicated server).
---@param ctx table { fillTypeIndex, basePrice, marketPrice }
---@return number|nil multiplier (>= 1.0) or nil
function OrganicPremiumBridge.modifierFn(ctx)
    if ctx == nil or ctx.fillTypeIndex == nil then return nil end

    -- Market-wide reading: the local/server farm is the only farm a global
    -- modifier can see. Nil on a dedicated server -> opt out (vanilla price).
    local farmId = 0
    if g_currentMission ~= nil and type(g_currentMission.getFarmId) == "function" then
        farmId = g_currentMission:getFarmId() or 0
    end
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
