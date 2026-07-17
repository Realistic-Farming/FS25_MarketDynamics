-- Logger.lua
-- [MDM]-prefixed logging helper. Wraps FS25's Logging.* functions so all
-- mod output is consistently prefixed and easy to grep in log.txt.
--
-- Usage:
--   MDMLog.info("message")    -> [MDM] message
--   MDMLog.warn("message")    -> [MDM] message          (Logging.warning)
--   MDMLog.error("message")   -> [MDM] message          (Logging.error)
--   MDMLog.debug("message")   -> [MDM] DEBUG: message   (only when debugEnabled)
--
-- MDMLog.debugEnabled is toggled by SettingsUI and mirrored in
-- coordinator.settings.debugMode so it survives save/load.
--
-- Author: tison (dev-1)

MDMLog = {}

local PREFIX = "[MDM] "

function MDMLog.info(msg)
    Logging.info(PREFIX .. tostring(msg))
end

function MDMLog.warn(msg)
    Logging.warning(PREFIX .. tostring(msg))
end

function MDMLog.error(msg)
    Logging.error(PREFIX .. tostring(msg))
end

-- Debug lines are only emitted when debugEnabled = true.
-- Toggle via ESC > Settings > Market Dynamics > Debug Logging,
-- or the 'mdmStatus' console command shows the current state.
function MDMLog.debug(msg)
    if MDMLog.debugEnabled then
        Logging.info(PREFIX .. "DEBUG: " .. tostring(msg))
    end
end

-- Off by default. Enabled by SettingsUI callback or loaded from save via MarketSerializer.
MDMLog.debugEnabled = false

-- ---------------------------------------------------------------------------
-- MDMUtil — shared utilities available to all MDM modules
-- ---------------------------------------------------------------------------
MDMUtil = {}

-- Returns absolute game-world time in milliseconds.
--
-- WHY NOT g_currentMission.time?
--   g_currentMission.time is session-elapsed time — it resets to 0 on every
--   load. Any value written to a savegame using .time as a base (contract
--   deadlines, event endsAt, cooldown lastFiredAt, history timestamps) will
--   be compared against a completely different .time value after reload,
--   causing incorrect expiry, wrong time-remaining display, and broken
--   cooldown logic.
--
-- The correct base is absolute game-world time:
--   (currentDay - 1) * 86400000 + dayTime
-- This is stable across saves and reloads.
function MDMUtil.getGameTime()
    local env = g_currentMission and g_currentMission.environment
    if not env then return 0 end
    local currentDay = env.currentDay or 1
    local dayTime    = env.dayTime    or 0
    return (currentDay - 1) * 86400000 + dayTime
end

-- Days/month (period length) scaling.
--
-- World event timing (roll interval, cooldowns, durations) is balanced around
-- a reference of 1 day per month. The player can stretch a month across several
-- days, which spreads one in-game month over more in-game time and would
-- otherwise pack proportionally more event rolls into a single month. Scaling
-- the timing values by the selected days/month keeps per-month event density
-- stable across day-length settings.
MDMUtil.BASE_DAYS_PER_MONTH = 1

-- Active days per month (Giants calls a month a "period"), clamped to 1-30.
-- Prefers the live environment value and falls back to the planned (menu)
-- value, then to the 1-day reference.
function MDMUtil.getDaysPerMonth()
    local mission = g_currentMission
    if mission == nil then
        return MDMUtil.BASE_DAYS_PER_MONTH
    end

    local env         = mission.environment
    local missionInfo = mission.missionInfo

    local days = (env and env.daysPerPeriod)
        or (missionInfo and missionInfo.plannedDaysPerPeriod)

    days = tonumber(days)
    if days == nil then
        return MDMUtil.BASE_DAYS_PER_MONTH
    end

    days = math.floor(days + 0.5)
    return math.max(1, math.min(30, days))
end

-- Multiplier applied to event timing so monthly density stays stable across
-- day-length settings. 1 day/month gives 1.0, 4 days/month gives 4.0.
function MDMUtil.getMonthLengthScale()
    return MDMUtil.getDaysPerMonth() / MDMUtil.BASE_DAYS_PER_MONTH
end
