-- =========================================================
-- FS25_MarketDynamics - MD-16 paid sale phase
-- =========================================================
-- The one place the material addition reaches money. PriceHook's
-- SellingStation.sellFillType wrap opens an entry here BEFORE the native body
-- runs, the native body reads its price once (SellingStation.lua:356,
-- self:getEffectiveFillTypePrice(fillTypeIndex, toolType)), PriceHook's price
-- hook answers that one read with the qualified rate, and the wrap closes the
-- entry when the native body returns or raises. The native body then pays
-- fillDelta * that rate through its own addMoney (:360-364). No second payment,
-- no second writer, no quantity touched.
--
-- WHERE THE FACTS COME FROM, every one of them read through StockGuard:
--   SG-2  handle.getNativeSaleInputsV1(nil): the SaleInputsV1 record of the
--         paid phase StockGuard's own station bracket opened for THIS call
--         (SGNativeSale.lua inputs; nil means the current phase, Iris's MD16 A4
--         reading). StockGuard's bracket is an INSTANCE wrapper on the station
--         (SGStationAdapter.lua installSaleBracket) that calls the class method
--         at call time, so MarketDynamics' class wrap always runs inside it.
--   Organic  capturedContributions[].properties.harvestOrganicOriginV1, the
--         record SoilFertilizer produces (OrganicOriginProperty.lua record):
--         knowledge, payload.fraction, knownAmount over basisAmount.
--   SG-3  handle.sg3.assessMaterialUse(lease, query, use, profileId) over the
--         record's stockRefs, through the md16.saleInputs consumer
--         (Md16Resolvers). Food first, then Feed, one use for the whole call.
--   Market  MarketEngine:getSaleQuoteComponents, captured in the same
--         _recalculate pass that produced the quote this hook would pay anyway.
-- They reduce through Md16Material.reduce and price through partRate (the rail
-- after the material terms), weighted by Md16Material.effectiveFactor. Contract
-- litres are frozen out first by Md16FuturesPlan and keep the baseline.
--
-- WHAT IT REFUSES, and the native price stands in every case: a client, Dynamic
-- Prices off or MarketDynamics not active, no captured components, components
-- that are not the quote this hook would pay, no StockGuard or no phase, a record
-- whose farm, fill type or paid amount is not this call's (Bob's MD16 A4 join),
-- contributions that do not add up to the paid amount, a futures plan that
-- cannot be admitted, and a material term of exactly one. The last one matters:
-- a sale with no proved grade and no proved origin takes the unchanged legacy
-- path, so an absent provider can never move a sale's money by rounding.
--
-- Server only and transient: nothing here is saved or sent.
-- =========================================================

Md16SalePhase = Md16SalePhase or {}
local S = Md16SalePhase

S.ORIGIN_PROPERTY = "harvestOrganicOriginV1"
S.ORIGIN_SCHEMA = 1
S.QUALITY_PROPERTY = "qualityBasisV1"
S.NATIVE_PATH = "SELLING_STATION"
S.UNIT = "LITRE"
S.EPSILON = 1e-6
-- SG-3's built-in use profiles (SG3Profiles.lua: FOOD/CROP_FOOD_V1, FEED/CROP_FEED_V1).
-- Food first: it is preferred only when it fully qualifies (brief :59).
S.USES = {
    { use = "FOOD", profileId = "CROP_FOOD_V1" },
    { use = "FEED", profileId = "CROP_FEED_V1" },
}

S._stack = {}            -- open entries, innermost last
S._callCounter = 0
S._paidLogged = false

local isFiniteNumber = Md16Material.isFiniteNumber
local isAmount = Md16Material.isAmount

local function positive(n) return isFiniteNumber(n) and n > 0 end

local function log(level, msg)
    if MDMLog ~= nil and type(MDMLog[level]) == "function" then MDMLog[level]("Md16SalePhase: " .. msg) end
end

-- ---------------------------------------------------------
-- Pure readers
-- ---------------------------------------------------------
--- The proved organic coverage of one harvestOrganicOriginV1 record.
--- KNOWN or PARTIAL with a coverage basis: knownAmount / basisAmount of these
--- litres carry the recorded fraction. Anything else proves nothing: an UNKNOWN
--- record, a missing one, a foreign schema, a fraction outside 0..1, or a record
--- without a coverage basis. Unproved litres are not conventional litres; they
--- simply earn no organic numerator (brief :63).
-- @return number coverage 0..1, number fraction 0..1
function S.originCoverage(rec)
    if type(rec) ~= "table" then return 0, 0 end
    if rec.propertyId ~= S.ORIGIN_PROPERTY or rec.schemaVersion ~= S.ORIGIN_SCHEMA then return 0, 0 end
    if rec.knowledge ~= "KNOWN" and rec.knowledge ~= "PARTIAL" then return 0, 0 end
    local payload = rec.payload
    local fraction = type(payload) == "table" and payload.fraction or nil
    if not isFiniteNumber(fraction) or fraction < 0 or fraction > 1 then return 0, 0 end
    local known, basis = rec.knownAmount, rec.basisAmount
    if not isAmount(known) or not positive(basis) or known > basis + S.EPSILON then return 0, 0 end
    return math.min(1, known / basis), fraction
end

--- The share of a contribution's PAID litres that SG-2 actually observed at the
--- source: sourceAmount against the source litres the paid amount needed through
--- the admitted conversion (paid / triggerRatio / dischargeFactor, the same chain
--- SGNativeSale.inputs projects through). Below one is an observation gap.
function S.observedShare(c)
    local conv = c.conversion
    if type(conv) ~= "table" or not positive(conv.triggerRatio) or not positive(conv.dischargeFactor) then return 0 end
    if not isAmount(c.sourceAmount) or not positive(c.actualAmount) then return 0 end
    local needed = c.actualAmount / conv.triggerRatio / conv.dischargeFactor
    if not positive(needed) then return 0 end
    local share = c.sourceAmount / needed
    if share >= 1 - S.EPSILON then return 1 end
    return math.max(0, share)
end

--- One captured contribution as reducer parts. Up to three:
---   observed litres with proved origin    grade, originKnown, originShare
---   observed litres without proved origin grade, origin unknown
---   unobserved litres                     no grade, origin unknown
--- Every paid litre lands in exactly one of them, so the reducer's basis is the
--- whole paid amount (brief :55, unavailable history withholds a term, never
--- quantity).
-- @return table parts
function S.partsOf(c, gradeLetter)
    local parts = {}
    local amount = type(c) == "table" and c.actualAmount or nil
    if not positive(amount) then return parts end
    local observed = amount * S.observedShare(c)
    if amount - observed <= S.EPSILON then observed = amount end
    local coverage, fraction = S.originCoverage(type(c.properties) == "table" and c.properties[S.ORIGIN_PROPERTY] or nil)
    local proved = observed * coverage
    if observed - proved <= S.EPSILON then proved = observed end
    if proved > S.EPSILON then
        parts[#parts + 1] = { amount = proved, grade = gradeLetter, originKnown = true, originShare = fraction }
    else
        proved = 0
    end
    if observed - proved > S.EPSILON then
        parts[#parts + 1] = { amount = observed - proved, grade = gradeLetter, originKnown = false }
    end
    if amount - observed > S.EPSILON then
        parts[#parts + 1] = { amount = amount - observed, originKnown = false }
    end
    return parts
end

--- Does an SG-3 Result qualify a grade? READY, KNOWN, SUITABLE, for the use and
--- profile that were asked, with a letter the dials price. Anything else earns
--- no grade addition (brief :59: "its canonical Result state/reasons/knowledge/
--- suitability ... determine eligibility").
function S.gradeQualifies(result, use, profileId)
    if type(result) ~= "table" then return false end
    if result.state ~= "READY" or result.knowledge ~= "KNOWN" or result.suitability ~= "SUITABLE" then return false end
    if result.use ~= use or result.profileId ~= profileId then return false end
    return Md16Material.GRADE_FACTORS[result.grade] ~= nil
end

--- The whole call's grade: Food if it fully qualifies, else Feed, else none.
-- @return string|nil letter, string|nil use
function S.gradeFor(stockRefs)
    if type(stockRefs) ~= "table" or #stockRefs == 0 then return nil, nil end
    local lease = Md16Resolvers.saleInputsLease()
    if lease == nil then return nil, nil end
    local letter, chosen = nil, nil
    Md16Resolvers.beginExecutionRead(stockRefs)
    local ok = pcall(function()
        for _, u in ipairs(S.USES) do
            local query = { stockRefs = stockRefs, purpose = Md16Resolvers.PURPOSE_EXECUTION, propertyIds = { S.QUALITY_PROPERTY } }
            local result = Md16Resolvers.assessMaterialUse(lease, query, u.use, u.profileId)
            if S.gradeQualifies(result, u.use, u.profileId) then
                letter, chosen = result.grade, u.use
                return
            end
        end
    end)
    Md16Resolvers.endExecutionRead()
    if not ok then return nil, nil end
    return letter, chosen
end

--- Is this facade record this call's record? Bob's MD16 A4 join, item 2: the
--- facade answers the innermost open phase, so the farm, the fill type name and
--- the paid amount must all be this call's, exactly.
function S.recordMatches(record, farmId, fillDelta, fillTypeName)
    if type(record) ~= "table" then return false, "NO_RECORD" end
    if record.schemaVersion ~= 1 or record.nativePath ~= S.NATIVE_PATH or record.amountUnit ~= S.UNIT then return false, "RECORD_SHAPE" end
    if record.farmId ~= farmId then return false, "FARM_MISMATCH" end
    if record.fillTypeName ~= fillTypeName then return false, "TYPE_MISMATCH" end
    if record.paidAmount ~= fillDelta then return false, "AMOUNT_MISMATCH" end
    if type(record.capturedContributions) ~= "table" or #record.capturedContributions == 0 then return false, "NO_CONTRIBUTIONS" end
    return true
end

-- ---------------------------------------------------------
-- Qualification
-- ---------------------------------------------------------
--- Qualify one paid sale call. Server only.
-- @return table|nil { rate, baselineRate, plan, planFrame, organicFactor,
--                     gradeFactor, selectedUse, paidBasisAmount }, string|nil reason
function S.qualify(station, farmId, fillDelta, fillTypeIndex)
    if g_server == nil then return nil, "NOT_SERVER" end
    if type(station) ~= "table" then return nil, "NO_STATION" end
    if not positive(fillDelta) then return nil, "NO_PAID_AMOUNT" end
    local md = g_MarketDynamics
    if md == nil or not md.isActive then return nil, "NO_MARKET" end
    if md.settings ~= nil and not md.settings.pricesEnabled then return nil, "PRICES_DISABLED" end
    local engine = md.marketEngine
    if engine == nil or type(engine.getSaleQuoteComponents) ~= "function" or type(engine.getPrice) ~= "function" then
        return nil, "NO_MARKET"
    end

    local comps = engine:getSaleQuoteComponents(fillTypeIndex)
    if comps == nil then return nil, "NO_MARKET" end
    -- The components must describe the very quote this hook would otherwise pay
    -- (MarketEngine:getPrice is entry.current, the same pass's railed product).
    -- If they do not, the baseline cannot be bound and the native path stands.
    local quoted = engine:getPrice(fillTypeIndex)
    if not positive(quoted) or math.abs(quoted - comps.baselineRate) > S.EPSILON * math.max(1, quoted) then
        return nil, "BASELINE_UNBOUND"
    end

    local sg = Md16Resolvers.saleInputsProvider()
    if sg == nil then return nil, "SOURCE_UNAVAILABLE" end
    -- A DOT call with nil: the current paid phase. pcall(f, nil) hands the
    -- closure exactly one nil argument, which is what the facade expects.
    local okIn, record, whyIn = pcall(sg.getNativeSaleInputsV1, nil)
    if not okIn then return nil, "SOURCE_ERROR" end
    if type(record) ~= "table" then return nil, tostring(whyIn or "SOURCE_UNAVAILABLE") end
    local matches, whyMatch = S.recordMatches(record, farmId, fillDelta, comps.fillTypeName)
    if not matches then return nil, whyMatch end

    local letter, use = S.gradeFor(record.stockRefs)

    local parts, contributed = {}, 0
    for _, c in ipairs(record.capturedContributions) do
        if type(c) ~= "table" or c.amountUnit ~= S.UNIT or not isAmount(c.actualAmount) then return nil, "CONTRIBUTION_SHAPE" end
        contributed = contributed + c.actualAmount
        for _, p in ipairs(S.partsOf(c, letter)) do parts[#parts + 1] = p end
    end
    -- The contributions are the paid population: they must account for exactly
    -- the paid litres, no more and no fewer.
    if math.abs(contributed - fillDelta) > S.EPSILON * math.max(1, fillDelta) then return nil, "CONTRIBUTION_SUM" end

    local reduced = Md16Material.reduce(parts)
    if not positive(reduced.paidBasisAmount) then return nil, "NO_PAID_BASIS" end
    local factor, spotRate, baseline = Md16Material.effectiveFactor(reduced, comps.baseThroughEvents, comps.otherConsumerProduct)
    if factor == nil or not positive(spotRate) or not positive(baseline) then return nil, "RATE_UNAVAILABLE" end
    if math.abs(spotRate - baseline) <= S.EPSILON * math.max(1, baseline) then return nil, "NO_BONUS" end

    -- Contract litres keep the baseline; only spot excess earns the addition
    -- (brief :47, :83). Frozen now, before native work; an unadmitted plan
    -- suppresses the addition for this call and the legacy futures path runs.
    local plan, planFrame = nil, nil
    local futures = md.futuresMarket
    if futures ~= nil and Md16FuturesPlan ~= nil then
        S._callCounter = S._callCounter + 1
        local now = 0
        if MDMUtil ~= nil and type(MDMUtil.getGameTime) == "function" then now = MDMUtil.getGameTime() or 0 end
        planFrame = { callRef = "md16:" .. tostring(S._callCounter), farmId = farmId, fillTypeIndex = fillTypeIndex,
                      paidLitres = fillDelta, now = now, baselineRate = comps.baselineRate }
        local whyPlan
        plan, whyPlan = Md16FuturesPlan.freeze(futures, planFrame)
        if plan == nil then return nil, "PLAN_" .. tostring(whyPlan) end
    end

    local rate = spotRate
    if plan ~= nil then
        rate = Md16FuturesPlan.effectiveRate(plan, spotRate)
        if not positive(rate) then return nil, "PLAN_RATE" end
    end

    return {
        rate = rate,
        spotRate = spotRate,
        baselineRate = comps.baselineRate,
        plan = plan,
        planFrame = planFrame,
        organicFactor = reduced.organicFactor,
        gradeFactor = reduced.gradeFactor,
        selectedUse = use,
        paidBasisAmount = reduced.paidBasisAmount,
    }
end

-- ---------------------------------------------------------
-- The call-scoped entry
-- ---------------------------------------------------------
--- Open the entry for one native sellFillType call. Every call pushes an entry,
--- qualified or not, so a nested native sale on the same station can never read
--- an outer call's rate: the price read answers only the INNERMOST entry.
function S.open(station, farmId, fillDelta, fillTypeIndex)
    local entry = { station = station, farmId = farmId, fillDelta = fillDelta, fillTypeIndex = fillTypeIndex,
                    open = true, consumed = false }
    local ok, ctx, why = pcall(S.qualify, station, farmId, fillDelta, fillTypeIndex)
    if ok and type(ctx) == "table" then
        for k, v in pairs(ctx) do entry[k] = v end
    else
        entry.reason = ok and why or "QUALIFY_ERROR"
        if not ok then log("warn", "qualification failed (" .. tostring(ctx) .. "); the native price stands") end
    end
    S._stack[#S._stack + 1] = entry
    return entry
end

--- The rate for the native price read, or nil. Answered once, to the innermost
--- open entry, for its own station and fill type only (brief :81). Every other
--- read, before, after or beside it, gets the ordinary price.
function S.rateFor(station, fillTypeIndex)
    local top = S._stack[#S._stack]
    if top == nil or not top.open or top.consumed or top.rate == nil then return nil end
    if top.station ~= station or top.fillTypeIndex ~= fillTypeIndex then return nil end
    top.consumed = true
    return top.rate
end

--- Close the entry the moment the native body returns or raises: from here on
--- it answers no read. It STAYS on the stack until release, because the wrap's
--- own post-sale futures read comes next, and a closed entry on top is what
--- stops that read from reaching an OUTER call's rate when this call was a
--- nested one (a foreign sale inside a bracketed sale, before the outer call's
--- own native read).
function S.close(entry)
    if type(entry) ~= "table" or not entry.open then return end
    entry.open = false
    if entry.consumed then
        local contracted = entry.plan ~= nil and #(entry.plan.assignments or {}) > 0
        local msg = string.format("material addition paid: %.3f L at %.4f per litre against a baseline of %.4f (organic x%.4f, grade x%.4f, use %s, contract litres %s)",
            entry.fillDelta or 0, entry.rate or 0, entry.baselineRate or 0, entry.organicFactor or 1, entry.gradeFactor or 1,
            tostring(entry.selectedUse or "none"), contracted and "at baseline" or "none")
        local added = isFiniteNumber(entry.rate) and isFiniteNumber(entry.baselineRate)
            and entry.rate - entry.baselineRate > S.EPSILON * math.max(1, entry.baselineRate)
        if not added then
            -- Every litre went to a contract: the call paid the baseline.
            log("debug", msg)
        elseif not S._paidLogged then
            S._paidLogged = true
            log("info", "first " .. msg)
        else
            log("debug", msg)
        end
    end
end

--- Take a closed entry off the stack, after the futures report. Closes it first
--- if it is somehow still open.
function S.release(entry)
    if type(entry) ~= "table" then return end
    S.close(entry)
    for i = #S._stack, 1, -1 do
        if S._stack[i] == entry then table.remove(S._stack, i) break end
    end
end

--- The futures report for a closed entry: the frozen plan when this call's
--- native read took the material rate, otherwise nil and the legacy path runs.
function S.allocationContext(entry)
    if type(entry) ~= "table" or not entry.consumed or entry.plan == nil then return nil end
    return { plan = entry.plan, frame = entry.planFrame }
end

--- Mission teardown: nothing is open across missions.
function S.reset()
    S._stack = {}
    S._callCounter = 0
    S._paidLogged = false
end
