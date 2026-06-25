-- MDMSettingsSyncEvent.lua
-- Network event for syncing Market Dynamics settings between server and clients.

MDMSettingsSyncEvent = {}
local MDMSettingsSyncEvent_mt = Class(MDMSettingsSyncEvent, Event)
InitEventClass(MDMSettingsSyncEvent, "MDMSettingsSyncEvent")

function MDMSettingsSyncEvent.emptyNew()
    return Event.new(MDMSettingsSyncEvent_mt)
end

function MDMSettingsSyncEvent.new(settings, volatilityScale)
    local self = MDMSettingsSyncEvent.emptyNew()
    self.settings = settings
    self.volatilityScale = volatilityScale
    return self
end

function MDMSettingsSyncEvent.sendToClients()
    if g_server ~= nil and g_MarketDynamics and g_MarketDynamics.settings then
        local scale = g_MarketDynamics.marketEngine and g_MarketDynamics.marketEngine.volatilityScale or 1.0
        g_server:broadcastEvent(MDMSettingsSyncEvent.new(g_MarketDynamics.settings, scale))
    end
end

function MDMSettingsSyncEvent.sendToClient(connection)
    if g_server ~= nil and connection ~= nil and g_MarketDynamics and g_MarketDynamics.settings then
        local scale = g_MarketDynamics.marketEngine and g_MarketDynamics.marketEngine.volatilityScale or 1.0
        connection:sendEvent(MDMSettingsSyncEvent.new(g_MarketDynamics.settings, scale))
    end
end

function MDMSettingsSyncEvent.sendToServer()
    if g_server == nil and g_MarketDynamics and g_MarketDynamics.settings then
        local scale = g_MarketDynamics.marketEngine and g_MarketDynamics.marketEngine.volatilityScale or 1.0
        g_client:getServerConnection():sendEvent(MDMSettingsSyncEvent.new(g_MarketDynamics.settings, scale))
    end
end

function MDMSettingsSyncEvent:writeStream(streamId, connection)
    local s = self.settings
    streamWriteBool(streamId, s.pricesEnabled ~= false)
    streamWriteBool(streamId, s.debugMode == true)
    streamWriteBool(streamId, s.eventsEnabled ~= false)
    streamWriteFloat32(streamId, s.eventFrequency or 1.0)
    streamWriteFloat32(streamId, s.futuresPenalty or 0.15)
    streamWriteBool(streamId, s.showEventNotifications ~= false)
    streamWriteBool(streamId, s.eventNotificationBanner == true)
    streamWriteBool(streamId, s.showContractHUD ~= false)
    streamWriteBool(streamId, s.useRealDays == true)

    -- Disabled events
    local de = s.disabledEvents or {}
    local deList = {}
    for id, _ in pairs(de) do table.insert(deList, id) end
    streamWriteInt32(streamId, #deList)
    for _, id in ipairs(deList) do
        streamWriteString(streamId, id)
    end

    -- Custom fill types per event
    local cft = s.eventCustomFillTypes or {}
    local eventIds = {}
    for id, list in pairs(cft) do if #list > 0 then table.insert(eventIds, id) end end
    streamWriteInt32(streamId, #eventIds)
    for _, eventId in ipairs(eventIds) do
        streamWriteString(streamId, eventId)
        local list = cft[eventId]
        streamWriteInt32(streamId, #list)
        for _, name in ipairs(list) do
            streamWriteString(streamId, name)
        end
    end

    streamWriteFloat32(streamId, self.volatilityScale or 1.0)
end

function MDMSettingsSyncEvent:readStream(streamId, connection)
    self.settings = {
        pricesEnabled  = streamReadBool(streamId),
        debugMode      = streamReadBool(streamId),
        eventsEnabled  = streamReadBool(streamId),
        eventFrequency = streamReadFloat32(streamId),
        futuresPenalty = streamReadFloat32(streamId),
        showEventNotifications = streamReadBool(streamId),
        eventNotificationBanner = streamReadBool(streamId),
        showContractHUD = streamReadBool(streamId),
        useRealDays = streamReadBool(streamId),
        disabledEvents = {},
        eventCustomFillTypes = {},
    }
    
    local deCount = streamReadInt32(streamId)
    for i = 1, deCount do
        local id = streamReadString(streamId)
        self.settings.disabledEvents[id] = true
    end

    local cftCount = streamReadInt32(streamId)
    for i = 1, cftCount do
        local eventId = streamReadString(streamId)
        self.settings.eventCustomFillTypes[eventId] = {}
        local ftCount = streamReadInt32(streamId)
        for j = 1, ftCount do
            local name = streamReadString(streamId)
            table.insert(self.settings.eventCustomFillTypes[eventId], name)
        end
    end

    self.volatilityScale = streamReadFloat32(streamId)
    self:run(connection)
end

function MDMSettingsSyncEvent:run(connection)
    if not g_MarketDynamics then return end

    if g_server ~= nil and connection ~= nil then
        -- Received on server from a client: update local settings and broadcast to all others
        -- Security: Allow farm managers OR the dedicated-server master user (admin who may not be in a farm)
        local userId = g_currentMission.userManager:getUserIdByConnection(connection)
        local farm = userId ~= nil and g_farmManager:getFarmByUserId(userId) or nil
        local isFarmManager = farm ~= nil and farm:isUserFarmManager(userId)
        local masterUserId
        pcall(function() masterUserId = g_currentMission.userManager:getMasterUserId() end)
        local isMasterUser = masterUserId ~= nil and userId ~= nil and userId == masterUserId
        local isAuthorized = isFarmManager or isMasterUser
        if isAuthorized then
            g_MarketDynamics.settings = self.settings
            if g_MarketDynamics.marketEngine then
                g_MarketDynamics.marketEngine.volatilityScale = self.volatilityScale
            end
            MDMLog.info("MDMSettingsSyncEvent: server received settings update from authorized client (farmManager=" .. tostring(isFarmManager) .. " masterUser=" .. tostring(isMasterUser) .. ")")
            -- Broadcast to all other clients
            g_server:broadcastEvent(self, false, connection)
        else
            MDMLog.warn("MDMSettingsSyncEvent: unauthorized settings update attempt from client " .. tostring(userId))
            -- Optional: Send the correct settings back to the unauthorized client to revert their local UI
            MDMSettingsSyncEvent.sendToClient(connection)
        end
    else
        -- Received on client from server
        g_MarketDynamics.settings = self.settings
        if g_MarketDynamics.marketEngine then
            g_MarketDynamics.marketEngine.volatilityScale = self.volatilityScale
        end
        MDMLog.info("MDMSettingsSyncEvent: client received settings sync from server")
        MDMLog.debugEnabled = self.settings.debugMode
    end
end
