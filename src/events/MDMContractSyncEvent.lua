-- MDMContractSyncEvent.lua
-- Server-to-Client network event for syncing contract state.

MDMContractSyncEvent = {}
local MDMContractSyncEvent_mt = Class(MDMContractSyncEvent, Event)
InitEventClass(MDMContractSyncEvent, "MDMContractSyncEvent")

MDMContractSyncEvent.SYNC_FULL = 1
MDMContractSyncEvent.SYNC_UPDATE = 2
MDMContractSyncEvent.SYNC_REMOVE = 3

function MDMContractSyncEvent.emptyNew()
    return Event.new(MDMContractSyncEvent_mt)
end

function MDMContractSyncEvent.new(syncType, data)
    local self = MDMContractSyncEvent.emptyNew()
    self.syncType = syncType
    self.data = data
    return self
end

function MDMContractSyncEvent.sendToClients(syncType, data)
    -- When NetworkSync is active it carries the full state; mark it dirty (full resync at
    -- the next batch) instead of broadcasting the own incremental event.
    if MDMNetworkSyncBridge ~= nil and MDMNetworkSyncBridge.markStateDirty() then
        return
    end
    if g_server ~= nil then
        g_server:broadcastEvent(MDMContractSyncEvent.new(syncType, data))
    end
end

function MDMContractSyncEvent.sendToClient(connection, syncType, data)
    if g_server ~= nil and connection ~= nil then
        connection:sendEvent(MDMContractSyncEvent.new(syncType, data))
    end
end

function MDMContractSyncEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.syncType)
    
    if self.syncType == MDMContractSyncEvent.SYNC_FULL then
        local count = 0
        for _ in pairs(self.data) do count = count + 1 end
        streamWriteInt32(streamId, count)
        for _, c in pairs(self.data) do
            self:writeContract(streamId, c)
        end
    elseif self.syncType == MDMContractSyncEvent.SYNC_UPDATE then
        self:writeContract(streamId, self.data)
    elseif self.syncType == MDMContractSyncEvent.SYNC_REMOVE then
        streamWriteInt32(streamId, self.data.id)
    end
end

function MDMContractSyncEvent:writeContract(streamId, c)
    streamWriteInt32(streamId, c.id)
    streamWriteInt32(streamId, c.farmId)
    streamWriteInt32(streamId, c.fillTypeIndex)
    streamWriteString(streamId, c.fillTypeName)
    streamWriteFloat32(streamId, c.quantity)
    streamWriteFloat32(streamId, c.lockedPrice)
    -- Time values are sent as Int32 seconds, not Float64. streamWriteFloat64 is
    -- unreliable on dedicated servers and silently corrupts the rest of the stream,
    -- so the client never receives valid contracts and nothing shows in the menu
    -- (issue #93). This mirrors the same fix already applied to MDMContractRequestEvent
    -- in #82. Game time in seconds fits comfortably in an Int32.
    streamWriteInt32(streamId, math.floor((c.deliveryTime or 0) / 1000))
    streamWriteInt32(streamId, math.floor((c.deliveryStartTime or 0) / 1000))
    streamWriteBool(streamId, c.bcManaged == true)
    streamWriteFloat32(streamId, c.delivered)
    streamWriteFloat32(streamId, c.valueReceived or 0)
    streamWriteString(streamId, c.status)
end

function MDMContractSyncEvent:readStream(streamId, connection)
    self.syncType = streamReadInt8(streamId)
    
    if self.syncType == MDMContractSyncEvent.SYNC_FULL then
        self.data = {}
        local count = streamReadInt32(streamId)
        for i = 1, count do
            local c = self:readContract(streamId)
            table.insert(self.data, c)
        end
    elseif self.syncType == MDMContractSyncEvent.SYNC_UPDATE then
        self.data = self:readContract(streamId)
    elseif self.syncType == MDMContractSyncEvent.SYNC_REMOVE then
        self.data = { id = streamReadInt32(streamId) }
    end
    self:run(connection)
end

function MDMContractSyncEvent:readContract(streamId)
    return {
        id = streamReadInt32(streamId),
        farmId = streamReadInt32(streamId),
        fillTypeIndex = streamReadInt32(streamId),
        fillTypeName = streamReadString(streamId),
        quantity = streamReadFloat32(streamId),
        lockedPrice = streamReadFloat32(streamId),
        -- Int32 seconds → ms, matching writeContract (see #93 / #82).
        deliveryTime = streamReadInt32(streamId) * 1000,
        deliveryStartTime = streamReadInt32(streamId) * 1000,
        bcManaged    = streamReadBool(streamId),
        delivered = streamReadFloat32(streamId),
        valueReceived = streamReadFloat32(streamId),
        status = streamReadString(streamId)
    }
end

function MDMContractSyncEvent.execute(syncType, data)
    if not g_MarketDynamics or not g_MarketDynamics.futuresMarket then return end
    local fm = g_MarketDynamics.futuresMarket
    
    if syncType == MDMContractSyncEvent.SYNC_FULL then
        fm.contracts = {}
        fm.nextId = 1
        for _, c in ipairs(data) do
            fm.contracts[c.id] = c
            if c.id >= fm.nextId then fm.nextId = c.id + 1 end
        end
    elseif syncType == MDMContractSyncEvent.SYNC_UPDATE then
        fm.contracts[data.id] = data
        if data.id >= fm.nextId then fm.nextId = data.id + 1 end
    elseif syncType == MDMContractSyncEvent.SYNC_REMOVE then
        fm.contracts[data.id] = nil
    end
    
    -- Reload UI if active
    if g_gui and g_gui.currentGuiName == "InGameMenu" then
        local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
        if inGameMenu then
            local page = inGameMenu[MDMMarketScreen.MENU_PAGE_NAME]
            if page and type(page._buildContractData) == "function" then
                if inGameMenu.currentPage == page then
                    page:_buildContractData()
                    page:reloadAllLists()
                end
            end
        end
    end
end

function MDMContractSyncEvent:run(connection)
    if not connection:getIsServer() then return end
    MDMContractSyncEvent.execute(self.syncType, self.data)
end
