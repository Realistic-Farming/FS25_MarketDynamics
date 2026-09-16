-- =========================================================
-- FS25_MarketDynamics - MD-16 futures allocation plan
-- =========================================================
-- Separating contract-assigned litres from spot excess, so that only the spot
-- part receives the material addition while the contracted part keeps its
-- existing locked-value settlement.
--
-- The plan is a TRUSTED SERVER-LOCAL record frozen inside the same owner frame
-- that captured the sale. A client cannot provide one and none is ever built
-- from a UI preview: a displayed quote is an estimate, never execution
-- authority. If a plan cannot be admitted before native work, MD-16 suppresses
-- the material addition for that call and the unchanged legacy futures path runs.
--
-- Plan = {
--   version = 1,
--   callRef,                 -- the native call this plan was frozen for
--   assignments = { { contractId, litres, baselineValue }, ... },
--   spotExcessLitres,
-- }
--
-- UNITS, because this is exactly where the brief warns a builder goes wrong.
-- `baselineValue` is the TOTAL baseline money for that assignment's litres, not
-- a per-litre rate. The existing FuturesMarket:recordDelivery takes a per-litre
-- price and multiplies (FuturesMarket.lua:93), so the conversion happens here,
-- once, where it can be seen: rate = baselineValue / litres. Handing a total to
-- a function that expects a rate would inflate valueReceived by the litre count
-- and silently claw back the player's settlement.
--
-- Contract-assigned parts are valued at the qualified native/market BASELINE, so
-- the material term never reaches a contracted litre. Spot parts use the
-- qualified material rate. One native effectiveRate pays the whole accepted call.
-- =========================================================

Md16FuturesPlan = Md16FuturesPlan or {}
local P = Md16FuturesPlan

P.VERSION = 1

local isFiniteNumber = Md16Material.isFiniteNumber
local isAmount = Md16Material.isAmount

--- Validate a plan against the call it claims to belong to.
-- The source frame, predicate and amount must all match. A plan for another
-- call, another farm or another quantity is refused rather than adapted.
-- @param plan  candidate
-- @param frame { callRef, paidLitres }
-- @return table|nil plan, string|nil reason
function P.validate(plan, frame)
    if type(plan) ~= "table" then return nil, "NOT_TABLE" end
    if plan.version ~= P.VERSION then return nil, "VERSION" end
    if type(frame) ~= "table" then return nil, "NO_FRAME" end
    if plan.callRef == nil or plan.callRef ~= frame.callRef then return nil, "CALL_REF" end
    if type(plan.assignments) ~= "table" then return nil, "ASSIGNMENTS" end
    if not isAmount(plan.spotExcessLitres) then return nil, "SPOT_EXCESS" end
    if not isAmount(frame.paidLitres) then return nil, "PAID_LITRES" end

    local assignedTotal = 0
    local seen = {}
    for _, a in ipairs(plan.assignments) do
        if type(a) ~= "table" then return nil, "ASSIGNMENT_SHAPE" end
        if a.contractId == nil then return nil, "CONTRACT_ID" end
        -- One assignment per contract in a single call: two rows for the same
        -- contract would double its delivered quantity.
        if seen[a.contractId] then return nil, "DUPLICATE_CONTRACT" end
        seen[a.contractId] = true
        if not isAmount(a.litres) or a.litres <= 0 then return nil, "ASSIGNED_LITRES" end
        if not isFiniteNumber(a.baselineValue) or a.baselineValue < 0 then return nil, "BASELINE_VALUE" end
        assignedTotal = assignedTotal + a.litres
    end

    -- THE AMOUNT MUST MATCH. Assigned plus spot excess is exactly the paid
    -- quantity: a plan that accounts for more or fewer litres than were actually
    -- paid for is not a description of this sale.
    local total = assignedTotal + plan.spotExcessLitres
    if math.abs(total - frame.paidLitres) > 1e-6 then return nil, "AMOUNT_MISMATCH" end

    return plan
end

--- The per-litre baseline price for one assignment, from its total value.
-- Zero litres does not divide.
function P.assignedRate(assignment)
    if type(assignment) ~= "table" then return nil end
    if not isAmount(assignment.litres) or assignment.litres <= 0 then return nil end
    if not isFiniteNumber(assignment.baselineValue) then return nil end
    return assignment.baselineValue / assignment.litres
end

--- The one native weighted rate that pays the entire accepted call.
-- Contract litres at the baseline rate, spot litres at the qualified material
-- rate, summed as money and divided once by the paid litres. Never an
-- unweighted average of the two rates.
-- @return number|nil effectiveRate, number gross
function P.effectiveRate(plan, spotRate)
    if type(plan) ~= "table" or not isFiniteNumber(spotRate) then return nil, 0 end
    local allocations = {}
    for _, a in ipairs(plan.assignments or {}) do
        local rate = P.assignedRate(a)
        if rate == nil then return nil, 0 end
        allocations[#allocations + 1] = { litres = a.litres, rate = rate }
    end
    if isAmount(plan.spotExcessLitres) and plan.spotExcessLitres > 0 then
        allocations[#allocations + 1] = { litres = plan.spotExcessLitres, rate = spotRate }
    end
    local rate, gross = Md16Material.weightedRate(allocations)
    return rate, gross
end

--- Apply an admitted plan to the existing futures tracker.
-- Each assignment reaches the EXISTING recordDelivery with its own baseline
-- rate, so the contract's fulfillment still pays quantity*lockedPrice minus
-- valueReceived and every existing default and BC-managed term is untouched.
-- No second writer and no second payment: this adds nothing to the player's
-- balance, it only tells the tracker what was already received at the station.
-- @return number applied, string|nil reason
function P.apply(futuresMarket, plan)
    if futuresMarket == nil or type(futuresMarket.recordDelivery) ~= "function" then
        return 0, "NO_FUTURES"
    end
    if type(plan) ~= "table" then return 0, "NO_PLAN" end

    local applied = 0
    for _, a in ipairs(plan.assignments or {}) do
        local rate = P.assignedRate(a)
        if rate ~= nil then
            local ok = pcall(function() futuresMarket:recordDelivery(a.contractId, a.litres, rate) end)
            if ok then applied = applied + 1 end
        end
    end
    return applied
end

--- Freeze a plan from the tracker's own current assignments.
-- Preserves the existing iteration semantics and makes no claim about order:
-- `pairs` is not proof of oldest-first, so the contract ids are sorted into a
-- deterministic order before assigning, and no player selector exists.
-- @param futuresMarket  the live tracker
-- @param frame { callRef, farmId, fillTypeIndex, paidLitres, now, baselineRate }
-- @return table|nil plan, string|nil reason
function P.freeze(futuresMarket, frame)
    if futuresMarket == nil or type(futuresMarket.contracts) ~= "table" then return nil, "NO_FUTURES" end
    if type(frame) ~= "table" or not isAmount(frame.paidLitres) then return nil, "NO_FRAME" end
    if not isFiniteNumber(frame.baselineRate) or frame.baselineRate < 0 then return nil, "NO_BASELINE" end

    local ids = {}
    for id, contract in pairs(futuresMarket.contracts) do
        local active = contract.status == "active"
        local farmMatch = contract.farmId == frame.farmId
        local typeMatch = contract.fillTypeIndex == frame.fillTypeIndex
        local timeMatch = (frame.now or 0) >= (contract.deliveryStartTime or 0)
        if active and farmMatch and typeMatch and timeMatch then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

    local remaining = frame.paidLitres
    local assignments = {}
    for _, id in ipairs(ids) do
        if remaining <= 0 then break end
        local contract = futuresMarket.contracts[id]
        local needed = (contract.quantity or 0) - (contract.delivered or 0)
        if needed > 0 then
            local applying = math.min(remaining, needed)
            assignments[#assignments + 1] = {
                contractId = id,
                litres = applying,
                baselineValue = applying * frame.baselineRate,
            }
            remaining = remaining - applying
        end
    end

    local plan = {
        version = P.VERSION,
        callRef = frame.callRef,
        assignments = assignments,
        spotExcessLitres = remaining,
    }
    return P.validate(plan, frame)
end

--- Install the optional fifth argument on the existing onCropDelivered.
-- The signature gains allocationContext at the END, so every existing caller is
-- unchanged and the legacy scan still runs when no plan is supplied. An
-- unadmitted plan is not an error and not a refusal of the delivery: it falls
-- back to the unchanged legacy path, which is what "suppress material additions
-- for that call" means for the tracker.
function P.install()
    if FuturesMarket == nil or type(FuturesMarket.onCropDelivered) ~= "function" then return false end
    if FuturesMarket.md16Installed then return false end

    local legacy = FuturesMarket.onCropDelivered
    FuturesMarket.onCropDelivered = function(self, farmId, fillTypeIndex, litres, pricePerLiter, allocationContext)
        if allocationContext ~= nil then
            local plan = P.validate(allocationContext.plan, allocationContext.frame)
            if plan ~= nil then
                P.apply(self, plan)
                return
            end
        end
        return legacy(self, farmId, fillTypeIndex, litres, pricePerLiter)
    end
    FuturesMarket.md16Installed = true
    return true
end

P.install()
