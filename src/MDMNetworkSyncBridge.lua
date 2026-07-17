-- =========================================================
-- FS25 Market Dynamics - NetworkSync bridge (Phase 2)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_NetworkSync. Routes the one client-initiated write, the
-- contract action (create / admin complete-cancel-delete / player forfeit), through
-- NetworkSync's server-authoritative action channel (Path 3) when NetworkSync is
-- present. Delegate-when-present:
--   * NetworkSync installed -> MDMContractRequestEvent.sendToServer forwards the action
--     as an NS requestAction; the server runs the SAME authorization as the own event
--     (anti-spoof farmId check, farm-manager / owner / admin rules) inside onAction and
--     then calls the identical MDMContractRequestEvent.execute.
--   * NetworkSync absent    -> the own MDMContractRequestEvent carries the action exactly
--     as before.
--
-- Scope note: this bridges the ACTION path only. The server->client STATE broadcasts
-- (MDMContractSyncEvent, MDMMarketSyncEvent) stay on their own hardened events. Those
-- carry side-effect-rich run() logic (world-event lifecycle, client notifications, UI
-- rebuilds) plus the #93/#82/#51 stream-corruption fixes, so migrating them is a
-- separate careful pass, not a mechanical swap. The action path is unaffected by that:
-- after execute() the server still broadcasts state via the own events exactly as before,
-- so client state stays correct on either transport.
--
-- Why the userId matches: NS resolves onAction's userId as
-- userManager:getUserByConnection(connection):getId(), the same id the own event derives
-- via getUserIdByConnection(connection). So getFarmByUserId / getUserByUserId behave
-- identically. A local host requestAction passes userId = nil (implicitly authorized),
-- mirroring the own event's "g_server present -> execute directly" host path.
--
-- The action id is transport, not persistence, so a rename cannot orphan saved data
-- (server and client always run the same registerAction / requestAction call).
-- =========================================================

MDMNetworkSyncBridge = {}

MDMNetworkSyncBridge.ACTION_ID = "MarketDynamics_Contract"

-- State-sync module (the deferred half, now built): a single FULL-snapshot module that
-- carries the whole syncable state - all futures contracts + market price volatility +
-- active world events - server->client. On any change the server marks it dirty and
-- NetworkSync sends the full snapshot at its next batch (NS chunks a large payload). The
-- registerModule id + channel are pre-reserved (Point-2: id FS25_MarketDynamics, channel
-- MarketDynamics_Sync). NetworkSync is transport, not a save key.
MDMNetworkSyncBridge.STATE_MODULE_ID = "FS25_MarketDynamics"
MDMNetworkSyncBridge.STATE_CHANNEL   = "MarketDynamics_Sync"

MDMNetworkSyncBridge.active      = false   -- action channel registered
MDMNetworkSyncBridge.stateActive = false   -- state-sync module registered
MDMNetworkSyncBridge._ns         = nil

-- Flatten contract params into a typed arg array (NetworkSync type-tags each value).
-- Mirrors MDMContractRequestEvent:writeStream field-for-field; index 1 is the action.
local function encodeArgs(action, params)
    local a = { action }
    if action == MDMContractRequestEvent.ACTION_CREATE then
        a[2] = params.farmId
        a[3] = params.fillTypeIndex
        a[4] = tostring(params.fillTypeName or "")
        a[5] = params.quantity
        a[6] = params.lockedPrice
        a[7] = math.floor((params.deliveryTimeMs or 0) / 1000)
        a[8] = params.isRealDays or false
        a[9] = params.createdTimeScale or 1
    else
        a[2] = params.contractId
    end
    return a
end

-- Rebuild the params table on the server. Twin of MDMContractRequestEvent:readStream.
local function decodeArgs(args)
    local action = args[1]
    local params = {}
    if action == MDMContractRequestEvent.ACTION_CREATE then
        params.farmId           = args[2]
        params.fillTypeIndex    = args[3]
        params.fillTypeName     = args[4]
        params.quantity         = args[5]
        params.lockedPrice      = args[6]
        params.deliveryTimeMs   = (args[7] or 0) * 1000
        params.isRealDays       = args[8]
        params.createdTimeScale = args[9]
    else
        params.contractId = args[2]
    end
    return action, params
end

-- Server-side handler. Ports MDMContractRequestEvent:run authorization exactly, starting
-- from the NS-resolved userId (nil = local host, implicitly authorized).
local function onAction(userId, args)
    if type(args) ~= "table" then return end
    local action, params = decodeArgs(args)

    if userId == nil then
        -- Local host: trusted, execute directly (mirrors the own event's host path).
        MDMContractRequestEvent.execute(action, params)
        return
    end

    local ok, err = pcall(function()
        local farm          = g_farmManager:getFarmByUserId(userId)
        local isFarmManager = farm ~= nil and farm:isUserFarmManager(userId)
        local user          = g_currentMission.userManager:getUserByUserId(userId)
        local isAdmin       = user ~= nil and (user.isMasterUser == true or user.isAdmin == true)

        if action == MDMContractRequestEvent.ACTION_CREATE then
            -- Security: non-farm-managers can only create contracts for their own farm.
            if not isAdmin and not isFarmManager then
                if farm == nil or params.farmId ~= farm.farmId then
                    MDMLog.warn("MDMNetworkSyncBridge: unauthorized CREATE from userId=" .. tostring(userId)
                        .. " farmId=" .. tostring(params.farmId))
                    return
                end
            end
        else
            -- Security: action on an existing contract. Admin OR farm manager OR owner.
            local fm       = g_MarketDynamics and g_MarketDynamics.futuresMarket
            local contract = fm and fm.contracts and fm.contracts[params.contractId]
            local isOwner  = contract ~= nil and farm ~= nil and contract.farmId == farm.farmId
            if not isAdmin and not isFarmManager and not isOwner then
                MDMLog.warn("MDMNetworkSyncBridge: unauthorized action " .. tostring(action)
                    .. " from userId=" .. tostring(userId))
                return
            end
        end

        MDMContractRequestEvent.execute(action, params)
    end)

    if not ok then
        MDMLog.error("MDMNetworkSyncBridge onAction error: " .. tostring(err))
    end
end

-- Try to route a contract action through NetworkSync. Returns true when it did (so the
-- caller skips the own event). On the local host, execute directly with the full-precision
-- params (no encode round-trip), matching the own event's host path exactly.
function MDMNetworkSyncBridge.trySendAction(action, params)
    if not MDMNetworkSyncBridge.active or MDMNetworkSyncBridge._ns == nil then
        return false
    end
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        MDMContractRequestEvent.execute(action, params)
    else
        MDMNetworkSyncBridge._ns:requestAction(MDMNetworkSyncBridge.ACTION_ID, encodeArgs(action, params))
    end
    return true
end

-- ── State-sync serialization (server->client full snapshot) ───────────────────
-- Flatten the whole syncable state into one typed array. Length-prefixed sub-lists so
-- NetworkSync's flat, type-tagged array round-trips: contractCount, then 12 fields per
-- contract (mirroring MDMContractSyncEvent:writeContract); priceCount, then 2 per price;
-- eventCount, then 4 per active event.
local function buildStateArray()
    local arr = {}
    local mdm = g_MarketDynamics
    local fm  = mdm ~= nil and mdm.futuresMarket or nil

    local contracts = (fm ~= nil and fm.contracts) or {}
    local cCount = 0
    for _ in pairs(contracts) do cCount = cCount + 1 end
    arr[#arr + 1] = cCount
    for _, c in pairs(contracts) do
        arr[#arr + 1] = c.id or 0
        arr[#arr + 1] = c.farmId or 0
        arr[#arr + 1] = c.fillTypeIndex or 0
        arr[#arr + 1] = tostring(c.fillTypeName or "")
        arr[#arr + 1] = c.quantity or 0
        arr[#arr + 1] = c.lockedPrice or 0
        arr[#arr + 1] = math.floor((c.deliveryTime or 0) / 1000)
        arr[#arr + 1] = math.floor((c.deliveryStartTime or 0) / 1000)
        arr[#arr + 1] = c.bcManaged == true
        arr[#arr + 1] = c.delivered or 0
        arr[#arr + 1] = c.valueReceived or 0
        arr[#arr + 1] = tostring(c.status or "")
    end

    -- Market prices + active events: reuse MDMMarketSyncEvent.new's capture exactly.
    local prices, events = {}, {}
    if mdm ~= nil then
        local snap = MDMMarketSyncEvent.new(mdm.marketEngine, mdm.worldEvents)
        prices = snap.prices or {}
        events = snap.activeEvents or {}
    end
    arr[#arr + 1] = #prices
    for _, p in ipairs(prices) do
        arr[#arr + 1] = p.index or 0
        arr[#arr + 1] = p.volatilityFactor or 1
    end
    arr[#arr + 1] = #events
    for _, e in ipairs(events) do
        arr[#arr + 1] = tostring(e.id or "")
        arr[#arr + 1] = e.endsAt or 0
        arr[#arr + 1] = e.intensity or 0
        arr[#arr + 1] = tostring(e.extraData or "")
    end
    return arr
end

-- Client: rebuild the state from the array and apply it through the SAME hardened paths
-- the own events use - MDMContractSyncEvent.execute (full contract rebuild + UI reload) and
-- MDMMarketSyncEvent.applyState (prices / event lifecycle / notifications / UI).
local function applyStateArray(arr)
    if type(arr) ~= "table" then return end
    local i = 1

    local cCount = tonumber(arr[i]) or 0; i = i + 1
    local contracts = {}
    for _ = 1, cCount do
        contracts[#contracts + 1] = {
            id                = arr[i],
            farmId            = arr[i + 1],
            fillTypeIndex     = arr[i + 2],
            fillTypeName      = arr[i + 3],
            quantity          = arr[i + 4],
            lockedPrice       = arr[i + 5],
            deliveryTime      = (tonumber(arr[i + 6]) or 0) * 1000,
            deliveryStartTime = (tonumber(arr[i + 7]) or 0) * 1000,
            bcManaged         = arr[i + 8],
            delivered         = arr[i + 9],
            valueReceived     = arr[i + 10],
            status            = arr[i + 11],
        }
        i = i + 12
    end

    local pCount = tonumber(arr[i]) or 0; i = i + 1
    local prices = {}
    for _ = 1, pCount do
        prices[#prices + 1] = { index = arr[i], volatilityFactor = arr[i + 1] }
        i = i + 2
    end

    local eCount = tonumber(arr[i]) or 0; i = i + 1
    local events = {}
    for _ = 1, eCount do
        events[#events + 1] = { id = arr[i], endsAt = arr[i + 1], intensity = arr[i + 2], extraData = arr[i + 3] }
        i = i + 4
    end

    MDMContractSyncEvent.execute(MDMContractSyncEvent.SYNC_FULL, contracts)
    MDMMarketSyncEvent.applyState(prices, events)
end

-- Server: mark the state module dirty so NetworkSync resyncs the full snapshot at its next
-- batch. Returns true when it handled it (so the caller skips the own broadcast event).
function MDMNetworkSyncBridge.markStateDirty()
    if not MDMNetworkSyncBridge.stateActive or MDMNetworkSyncBridge._ns == nil then
        return false
    end
    MDMNetworkSyncBridge._ns:markDirty(MDMNetworkSyncBridge.STATE_MODULE_ID)
    return true
end

-- Register the action handler + the state-sync module with NetworkSync if present.
-- adminOnly = false on the action because the fine-grained farm-manager / owner rules live
-- in onAction, not a blanket admin gate.
function MDMNetworkSyncBridge.register(mdm)
    MDMNetworkSyncBridge.active      = false
    MDMNetworkSyncBridge.stateActive = false
    MDMNetworkSyncBridge._ns         = nil

    local ns = (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
    if ns == nil then
        MDMLog.info("Market Dynamics: NetworkSync not detected; contract actions + state use their own events")
        return
    end

    local ok, err = pcall(function()
        ns:registerAction(MDMNetworkSyncBridge.ACTION_ID, {
            adminOnly = false,
            onAction  = onAction,
        })
        ns:registerModule(MDMNetworkSyncBridge.STATE_MODULE_ID, {
            channel      = MDMNetworkSyncBridge.STATE_CHANNEL,
            onWriteState = buildStateArray,
            onReadState  = applyStateArray,
        })
    end)

    if ok then
        MDMNetworkSyncBridge.active      = true
        MDMNetworkSyncBridge.stateActive = true
        MDMNetworkSyncBridge._ns         = ns
        MDMLog.info("Market Dynamics: contract action channel + state-sync registered with NetworkSync")
    else
        MDMLog.error("Market Dynamics: NetworkSync registration failed: " .. tostring(err))
    end
end
