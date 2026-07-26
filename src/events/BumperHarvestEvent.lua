-- BumperHarvestEvent.lua
-- A bumper harvest in a major region floods the market — grain prices drop.
--
-- Intensity 0-1 maps to a -8%..-25% price reduction on affected crops:
--   factor = 0.92 - intensity * 0.17   (0.92x at min, 0.75x at max)
--
-- Affected crops: wheat, barley, corn, oat, sorghum
-- Duration: 8-15 in-game minutes | Cooldown: 25 in-game minutes | p = 0.10
--
-- Author: tison (dev-1)

local EVENT_ID = "bumper_harvest"

local AFFECTED_CROPS = { "wheat", "barley", "corn", "dryCorn", "oat", "sorghum" }

local function onFire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    local factor = 0.92 - intensity * 0.17  -- 0.92x to 0.75x

    for _, cropName in ipairs(AFFECTED_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
        if fillType then
            g_MarketDynamics.marketEngine:addModifier({
                id            = EVENT_ID .. "_" .. cropName,
                fillTypeIndex = fillType.index,
                factor        = factor,
            })
        end
    end

    MDMEventConfig.applyExtra(EVENT_ID, factor)
    MDMLog.info("BumperHarvestEvent fired — factor " .. string.format("%.2f", factor))
end

local function onExpire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    for _, cropName in ipairs(AFFECTED_CROPS) do
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
    nameKey        = "mdm_event_bumper_harvest",
    name           = "Bumper Harvest",
    probability    = 0.10,
    minIntensity   = 0.2,
    maxIntensity   = 1.0,
    cooldownMs     = 25 * 60 * 1000,
    minDurationMs  = 8  * 60 * 1000,   -- 8-15 in-game minutes
    maxDurationMs  = 15 * 60 * 1000,
    onFire         = onFire,
    onExpire       = onExpire,
})
