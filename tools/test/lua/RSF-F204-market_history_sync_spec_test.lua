--!load: src/events/MDMMarketSyncEvent.lua, src/MDMNetworkSyncBridge.lua, src/MarketEngine.lua, src/MarketDynamics.lua
-- RSF-F204: market history transport contract, run against production code.
--
-- Ported from Office Tyson/mods/FS25_MarketDynamics/RSF-F204-market_history_sync_spec_test.lua
-- (bar authored by Iris, re-pointed by ClaudeA). The original group A recorded the
-- incumbent seam (history stripped at both constructors, presence inferred from
-- length); those witnesses are inverted here. The original group B modeled the
-- included/omitted contract with a helper; here every call goes through the real
-- MDMMarketSyncEvent.applyState. Logic evidence only: no native multiplayer, no
-- GIANTS Event framing, no wire ordering proof.

MDMLog = MDMLog or { info=function() end, warn=function() end, debug=function() end, error=function() end }
MDMUtil = MDMUtil or {}
MDMUtil.getGameTime = MDMUtil.getGameTime or function() return 0 end
MDMContractRequestEvent = MDMContractRequestEvent or { ACTION_CREATE = "create" }
MDMContractSyncEvent = MDMContractSyncEvent or { SYNC_FULL = "full", execute=function() end }

local function sample(price, time) return { price=price, time=time } end
local function twoSamples() return { sample(90, 1), sample(101.25, 2) } end

-- Real MarketEngine with one price entry. `modifiers` is required by _recalculate.
local function engineWith(history)
    local e = MarketEngine.new()
    local entry = { base = 100, current = 101.25, volatilityFactor = 1.1, modifiers = {}, history = history or {} }
    e.prices[1] = entry
    return e, entry
end

local function worldEventsStub()
    return { active = {}, registry = {}, isInitialized = true,
             _expireEvent = function() end, loadActiveEvent = function() end }
end

local function clientMdm(history)
    local e, entry = engineWith(history)
    g_MarketDynamics = { marketEngine = e, worldEvents = worldEventsStub(), futuresMarket = { contracts = {} },
                         _marketStateReady = false }
    return e, entry
end

-- ── A: marks and constructor ───────────────────────────────
do
    T.eq("A1 WIRE_MARK is still MDM-CALENDAR/1 (array envelope untouched)", MDMMarketSyncEvent.WIRE_MARK, "MDM-CALENDAR/1")
    T.eq("A2 STREAM_MARK is MDM-CALENDAR/2", MDMMarketSyncEvent.STREAM_MARK, "MDM-CALENDAR/2")
    T.ok("A3 STREAM_MARK differs from WIRE_MARK", MDMMarketSyncEvent.STREAM_MARK ~= MDMMarketSyncEvent.WIRE_MARK)

    local e = engineWith(twoSamples())
    local we = { active = {}, registry = {} }
    local full = MDMMarketSyncEvent.new(e, we, true)
    local omitFalse = MDMMarketSyncEvent.new(e, we, false)
    local omitNil = MDMMarketSyncEvent.new(e, we)
    T.eq("A4 historyIncluded equals constructor true", full.historyIncluded, true)
    T.eq("A5 historyIncluded equals constructor false", omitFalse.historyIncluded, false)
    T.eq("A6 historyIncluded is false for a nil constructor argument", omitNil.historyIncluded, false)
    T.eq("A7 included constructor carries the two real samples", #full.prices[1].history, 2)
    T.eq("A8 omitted constructor strips history", #omitNil.prices[1].history, 0)
    T.near("A9 included snapshot preserves the first price", full.prices[1].history[1].price, 90, 1e-9)

    -- historyIncluded is the constructor fact, not a length inference: an included
    -- capture of an engine with no history is still included.
    local e0 = engineWith({})
    local fullEmpty = MDMMarketSyncEvent.new(e0, we, true)
    T.eq("A10 included capture of empty history is still historyIncluded", fullEmpty.historyIncluded, true)
    T.eq("A11 included capture of empty history carries zero samples", #fullEmpty.prices[1].history, 0)

    -- Direct join path (NetworkSync absent, joining farmer): sendToClient must
    -- build an included event that carries the server samples.
    local sent
    g_MarketDynamics = { marketEngine = e, worldEvents = we }
    g_server = { broadcastEvent = function() end }
    local connection = { sendEvent = function(_, event) sent = event end }
    MDMMarketSyncEvent.sendToClient(connection)
    T.ok("A12 direct join send builds an event", sent ~= nil)
    T.eq("A13 direct join send is historyIncluded", sent.historyIncluded, true)
    T.eq("A14 direct join send carries the two server samples", #sent.prices[1].history, 2)
    g_server = nil
end

-- ── B: NetworkSync full array carries history both ways ─────
do
    local e, entry = engineWith(twoSamples())
    g_MarketDynamics = { marketEngine = e, worldEvents = { active = {}, registry = {} }, futuresMarket = { contracts = {} } }
    local module
    local ns = { registerAction = function() end,
                 registerModule = function(_, _, definition) module = definition end,
                 markDirty = function() end }
    g_currentMission = { networkSync = ns }
    MDMNetworkSyncBridge.register(g_MarketDynamics)
    T.ok("B1 real bridge registers a state module", module ~= nil)
    local array = module.onWriteState()
    -- Layout for this fixture: [1] wire mark, [2] contractCount=0, [3] priceCount=1,
    -- [4] index, [5] base text, [6] current text, [7] volatilityFactor, [8] histCount,
    -- then (price, time) pairs.
    T.eq("B2 array keeps the WIRE_MARK", array[1], "MDM-CALENDAR/1")
    T.eq("B3 array writes one price", array[3], 1)
    T.eq("B4 array histCount equals the server history count", array[8], #entry.history)
    T.eq("B5 array carries the first sample price", array[9], 90)
    T.eq("B6 array carries the first sample time", array[10], 1)
    T.eq("B7 array carries the second sample price", array[11], 101.25)
    T.eq("B8 array carries the second sample time", array[12], 2)

    -- Client side: a joiner with no history adopts the array's history.
    g_server = nil
    local ce, centry = clientMdm({})
    module.onReadState(array)
    T.eq("B9 client adopts the array history", #centry.history, 2)
    T.near("B10 adopted history keeps the newest price", centry.history[2].price, 101.25, 1e-9)
    T.eq("B11 client is ready after the full array apply", g_MarketDynamics._marketStateReady, true)

    -- Server with legitimately empty history: the full array clears the client.
    g_server = nil
    local se = engineWith({})
    g_MarketDynamics = { marketEngine = se, worldEvents = { active = {}, registry = {} }, futuresMarket = { contracts = {} } }
    local emptyArray = module.onWriteState()
    T.eq("B12 empty server history writes histCount zero", emptyArray[8], 0)
    local ce2, centry2 = clientMdm(twoSamples())
    module.onReadState(emptyArray)
    T.eq("B13 applyStateArray with empty history clears the client", #centry2.history, 0)
    T.eq("B14 client is ready after an empty full array apply", g_MarketDynamics._marketStateReady, true)

    MDMNetworkSyncBridge.stateActive = false
    MDMNetworkSyncBridge._ns = nil
    g_currentMission = { time = 1000, environment = { currentDay = 1, daysPerPeriod = 1 }, missionInfo = {} }
end

-- ── C: direct stream layout and roundtrip ──────────────────
do
    local clientConn = { getIsServer = function() return true end } -- the peer is the server, so we are a client
    local e = engineWith(twoSamples())
    local we = { active = {}, registry = {} }

    -- Included stream: bool sits after the mark and before the price count.
    local s = _sfMockStream()
    MDMMarketSyncEvent.new(e, we, true):writeStream(s, clientConn)
    T.eq("C1 stream slot 1 is STREAM_MARK", s.q[1].v, MDMMarketSyncEvent.STREAM_MARK)
    T.eq("C2 stream slot 2 is the bool", s.q[2].t, "bool")
    T.eq("C3 stream slot 2 carries true when included", s.q[2].v, true)
    T.eq("C4 stream slot 3 is the price count", s.q[3].t, "i32")
    T.eq("C5 stream price count is one", s.q[3].v, 1)

    g_server = nil
    local ce, centry = clientMdm({})
    local recv = MDMMarketSyncEvent.emptyNew()
    recv:readStream(s, clientConn)
    T.eq("C6 roundtrip read historyIncluded true", recv.historyIncluded, true)
    T.eq("C7 roundtrip drains the stream exactly", s.r, #s.q + 1)
    T.eq("C8 roundtrip has zero type mismatches", s.typeErrors, 0)
    T.eq("C9 roundtrip has zero underflows", s.underflows, 0)
    T.eq("C10 roundtrip applied the two samples on the client", #centry.history, 2)
    T.eq("C11 client is ready after the included stream apply", g_MarketDynamics._marketStateReady, true)

    -- Omitted stream: bool false, zero-count history, client history preserved.
    local s2 = _sfMockStream()
    MDMMarketSyncEvent.new(e, we):writeStream(s2, clientConn)
    T.eq("C12 omitted stream writes bool false", s2.q[2].v, false)
    local ce2, centry2 = clientMdm(twoSamples())
    local recv2 = MDMMarketSyncEvent.emptyNew()
    recv2:readStream(s2, clientConn)
    T.eq("C13 omitted stream read historyIncluded false", recv2.historyIncluded, false)
    T.eq("C14 omitted stream preserves the client's two samples", #centry2.history, 2)
    T.eq("C15 omitted stream drains exactly", s2.r, #s2.q + 1)
    T.eq("C16 omitted stream leaves the client not ready", g_MarketDynamics._marketStateReady, false)

    -- Old-layout stream ("/1" mark) is rejected at the mark with no apply.
    local s3 = _sfMockStream()
    streamWriteString(s3, "MDM-CALENDAR/1")
    streamWriteInt32(s3, 1)
    streamWriteInt32(s3, 1)
    local ce3, centry3 = clientMdm(twoSamples())
    local applied = false
    local origApply = MDMMarketSyncEvent.applyState
    MDMMarketSyncEvent.applyState = function(...) applied = true; return origApply(...) end
    local recv3 = MDMMarketSyncEvent.emptyNew()
    recv3:readStream(s3, clientConn)
    MDMMarketSyncEvent.applyState = origApply
    T.eq("C17 a /1 stream mark is rejected without apply", applied, false)
    T.eq("C18 rejected stream reads only the mark", s3.r, 2)
    T.eq("C19 rejected stream leaves client history intact", #centry3.history, 2)
    T.eq("C20 rejected stream leaves the client not ready", g_MarketDynamics._marketStateReady, false)
end

-- ── D: applyState inclusion semantics ──────────────────────
do
    g_server = nil
    local seeds = 0
    MDMMarketScreenGraph = { seedFromHistory = function() seeds = seeds + 1 end }

    -- Included nonempty replaces, with a copy.
    local e, entry = clientMdm(twoSamples())
    local incoming = { sample(120, 3) }
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2, history=incoming } }, {}, true)
    T.eq("D1 included nonempty replaces the sample count", #entry.history, 1)
    T.near("D2 included replacement carries the supplied price", entry.history[1].price, 120, 1e-9)
    T.ok("D3 entry.history does not alias the incoming array", entry.history ~= incoming)
    T.ok("D4 entry.history samples do not alias incoming samples", entry.history[1] ~= incoming[1])
    T.eq("D5 included nonempty seeds the graph once", seeds, 1)

    -- Included empty clears and does not seed.
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2, history={} } }, {}, true)
    T.eq("D6 included empty clears all samples", #entry.history, 0)
    T.eq("D7 included empty does not seed", seeds, 1)

    -- Omitted (false) preserves, no seed.
    local e2, entry2 = clientMdm(twoSamples())
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2, history={} } }, {}, false)
    T.eq("D8 omitted (false) with count zero preserves the two samples", #entry2.history, 2)
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2, history={ sample(5, 9) } } }, {}, false)
    T.eq("D9 omitted (false) with a stray nonempty payload still preserves", #entry2.history, 2)
    T.near("D10 preserved history keeps its newest price", entry2.history[2].price, 101.25, 1e-9)

    -- Nil inclusion is omitted, never included-empty.
    local e3, entry3 = clientMdm(twoSamples())
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2, history={} } }, {})
    T.eq("D11 nil inclusion preserves the two samples", #entry3.history, 2)
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2 } }, {}, nil)
    T.eq("D12 nil inclusion with no history field preserves", #entry3.history, 2)
    T.eq("D13 omitted and nil applies never seed", seeds, 1)

    -- Included with a missing history field clears (authoritative, nothing to carry).
    local e4, entry4 = clientMdm(twoSamples())
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.2 } }, {}, true)
    T.eq("D14 included with no history field clears", #entry4.history, 0)

    MDMMarketScreenGraph = nil
end

-- ── E: senders ─────────────────────────────────────────────
do
    local sent = {}
    g_server = { broadcastEvent = function(_, ev) sent[#sent + 1] = ev end }
    MDMNetworkSyncBridge.stateActive = false
    MDMNetworkSyncBridge._ns = nil

    local e, entry = engineWith({})
    g_MarketDynamics = { marketEngine = e, worldEvents = { active = {}, registry = {} }, priceModifiers = {} }

    -- Intraday only.
    e.intradayTimer = 60 * 1000
    e.dailyTimer = 0
    e:update(0)
    T.eq("E1 intraday-only tick sends exactly one event", #sent, 1)
    T.eq("E2 intraday-only send includes history", sent[1].historyIncluded, true)
    T.eq("E3 intraday-only tick appends no daily sample", #entry.history, 0)

    -- Daily only.
    sent = {}
    e.intradayTimer = 0
    e.dailyTimer = 24 * 60 * 60 * 1000
    e:update(0)
    T.eq("E4 daily-only tick sends exactly one event", #sent, 1)
    T.eq("E5 daily-only send includes history", sent[1].historyIncluded, true)
    T.eq("E6 daily-only tick appended one sample on the server", #entry.history, 1)
    T.eq("E7 daily-only send carries that sample", #sent[1].prices[1].history, 1)

    -- Coincident.
    sent = {}
    e.intradayTimer = 60 * 1000
    e.dailyTimer = 24 * 60 * 60 * 1000
    e:update(0)
    T.eq("E8 coincident tick coalesces into one send", #sent, 1)
    T.eq("E9 coincident send includes history", sent[1].historyIncluded, true)
    T.eq("E10 coincident send carries two samples", #sent[1].prices[1].history, 2)

    -- No change: no send.
    sent = {}
    e.intradayTimer = 0
    e.dailyTimer = 0
    e:update(0)
    T.eq("E11 an idle tick sends nothing", #sent, 0)

    -- Calendar publisher.
    sent = {}
    local mdm = setmetatable({ quoteDirty = true, displayDirty = false }, MarketDynamics)
    mdm:_flushPublications()
    T.eq("E12 _flushPublications publishes once", #sent, 1)
    T.eq("E13 publishMarketState includes history", sent[1].historyIncluded, true)
    T.eq("E14 flush clears the dirty flags", mdm.quoteDirty or mdm.displayDirty, false)

    -- Omit form used by the three non-history callers (WorldEventSystem,
    -- MDMEventSettingsDialog, AdminCommands): sendToClients() with no argument.
    sent = {}
    MDMMarketSyncEvent.sendToClients()
    T.eq("E15 argument-less sendToClients broadcasts", #sent, 1)
    T.eq("E16 argument-less sendToClients omits history", sent[1].historyIncluded, false)

    -- NetworkSync active: markStateDirty handles it, no direct broadcast.
    sent = {}
    local dirty = 0
    MDMNetworkSyncBridge.stateActive = true
    MDMNetworkSyncBridge._ns = { markDirty = function() dirty = dirty + 1 end }
    MDMMarketSyncEvent.sendToClients(true)
    T.eq("E17 markStateDirty true means no direct broadcast", #sent, 0)
    T.eq("E18 markStateDirty marked the module dirty once", dirty, 1)
    MDMNetworkSyncBridge.stateActive = false
    MDMNetworkSyncBridge._ns = nil
    g_server = nil
end

-- ── F: readiness flag ──────────────────────────────────────
do
    -- Coordinator construction stubs (subsystems not under test).
    WorldEventSystem = { new = function() return { active = {}, registry = {} } end }
    FuturesMarket = { new = function() return { contracts = {} } end }
    BCIntegration = {}
    MDMRWEIntegration = { new = function() return { cleanup = function() end } end }
    g_modManager = { getModByName = function() return { version = "test" } end }
    MDMEventConfig = { load = function() end, validateAndClean = function() end }
    MDMStateLedgerBridge = { register = function() end, hasState = function() return false end }
    UPIntegration = { reregisterActiveContracts = function() end }
    MDMSettingsHubBridge = { register = function() end }
    MDMContractSyncRequestEvent = { sendToServer = function() end }
    MDMAdminCommands_remove = function() end
    MDMDialogLoader = { cleanup = function() end }
    OrganicPremiumBridge = { unregister = function() end }
    local serializerCalls = { load = 0, finalize = 0, project = 0 }
    MarketSerializer = {
        load = function() serializerCalls.load = serializerCalls.load + 1 end, -- "no save": nothing restored
        finalizeRestore = function() serializerCalls.finalize = serializerCalls.finalize + 1 end,
        projectIncumbentRestore = function() serializerCalls.project = serializerCalls.project + 1 end,
    }
    g_timeGuard = nil
    MessageType = nil

    g_server = nil
    local mdm = MarketDynamics.new("dir", "FS25_MarketDynamics")
    T.eq("F1 readiness is false after new", mdm._marketStateReady, false)

    -- Server, calendar model, no save.
    g_server = {}
    g_MarketDynamics = mdm
    mdm.settings.experimentalSystems = true
    mdm:onStartMission({})
    T.eq("F2 server calendar restore sets readiness true", mdm._marketStateReady, true)
    T.eq("F3 calendar path ran finalizeRestore", serializerCalls.finalize, 1)
    mdm:delete()
    T.eq("F4 readiness is false after delete", mdm._marketStateReady, false)

    -- Server, incumbent model, no save.
    local mdm2 = MarketDynamics.new("dir", "FS25_MarketDynamics")
    g_MarketDynamics = mdm2
    mdm2.settings.experimentalSystems = false
    mdm2:onStartMission({})
    T.eq("F5 server incumbent restore sets readiness true", mdm2._marketStateReady, true)
    T.eq("F6 incumbent path ran projectIncumbentRestore", serializerCalls.project, 1)
    mdm2:delete()
    T.eq("F7 readiness is false after delete (incumbent)", mdm2._marketStateReady, false)

    -- Pure client: onStartMission never sets readiness.
    g_server = nil
    local cli = MarketDynamics.new("dir", "FS25_MarketDynamics")
    g_MarketDynamics = cli
    cli:onStartMission({})
    T.eq("F8 client onStartMission leaves readiness false", cli._marketStateReady, false)

    -- Omitted delta before the first full snapshot: still not ready.
    cli.marketEngine.prices[1] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
    cli.worldEvents = worldEventsStub()
    MDMMarketSyncEvent.applyState({ { index=1, volatilityFactor=1.05, history={} } }, {}, false)
    T.eq("F9 omitted delta before the first snapshot leaves readiness false", cli._marketStateReady, false)

    -- Error mid-apply (events stage throws): readiness stays false.
    cli.worldEvents.active = { ghost = { endsAt = 1, intensity = 1 } }
    cli.worldEvents._expireEvent = function() error("boom") end
    local ok = pcall(MDMMarketSyncEvent.applyState, { { index=1, volatilityFactor=1.05, history={} } }, {}, true)
    T.eq("F10 apply that errors mid-way raises", ok, false)
    T.eq("F11 readiness stays false when apply fails before completion", cli._marketStateReady, false)

    -- Included full apply with empty arrays completes readiness.
    cli.worldEvents = worldEventsStub()
    MDMMarketSyncEvent.applyState({}, {}, true)
    T.eq("F12 included full apply with empty arrays sets readiness true", cli._marketStateReady, true)
    T.eq("F13 client history untouched by an empty price list", #cli.marketEngine.prices[1].history, 0)
end
