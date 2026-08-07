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

-- Captured at load so event/notify paths keep MDM modEnv even if caller context shifts.
local MDM_MOD_NAME = g_currentModName

-- Mod-scoped i18n with Missing-reject (same spirit as MdRfPdaGuest.tr).
-- Giants g_i18n:getText returns a truthy "Missing '…'" banner on miss; never paint that.
function MDMUtil.getModText(key)
    if key == nil or key == "" then
        return nil
    end
    local modEnv = g_modEnvironments and g_modEnvironments[MDM_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or nil
    if i18n == nil then
        return nil
    end
    local ok, text = pcall(function() return i18n:getText(key) end)
    if not ok or type(text) ~= "string" or text == "" then
        return nil
    end
    local lower = text:lower()
    if lower == tostring(key):lower()
        or text == ("$l10n_" .. key)
        or lower:find("^missing%s")
        or lower:find("^missing_")
    then
        return nil
    end
    return text
end

-- Resolve event display name: modEnv i18n → desc.name → id. Never Giants Missing banners.
-- Accepts a registry desc table, or (nameKey, fallbackName, id).
function MDMUtil.resolveEventName(descOrNameKey, fallbackName, id)
    local nameKey, fallback, eventId
    if type(descOrNameKey) == "table" then
        nameKey = descOrNameKey.nameKey
        fallback = descOrNameKey.name
        eventId = descOrNameKey.id or id
    else
        nameKey = descOrNameKey
        fallback = fallbackName
        eventId = id
    end
    if nameKey ~= nil and nameKey ~= "" then
        local text = MDMUtil.getModText(nameKey)
        if text ~= nil then
            return text
        end
    end
    if fallback ~= nil and fallback ~= "" then
        return fallback
    end
    if eventId ~= nil and eventId ~= "" then
        return tostring(eventId)
    end
    if nameKey ~= nil and nameKey ~= "" then
        return tostring(nameKey)
    end
    return ""
end

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
