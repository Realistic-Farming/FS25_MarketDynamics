-- =========================================================
-- FS25_MarketDynamics - vendored data-only SG_VALUES_2 codec (MD-16)
-- =========================================================
-- VENDORED, NOT A DEPENDENCY. MD-16's private preview event carries its typed
-- records as an SG_VALUES_2 flat scalar-string token array. The MarketDynamics
-- package therefore carries its own data-only copy of that codec so the native
-- floor does not require StockGuard to be installed: with StockGuard absent the
-- event still encodes and decodes, and the records simply describe less.
--
-- The WIRE is deliberately identical to StockGuard's. The format and version
-- tokens below are SG_VALUES and 2 exactly as SGValues writes them, so a record
-- produced here decodes there and the reverse. Only the Lua namespace differs.
-- This is data only: no callbacks, no native pointers, no credentials.
--
-- Vendored from FS25_StockGuard src/core/SGValues.lua. Keep the two in step:
-- a change to the shared format belongs in both, and the MD-16 bench asserts
-- the format/version tokens so a silent drift fails here.
-- =========================================================

Md16Values = Md16Values or {}
local V = Md16Values

V.FORMAT = "SG_VALUES"
V.VERSION = "2"
V.FORMAT_TOKEN = "SG_VALUES_2"
V.MAX_TOKENS = 1000000
V.MAX_DEPTH = 64
V.INTEGER_LIMIT = 2 ^ 53

local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
V.isFinite = isFinite

local function isInteger(n) return isFinite(n) and n == math.floor(n) and math.abs(n) < V.INTEGER_LIMIT end
V.isInteger = isInteger

--- Integer to a lossless decimal string (no exponent, no ".0").
local function integerToken(n)
    return string.format("%d", n)
end

--- Array test: keys are exactly 1..n.
local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return true, 0 end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end
V.isArray = isArray

local function encodeInto(value, out, depth)
    if depth > V.MAX_DEPTH then return false, "DEPTH" end
    local t = type(value)
    if value == nil then
        out[#out + 1] = "N"
        return true
    elseif t == "boolean" then
        out[#out + 1] = "B"
        out[#out + 1] = value and "1" or "0"
        return true
    elseif t == "number" then
        if not isFinite(value) then return false, "NON_FINITE" end
        if isInteger(value) then
            out[#out + 1] = "I"
            out[#out + 1] = integerToken(value)
        else
            out[#out + 1] = "R"
            out[#out + 1] = string.format("%.17g", value)
        end
        return true
    elseif t == "string" then
        out[#out + 1] = "S"
        out[#out + 1] = value
        return true
    elseif t == "table" then
        local array, n = isArray(value)
        if array then
            out[#out + 1] = "L"
            out[#out + 1] = integerToken(n)
            for i = 1, n do
                local ok, why = encodeInto(value[i], out, depth + 1)
                if not ok then return false, why end
            end
            return true
        end
        local keys = {}
        for k in pairs(value) do
            if type(k) ~= "string" then return false, "NON_STRING_KEY" end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        out[#out + 1] = "M"
        out[#out + 1] = integerToken(#keys)
        for _, k in ipairs(keys) do
            out[#out + 1] = k
            local ok, why = encodeInto(value[k], out, depth + 1)
            if not ok then return false, why end
        end
        return true
    end
    return false, "UNSUPPORTED_TYPE"
end

--- Encode a value tree. Returns the token array or nil, reason.
function V.encode(value)
    local out = { V.FORMAT, V.VERSION }
    local ok, why = encodeInto(value, out, 0)
    if not ok then return nil, why end
    return out
end

--- Encode without the format prefix (for nested canonical keys and witness
--- fingerprints that are embedded in a larger record).
function V.encodeBare(value)
    local out = {}
    local ok, why = encodeInto(value, out, 0)
    if not ok then return nil, why end
    return out
end

local function parseCount(token, remaining)
    if type(token) ~= "string" or token:find("^%d+$") == nil or #token > 15 then return nil end
    local n = tonumber(token)
    if n == nil or n > remaining then return nil end
    return n
end

local function parseIntegerToken(token)
    if type(token) ~= "string" or token:find("^%-?%d+$") == nil or #token > 17 then return nil end
    if token ~= "0" and token:find("^%-?0") ~= nil then return nil end
    local n = tonumber(token)
    if n == nil or not isInteger(n) then return nil end
    return n
end
V.parseIntegerToken = parseIntegerToken

local function parseRealToken(token)
    if type(token) ~= "string" or token == "" or #token > 32 then return nil end
    if token:find("^[%-%d%.eE%+]+$") == nil then return nil end
    local n = tonumber(token)
    if n == nil or not isFinite(n) then return nil end
    return n
end
V.parseRealToken = parseRealToken

local function decodeAt(tokens, i, depth)
    if depth > V.MAX_DEPTH then return nil, i, "DEPTH" end
    local tag = tokens[i]
    if tag == "N" then return nil, i + 1, nil, true
    elseif tag == "B" then
        local b = tokens[i + 1]
        if b == "1" then return true, i + 2 elseif b == "0" then return false, i + 2 end
        return nil, i, "BAD_BOOL"
    elseif tag == "I" then
        local n = parseIntegerToken(tokens[i + 1])
        if n == nil then return nil, i, "BAD_INTEGER" end
        return n, i + 2
    elseif tag == "R" then
        local n = parseRealToken(tokens[i + 1])
        if n == nil then return nil, i, "BAD_REAL" end
        return n, i + 2
    elseif tag == "S" then
        local s = tokens[i + 1]
        if type(s) ~= "string" then return nil, i, "BAD_STRING" end
        return s, i + 2
    elseif tag == "L" then
        local n = parseCount(tokens[i + 1], #tokens - (i + 1))
        if n == nil then return nil, i, "BAD_COUNT" end
        local list = {}
        local pos = i + 2
        for k = 1, n do
            local v, nextPos, why = decodeAt(tokens, pos, depth + 1)
            if why ~= nil then return nil, pos, why end
            list[k] = v
            pos = nextPos
        end
        return list, pos
    elseif tag == "M" then
        local n = parseCount(tokens[i + 1], #tokens - (i + 1))
        if n == nil then return nil, i, "BAD_COUNT" end
        local map = {}
        local pos = i + 2
        local lastKey = nil
        for _ = 1, n do
            local key = tokens[pos]
            if type(key) ~= "string" then return nil, pos, "BAD_KEY" end
            if lastKey ~= nil and not (lastKey < key) then return nil, pos, (lastKey == key) and "DUPLICATE_KEY" or "UNSORTED_KEY" end
            lastKey = key
            local v, nextPos, why, present = decodeAt(tokens, pos + 1, depth + 1)
            if why ~= nil then return nil, pos, why end
            if not present or v ~= nil then map[key] = v end
            pos = nextPos
        end
        return map, pos
    end
    return nil, i, "UNKNOWN_TAG"
end

--- Decode a prefixed token array. Returns value, nil on success (a decoded
--- absent value is nil with no reason); nil, reason on refusal.
function V.decode(tokens)
    if type(tokens) ~= "table" then return nil, "NOT_ARRAY" end
    local n = #tokens
    if n < 3 or n > V.MAX_TOKENS then return nil, "BAD_LENGTH" end
    if tokens[1] ~= V.FORMAT or tokens[2] ~= V.VERSION then return nil, "UNSUPPORTED_FORMAT" end
    local value, pos, why = decodeAt(tokens, 3, 0)
    if why ~= nil then return nil, why end
    if pos ~= n + 1 then return nil, "TRAILING_TOKENS" end
    return value, nil
end

--- Decode a bare token array (no prefix), starting at index 1.
function V.decodeBare(tokens)
    if type(tokens) ~= "table" or #tokens == 0 then return nil, "BAD_LENGTH" end
    local value, pos, why = decodeAt(tokens, 1, 0)
    if why ~= nil then return nil, why end
    if pos ~= #tokens + 1 then return nil, "TRAILING_TOKENS" end
    return value, nil
end

--- Whether every element is a string token (the transport precondition).
function V.isTokenArray(tokens)
    if type(tokens) ~= "table" then return false end
    for i = 1, #tokens do
        if type(tokens[i]) ~= "string" then return false end
    end
    return true
end

--- Lossless correlation string: byte length, colon, bytes, per token.
function V.selectionKey(tokens)
    if type(tokens) ~= "table" then return nil end
    local parts = {}
    for i = 1, #tokens do
        local t = tokens[i]
        if type(t) ~= "string" then return nil end
        parts[#parts + 1] = tostring(#t) .. ":" .. t
    end
    return table.concat(parts)
end

--- Canonical string key of a value tree (for CarrierKey map keys).
function V.canonicalKey(value)
    local tokens = V.encodeBare(value)
    if tokens == nil then return nil end
    return V.selectionKey(tokens)
end

--- Deep copy a value tree (tables only; functions and userdata refuse).
function V.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = V.copy(v) end
    return out
end

--- Structural equality of two value trees.
function V.equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not V.equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Canonical positive decimal counters (no float arithmetic, no wrap).
function V.isCanonicalDecimal(s)
    return type(s) == "string" and s:find("^[1-9]%d*$") ~= nil
end

function V.incrementDecimal(s)
    if s == nil or s == "" or s == "0" then return "1" end
    if not V.isCanonicalDecimal(s) then return nil end
    local digits = {}
    for i = 1, #s do digits[i] = s:byte(i) - 48 end
    local i = #digits
    while i >= 1 do
        if digits[i] < 9 then
            digits[i] = digits[i] + 1
            for j = i + 1, #digits do digits[j] = 0 end
            local out = {}
            for j = 1, #digits do out[j] = string.char(digits[j] + 48) end
            return table.concat(out)
        end
        i = i - 1
    end
    local out = { "1" }
    for _ = 1, #digits do out[#out + 1] = "0" end
    return table.concat(out)
end

--- Compare canonical decimals: byte length first, then lexical bytes.
function V.compareDecimal(a, b)
    if #a ~= #b then return #a < #b and -1 or 1 end
    if a == b then return 0 end
    return a < b and -1 or 1
end

--- Bounded UTF-8 check for identifiers: 1..maxBytes bytes, no control chars.
function V.isIdentifier(s, maxBytes)
    if type(s) ~= "string" or s == "" or #s > (maxBytes or 128) then return false end
    if s:find("[%z\1-\31\127]") ~= nil then return false end
    return true
end
