-- FinancialPanicEvent.lua
-- A macro-economic shock (banking stress, credit freeze, commodity fund
-- liquidation) triggers a broad sell-off across ALL agricultural futures.
--
-- This is the only event in the mod that pushes every tracked commodity DOWN
-- simultaneously. It is intentionally rare and short-lived — hedge funds
-- unwind quickly once central banks respond.
--
-- Intensity 0-1 maps to:
--   factor = 0.80 - intensity * 0.15   (-20%..-35% across the board)
--
-- Affected crops: ALL (wheat, barley, canola, corn, dryCorn, sunflower,
--                      soybean, oat, potato, sugarbeet, silage)
--
-- Duration: 5-10 in-game minutes | Cooldown: 120 in-game minutes | p = 0.02
--
-- Very rare (p=0.02), high-intensity floor (0.5), long cooldown — designed
-- to feel like a true black-swan moment.
--
-- Author: tison (dev-1)

local EVENT_ID = "financial_panic"

local ALL_CROPS = {
    "WHEAT", "BARLEY", "CANOLA", "CORN", "DRYCORN",
    "SUNFLOWER", "SOYBEAN", "OAT", "POTATO", "SUGARBEET", "SILAGE",
}

local function onFire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    local factor = 0.80 - intensity * 0.15  -- 0.80x to 0.65x

    for _, cropName in ipairs(ALL_CROPS) do
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
    MDMLog.info(string.format(
        "FinancialPanicEvent fired — ALL crops suppressed x%.2f (intensity %.2f)",
        factor, intensity))
end

local function onExpire(intensity)
    if not g_MarketDynamics then return end
    if not g_fillTypeManager then MDMLog.warn("g_fillTypeManager nil") return end

    for _, cropName in ipairs(ALL_CROPS) do
        local fillType = g_fillTypeManager:getFillTypeByName(cropName)
        if fillType then
            g_MarketDynamics.marketEngine:removeModifierById(fillType.index, EVENT_ID .. "_" .. cropName)
        end
    end
    MDMEventConfig.removeExtra(EVENT_ID)

    MDMLog.info("FinancialPanicEvent expired — commodity markets stabilising")
end

local onLoad = onFire
local function getExtraData() return "" end

MDM_pendingRegistrations = MDM_pendingRegistrations or {}
table.insert(MDM_pendingRegistrations, {
    onLoad         = onLoad,
    getExtraData   = getExtraData,
    id             = EVENT_ID,
    nameKey        = "mdm_event_financial_panic",
    name           = "Financial Panic",
    probability    = 0.02,
    minIntensity   = 0.5,
    maxIntensity   = 1.0,
    cooldownMs     = 120 * 60 * 1000,   -- 2 in-game hours
    minDurationMs  =  5  * 60 * 1000,   -- 5-10 in-game minutes
    maxDurationMs  = 10  * 60 * 1000,
    onFire         = onFire,
    onExpire       = onExpire,
})
