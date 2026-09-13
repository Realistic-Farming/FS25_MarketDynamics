--!load: src/MarketEngine.lua, src/WorldEventSystem.lua, src/RWEIntegration.lua, src/BCIntegration.lua, src/MarketSerializer.lua, src/MarketDynamics.lua
-- MD-15 / RSF-F203 LOCKED default: strict per-mission server latch of the
-- economic model (brief :35, F203 :135-139).
--
-- Witnesses the real coordinator, engine, world-event system, RWE/BC bridges
-- and serializer under the bench shim:
--   L  latch truth table (nil / false / missing / non-boolean select the
--      incumbent, only true selects the calendar), no ReleaseGate use, fixed
--      for the session, pure client never selects;
--   S  onStartMission ordering (settings from the save decide, ticks only on
--      the selected calendar path, client requests sync and selects nothing);
--   T  one economic path per session: the incumbent ticks the raw-dt engine
--      and never _reconcile, the calendar the reverse, no double ticking, zero
--      draws from the other path, calendar tick callbacks inert on incumbent;
--   R  RWE crop-stress clock and BC supply-spike expiry follow the selection;
--   Z  serializer: incumbent writes legacy state (no stale v3 bundle),
--      calendar writes v3, v3-to-incumbent projects canonical dates into the
--      legacy fields, legacy-to-calendar anchors the first cursor.
-- No game, network or rendering behaviour is proved here.

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

local function latch(mdm)
  if type(mdm._latchEconomicModel) ~= "function" then return nil end
  return mdm:_latchEconomicModel()
end

T.ok("L0 real MarketDynamics.lua loads under the bench shim", type(MarketDynamics) == "table" and type(MarketDynamics.new) == "function")

-- ── L: latch truth table ───────────────────────────────────
do
  g_server = {}
  local gateCalls = 0
  ReleaseGate = { EXPERIMENTAL = {}, isSystemLive = function() gateCalls = gateCalls + 1; return true end,
                  isReleased = function() gateCalls = gateCalls + 1; return true end }

  local a = newCoordinator()
  T.eq("L1 shipped default is experimentalSystems=false", a.settings.experimentalSystems, false)
  T.eq("L2 default (false) settings select the incumbent", latch(a), "incumbent")

  local b = newCoordinator(); b.settings = nil
  T.eq("L3 nil settings table selects the incumbent", latch(b), "incumbent")

  local c = newCoordinator(); c.settings.experimentalSystems = nil
  T.eq("L4 missing experimentalSystems key selects the incumbent", latch(c), "incumbent")

  local d = newCoordinator(); d.settings.experimentalSystems = "true"
  T.eq("L5 a non-boolean truthy value does not select the calendar", latch(d), "incumbent")

  local e = newCoordinator(); e.settings.experimentalSystems = true
  T.eq("L6 experimentalSystems == true selects the calendar", latch(e), "calendar")
  local function usesCalendar(m) return type(m.usesCalendarModel) == "function" and m:usesCalendarModel() end
  T.ok("L7 usesCalendarModel reports the calendar selection", usesCalendar(e) == true)
  T.ok("L8 usesCalendarModel is false on the incumbent", usesCalendar(a) == false)

  T.eq("L9 the latch never consults the fail-open ReleaseGate", gateCalls, 0)
  T.ok("L10 the empty EXPERIMENTAL table is not a selection input", a.economicModel == "incumbent" and next(ReleaseGate.EXPERIMENTAL) == nil)

  -- Fixed for the session: a mid-session toggle does not move the latch.
  a.settings.experimentalSystems = true
  T.eq("L11 mid-session toggle on keeps the incumbent selection", latch(a), "incumbent")
  T.eq("L12 the coordinator field is unchanged by the toggle", a.economicModel, "incumbent")
  e.settings.experimentalSystems = false
  T.eq("L13 mid-session toggle off keeps the calendar selection", latch(e), "calendar")
  T.ok("L14 allowsExperimentalSystems still reflects the live setting (help text: next mission start)", a:allowsExperimentalSystems() == true and e:allowsExperimentalSystems() == false)

  -- Pure client: never selects.
  g_server = nil
  local f = newCoordinator(); f.settings.experimentalSystems = true
  T.eq("L15 a pure client latches nothing even with the toggle on", latch(f), nil)
  T.eq("L16 client economicModel stays nil", f.economicModel, nil)
  T.ok("L17 client latch attempt leaves the latch open (server-only state)", f._modelLatched ~= true)
  ReleaseGate = nil
end

-- ── S: onStartMission ordering ─────────────────────────────
do
  xmlStore = {}
  g_server = {}
  local s1 = newCoordinator()
  s1:onStartMission({})
  T.eq("S1 fresh server mission (no save) latches the incumbent", s1.economicModel, "incumbent")
  T.eq("S2 incumbent subscribes to no calendar tick source", s1.calendarSource, nil)
  T.eq("S3 incumbent holds no calendar cursor after restore", s1.lastObservedMs, nil)
  T.eq("S4 load phase is cleared after start", s1._loadPhase, false)

  local s2 = newCoordinator(); s2.settings.experimentalSystems = true
  s2:onStartMission({})
  T.eq("S5 experimental server mission latches the calendar", s2.economicModel, "calendar")
  T.eq("S6 calendar latches the native tick source when TimeGuard is absent", s2.calendarSource, "native")
  T.eq("S7 calendar cursor is anchored at the current monotonic time", s2.lastObservedMs, MONO_NOW)
  T.eq("S8 calendar processed hour anchors to the current farming hour", s2.processedHour, math.floor(MONO_NOW / 3600000))

  -- The SAVED setting decides, after serializer:load: a v2 save with the toggle
  -- on is loaded by a coordinator whose in-memory default is false.
  xmlStore = {}
  local writer = newCoordinator(); writer.settings.experimentalSystems = true
  writer.economicModel = "incumbent"     -- previous session ran the incumbent
  MarketSerializer:save(writer)
  T.eq("S9 fixture save was written", xmlStore[SAVE_PATH] ~= nil, true)
  T.eq("S10 fixture save carries experimentalSystems=true", xmlStore[SAVE_PATH]["marketDynamics.settings#experimentalSystems"], true)
  local s3 = newCoordinator()
  T.eq("S11 reader default is false before load", s3.settings.experimentalSystems, false)
  s3:onStartMission({})
  T.eq("S12 the saved setting selects the calendar after serializer:load", s3.economicModel, "calendar")

  -- And the reverse: a save with the toggle off, loaded by a coordinator that
  -- someone set to true in memory before start, still selects the incumbent.
  xmlStore = {}
  local writer2 = newCoordinator(); writer2.settings.experimentalSystems = false
  writer2.economicModel = "incumbent"
  MarketSerializer:save(writer2)
  local s4 = newCoordinator(); s4.settings.experimentalSystems = true
  s4:onStartMission({})
  T.eq("S13 the saved false overrides the in-memory true at selection time", s4.economicModel, "incumbent")

  -- Pure client start: requests sync, selects nothing, subscribes nothing.
  g_server = nil
  syncRequests = 0
  local s5 = newCoordinator(); s5.settings.experimentalSystems = true
  s5:onStartMission({})
  T.eq("S14 client start requests the contract sync", syncRequests, 1)
  T.eq("S15 client start selects no model", s5.economicModel, nil)
  T.eq("S16 client start subscribes to no calendar ticks", s5.calendarSource, nil)
  xmlStore = {}
end

-- ── T: one economic path per session ───────────────────────
do
  g_server = {}
  local bcCanonical, bcIncumbent = 0, 0
  local realBcUpdate, realBcIncumbent = BCIntegration.update, BCIntegration.updateIncumbent
  BCIntegration.update = function() bcCanonical = bcCanonical + 1 end
  BCIntegration.updateIncumbent = function() bcIncumbent = bcIncumbent + 1 end

  -- Incumbent session.
  local inc = newCoordinator()
  inc:onStartMission({})
  inc:update(60000)
  T.eq("T1 incumbent: one raw minute fires one intraday tick", inc.marketEngine._intradayCalls, 1)
  T.eq("T2 incumbent: _reconcile never runs", inc._reconcileCalls, 0)
  T.eq("T3 incumbent: no calendar quote step is drawn", inc.marketEngine._hourlyCalls, 0)
  T.eq("T4 incumbent: world-event raw-dt timer accumulates", inc.worldEvents.timer, 60000)
  T.eq("T5 incumbent: BC expiry runs on mission time", bcIncumbent, 1)
  T.eq("T6 incumbent: BC canonical expiry does not run", bcCanonical, 0)
  inc:update(86400000)
  T.eq("T7 incumbent: a full raw day fires the daily shift", inc.marketEngine._dailyCalls, 1)
  T.eq("T8 incumbent: still no calendar cursor after ticking", inc.lastObservedMs, nil)
  -- Calendar tick callbacks are inert on the incumbent.
  inc:_onNativeHourChanged(); inc:_onNativeDayChanged(); inc:_onCalendarTick("hour", {})
  T.eq("T9 incumbent: native/TimeGuard tick callbacks do not reconcile", inc._reconcileCalls, 0)
  MarketDynamics._reconcile(inc)   -- class method, bypassing the counting wrapper
  T.eq("T10 incumbent: a direct _reconcile call performs no observation", inc.lastObservedMs, nil)
  -- Mid-session toggle changes nothing this session.
  inc.settings.experimentalSystems = true
  inc:update(60000)
  T.eq("T11 incumbent: toggle mid-session still ticks the raw-dt engine", inc.marketEngine._intradayCalls, 3)
  T.eq("T12 incumbent: toggle mid-session still never reconciles", inc._reconcileCalls, 0)

  -- Calendar session.
  bcCanonical, bcIncumbent = 0, 0
  local cal = newCoordinator(); cal.settings.experimentalSystems = true
  cal:onStartMission({})
  cal:update(60000)
  T.eq("T13 calendar: _reconcile runs once per frame", cal._reconcileCalls, 1)
  T.eq("T14 calendar: raw-dt intraday tick never fires", cal.marketEngine._intradayCalls, 0)
  T.eq("T15 calendar: raw-dt engine timer does not accumulate", cal.marketEngine.intradayTimer, 0)
  T.eq("T16 calendar: world-event raw-dt timer does not accumulate", cal.worldEvents.timer, 0)
  T.eq("T17 calendar: BC expiry runs on the canonical clock", bcCanonical, 1)
  T.eq("T18 calendar: BC mission-time expiry does not run", bcIncumbent, 0)
  -- One crossed farming hour → one quote step on the calendar path only.
  MONO_NOW = MONO_NOW + 3600000
  cal:update(16)
  T.eq("T19 calendar: a crossed farming hour draws one quote step", cal.marketEngine._hourlyCalls, 1)
  T.eq("T20 calendar: the same hour again is inert", (function() cal:update(16); return cal.marketEngine._hourlyCalls end)(), 1)
  cal:_onNativeHourChanged()
  T.eq("T21 calendar: tick callback reconciles (idempotent with the frame)", cal._reconcileCalls, 4)
  T.eq("T22 calendar: still zero raw-dt ticks after four frames", cal.marketEngine._intradayCalls + cal.marketEngine._dailyCalls, 0)
  cal.settings.experimentalSystems = false
  cal:update(60000)
  T.eq("T23 calendar: toggle off mid-session still reconciles", cal._reconcileCalls, 5)
  T.eq("T24 calendar: toggle off mid-session never starts the raw-dt engine", cal.marketEngine._intradayCalls, 0)
  MONO_NOW = LEGACY_NOW

  -- Pure client runs neither simulation.
  g_server = nil
  bcCanonical, bcIncumbent = 0, 0
  local cli = newCoordinator(); cli.settings.experimentalSystems = true
  cli:onStartMission({})
  cli:update(60000)
  T.eq("T25 client: no reconcile", cli._reconcileCalls, 0)
  T.eq("T26 client: no raw-dt engine tick", cli.marketEngine._intradayCalls, 0)
  T.eq("T27 client: no calendar quote step", cli.marketEngine._hourlyCalls, 0)

  BCIntegration.update, BCIntegration.updateIncumbent = realBcUpdate, realBcIncumbent
  g_server = {}
end

-- ── R: RWE crop-stress clock and BC spike expiry per selection ──
do
  g_server = {}
  local function stressed()
    return { stressModifier = { fieldStress = { 0.9, 0.9, 0.1 } } }  -- 2/3 critical → strong
  end
  local e1 = MarketEngine.new(); e1.prices[2] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
  local r1 = MDMExternalIntegration.new(e1); r1.cropStressManager = stressed()
  r1:update(86400000 - 1, "incumbent")
  T.eq("R1 incumbent: crop stress is not evaluated before one raw day accumulates", r1.lastCsModifierFactor, nil)
  r1:update(1, "incumbent")
  T.eq("R2 incumbent: one accumulated raw day evaluates crop stress", r1.lastCsModifierFactor, 1.12)
  T.eq("R3 incumbent: the accumulator resets after the check", r1.csDailyTimer, 0)
  T.eq("R4 incumbent: the monotonic day cursor is untouched", r1.lastCsCheckMonotonicDay, nil)

  local e2 = MarketEngine.new(); e2.prices[2] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
  local r2 = MDMExternalIntegration.new(e2); r2.cropStressManager = stressed()
  r2:update(86400000, "calendar")
  T.eq("R5 calendar: first observed monotonic day evaluates once", r2.lastCsModifierFactor, 1.12)
  T.eq("R6 calendar: the raw-dt accumulator is not used", r2.csDailyTimer, 0)
  r2.lastCsModifierFactor = nil
  r2:update(86400000, "calendar")
  T.eq("R7 calendar: the same monotonic day does not re-evaluate", r2.lastCsModifierFactor, nil)

  -- BC: one recorded spike, two deadlines, exactly one read per selection.
  AbstractMission = { finish = function() end }
  Utils = { appendedFunction = function(prev, app) return function(self, ...) prev(self, ...); return app(self, ...) end end }
  MissionFinishState = { SUCCESS = 1 }
  g_modManager = { getModByName = function(_, name) if name == "FS25_FuturesMission" then return { version = "fixture" } end end }
  g_fillTypeManager = { getFillTypeByIndex = function(_, i) return { name = "WHEAT", index = i } end }
  g_fruitTypeManager = { getFillTypeIndexByFruitTypeIndex = function(_, i) return i == 7 and 2 or nil end }
  resetMission()
  g_currentMission.time = 500000
  local e3 = MarketEngine.new(); e3.prices[2] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
  BCIntegration.init(e3, { contracts = {} })
  BCIntegration._onMissionFinish({ time = 0, fruitType = { index = 7 } }, MissionFinishState.SUCCESS)
  T.eq("R8 BC: successful finish adds the .92 spike", #e3.prices[2].modifiers, 1)
  -- Advance mission time one hour; leave the canonical clock where it is.
  g_currentMission.time = 500000 + 3600000 - 1
  local okI = pcall(BCIntegration.updateIncumbent)
  T.ok("R9 BC: mission-time expiry keeps the spike one ms early", okI and #e3.prices[2].modifiers == 1)
  BCIntegration.update()
  T.eq("R10 BC: canonical expiry does not fire on mission time alone", #e3.prices[2].modifiers, 1)
  g_currentMission.time = 500000 + 3600000
  BCIntegration.update()
  T.eq("R11 BC: canonical clock unchanged, canonical expiry still keeps the spike", #e3.prices[2].modifiers, 1)
  okI = pcall(BCIntegration.updateIncumbent)
  T.ok("R12 BC: exact mission-time hour removes the spike on the incumbent", okI and #e3.prices[2].modifiers == 0)
  okI = pcall(BCIntegration.updateIncumbent)
  T.ok("R13 BC: the pending row is consumed once", okI and #e3.prices[2].modifiers == 0)
  g_modManager = { getModByName = function() return nil end }
  g_fillTypeManager, g_fruitTypeManager, AbstractMission, Utils, MissionFinishState = nil, nil, nil, nil, nil
end

-- ── Z: serializer shape per selection ──────────────────────
do
  g_server = {}
  local drought = { id = "drought", name = "Drought", probability = 0, minIntensity = 0.2, maxIntensity = 0.4,
                    onFire = function() end, onExpire = function() end }

  local function stateful(model, experimental)
    xmlStore = {}
    local m = newCoordinator()
    m.settings.experimentalSystems = experimental
    m.economicModel = model
    m.worldEvents:registerEvent(drought)
    m.worldEvents.registry.drought.lastFiredAt = LEGACY_NOW - 1000
    m.worldEvents.registry.drought.lastFiredMonotonicMs = MONO_NOW - 1000
    m.worldEvents.active.drought = { event = drought, endsAt = LEGACY_NOW + 7200000,
                                     endsAtMonotonicMs = MONO_NOW + 7200000, intensity = 0.3 }
    m.marketEngine.prices[2].lastHistoryDay = 41
    return m
  end

  local inc = stateful("incumbent", false)
  MarketSerializer:save(inc)
  local x = xmlStore[SAVE_PATH]
  T.eq("Z1 incumbent save stamps legacy version 2", x["marketDynamics#version"], "2")
  T.eq("Z2 incumbent save writes no lastMonotonicTime", x["marketDynamics#lastMonotonicTime"], nil)
  T.eq("Z3 incumbent save still writes lastGameTime", x["marketDynamics#lastGameTime"], tostring(LEGACY_NOW))
  T.eq("Z4 incumbent save writes no history-day cursor", x["marketDynamics.prices.price(0)#lastHistoryDay"], nil)
  T.eq("Z5 incumbent save writes no canonical firing time", x["marketDynamics.events.event(0)#lastFiredMonotonicMs"], nil)
  T.eq("Z6 incumbent save writes no canonical deadline", x["marketDynamics.activeEvents.event(0)#endsAtMonotonicMs"], nil)
  T.eq("Z7 incumbent save keeps the legacy public deadline", x["marketDynamics.activeEvents.event(0)#endsAt"], tostring(LEGACY_NOW + 7200000))
  T.eq("Z8 incumbent save keeps the price row", x["marketDynamics.prices.price(0)#index"], 2)
  local t = MarketSerializer:toTable(inc)
  T.eq("Z9 incumbent ledger twin is version 2", t.version, 2)
  T.eq("Z10 incumbent ledger twin omits lastMonotonicTime", t.lastMonotonicTime, nil)
  T.eq("Z11 incumbent ledger twin omits the history-day cursor", t.prices[1].lastHistoryDay, nil)
  T.eq("Z12 incumbent ledger twin omits the canonical firing time", t.eventCooldowns[1].lastFiredMonotonicMs, nil)

  local cal = stateful("calendar", true)
  MarketSerializer:save(cal)
  local y = xmlStore[SAVE_PATH]
  T.eq("Z13 calendar save stamps version 3", y["marketDynamics#version"], "3")
  T.eq("Z14 calendar save writes lastMonotonicTime", y["marketDynamics#lastMonotonicTime"], tostring(MONO_NOW))
  T.eq("Z15 calendar save writes the history-day cursor", y["marketDynamics.prices.price(0)#lastHistoryDay"], 41)
  T.eq("Z16 calendar save writes the canonical firing time", y["marketDynamics.events.event(0)#lastFiredMonotonicMs"], tostring(MONO_NOW - 1000))
  T.eq("Z17 calendar save writes the canonical deadline", y["marketDynamics.activeEvents.event(0)#endsAtMonotonicMs"], tostring(MONO_NOW + 7200000))
  local u = MarketSerializer:toTable(cal)
  T.eq("Z18 calendar ledger twin is version 3", u.version, 3)
  T.eq("Z19 calendar ledger twin carries lastMonotonicTime", u.lastMonotonicTime, MONO_NOW)
  T.eq("Z20 an unlatched coordinator writes legacy state (nil selects the incumbent)", MarketSerializer:toTable({ marketEngine = cal.marketEngine, futuresMarket = { contracts = {} }, worldEvents = { registry = {} } }).version, 2)

  -- v3-to-incumbent: a calendar session saved v3 with the toggle turned off
  -- mid-session; the restart selects the incumbent and projects the dates.
  xmlStore = {}
  local prev = stateful("calendar", true)
  prev.settings.experimentalSystems = false     -- toggled off mid-session, latch fixed
  MarketSerializer:save(prev)
  T.eq("Z21 fixture: the prior calendar session still saved v3", xmlStore[SAVE_PATH]["marketDynamics#version"], "3")
  -- Restart at a different clock offset so projection is observable.
  local savedEndsAtMono = MONO_NOW + 7200000
  LEGACY_NOW, MONO_NOW = 90000000 + 500000, 90000000 + 100000
  resetMission()
  local next1 = newCoordinator()
  next1.worldEvents:registerEvent(drought)
  next1:onStartMission({})
  T.eq("Z22 restart after v3 with the toggle off selects the incumbent", next1.economicModel, "incumbent")
  local act = next1.worldEvents.active.drought
  T.ok("Z23 the active event was restored", act ~= nil)
  T.eq("Z24 canonical deadline is projected into the legacy endsAt at the new offset", act and act.endsAt, LEGACY_NOW + (savedEndsAtMono - MONO_NOW))
  T.eq("Z25 no live canonical deadline is retained on the incumbent", act and act.endsAtMonotonicMs, nil)
  T.eq("Z26 canonical firing time is projected into lastFiredAt", next1.worldEvents.registry.drought.lastFiredAt, LEGACY_NOW + ((90000000 - 1000) - MONO_NOW))
  T.eq("Z27 no live canonical firing time is retained", next1.worldEvents.registry.drought.lastFiredMonotonicMs, nil)
  T.eq("Z28 no calendar cursor is retained", next1.lastObservedMs, nil)
  T.eq("Z29 restored price row drops the history-day cursor", next1.marketEngine.prices[2].lastHistoryDay, nil)
  T.eq("Z30 incumbent timers start from zero", next1.marketEngine.intradayTimer + next1.marketEngine.dailyTimer + next1.worldEvents.timer, 0)
  T.eq("Z31 the selection itself fires no event", (function() local n = 0; for _ in pairs(next1.worldEvents.active) do n = n + 1 end; return n end)(), 1)
  MarketSerializer:save(next1)
  T.eq("Z32 the incumbent's next save is legacy v2 again", xmlStore[SAVE_PATH]["marketDynamics#version"], "2")
  T.eq("Z33 the incumbent's next save carries no stale canonical deadline", xmlStore[SAVE_PATH]["marketDynamics.activeEvents.event(0)#endsAtMonotonicMs"], nil)

  -- legacy-to-calendar: an incumbent session saved v2 with the toggle turned
  -- on; the restart selects the calendar and anchors the first cursor.
  xmlStore = {}
  LEGACY_NOW, MONO_NOW = 90000000, 90000000
  resetMission()
  local prev2 = stateful("incumbent", true)
  MarketSerializer:save(prev2)
  T.eq("Z34 fixture: the prior incumbent session saved v2", xmlStore[SAVE_PATH]["marketDynamics#version"], "2")
  LEGACY_NOW, MONO_NOW = 90000000 + 500000, 90000000 + 100000
  resetMission()
  local next2 = newCoordinator()
  next2.worldEvents:registerEvent(drought)
  next2:onStartMission({})
  T.eq("Z35 restart after v2 with the toggle on selects the calendar", next2.economicModel, "calendar")
  local act2 = next2.worldEvents.active.drought
  T.ok("Z36 the active event was restored from legacy fields", act2 ~= nil)
  T.eq("Z37 canonical deadline is derived from the legacy endsAt at the current offset", act2 and act2.endsAtMonotonicMs, MONO_NOW + ((90000000 + 7200000) - LEGACY_NOW))
  T.eq("Z38 calendar cursor is anchored at the current monotonic time (first-anchor rule)", next2.lastObservedMs, MONO_NOW)
  T.eq("Z39 calendar path subscribed to the tick source", next2.calendarSource, "native")
  MarketSerializer:save(next2)
  T.eq("Z40 the calendar's next save is v3", xmlStore[SAVE_PATH]["marketDynamics#version"], "3")
  LEGACY_NOW, MONO_NOW = 90000000, 90000000
  xmlStore = {}
end

g_server = nil
g_currentMission = nil
