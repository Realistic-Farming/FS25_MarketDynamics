--!load: src/MarketEngine.lua, src/WorldEventSystem.lua, src/RWEIntegration.lua, src/BCIntegration.lua, src/MarketSerializer.lua, src/MarketDynamics.lua
-- EC-6 (brief v1.7 section 3.2), the MarketDynamics half of the paired release.
--
-- Witnesses the real coordinator, engine, RWE/CS bridge and serializer:
--   C  the read-only capability rweConsumerContractVersion = 1, not saved;
--   X  the RandomWorldEvents reader is retired: an active RandomWorldEvents event
--      adds no rwe_ stack modifier on any path, while the SeasonalCropStress half
--      of the same update still runs; a registered consumer modifier is the one
--      path and composes once;
--   R  refreshConsumerPrices(): false on a client and during the load phase with
--      nothing changed; on the server it recomposes every current quote through the
--      registered modifiers and the clamp, requests publication, and changes no base,
--      volatility, stack modifier or history.
-- No game, network or rendering behaviour is proved here. The publication flush is
-- driven by calling it; the quote reaching a joined client is observation 28.
--
-- Every group runs under pcall, so a Lua error fails a named row instead of the
-- runner discarding the file. Every refusal has a twin proving the fixture reaches
-- the branch.

-- ── bench shim (as MD-15-session_latch_spec_test) ───────────
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
local published = 0
MDMMarketSyncEvent = { sendToClients = function() published = published + 1 end }

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

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

--- A server coordinator past its load phase with two tracked fill types.
local function newCoordinator()
  g_currentMission = {
    time = 5000,
    environment = { currentDay = 2, dayTime = 3600000, daysPerPeriod = 1, currentMonotonicDay = 2 },
    missionInfo = { savegameDirectory = "sg", savegameIndex = 1 },
  }
  local mdm = MarketDynamics.new("dir/", "FS25_MarketDynamics")
  local e = mdm.marketEngine
  e.prices[2] = { base = 100, current = 100, volatilityFactor = 1.1, modifiers = {}, history = { { price = 90, time = 1000 }, { price = 95, time = 2000 } } }
  e.prices[7] = { base = 50, current = 50, volatilityFactor = 1.0, modifiers = { { id = "bc_spike", fillTypeIndex = 7, factor = 0.92 } }, history = {} }
  mdm.isActive = true
  mdm._loadPhase = false
  mdm.economicModel = "incumbent"
  g_MarketDynamics = mdm
  return mdm
end

local function modifierIds(entry)
  local ids = {}
  for _, m in ipairs(entry.modifiers) do ids[#ids + 1] = m.id end
  return table.concat(ids, ",")
end

T.ok("C0 real MarketDynamics.lua loads under the bench shim", type(MarketDynamics) == "table" and type(MarketDynamics.new) == "function")

-- ══════════════════════════════════════════════════════════
-- C. THE CAPABILITY
-- ══════════════════════════════════════════════════════════
group("C", function()
  g_server = {}
  local mdm = newCoordinator()
  T.eq("C1 a MarketDynamics advertises rweConsumerContractVersion 1", mdm.rweConsumerContractVersion, 1)
  T.eq("C2 as a plain number", type(mdm.rweConsumerContractVersion), "number")
  T.eq("C3 and offers refreshConsumerPrices beside it", type(mdm.refreshConsumerPrices), "function")
  xmlStore = {}
  MarketSerializer:save(mdm)
  local x = xmlStore[SAVE_PATH]
  T.ok("C4 [reached] the save was written", x ~= nil and x["marketDynamics#version"] ~= nil)
  local leaked = false
  for k, v in pairs(x or {}) do
    if tostring(k):lower():find("rweconsumer") or tostring(k):lower():find("rwe") then leaked = true end
  end
  T.eq("C5 the capability is never written to the save", leaked, false)
  local t = MarketSerializer:toTable(mdm)
  T.eq("C6 nor to the StateLedger twin", t.rweConsumerContractVersion, nil)
  g_MarketDynamics = nil
end)

-- ══════════════════════════════════════════════════════════
-- X. THE RANDOMWORLDEVENTS READER IS RETIRED
-- ══════════════════════════════════════════════════════════
local OLD_READER_NAMES = { "market_boom", "market_crash", "export_opportunity", "economic_crisis",
                           "government_subsidy", "price_fixing", "crop_yield_penalty", "crop_yield_bonus" }

group("X", function()
  g_server = {}
  local mdm = newCoordinator()
  local rwe = { EVENT_STATE = { activeEvent = "market_boom" } }
  g_currentMission.randomWorldEvents = rwe
  g_currentMission.cropStressManager = { stressModifier = { fieldStress = { 0.9, 0.9, 0.1 } } }
  mdm.rweIntegration:detect()
  T.eq("X1 detection binds no RandomWorldEvents manager", mdm.rweIntegration.rweManager, nil)
  T.ok("X2 [reached] the SeasonalCropStress half of the same bridge was detected", mdm.rweIntegration.cropStressManager ~= nil)

  -- Drive the bridge's real per-frame update through a full raw day, for every name
  -- the old reader priced. The crop-stress modifier appearing proves the update ran.
  for _, name in ipairs(OLD_READER_NAMES) do
    rwe.EVENT_STATE.activeEvent = name
    mdm.rweIntegration:update(1000, "incumbent")
  end
  mdm.rweIntegration:update(86400000, "incumbent")
  T.eq("X3 [reached] the same update applied the crop-stress modifier", mdm.rweIntegration.lastCsModifierFactor, 1.12)
  local rweMods = 0
  for _, entry in pairs(mdm.marketEngine.prices) do
    for _, m in ipairs(entry.modifiers) do
      if tostring(m.id):sub(1, 4) == "rwe_" then rweMods = rweMods + 1 end
    end
  end
  T.eq("X4 no RandomWorldEvents event adds an rwe_ stack modifier, for any of the eight old names", rweMods, 0)
  T.eq("X5 fill type 2 carries only the crop-stress modifier", modifierIds(mdm.marketEngine.prices[2]), "cs_stress_pressure")

  -- Through the coordinator's own per-frame update, on the calendar path too.
  local mdm2 = newCoordinator()
  mdm2.economicModel = "calendar"
  g_currentMission.randomWorldEvents = { EVENT_STATE = { activeEvent = "export_opportunity" } }
  mdm2.rweIntegration:detect()
  local okU = pcall(mdm2.update, mdm2, 16)
  T.ok("X6 [reached] the coordinator's update ran", okU)
  T.eq("X7 the coordinator's update adds no rwe_ modifier either", modifierIds(mdm2.marketEngine.prices[2]), "")

  -- cleanup still lifts the crop-stress modifier with a RandomWorldEvents manager on the mission.
  mdm.rweIntegration:cleanup()
  T.eq("X8 cleanup lifts the crop-stress modifier (the kept half is unchanged)", modifierIds(mdm.marketEngine.prices[2]), "")
  T.eq("X9 and leaves the other stack entries alone", modifierIds(mdm.marketEngine.prices[7]), "bc_spike")

  -- The registered consumer modifier is the one path: applied once, clamped.
  local mdm3 = newCoordinator()
  mdm3:registerPriceModifier("RandomWorldEvents", function(ctx) return 1.2 end)
  mdm3.marketEngine:composeAll()
  T.near("X10 a registered RandomWorldEvents modifier composes exactly once", mdm3.marketEngine.prices[2].current, 100 * 1.1 * 1.2, 1e-9)
  g_currentMission.randomWorldEvents = nil
  g_currentMission.cropStressManager = nil
  g_MarketDynamics = nil
end)

-- ══════════════════════════════════════════════════════════
-- R. refreshConsumerPrices()
-- ══════════════════════════════════════════════════════════
group("R", function()
  g_server = {}
  local mdm = newCoordinator()
  local term = 1.2
  mdm:registerPriceModifier("RandomWorldEvents", function(ctx) return term end)
  mdm.marketEngine:composeAll()
  local e2, e7 = mdm.marketEngine.prices[2], mdm.marketEngine.prices[7]
  T.near("R0 [reached] the cached quote holds the event term", e2.current, 100 * 1.1 * 1.2, 1e-9)

  -- The event ends in RandomWorldEvents; the cached quote still holds its term.
  term = nil
  mdm.quoteDirty = false
  local before = { base2 = e2.base, vol2 = e2.volatilityFactor, mods7 = modifierIds(e7), hist2 = #e2.history, h2a = e2.history[1].price }

  -- Client: false, nothing composed, nothing requested.
  g_server = nil
  T.eq("R1 a client refresh returns false", mdm:refreshConsumerPrices(), false)
  T.near("R2 and recomposes nothing", e2.current, 100 * 1.1 * 1.2, 1e-9)
  T.eq("R3 and requests no publication", mdm.quoteDirty, false)
  g_server = {}

  -- Load phase: false, nothing composed.
  mdm._loadPhase = true
  T.eq("R4 a refresh during the load phase returns false", mdm:refreshConsumerPrices(), false)
  T.near("R5 and recomposes nothing", e2.current, 100 * 1.1 * 1.2, 1e-9)
  T.eq("R6 and requests no publication", mdm.quoteDirty, false)
  mdm._loadPhase = false

  -- Server, loaded: the twin that proves both refusals are the gates.
  T.eq("R7 twin: on the loaded server it returns true", mdm:refreshConsumerPrices(), true)
  T.near("R8 the quote is recomposed without the ended term", e2.current, 100 * 1.1, 1e-9)
  T.near("R9 every tracked fill type is recomposed, stack modifiers included", e7.current, 50 * 1.0 * 0.92, 1e-9)
  T.eq("R10 publication is requested", mdm.quoteDirty, true)
  T.eq("R11 no base price changed", e2.base, before.base2)
  T.eq("R12 no volatility changed", e2.volatilityFactor, before.vol2)
  T.eq("R13 no stack modifier changed", modifierIds(e7), before.mods7)
  T.eq("R14 no history changed", #e2.history .. "/" .. e2.history[1].price, before.hist2 .. "/" .. before.h2a)

  -- The clamp still bounds the composition on a refresh.
  term = 5.0
  mdm:refreshConsumerPrices()
  T.near("R15 the consumer clamp still applies (5.0 composes as 3.0)", e2.current, 100 * 1.1 * 3.0, 1e-9)

  -- The request is flushed by MarketDynamics' own publication path.
  published = 0
  mdm:_flushPublications()
  T.eq("R16 the requested publication goes out on the normal flush", published, 1)
  T.eq("R17 and the flag is cleared", mdm.quoteDirty, false)
  g_MarketDynamics = nil
end)
