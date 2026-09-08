--!load: src/MarketSerializer.lua, src/events/MDMMarketSyncEvent.lua, src/BCIntegration.lua, src/MarketEngine.lua, src/events/ColdSnapEvent.lua
-- RSF-F203 source witnesses and reference contracts. These models do not execute
-- a repaired serializer, clock adapter, event callback or network transport.
MDMLog = { info=function() end, warn=function() end, error=function() end }
MDMUtil = { getGameTime=function() return 100000 end, getMonotonicTime=function() return 100000 end }
local sourceMarketSyncEvent = MDMMarketSyncEvent

-- A: actual supplied production interfaces expose the split and local recomposition.
do
    local engine = { prices={ [1]={ base=100, current=144, volatilityFactor=1.2, history={} } }, volatilityScale=1 }
    local coordinator = { marketEngine=engine, futuresMarket={ contracts={} },
        worldEvents={ registry={ sample={ lastFiredAt=123 } }, active={ sample={ endsAt=200000, intensity=.5 } } } }
    local data = MarketSerializer:toTable(coordinator)
    T.eq("A1 current serializer uses durable version three", data.version, 3)
    T.eq("A2 current durable snapshot omits active events", data.activeEvents, nil)
    T.eq("A3 current durable snapshot omits calendar admission", data.calendar, nil)
    T.eq("A4 current durable snapshot carries the factor", data.prices[1].volatilityFactor, 1.2)
    local snap = MDMMarketSyncEvent.new(engine, { active={} }, true)
    T.eq("A5 current wire constructor carries the final current quote", snap.prices[1].current, 144)
    T.eq("A6 current wire constructor carries the server base", snap.prices[1].base, 100)
    function engine:_recalculate(index)
        local p = self.prices[index]
        p.current = p.base * p.volatilityFactor * 1.5 -- synthetic local provider
    end
    g_MarketDynamics = { marketEngine=engine }
    MDMMarketSyncEvent.applyState(snap.prices, {})
    T.near("A7 real apply recomposes with the synthetic local provider", engine.prices[1].current, 180, 1e-9)
    T.ok("A8 resulting peer quote differs from the captured server quote", engine.prices[1].current ~= 144)
end

-- F: actual BC integration uses the canonical monotonic clock for expiry and
-- has no current sync send or server gate on its successful-finish path. The
-- fixture keeps the companion-manager eligibility checks real and only stubs
-- recomposition.
do
    AbstractMission = { finish=function() end }
    Utils = { appendedFunction=function(previous, appended)
        return function(self, ...)
            previous(self, ...)
            return appended(self, ...)
        end
    end }
    MissionFinishState = { SUCCESS=1 }
    g_modManager = { getModByName=function(_, name)
        if name == "FS25_FuturesMission" then return { version="fixture" } end
        return nil
    end }
    g_fillTypeManager = { getFillTypeByIndex=function(_, index) return { name="WHEAT", index=index } end }
    g_fruitTypeManager = { getFillTypeIndexByFruitTypeIndex=function(_, index)
        return index == 7 and 2 or nil
    end }
    local monoNow = 1000000
    local mission = { time=500000, fruitType={ index=7 }, environment={ dayTime=0 } }
    g_currentMission = mission
    g_server = nil
    local sendCount = 0
    MDMMarketSyncEvent = { sendToClients=function() sendCount = sendCount + 1 end }
    MDMUtil = {
        getGameTime = function() return 500000 end,
        getMonotonicTime = function() return monoNow end,
    }
    local engine = MarketEngine.new()
    engine.prices[2] = { base=100, current=100, volatilityFactor=1, modifiers={}, history={} }
    function engine:_recalculate(index)
        local entry = self.prices[index]
        local factor = entry.volatilityFactor
        for _, modifier in ipairs(entry.modifiers) do factor = factor * modifier.factor end
        entry.current = entry.base * factor
    end
    local originalAdd = engine.addModifier
    local addCount = 0
    function engine:addModifier(modifier)
        addCount = addCount + 1
        return originalAdd(self, modifier)
    end
    BCIntegration.init(engine, { contracts={} })
    BCIntegration._onMissionFinish(mission, MissionFinishState.SUCCESS)
    T.eq("F1 actual callback adds on a fixture with no g_server", addCount, 1)
    T.eq("F2 successful BC modifier uses the .92 supply factor", engine.prices[2].modifiers[1].factor, .92)
    T.near("F3 real MarketEngine mutation recomposes the quote", engine:getPrice(2), 92, 1e-9)
    local durable = MarketSerializer:toTable({ marketEngine=engine, futuresMarket={contracts={}}, worldEvents={registry={}} })
    T.eq("F3a actual durable price row has no modifier stack", durable.prices[1].modifiers, nil)
    T.eq("F3b actual durable serializer has no BC pending-removal set", durable.pendingRemovals, nil)
    -- Canonical clock: the spike lives exactly one monotonic hour.
    monoNow = monoNow + 3600000 - 1
    BCIntegration.update()
    T.eq("F4 spike survives just before the canonical hour", #engine.prices[2].modifiers, 1)
    monoNow = monoNow + 1
    BCIntegration.update()
    T.eq("F5 exact canonical hour removes the spike", #engine.prices[2].modifiers, 0)
    T.near("F6 expiry recomposes back to the base quote", engine:getPrice(2), 100, 1e-9)
    T.eq("F7 BC finish path sends no direct sync", sendCount, 0)
    T.eq("F8 actual expiry also sends no sync", sendCount, 0)
    g_currentMission, g_modManager, g_fillTypeManager, g_fruitTypeManager = nil, nil, nil, nil
    MDMMarketSyncEvent, g_server, MissionFinishState, AbstractMission, Utils = nil, nil, nil, nil, nil
end

-- G: reference-only reconciliation separates a transient public-clock offset
-- from the economic monotonic high-water. It models publication accounting;
-- it is not a production callback or event implementation.
do
    local function bridge()
        return { offset=0, lastMono=1000, endMono=5000, firedMono=2000,
            publicEnd=5000, publicFired=2000, displayDirty=false,
            quoteDirty=false, publishes=0, draws=0, stack={},
            hours=0, history=0, opportunities=0, client=false }
    end
    local function reconcile(s, mono, legacy)
        if s.client then return end
        local offset = legacy - mono
        if offset ~= s.offset then
            s.offset = offset
            s.publicEnd, s.publicFired = s.endMono + offset, s.firedMono + offset
            s.displayDirty = true
        end
        -- Ordinary high-water admission is deliberately not invoked here.
    end
    local function add(s, id, factor)
        if s.client then return end
        s.stack[id], s.quoteDirty = factor, true
    end
    local function remove(s, id)
        if s.client or s.stack[id] == nil then return end
        s.stack[id], s.quoteDirty = nil, true
    end
    local function flush(s, duringPublish)
        if s.client or not (s.quoteDirty or s.displayDirty) then return end
        s.quoteDirty, s.displayDirty = false, false
        s.publishes = s.publishes + 1
        if duringPublish then duringPublish() end
    end
    local s = bridge()
    reconcile(s, 1000, 1300)
    T.eq("G1 same mono offset change reprojects public expiry", s.publicEnd, 5300)
    T.eq("G2 same mono offset change reprojects public fired time", s.publicFired, 2300)
    T.eq("G3 canonical expiry is unchanged", s.endMono, 5000)
    T.eq("G4 canonical firing time is unchanged", s.firedMono, 2000)
    T.ok("G4a display publication is pending", s.displayDirty)
    T.eq("G4b offset change adds no ordinary quote request", s.quoteDirty, false)
    flush(s)
    T.eq("G4c display-only change actually publishes", s.publishes, 1)
    T.eq("G5 clock reconciliation creates no ordinary draw", s.draws, 0)
    T.eq("G6 clock reconciliation creates no hour work", s.hours, 0)
    T.eq("G7 clock reconciliation creates no history work", s.history, 0)
    T.eq("G8 clock reconciliation creates no opportunity work", s.opportunities, 0)
    reconcile(s, 1000, 1300)
    flush(s)
    T.eq("G9 repeating the same offset does not republish", s.publishes, 1)
    reconcile(s, 900, 1300)
    flush(s)
    T.eq("G9a earlier mono time can reproject public expiry", s.publicEnd, 5400)
    T.eq("G9b second projection uses canonical value without compounding offsets", s.publicFired, 2400)
    T.eq("G9c economic high-water stays fixed", s.lastMono, 1000)
    T.eq("G9d canonical remaining time matches displayed remaining time", s.publicEnd-1300, s.endMono-900)
    local prior = s.publishes
    add(s, "a", .92)
    remove(s, "a")
    flush(s)
    T.eq("G10 successful add and remove publish once without a new hour", s.publishes, prior+1)
    T.eq("G11 successful add and remove leave no pending quote dirty", s.quoteDirty, false)
    remove(s, "unknown")
    flush(s)
    T.eq("G12 unknown remove is inert", s.publishes, prior+1)
    add(s, "b", .92)
    add(s, "c", .92)
    flush(s)
    T.eq("G13 two batched adds publish once", s.publishes, prior+2)
    T.eq("G13a stack changes do not advance economic high-water", s.lastMono, 1000)
    T.eq("G13b stack changes draw no ordinary random quote", s.draws, 0)
    add(s, "d", .92)
    flush(s, function() add(s, "arrivedDuringPublish", .92) end)
    T.ok("G13c request arriving during publication remains pending", s.quoteDirty)
    flush(s)
    T.eq("G13d retained request reaches the next publication", s.publishes, prior+4)
    s.client = true
    add(s, "client", .92)
    flush(s)
    T.eq("G14 pure client path is ignored", s.publishes, prior+4)
    T.eq("G15 client mutation was not inserted", s.stack.client, nil)
end

-- H: reference BC lifetime is monotonic and factor-preserving, including
-- stacking and forward skips. Loading/deleting clears transient spikes; the
-- existing save contract has no durable spike field.
do
    local function spike(startMono, id)
        return { id=id, factor=.92, expiresAt=startMono + 3600000 }
    end
    local active = { spike(100000, "one") }
    T.eq("H1 BC lifetime is one monotonic hour", active[1].expiresAt, 3700000)
    T.eq("H2 BC factor remains .92", active[1].factor, .92)
    table.insert(active, spike(200000, "two"))
    T.eq("H3 legitimate spikes stack independently", #active, 2)
    local function expire(now)
        local removed = 0
        for i=#active,1,-1 do
            if now >= active[i].expiresAt then table.remove(active, i); removed = removed + 1 end
        end
        return removed
    end
    T.eq("H4 exact canonical due time removes once", expire(3700000), 1)
    T.eq("H5 forward skip removes remaining due spike once", expire(4000000), 1)
    T.eq("H6 repeated forward update has no second removal", expire(4000000), 0)
    local speedChanged = spike(500000, "speed")
    active = { speedChanged }
    T.eq("H7 still before canonical expiry retains spike", expire(4099999), 0)
    T.eq("H8 same monotonic endpoint is inert despite arbitrary frame scheduling", expire(4099999), 0)
    local removedAtDelete = 0
    local function clearTransient()
        for i=#active,1,-1 do
            table.remove(active, i)
            removedAtDelete = removedAtDelete + 1
        end
    end
    clearTransient()
    T.eq("H9 lifecycle cleanup removes the existing transient spike", removedAtDelete, 1)
    T.eq("H10 lifecycle cleanup leaves no pending expiry", expire(5000000), 0)
    clearTransient()
    T.eq("H11 repeated cleanup is inert", removedAtDelete, 1)
end

-- B: proposed canonical expiry versus unchanged public legacy epoch.
local function toMono(legacyValue, monoNow, legacyNow)
    return monoNow + (legacyValue - legacyNow)
end
local function publicTime(monoValue, monoNow, legacyNow)
    return legacyNow + (monoValue - monoNow)
end
do
    local expiry = toMono(150000, 900000, 100000)
    T.eq("B1 migration preserves remaining event time", expiry - 900000, 50000)
    T.eq("B2 projection returns the original public deadline", publicTime(expiry, 900000, 100000), 150000)
    T.eq("B3 remapped calendar preserves remaining duration", publicTime(expiry, 910000, 600000) - 600000, 40000)
    T.ok("B4 canonical expiry is due at its exact deadline", 950000 >= expiry)
    T.ok("B5 migrated expired event stays expired", toMono(99000, 900000, 100000) < 900000)
    local futures = { lockedPrice=321.25, deliveryTime=120000 }
    publicTime(expiry, 910000, 600000)
    T.eq("B6 event conversion does not alter fixture contract deadline", futures.deliveryTime, 120000)
    T.eq("B7 event conversion does not alter fixture locked price", futures.lockedPrice, 321.25)
end

-- C: reference opportunity phase. Calls are scalar observations, not raw dt.
local function phaseState(t, days)
    return { observed=t, days=days, phase=0, rolls=0 }
end
local function advance(s, t, days, enabled)
    if days ~= s.days then
        s.observed, s.days, s.phase = math.max(s.observed,t), days, 0
        return
    end
    if t <= s.observed then return end
    local total = s.phase + (t-s.observed) / (300000*days)
    local due = math.floor(total)
    s.observed, s.phase = t, total-due
    if due > 0 and enabled then s.rolls = s.rolls + 1 end
end
do
    local s = phaseState(0, 1)
    advance(s, 150000, 1, true)
    T.near("C1 half interval retains fractional opportunity", s.phase, .5, 1e-9)
    T.eq("C2 half interval does not roll", s.rolls, 0)
    advance(s, 300000, 1, true)
    T.eq("C3 complete interval rolls once", s.rolls, 1)
    advance(s, 300000, 1, true)
    T.eq("C4 duplicate observation does not roll again", s.rolls, 1)
    advance(s, 3150000, 1, true)
    T.eq("C5 nine skipped checks coalesce to one current roll", s.rolls, 2)
    T.near("C6 skipped whole opportunities leave only fraction", s.phase, .5, 1e-9)
    advance(s, 3450000, 1, false)
    T.eq("C7 disabled observation does not roll", s.rolls, 2)
    T.near("C8 disabled opportunity is consumed", s.phase, .5, 1e-9)
    advance(s, 3450001, 1, true)
    T.eq("C9 reenable does not flush old opportunities", s.rolls, 2)
    advance(s, 3600000, 4, true)
    T.eq("C10 period-length transition starts fresh phase", s.phase, 0)
    T.eq("C11 period-length transition does not fire", s.rolls, 2)
    advance(s, 4800000, 4, true)
    T.eq("C12 four-day scaling needs twenty game minutes", s.rolls, 3)
    advance(s, 1000000, 4, true)
    T.eq("C13 rewind keeps event opportunity high-water", s.observed, 4800000)
    s.phase = .75
    advance(s, 4800000, 2, true)
    T.eq("C14 same-time period change resets phase", s.phase, 0)
    T.eq("C15 same-time period change grants no roll", s.rolls, 3)
    advance(s, 4700000, 1, true)
    T.eq("C16 earlier-time period change does not lower high-water", s.observed, 4800000)
    T.eq("C17 earlier-time period change records live period length", s.days, 1)
end

-- D: selected snapshot references are fixtures, not disk/StateLedger proof.
local function selectSnapshot(ledger, own)
    if ledger and ledger.version == 3 and ledger.valid then return ledger, "ledger3" end
    if own and own.version == 3 and own.valid then return own, "own3" end
    if ledger and ledger.version == 2 then
        return { prices=ledger.prices, calendar=nil,
            activeEvents=(own and own.lastGameTime == ledger.lastGameTime) and own.activeEvents or {} }, "legacy"
    end
    return own or { activeEvents={} }, "fallback"
end
do
    local a = { version=3, valid=true, prices={ quote=120 }, calendar={ quoteHour=12 }, activeEvents={} }
    local b = { version=3, valid=true, prices={ quote=110 }, calendar={ quoteHour=11 }, activeEvents={old=true} }
    local selected = selectSnapshot(a,b)
    T.eq("D1 valid v3 ledger selects its complete snapshot", selected, a)
    T.eq("D2 selected cursor stays with its prices", selected.calendar.quoteHour, 12)
    T.eq("D3 included empty events do not borrow old XML events", next(selected.activeEvents), nil)
    a.valid = false
    T.eq("D4 invalid v3 ledger falls back to valid own snapshot", selectSnapshot(a,b), b)
    local legacy = { version=2, lastGameTime=100, prices={ quote=99 } }
    local own = { version=2, lastGameTime=90, activeEvents={ old=true } }
    local mixed = selectSnapshot(legacy,own)
    T.eq("D5 mismatched legacy active snapshot is not replayed", next(mixed.activeEvents), nil)
    T.eq("D6 legacy price state is retained without guessed cursor", mixed.prices, legacy.prices)
    T.eq("D7 legacy migration leaves cursor for first anchoring", mixed.calendar, nil)
    own.lastGameTime = 100
    T.eq("D8 matching legacy active state is available for one restore", selectSnapshot(legacy,own).activeEvents, own.activeEvents)
    local legacyLedger = { version=2, lastGameTime=100, prices={ quote=77 } }
    local ownV3 = { version=3, valid=true, prices={ quote=88 }, calendar={ quoteHour=8 }, activeEvents={} }
    T.eq("D9 valid own v3 beats legacy ledger v2 for market bundle", selectSnapshot(legacyLedger, ownV3), ownV3)
    -- Existing contract selection is a different owner path, not proved here.
end

-- E: reference final quote assignment follows local display callbacks.
do
    local entry = { base=100, current=180, volatilityFactor=1.2 }
    local row = { baseText=string.format("%.17g",100.125), currentText=string.format("%.17g",144.625) }
    entry.current = 777 -- synthetic display callback attempted a local recomposition
    entry.base, entry.current = tonumber(row.baseText), tonumber(row.currentText)
    T.near("E1 final received quote wins over local display callback", entry.current, 144.625, 1e-9)
    T.near("E2 received base travels with current quote", entry.base, 100.125, 1e-9)
    local before = entry.current
    local function clientRecalculate() return entry.current end
    T.eq("E3 reference pure-client recalc returns retained quote", clientRecalculate(), before)
end

-- I: the R2 event-row clarification preserves the real capture/onLoad contract.
-- Row packing/decoding below is reference code, not either production transport.
do
    MDMMarketSyncEvent = sourceMarketSyncEvent
    local payload = "b:WHEAT,BARLEY|s:SILAGE"
    local expiry = 21600123456.5
    local snap = MDMMarketSyncEvent.new({prices={}}, {
        active={ cold_snap={ endsAt=expiry, intensity=.25 } },
        registry={ cold_snap={ getExtraData=function() return payload end } },
    }, true)
    local captured = snap.activeEvents[1]
    T.eq("I1 actual capture retains event identity", captured.id, "cold_snap")
    T.eq("I2 actual capture retains crop-specific extraData", captured.extraData, payload)
    local function row(e)
        return { e.id, string.format("%.17g",e.endsAt), e.intensity, e.extraData }
    end
    local function finite(x)
        return type(x)=="number" and x==x and x~=math.huge and x~=-math.huge
    end
    local function decode(r)
        if #r~=4 or type(r[1])~="string" or r[1]=="" or type(r[2])~="string"
            or not finite(tonumber(r[2])) or not finite(r[3]) or type(r[4])~="string" then return nil end
        return { id=r[1], endsAt=tonumber(r[2]), intensity=r[3], extraData=r[4] }
    end
    local directTokens = row(captured)
    local nsArray = { 1 } -- event count, followed by its four-value sub-list
    for _,v in ipairs(row(captured)) do nsArray[#nsArray+1]=v end
    local direct = decode(directTokens)
    local fromNs = decode({nsArray[2],nsArray[3],nsArray[4],nsArray[5]})
    T.eq("I3 direct row has exactly four fields", #directTokens, 4)
    T.eq("I4 NS expiry stays a decimal string before writer", type(nsArray[3]), "string")
    T.eq("I5 both decoders retain the same identity", direct.id, fromNs.id)
    T.eq("I6 both decoders retain the same expiry", direct.endsAt, fromNs.endsAt)
    T.eq("I7 both decoders retain the same intensity", direct.intensity, fromNs.intensity)
    T.eq("I8 both decoders retain the same opaque crop data", direct.extraData, fromNs.extraData)
    T.eq("I9 decimal expiry roundtrips exactly in the reference model", direct.endsAt, expiry)
    T.eq("I10 empty extraData is a valid present field", decode({"drought","1000",.5,""}).extraData, "")
    T.eq("I11 missing extraData does not become valid empty data", decode({"cold_snap","1000",.5}), nil)
    T.eq("I12 truncated expiry-only row is rejected", decode({"1000"}), nil)
    T.eq("I13 numeric extraData is rejected", decode({"cold_snap","1000",.5,42}), nil)
    T.eq("I14 nonfinite projected expiry is rejected", decode({"cold_snap","nan",.5,""}), nil)
    local coldSnap
    for _,definition in ipairs(MDM_pendingRegistrations or {}) do
        if definition.id == "cold_snap" then coldSnap=definition; break end
    end
    T.ok("I15 actual ColdSnap descriptor has deterministic onLoad", coldSnap and type(coldSnap.onLoad)=="function")
    if coldSnap then
        local crops={WHEAT=3,BARLEY=4,SILAGE=5}
        local received={}
        g_fillTypeManager={getFillTypeByName=function(_,name) return crops[name] and {index=crops[name]} end}
        MDMEventConfig={applyExtra=function() end} -- independent configured crops excluded
        g_MarketDynamics={marketEngine={addModifier=function(_,modifier) received[modifier.fillTypeIndex]=modifier.factor end}}
        coldSnap.onLoad(direct.intensity,direct.extraData)
        T.near("I16 real onLoad restores boosted wheat from row", received[3],1.19,1e-9)
        T.near("I17 real onLoad restores boosted barley from row", received[4],1.19,1e-9)
        T.near("I18 real onLoad restores suppressed silage from row", received[5],.85,1e-9)
        T.eq("I19 real event returns the same affected-crop record", coldSnap.getExtraData(),payload)
    end
end

-- J: actual MDMMarketSyncEvent writeStream/readStream round-trips through the
-- mock typed FIFO with zero type errors and zero underflows, carrying the
-- MDM-CALENDAR/1 wire mark, sector-digit base/current, and decimal-string
-- event deadlines.
do
    MDMMarketSyncEvent = sourceMarketSyncEvent
    local engine = { prices = {
        [1] = { base=100.125, current=144.625, volatilityFactor=1.2, history={ {price=140, time=1000} } },
        [2] = { base=50, current=55.5, volatilityFactor=0.9, history={} },
    } }
    local worldEvents = { active = {
        cold_snap = { endsAt=21600123456.5, intensity=.25 },
    }, registry = {
        cold_snap = { getExtraData=function() return "b:WHEAT|s:SILAGE" end },
    } }
    local snap = MDMMarketSyncEvent.new(engine, worldEvents, true)
    local stream = _sfMockStream()
    snap:writeStream(stream)
    local received = MDMMarketSyncEvent.emptyNew()
    received:readStream(stream, { getIsServer=function() return false end })
    T.eq("J1 wire round-trip has zero type errors", stream.typeErrors, 0)
    T.eq("J2 wire round-trip has zero underflows", stream.underflows, 0)
    T.eq("J3 wire round-trip drains the FIFO exactly", stream.r, #stream.q + 1)
    T.eq("J4 received base travels with the quote", received.prices[1].base, 100.125)
    T.eq("J5 received current quote is exact", received.prices[1].current, 144.625)
    T.eq("J6 received volatility factor survives", received.prices[1].volatilityFactor, 1.2)
    T.eq("J7 received history row survives", received.prices[1].history[1].price, 140)
    T.eq("J8 second price row round-trips", received.prices[2].current, 55.5)
    T.eq("J9 received event identity survives", received.activeEvents[1].id, "cold_snap")
    T.eq("J10 decimal event deadline round-trips exactly", received.activeEvents[1].endsAt, 21600123456.5)
    T.eq("J11 received event intensity survives", received.activeEvents[1].intensity, .25)
    T.eq("J12 received opaque crop data survives", received.activeEvents[1].extraData, "b:WHEAT|s:SILAGE")
end

g_MarketDynamics = nil
T.summary()
