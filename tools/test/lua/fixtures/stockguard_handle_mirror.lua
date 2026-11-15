-- stockguard_handle_mirror.lua - a StockGuard mission handle for the MD-16 bars.
--
-- WHY THIS EXISTS. The first MD-16 bar stubbed each provider as whatever the
-- caller happened to want: getManagementView returned a flat page and ignored
-- its arguments, and nothing stood where SG-2 and SG-3 live at all. A stub that
-- ignores its arguments cannot see a wrong argument, and one that returns the
-- caller's expected shape cannot see a wrong shape, so a colon call and an
-- unwrapped read passed 609 assertions and paid nothing in game.
--
-- This mirror copies the REAL contracts on FS25_StockGuard origin/development
-- (read 2026-11-11), each at the line it comes from, and keeps their failure
-- behaviour too: a colon call fails here exactly the way it fails there.
--   * every handle function is a DOT closure (StockGuard.lua:107-112 "no
--     implicit self"); the server-only ones go through serverOnly (:112-117),
--     which forwards ... unchanged and answers nil, "NOT_SERVER" on a client
--   * registerConsumer (:121 -> SGRegistry.lua:173-184) validates the spec and
--     issues a live lease; a second live owner of an id is DUPLICATE_OWNER
--   * readMaterial (:136 -> SGOperations.lua:1699-1755) refuses a dead lease,
--     refuses a propertyId the consumer did not declare, calls the consumer's
--     resolveReadContext with a COPY of the query, and reads each stockRef
--   * getManagementView (:191 -> SGViews.lua:489-667) returns the WRAPPER
--     { state, reason, view }; actorAvailability (:185-191), normalizeSelection
--     (:76-96) and normalizeReadOptions (:100-127) refuse what they refuse there
--   * getNativeSaleInputsV1 (:140-144 -> SGNativeSale.lua:117-200): nil means the
--     innermost open paid phase (NO_SALE_PHASE without one); any table is looked
--     up as an issued frame, so the handle itself, which a colon call passes, is
--     UNKNOWN_FRAME
--   * sg3.assessMaterialUse (SG3.lua:169-172 -> Member:assessMaterialUse :87):
--     reads through the CALLER's consumer lease, DENIED -> DISCLOSURE_DENIED,
--     not READY -> SOURCE_CHANGED
--   * the station sale bracket (SGStationAdapter.lua:330-345) is an INSTANCE
--     wrapper that opens the paid phase and then calls the CLASS method resolved
--     at call time, so a class wrap installed by MarketDynamics runs inside it
--
-- The one simplification is SG-3's evaluator: a test stock carries its Result
-- per use directly instead of a qualityBasisV1 score payload. The call path to
-- it (lease, readMaterial, resolveReadContext, the member table) is the real one.

SGMirror = SGMirror or {}

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
SGMirror.copy = copy

local function nonempty(s, n) return type(s) == "string" and s ~= "" and #s <= (n or 128) end
local function positiveInt(n) return type(n) == "number" and n >= 1 and n == math.floor(n) end
local function sameRef(a, b)
    return type(a) == "table" and type(b) == "table" and a.stockId == b.stockId
        and a.contentsGeneration == b.contentsGeneration and a.dataRevision == b.dataRevision
end

--- A new handle and the world behind it.
-- world.isServer        boolean, what serverOnly checks
-- world.stocks          stockId -> { stockRef, materialRef, observedAmount, amountUnit, properties, sg3 = { [use] = Result fields } }
-- world.viewRows        rows the STOCK view returns
-- world.parent          the discharge parent of the next paid phase (SGNativeSale inputs' d), or nil
-- world.calls           a log of every call, { name, args }
function SGMirror.newHandle(opts)
    opts = opts or {}
    local world = {
        isServer = opts.isServer ~= false,
        stocks = opts.stocks or {},
        viewRows = opts.viewRows or {},
        viewNext = opts.viewNext,
        parent = opts.parent,
        phases = {},
        leases = {},
        byId = {},
        nextLease = 0,
        epoch = "1",
        calls = {},
        withSg3 = opts.withSg3 ~= false,
    }
    local h = {}
    local function record(name, ...) world.calls[#world.calls + 1] = { name = name, n = select("#", ...), args = { ... } } end
    local function serverOnly(name, fn)
        return function(...)
            record(name, ...)
            if not world.isServer then return nil, "NOT_SERVER" end
            return fn(...)
        end
    end

    -- SGRegistry.lua:173-184 and :71-81.
    h.registerConsumer = function(consumerId, spec)
        record("registerConsumer", consumerId, spec)
        if not nonempty(consumerId, 64) then return nil, "INVALID_ID" end
        if type(spec) ~= "table" then return nil, "INVALID_SPEC" end
        if not positiveInt(spec.version) then return nil, "VERSION" end
        if type(spec.requiredSchemas) ~= "table" then return nil, "REQUIRED_SCHEMAS" end
        for pid, ver in pairs(spec.requiredSchemas) do
            if not nonempty(pid, 128) or not positiveInt(ver) then return nil, "REQUIRED_SCHEMAS" end
        end
        if type(spec.materialKinds) ~= "table" or #spec.materialKinds == 0 then return nil, "MATERIAL_KINDS" end
        if type(spec.resolveReadContext) ~= "function" then return nil, "CALLBACKS" end
        if world.byId[consumerId] ~= nil then return nil, "DUPLICATE_OWNER" end
        world.nextLease = world.nextLease + 1
        local lease = { leaseId = world.epoch .. ":" .. world.nextLease, kind = "CONSUMER", ownerId = consumerId, spec = spec, epoch = world.epoch, live = true }
        world.leases[lease.leaseId] = lease
        world.byId[consumerId] = lease
        return lease
    end
    h.unregisterOwner = function(lease)
        record("unregisterOwner", lease)
        if type(lease) ~= "table" or world.leases[lease.leaseId] ~= lease then return false end
        lease.live = false
        world.leases[lease.leaseId] = nil
        world.byId[lease.ownerId] = nil
        return true
    end
    local function isLive(lease)
        return type(lease) == "table" and lease.epoch == world.epoch and world.leases[lease.leaseId] == lease and lease.live
    end

    -- SGOperations.lua:1699-1755.
    h.readMaterial = serverOnly("readMaterial", function(lease, query)
        if not isLive(lease) then return { state = "DENIED", reason = "LEASE", records = {} } end
        if type(query) ~= "table" then return { state = "REFUSED", reason = "QUERY", records = {} } end
        local spec = lease.spec
        if query.propertyIds ~= nil then
            for _, pid in ipairs(query.propertyIds) do
                if spec.requiredSchemas[pid] == nil then return { state = "REFUSED", reason = "PROPERTY_NOT_ADMITTED:" .. tostring(pid), records = {} } end
            end
        end
        local ok, ctx, reason = pcall(spec.resolveReadContext, copy(query))
        if not ok then return { state = "ERROR", reason = "RESOLVE_ERROR", records = {} } end
        if type(ctx) ~= "table" or type(ctx.stockRefs) ~= "table" then return { state = "DENIED", reason = tostring(reason or "CONTEXT_DENIED"), records = {} } end
        local records = {}
        for _, ref in ipairs(ctx.stockRefs) do
            local stock = type(ref) == "table" and world.stocks[ref.stockId] or nil
            if stock == nil then
                records[#records + 1] = { stockRef = copy(ref), state = "UNAVAILABLE", reason = "STOCK_UNAVAILABLE" }
            else
                local snap = copy(stock)
                snap.state = sameRef(ref, stock.stockRef) and "READY" or "STALE_REFERENCE"
                records[#records + 1] = snap
            end
        end
        return { state = "READY", readRevision = "1", purpose = ctx.purpose, records = records }
    end)

    -- SGViews.lua:151-170 (only the field MD-16 gates on).
    h.getCapabilities = function()
        record("getCapabilities")
        return { managementPagingVersion = opts.pagingVersion == nil and 1 or opts.pagingVersion }
    end

    -- SGViews.lua:185-191.
    local function actorAvailability(actor)
        if type(actor) ~= "table" then return "DENIED", "NO_ACTOR" end
        if actor.actorState == "WAITING" then return "WAITING", "ACTOR_WAITING" end
        if actor.actorState == "SPECTATOR" or actor.actorState == "INVALID" then return "DENIED", "ACTOR_" .. actor.actorState end
        if type(actor.farmId) ~= "number" or actor.farmId < 1 or actor.farmId > 8 then return "DENIED", "INVALID_FARM" end
        return "READY", nil
    end

    -- SGViews.lua:489-667: the wrapper, the view and its envelope fields.
    h.getManagementView = serverOnly("getManagementView", function(actor, selection, readOptions)
        local availability, reason = actorAvailability(actor)
        local route = type(selection) == "table" and selection.route or "STOCK"
        if route ~= "STOCK" or type(selection) ~= "table" then return { state = "UNAVAILABLE", reason = "SELECTION", view = nil } end
        if selection.selectionKind ~= "FARM" then return { state = "UNAVAILABLE", reason = "SELECTION_KIND", view = nil } end
        if readOptions ~= nil and type(readOptions) ~= "table" then return { state = "UNAVAILABLE", reason = "READ_OPTIONS", view = nil } end
        local opt = readOptions or {}
        if opt.rowKinds ~= nil and (type(opt.rowKinds) ~= "table" or #opt.rowKinds == 0) then return { state = "UNAVAILABLE", reason = "ROW_KINDS", view = nil } end
        local view = {
            schemaVersion = 2, route = "STOCK", availability = availability, reasonCode = reason or "",
            viewKey = "", dataRevision = "17", selectionKind = "FARM", selectionKey = "sk:farm",
            pagingVersion = 1, pageCursor = opt.pageCursor, nextPageCursor = nil, rows = {}, ownerStates = {},
        }
        if availability ~= "READY" then return { state = availability, reason = reason, view = view } end
        view.viewKey = "vk:" .. tostring(actor.farmId)
        local want = nil
        if opt.rowKinds ~= nil then
            want = {}
            for _, k in ipairs(opt.rowKinds) do want[k] = true end
        end
        for _, row in ipairs(world.viewRows) do
            if want == nil or want[row.rowKind] or row.rowKind == "CARRIER" then view.rows[#view.rows + 1] = copy(row) end
        end
        view.nextPageCursor = world.viewNext
        return { state = "READY", reason = nil, view = view }
    end)

    -- SGNativeSale.lua:117-200, for the SELLING_STATION path.
    h.getNativeSaleInputsV1 = serverOnly("getNativeSaleInputsV1", function(saleFrame)
        local phase
        if saleFrame == nil then
            phase = world.phases[#world.phases]
            if phase == nil then return nil, "NO_SALE_PHASE" end
        else
            if type(saleFrame) ~= "table" then return nil, "FRAME" end
            return nil, "UNKNOWN_FRAME"
        end
        if not (type(phase.fillDelta) == "number" and phase.fillDelta > 0) then return nil, "INVALID_PAID" end
        local d = phase.parent
        if d == nil then return nil, "NO_PARENT" end
        if d.station ~= phase.station then return nil, "DESTINATION_MISMATCH" end
        if d.farmId ~= phase.farmId then return nil, "FARM_MISMATCH" end
        if d.paidFillTypeIndex ~= phase.fillTypeIndex then return nil, "TYPE_MISMATCH" end
        local stock = world.stocks[d.stockId]
        if stock == nil then return nil, "SOURCE_UNBOUND" end
        local projected = phase.fillDelta / d.triggerRatio / d.dischargeFactor
        local available = d.available
        local sourceAmount = math.min(projected, available)
        local share = available > 0 and math.min(1, sourceAmount / available) or 0
        local properties = {}
        for pid, p in pairs(stock.properties or {}) do
            local q = copy(p)
            if q.basisAmount ~= nil then
                q.knownAmount = (q.knownAmount or 0) * share
                q.basisAmount = q.basisAmount * share
            end
            properties[pid] = q
        end
        local complete = projected <= available + 1e-6
        return {
            schemaVersion = 1, nativePath = "SELLING_STATION", destinationId = "dest:" .. tostring(phase.station.name),
            farmId = phase.farmId, fillTypeName = d.fillTypeName, paidAmount = phase.fillDelta, amountUnit = "LITRE",
            stockRefs = { copy(stock.stockRef) },
            capturedContributions = { {
                captureRef = "cap:1", allocationRef = "op:1:a1", materialRef = copy(stock.materialRef),
                actualAmount = phase.fillDelta, amountUnit = "LITRE", sourceAmount = sourceAmount, sourceUnit = "LITRE",
                conversion = { dischargeFactor = d.dischargeFactor, triggerRatio = d.triggerRatio },
                properties = properties, knowledge = "KNOWN",
            } },
            sourceComplete = complete,
            reasons = complete and {} or { "OBSERVATION_GAP" },
        }
    end)

    -- SG3.lua:87-125 and :169-172, with the evaluator reduced to the stock's own Result.
    if world.withSg3 then
        h.sg3 = {
            getReadiness = function() return { schema = "SG3_READINESS_1", ready = true } end,
            assessMaterialUse = function(consumerLease, query, use, profileId)
                record("sg3.assessMaterialUse", consumerLease, query, use, profileId)
                local function unavailable(reason)
                    return { state = "UNAVAILABLE", use = use, profileId = profileId, knowledge = "UNAVAILABLE", suitability = "UNAVAILABLE", reasons = { reason } }
                end
                local ok, res = pcall(h.readMaterial, consumerLease, query)
                if ok and type(res) == "table" and res.state == "DENIED" then return unavailable("DISCLOSURE_DENIED") end
                if not ok or type(res) ~= "table" or res.state ~= "READY" then return unavailable("SOURCE_CHANGED") end
                local rec = res.records and res.records[1] or nil
                if rec == nil or rec.state ~= "READY" then return unavailable("SOURCE_CHANGED") end
                local expected = ({ FOOD = "CROP_FOOD_V1", FEED = "CROP_FEED_V1" })[use]
                if expected ~= profileId then return { state = "UNSUPPORTED", use = use, profileId = profileId, knowledge = "UNAVAILABLE", suitability = "UNAVAILABLE", reasons = { "UNSUPPORTED_PROFILE" } } end
                local r = rec.sg3 and rec.sg3[use] or nil
                if r == nil then return { state = "READY", use = use, profileId = profileId, knowledge = "UNKNOWN", suitability = "UNKNOWN", reasons = { "ORIGIN_UNPROVEN" } } end
                return { state = "READY", use = use, profileId = profileId, knowledge = r.knowledge, suitability = r.suitability, grade = r.grade, reasons = {} }
            end,
        }
    end

    -- SGStationAdapter.lua:330-345: the instance wrapper that opens the paid phase.
    function world.bracket(station)
        local raw = rawget(station, "sellFillType")
        rawset(station, "sellFillType", function(self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes, ...)
            local phase = { station = self, farmId = farmId, fillDelta = fillDelta, fillTypeIndex = fillTypeIndex, parent = world.parent }
            world.phases[#world.phases + 1] = phase
            local fn = raw or getmetatable(self).__index.sellFillType
            local results = { pcall(fn, self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes, ...) }
            for i = #world.phases, 1, -1 do if world.phases[i] == phase then table.remove(world.phases, i) break end end
            if not results[1] then error(results[2], 0) end
            return unpack(results, 2)
        end)
    end

    function world.count(name)
        local n = 0
        for _, c in ipairs(world.calls) do if c.name == name then n = n + 1 end end
        return n
    end
    function world.last(name)
        for i = #world.calls, 1, -1 do if world.calls[i].name == name then return world.calls[i] end end
        return nil
    end

    return h, world
end
