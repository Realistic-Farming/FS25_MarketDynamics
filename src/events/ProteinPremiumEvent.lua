-- ProteinPremiumEvent.lua
-- A sustained consumer trend toward high-protein diets drives exceptional
-- demand for plant-protein feedstocks and premium milling wheat.
--
-- This differs from GeopoliticalEvent (which is a supply shock on staples)
-- and BiofuelInitiative (which targets energy crops). This is a pure
-- demand-pull event focused on protein content:
--
--   High-protein crops (primary boost):
--     SOYBEAN, CANOLA                — protein meal / crush margin
--     factor = 1.18 + intensity * 0.32   (+18%..+50%)
--
--   Milling grains (secondary / indirect demand):
--     WHEAT, BARLEY                  — premium milling grades in demand
--     factor = 1.08 + intensity * 0.17   (+8%..+25%)
--
-- Intensity 0-1 | Duration: 20-35 min | Cooldown: 75 min | p = 0.05
--
-- Author: tison (dev-1)

local EVENT_ID = "protein_premium"

local PROTEIN_CROPS = { "SOYBEAN", "CANOLA" }
local MILLING_CROPS = { "WHEAT", "BARLEY" }

local function onFire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    local proteinFactor = 1.18 + intensity * 0.32  -- 1.18x to 1.50x
    local millingFactor = 1.08 + intensity * 0.17  -- 1.08x to 1.25x

    for _, cropName in ipairs(PROTEIN_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_prot_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = proteinFactor,
            })
        end
    end

    for _, cropName in ipairs(MILLING_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_mill_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = millingFactor,
            })
        end
    end

    -- Extra config crops use the protein (primary) factor
    MDMEventConfig.applyExtra(EVENT_ID, proteinFactor)
    MDMLog.info(string.format(
        "ProteinPremiumEvent fired — protein x%.2f, milling x%.2f (intensity %.2f)",
        proteinFactor, millingFactor, intensity))
end

local function onExpire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    for _, cropName in ipairs(PROTEIN_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:removeModifierById(fillType.index, EVENT_ID .. "_prot_" .. cropName)
        end
    end

    for _, cropName in ipairs(MILLING_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:removeModifierById(fillType.index, EVENT_ID .. "_mill_" .. cropName)
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
    nameKey        = "mdm_event_protein_premium",
    name           = "Protein Premium Surge",
    probability    = 0.05,
    minIntensity   = 0.3,
    maxIntensity   = 1.0,
    cooldownMs     = 75 * 60 * 1000,    -- 75 in-game minutes
    minDurationMs  = 20 * 60 * 1000,   -- 20-35 in-game minutes
    maxDurationMs  = 35 * 60 * 1000,
    onFire         = onFire,
    onExpire       = onExpire,
})
