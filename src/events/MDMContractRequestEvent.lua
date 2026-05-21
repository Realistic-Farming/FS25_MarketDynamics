-- MDMContractRequestEvent.lua
-- Client-to-Server network event for contract actions (Create, Complete, Cancel, Delete).

MDMContractRequestEvent = {}
local MDMContractRequestEvent_mt = Class(MDMContractRequestEvent, Event)
InitEventClass(MDMContractRequestEvent, "MDMContractRequestEvent")

MDMContractRequestEvent.ACTION_CREATE = 1
MDMContractRequestEvent.ACTION_ADMIN_COMPLETE = 2
MDMContractRequestEvent.ACTION_ADMIN_CANCEL = 3
MDMContractRequestEvent.ACTION_ADMIN_DELETE = 4
MDMContractRequestEvent.ACTION_PLAYER_FORFEIT = 5

function MDMContractRequestEvent.emptyNew()
    return Event.new(MDMContractRequestEvent_mt)
end

function MDMContractRequestEvent.new(action, params)
    local self = MDMContractRequestEvent.emptyNew()
    self.action = action
    self.params = params or {}
    return self
end

function MDMContractRequestEvent.sendToServer(action, params)
    if g_server ~= nil then
        MDMContractRequestEvent.execute(action, params)
    else
        g_client:getServerConnection():sendEvent(MDMContractRequestEvent.new(action, params))
    end
end

function MDMContractRequestEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    if self.action == MDMContractRequestEvent.ACTION_CREATE then
        streamWriteInt32(streamId, self.params.farmId)
        streamWriteInt32(streamId, self.params.fillTypeIndex)
        streamWriteString(streamId, self.params.fillTypeName)
        streamWriteFloat32(streamId, self.params.quantity)
        streamWriteFloat32(streamId, self.params.lockedPrice)
        streamWriteFloat64(streamId, self.params.deliveryTimeMs)
        streamWriteBool(streamId, self.params.isRealDays or false)
        streamWriteFloat32(streamId, self.params.createdTimeScale or 1)
    else
        streamWriteInt32(streamId, self.params.contractId)
    end
end

function MDMContractRequestEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.params = {}
    if self.action == MDMContractRequestEvent.ACTION_CREATE then
        self.params.farmId           = streamReadInt32(streamId)
        self.params.fillTypeIndex    = streamReadInt32(streamId)
        self.params.fillTypeName     = streamReadString(streamId)
        self.params.quantity         = streamReadFloat32(streamId)
        self.params.lockedPrice      = streamReadFloat32(streamId)
        self.params.deliveryTimeMs   = streamReadFloat64(streamId)
        self.params.isRealDays       = streamReadBool(streamId)
        self.params.createdTimeScale = streamReadFloat32(streamId)
    else
        self.params.contractId = streamReadInt32(streamId)
    end
    self:run(connection)
end

function MDMContractRequestEvent.execute(action, params)
    if not g_MarketDynamics or not g_MarketDynamics.futuresMarket then return end
    local fm = g_MarketDynamics.futuresMarket

    if action == MDMContractRequestEvent.ACTION_CREATE then
        fm:createContract(params)
    elseif action == MDMContractRequestEvent.ACTION_ADMIN_COMPLETE then
        fm:adminComplete(params.contractId)
    elseif action == MDMContractRequestEvent.ACTION_ADMIN_CANCEL then
        fm:adminCancel(params.contractId)
    elseif action == MDMContractRequestEvent.ACTION_ADMIN_DELETE then
        fm:adminDelete(params.contractId)
    elseif action == MDMContractRequestEvent.ACTION_PLAYER_FORFEIT then
        fm:playerForfeit(params.contractId)
    end
end

function MDMContractRequestEvent:run(connection)
    if connection:getIsServer() then return end

    local ok, err = pcall(function()
        local userId = g_currentMission.userManager:getUserIdByConnection(connection)
        local farm = userId ~= nil and g_farmManager:getFarmByUserId(userId) or nil
        local isFarmManager = farm ~= nil and farm:isUserFarmManager(userId)
        local user = userId ~= nil and g_currentMission.userManager:getUserByUserId(userId) or nil
        local isAdmin = user ~= nil and (user.isMasterUser == true or user.isAdmin == true)

        if self.action == MDMContractRequestEvent.ACTION_CREATE then
            -- Security: Non-farm-managers can only create contracts for their own farm
            if not isAdmin and not isFarmManager then
                if farm == nil or self.params.farmId ~= farm.farmId then
                    MDMLog.warn("MDMContractRequestEvent: unauthorized CREATE from userId=" .. tostring(userId)
                        .. " farmId=" .. tostring(self.params.farmId))
                    return
                end
            end
        else
            -- Security: Action on existing contract.
            -- Allow if user is Admin OR Farm Manager OR the contract belongs to their farm.
            local fm = g_MarketDynamics and g_MarketDynamics.futuresMarket
            local contract = fm and fm.contracts and fm.contracts[self.params.contractId]
            local isOwner = contract ~= nil and farm ~= nil and contract.farmId == farm.farmId

            if not isAdmin and not isFarmManager and not isOwner then
                MDMLog.warn("MDMContractRequestEvent: unauthorized action " .. tostring(self.action)
                    .. " from userId=" .. tostring(userId))
                return
            end
        end

        MDMContractRequestEvent.execute(self.action, self.params)
    end)

    if not ok then
        MDMLog.error("MDMContractRequestEvent:run error: " .. tostring(err))
    end
end
