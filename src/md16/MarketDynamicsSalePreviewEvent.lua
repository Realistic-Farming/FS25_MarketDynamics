-- =========================================================
-- FS25_MarketDynamics - MD-16 private sale preview event
-- =========================================================
-- The owner-private demand/reply channel for the load-value surface. It is NOT
-- a public broadcast and not a NetworkSync action: one client asks its own
-- server for its own authorized result, and the server replies to that one
-- connection.
--
-- WIRE ORDER, and it is exact because both ends have to agree before any apply:
--   1. isReply        Bool
--   2. schemaVersion  UInt8, must be 1
--   3. kind           UInt8, STOCKS=1 DESTINATIONS=2 PREVIEW=3 LATEST=4
--   4. requestId      Int32, positive 31-bit
--   5. tokenCount     UInt32, bounded
--   6. tokenCount * String
--
-- The record travels as ONE SG_VALUES_2 flat scalar-string token array, not an
-- invented single serialized string, and the codec is vendored (Md16Values) so
-- the native floor does not require StockGuard installed.
--
-- Unknown kind, schema or direction is rejected BEFORE any apply. That ordering
-- is the point: a malformed or cross-direction event must never reach a lookup,
-- a cache or a resolver, because by then it has already been treated as real.
--
-- No callbacks, native pointers or credentials cross this wire. The request
-- record carries only what its kind needs, and any extra trusted field (a farm,
-- a grade, a rate, an amount, a payment or a plan) REFUSES the event rather than
-- being ignored: a client that sends one is not making a request this owner
-- recognises.
-- =========================================================

MarketDynamicsSalePreviewEvent = MarketDynamicsSalePreviewEvent or {}
local E = MarketDynamicsSalePreviewEvent
local MarketDynamicsSalePreviewEvent_mt = Class(MarketDynamicsSalePreviewEvent, Event)
InitEventClass(MarketDynamicsSalePreviewEvent, "MarketDynamicsSalePreviewEvent")

E.SCHEMA_VERSION = 1

E.KIND_STOCKS = 1
E.KIND_DESTINATIONS = 2
E.KIND_PREVIEW = 3
E.KIND_LATEST = 4

E.KIND_NAMES = {
    [E.KIND_STOCKS] = "STOCKS",
    [E.KIND_DESTINATIONS] = "DESTINATIONS",
    [E.KIND_PREVIEW] = "PREVIEW",
    [E.KIND_LATEST] = "LATEST",
}

-- Budgets. Refuse rather than truncate: a silently clipped record is a wrong
-- answer that looks like a right one.
E.MAX_TOKENS = 4096
E.MAX_TOKEN_BYTES = 4096
E.MAX_TOTAL_BYTES = 32768
E.MAX_REQUEST_ID = 2147483647

--- The request record shape per kind. An extra key refuses.
E.REQUEST_KEYS = {
    [E.KIND_STOCKS] = { cursor = true },
    [E.KIND_DESTINATIONS] = { stockRef = true, cursor = true },
    [E.KIND_PREVIEW] = { destinationId = true, stockRef = true },
    [E.KIND_LATEST] = { destinationId = true },
}

--- Required keys per kind: a request missing one is not that request.
E.REQUEST_REQUIRED = {
    [E.KIND_STOCKS] = {},
    [E.KIND_DESTINATIONS] = { "stockRef" },
    [E.KIND_PREVIEW] = { "destinationId", "stockRef" },
    [E.KIND_LATEST] = { "destinationId" },
}

local function isPositiveInt31(n)
    return type(n) == "number" and n == n and n == math.floor(n) and n >= 1 and n <= E.MAX_REQUEST_ID
end
E.isPositiveInt31 = isPositiveInt31

--- Validate a request record against its kind, structurally, before it is
--- encoded or after it is decoded. Same function both ways, so the sender
--- cannot produce something the receiver would refuse.
-- @return table|nil record, string|nil reason
function E.validateRequestRecord(kind, record)
    local allowed = E.REQUEST_KEYS[kind]
    if allowed == nil then return nil, "KIND" end
    if type(record) ~= "table" then return nil, "NOT_TABLE" end
    for key in pairs(record) do
        if not allowed[key] then return nil, "UNEXPECTED_FIELD:" .. tostring(key) end
    end
    for _, key in ipairs(E.REQUEST_REQUIRED[kind]) do
        if record[key] == nil then return nil, "MISSING_FIELD:" .. key end
    end
    return record
end

--- Token budget check. Applied to what is about to be written AND to what was
--- just read, because a peer is not a source of truth about its own size.
-- @return boolean ok, string|nil reason
function E.checkTokens(tokens)
    if type(tokens) ~= "table" then return false, "TOKENS" end
    local count = #tokens
    if count < 1 or count > E.MAX_TOKENS then return false, "TOKEN_COUNT" end
    local total = 0
    for i = 1, count do
        local t = tokens[i]
        if type(t) ~= "string" then return false, "TOKEN_TYPE" end
        local n = #t
        if n > E.MAX_TOKEN_BYTES then return false, "TOKEN_SIZE" end
        total = total + n
        if total > E.MAX_TOTAL_BYTES then return false, "TOTAL_SIZE" end
    end
    return true
end

local function newEvent()
    return Event.new(MarketDynamicsSalePreviewEvent_mt)
end

function E.emptyNew()
    return newEvent()
end

--- A demand from a client (or the listen host's own local actor) to the owner.
function E.newRequest(kind, requestId, requestRecord)
    if E.KIND_NAMES[kind] == nil then return nil, "KIND" end
    if not isPositiveInt31(requestId) then return nil, "REQUEST_ID" end
    local rec, why = E.validateRequestRecord(kind, requestRecord)
    if rec == nil then return nil, why end
    local tokens = Md16Values.encode(rec)
    if tokens == nil then return nil, "ENCODE" end
    local ok, budgetWhy = E.checkTokens(tokens)
    if not ok then return nil, budgetWhy end

    local self = newEvent()
    self.isReply = false
    self.kind = kind
    self.requestId = requestId
    self.tokens = tokens
    self.record = rec
    return self
end

--- The owner's reply to exactly one connection.
function E.newReply(kind, requestId, replyRecord)
    if E.KIND_NAMES[kind] == nil then return nil, "KIND" end
    if not isPositiveInt31(requestId) then return nil, "REQUEST_ID" end
    if type(replyRecord) ~= "table" then return nil, "NOT_TABLE" end
    local tokens = Md16Values.encode(replyRecord)
    if tokens == nil then return nil, "ENCODE" end
    local ok, budgetWhy = E.checkTokens(tokens)
    if not ok then return nil, budgetWhy end

    local self = newEvent()
    self.isReply = true
    self.kind = kind
    self.requestId = requestId
    self.tokens = tokens
    self.record = replyRecord
    return self
end

-- ---------------------------------------------------------
-- Wire
-- ---------------------------------------------------------
function E:writeStream(streamId, connection)
    -- DIRECTION AT THE WRITE. A target that is the server may only be sent a
    -- REQUEST; a target that is a client may only be sent a REPLY. Checked here
    -- as well as on read, so a wrong-direction event is not produced at all.
    local targetIsServer = connection ~= nil and connection:getIsServer() == true
    if targetIsServer == (self.isReply == true) then
        -- Nothing is written: an event that cannot legally travel this way
        -- carries no payload rather than a misleading partial one.
        streamWriteBool(streamId, false)
        streamWriteUInt8(streamId, 0)
        streamWriteUInt8(streamId, 0)
        streamWriteInt32(streamId, 0)
        streamWriteUInt32(streamId, 0)
        return
    end

    streamWriteBool(streamId, self.isReply == true)
    streamWriteUInt8(streamId, E.SCHEMA_VERSION)
    streamWriteUInt8(streamId, self.kind)
    streamWriteInt32(streamId, self.requestId)
    streamWriteUInt32(streamId, #self.tokens)
    for i = 1, #self.tokens do
        streamWriteString(streamId, self.tokens[i])
    end
end

function E:readStream(streamId, connection)
    self.isReply = streamReadBool(streamId)
    self.schemaVersion = streamReadUInt8(streamId)
    self.kind = streamReadUInt8(streamId)
    self.requestId = streamReadInt32(streamId)
    local count = streamReadUInt32(streamId)

    self.malformed = nil
    if self.schemaVersion ~= E.SCHEMA_VERSION then self.malformed = "SCHEMA" end
    if E.KIND_NAMES[self.kind] == nil then self.malformed = self.malformed or "KIND" end
    if not isPositiveInt31(self.requestId) then self.malformed = self.malformed or "REQUEST_ID" end
    if type(count) ~= "number" or count < 0 or count > E.MAX_TOKENS then
        self.malformed = self.malformed or "TOKEN_COUNT"
        count = 0
    end

    -- The stream is drained whatever the verdict, so a refused event cannot
    -- leave unread bits behind it for the next event in the same packet.
    local tokens = {}
    for i = 1, count do
        tokens[i] = streamReadString(streamId)
    end
    self.tokens = tokens

    if self.malformed == nil then
        local ok, why = E.checkTokens(tokens)
        if not ok then self.malformed = why end
    end

    self:run(connection)
end

function E:run(connection)
    -- DIRECTION AT THE READ, the authoritative one. A source that is the server
    -- may only have sent a REPLY; a source that is a client may only have sent a
    -- REQUEST on the actual server. Refuse before any lookup or apply.
    local sourceIsServer = connection ~= nil and connection:getIsServer() == true
    if sourceIsServer ~= (self.isReply == true) then return end
    if self.malformed ~= nil then return end

    local record, why = Md16Values.decode(self.tokens)
    if record == nil then return end

    if self.isReply then
        if E.onReply ~= nil then E.onReply(self.kind, self.requestId, record) end
        return
    end

    -- A request only ever runs on the actual server.
    if g_server == nil then return end
    local valid = E.validateRequestRecord(self.kind, record)
    if valid == nil then return end
    if E.onRequest ~= nil then E.onRequest(connection, self.kind, self.requestId, valid) end
end

--- Send a demand to the owner. A pure client asks its server; the listen host
--- has no wire to use and resolves locally instead, which is why this returns
--- false there rather than faking a loopback connection.
function E.sendRequest(kind, requestId, requestRecord)
    if g_server ~= nil then return false, "IS_SERVER" end
    if g_client == nil then return false, "NO_CLIENT" end
    local event, why = E.newRequest(kind, requestId, requestRecord)
    if event == nil then return false, why end
    g_client:getServerConnection():sendEvent(event)
    return true
end

--- Reply to exactly one connection. Never a broadcast.
function E.sendReply(connection, kind, requestId, replyRecord)
    if g_server == nil then return false, "NOT_SERVER" end
    if connection == nil then return false, "NO_CONNECTION" end
    local event, why = E.newReply(kind, requestId, replyRecord)
    if event == nil then return false, why end
    connection:sendEvent(event)
    return true
end
