-- RWEIntegration.lua
-- Bridges FS25_SeasonalCropStress data into MarketDynamics price modifiers.
--
-- CropStress detection: g_currentMission.cropStressManager (set by CS's Mission00.load hook).
-- Pattern mirrors BCIntegration/UPIntegration: detected once in onMissionLoaded, then polled.
--
-- EC-6 (brief v1.7 section 3.2): this file no longer reads FS25_RandomWorldEvents.
-- RandomWorldEvents prices its own events through the registered consumer modifier
-- (MarketDynamics:registerPriceModifier), and MarketDynamics advertises that with
-- rweConsumerContractVersion = 1. A second reader here would apply two price paths
-- to one event. The file name and the MDMRWEIntegration alias are kept for the
-- construction in MarketDynamics.lua.

MDMExternalIntegration = MDMExternalIntegration or {}
MDMExternalIntegration.__index = MDMExternalIntegration

local CS_MODIFIER_ID         = "cs_stress_pressure"
local CS_DAILY_INTERVAL_MS   = 24 * 60 * 60 * 1000  -- check once per in-game day
local CS_CRITICAL_THRESHOLD  = 0.70                  -- field stress above this is "critical"
local CS_MILD_FRACTION       = 0.25                  -- >25% critical fields → mild price pressure
local CS_STRONG_FRACTION     = 0.55                  -- >55% critical fields → strong pressure

function MDMExternalIntegration.new(engine)
    local self = setmetatable({}, MDMExternalIntegration)
    self.engine = engine
    -- CropStress state
    self.cropStressManager = nil
    self.csDailyTimer = 0                 -- incumbent path: raw-dt day accumulator
    self.lastCsCheckMonotonicDay = nil    -- calendar path: monotonic day cursor
    self.lastCsModifierFactor = nil
    return self
end

-- Called once from MarketDynamics:onMissionLoaded(): detect SeasonalCropStress.
function MDMExternalIntegration:detect()
    local cs = g_currentMission and g_currentMission.cropStressManager
    if cs then
        self.cropStressManager = cs
        MDMLog.info("MDMExternalIntegration: FS25_SeasonalCropStress detected — widespread crop stress will apply supply pressure")
    end
end

-- Called every frame from MarketDynamics:update(dt). economicModel is the
-- session's latched model ("incumbent" | "calendar"); nil (pure client, or a
-- missing latch) takes the incumbent clock, matching the LOCKED default.
function MDMExternalIntegration:update(dt, economicModel)
    if economicModel == "calendar" then
        self:_updateCropStressCalendar()
    else
        self:_updateCropStressIncumbent(dt)
    end
end

-- ── CropStress ───────────────────────────────────────────────────────────────

-- Incumbent path: check CropStress supply pressure once per accumulated
-- in-game day of raw dt (pre-MD-15 behaviour, kept while the calendar model
-- is LOCKED).
function MDMExternalIntegration:_updateCropStressIncumbent(dt)
    if not self.cropStressManager then return end

    self.csDailyTimer = self.csDailyTimer + (dt or 0)
    if self.csDailyTimer < CS_DAILY_INTERVAL_MS then return end
    self.csDailyTimer = 0

    self:_evaluateCropStress()
end

-- Calendar path: check CropStress supply pressure once per newly crossed
-- farming day (canonical monotonic day, RSF-F203). A time jump crosses days
-- without replaying intermediate checks; the current day's state is evaluated
-- once.
function MDMExternalIntegration:_updateCropStressCalendar()
    if not self.cropStressManager then return end

    local monoDay = MDMUtil.getMonotonicDay()
    if monoDay == self.lastCsCheckMonotonicDay then return end
    self.lastCsCheckMonotonicDay = monoDay

    self:_evaluateCropStress()
end

-- Shared evaluation: count critical fields and apply/lift the CS modifier.
function MDMExternalIntegration:_evaluateCropStress()
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
    -- Remove CS modifier
    if self.lastCsModifierFactor then
        for fillTypeIndex in pairs(self.engine.prices) do
            self.engine:removeModifierById(fillTypeIndex, CS_MODIFIER_ID)
        end
    end
    self.cropStressManager = nil
    self.lastCsModifierFactor = nil
end

-- Backward-compatible alias (was MDMRWEIntegration before crop stress was added)
MDMRWEIntegration = MDMExternalIntegration
