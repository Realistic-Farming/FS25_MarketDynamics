-- =========================================================
-- FS25_MarketDynamics - MD-16 private read contract and resolvers
-- =========================================================
-- The owner-side resolvers behind the load-value surface, built against the
-- DECLARED provider interfaces rather than against present ones.
--
-- EVERY PROVIDER THIS FILE READS IS UNBUILT TODAY. SG-2's getNativeSaleInputsV1
-- facade, SG-3's assessMaterialUse and Organic's harvestOrganicOriginV1 payload
-- are paired owner work in their own handoffs, and SG-1's paged
-- getManagementView lands with the StockGuard family. So the absent path is not
-- an edge case here, it is the ONLY path that runs today, and it is written as
-- the normal one: every probe is protected, an absent or malformed provider is
-- explicitly unavailable with a reason, and nothing ever falls back to a
-- favorable default. A missing fact must never be worth money.
--
-- Nothing in this file writes money, mutates a native object, creates a capture
-- handle or grants permission to sell. A preview is an estimate tied to a stock
-- and a market revision; the actual native operation prices its own paid amount
-- from fresh server-admitted inputs, and never treats a displayed quote as an
-- offer, a reservation or execution authority.
-- =========================================================

Md16Resolvers = Md16Resolvers or {}
local R = Md16Resolvers

R.SCHEMA_VERSION = 1

-- The public reason vocabulary and its exact player-facing English. Closed set:
-- no free text, no hidden parameters, no source identities.
R.REASONS = {
    ACTOR_DENIED        = "This actor cannot read this load or destination.",
    DISCLOSURE_DENIED   = "This material fact is not available to this actor.",
    NO_MARKET           = "The market value is not available.",
    SOURCE_UNAVAILABLE  = "This sale has no proved matching material source.",
    GRADE_PARTIAL       = "Some of the load lacks a complete supported grade; those litres earn no grade addition.",
    ORGANIC_PARTIAL     = "Some origin is unknown; only the proved eligible share earns the organic addition.",
    HISTORY_LIMIT       = "Some older material history is unavailable; quantity is preserved.",
    DETAIL_LIMIT        = "Some contract detail exceeded the explanation limit; those litres use baseline terms.",
    PROFILE_UNSUPPORTED = "This material or sale path has no supported value profile.",
    STALE_STOCK         = "The load changed; refresh the estimate.",
    OBSERVATION_GAP     = "Part of this material movement was not observed.",
    CONTRACT_PRICED     = "The contracted portion follows its existing settlement terms.",
    NO_PAID_SALE        = "This destination stores material and does not pay for this delivery.",
    NO_OUTPUT           = "No supported paid sale has been observed.",
    PUBLIC_UNAVAILABLE  = "The authorized load-value result is not currently available.",
}
R.MAX_REASONS = 15

R.PREVIEW_STATES = { READY = true, BASELINE_ONLY = true, NATIVE_STORAGE = true, UNAVAILABLE = true, STALE = true, DENIED = true }
R.TERM_STATES = { QUALIFIED = true, NO_BONUS = true, PARTIAL = true, UNAVAILABLE = true, UNSUPPORTED = true, HISTORICAL = true }
R.AVAILABILITY = { READY = true, UNAVAILABLE = true, DENIED = true }
R.NATIVE_KINDS = { SALE_SPOT = true, STORE_INPUT = true, UNSUPPORTED = true }

R.MAX_ROWS = 64
R.MAX_PARTS = 4
R.MAX_CURSOR_BYTES = 128

local isFiniteNumber = Md16Material.isFiniteNumber
local isAmount = Md16Material.isAmount

--- Trim a reason list to the public bound, preserving order.
function R.reasons(list)
    local out = {}
    for _, code in ipairs(type(list) == "table" and list or {}) do
        if R.REASONS[code] ~= nil and #out < R.MAX_REASONS then
            out[#out + 1] = code
        end
    end
    return out
end

--- The player-facing English for a reason code. Returns nil for an unknown
--- code rather than echoing it: a code is not a sentence.
function R.reasonText(code)
    return R.REASONS[code]
end

-- ---------------------------------------------------------
-- Provider probes
-- ---------------------------------------------------------
-- Each of these answers "is this owner here AND does it speak the version this
-- build was written against". Absent, wrong version, thrown or malformed all
-- reduce to the same answer: unavailable. None of them is a hard dependency.

--- The optional StockGuard mission handle.
function R.stockGuard()
    local mission = g_currentMission
    if mission == nil then return nil end
    local handle
    pcall(function() handle = mission.stockGuard end)
    if type(handle) ~= "table" then return nil end
    return handle
end

--- SG-2's declared native sale inputs facade. UNBUILT.
function R.saleInputsProvider()
    local sg = R.stockGuard()
    if sg == nil then return nil, "SOURCE_UNAVAILABLE" end
    if type(sg.getNativeSaleInputsV1) ~= "function" then return nil, "SOURCE_UNAVAILABLE" end
    return sg
end

--- SG-1's paged management view. UNBUILT at the paging version MD-16 needs.
--- The capability must explicitly advertise managementPagingVersion = 1 before a
--- paged request is made: feeding a first page to an old whole-farm interpreter
--- is worse than reporting unavailable.
function R.managementProvider()
    local sg = R.stockGuard()
    if sg == nil then return nil, "PUBLIC_UNAVAILABLE" end
    if type(sg.getManagementView) ~= "function" then return nil, "PUBLIC_UNAVAILABLE" end
    local caps
    if type(sg.getCapabilities) == "function" then
        pcall(function() caps = sg:getCapabilities() end)
    end
    if type(caps) ~= "table" or caps.managementPagingVersion ~= 1 then
        return nil, "PUBLIC_UNAVAILABLE"
    end
    return sg
end

--- SG-3's four-argument pure evaluator. UNBUILT.
--- Called under protection: a thrown, nil or malformed result, or an absent
--- required owner, is unavailable and can never grant a favorable term.
function R.assessMaterialUse(consumerLease, query, use, profileId)
    local sg = R.stockGuard()
    if sg == nil or type(sg.assessMaterialUse) ~= "function" then
        return nil, "PROFILE_UNSUPPORTED"
    end
    local ok, result = pcall(sg.assessMaterialUse, consumerLease, query, use, profileId)
    if not ok or type(result) ~= "table" then return nil, "PROFILE_UNSUPPORTED" end
    return result
end

-- ---------------------------------------------------------
-- Destination role
-- ---------------------------------------------------------
--- Derive a destination's role from the station's ACTUAL overrides, for this
--- farm and this fill type, freshly on every catalogue and preview.
--
-- The four combinations are not symmetric and the brief is explicit that
-- guessing either way is wrong:
--   store=true,  skip=true   -> STORE_INPUT, native storage, no unload money
--   store=false, skip=false  -> SALE_SPOT, a paid sale
--   store=true,  skip=false  -> a paid-capacity path, eligible ONLY when its
--                               declared source/receiver basis supports an
--                               estimate; otherwise unavailable, never invented
--   skip=true,   store=false -> unsupported/unavailable, not invented storage
--
-- A factory or production object is NOT universally unpaid merely because it
-- stores material, and NO_PAID_SALE applies only to a PROVED non-paying
-- delivery. Both getters are read under protection: an unresolved policy is
-- unsupported, which is a different answer from "stores".
-- @return string nativeKind, string availability, table reasons
function R.destinationRole(station, farmId, fillTypeIndex, basisSupported)
    if type(station) ~= "table" then
        return "UNSUPPORTED", "UNAVAILABLE", R.reasons({ "PROFILE_UNSUPPORTED" })
    end

    local store, skip
    if type(station.getStoreGoods) == "function" then
        pcall(function() store = station:getStoreGoods(farmId, fillTypeIndex) end)
    end
    if type(station.getSkipSell) == "function" then
        pcall(function() skip = station:getSkipSell(farmId, fillTypeIndex) end)
    end

    if type(store) ~= "boolean" or type(skip) ~= "boolean" then
        return "UNSUPPORTED", "UNAVAILABLE", R.reasons({ "PROFILE_UNSUPPORTED" })
    end

    if store and skip then
        return "STORE_INPUT", "READY", R.reasons({ "NO_PAID_SALE" })
    end
    if not store and not skip then
        return "SALE_SPOT", "READY", R.reasons({})
    end
    if store and not skip then
        if basisSupported == true then
            return "SALE_SPOT", "READY", R.reasons({})
        end
        return "UNSUPPORTED", "UNAVAILABLE", R.reasons({ "PROFILE_UNSUPPORTED" })
    end
    -- skip and not store
    return "UNSUPPORTED", "UNAVAILABLE", R.reasons({ "PROFILE_UNSUPPORTED" })
end

-- ---------------------------------------------------------
-- DTO validation
-- ---------------------------------------------------------
local function validRowAmount(amount, unit)
    if not isAmount(amount) then return false end
    if unit == "COUNT" and amount ~= math.floor(amount) then return false end
    return true
end
R.validRowAmount = validRowAmount

--- MD16_STOCK_PAGE_1. READY requires a losslessly copied view revision and rows
--- carrying only the public fields: never properties, actions, carrier
--- positions, private causal state or source identities.
-- @return table|nil page, string|nil reason
function R.validateStockPage(page)
    if type(page) ~= "table" then return nil, "NOT_TABLE" end
    if page.schemaVersion ~= R.SCHEMA_VERSION then return nil, "SCHEMA" end
    if not R.AVAILABILITY[page.availability] then return nil, "AVAILABILITY" end

    if page.availability ~= "READY" then
        -- Non-READY carries no usable rows, cursor or revision. A page that
        -- refused and still handed over rows would be read as a small result.
        if page.rows ~= nil or page.nextCursor ~= nil or page.viewRevision ~= nil then
            return nil, "NON_READY_PAYLOAD"
        end
        return page
    end

    local rev = page.viewRevision
    if type(rev) ~= "table" or type(rev.viewKey) ~= "string" or type(rev.dataRevision) ~= "string" then
        return nil, "VIEW_REVISION"
    end
    if type(page.rows) ~= "table" then return nil, "ROWS" end
    if #page.rows > R.MAX_ROWS then return nil, "ROW_COUNT" end
    for _, row in ipairs(page.rows) do
        if type(row) ~= "table" then return nil, "ROW" end
        if type(row.stockRef) ~= "table" then return nil, "STOCK_REF" end
        if type(row.displayName) ~= "string" then return nil, "DISPLAY_NAME" end
        if type(row.materialRef) ~= "table" then return nil, "MATERIAL_REF" end
        if type(row.amountUnit) ~= "string" then return nil, "AMOUNT_UNIT" end
        if not validRowAmount(row.amount, row.amountUnit) then return nil, "AMOUNT" end
    end
    if page.nextCursor ~= nil then
        if type(page.nextCursor) ~= "string" or #page.nextCursor == 0 or #page.nextCursor > R.MAX_CURSOR_BYTES then
            return nil, "CURSOR"
        end
    end
    return page
end

--- MD16_SALE_PREVIEW_V1. `parts` is the four-bucket coalesced explanation and
--- never a witness list, so more than four buckets is a shape error rather than
--- something to trim.
function R.validatePreview(p)
    if type(p) ~= "table" then return nil, "NOT_TABLE" end
    if p.schemaVersion ~= R.SCHEMA_VERSION then return nil, "SCHEMA" end
    if not R.PREVIEW_STATES[p.state] then return nil, "STATE" end
    if not R.TERM_STATES[p.gradeState] then return nil, "GRADE_STATE" end
    if not R.TERM_STATES[p.organicState] then return nil, "ORGANIC_STATE" end
    if p.parts ~= nil then
        if type(p.parts) ~= "table" or #p.parts > R.MAX_PARTS then return nil, "PARTS" end
        local sum = 0
        for _, part in ipairs(p.parts) do
            if not isAmount(part.paidBasisAmount) then return nil, "PART_AMOUNT" end
            if not isFiniteNumber(part.gradeFactor) or not isFiniteNumber(part.organicFactor) then
                return nil, "PART_FACTOR"
            end
            sum = sum + part.paidBasisAmount
        end
        -- ALL BUCKET AMOUNTS SUM EXACTLY TO THE PAID BASIS. That is what makes
        -- the four-bucket explanation a reduction of the paid litres rather than
        -- a sample of them.
        if isAmount(p.paidBasisAmount) and math.abs(sum - p.paidBasisAmount) > 1e-6 then
            return nil, "PART_SUM"
        end
    end
    return p
end

--- Build the preview's parts from the reducer's rows, carrying the whole-call
--- selected use onto each bucket. No per-part Food/Feed opportunism: the use is
--- chosen once for the entire paid call.
function R.partsFromReduction(reduction, selectedUse, originCoverageState)
    local parts = {}
    for _, row in ipairs(reduction.rows) do
        parts[#parts + 1] = {
            bucket = row.bucket,
            paidBasisAmount = row.paidBasisAmount,
            selectedUse = selectedUse,
            gradeFactor = row.gradeFactor,
            eligibleKnownOrganicAmount = reduction.paidBasisAmount > 0
                and reduction.eligibleKnownOrganicAmount * (row.paidBasisAmount / reduction.paidBasisAmount)
                or 0,
            organicFactor = reduction.organicFactor,
            originCoverageState = originCoverageState,
        }
    end
    return parts
end

--- An unavailable preview, which is what every call returns today.
function R.unavailablePreview(destinationId, stockRef, reasonCodes, state)
    return {
        schemaVersion = R.SCHEMA_VERSION,
        destinationId = destinationId,
        stockRef = stockRef,
        state = state or "UNAVAILABLE",
        amountUnit = "LITRE",
        gradeState = "UNAVAILABLE",
        organicState = "UNAVAILABLE",
        reasons = R.reasons(reasonCodes),
    }
end

-- ---------------------------------------------------------
-- Resolvers
-- ---------------------------------------------------------
--- The server-local sale-stock page.
-- Reads the EXISTING server view: it never sends a view request, never asks for
-- a full replica, never alters another controller's selection and never touches
-- command credentials. rowKinds is a trusted server-local filter and must never
-- enter a client request or a network payload.
-- @return table MD16_STOCK_PAGE_1
function R._resolveSaleStocks(trustedActorContext, cursor)
    if type(trustedActorContext) ~= "table" then
        return { schemaVersion = R.SCHEMA_VERSION, availability = "DENIED", reasons = R.reasons({ "ACTOR_DENIED" }) }
    end
    local sg, why = R.managementProvider()
    if sg == nil then
        return { schemaVersion = R.SCHEMA_VERSION, availability = "UNAVAILABLE", reasons = R.reasons({ why }) }
    end

    local readOptions = { rowKinds = { "STOCK" } }
    if cursor ~= nil then readOptions.pageCursor = cursor end

    local view
    local ok = pcall(function()
        view = sg:getManagementView(trustedActorContext,
            { route = "STOCK", selectionKind = "FARM" }, readOptions)
    end)
    if not ok or type(view) ~= "table" or view.state ~= "READY" then
        return { schemaVersion = R.SCHEMA_VERSION, availability = "UNAVAILABLE", reasons = R.reasons({ "PUBLIC_UNAVAILABLE" }) }
    end
    if view.pagingVersion ~= 1 then
        return { schemaVersion = R.SCHEMA_VERSION, availability = "UNAVAILABLE", reasons = R.reasons({ "PUBLIC_UNAVAILABLE" }) }
    end

    -- The provider may include a required contextual CARRIER row beside the
    -- STOCK rows. It counts inside the provider's own 64-row page, and MD-16
    -- omits it from the public sale-stock list WITHOUT dropping any STOCK
    -- identity: ignoring the context row is not the same as skipping a stock.
    local rows = {}
    for _, row in ipairs(view.rows or {}) do
        if row.rowKind == "STOCK" and #rows < R.MAX_ROWS then
            rows[#rows + 1] = {
                stockRef = row.stockRef,
                displayName = row.label,
                materialRef = row.materialRef,
                amount = row.amount,
                amountUnit = row.amountUnit,
            }
        end
    end

    local page = {
        schemaVersion = R.SCHEMA_VERSION,
        availability = "READY",
        viewRevision = { viewKey = tostring(view.viewKey), dataRevision = tostring(view.dataRevision) },
        rows = rows,
        nextCursor = view.nextPageCursor,
        reasons = R.reasons({}),
    }
    local valid = R.validateStockPage(page)
    if valid == nil then
        return { schemaVersion = R.SCHEMA_VERSION, availability = "UNAVAILABLE", reasons = R.reasons({ "PUBLIC_UNAVAILABLE" }) }
    end
    return valid
end

--- The server-local sale quote.
-- Today this always reaches the unavailable path, because the SG-2 facade it
-- needs does not exist. That is the correct answer and not a stub shortcut:
-- with no proved matching material source there is no material addition to
-- estimate, and the native rate stands.
-- @return table|nil preview, string|nil reason
function R._resolveSaleQuote(destinationId, stockRef, trustedActorContext)
    if type(trustedActorContext) ~= "table" then
        return R.unavailablePreview(destinationId, stockRef, { "ACTOR_DENIED" }, "DENIED")
    end
    if destinationId == nil or type(stockRef) ~= "table" then
        return R.unavailablePreview(destinationId, stockRef, { "PUBLIC_UNAVAILABLE" })
    end

    local engine = g_MarketDynamics ~= nil and g_MarketDynamics.marketEngine or nil
    if engine == nil or type(engine.getSaleQuoteComponents) ~= "function" then
        return R.unavailablePreview(destinationId, stockRef, { "NO_MARKET" })
    end

    local provider, why = R.saleInputsProvider()
    if provider == nil then
        -- No proved source: the market baseline may still be shown, but no
        -- material addition is estimated and no favorable default is used.
        return R.unavailablePreview(destinationId, stockRef, { why }, "BASELINE_ONLY")
    end

    -- The admitted path is owner work in the SG-2 handoff and is not reachable
    -- from this subset. Refusing here is deliberate: a preview built without the
    -- facade would be an invented estimate.
    return R.unavailablePreview(destinationId, stockRef, { "SOURCE_UNAVAILABLE" }, "BASELINE_ONLY")
end

--- The latest observed outcome for one destination.
-- Keyed by the resolved farm identity and destination token, never by a public
-- station shared between farms, so one farm's last sale can never be read by
-- another. No outcome means UNAVAILABLE, which is not the same as zero.
R._latestOutcome = {}

function R.outcomeKey(farmKey, destinationId)
    return tostring(farmKey) .. "|" .. tostring(destinationId)
end

function R.recordOutcome(farmKey, destinationId, outcome)
    if farmKey == nil or destinationId == nil or type(outcome) ~= "table" then return false end
    R._latestOutcome[R.outcomeKey(farmKey, destinationId)] = outcome
    return true
end

function R.getLatestSaleOutcome(farmKey, destinationId)
    local found = R._latestOutcome[R.outcomeKey(farmKey, destinationId)]
    if found == nil then
        return {
            schemaVersion = R.SCHEMA_VERSION,
            destinationId = destinationId,
            amountUnit = "LITRE",
            state = "UNAVAILABLE",
            reasons = R.reasons({ "NO_OUTPUT" }),
        }
    end
    return found
end

--- Clear every derived map. Nothing here is saved, so invalidation is the whole
--- lifecycle: owner, source binding, actor, farm or mission change clears it.
function R.invalidate()
    R._latestOutcome = {}
end
