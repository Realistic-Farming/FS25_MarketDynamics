-- RWEIntegration.lua
-- Bridges FS25_RandomWorldEvents world events and FS25_SeasonalCropStress data into
-- MarketDynamics price modifiers.
--
-- RWE detection: g_currentMission.randomWorldEvents (set by RWE's Mission00.load hook).
-- CropStress detection: g_currentMission.cropStressManager (set by CS's Mission00.load hook).
-- Pattern mirrors BCIntegration/UPIntegration — detected once in onMissionLoaded, then polled.

MDMExternalIntegration = MDMExternalIntegration or {}
MDMExternalIntegration.__index = MDMExternalIntegration

-- RWE event id → price multiplier applied to all tracked fill types.
-- >1.0 = prices rise, <1.0 = prices fall. Values are intentionally modest
-- to layer cleanly on top of MDM's own WorldEventSystem events.
local EVENT_PRICE_EFFECTS = {
    market_boom        = 1.12,
    market_crash       = 0.87,
    export_opportunity = 1.18,
    economic_crisis    = 0.80,
    government_subsidy = 1.08,
    price_fixing       = 0.92,
    crop_yield_penalty = 1.10,  -- lower supply → prices rise
    crop_yield_bonus   = 0.95,  -- surplus supply → prices ease
}

local RWE_MODIFIER_PREFIX    = "rwe_"
local CS_MODIFIER_ID         = "cs_stress_pressure"
local CS_DAILY_INTERVAL_MS   = 24 * 60 * 60 * 1000  -- check once per in-game day
local CS_CRITICAL_THRESHOLD  = 0.70                  -- field stress above this is "critical"
local CS_MILD_FRACTION       = 0.25                  -- >25% critical fields → mild price pressure
local CS_STRONG_FRACTION     = 0.55                  -- >55% critical fields → strong pressure

function MDMExternalIntegration.new(engine)
    local self = setmetatable({}, MDMExternalIntegration)
    self.engine = engine
    -- RWE state
    self.rweManager = nil
    self.lastActiveEvent = nil
    -- CropStress state
    self.cropStressManager = nil
    self.csDailyTimer = 0
    self.lastCsModifierFactor = nil
    return self
end

-- Called once from MarketDynamics:onMissionLoaded() — detect both companion mods.
function MDMExternalIntegration:detect()
    local rwe = g_currentMission and g_currentMission.randomWorldEvents
    if rwe then
        self.rweManager = rwe
        MDMLog.info("MDMExternalIntegration: FS25_RandomWorldEvents detected — world events will influence prices")
    end

    local cs = g_currentMission and g_currentMission.cropStressManager
    if cs then
        self.cropStressManager = cs
        MDMLog.info("MDMExternalIntegration: FS25_SeasonalCropStress detected — widespread crop stress will apply supply pressure")
    end
end

-- Called every frame from MarketDynamics:update(dt).
function MDMExternalIntegration:update(dt)
    self:_updateRWE()
    self:_updateCropStress(dt)
end

-- ── RWE ──────────────────────────────────────────────────────────────────────

function MDMExternalIntegration:_updateRWE()
    if not self.rweManager then return end
    local state = self.rweManager.EVENT_STATE
    if not state then return end

    local currentEvent = state.activeEvent
    if currentEvent == self.lastActiveEvent then return end

    -- Clear modifiers from the previous event
    if self.lastActiveEvent and EVENT_PRICE_EFFECTS[self.lastActiveEvent] then
        local modId = RWE_MODIFIER_PREFIX .. self.lastActiveEvent
        for fillTypeIndex in pairs(self.engine.prices) do
            self.engine:removeModifierById(fillTypeIndex, modId)
        end
        MDMLog.info("MDMExternalIntegration: removed RWE price modifier for '" .. self.lastActiveEvent .. "'")
    end

    -- Apply modifiers for the new event (if it has a price effect)
    if currentEvent then
        local factor = EVENT_PRICE_EFFECTS[currentEvent]
        if factor then
            local modId = RWE_MODIFIER_PREFIX .. currentEvent
            for fillTypeIndex in pairs(self.engine.prices) do
                self.engine:addModifier({ id = modId, fillTypeIndex = fillTypeIndex, factor = factor })
            end
            MDMLog.info(string.format(
                "MDMExternalIntegration: RWE '%s' → price factor %.2f on %d fill types",
                currentEvent, factor, self:_countPrices()))
        end
    end

    self.lastActiveEvent = currentEvent
end

-- ── CropStress ───────────────────────────────────────────────────────────────

function MDMExternalIntegration:_updateCropStress(dt)
    if not self.cropStressManager then return end

    self.csDailyTimer = self.csDailyTimer + dt
    if self.csDailyTimer < CS_DAILY_INTERVAL_MS then return end
    self.csDailyTimer = 0

    -- Count fields and how many are under critical stress
    local modifier = self.cropStressManager.stressModifier
    if not modifier or not modifier.fieldStress then return end

    local total, critical = 0, 0
    for _, stress in pairs(modifier.fieldStress) do
        total = total + 1
        if stress >= CS_CRITICAL_THRESHOLD then critical = critical + 1 end
    end

    local newFactor = nil
    if total > 0 then
        local critFrac = critical / total
        if critFrac >= CS_STRONG_FRACTION then
            newFactor = 1.12  -- severe supply pressure
        elseif critFrac >= CS_MILD_FRACTION then
            newFactor = 1.06  -- mild supply pressure
        end
    end

    -- Remove old CS modifier if it changed
    if newFactor ~= self.lastCsModifierFactor then
        if self.lastCsModifierFactor then
            for fillTypeIndex in pairs(self.engine.prices) do
                self.engine:removeModifierById(fillTypeIndex, CS_MODIFIER_ID)
            end
        end

        if newFactor then
            for fillTypeIndex in pairs(self.engine.prices) do
                self.engine:addModifier({ id = CS_MODIFIER_ID, fillTypeIndex = fillTypeIndex, factor = newFactor })
            end
            MDMLog.info(string.format(
                "MDMExternalIntegration: CropStress supply pressure → factor %.2f (%d/%d fields critical)",
                newFactor, critical, total))
        else
            MDMLog.info("MDMExternalIntegration: CropStress supply pressure lifted")
        end

        self.lastCsModifierFactor = newFactor
    end
end

-- ── Shared ───────────────────────────────────────────────────────────────────

function MDMExternalIntegration:cleanup()
    -- Remove RWE modifier
    if self.lastActiveEvent and EVENT_PRICE_EFFECTS[self.lastActiveEvent] then
        local modId = RWE_MODIFIER_PREFIX .. self.lastActiveEvent
        for fillTypeIndex in pairs(self.engine.prices) do
            self.engine:removeModifierById(fillTypeIndex, modId)
        end
    end
    -- Remove CS modifier
    if self.lastCsModifierFactor then
        for fillTypeIndex in pairs(self.engine.prices) do
            self.engine:removeModifierById(fillTypeIndex, CS_MODIFIER_ID)
        end
    end
    self.rweManager = nil
    self.cropStressManager = nil
    self.lastActiveEvent = nil
    self.lastCsModifierFactor = nil
end

function MDMExternalIntegration:_countPrices()
    local n = 0
    for _ in pairs(self.engine.prices) do n = n + 1 end
    return n
end

-- Backward-compatible alias (was MDMRWEIntegration before crop stress was added)
MDMRWEIntegration = MDMExternalIntegration
