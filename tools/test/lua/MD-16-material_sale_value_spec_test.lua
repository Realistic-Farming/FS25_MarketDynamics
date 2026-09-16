-- MD-16: material sale value. The certified reference bar (Office Tyson/
-- StockGuard-First-Family-2026-09-15/reference-tests/MD-16-material_sale_value_spec_test.lua)
-- ported against the BUILT modules rather than against local copies of the
-- arithmetic, plus production cases for the parts of this subset the reference
-- bar does not reach.
--!load: src/OrganicPremiumBridge.lua, src/MarketEngine.lua, src/FuturesMarket.lua, src/md16/Md16Values.lua, src/md16/Md16Material.lua, src/md16/Md16SaleComponents.lua, src/md16/Md16FuturesPlan.lua, src/md16/Md16Resolvers.lua, src/md16/MarketDynamicsSalePreviewEvent.lua
--
-- Engine-neutral. Nothing here proves native station execution, GUI, locale,
-- multiplayer or save behaviour; those are implementation and release
-- observations and this is a DRAFT that must not merge.

local M = Md16Material
local C = Md16SaleComponents
local P = Md16FuturesPlan
local R = Md16Resolvers
local E = MarketDynamicsSalePreviewEvent

-- =========================================================
-- GROUP A: the reference bar, against the built module
-- =========================================================
-- Every one of these ran in the design bar against a local copy of the
-- arithmetic. Here they drive Md16Material, so the shipped constants and the
-- certified numbers are the same numbers.
local function grade(letter, complete) return M.gradeFactor(letter, complete) end
local function organic(eligible, basis) return M.organicFactor(eligible, basis) end
local function rate(base, consumers, gf, of) return M.partRate(base, consumers, gf, of) end

T.near('A1 grade A starts at fifteen percent', grade('A', true), 1.15, 1e-9)
T.near('A2 grade B starts at five percent', grade('B', true), 1.05, 1e-9)
T.eq('A3 C has no grade addition', grade('C', true), 1)
T.eq('A4 missing grade has no addition', grade(nil, false), 1)
T.eq('A5 partial grade cannot borrow known letters', grade('A', false), 1)
T.near('A6 half captured eligible origin share adds ten percent', organic(50, 100), 1.10, 1e-9)
T.eq('A7 known conventional zero is neutral', organic(0, 100), 1)
T.near('A8 maximum independent material terms compose', rate(100, 1, grade('A', true), organic(100, 100)), 138, 1e-9)
T.near('A9 grade survives independently missing organic proof', rate(100, 1, grade('A', true), organic(0, 100)), 115, 1e-9)
T.near('A10 origin proof survives independently missing grade', rate(100, 1, grade('A', false), organic(50, 100)), 110, 1e-9)
T.eq('A11 upper consumer rail applies after material composition', rate(100, 2.9, 1.15, organic(100, 100)), 300)
T.eq('A12 lower consumer rail applies after material composition', rate(100, .1, 1.15, 1.2), 50)
local wrongAfterClamp = rate(100, 2.9, 1, 1) * 1.15 * 1.2
T.ok('A13 DIFFERENCE: post-clamp multiplication violates the upper rail', wrongAfterClamp > 300)
T.near('A14 native event base is retained separately', rate(150, 1, 1.15, 1), 172.5, 1e-9)
T.eq('A15 zero paid basis is neutral rather than a division', organic(0, 0), 1)
T.eq('A16 a negative basis is neutral rather than a sign flip', organic(10, -5), 1)
T.eq('A17 a non-finite factor makes the rate unavailable, not guessed', rate(100, 0 / 0, 1, 1), nil)
T.near('A18 the baseline rate carries no material term', M.baselineRate(100, 2), 200, 1e-9)

-- =========================================================
-- GROUP B: the ordered reduction
-- =========================================================
local many = {}
for i = 1, 256 do
    many[i] = { amount = 1, grade = ({ 'A', 'B', 'C', nil })[(i - 1) % 4 + 1], originKnown = true, originShare = (i % 2) }
end
local a = M.reduce(many)
T.eq('B1 256 source witnesses reconcile to the paid basis', a.paidBasisAmount, 256)
T.ok('B2 the grade contract coalesces to at most four price buckets', #a.rows <= 4)
T.eq('B3 sale detail never exposes one raw row per witness', #a.rows < 256, true)
T.near('B4 complete origin numerator yields one whole-call organic factor', a.organicFactor, 1.10, 1e-9)
T.near('B5 preview and execution share the same aggregate factor',
    M.effectiveFactor(a, 100, 2.8), M.effectiveFactor(M.reduce(many), 100, 2.8), 1e-9)

-- Every litre is still accounted for after the coalescing.
local summed = 0
for _, row in ipairs(a.rows) do summed = summed + row.paidBasisAmount end
T.eq('B6 the coalesced rows sum exactly to the paid basis', summed, a.paidBasisAmount)

local partial = { { amount = 50, grade = 'A', originKnown = true, originShare = 1 }, { amount = 50, grade = 'B', originKnown = false } }
local pa = M.reduce(partial)
T.near('B7 partial origin coverage rewards only the proved eligible share', pa.organicFactor, 1.10, 1e-9)
T.near('B8 known grade remains when organic coverage is partial', pa.gradeFactor, 1.10, 1e-9)
T.eq('B9 coalesced rows still reconcile every paid litre', pa.rows[1].paidBasisAmount + pa.rows[2].paidBasisAmount, pa.paidBasisAmount)
T.eq('B10 partial origin state remains visible without dropping quantity', pa.originComplete, false)

local incompleteGrade = M.reduce({ { amount = 99, grade = 'A', originKnown = true, originShare = 1 }, { amount = 1, originKnown = false } })
T.eq('B11 whole-call incomplete grade keeps the neutral grade rule', incompleteGrade.gradeFactor, 1)
T.eq('B12 unknown grade is shown as UNAVAILABLE rather than C', incompleteGrade.rows[1].bucket, 'GRADE_UNAVAILABLE')
T.eq('B13 whole-call unavailable grade still accounts for every litre', incompleteGrade.rows[1].paidBasisAmount, 100)
T.near('B14 grade failure does not void independently proved organic share', incompleteGrade.organicFactor, 1.198, 1e-9)
T.eq('B15 zero paid basis has no aggregate factor at all, rather than a neutral 1',
    M.effectiveFactor(M.reduce({}), 100, 2.8), nil)

-- DIFFERENCE: the per-part grade build a reasonable person writes without the
-- whole-call rule. It lets a known letter earn its addition while another
-- required positive part is unknown, which is the rule the brief states twice.
local mixedKnown = { { amount = 99, grade = 'A', originKnown = false }, { amount = 1, originKnown = false } }
local perPartFactor = (99 * 1.15 + 1 * 1) / 100
T.ok('B16 DIFFERENCE: a per-part grade build pays the known letters', perPartFactor > 1)
T.eq('B17 DIFFERENCE: the whole-call rule pays nothing', M.reduce(mixedKnown).gradeFactor, 1)
T.eq('B18 and every litre lands in the grade-unavailable bucket, never C', M.reduce(mixedKnown).rows[1].bucket, 'GRADE_UNAVAILABLE')
T.eq('B19 C is only ever reached by an actual C grade', M.reduce({ { amount = 5, grade = 'C', originKnown = true, originShare = 0 } }).rows[1].bucket, 'C')

-- A zero-amount unsupported part cannot spoil a complete call.
T.eq('B20 a zero-amount part does not break whole-call completeness',
    M.reduce({ { amount = 10, grade = 'A', originKnown = true, originShare = 1 }, { amount = 0 } }).gradeComplete, true)
-- An out-of-range origin share is clamped rather than trusted.
T.near('B21 an origin share above one is clamped, not paid', M.reduce({ { amount = 10, grade = 'A', originKnown = true, originShare = 9 } }).organicFactor, 1.20, 1e-9)

T.eq('B22 bucket order is A, B, C, then grade-unavailable',
    table.concat({ M.BUCKET_ORDER[1], M.BUCKET_ORDER[2], M.BUCKET_ORDER[3], M.BUCKET_ORDER[4] }, ","),
    "A,B,C,GRADE_UNAVAILABLE")

-- =========================================================
-- GROUP C: sale components from the REAL engine
-- =========================================================
g_server = {}
C.reset()
local calls = 0
local organicCalls = 0
g_MarketDynamics = { priceModifiers = {
    probe = function() calls = calls + 1 return 10 end,
} }
local engine = setmetatable({ prices = { [1] = { base = 100, volatilityFactor = 1, modifiers = { { factor = 1.5 } }, current = 100 } } }, { __index = MarketEngine })
engine:_recalculate(1)
T.eq('C1 the real current recalculation invokes each consumer exactly once', calls, 1)
T.eq('C2 the real current source still bounds consumers after the event base', engine.prices[1].current, 450)

local comps = engine:getSaleQuoteComponents(1)
T.ok('C3 the components are captured from that same pass', comps ~= nil)
T.near('C4 baseThroughEvents is base times volatility times the event factors', comps.baseThroughEvents, 150, 1e-9)
T.eq('C5 otherConsumerProduct is kept UNCLAMPED so the rail can be applied later', comps.otherConsumerProduct, 10)
T.near('C6 baselineRate applies the rail with no material term', comps.baselineRate, 450, 1e-9)
T.eq('C7 the components carry their own schema version', comps.schemaVersion, 1)
T.eq('C8 and a READY state', comps.state, "READY")

-- DIFFERENCE: a builder who read the finished quote could not separate the rail
-- from what it clamped, which is why the components are captured and not derived.
T.ok('C9 DIFFERENCE: the finished quote cannot be divided back into its components',
    engine.prices[1].current / comps.baseThroughEvents ~= comps.otherConsumerProduct)

-- THE RETIREMENT. OrganicPremium is excluded at the composition point.
-- The probe returns 2 here, not 10, so the whole test sits INSIDE the 0.5-3.0
-- rail. At a product of 10 the rail clamps to 3 with or without the premium, so
-- a retirement test run there would pass against both builds and discriminate
-- nothing at all.
C.reset()
calls = 0
g_MarketDynamics.priceModifiers.probe = function() calls = calls + 1 return 2 end
g_MarketDynamics.priceModifiers[C.RETIRED_MODIFIER] = function() organicCalls = organicCalls + 1 return 1.20 end
local engine2 = setmetatable({ prices = { [1] = { base = 100, volatilityFactor = 1, modifiers = {}, current = 100 } } }, { __index = MarketEngine })
engine2:_recalculate(1)
T.eq('C10 the retired pooled organic premium is never invoked', organicCalls, 0)
T.eq('C11 and it contributes nothing to the live quote', engine2.prices[1].current, 200)
T.eq('C12 the other consumer still counts', calls, 1)
local comps2 = engine2:getSaleQuoteComponents(1)
T.eq('C13 nor to the captured components', comps2.otherConsumerProduct, 2)
-- DIFFERENCE, and it is visible because the rail is not reached: an unretired
-- premium composes to 2.4 and pays 240 instead of 200.
T.near('C14 DIFFERENCE: an unretired premium would have paid more', 100 * math.max(.5, math.min(3, 2 * 1.20)), 240, 1e-9)
T.ok('C14b and the built quote does not', engine2.prices[1].current < 240)

-- The revision advances with an actual component change, never with the clock.
local first = engine2:getSaleQuoteComponents(1).marketRevision
engine2:_recalculate(1)
T.eq('C15 a recalculation that changed nothing keeps the market revision', engine2:getSaleQuoteComponents(1).marketRevision, first)
engine2.prices[1].base = 200
engine2:_recalculate(1)
T.ok('C16 an actual component change advances it', engine2:getSaleQuoteComponents(1).marketRevision ~= first)
T.eq('C17 the revision is an opaque string, never a coerced numeric counter', type(first), "string")

-- An invalid component makes the snapshot unavailable, never a guessed number.
C.reset()
C.capture(9, "WHEAT", 0 / 0, 1)
T.eq('C18 a non-finite component is UNAVAILABLE, not a corrected guess', (C.get(9)), nil)
T.eq('C19 and the reason names the market rather than the material', select(2, C.get(9)), "NO_MARKET")
T.eq('C20 an unknown fill type is NO_MARKET', select(2, C.get(4242)), "NO_MARKET")
g_MarketDynamics.priceModifiers[C.RETIRED_MODIFIER] = nil

-- =========================================================
-- GROUP D: the futures plan
-- =========================================================
local frame = { callRef = "call:1", paidLitres = 100 }
local goodPlan = { version = 1, callRef = "call:1", spotExcessLitres = 90,
    assignments = { { contractId = 1, litres = 10, baselineValue = 20 } } }
T.ok('D1 a plan whose amounts reconcile to the paid quantity is admitted', P.validate(goodPlan, frame) ~= nil)
T.eq('D2 a plan for another call is refused', select(2, P.validate({ version = 1, callRef = "call:2", spotExcessLitres = 100, assignments = {} }, frame)), "CALL_REF")
T.eq('D3 a plan that accounts for the wrong quantity is refused', select(2, P.validate({ version = 1, callRef = "call:1", spotExcessLitres = 50, assignments = {} }, frame)), "AMOUNT_MISMATCH")
T.eq('D4 two assignments for one contract are refused', select(2, P.validate({ version = 1, callRef = "call:1", spotExcessLitres = 80,
    assignments = { { contractId = 1, litres = 10, baselineValue = 20 }, { contractId = 1, litres = 10, baselineValue = 20 } } }, frame)), "DUPLICATE_CONTRACT")
T.eq('D5 a wrong version is refused', select(2, P.validate({ version = 2, callRef = "call:1", spotExcessLitres = 100, assignments = {} }, frame)), "VERSION")

-- UNITS. baselineValue is the TOTAL for those litres; recordDelivery takes a rate.
T.near('D6 the assigned rate is the total baseline value over its litres', P.assignedRate({ litres = 10, baselineValue = 20 }), 2, 1e-9)
T.eq('D7 zero litres does not divide', P.assignedRate({ litres = 0, baselineValue = 20 }), nil)

-- The reference bar's allocation, driven through the built plan.
local spotRate = M.partRate(2, 1, 1.15, 1.2)
local effective, gross = P.effectiveRate(goodPlan, spotRate)
T.near('D8 one native weighted price accounts for both portions', effective, 2.684, 1e-9)
T.near('D9 native gross is one sale payment', gross, 268.4, 1e-9)
T.eq('D10 assigned plus spot equals the actual paid amount', 10 + goodPlan.spotExcessLitres, frame.paidLitres)

-- Drive the REAL FuturesMarket through the plan.
MDMLog = MDMLog or { info = function() end, debug = function() end, warn = function() end, error = function() end }
UPIntegration = UPIntegration or { onContractFulfilled = function() end }
MDMContractSyncEvent = MDMContractSyncEvent or { SYNC_UPDATE = 1, sendToClients = function() end }
MoneyType = MoneyType or {}; MoneyType.OTHER = MoneyType.OTHER or 0
g_localPlayer = nil
local balance = gross
g_currentMission = { isServer = true, isClient = false, addMoney = function(_self, money) balance = balance + money end }
local futures = setmetatable({ contracts = { [1] = { status = 'active', quantity = 10, delivered = 0, valueReceived = 0,
    lockedPrice = 3, farmId = 1, fillTypeName = 'WHEAT', fillTypeIndex = 1, deliveryStartTime = 0 } } }, { __index = FuturesMarket })
local applied = P.apply(futures, goodPlan)
T.eq('D11 every assignment reaches the existing tracker', applied, 1)
T.near('D12 the contract stores only its ASSIGNED baseline value', futures.contracts[1].valueReceived, 20, 1e-9)
T.near('D13 the locked portion plus the spot excess nets correctly', balance, 10 * 3 + 90 * spotRate, 1e-9)
local before = balance
futures:_fulfillContract(1)
T.eq('D14 a repeated fulfillment adds no money', balance, before)

-- DIFFERENCE: paying the blended rate into the tracker loses part of the bonus.
local wrongNet = gross + (10 * 3 - 10 * effective)
T.near('D15 DIFFERENCE: an averaged rate counterexample loses spot bonus', balance - wrongNet, 6.84, 1e-9)

-- Freezing a plan from the tracker's own contracts.
local futures2 = setmetatable({ contracts = {
    [2] = { status = 'active', quantity = 30, delivered = 0, farmId = 1, fillTypeIndex = 1, deliveryStartTime = 0 },
    [3] = { status = 'active', quantity = 30, delivered = 0, farmId = 2, fillTypeIndex = 1, deliveryStartTime = 0 },
    [4] = { status = 'fulfilled', quantity = 30, delivered = 30, farmId = 1, fillTypeIndex = 1, deliveryStartTime = 0 },
} }, { __index = FuturesMarket })
local frozen = P.freeze(futures2, { callRef = "c9", farmId = 1, fillTypeIndex = 1, paidLitres = 50, now = 10, baselineRate = 2 })
T.ok('D16 a plan freezes from the tracker current assignments', frozen ~= nil)
T.eq('D17 only this farm active matching contract is assigned', #frozen.assignments, 1)
T.eq('D18 and it takes what it still needs, not the whole delivery', frozen.assignments[1].litres, 30)
T.eq('D19 the remainder is spot excess', frozen.spotExcessLitres, 20)
T.near('D20 the assignment is valued at the BASELINE, never the material rate', frozen.assignments[1].baselineValue, 60, 1e-9)

-- The optional fifth argument leaves every existing caller unchanged.
local legacyCalls = 0
local futures3 = setmetatable({ contracts = {} }, { __index = FuturesMarket })
futures3.recordDelivery = function() legacyCalls = legacyCalls + 1 return false end
futures3:onCropDelivered(1, 1, 10, 2)
T.eq('D21 a caller with no plan still runs the unchanged legacy path', legacyCalls, 0)
local futures4 = setmetatable({ contracts = { [1] = { status = 'active', quantity = 10, delivered = 0, valueReceived = 0,
    lockedPrice = 3, farmId = 1, fillTypeIndex = 1, deliveryStartTime = 0 } } }, { __index = FuturesMarket })
local planCalls = 0
futures4.recordDelivery = function(_self, _id, _l, _p) planCalls = planCalls + 1 return false end
futures4:onCropDelivered(1, 1, 100, 2, { plan = goodPlan, frame = frame })
T.eq('D22 an admitted plan drives the tracker from its assignments', planCalls, 1)
local badPlanCalls = 0
futures4.recordDelivery = function() badPlanCalls = badPlanCalls + 1 return false end
futures4:onCropDelivered(1, 1, 100, 2, { plan = { version = 9 }, frame = frame })
T.ok('D23 an unadmitted plan falls back to the legacy path rather than refusing the delivery', badPlanCalls >= 0)

-- =========================================================
-- GROUP E: the five-argument sale wrapper
-- =========================================================
local function nativeFive(farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
    return { farmId, fillDelta, fillTypeIndex, toolType, extraAttributes }
end
local function correctedCall(superFunc, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
    return superFunc(farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
end
local forwarded = correctedCall(nativeFive, 4, 125, 7, "TRAILER", { priceScale = .9 })
T.eq('E1 the corrected wrapper preserves the toolType slot', forwarded[4], 'TRAILER')
T.near('E2 the corrected wrapper preserves the extraAttributes slot', forwarded[5].priceScale, .9, 1e-9)

-- The old six-slot shape, and the honest account of what it did and did not do.
local attributes = { priceScale = .9 }
local function oldSix(superFunc, farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)
    return superFunc(farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)
end
local shifted = oldSix(nativeFive, 4, 125, 7, 'TRAILER', attributes)
T.eq('E3 the old wrapper still forwarded the native tool position', shifted[4], 'TRAILER')
T.eq('E4 and the native attributes position', shifted[5], attributes)
local function oldNamedReads(farmId, fillDelta, fillTypeIndex, fillPositionData, toolType, extraAttributes)
    return toolType, extraAttributes
end
local wrongTool, missingAttributes = oldNamedReads(4, 125, 7, 'TRAILER', attributes)
T.eq('E5 DIFFERENCE: the old local named toolType actually held the attributes', wrongTool, attributes)
T.eq('E6 DIFFERENCE: and the old local named extraAttributes was always nil', missingAttributes, nil)

-- =========================================================
-- GROUP F: the vendored codec
-- =========================================================
T.eq('F1 the vendored codec writes the SAME wire format as StockGuard', Md16Values.FORMAT, "SG_VALUES")
T.eq('F2 at the same version', Md16Values.VERSION, "2")
T.eq('F3 and the same format token', Md16Values.FORMAT_TOKEN, "SG_VALUES_2")
local roundTrip = Md16Values.decode(Md16Values.encode({ a = 1, b = "two", c = { 3, 4 }, d = 1.5 }))
T.ok('F4 a record round-trips through the vendored codec', roundTrip ~= nil)
T.eq('F5 strings survive', roundTrip.b, "two")
T.eq('F6 nested arrays survive', roundTrip.c[2], 4)
T.near('F7 decimals preserve their value rather than coercing to integer money', roundTrip.d, 1.5, 1e-12)
T.eq('F8 a malformed token array decodes to nil rather than a partial record', (Md16Values.decode({ "NOT", "A", "RECORD" })), nil)

-- =========================================================
-- GROUP G: the private preview event
-- =========================================================
T.eq('G1 the kind codes are fixed', E.KIND_STOCKS .. "," .. E.KIND_DESTINATIONS .. "," .. E.KIND_PREVIEW .. "," .. E.KIND_LATEST, "1,2,3,4")

-- Request record shapes: only what the kind needs, and an extra trusted field
-- REFUSES rather than being ignored.
T.ok('G2 a STOCKS request may carry only a cursor', E.validateRequestRecord(E.KIND_STOCKS, { cursor = "c1" }) ~= nil)
T.ok('G3 a STOCKS request may be empty', E.validateRequestRecord(E.KIND_STOCKS, {}) ~= nil)
T.eq('G4 a trusted farm field on a request REFUSES', select(2, E.validateRequestRecord(E.KIND_STOCKS, { farmId = 1 })), "UNEXPECTED_FIELD:farmId")
T.eq('G5 a rate field REFUSES', select(2, E.validateRequestRecord(E.KIND_PREVIEW, { destinationId = "d", stockRef = {}, rate = 2 })), "UNEXPECTED_FIELD:rate")
T.eq('G6 a plan field REFUSES', select(2, E.validateRequestRecord(E.KIND_PREVIEW, { destinationId = "d", stockRef = {}, plan = {} })), "UNEXPECTED_FIELD:plan")
T.eq('G7 a PREVIEW request without its stockRef is refused', select(2, E.validateRequestRecord(E.KIND_PREVIEW, { destinationId = "d" })), "MISSING_FIELD:stockRef")
T.eq('G8 LATEST carries no stockRef and must not borrow one', select(2, E.validateRequestRecord(E.KIND_LATEST, { destinationId = "d", stockRef = {} })), "UNEXPECTED_FIELD:stockRef")
T.eq('G9 an unknown kind is refused before anything else', select(2, E.validateRequestRecord(99, {})), "KIND")

T.eq('G10 a request id must be a positive 31 bit integer', E.isPositiveInt31(0), false)
T.eq('G11 and bounded', E.isPositiveInt31(2147483648), false)
T.ok('G12 an ordinary id is accepted', E.isPositiveInt31(7))
T.eq('G13 a zero request id refuses construction', select(2, E.newRequest(E.KIND_STOCKS, 0, {})), "REQUEST_ID")

-- Budgets refuse rather than truncate.
local tooMany = {}
for i = 1, E.MAX_TOKENS + 1 do tooMany[i] = "t" end
T.eq('G14 an oversized token count refuses', select(2, E.checkTokens(tooMany)), "TOKEN_COUNT")
T.eq('G15 an oversized single token refuses', select(2, E.checkTokens({ string.rep("x", E.MAX_TOKEN_BYTES + 1) })), "TOKEN_SIZE")
local bigTokens = {}
for i = 1, 16 do bigTokens[i] = string.rep("y", 4096) end
T.eq('G16 an oversized combined payload refuses', select(2, E.checkTokens(bigTokens)), "TOTAL_SIZE")

-- The wire order, exactly. A reply travelling to a client.
local function mockConnection(isServer) return { getIsServer = function() return isServer end, sendEvent = function() end } end
local reply = E.newReply(E.KIND_PREVIEW, 11, { state = "UNAVAILABLE" })
T.ok('G17 a reply is constructible', reply ~= nil)
local stream = _sfMockStream()
reply:writeStream(stream, mockConnection(false))
T.eq('G18 field 1 is isReply as a Bool', stream.q[1].t .. "=" .. tostring(stream.q[1].v), "bool=true")
T.eq('G19 field 2 is the schema version as a UInt8', stream.q[2].t .. "=" .. tostring(stream.q[2].v), "u8=1")
T.eq('G20 field 3 is the kind as a UInt8', stream.q[3].t .. "=" .. tostring(stream.q[3].v), "u8=3")
T.eq('G21 field 4 is the request id as an Int32', stream.q[4].t .. "=" .. tostring(stream.q[4].v), "i32=11")
-- The token count is no longer a UInt32 against a 4096 bound, which left every
-- value from 4097 up expressible and mis-aligned the stream when one arrived.
-- It is a field sized to exactly the token budget, so out of range cannot travel.
T.eq('G22 field 5 is the token count in a field sized to the budget', stream.q[5].t, "uN")
T.eq('G22b and that field is TOKEN_COUNT_BITS wide', stream.q[5].bits, E.TOKEN_COUNT_BITS)
T.eq('G23 and the tokens follow as strings', stream.q[6].t, "str")
T.eq('G24 the token count matches the tokens written', stream.q[5].v, #stream.q - 5)

-- DIRECTION. A reply may not be written to a target that is the server.
local wrongWay = _sfMockStream()
reply:writeStream(wrongWay, mockConnection(true))
T.eq('G25 a reply addressed to the server carries no payload', wrongWay.q[5].v, 0)
T.eq('G26 and its kind byte is zeroed rather than misleading', wrongWay.q[3].v, 0)

-- A request read from a source that claims to be the server never runs.
local ran = 0
E.onRequest = function() ran = ran + 1 end
local request = E.newRequest(E.KIND_STOCKS, 5, {})
local reqStream = _sfMockStream()
request:writeStream(reqStream, mockConnection(true))
g_server = {}
local received = E.emptyNew()
received.readStream(received, reqStream, mockConnection(true))
T.eq('G27 a request whose source claims to be the server is refused before apply', ran, 0)

local reqStream2 = _sfMockStream()
local request2 = E.newRequest(E.KIND_STOCKS, 6, { cursor = "c1" })
request2:writeStream(reqStream2, mockConnection(true))
local received2 = E.emptyNew()
received2.readStream(received2, reqStream2, mockConnection(false))
T.eq('G28 a request from a real client on the server runs', ran, 1)

-- THE ROUND TRIP ITSELF, which nothing here was asserting. G22b only inspects the
-- declared WRITE width, so the read side was unguarded: reading the token count at
-- a different width than it was written left the whole bar green. The mock stream
-- already counts a tag or width mismatch and an underflow, so this is the same one
-- line RSF-F203 and RSF-F204 both carry, and it is what makes a read-side width
-- change fail. A desync is exactly "the two sides disagreed about the shape",
-- which is what these two counters mean.
T.eq('G28b the request round trip has no type or width mismatch', reqStream2.typeErrors, 0)
T.eq('G28c and drained the stream exactly, with no underflow', reqStream2.underflows, 0)
T.eq('G28d the reply round trip is clean too', stream.typeErrors, 0)
E.onRequest = nil

-- =========================================================
-- GROUP H: resolvers against absent providers
-- =========================================================
-- ABSENT IS THE NORMAL PATH. Every provider MD-16 reads is unbuilt today.
g_currentMission = { isServer = true }
T.eq('H1 with no StockGuard there is no sale inputs facade', (R.saleInputsProvider()), nil)
T.eq('H2 and the reason is a missing source, not a favorable default', select(2, R.saleInputsProvider()), "SOURCE_UNAVAILABLE")
T.eq('H3 with no StockGuard there is no paged management provider', (R.managementProvider()), nil)
T.eq('H4 the grade evaluator is unsupported rather than neutral-favorable', select(2, R.assessMaterialUse(nil, nil, nil, nil)), "PROFILE_UNSUPPORTED")

local page = R._resolveSaleStocks({ farmId = 1 })
T.eq('H5 the stock page is UNAVAILABLE rather than an empty success', page.availability, "UNAVAILABLE")
T.ok('H6 and it carries no usable rows, cursor or revision', page.rows == nil and page.nextCursor == nil and page.viewRevision == nil)
T.eq('H7 an actorless call is DENIED, which is a different answer', R._resolveSaleStocks(nil).availability, "DENIED")

local preview = R._resolveSaleQuote("dest:1", { stockId = "s1" }, { farmId = 1 })
T.eq('H8 a preview without the source facade is not READY', preview.state ~= "READY", true)
T.eq('H9 an actorless preview is DENIED', R._resolveSaleQuote("dest:1", { stockId = "s1" }, nil).state, "DENIED")
T.eq('H10 a preview never invents a grade term when the evaluator is absent', preview.gradeState, "UNAVAILABLE")
T.eq('H11 nor an organic term', preview.organicState, "UNAVAILABLE")

-- A capability that does not advertise the paging version is refused rather
-- than probed: feeding a first page to an old whole-farm reader is worse.
g_currentMission.stockGuard = { getManagementView = function() return { state = "READY" } end,
    getCapabilities = function() return { managementPagingVersion = 0 } end }
T.eq('H12 an old paging capability is explicitly unavailable', (R.managementProvider()), nil)
g_currentMission.stockGuard = { getManagementView = function() return { state = "READY", pagingVersion = 1, rows = {},
    viewKey = "vk", dataRevision = "dr" } end, getCapabilities = function() return { managementPagingVersion = 1 } end }
T.ok('H13 a matching capability is accepted', R.managementProvider() ~= nil)
local readyPage = R._resolveSaleStocks({ farmId = 1 })
T.eq('H14 a READY page copies the view revision losslessly', readyPage.viewRevision.viewKey .. "/" .. readyPage.viewRevision.dataRevision, "vk/dr")
T.eq('H15 an empty READY page is READY, not unavailable', readyPage.availability, "READY")

-- The provider's contextual CARRIER row is omitted from the sale-stock list
-- WITHOUT dropping a STOCK identity.
g_currentMission.stockGuard.getManagementView = function()
    return { state = "READY", pagingVersion = 1, viewKey = "vk", dataRevision = "dr", rows = {
        { rowKind = "CARRIER", label = "context" },
        { rowKind = "STOCK", stockRef = { stockId = "s1" }, label = "Bin 1", materialRef = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }, amount = 10, amountUnit = "LITRE" },
        { rowKind = "STOCK", stockRef = { stockId = "s2" }, label = "Bin 2", materialRef = { kind = "FILL_TYPE", fillTypeName = "WHEAT" }, amount = 20, amountUnit = "LITRE" },
    } }
end
local mixedPage = R._resolveSaleStocks({ farmId = 1 })
T.eq('H16 the contextual carrier row is omitted from the sale-stock list', #mixedPage.rows, 2)
T.eq('H17 without dropping a STOCK identity', mixedPage.rows[1].stockRef.stockId .. "," .. mixedPage.rows[2].stockRef.stockId, "s1,s2")
T.eq('H18 rows carry only the public fields', tostring(mixedPage.rows[1].properties), "nil")

-- The destination role table, all four combinations.
local function station(store, skip)
    return { getStoreGoods = function() return store end, getSkipSell = function() return skip end }
end
T.eq('H19 store and skip is native storage with no unload money', (R.destinationRole(station(true, true), 1, 1)), "STORE_INPUT")
T.eq('H20 neither is an ordinary paid spot sale', (R.destinationRole(station(false, false), 1, 1)), "SALE_SPOT")
T.eq('H21 store without skip is a paid-capacity path only when its basis supports one', (R.destinationRole(station(true, false), 1, 1, true)), "SALE_SPOT")
T.eq('H22 and is unavailable otherwise, never invented storage', (R.destinationRole(station(true, false), 1, 1, false)), "UNSUPPORTED")
T.eq('H23 skip without store is unsupported, not invented storage', (R.destinationRole(station(false, true), 1, 1)), "UNSUPPORTED")
T.eq('H24 an unresolved policy is unsupported rather than assumed to store', (R.destinationRole({}, 1, 1)), "UNSUPPORTED")
T.eq('H25 NO_PAID_SALE is only reported for a PROVED non-paying delivery',
    select(3, R.destinationRole(station(true, true), 1, 1))[1], "NO_PAID_SALE")

-- The reason vocabulary is closed and carries exact English.
T.eq('H26 an unknown reason code is dropped rather than echoed as text', #R.reasons({ "NOT_A_REASON" }), 0)
T.eq('H27 the vocabulary carries exact player-facing English', R.reasonText("NO_PAID_SALE"), "This destination stores material and does not pay for this delivery.")
T.eq('H28 reasons are bounded at fifteen', #R.reasons({ "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET",
    "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET", "NO_MARKET",
    "NO_MARKET", "NO_MARKET" }), 15)

-- The latest outcome is per farm AND per destination. No outcome is not zero.
R.invalidate()
T.eq('H29 no observed outcome is UNAVAILABLE rather than a zero sale', R.getLatestSaleOutcome("farm:1", "dest:1").state, "UNAVAILABLE")
R.recordOutcome("farm:1", "dest:1", { schemaVersion = 1, destinationId = "dest:1", state = "OBSERVED", paidAmount = 100, amountUnit = "LITRE" })
T.eq('H30 an observed outcome is returned to its own farm', R.getLatestSaleOutcome("farm:1", "dest:1").state, "OBSERVED")
T.eq('H31 and is NEVER visible to another farm at the same public station', R.getLatestSaleOutcome("farm:2", "dest:1").state, "UNAVAILABLE")
R.invalidate()
T.eq('H32 invalidation clears it', R.getLatestSaleOutcome("farm:1", "dest:1").state, "UNAVAILABLE")

-- Preview DTO validation: the four buckets must reconcile to the paid basis.
local reduction = M.reduce({ { amount = 60, grade = 'A', originKnown = true, originShare = 1 }, { amount = 40, grade = 'B', originKnown = true, originShare = 0 } })
local parts = R.partsFromReduction(reduction, "FOOD", "PARTIAL")
T.eq('H33 the parts are the coalesced buckets, not a witness list', #parts, 2)
T.eq('H34 every bucket carries the whole-call selected use', parts[1].selectedUse .. "/" .. parts[2].selectedUse, "FOOD/FOOD")
local previewDto = { schemaVersion = 1, state = "READY", gradeState = "QUALIFIED", organicState = "PARTIAL",
    paidBasisAmount = 100, parts = parts }
T.ok('H35 a preview whose buckets sum to the paid basis validates', R.validatePreview(previewDto) ~= nil)
previewDto.paidBasisAmount = 101
T.eq('H36 one that does not is refused, because the buckets are a reduction', select(2, R.validatePreview(previewDto)), "PART_SUM")
T.eq('H37 more than four buckets is a shape error rather than something to trim',
    select(2, R.validatePreview({ schemaVersion = 1, state = "READY", gradeState = "QUALIFIED", organicState = "QUALIFIED",
        parts = { {}, {}, {}, {}, {} } })), "PARTS")
T.eq('H38 a non-READY stock page carrying rows is refused', select(2, R.validateStockPage({ schemaVersion = 1, availability = "UNAVAILABLE", rows = {} })), "NON_READY_PAYLOAD")


-- =========================================================
-- GROUP J: Bob's cold review of 6747d7a, the seven MAJORs
--
-- Each case below exists because a rule was load-bearing and had nothing under
-- it. Where a mutation is named, it was actually run against this bar.
-- =========================================================

-- J1: THE RETIREMENT IS PINNED TO THE REGISTRY, not to itself.
-- Bob set C.RETIRED_MODIFIER to "OrganicPremiumX" and the whole bar stayed green
-- at 609/0, because the retirement cases register their probe under the same
-- constant they assert against. Nothing bound either to the name the bridge
-- really registers. This is that binding.
T.eq('J1 the retirement names exactly the modifier the bridge registers',
    C.RETIRED_MODIFIER, OrganicPremiumBridge.MODIFIER_NAME)
T.eq('J1b the bridge name is the literal the composition point excludes',
    OrganicPremiumBridge.MODIFIER_NAME, "OrganicPremium")
T.eq('J1c the binding check passes when they agree', (C.verifyRetiredModifierBinding()), true)
do
    -- Drift the registry name and the check must catch it. This is the exact
    -- mutation that used to leave the bar fully green.
    local real = OrganicPremiumBridge.MODIFIER_NAME
    OrganicPremiumBridge.MODIFIER_NAME = "OrganicPremiumX"
    local okBind, why = C.verifyRetiredModifierBinding()
    T.eq('J1d a drifted registry name is caught', okBind, false)
    T.ok('J1e and the reason says the premium is still paying',
        type(why) == "string" and why:find("still paying") ~= nil)
    OrganicPremiumBridge.MODIFIER_NAME = real
    T.eq('J1f restored', (C.verifyRetiredModifierBinding()), true)
end

-- J2: THE AGGREGATE FACTOR AGREES WITH THE MONEY, ACROSS THE RAIL.
-- Bob's probe: base 100, consumer product 2.8, 50 L grade A and 50 L grade C.
-- Grade A rails (2.8 * 1.15 = 3.22 clamps to 3.0), grade C does not. The money
-- path pays 290. The old blended-then-unrailed factor implied 300.
do
    local reduced = M.reduce({
        { amount = 50, grade = 'A', originKnown = true, originShare = 0 },
        { amount = 50, grade = 'C', originKnown = true, originShare = 0 },
    })
    T.near('J2 the organic term is neutral so this case is purely about grade',
        reduced.organicFactor, 1, 1e-9)
    local factor, effective, baseline = M.effectiveFactor(reduced, 100, 2.8)
    T.near('J2b the effective rate is what the money path pays', effective, 290, 1e-9)
    T.near('J2c the baseline carries no material term', baseline, 280, 1e-9)
    T.near('J2d the factor is the ratio of the two', factor, 290 / 280, 1e-9)
    T.near('J2e and it reconstructs the rate exactly', factor * baseline, 290, 1e-9)

    -- DIFFERENCE, and it is the defect this replaces: blending the grade factors
    -- and only then railing gives 1.075, which implies 300 rather than 290.
    local blended = reduced.gradeFactor * reduced.organicFactor
    T.near('J2f DIFFERENCE: the old blended factor was 1.075', blended, 1.075, 1e-9)
    T.near('J2g DIFFERENCE: which implies 300, not the 290 actually paid',
        100 * M.rail(2.8 * blended), 300, 1e-9)
    T.ok('J2h so the old factor and the money genuinely disagreed',
        math.abs(100 * M.rail(2.8 * blended) - effective) > 9)

    -- The reducer must no longer publish a factor at all: it cannot rail without
    -- the consumer product, so a field there could only ever be the wrong one.
    T.eq('J2i the reducer publishes no aggregate factor of its own',
        reduced.effectiveFactor, nil)

    -- Below the rail the two agree, which is why this went unnoticed.
    local low = M.effectiveFactor(reduced, 100, 1.0)
    T.near('J2j well inside the rail the factor is just the blend', low, 1.075, 1e-9)
end

T.eq('J2k a non-finite consumer product yields no factor',
    M.effectiveFactor(M.reduce({ { amount = 10, grade = 'A' } }), 100, 0 / 0), nil)
T.eq('J2l a non-table reduction yields no factor', M.effectiveFactor(nil, 100, 2.8), nil)

-- J3: weightedRate's TWO refusal branches, which had zero coverage.
-- Bob mutated both and the bar stayed green: returning 0 instead of nil on zero
-- litres, and accepting a non-finite rate.
T.eq('J3 zero paid litres does not divide and returns no rate',
    M.weightedRate({ { litres = 0, rate = 100 } }), nil)
T.eq('J3b an empty allocation list returns no rate', M.weightedRate({}), nil)
T.eq('J3c a non-finite rate refuses the whole call',
    M.weightedRate({ { litres = 10, rate = 100 }, { litres = 10, rate = 0 / 0 } }), nil)
T.eq('J3d a negative litre amount refuses',
    M.weightedRate({ { litres = -1, rate = 100 } }), nil)
T.eq('J3e a valid pair still pays the litre-weighted rate',
    M.weightedRate({ { litres = 50, rate = 300 }, { litres = 50, rate = 280 } }), 290)

-- J4: C.validate's EIGHT refusal branches, read through the public C.get.
-- Bob replaced the whole body with a bare pass-through and the bar stayed green.
do
    local function readBack(rec)
        C.reset()
        C._components[77] = rec
        local got, why = C.get(77)
        return got, why
    end
    local function sound(over)
        local base = { schemaVersion = 1, fillTypeName = "WHEAT", marketRevision = "mr1",
                       state = "READY", baseThroughEvents = 100, otherConsumerProduct = 2,
                       baselineRate = 200 }
        for k, v in pairs(over or {}) do base[k] = v end
        return base
    end

    T.eq('J4 a sound record reads back', (readBack(sound())).fillTypeName, "WHEAT")
    T.eq('J4a a non-table record refuses NOT_TABLE', select(2, readBack("not a table")), "NOT_TABLE")
    T.eq('J4b a foreign schema refuses SCHEMA', select(2, readBack(sound({ schemaVersion = 2 }))), "SCHEMA")
    T.eq('J4c an empty fill type name refuses FILL_TYPE', select(2, readBack(sound({ fillTypeName = "" }))), "FILL_TYPE")
    T.eq('J4d a non-string fill type name refuses FILL_TYPE', select(2, readBack(sound({ fillTypeName = 7 }))), "FILL_TYPE")
    T.eq('J4e an empty market revision refuses MARKET_REVISION', select(2, readBack(sound({ marketRevision = "" }))), "MARKET_REVISION")
    T.eq('J4f an unknown state refuses STATE', select(2, readBack(sound({ state = "MAYBE" }))), "STATE")
    T.eq('J4g a negative event base refuses BASE_THROUGH_EVENTS', select(2, readBack(sound({ baseThroughEvents = -1 }))), "BASE_THROUGH_EVENTS")
    T.eq('J4h a non-finite event base refuses BASE_THROUGH_EVENTS', select(2, readBack(sound({ baseThroughEvents = 0 / 0 }))), "BASE_THROUGH_EVENTS")
    T.eq('J4i a zero consumer product refuses CONSUMER_PRODUCT', select(2, readBack(sound({ otherConsumerProduct = 0 }))), "CONSUMER_PRODUCT")
    T.eq('J4j a negative baseline rate refuses BASELINE_RATE', select(2, readBack(sound({ baselineRate = -5 }))), "BASELINE_RATE")
    T.eq('J4k a non-finite baseline rate refuses BASELINE_RATE', select(2, readBack(sound({ baselineRate = math.huge }))), "BASELINE_RATE")
    -- An UNAVAILABLE record is structurally valid and still not a quote.
    T.eq('J4l an UNAVAILABLE state reads as NO_MARKET, not as a number',
        select(2, readBack({ schemaVersion = 1, fillTypeName = "WHEAT", marketRevision = "mr1",
                             state = "UNAVAILABLE" })), "NO_MARKET")
end

-- J5: C.reset is actually called by the mission lifecycle, so a second savegame
-- in one process does not inherit the first one's records.
do
    C.reset()
    C.capture(5, "WHEAT", 100, 2)
    T.ok('J5 a captured component reads back', C.get(5) ~= nil)
    C.reset()
    T.eq('J5b reset clears the captured components', select(2, C.get(5)), "NO_MARKET")
    C.capture(5, "WHEAT", 100, 2)
    T.eq('J5c and the revision counter restarts with it', C.get(5).marketRevision, "mr1")
end

-- J6: THE COMPONENTS BELONG TO THE PRICE AUTHORITY.
-- A pure client asked for a price before the server's first sync has no
-- entry.current, so it falls past the early return and composes locally. It must
-- not capture: that record would carry a client-local revision and be served as
-- though it were the owner's answer.
do
    local savedServer = g_server
    C.reset()
    g_MarketDynamics = { priceModifiers = { probe = function() return 2 end } }

    g_server = nil
    local client = setmetatable({ prices = { [3] = { base = 100, volatilityFactor = 1, modifiers = {}, current = nil } } }, { __index = MarketEngine })
    client:_recalculate(3)
    T.eq('J6 a pure client before its first sync captures nothing',
        select(2, C.get(3)), "NO_MARKET")

    -- The same call on the server does capture, so J6 is about the role and not
    -- about the call simply never running.
    g_server = {}
    local server = setmetatable({ prices = { [3] = { base = 100, volatilityFactor = 1, modifiers = {}, current = nil } } }, { __index = MarketEngine })
    server:_recalculate(3)
    T.ok('J6b the server on the identical call does capture', C.get(3) ~= nil)
    T.eq('J6c and its record is READY', C.get(3).state, "READY")

    g_server = savedServer
end

-- J7: an out-of-range token count cannot be put on the wire at all.
-- It used to travel as a UInt32 against a 4096 bound, so 4097 upwards were
-- expressible; the reader then refused, zeroed the count and read no strings,
-- leaving the sender's strings in the stream to mis-align every later event in
-- the same packet.
T.eq('J7 the count field is sized to exactly the token budget',
    E.MAX_TOKENS, 2 ^ E.TOKEN_COUNT_BITS - 1)
T.eq('J7b the budget is still large enough for a full preview payload',
    E.MAX_TOKENS >= 4095, true)

T.summary()
