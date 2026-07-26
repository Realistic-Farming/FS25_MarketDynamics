-- GeopoliticalEvent.lua
-- Geopolitical instability (conflict, sanctions, policy shock).
-- Spikes staple crops (food security demand) and energy-adjacent crops
-- (canola/sunflower as biofuel feedstocks).
--
-- Intensity 0-1 maps to:
--   Staples (wheat, barley):       +15%..+45%  factor = 1.15 + intensity * 0.30
--   Energy crops (canola, sunflower): +20%..+55%  factor = 1.20 + intensity * 0.35
--
-- Duration: 15-25 in-game minutes | Cooldown: 60 in-game minutes | p = 0.04
--
-- Author: tison (dev-1)

local EVENT_ID = "geopolitical"

local STAPLE_CROPS = { "wheat", "barley" }
local ENERGY_CROPS = { "canola", "sunflower" }

local function onFire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    local stapleFactor = 1.15 + intensity * 0.30  -- 1.15x to 1.45x
    local energyFactor = 1.20 + intensity * 0.35  -- 1.20x to 1.55x

    for _, cropName in ipairs(STAPLE_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = stapleFactor,
            })
        end
    end

    for _, cropName in ipairs(ENERGY_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = energyFactor,
            })
        end
    end

    -- Extra config crops use the staple factor (primary group)
    MDMEventConfig.applyExtra(EVENT_ID, stapleFactor)
    MDMLog.info("GeopoliticalEvent fired — staple " .. string.format("%.2f", stapleFactor) ..
        "  energy " .. string.format("%.2f", energyFactor))
end

local function onExpire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    -- Combine both crop lists for a single removal pass
    local allCrops = {}
    for _, c in ipairs(STAPLE_CROPS) do table.insert(allCrops, c) end
    for _, c in ipairs(ENERGY_CROPS)  do table.insert(allCrops, c) end

    for _, cropName in ipairs(allCrops) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
        if fillType then
            g_MarketDynamics.marketEngine:removeModifierById(fillType.index, EVENT_ID .. "_" .. cropName)
        end
    end
    MDMEventConfig.removeExtra(EVENT_ID)
end

local onLoad = onFire
local function getExtraData() return "" end

MDM_pendingRegistrations = MDM_pendingRegistrations or {}
table.insert(MDM_pendingRegistrations, {
    onLoad         = onLoad,
    getExtraData   = getExtraData,
    id             = EVENT_ID,
    nameKey        = "mdm_event_geopolitical",
    name           = "Geopolitical Crisis",
    probability    = 0.04,
    minIntensity   = 0.4,
    maxIntensity   = 1.0,
    cooldownMs     = 60 * 60 * 1000,
    minDurationMs  = 15 * 60 * 1000,   -- 15-25 in-game minutes
    maxDurationMs  = 25 * 60 * 1000,
    onFire         = onFire,
    onExpire       = onExpire,
})
