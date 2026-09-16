-- =========================================================
-- FS25_MarketDynamics - MD-16 material terms and the sale reducer
-- =========================================================
-- The pure arithmetic half of MD-16: the grade term, the captured-origin term,
-- the rate composition and the ordered reduction that turns a complete paid
-- source population into at most four display buckets.
--
-- PURE. Nothing here reads the mission, the market, a native object or a clock,
-- and nothing here writes money. The SAME reducer supplies the preview and the
-- later revalidated execution frame, which is what makes it impossible for the
-- two to disagree because one of them only saw the first witnesses.
--
-- The three rules a builder gets wrong, each stated once here and asserted as a
-- difference in the bench:
--   1. The consumer rail is applied AFTER the material factors compose, never
--      before. Multiplying an already clamped quote by the material term breaks
--      the rail; dividing that quote to recover components loses stateful inputs.
--   2. Grade is a WHOLE-CALL decision. If any required positive part lacks a
--      complete supported grade, the entire grade term is 1 and every paid litre
--      appears in the grade-unavailable bucket, never in C.
--   3. Organic is INDEPENDENT of grade and shares no fate with it. Every actual
--      paid litre is in the denominator; only proved eligible litres are in the
--      numerator. Known conventional and unknown origin both contribute zero to
--      the numerator without voiding the proved share.
-- =========================================================

Md16Material = Md16Material or {}
local M = Md16Material

-- 4.9 dials: MarketDynamics-owned named constants, not magic numbers at a call
-- site. The approved starting values are grade A 1.15 / B 1.05 / C 1 and an
-- organic ceiling of 0.20.
M.GRADE_FACTORS = { A = 1.15, B = 1.05, C = 1.00 }
M.ORGANIC_CEILING = 0.20

-- The consumer composition band, ruled 0.5 to 3.0. Same band MarketEngine
-- already applies; named here because MD-16 applies it at a different point.
M.RAIL_MIN = 0.5
M.RAIL_MAX = 3.0

M.BUCKET_ORDER = { "A", "B", "C", "GRADE_UNAVAILABLE" }

local function isFiniteNumber(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
M.isFiniteNumber = isFiniteNumber

local function isAmount(n)
    return isFiniteNumber(n) and n >= 0
end
M.isAmount = isAmount

--- The grade term for one uniform part.
-- `complete` is the WHOLE-CALL grade admission, not this part's own state: a
-- known letter on one part earns nothing while another required positive part is
-- unknown. That is rule 2, and passing the part's own completeness here is the
-- shape of getting it wrong.
-- @return number  1.15, 1.05 or 1
function M.gradeFactor(letter, complete)
    if not complete then return 1 end
    return M.GRADE_FACTORS[letter] or 1
end

--- The captured-origin term over a complete paid basis.
-- Unsupported or zero paid basis is neutral 1 rather than a division.
function M.organicFactor(eligibleKnownLitres, paidBasisAmount)
    if not isAmount(paidBasisAmount) or paidBasisAmount <= 0 then return 1 end
    if not isAmount(eligibleKnownLitres) then return 1 end
    return 1 + M.ORGANIC_CEILING * (eligibleKnownLitres / paidBasisAmount)
end

--- Clamp to the consumer rail.
function M.rail(value)
    if not isFiniteNumber(value) then return nil end
    return math.max(M.RAIL_MIN, math.min(M.RAIL_MAX, value))
end

--- The rate for one qualified tracked spot part.
-- partRate = baseThroughEvents * clamp(otherConsumerProduct * gradeFactor * organicFactor)
-- THE RAIL IS APPLIED AFTER THE MATERIAL COMPOSITION. Never multiply a final
-- clamped quote by the material factor, and never divide a quote to recover
-- components or invoke the consumer callbacks a second time during a sale.
-- @return number|nil  nil when any input is not a finite number
function M.partRate(baseThroughEvents, otherConsumerProduct, gradeFactor, organicFactor)
    if not isFiniteNumber(baseThroughEvents) or not isFiniteNumber(otherConsumerProduct) then return nil end
    if not isFiniteNumber(gradeFactor) or not isFiniteNumber(organicFactor) then return nil end
    local railed = M.rail(otherConsumerProduct * gradeFactor * organicFactor)
    if railed == nil then return nil end
    return baseThroughEvents * railed
end

--- The baseline rate, which carries no material term at all.
-- baselineRate = baseThroughEvents * clamp(otherConsumerProduct)
function M.baselineRate(baseThroughEvents, otherConsumerProduct)
    return M.partRate(baseThroughEvents, otherConsumerProduct, 1, 1)
end

-- ---------------------------------------------------------
-- The ordered reduction
-- ---------------------------------------------------------
--- Is the whole call's grade complete?
-- Every part with a POSITIVE amount must carry a supported letter. A zero-amount
-- part cannot spoil the call, and an unsupported letter is not treated as C.
local function wholeCallGradeComplete(parts)
    for _, p in ipairs(parts) do
        if isAmount(p.amount) and p.amount > 0 then
            if M.GRADE_FACTORS[p.grade] == nil then return false end
        end
    end
    return true
end
M.wholeCallGradeComplete = wholeCallGradeComplete

--- Reduce a complete ordered paid-source population to the public explanation.
--
-- THE PAID POPULATION IS ONE COMPLETE ORDERED REDUCTION, NEVER THE VISIBLE
-- WITNESS LIST. Every actual paid litre is reconciled to paidBasisAmount first,
-- INCLUDING litres whose history is unavailable: unavailable history withholds a
-- favorable term, it never removes quantity. Only then is the display coalesced
-- to at most four buckets, so 256 witnesses and 4 rows describe the same litres.
--
-- Order, and it is the brief's order rather than a convenient one:
--   1. reconcile every paid litre to the basis
--   2. apply the WHOLE-CALL grade completeness rule, then map each litre to its
--      admitted A/B/C bucket or to grade-unavailable
--   3. organic over the complete basis, independent of step 2
--   4. (futures partitioning happens outside this reducer, on these amounts)
--   5. coalesce to at most four buckets in A, B, C, GRADE_UNAVAILABLE order
--
-- @param parts  ordered list of { amount, grade?, originKnown?, originShare?, selectedUse? }
-- @return table { paidBasisAmount, buckets, rows, gradeFactor, organicFactor,
--                 effectiveFactor, gradeComplete, originComplete }
function M.reduce(parts)
    parts = type(parts) == "table" and parts or {}

    local gradeComplete = wholeCallGradeComplete(parts)
    local buckets = { A = 0, B = 0, C = 0, GRADE_UNAVAILABLE = 0 }
    local basis, originNumerator, originComplete = 0, 0, true

    for _, p in ipairs(parts) do
        local amount = isAmount(p.amount) and p.amount or 0
        basis = basis + amount

        -- On the incomplete-grade branch EVERY paid litre lands in
        -- GRADE_UNAVAILABLE, never in C. C means "graded, and its grade adds
        -- nothing"; grade-unavailable means "not graded". Collapsing the two
        -- would tell the farmer his load was assessed when it was not.
        local bucket = "GRADE_UNAVAILABLE"
        if gradeComplete and M.GRADE_FACTORS[p.grade] ~= nil then
            bucket = p.grade
        end
        buckets[bucket] = buckets[bucket] + amount

        -- Organic is independent. A part whose origin is unknown leaves the
        -- coverage incomplete and contributes zero to the numerator, but its
        -- litres stay in the denominator and it does not void another part's
        -- proved eligible share.
        if p.originKnown then
            local share = isFiniteNumber(p.originShare) and p.originShare or 0
            if share < 0 then share = 0 elseif share > 1 then share = 1 end
            originNumerator = originNumerator + amount * share
        else
            originComplete = false
        end
    end

    local rows = {}
    for _, k in ipairs(M.BUCKET_ORDER) do
        if buckets[k] > 0 then
            rows[#rows + 1] = {
                bucket = k,
                paidBasisAmount = buckets[k],
                gradeFactor = M.gradeFactor(k, gradeComplete and k ~= "GRADE_UNAVAILABLE"),
            }
        end
    end

    -- The call's grade factor is the money-weighted blend of its buckets, not an
    -- unweighted average of letters and not a parent letter. PORTIONED has no
    -- parent grade, so mixed letters stay mixed and are priced by amount.
    local gradeFactorTotal = 1
    if basis > 0 then
        gradeFactorTotal = (buckets.A * M.GRADE_FACTORS.A
            + buckets.B * M.GRADE_FACTORS.B
            + buckets.C * M.GRADE_FACTORS.C
            + buckets.GRADE_UNAVAILABLE) / basis
    end

    local organicFactor = M.organicFactor(originNumerator, basis)

    return {
        paidBasisAmount = basis,
        buckets = buckets,
        rows = rows,
        gradeFactor = gradeFactorTotal,
        organicFactor = organicFactor,
        effectiveFactor = gradeFactorTotal * organicFactor,
        eligibleKnownOrganicAmount = originNumerator,
        gradeComplete = gradeComplete,
        originComplete = originComplete,
    }
end

--- One native weighted rate pays the entire accepted call.
-- effectiveRate = sum(partLitres * partRate) / paidLitres.
-- A zero paid quantity does NOT divide and does not create a new outcome.
-- @param allocations list of { litres, rate }
-- @return number|nil rate, number gross, number litres
function M.weightedRate(allocations)
    local gross, litres = 0, 0
    for _, a in ipairs(type(allocations) == "table" and allocations or {}) do
        if not isAmount(a.litres) or not isFiniteNumber(a.rate) then return nil, 0, 0 end
        gross = gross + a.litres * a.rate
        litres = litres + a.litres
    end
    if litres <= 0 then return nil, 0, 0 end
    return gross / litres, gross, litres
end
