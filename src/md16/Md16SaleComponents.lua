-- =========================================================
-- FS25_MarketDynamics - MD-16 sale components (SaleComponentsV1)
-- =========================================================
-- The market side of MD-16. The components are captured at the existing server
-- MarketEngine:_recalculate WHILE EACH REGISTERED CALLBACK IS EVALUATED ONCE,
-- because the alternatives are all wrong: invoking the consumers again during a
-- sale re-runs stateful inputs, and dividing the finished quote to recover the
-- components cannot separate the rail from what it clamped.
--
-- SaleComponentsV1 = {
--   schemaVersion = 1,
--   fillTypeName,            -- the market's own key for this quote
--   marketRevision,          -- opaque mission-local revision, NOT wall time
--   baseThroughEvents,       -- base * volatilityFactor * product(event factors)
--   otherConsumerProduct,    -- UNCLAMPED product of valid consumers, minus OrganicPremium
--   baselineRate,            -- baseThroughEvents * clamp(otherConsumerProduct)
--   state,                   -- READY or UNAVAILABLE
-- }
--
-- otherConsumerProduct is kept UNCLAMPED on purpose. The rail belongs after the
-- material terms compose (Md16Material.partRate), so a component record that had
-- already clamped would make the correct composition unreachable.
--
-- THE ORGANIC PREMIUM RETIREMENT LIVES HERE AND IS WHY THIS PR CANNOT MERGE
-- EARLY. The MD-16 brief retires the pooled OrganicPremium modifier in every
-- mode, including when MD-16 itself is disabled or unavailable, because the
-- pooled farm-average premium is the wrong answer to "what is THIS load worth".
-- Its replacement is the captured-origin term, which needs SG-1, SG-2, SG-4,
-- SG-3 and FP-1 Organic to exist. Merging this before those land removes the
-- live organic premium with nothing in its place.
-- =========================================================

Md16SaleComponents = Md16SaleComponents or {}
local C = Md16SaleComponents

C.SCHEMA_VERSION = 1

--- The retired modifier's registry name. Excluded at the COMPOSITION point
--- rather than at registration, so the exclusion holds no matter which mod
--- registered it, whether MD-16 is enabled, and whether the bridge ran at all.
--- The bridge keeps registering so the name stays reserved against another
--- suite mod claiming it; the modifier simply can never contribute again.
C.RETIRED_MODIFIER = "OrganicPremium"

C.STATE_READY = "READY"
C.STATE_UNAVAILABLE = "UNAVAILABLE"

local isFiniteNumber = Md16Material.isFiniteNumber

-- fillTypeIndex -> SaleComponentsV1
C._components = {}
-- monotonic mission-local counter behind the opaque marketRevision
C._revisionCounter = 0

--- Reset every captured component and the revision counter. Called on mission
--- load and teardown; nothing here is saved.
function C.reset()
    C._components = {}
    C._revisionCounter = 0
end

--- The market's own name for a fill type index, resolved under protection.
--- The engine's price entry does not carry one, and a MaterialRef is exactly
--- FILL_TYPE/fillTypeName, so the name is looked up rather than invented. With
--- no manager the index's own string stands in and the record is still valid.
function C.fillTypeNameOf(fillTypeIndex)
    local name
    if g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeNameByIndex) == "function" then
        pcall(function() name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) end)
    end
    if type(name) == "string" and #name > 0 then return name end
    return tostring(fillTypeIndex)
end

local function nextRevision()
    C._revisionCounter = C._revisionCounter + 1
    return "mr" .. tostring(C._revisionCounter)
end

--- Do two snapshots describe the same quote? Compared on the component values
--- only: the revision is what changes when these do, so including it would make
--- every comparison false.
local function sameQuote(a, b)
    if a == nil or b == nil then return false end
    return a.fillTypeName == b.fillTypeName
        and a.baseThroughEvents == b.baseThroughEvents
        and a.otherConsumerProduct == b.otherConsumerProduct
        and a.state == b.state
end

--- Validate a component record. An invalid or non-finite component makes the new
--- sale snapshot UNAVAILABLE. It never becomes a guessed correction to native
--- money: a wrong number here would be paid out.
-- @return table|nil record, string|nil reason
function C.validate(rec)
    if type(rec) ~= "table" then return nil, "NOT_TABLE" end
    if rec.schemaVersion ~= C.SCHEMA_VERSION then return nil, "SCHEMA" end
    if type(rec.fillTypeName) ~= "string" or #rec.fillTypeName == 0 then return nil, "FILL_TYPE" end
    if type(rec.marketRevision) ~= "string" or #rec.marketRevision == 0 then return nil, "MARKET_REVISION" end
    if rec.state ~= C.STATE_READY and rec.state ~= C.STATE_UNAVAILABLE then return nil, "STATE" end
    if rec.state == C.STATE_UNAVAILABLE then return rec end
    if not isFiniteNumber(rec.baseThroughEvents) or rec.baseThroughEvents < 0 then return nil, "BASE_THROUGH_EVENTS" end
    if not isFiniteNumber(rec.otherConsumerProduct) or rec.otherConsumerProduct <= 0 then return nil, "CONSUMER_PRODUCT" end
    if not isFiniteNumber(rec.baselineRate) or rec.baselineRate < 0 then return nil, "BASELINE_RATE" end
    return rec
end

--- Record the components observed during one _recalculate.
-- Called from inside the engine's own composition, with the consumer product it
-- already computed, so no callback is invoked a second time.
-- @param fillTypeIndex   the engine's key
-- @param fillTypeName    the market's name for it, or nil
-- @param baseThroughEvents number
-- @param otherConsumerProduct number, UNCLAMPED, OrganicPremium already excluded
function C.capture(fillTypeIndex, fillTypeName, baseThroughEvents, otherConsumerProduct)
    if fillTypeIndex == nil then return nil end
    fillTypeName = fillTypeName or C.fillTypeNameOf(fillTypeIndex)

    local rec
    if not isFiniteNumber(baseThroughEvents) or not isFiniteNumber(otherConsumerProduct)
        or baseThroughEvents < 0 or otherConsumerProduct <= 0 then
        rec = {
            schemaVersion = C.SCHEMA_VERSION,
            fillTypeName = fillTypeName or tostring(fillTypeIndex),
            marketRevision = "",
            state = C.STATE_UNAVAILABLE,
        }
    else
        rec = {
            schemaVersion = C.SCHEMA_VERSION,
            fillTypeName = fillTypeName or tostring(fillTypeIndex),
            marketRevision = "",
            baseThroughEvents = baseThroughEvents,
            otherConsumerProduct = otherConsumerProduct,
            baselineRate = Md16Material.baselineRate(baseThroughEvents, otherConsumerProduct),
            state = C.STATE_READY,
        }
    end

    -- The revision advances with an actual component change, never with the
    -- clock and never on a recalculation that changed nothing.
    local previous = C._components[fillTypeIndex]
    if sameQuote(previous, rec) then
        rec.marketRevision = previous.marketRevision
    else
        rec.marketRevision = nextRevision()
    end

    C._components[fillTypeIndex] = rec
    return rec
end

--- The public read. Validated on the way out, so a caller can never act on a
--- component record the engine would not stand behind.
-- @return table|nil components, string|nil reason
function C.get(fillTypeIndex)
    local rec = C._components[fillTypeIndex]
    if rec == nil then return nil, "NO_MARKET" end
    local valid, why = C.validate(rec)
    if valid == nil then return nil, why end
    if valid.state ~= C.STATE_READY then return nil, "NO_MARKET" end
    -- A copy: the caller must not be able to edit the engine's snapshot.
    return {
        schemaVersion = valid.schemaVersion,
        fillTypeName = valid.fillTypeName,
        marketRevision = valid.marketRevision,
        baseThroughEvents = valid.baseThroughEvents,
        otherConsumerProduct = valid.otherConsumerProduct,
        baselineRate = valid.baselineRate,
        state = valid.state,
    }
end

--- Install getSaleQuoteComponents on the existing MarketEngine class.
--- A method rather than a free function because 4.3 names it
--- marketEngine:getSaleQuoteComponents(fillTypeIndex).
function C.install()
    if MarketEngine == nil then return false end
    if MarketEngine.getSaleQuoteComponents ~= nil then return false end
    --- @return table|nil SaleComponentsV1, string|nil reason
    MarketEngine.getSaleQuoteComponents = function(_self, fillTypeIndex)
        return C.get(fillTypeIndex)
    end
    return true
end

C.install()
