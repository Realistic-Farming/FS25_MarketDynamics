--!load: src/MarketEngine.lua, src/WorldEventSystem.lua, src/RWEIntegration.lua, src/BCIntegration.lua, src/MarketSerializer.lua, src/MarketDynamics.lua
-- MAINTENANCE row 303: the incumbent (default) economic model's daily work follows
-- the game's day change, not a raw-dt timer.
--
-- The mission's dt is REAL milliseconds: BaseMission:update passes it on unscaled
-- and only Environment:update multiplies it by the time scale
-- (environment/Environment.lua:279). MarketEngine added that dt to a dailyTimer of
-- 86,400,000 ms that started at 0 every session and was never saved, and
-- RWEIntegration did the same for its crop-stress check, so the daily shift, the
-- seasonal base refresh, the 7-day history sample and the crop-stress check waited
-- for 24 real hours of unbroken play. Now MarketDynamics subscribes the engine's
-- DAY_CHANGED message (Environment.lua:408) for an incumbent session and runs that
-- work once per in-game day. The intraday tick stays on real time by Tyson's ruling
-- of 2026-10-13.
--
-- Entry point: the real MarketDynamics.new and onStartMission, with a message center
-- that follows the engine's subscribe / unsubscribe / publish
-- (MessageCenter.lua:27-110). The daily shift, the history append, the base refresh
-- and the crop-stress check are the real bodies.
--   A  the incumbent session subscribes once; calendar sessions and pure clients do not
--   B  raw dt never fires the daily work; the intraday tick stays one per real minute
--   C  a published DAY_CHANGED runs the real daily work once per day
--   D  guards: load phase, inactive, pure client, calendar session
--   E  delete removes the subscription with the engine's argument order
-- No game, network or rendering behaviour is proved here.

-- ── bench shim (as MD-15-session_latch_spec_test.lua) ──────────
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
MDMContractSyncRequestEvent = { sendToServer = function() end }
FuturesMarket = { new = function()
  return { contracts = {}, nextId = 1, checkExpiry = function() end, checkTimeScaleDrift = function() end }
end }
MDMAdminCommands_remove = function() end
MDMDialogLoader = { cleanup = function() end }
OrganicPremiumBridge = { unregister = function() end }

local sends = {}
MDMMarketSyncEvent = { sendToClients = function(includeHistory) sends[#sends + 1] = includeHistory end }

-- The engine's base price, read by the real refreshBasePrices.
local BASE_FROM_ECONOMY = 150
MDMGetVanillaPrice = function(_, fillTypeIndex) return fillTypeIndex == 2 and BASE_FROM_ECONOMY or nil end
g_fillTypeManager = { getFillTypes = function() return { { index = 2 } } end }

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

-- The engine's message center (MessageCenter.lua:27-110): subscribe stores the
-- callback with its target, unsubscribe(messageType, callbackTarget, callback)
-- matches on the target, publish calls callback(callbackTarget, ...).
local function newMessageCenter()
  local mc = { subscribers = {} }
  function mc:subscribe(messageType, callback, callbackTarget, argument)
    local list = self.subscribers[messageType] or {}
    self.subscribers[messageType] = list
    list[#list + 1] = { callback = callback, callbackTarget = callbackTarget, argument = argument }
  end
  function mc:unsubscribe(messageType, callbackTarget, callback)
    local list = self.subscribers[messageType]
    if list == nil then return end
    for i = #list, 1, -1 do
      local info = list[i]
      if info.callbackTarget == callbackTarget and (callback == nil or info.callback == callback) then
        table.remove(list, i)
      end
    end
    if #list == 0 then self.subscribers[messageType] = nil end
  end
  function mc:publish(messageType, ...)
    local list = self.subscribers[messageType]
    if list == nil then return end
    local copy = {}
    for i, info in ipairs(list) do copy[i] = info end
    for _, info in ipairs(copy) do
      if info.callbackTarget == nil then info.callback(...)
      else info.callback(info.callbackTarget, ...) end
    end
  end
  function mc:count(messageType, target)
    local n = 0
    for _, info in ipairs(self.subscribers[messageType] or {}) do
      if target == nil or info.callbackTarget == target then n = n + 1 end
    end
    return n
  end
  return mc
end

local function stressed()
  return { stressModifier = { fieldStress = { 0.9, 0.9, 0.1 } } }  -- 2 of 3 critical: strong pressure
end

local function newSession(opts)
  opts = opts or {}
  if opts.client then g_server = nil else g_server = {} end
  g_messageCenter = newMessageCenter()
  g_currentMission = {
    time = 5000,
    environment = { currentDay = 2, dayTime = 3600000, daysPerPeriod = 1, currentMonotonicDay = 2 },
    missionInfo = { savegameDirectory = "sg", savegameIndex = 1 },
    economyManager = {},
  }
  xmlStore = {}
  local mdm = MarketDynamics.new("dir/", "FS25_MarketDynamics")
  if opts.calendar then mdm.settings.experimentalSystems = true end
  local e = mdm.marketEngine
  e.prices[2] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
  e._dailyCalls, e._intradayCalls = 0, 0
  local realDaily, realIntraday = MarketEngine._applyDailyShift, MarketEngine._applyIntradayVolatility
  e._applyDailyShift = function(self) self._dailyCalls = self._dailyCalls + 1; return realDaily(self) end
  e._applyIntradayVolatility = function(self) self._intradayCalls = self._intradayCalls + 1; return realIntraday(self) end
  mdm.rweIntegration.cropStressManager = stressed()
  mdm.isActive = true
  mdm:onStartMission({})
  sends = {}
  return mdm, e
end

local function try(obj, name, ...)
  local fn = obj and obj[name]
  if type(fn) ~= "function" then return false, "no " .. name end
  return pcall(fn, obj, ...)
end

-- =====================================================================
-- A: who subscribes
-- =====================================================================
do
  local mdm = newSession()
  T.eq("A1 an incumbent session latched the incumbent model", mdm.economicModel, "incumbent")
  T.eq("A2 it subscribed one DAY_CHANGED handler with itself as the target",
    g_messageCenter:count(MessageType.DAY_CHANGED, mdm), 1)
  local info = (g_messageCenter.subscribers[MessageType.DAY_CHANGED] or {})[1]
  T.ok("A3 the handler is _onIncumbentDayChanged",
    info ~= nil and MarketDynamics._onIncumbentDayChanged ~= nil and info.callback == MarketDynamics._onIncumbentDayChanged)
  mdm:onStartMission({})
  T.eq("A4 a second onStartMission does not subscribe again", g_messageCenter:count(MessageType.DAY_CHANGED, mdm), 1)

  local cal = newSession({ calendar = true })
  local incumbentHandlers = 0
  for _, i in ipairs(g_messageCenter.subscribers[MessageType.DAY_CHANGED] or {}) do
    if MarketDynamics._onIncumbentDayChanged ~= nil and i.callback == MarketDynamics._onIncumbentDayChanged then
      incumbentHandlers = incumbentHandlers + 1
    end
  end
  T.eq("A5 a calendar session latched the calendar model", cal.economicModel, "calendar")
  T.eq("A6 and subscribed no incumbent day handler", incumbentHandlers, 0)

  local cli = newSession({ client = true })
  T.eq("A7 a pure client subscribes nothing to DAY_CHANGED", g_messageCenter:count(MessageType.DAY_CHANGED), 0)
  g_server = {}
end

-- =====================================================================
-- B: raw dt never fires the daily work
-- =====================================================================
do
  local mdm, e = newSession()
  for _ = 1, 3 do mdm:update(60000) end
  T.eq("B1 the intraday tick stays one per real minute", e._intradayCalls, 3)
  mdm:update(86400000)
  T.eq("B2 a full real day of dt fires no daily shift", e._dailyCalls, 0)
  T.eq("B3 and appends no history sample", #e.prices[2].history, 0)
  T.eq("B4 and refreshes no base price", e.prices[2].base, 100)
  T.eq("B5 and applies no crop-stress pressure", mdm.rweIntegration.lastCsModifierFactor, nil)
  T.eq("B6 no raw-dt daily timer exists on the engine", e.dailyTimer, nil)
  T.eq("B7 no raw-dt day accumulator exists on the bridge", mdm.rweIntegration.csDailyTimer, nil)
end

-- =====================================================================
-- C: the game's day change runs the real daily work, once per day
-- =====================================================================
do
  local mdm, e = newSession()
  g_messageCenter:publish(MessageType.DAY_CHANGED, 3)
  T.eq("C1 one day change runs the daily shift once", e._dailyCalls, 1)
  T.eq("C2 and appends one history sample", #e.prices[2].history, 1)
  T.eq("C3 and refreshes the base from the economy", e.prices[2].base, BASE_FROM_ECONOMY)
  T.eq("C4 and applies the crop-stress pressure", mdm.rweIntegration.lastCsModifierFactor, 1.12)
  T.eq("C5 and sends the market to clients once", #sends, 1)
  T.eq("C6 with its history", sends[1], true)
  g_messageCenter:publish(MessageType.DAY_CHANGED, 4)
  T.eq("C7 a second day change runs it a second time", e._dailyCalls, 2)
  T.eq("C8 and appends a second sample", #e.prices[2].history, 2)
  for _ = 1, 8 do g_messageCenter:publish(MessageType.DAY_CHANGED, 5) end
  T.eq("C9 the history keeps its 7-day cap", #e.prices[2].history, 7)
end

-- =====================================================================
-- D: guards
-- =====================================================================
do
  local mdm, e = newSession()
  mdm._loadPhase = true
  g_messageCenter:publish(MessageType.DAY_CHANGED, 3)
  T.eq("D1 a day change during the load phase does nothing", e._dailyCalls, 0)
  mdm._loadPhase = false
  mdm.isActive = false
  g_messageCenter:publish(MessageType.DAY_CHANGED, 3)
  T.eq("D2 a day change on an inactive coordinator does nothing", e._dailyCalls, 0)
  mdm.isActive = true

  g_server = nil
  local ok = try(mdm, "_onIncumbentDayChanged")
  T.eq("D3 the handler does nothing without a server", e._dailyCalls, 0)
  T.ok("D3b and the handler exists", ok)
  g_server = {}

  local cal, ce = newSession({ calendar = true })
  local okCal = try(cal, "_onIncumbentDayChanged")
  T.eq("D4 the incumbent handler does nothing on a calendar session", ce._dailyCalls, 0)
  T.ok("D4b and the handler exists", okCal)
end

-- =====================================================================
-- E: delete removes the subscription
-- =====================================================================
do
  local mdm, e = newSession()
  local okDelete, errDelete = pcall(mdm.delete, mdm)
  T.ok("E1 delete runs", okDelete, tostring(errDelete))
  T.eq("E2 no DAY_CHANGED subscription with this coordinator as target remains",
    g_messageCenter:count(MessageType.DAY_CHANGED, mdm), 0)
  mdm.isActive = true -- a stale handle: only a leaked subscription could run it now
  g_messageCenter:publish(MessageType.DAY_CHANGED, 3)
  T.eq("E3 a day change after delete does nothing", e._dailyCalls, 0)
end
