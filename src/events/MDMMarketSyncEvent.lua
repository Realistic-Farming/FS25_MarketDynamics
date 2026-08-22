-- MDMMarketSyncEvent.lua
-- Syncs prices and active world events from server to clients.

MDMMarketSyncEvent = MDMMarketSyncEvent or {}
local MDMMarketSyncEvent_mt = Class(MDMMarketSyncEvent, Event)
InitEventClass(MDMMarketSyncEvent, "MDMMarketSyncEvent")

function MDMMarketSyncEvent.emptyNew()
    return Event.new(MDMMarketSyncEvent_mt)
end

function MDMMarketSyncEvent.new(marketEngine, worldEvents)
    local self = MDMMarketSyncEvent.emptyNew()
    self.prices = {}
    if marketEngine then
        for index, entry in pairs(marketEngine.prices) do
            table.insert(self.prices, {
                index = index,
                volatilityFactor = entry.volatilityFactor
            })
        end
    end
    self.activeEvents = {}
    if worldEvents then
        for id, active in pairs(worldEvents.active) do
            local extraData = ""
            if worldEvents.registry[id] and worldEvents.registry[id].getExtraData then
                extraData = worldEvents.registry[id].getExtraData() or ""
            end
            table.insert(self.activeEvents, {
                id = id,
                endsAt = active.endsAt,
                intensity = active.intensity,
                extraData = extraData
            })
        end
    end
    return self
end

function MDMMarketSyncEvent.sendToClients()
    -- When NetworkSync is active it carries the full state; mark it dirty instead of
    -- broadcasting the own event.
    if MDMNetworkSyncBridge ~= nil and MDMNetworkSyncBridge.markStateDirty() then
        return
    end
    if g_server ~= nil and g_MarketDynamics then
        g_server:broadcastEvent(MDMMarketSyncEvent.new(g_MarketDynamics.marketEngine, g_MarketDynamics.worldEvents))
    end
end

function MDMMarketSyncEvent.sendToClient(connection)
    if g_server ~= nil and connection ~= nil and g_MarketDynamics then
        connection:sendEvent(MDMMarketSyncEvent.new(g_MarketDynamics.marketEngine, g_MarketDynamics.worldEvents))
    end
end

function MDMMarketSyncEvent:writeStream(streamId, connection)
    -- Write prices
    streamWriteInt32(streamId, #self.prices)
    for _, p in ipairs(self.prices) do
        streamWriteInt32(streamId, p.index)
        streamWriteFloat32(streamId, p.volatilityFactor)
    end

    -- Write active events
    streamWriteInt32(streamId, #self.activeEvents)
    for _, e in ipairs(self.activeEvents) do
        streamWriteString(streamId, e.id)
        streamWriteFloat32(streamId, e.endsAt)
        streamWriteFloat32(streamId, e.intensity)
        streamWriteString(streamId, e.extraData)
    end
end

function MDMMarketSyncEvent:readStream(streamId, connection)
    self.prices = {}
    local numPrices = streamReadInt32(streamId)
    for i = 1, numPrices do
        table.insert(self.prices, {
            index = streamReadInt32(streamId),
            volatilityFactor = streamReadFloat32(streamId)
        })
    end

    self.activeEvents = {}
    local numEvents = streamReadInt32(streamId)
    for i = 1, numEvents do
        table.insert(self.activeEvents, {
            id = streamReadString(streamId),
            endsAt = streamReadFloat32(streamId),
            intensity = streamReadFloat32(streamId),
            extraData = streamReadString(streamId)
        })
    end
    self:run(connection)
end

-- Apply market prices + active world events to the local client. Extracted from :run so
-- the NetworkSync bridge can reuse the EXACT same apply path (prices, event lifecycle,
-- notifications, UI refresh) instead of re-implementing it. `prices` = array of
-- {index, volatilityFactor}; `activeEvents` = array of {id, endsAt, intensity, extraData}.
function MDMMarketSyncEvent.applyState(prices, activeEvents)
    if not g_MarketDynamics then return end

    if g_MarketDynamics.marketEngine then
        for _, p in ipairs(prices) do
            local entry = g_MarketDynamics.marketEngine.prices[p.index]
            if entry then
                entry.volatilityFactor = p.volatilityFactor
                g_MarketDynamics.marketEngine:_recalculate(p.index)
            end
        end
    end

    if g_MarketDynamics.worldEvents then
        local incoming = {}
        for _, e in ipairs(activeEvents) do
            incoming[e.id] = e
        end

        local oldActive = {}
        for id, _ in pairs(g_MarketDynamics.worldEvents.active) do
            oldActive[id] = true
        end

        -- Only expire events that are no longer in the incoming set
        for id, _ in pairs(oldActive) do
            if not incoming[id] then
                g_MarketDynamics.worldEvents:_expireEvent(id)
            end
        end

        local newEventNames = {}
        for _, e in ipairs(activeEvents) do
            if oldActive[e.id] then
                -- Already active: update timing silently without re-firing callbacks
                local active = g_MarketDynamics.worldEvents.active[e.id]
                if active then
                    active.endsAt = e.endsAt
                    active.intensity = e.intensity
                end
            else
                -- Genuinely new event: full lifecycle
                g_MarketDynamics.worldEvents:loadActiveEvent(e.id, e.endsAt, e.intensity, e.extraData)
                if g_MarketDynamics.worldEvents.isInitialized then
                    local desc = g_MarketDynamics.worldEvents.registry[e.id]
                    local name = MDMUtil.resolveEventName(desc or e.id, desc and desc.name, e.id)
                    table.insert(newEventNames, name)
                end
            end
        end

        g_MarketDynamics.worldEvents.isInitialized = true

        if #newEventNames > 0 then
            local names = table.concat(newEventNames, ", ")
            g_MarketDynamics.pendingEventNotificationName = names
            addTimer(1000, "showEventNotification", g_MarketDynamics)
        end
    end

    -- Refresh UI
    if g_gui and g_gui.currentGuiName == "InGameMenu" then
        local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
        if inGameMenu then
            local page = inGameMenu[MDMMarketScreen.MENU_PAGE_NAME]
            if page and type(page.refreshData) == "function" then
                if inGameMenu.currentPage == page then
                    page:refreshData()
                end
            end
        end
    end
end

function MDMMarketSyncEvent:run(connection)
    if not connection:getIsServer() then return end -- only clients process this
    MDMMarketSyncEvent.applyState(self.prices, self.activeEvents)
end
