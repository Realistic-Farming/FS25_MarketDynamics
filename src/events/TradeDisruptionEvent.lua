-- TradeDisruptionEvent.lua
-- A trade disruption (export ban, port strike, logistics collapse).
-- A random 50% subset of crops is affected per firing — prices pushed up.
--
-- onFire records exactly which crops were affected so onExpire only removes
-- modifiers that were actually applied (avoids noisy removeModifierById calls
-- for modifiers that don't exist).
--
-- Author: tison (dev-1)

local EVENT_ID = "trade_disruption"

local ALL_CROPS = { "wheat", "barley", "canola", "corn", "dryCorn", "sunflower", "soybean", "oat" }

-- Tracks which cropNames were affected by the most recent firing.
-- Populated in onFire, consumed in onExpire.
-- Single-event design is safe because only one instance of this event can be
-- active at a time (WorldEventSystem guards against concurrent firing of the same id).
local _affectedCrops = {}

local function onFire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    local factor = 1.05 + intensity * 0.20  -- 1.05x to 1.25x

    _affectedCrops = {}  -- reset from any prior (expired) firing

    for _, cropName in ipairs(ALL_CROPS) do
        if math.random() < 0.5 then  -- 50% chance each crop is affected
            local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
            if fillType then
                g_MarketDynamics.marketEngine:addModifier({
                    id            = EVENT_ID .. "_" .. cropName,
                    fillTypeIndex = fillType.index,
                    factor        = factor,
                })
                -- Record so onExpire only removes what was actually applied.
                _affectedCrops[#_affectedCrops + 1] = cropName
            end
        end
    end

    -- User-configured extra fill types also get the 50% random chance
    for _, extraName in ipairs(MDMEventConfig.getExtraFillTypes(EVENT_ID)) do
        if math.random() < 0.5 then
            local fillType = g_fillTypeManager:getFillTypeByName(extraName:upper())
            if fillType then
                g_MarketDynamics.marketEngine:addModifier({
                    id            = EVENT_ID .. "_" .. extraName,
                    fillTypeIndex = fillType.index,
                    factor        = factor,
                })
                _affectedCrops[#_affectedCrops + 1] = extraName
            end
        end
    end

    MDMLog.info("TradeDisruptionEvent fired — factor " .. string.format("%.2f", factor) ..
        "  affected " .. #_affectedCrops .. "/" .. #ALL_CROPS .. " crops")
end

local function onExpire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    -- Only remove modifiers for crops that were actually applied at fire time.
    -- This includes any user-configured extra fill types that were selected.
    for _, cropName in ipairs(_affectedCrops) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
        if fillType then
            g_MarketDynamics.marketEngine:removeModifierById(fillType.index, EVENT_ID .. "_" .. cropName)
        end
    end

    _affectedCrops = {}
end

-- Restore from saved state.  Called by WorldEventSystem:loadActiveEvent() instead of
-- onFire so the affected-crop set is deterministically restored rather than re-rolled.
local function onLoad(intensity, extraData)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    _affectedCrops = {}
    local factor = 1.05 + intensity * 0.20

    for cropName in (extraData or ""):gmatch("[^,]+") do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = factor,
            })
            _affectedCrops[#_affectedCrops + 1] = cropName
        end
    end

    MDMLog.info("TradeDisruptionEvent restored — " .. #_affectedCrops .. " crops from save")
end

MDM_pendingRegistrations = MDM_pendingRegistrations or {}
table.insert(MDM_pendingRegistrations, {
    id             = EVENT_ID,
    nameKey        = "mdm_event_trade_disruption",
    name           = "Trade Disruption",
    probability    = 0.06,
    minIntensity   = 0.3,
    maxIntensity   = 1.0,
    cooldownMs     = 40 * 60 * 1000,
    minDurationMs  = 5  * 60 * 1000,   -- 5–12 in-game minutes
    maxDurationMs  = 12 * 60 * 1000,
    onFire         = onFire,
    onExpire       = onExpire,
    onLoad         = onLoad,
    getExtraData   = function() return table.concat(_affectedCrops, ",") end,
})
