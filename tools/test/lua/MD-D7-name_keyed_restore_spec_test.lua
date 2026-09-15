--!load: src/MarketSerializer.lua, src/MarketEngine.lua, src/FuturesMarket.lua, src/MDMHUD.lua
-- D7 (2026-09-15): saved prices and futures contracts are restored by fill
-- type NAME, not by the raw fill type index, because the index shifts with the
-- selected mod set. Runs the real MarketSerializer toTable/applyTable (the
-- StateLedger block) and save/load (the own XML) against a fake registry that
-- moves WHEAT from index 3 to index 5 between sessions, plus the legacy
-- (name-less) and unknown-name cases. Logic evidence only: no native XML, no
-- real fill type manager, no gameplay.

MDMUtil = { getGameTime = function() return 1000 end, getMonotonicTime = function() return 1000 end }
UPIntegration = UPIntegration or { save = function() end, load = function() end }
local logged = {}
MDMLog = { info = function(m) logged[#logged + 1] = "I:" .. tostring(m) end, warn = function(m) logged[#logged + 1] = "W:" .. tostring(m) end,
           debug = function() end, error = function(m) logged[#logged + 1] = "E:" .. tostring(m) end }
local function anyLog(sub) for _, l in ipairs(logged) do if l:find(sub, 1, true) then return true end end return false end
local function countLog(sub) local n = 0 for _, l in ipairs(logged) do if l:find(sub, 1, true) then n = n + 1 end end return n end

-- A fake registry: names by index and the reverse map (upper-cased like the engine).
local function registry(names)
    local byName = {}
    for i, n in pairs(names) do byName[string.upper(n)] = i end
    return { getFillTypeNameByIndex = function(_, i) return names[i] end,
             getFillTypeIndexByName = function(_, n) if n == nil then return nil end return byName[string.upper(n)] end }
end
local SESSION_A = { [2] = "BARLEY", [3] = "WHEAT", [4] = "CANOLA" }
local SESSION_B = { [2] = "BARLEY", [3] = "SORGHUM", [4] = "CANOLA", [5] = "WHEAT" }   -- a new mod pushed WHEAT to 5

local function engineFor(names)
    local e = MarketEngine.new()
    for i in pairs(names) do
        e.prices[i] = { base = 100, current = 100, volatilityFactor = 1, modifiers = {}, history = {} }
    end
    function e:_recalculate(index) local entry = self.prices[index] entry.current = entry.base * entry.volatilityFactor end
    return e
end
local function coordinatorFor(names)
    return { marketEngine = engineFor(names), futuresMarket = { contracts = {}, nextId = 1 }, worldEvents = { registry = {}, active = {} }, settings = {} }
end

-- (A) resolveSavedFillType.
do
    g_fillTypeManager = registry(SESSION_B)
    local r = MarketSerializer.resolveSavedFillType
    T.eq("A1 a saved name resolves to the current index", select(1, r("WHEAT", 3)), 5)
    T.eq("A2 resolved how", select(2, r("WHEAT", 3)), "name")
    T.eq("A3 lower-case saved name resolves", select(1, r("wheat", 3)), 5)
    T.eq("A4 unknown name yields nil", select(1, r("GOLD", 3)), nil)
    T.eq("A5 unknown how", select(2, r("GOLD", 3)), "unknown")
    T.eq("A6 no name keeps the saved index", select(1, r(nil, 3)), 3)
    T.eq("A7 legacy how", select(2, r(nil, 3)), "legacy")
    T.eq("A8 empty name is legacy", select(2, r("", 3)), "legacy")
    g_fillTypeManager = nil
    T.eq("A9 without a registry a named row is unknown", select(2, r("WHEAT", 3)), "unknown")
end

-- (B) The ledger block carries names and restores by them across a shifted registry.
do
    logged = {}
    g_fillTypeManager = registry(SESSION_A)
    local a = coordinatorFor(SESSION_A)
    a.marketEngine.prices[3].current = 123
    a.marketEngine.prices[3].volatilityFactor = 1.23
    a.marketEngine.prices[3].history = { { price = 120, time = 1 } }
    a.futuresMarket.contracts[7] = { id = 7, farmId = 1, fillTypeIndex = 3, fillTypeName = "WHEAT", quantity = 5000, lockedPrice = 1.1, deliveryTime = 9000, status = "active" }
    local block = MarketSerializer:toTable(a)
    local wheatRow
    for _, p in ipairs(block.prices) do if p.index == 3 then wheatRow = p end end
    T.eq("B1 the ledger price row carries the name", wheatRow.fillTypeName, "WHEAT")
    T.eq("B2 the contract carries its name", block.contracts[1].fillTypeName, "WHEAT")

    -- Next session: WHEAT is index 5, SORGHUM took index 3.
    g_fillTypeManager = registry(SESSION_B)
    local b = coordinatorFor(SESSION_B)
    T.eq("B3 applied", MarketSerializer:applyTable(b, block), true)
    T.eq("B4 WHEAT's price landed on its new index", b.marketEngine.prices[5].volatilityFactor, 1.23)
    T.eq("B5 with its history", #b.marketEngine.prices[5].history, 1)
    T.eq("B6 SORGHUM at the old index is untouched", b.marketEngine.prices[3].volatilityFactor, 1)
    T.eq("B7 the contract follows the name", b.futuresMarket.contracts[7].fillTypeIndex, 5)
    T.eq("B8 the contract keeps its name", b.futuresMarket.contracts[7].fillTypeName, "WHEAT")
    T.ok("B9 the move is logged", anyLog("moved from index 3 to 5"))
    T.ok("B10 no legacy warning for a named block", not anyLog("legacy save"))
end

-- (C) Legacy block without names: index behaviour, logged once.
do
    logged = {}
    g_fillTypeManager = registry(SESSION_B)
    local b = coordinatorFor(SESSION_B)
    local legacy = { version = 2, lastGameTime = 5,
        prices = { { index = 3, current = 77, volatilityFactor = 1.5, history = {} }, { index = 4, current = 80, volatilityFactor = 1.2, history = {} } },
        contracts = { { id = 1, farmId = 1, fillTypeIndex = 3, quantity = 1, lockedPrice = 1, deliveryTime = 9000 } },
        eventCooldowns = {} }
    MarketSerializer:applyTable(b, legacy)
    T.eq("C1 legacy price row applied by index", b.marketEngine.prices[3].volatilityFactor, 1.5)
    T.eq("C2 legacy contract keeps its index", b.futuresMarket.contracts[1].fillTypeIndex, 3)
    T.eq("C3 the contract gets the current name of that index", b.futuresMarket.contracts[1].fillTypeName, "SORGHUM")
    T.eq("C4 legacy restore logged once", countLog("legacy save without fill type names"), 1)
    T.ok("C5 the log counts rows and contracts", anyLog("2 price row(s) and 1 contract(s)"))
end

-- (D) Unknown names: a price row is skipped, a contract is kept on its saved index, both logged.
do
    logged = {}
    g_fillTypeManager = registry(SESSION_B)
    local b = coordinatorFor(SESSION_B)
    local block = { version = 3, lastGameTime = 5,
        prices = { { index = 3, fillTypeName = "GOLD", current = 999, volatilityFactor = 9, history = {} } },
        contracts = { { id = 2, farmId = 1, fillTypeIndex = 3, fillTypeName = "GOLD", quantity = 1, lockedPrice = 1, deliveryTime = 9000 } },
        eventCooldowns = {} }
    MarketSerializer:applyTable(b, block)
    T.eq("D1 an unknown product's price row never lands on the index's current occupant", b.marketEngine.prices[3].volatilityFactor, 1)
    T.ok("D2 the skip is logged", anyLog("not registered in this session; row skipped"))
    T.eq("D3 the contract is kept", b.futuresMarket.contracts[2] ~= nil, true)
    T.eq("D4 with an unresolved index, never the saved one", b.futuresMarket.contracts[2].fillTypeIndex, nil)
    T.eq("D5 with its saved name", b.futuresMarket.contracts[2].fillTypeName, "GOLD")
    T.ok("D6 the kept contract is logged as unresolved", anyLog("kept unresolved"))
    T.ok("D7 no legacy warning", not anyLog("legacy save"))
    -- No delivery of the product now at the old index can match the unresolved contract.
    local fm = FuturesMarket.new()
    fm.contracts = b.futuresMarket.contracts
    local c = fm.contracts[2]
    c.status = "active"; c.delivered = 0; c.deliveryStartTime = 0
    g_server = nil
    fm:onCropDelivered(1, 3, 500, 1.0)
    T.eq("D8 a delivery of the product now at the old index does not count toward the unresolved contract", c.delivered, 0)
    T.eq("D9 the contract stays active for its normal expiry rules", c.status, "active")
    -- The HUD reads the fill type through a nil-safe helper and still has the saved name for the title.
    g_fillTypeManager.getFillTypeByIndex = function(_, i) return { index = i, hudOverlayFilename = "x" } end
    T.eq("D10 HUD fill type lookup is nil for an unresolved contract", MDMHUD.contractFillType(c), nil)
    T.eq("D11 the HUD title still has the saved name", c.fillTypeName:upper(), "GOLD")
    T.eq("D12 a resolved contract still yields its fill type", MDMHUD.contractFillType({ fillTypeIndex = 5 }).index, 5)
end

-- (E) The own XML: save writes the name, load restores by it.
local function fakeXML(store)
    store = store or {}
    local x = { store = store }
    function x:setInt(k, v) store[k] = v end
    function x:setFloat(k, v) store[k] = v end
    function x:setString(k, v) store[k] = v end
    function x:setBool(k, v) store[k] = v end
    function x:getInt(k) return store[k] end
    function x:getFloat(k) return store[k] end
    function x:getString(k) local v = store[k] if v == nil then return nil end return tostring(v) end
    function x:getBool(k) return store[k] end
    function x:hasProperty(k)
        for key in pairs(store) do if key == k or key:sub(1, #k + 1) == k .. "#" or key:sub(1, #k + 1) == k .. "." then return true end end
        return false
    end
    function x:save() end
    function x:delete() end
    return x
end
do
    logged = {}
    g_fillTypeManager = registry(SESSION_A)
    g_currentMission = { missionInfo = { savegameDirectory = "save" } }
    getUserProfileAppPath = function() return "profile/" end
    fileExists = function() return true end
    local captured
    XMLFile = { create = function(_, _, _) captured = fakeXML() return captured end, load = function() return captured end }
    local a = coordinatorFor(SESSION_A)
    a.marketEngine.prices[3].volatilityFactor = 1.33
    a.futuresMarket.contracts[9] = { id = 9, farmId = 1, fillTypeIndex = 3, fillTypeName = "WHEAT", quantity = 10, lockedPrice = 2, deliveryTime = 9000 }
    MarketSerializer:save(a)
    local wheatKey
    for k, v in pairs(captured.store) do if k:find("prices.price%(%d+%)#index$") and v == 3 then wheatKey = k:gsub("#index$", "") end end
    T.ok("E1 a price row was written", wheatKey ~= nil)
    T.eq("E2 the row carries the fill type name", captured.store[wheatKey .. "#fillTypeName"], "WHEAT")

    g_fillTypeManager = registry(SESSION_B)
    local b = coordinatorFor(SESSION_B)
    MarketSerializer:load(b)
    T.eq("E3 the XML price row restores by name onto index 5", b.marketEngine.prices[5].volatilityFactor, 1.33)
    T.eq("E4 index 3's new occupant untouched", b.marketEngine.prices[3].volatilityFactor, 1)
    T.eq("E5 the XML contract follows the name", b.futuresMarket.contracts[9].fillTypeIndex, 5)
    T.ok("E6 no legacy warning for a named file", not anyLog("legacy save"))

    -- A legacy file (no names) restores by index and says so.
    logged = {}
    captured = fakeXML({
        ["marketDynamics#version"] = "2", ["marketDynamics#lastGameTime"] = "5",
        ["marketDynamics.prices.price(0)#index"] = 3, ["marketDynamics.prices.price(0)#current"] = 50, ["marketDynamics.prices.price(0)#volatilityFactor"] = 1.7,
        ["marketDynamics.futures.contract(0)#id"] = 4, ["marketDynamics.futures.contract(0)#farmId"] = 1, ["marketDynamics.futures.contract(0)#fillTypeIndex"] = 3,
        ["marketDynamics.futures.contract(0)#quantity"] = 1, ["marketDynamics.futures.contract(0)#lockedPrice"] = 1, ["marketDynamics.futures.contract(0)#deliveryTime"] = "9000",
    })
    local c = coordinatorFor(SESSION_B)
    MarketSerializer:load(c)
    T.eq("E7 legacy XML price row by index", c.marketEngine.prices[3].volatilityFactor, 1.7)
    T.eq("E8 legacy XML contract by index", c.futuresMarket.contracts[4].fillTypeIndex, 3)
    T.eq("E9 legacy XML logged once", countLog("legacy save without fill type names"), 1)
    g_currentMission = nil
end
