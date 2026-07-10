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

MDMNetworkSyncBridge.active = false
MDMNetworkSyncBridge._ns    = nil

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

-- Register the action handler with NetworkSync if present. adminOnly = false because
-- the fine-grained farm-manager / owner rules live in onAction, not a blanket admin gate.
function MDMNetworkSyncBridge.register(mdm)
    MDMNetworkSyncBridge.active = false
    MDMNetworkSyncBridge._ns    = nil

    local ns = (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
    if ns == nil then
        MDMLog.info("Market Dynamics: NetworkSync not detected; contract actions use their own event")
        return
    end

    local ok, err = pcall(function()
        ns:registerAction(MDMNetworkSyncBridge.ACTION_ID, {
            adminOnly = false,
            onAction  = onAction,
        })
    end)

    if ok then
        MDMNetworkSyncBridge.active = true
        MDMNetworkSyncBridge._ns    = ns
        MDMLog.info("Market Dynamics: contract action channel registered with NetworkSync")
    else
        MDMLog.error("Market Dynamics: NetworkSync registration failed: " .. tostring(err))
    end
end
