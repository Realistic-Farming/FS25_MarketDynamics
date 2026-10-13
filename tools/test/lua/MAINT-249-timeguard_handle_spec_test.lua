--!load: src/MarketEngine.lua, src/WorldEventSystem.lua, src/RWEIntegration.lua, src/BCIntegration.lua, src/MarketSerializer.lua, src/MarketDynamics.lua
-- MAINT-249-timeguard_handle_spec_test.lua - MAINTENANCE row 249 (Bob's fleet sweep row 8): the calendar
-- economy latches to FS25_TimeGuard in a game.
--
-- THE DEFECT THIS PINS (development 6be7e1d): MarketDynamics:_latchCalendarSource read TimeGuard through the
-- bare global g_timeGuard (src/MarketDynamics.lua:508). TimeGuard writes that global into its own mod
-- environment (getfenv(0), TimeGuard main.lua:38), so the read was nil in a game and the calendar economy
-- always latched to the native messages; delete re-read the same nil global to unsubscribe.
--
-- THE FIX (RSF-F203 :50, "bind to the actual mission handle ... retain the actual provider instance ... and
-- detach at delete"): the latch reads g_currentMission.timeGuard first, keeps the instance, and delete
-- unsubscribes from that instance.
--
-- THE ENTRY-POINT BAR IS GROUP E. The real coordinator (MD-15's bench shim, copied from
-- MD-15-session_latch_spec_test.lua) enters through onStartMission, the call main.lua's Mission00.onStartMission
-- append makes (main.lua:73-75, :242), on an experimental server mission. TimeGuard is modelled in its own mod
-- environment and is reachable only through the mission; its subscribe API is verbatim from
-- TimeGuard.lua:301-322. Its ticks are run by calling the callbacks it holds, as its _fireTick does.
--
--   E0  the world: MarketDynamics' environment has no g_timeGuard; TimeGuard's has it
--   E1  onStartMission latches the calendar source to TimeGuard, and TimeGuard holds both subscriptions
--   E2  TimeGuard's hour and day ticks each reconcile the calendar economy once
--   E3  delete detaches both subscriptions from the TimeGuard it latched


-- ── bench shim ──────────────────────────────────────────────
MDMLog = { info=function() end, warn=function() end, debug=function() end, error=function() end }
local LEGACY_NOW, MONO_NOW = 90000000, 90000000
MDMUtil = {
  getGameTime        = function() return LEGACY_NOW end,
  getMonotonicTime   = function() return MONO_NOW end,
  getMonotonicHour   = function(m) return math.floor((m or MONO_NOW) / 3600000) end,
  getMonotonicDay    = function(m) return math.floor((m or MONO_NOW) / 86400000) end,
  getMonthLengthScale = function() return 1 end,
  resolveEventName   = function(desc, _, id) return (desc and desc.name) or id or "?" end,
}
MessageType = { HOUR_CHANGED = 1, DAY_CHANGED = 2 }
g_timeGuard = nil
g_modManager = { getModByName = function() return nil end }
MDMEventConfig = { load = function() end, validateAndClean = function() end }
MDMStateLedgerBridge = { register = function() end, hasState = function() return false end, applyState = function() end }
MDMSettingsHubBridge = { register = function() end }
MDMNetworkSyncBridge = { stateActive = false, register = function() end }
UPIntegration = {
  reregisterActiveContracts = function() end, save = function() end, load = function() end,
  onWorldEventFired = function() end, onWorldEventExpired = function() end, init = function() end,
}
local syncRequests = 0
MDMContractSyncRequestEvent = { sendToServer = function() syncRequests = syncRequests + 1 end }
FuturesMarket = { new = function()
  return { contracts = {}, nextId = 1, checkExpiry = function() end, checkTimeScaleDrift = function() end }
end }

-- In-memory XMLFile mock keyed by path; enough for MarketSerializer save/load.
local xmlStore = {}
local function xmlHandle(t)
  local h = { _t = t }
  function h:setString(k, v) self._t[k] = v end
  function h:setInt(k, v)    self._t[k] = v end
  function h:setFloat(k, v)  self._t[k] = v end
  function h:setBool(k, v)   self._t[k] = v end
  function h:getString(k) local v = self._t[k]; if v ~= nil then return tostring(v) end end
  function h:getInt(k)    local v = self._t[k]; if type(v) == "number" then return v end end
  function h:getFloat(k)  local v = self._t[k]; if type(v) == "number" then return v end end
  function h:getBool(k)   local v = self._t[k]; if type(v) == "boolean" then return v end end
  function h:hasProperty(k)
    for key in pairs(self._t) do
      if key == k or key:sub(1, #k + 1) == k .. "#" or key:sub(1, #k + 1) == k .. "." then return true end
    end
    return false
  end
  function h:save() end
  function h:delete() end
  return h
end
XMLFile = {
  create = function(_, path) xmlStore[path] = {}; return xmlHandle(xmlStore[path]) end,
  load   = function(_, path) if xmlStore[path] then return xmlHandle(xmlStore[path]) end end,
}
function fileExists(path) return xmlStore[path] ~= nil end
function getUserProfileAppPath() return "profile/" end
local SAVE_PATH = "sg/FS25_MarketDynamics.xml"

local function resetMission()
  g_currentMission = {
    time = 5000,
    environment = { currentDay = 2, dayTime = 3600000, daysPerPeriod = 1, currentMonotonicDay = 2 },
    missionInfo = { savegameDirectory = "sg", savegameIndex = 1 },
  }
end

-- Fresh coordinator with counting stubs on the two economic drivers.
local function newCoordinator()
  resetMission()
  local mdm = MarketDynamics.new("dir/", "FS25_MarketDynamics")
  local e = mdm.marketEngine
  e.prices[2] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
  e._intradayCalls, e._dailyCalls, e._hourlyCalls = 0, 0, 0
  e._applyIntradayVolatility = function(self) self._intradayCalls = self._intradayCalls + 1 end
  e._applyDailyShift = function(self) self._dailyCalls = self._dailyCalls + 1 end
  e.applyHourlyMovement = function(self, n) self._hourlyCalls = self._hourlyCalls + 1 end
  mdm._reconcileCalls = 0
  local origReconcile = mdm._reconcile
  mdm._reconcile = function(self, ...) self._reconcileCalls = self._reconcileCalls + 1; return origReconcile(self, ...) end
  mdm.isActive = true
  return mdm
end

-- ── TimeGuard, in its own mod environment (mods.lua:482-520) ───────────────────
-- Its subscribe API is verbatim from TimeGuard src/TimeGuard.lua:301-322 at e34495e; its publish
-- is main.lua:38 (getfenv(0), at source time) and :48 (mission.timeGuard, in Mission00.load).
local tgEnv = setmetatable({}, { __index = _G })
tgEnv._G = tgEnv
tgEnv.getfenv = function() return tgEnv end
local TG_LOAD = [==[
local mission = ...
TGLogger = { warning = function() end }
local TimeGuard = {}
TimeGuard.__index = TimeGuard

function TimeGuard:subscribeTick(event, id, callback)
    if self.tickSubs[event] == nil then
        TGLogger.warning("subscribeTick: unknown event '%s'", tostring(event))
        return false
    end
    if type(id) ~= "string" or id == "" or type(callback) ~= "function" then
        TGLogger.warning("subscribeTick('%s'): needs a string id and a function", tostring(event))
        return false
    end
    if self.tickSubs[event][id] == nil then
        table.insert(self.tickSubOrder[event], id)
        table.sort(self.tickSubOrder[event])   -- deterministic fire order
    end
    self.tickSubs[event][id] = callback
    return true
end

function TimeGuard:unsubscribeTick(event, id)
    if self.tickSubs[event] ~= nil then
        self.tickSubs[event][id] = nil
    end
end

local timeGuard = setmetatable({
    tickSubs     = { hour = {}, day = {}, month = {}, year = {} },
    tickSubOrder = { hour = {}, day = {}, month = {}, year = {} },
}, TimeGuard)
getfenv(0)["g_timeGuard"] = timeGuard
mission.timeGuard = timeGuard
return timeGuard
]==]

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

g_server = {}
ReleaseGate = { EXPERIMENTAL = {}, isSystemLive = function() return true end, isReleased = function() return true end }

-- An experimental server mission (the calendar model selected), with TimeGuard on the mission only.
local mdm = newCoordinator()
mdm.settings.experimentalSystems = true
g_timeGuard = nil
local tg = assert(load(TG_LOAD, "=FS25_TimeGuard main.lua (model)", "t", tgEnv))(g_currentMission)

group("E0", function()
  T.eq("E0 MarketDynamics' environment has no g_timeGuard", g_timeGuard, nil)
  T.ok("E0 TimeGuard's own environment has it, and the mission carries it",
    tgEnv.g_timeGuard == tg and g_currentMission.timeGuard == tg)
end)

group("E1", function()
  mdm:onStartMission({})
  T.eq("E1 [reached] the experimental mission latches the calendar model", mdm.economicModel, "calendar")
  T.eq("E1 the calendar source latches to TimeGuard", mdm.calendarSource, "timeguard")
  T.eq("E1 TimeGuard holds MarketDynamics' hour subscription", type(tg.tickSubs.hour["MDM-calendar"]), "function")
  T.eq("E1 and its day subscription", type(tg.tickSubs.day["MDM-calendar"]), "function")
end)

group("E2", function()
  local before = mdm._reconcileCalls
  tg.tickSubs.hour["MDM-calendar"]({ tickEvent = "hour" })
  T.eq("E2 TimeGuard's hour tick reconciles the calendar economy once", mdm._reconcileCalls, before + 1)
  tg.tickSubs.day["MDM-calendar"]({ tickEvent = "day" })
  T.eq("E2 and its day tick once more", mdm._reconcileCalls, before + 2)
end)

-- delete's other teardown, not under test: the console commands (src/AdminCommands.lua:244), the dialogs
-- and the organic premium bridge (MarketDynamics.lua:624-629).
MDMAdminCommands_remove = MDMAdminCommands_remove or function() end
MDMDialogLoader = MDMDialogLoader or { cleanup = function() end }
OrganicPremiumBridge = OrganicPremiumBridge or { unregister = function() end }

group("E3", function()
  mdm:delete()
  T.eq("E3 delete detaches the hour subscription from the TimeGuard it latched", tg.tickSubs.hour["MDM-calendar"], nil)
  T.eq("E3 and the day subscription", tg.tickSubs.day["MDM-calendar"], nil)
end)
