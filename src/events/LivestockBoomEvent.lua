-- LivestockBoomEvent.lua
-- A surge in demand for livestock feed as regional herds expand.
--
-- Intensity 0-1 maps to a +15%..+40% price boost:
--   factor = 1.15 + intensity * 0.25
--
-- Affected crops: GRASS, SILAGE, MAIZE (CORN)
-- Duration: 20-40 in-game minutes | Cooldown: 90 in-game minutes | p = 0.04
--
-- Author: tison (dev-1)

local EVENT_ID = "livestock_boom"

local AFFECTED_CROPS = { "GRASS_WINDROW", "SILAGE", "MAIZE", "DRYCORN" }

local function onFire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    local factor = 1.15 + intensity * 0.25  -- 1.15x to 1.40x

    for _, cropName in ipairs(AFFECTED_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = factor,
            })
        end
    end

    MDMEventConfig.applyExtra(EVENT_ID, factor)
    MDMLog.info("LivestockBoomEvent fired — forage crops up " .. math.floor((factor - 1) * 100) .. "pct")
end

local function onExpire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    for _, cropName in ipairs(AFFECTED_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:removeModifierById(fillType.index, EVENT_ID .. "_" .. cropName)
        end
    end
    MDMEventConfig.removeExtra(EVENT_ID)
end

-- Deferred registration
local onLoad = onFire
local function getExtraData() return "" end

MDM_pendingRegistrations = MDM_pendingRegistrations or {}
table.insert(MDM_pendingRegistrations, {
    onLoad         = onLoad,
    getExtraData   = getExtraData,
    id             = EVENT_ID,
    nameKey        = "mdm_event_livestock_boom",
    name           = "Livestock Feed Boom",
    probability    = 0.04,
    minIntensity   = 0.4,
    maxIntensity   = 1.0,
    cooldownMs     = 90 * 60 * 1000,   -- 1.5 hours
    minDurationMs  = 20 * 60 * 1000,   -- 20-40 minutes
    maxDurationMs  = 40 * 60 * 1000,
    onFire         = onFire,
    onExpire       = onExpire,
})
