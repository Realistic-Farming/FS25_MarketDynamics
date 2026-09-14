-- MDMMarketSyncEvent.lua
-- Syncs prices and active world events from server to clients.
--
-- Direct stream format: STREAM_MARK "MDM-CALENDAR/2" (RSF-F204), the history
-- inclusion bool right after the mark, then the counted regions. The NetworkSync
-- array keeps WIRE_MARK "MDM-CALENDAR/1"; its layout did not change. In both,
-- the server's authoritative base and current quote travel as %.17g decimal
-- strings (RSF-F203) so the client keeps the exact received quote instead of a
-- float32-truncated recomposition; active-event deadlines travel the same way
-- so a large monotonic expiry round-trips exactly.

MDMMarketSyncEvent = MDMMarketSyncEvent or {}
local MDMMarketSyncEvent_mt = Class(MDMMarketSyncEvent, Event)
InitEventClass(MDMMarketSyncEvent, "MDMMarketSyncEvent")

MDMMarketSyncEvent.WIRE_MARK = "MDM-CALENDAR/1"
-- Direct-event stream mark (RSF-F204). The stream layout gained the history
-- inclusion boolean, so the direct envelope carries its own mark. WIRE_MARK
-- stays on the NetworkSync array, whose layout did not change; do not merge them.
MDMMarketSyncEvent.STREAM_MARK = "MDM-CALENDAR/2"

function MDMMarketSyncEvent.emptyNew()
    return Event.new(MDMMarketSyncEvent_mt)
end

function MDMMarketSyncEvent.new(marketEngine, worldEvents, includeHistory)
    local self = MDMMarketSyncEvent.emptyNew()
    -- Equals the constructor argument, never derived from history length:
    -- included-empty and omitted are distinct facts on the wire (RSF-F204).
    self.historyIncluded = (includeHistory == true)
    self.prices = {}
    if marketEngine then
        for index, entry in pairs(marketEngine.prices) do
            table.insert(self.prices, {
                index = index,
                base = entry.base,
                current = entry.current,
                volatilityFactor = entry.volatilityFactor,
                history = includeHistory and entry.history or {},
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

-- includeHistory: true on any send that can change history (the coalesced
-- MarketEngine tick and publishMarketState). Deltas that never touch history
-- may omit it. When in doubt, include (RSF-F204).
function MDMMarketSyncEvent.sendToClients(includeHistory)
    -- When NetworkSync is active it carries the full state; mark it dirty instead of
    -- broadcasting the own event.
    if MDMNetworkSyncBridge ~= nil and MDMNetworkSyncBridge.markStateDirty() then
        return
    end
    if g_server ~= nil and g_MarketDynamics then
        g_server:broadcastEvent(MDMMarketSyncEvent.new(g_MarketDynamics.marketEngine, g_MarketDynamics.worldEvents, includeHistory))
    end
end

function MDMMarketSyncEvent.sendToClient(connection)
    if g_server ~= nil and connection ~= nil and g_MarketDynamics then
        connection:sendEvent(MDMMarketSyncEvent.new(g_MarketDynamics.marketEngine, g_MarketDynamics.worldEvents, true))
    end
end

function MDMMarketSyncEvent:writeStream(streamId, connection)
    -- Stream mark: receivers reject streams without it (single-version deployment).
    streamWriteString(streamId, MDMMarketSyncEvent.STREAM_MARK)
    -- Event-level inclusion fact, outside every counted region.
    streamWriteBool(streamId, self.historyIncluded == true)

    -- Write prices
    streamWriteInt32(streamId, #self.prices)
    for _, p in ipairs(self.prices) do
        streamWriteInt32(streamId, p.index)
        streamWriteString(streamId, string.format("%.17g", p.base or 0))
        streamWriteString(streamId, string.format("%.17g", p.current or 0))
        streamWriteFloat32(streamId, p.volatilityFactor)
        local hist = p.history or {}
        streamWriteInt32(streamId, #hist)
        for _, h in ipairs(hist) do
            streamWriteFloat32(streamId, h.price or 0)
            streamWriteFloat32(streamId, h.time or 0)
        end
    end

    -- Write active events
    streamWriteInt32(streamId, #self.activeEvents)
    for _, e in ipairs(self.activeEvents) do
        streamWriteString(streamId, e.id)
        streamWriteString(streamId, string.format("%.17g", e.endsAt or 0))
        streamWriteFloat32(streamId, e.intensity)
        streamWriteString(streamId, e.extraData)
    end
end

function MDMMarketSyncEvent:readStream(streamId, connection)
    local mark = streamReadString(streamId)
    if mark ~= MDMMarketSyncEvent.STREAM_MARK then
        MDMLog.error("MDMMarketSyncEvent: stream rejected, stream mark mismatch (got '" .. tostring(mark) .. "')")
        return
    end
    self.historyIncluded = streamReadBool(streamId)

    self.prices = {}
    local numPrices = streamReadInt32(streamId)
    for i = 1, numPrices do
        local index = streamReadInt32(streamId)
        local baseText = streamReadString(streamId)
        local currentText = streamReadString(streamId)
        local volatilityFactor = streamReadFloat32(streamId)
        local numHist = streamReadInt32(streamId)
        local history = {}
        for j = 1, numHist do
            history[j] = {
                price = streamReadFloat32(streamId),
                time  = streamReadFloat32(streamId),
            }
        end
        table.insert(self.prices, {
            index = index,
            base = tonumber(baseText),
            current = tonumber(currentText),
            volatilityFactor = volatilityFactor,
            history = history,
        })
    end

    self.activeEvents = {}
    local numEvents = streamReadInt32(streamId)
    for i = 1, numEvents do
        table.insert(self.activeEvents, {
            id = streamReadString(streamId),
            endsAt = tonumber(streamReadString(streamId)),
            intensity = streamReadFloat32(streamId),
            extraData = streamReadString(streamId)
        })
    end
    self:run(connection)
end

-- Apply market prices + active world events to the local client. Extracted from :run so
-- the NetworkSync bridge can reuse the EXACT same apply path (prices, event lifecycle,
-- notifications, UI refresh) instead of re-implementing it. `prices` = array of
-- {index, base, current, volatilityFactor, history?}; `activeEvents` = array of
-- {id, endsAt, intensity, extraData}. `historyIncluded` is the explicit inclusion
-- fact: true means the payload is authoritative for history (nonempty replaces,
-- empty clears); nil or false means history was omitted and the retained
-- samples are preserved. Presence is never inferred from length (RSF-F204).
function MDMMarketSyncEvent.applyState(prices, activeEvents, historyIncluded)
    if not g_MarketDynamics then return end

    if g_MarketDynamics.marketEngine then
        for _, p in ipairs(prices) do
            local entry = g_MarketDynamics.marketEngine.prices[p.index]
            if entry then
                -- The received server quote is authoritative: base and current
                -- travel together and win over any local display recomposition
                -- (RSF-F203). _recalculate on a pure client returns the retained
                -- quote unchanged.
                if p.base ~= nil then entry.base = p.base end
                if p.current ~= nil then entry.current = p.current end
                entry.volatilityFactor = p.volatilityFactor
                if historyIncluded == true then
                    -- Copy: the incoming array must not alias client state.
                    local history = {}
                    for j, h in ipairs(p.history or {}) do
                        history[j] = { price = h.price, time = h.time }
                    end
                    entry.history = history
                    if #history > 0 and MDMMarketScreenGraph ~= nil and type(MDMMarketScreenGraph.seedFromHistory) == "function" then
                        MDMMarketScreenGraph.seedFromHistory(p.index, history)
                    end
                end
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

    -- A complete snapshot (history included) is the first point at which a
    -- client holds the server's market state; F205's sampler waits on this.
    if historyIncluded == true then
        g_MarketDynamics._marketStateReady = true
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
    MDMMarketSyncEvent.applyState(self.prices, self.activeEvents, self.historyIncluded)
end
