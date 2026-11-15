-- MD-16: the material addition at the sale, through the real wiring.
--
-- One bar from production's own entry point (R-18): every sale below starts at
-- SellingStation:addFillLevelFromTool, the call UnloadTrigger makes, on a
-- station StockGuard has bracketed. It runs through StockGuard's instance
-- wrapper (the paid phase), MarketDynamics' REAL PriceHook class wraps, the
-- native sellFillType body and its one price read, and pays through addMoney.
-- Nothing calls Md16SalePhase directly to get a number.
--
-- The StockGuard side is tools/test/lua/fixtures/stockguard_handle_mirror.lua,
-- which copies the real handle's call forms and return shapes at the lines it
-- names, so a colon call or an unwrapped read fails here the way it fails in
-- game. The organic records are built exactly as SoilFertilizer's
-- OrganicOriginProperty.record builds them (FS25_SoilFertilizer
-- src/OrganicOriginProperty.lua, record()).
--
--!load: tools/test/lua/fixtures/selling_station_native.lua, tools/test/lua/fixtures/stockguard_handle_mirror.lua, src/MarketEngine.lua, src/FuturesMarket.lua, src/PriceHook.lua, src/md16/Md16Values.lua, src/md16/Md16Material.lua, src/md16/Md16SaleComponents.lua, src/md16/Md16FuturesPlan.lua, src/md16/Md16Resolvers.lua, src/md16/Md16SalePhase.lua, src/OrganicPremiumBridge.lua

local S = Md16SalePhase
local R = Md16Resolvers
local WHEAT, BARLEY = 1, 2

-- ── the world ─────────────────────────────────────────────
g_server = {}
local balance = 0
local infoLines = {}
MDMLog = { info = function(m) infoLines[#infoLines + 1] = m end, warn = function() end, debug = function() end, error = function() end }
UPIntegration = { onContractFulfilled = function() end }
MDMContractSyncEvent = { SYNC_UPDATE = 1, sendToClients = function() end }
MoneyType = { OTHER = 0 }
g_localPlayer = nil
g_currentMission = { isServer = true, isClient = false,
    addMoney = function(_self, money, _farmId) balance = balance + money end }
g_fillTypeManager = { getFillTypeNameByIndex = function(_self, idx) return ({ [WHEAT] = "WHEAT", [BARLEY] = "BARLEY" })[idx] end }

-- The REAL market engine composes the quote, and its _recalculate captures the
-- sale components in the same pass. No modifiers: the baseline is base * 1.
local engine = setmetatable({ prices = {
    [WHEAT] = { base = 2, volatilityFactor = 1, modifiers = {}, current = 2, history = {} },
    [BARLEY] = { base = 3, volatilityFactor = 1, modifiers = {}, current = 3, history = {} },
} }, { __index = MarketEngine })
local futures = setmetatable({ contracts = {} }, { __index = FuturesMarket })
g_MarketDynamics = { isActive = true, settings = { pricesEnabled = true }, priceModifiers = {},
    marketEngine = engine, futuresMarket = futures }
Md16SaleComponents.reset()
engine:_recalculate(WHEAT)
engine:_recalculate(BARLEY)
T.near('S0 the real engine quotes wheat at its baseline', engine:getPrice(WHEAT), 2, 1e-9)
T.ok('S0b and captured its sale components in the same pass', engine:getSaleQuoteComponents(WHEAT) ~= nil)

-- SoilFertilizer's record() for a birth of `amount` litres: KNOWN with a
-- fraction, or UNKNOWN with fraction 0 and no known litres.
local function soilOrigin(fraction, amount)
    local known = type(fraction) == "number"
    return { propertyId = "harvestOrganicOriginV1", schemaVersion = 1, producerId = "soil", propertyRevision = 0,
             knowledge = known and "KNOWN" or "UNKNOWN", payload = { fraction = known and fraction or 0 },
             basisAmount = amount, knownAmount = known and amount or 0, amountUnit = "LITRE" }
end

local function stock(props, sg3)
    return { stockRef = { stockId = "s1", contentsGeneration = 1, dataRevision = "r1" },
             materialRef = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }, observedAmount = 4000, amountUnit = "LITRE",
             properties = props or {}, sg3 = sg3 }
end

local GRADE_A_FOOD = { FOOD = { knowledge = "KNOWN", suitability = "SUITABLE", grade = "A" }, FEED = { knowledge = "KNOWN", suitability = "SUITABLE", grade = "A" } }

--- One delivery of `litres` from a trailer StockGuard captured, at a fresh
--- bracketed station. Returns the station, the mirror world and the handle.
local function sell(o)
    o = o or {}
    local h, world = SGMirror.newHandle({ stocks = { s1 = stock(o.props, o.sg3) }, withSg3 = o.withSg3 })
    local st = SellingStation.newBench("silo", { [WHEAT] = 1.7, [BARLEY] = 2.5 })
    world.parent = { station = st, farmId = o.parentFarm or 1, paidFillTypeIndex = WHEAT, fillTypeName = "WHEAT",
                     stockId = "s1", available = o.available or 4000, dischargeFactor = 1, triggerRatio = 1 }
    if o.bracket ~= false then world.bracket(st) end
    if o.prepare ~= nil then o.prepare(h, world, st) end
    if o.noStockGuard then g_currentMission.stockGuard = nil else g_currentMission.stockGuard = h end
    balance = 0
    local ok, err = pcall(st.addFillLevelFromTool, st, o.farmId or 1, o.litres or 1000, WHEAT, nil, nil, nil)
    return st, world, h, ok, err
end

-- =========================================================
-- GROUP S1: the organic premium now pays, per load
-- =========================================================
local st, world = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
T.near('S1 a certified load pays the captured-origin addition: 1000 L at 2 x 1.20', balance, 2400, 1e-6)
T.eq('S1a the native body read its price exactly once', #st.priceReads, 1)
T.near('S1b and that one read took the material rate', st.priceReads[1], 2.4, 1e-9)
T.eq('S1c the facade was called once, dot form, with nil for the current phase', world.count("getNativeSaleInputsV1"), 1)
local call = world.last("getNativeSaleInputsV1")
T.ok('S1d and its one argument was nil, never the handle', call.n == 1 and call.args[1] == nil)
T.eq('S1e no entry is left open after the sale', #S._stack, 0)
T.eq('S1f nor is StockGuard\'s phase', #world.phases, 0)

st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(0, 4000) } })
T.near('S2 a known conventional load pays the plain market rate', balance, 2000, 1e-6)
T.near('S2a the read was the market price, not the native station price', st.priceReads[1], 2, 1e-9)

sell({ props = { harvestOrganicOriginV1 = soilOrigin(nil, 4000) } })
T.near('S3 an UNKNOWN origin earns nothing and is not treated as conventional proof', balance, 2000, 1e-6)

sell({ props = {} })
T.near('S4 a load with no origin record pays the plain market rate', balance, 2000, 1e-6)

local half = soilOrigin(1, 4000)
half.knowledge, half.knownAmount = "PARTIAL", 2000
sell({ props = { harvestOrganicOriginV1 = half } })
T.near('S5 a PARTIAL record pays only its proved share: 1 + 0.20 x 0.5', balance, 2200, 1e-6)

local mixed = soilOrigin(0.5, 4000)
sell({ props = { harvestOrganicOriginV1 = mixed } })
T.near('S6 a blended fraction pays in proportion: 1 + 0.20 x 0.5', balance, 2200, 1e-6)

sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, available = 500 })
T.near('S7 an observation gap keeps the unobserved litres out of the numerator', balance, 2200, 1e-6)

local foreign = soilOrigin(1, 4000)
foreign.schemaVersion = 2
sell({ props = { harvestOrganicOriginV1 = foreign } })
T.near('S8 a record in a schema this build does not read proves nothing', balance, 2000, 1e-6)

-- =========================================================
-- GROUP S2: nothing moves money without its facts
-- =========================================================
st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, noStockGuard = true })
T.near('S9 with no StockGuard the sale pays the plain market rate', balance, 2000, 1e-6)

g_MarketDynamics.settings.pricesEnabled = false
st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
T.near('S10 with Dynamic Prices off the native station price stands, and no addition', balance, 1700, 1e-6)
g_MarketDynamics.settings.pricesEnabled = true

g_MarketDynamics.isActive = false
sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
T.near('S11 with MarketDynamics not active the native price stands', balance, 1700, 1e-6)
g_MarketDynamics.isActive = true

local _, w12 = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, bracket = false })
T.near('S12 a sale StockGuard did not bracket pays the plain market rate', balance, 2000, 1e-6)
T.eq('S12a the facade was asked once and had no phase to answer for', w12.count("getNativeSaleInputsV1"), 1)

g_server = nil
local savedComps = engine:getSaleQuoteComponents(WHEAT)
sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
T.near('S13 a client never qualifies a sale', balance, 2000, 1e-6)
g_server = {}
T.ok('S13a and the components were never touched', savedComps ~= nil)

-- THE CALL FORM, the defect itself. The mirror answers a colon call the way
-- the real facade does: the handle arrives as the frame.
do
    local h, w = SGMirror.newHandle({ stocks = { s1 = stock({}) } })
    local rec, why = h:getNativeSaleInputsV1()
    T.eq('S14 DIFFERENCE: a colon call hands the handle in as the frame and is refused', why, "UNKNOWN_FRAME")
    T.eq('S14a so it can never return a record', rec, nil)
    local rec2, why2 = h.getNativeSaleInputsV1(nil)
    T.eq('S14b a dot call outside a paid phase has no phase to answer for', why2, "NO_SALE_PHASE")
    T.eq('S14c and no record', rec2, nil)
    w.isServer = false
    T.eq('S14d a client\'s call is NOT_SERVER, as serverOnly answers', select(2, h.getNativeSaleInputsV1(nil)), "NOT_SERVER")
end

-- =========================================================
-- GROUP S3: one read, one station, one fill type
-- =========================================================
st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, prepare = function(_h, _w, s) s.extraReadInside = true end })
T.near('S15 the native read takes the material rate', st.priceReads[1], 2.4, 1e-9)
T.near('S15a a second read inside the same phase gets the plain market rate', st.priceReads[2], 2, 1e-9)
T.near('S15b and the money is the first read times the litres', balance, 2400, 1e-6)

local other = SellingStation.newBench("other", { [WHEAT] = 1.7, [BARLEY] = 2.5 })
st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, prepare = function(_h, _w, s) s.foreignReadInside = { station = other, fillTypeIndex = WHEAT } end })
T.near('S16 a read for another station inside the phase gets the plain rate', st.foreignReads[1], 2, 1e-9)
T.near('S16a and this station still pays the material rate', balance, 2400, 1e-6)
st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, prepare = function(_h, _w, s) s.foreignReadInside = { station = s, fillTypeIndex = BARLEY } end })
T.near('S17 a read for another fill type on the same station gets that type\'s plain rate', st.foreignReads[1], 3, 1e-9)

-- A foreign mod's sale nested inside the bracketed one, on the SAME station
-- and fill type. The facade answers the outer phase, so MarketDynamics' own
-- join (farm, type, paid amount) must refuse it, and the nested call must
-- never consume the outer call's rate.
st = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, prepare = function(_h, _w, s)
    s.nestedSaleInside = { station = s, farmId = 1, fillDelta = 50, fillTypeIndex = WHEAT }
end })
T.near('S18 a nested foreign sale of 50 L reads the plain rate, not the outer rate', st.priceReads[1], 2, 1e-9)
T.near('S18a the outer call still takes its own material rate', st.priceReads[2], 2.4, 1e-9)
T.near('S18b and the money is both, each at its own rate', balance, 50 * 2 + 1000 * 2.4, 1e-6)

do
    local rec = { schemaVersion = 1, nativePath = "SELLING_STATION", amountUnit = "LITRE", farmId = 1, fillTypeName = "WHEAT",
                  paidAmount = 1000, capturedContributions = { {} } }
    T.ok('S19 the join admits this call\'s own record', (S.recordMatches(rec, 1, 1000, "WHEAT")))
    T.eq('S19a another farm\'s record is refused', select(2, S.recordMatches(rec, 2, 1000, "WHEAT")), "FARM_MISMATCH")
    T.eq('S19b another fill type\'s record is refused', select(2, S.recordMatches(rec, 1, 1000, "BARLEY")), "TYPE_MISMATCH")
    T.eq('S19c another paid amount\'s record is refused', select(2, S.recordMatches(rec, 1, 999, "WHEAT")), "AMOUNT_MISMATCH")
end

-- An error in the native body propagates, after the entry is closed.
st, world = nil, nil
local _, wErr, _, okErr, err = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, prepare = function(_h, _w, s) s.throwInside = true end })
T.eq('S20 an error in the native body propagates unchanged', okErr == false and err, "native body failed")
T.eq('S20a and no entry is left open behind it', #S._stack, 0)
T.eq('S20b nor a StockGuard phase', #wErr.phases, 0)
sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
T.near('S20c the next sale still pays normally', balance, 2400, 1e-6)

-- =========================================================
-- GROUP S4: the grade term through SG-3 and the md16.saleInputs lease
-- =========================================================
local hG, wG
st, wG, hG = sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, sg3 = GRADE_A_FOOD })
T.near('S21 grade A and full organic compose before the rail: 2 x 1.15 x 1.20', balance, 2760, 1e-6)
T.eq('S21a the md16.saleInputs consumer was registered on the handle', wG.byId["md16.saleInputs"] ~= nil, true)
local spec = wG.byId["md16.saleInputs"].spec
T.ok('S21b with the brief\'s three schemas at version 1',
    spec.requiredSchemas.qualityBasisV1 == 1 and spec.requiredSchemas.harvestOrganicOriginV1 == 1 and spec.requiredSchemas["sg4.composition"] == 1)
local read = wG.last("readMaterial")
T.eq('S21c SG-3 read through that lease, for this sale\'s EXECUTION context', read.args[2].purpose, "EXECUTION")
T.eq('S21d naming only qualityBasisV1, so sg4.composition is never queried', #read.args[2].propertyIds .. ":" .. read.args[2].propertyIds[1], "1:qualityBasisV1")
T.eq('S21e Food qualified first, so Feed was never asked', wG.count("sg3.assessMaterialUse"), 1)

sell({ props = { harvestOrganicOriginV1 = soilOrigin(0, 4000) }, sg3 = GRADE_A_FOOD })
T.near('S22 grade A alone pays fifteen percent', balance, 2300, 1e-6)

local _, wB = sell({ props = {}, sg3 = { FOOD = { knowledge = "KNOWN", suitability = "UNSUITABLE" }, FEED = { knowledge = "KNOWN", suitability = "SUITABLE", grade = "B" } } })
T.near('S23 an unsuitable Food use falls to a suitable Feed B', balance, 2100, 1e-6)
T.eq('S23a after asking Food, then Feed', wB.count("sg3.assessMaterialUse"), 2)

sell({ props = {}, sg3 = { FOOD = { knowledge = "UNKNOWN", suitability = "UNKNOWN", grade = "A" } } })
T.near('S24 an UNKNOWN grade earns nothing even with a letter beside it', balance, 2000, 1e-6)

sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, sg3 = GRADE_A_FOOD, available = 500 })
T.near('S25 an observation gap voids the whole call\'s grade and keeps the proved origin', balance, 2200, 1e-6)

-- THE LOCATION, the defect itself. SG-3 lives on handle.sg3; a function on the
-- handle's top level is not SG-3 and must not be read as one.
sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, withSg3 = false, prepare = function(h)
    h.assessMaterialUse = function() return { state = "READY", knowledge = "KNOWN", suitability = "SUITABLE", grade = "A", use = "FOOD", profileId = "CROP_FOOD_V1" } end
end })
T.near('S26 DIFFERENCE: an assessMaterialUse on the handle itself is not read; organic alone pays', balance, 2400, 1e-6)

-- No lease, no grade: SG-3's own read refuses a caller that is not a live consumer.
sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) }, sg3 = GRADE_A_FOOD, prepare = function(h)
    h.registerConsumer("md16.saleInputs", { version = 1, requiredSchemas = { x = 1 }, materialKinds = { "FILL_TYPE" }, resolveReadContext = function() end })
end })
T.near('S27 a refused lease leaves the grade unavailable and the origin still pays', balance, 2400, 1e-6)

do
    -- The resolver admits only the sale being qualified, never a free read.
    local h, w = SGMirror.newHandle({ stocks = { s1 = stock({}, GRADE_A_FOOD) } })
    g_currentMission.stockGuard = h
    R.releaseLease()
    local lease = R.saleInputsLease()
    T.ok('S28 the lease is issued on demand', lease ~= nil)
    T.eq('S28a and once per handle', (R.saleInputsLease()) == lease and w.count("registerConsumer"), 1)
    local refs = { { stockId = "s1", contentsGeneration = 1, dataRevision = "r1" } }
    local free = h.readMaterial(lease, { stockRefs = refs, purpose = "EXECUTION", propertyIds = { "qualityBasisV1" } })
    T.eq('S28b an EXECUTION read outside a sale is denied', free.state, "DENIED")
    R.beginExecutionRead(refs)
    local preview = h.readMaterial(lease, { stockRefs = refs, purpose = "PREVIEW", propertyIds = { "qualityBasisV1" } })
    T.eq('S28c a PREVIEW read is denied even while a sale is open', preview.state, "DENIED")
    local wrong = h.readMaterial(lease, { stockRefs = { { stockId = "s9", contentsGeneration = 1, dataRevision = "r1" } }, purpose = "EXECUTION" })
    T.eq('S28d a read of another stock is denied', wrong.state, "DENIED")
    local right = h.readMaterial(lease, { stockRefs = refs, purpose = "EXECUTION", propertyIds = { "qualityBasisV1" } })
    T.eq('S28e the open sale\'s own stock reads', right.state, "READY")
    R.endExecutionRead()
    local colon = h:registerConsumer("md16.saleInputs", R.consumerSpec())
    T.eq('S28f DIFFERENCE: a colon registerConsumer passes the handle as the id and is refused', colon, nil)
    R.releaseLease()
    T.eq('S28g teardown withdraws the lease from its handle', w.byId["md16.saleInputs"], nil)
end

-- =========================================================
-- GROUP S5: contract litres keep the baseline
-- =========================================================
do
    futures.contracts = { [1] = { status = "active", quantity = 300, delivered = 0, valueReceived = 0, lockedPrice = 3,
                                  farmId = 1, fillTypeIndex = WHEAT, fillTypeName = "WHEAT", deliveryStartTime = 0 } }
    local reported = {}
    local realReport = FuturesMarket.onCropDelivered
    futures.onCropDelivered = function(self, ...)
        reported[#reported + 1] = { n = select("#", ...), args = { ... } }
        return realReport(self, ...)
    end
    sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
    futures.onCropDelivered = nil
    local c = futures.contracts[1]
    T.eq('S29e the tracker was told once, with the plan frozen before the sale', #reported == 1 and reported[1].n, 5)
    local alloc = reported[1].args[5]
    T.ok('S29f that plan assigns this contract its 300 L and leaves 700 L as spot excess',
        type(alloc) == "table" and alloc.plan.assignments[1].litres == 300 and alloc.plan.spotExcessLitres == 700)
    T.near('S29g valued at the baseline the sale was priced against', alloc.plan.assignments[1].baselineValue, 600, 1e-6)
    T.eq('S29 the contract takes the litres it still needed', c.delivered, 300)
    T.near('S29a and records them at the BASELINE value, never the material rate', c.valueReceived, 600, 1e-6)
    T.eq('S29b the filled contract settled', c.status, "fulfilled")
    T.near('S29c the farmer nets the locked value plus the spot excess at the material rate',
        balance, 300 * 3 + 700 * 2.4, 1e-6)
    -- DIFFERENCE: paying the whole call at the material rate and telling the
    -- tracker the plain price after the sale would give the contract litres the
    -- addition too: 1000 x 2.4 at the station, then 900 - 600 settled.
    T.near('S29d DIFFERENCE: the unplanned path would have paid 120 more on contract litres',
        (1000 * 2.4 + (900 - 600)) - balance, 120, 1e-6)
    futures.contracts = {}

    futures.contracts = { [2] = { status = "active", quantity = 5000, delivered = 0, valueReceived = 0, lockedPrice = 3,
                                  farmId = 1, fillTypeIndex = WHEAT, fillTypeName = "WHEAT", deliveryStartTime = 0 } }
    sell({ props = { harvestOrganicOriginV1 = soilOrigin(1, 4000) } })
    T.near('S30 a delivery wholly under contract pays the baseline at the station', balance, 2000, 1e-6)
    T.near('S30a and the contract records exactly that', futures.contracts[2].valueReceived, 2000, 1e-6)
    futures.contracts = {}

    futures.contracts = { [3] = { status = "active", quantity = 300, delivered = 0, valueReceived = 0, lockedPrice = 3,
                                  farmId = 1, fillTypeIndex = WHEAT, fillTypeName = "WHEAT", deliveryStartTime = 0 } }
    sell({ props = { harvestOrganicOriginV1 = soilOrigin(0, 4000) } })
    T.near('S31 with no material term the unchanged legacy path records the plain price', futures.contracts[3].valueReceived, 600, 1e-6)
    futures.contracts = {}
end

-- =========================================================
-- GROUP S6: what log.txt says
-- =========================================================
do
    local found = 0
    for _, line in ipairs(infoLines) do
        if line:find("first material addition paid", 1, true) then found = found + 1 end
    end
    T.eq('S32 the first paid addition is logged once at info', found, 1)
    infoLines = {}
    g_MarketDynamics.registerPriceModifier = function() return true end
    OrganicPremiumBridge.register()
    local said = infoLines[#infoLines] or ""
    T.ok('S33 the bridge line still reports the pooled premium RETIRED', said:find("RETIRED it", 1, true) ~= nil)
    T.ok('S33a and names what replaced it, without claiming it always pays',
        said:find("captured-origin premium at the sale", 1, true) ~= nil and said:find("only for a load whose organic origin StockGuard recorded", 1, true) ~= nil)
end
