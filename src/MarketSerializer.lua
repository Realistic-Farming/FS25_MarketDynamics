-- MarketSerializer.lua
-- Persists and restores all market-related state to/from a dedicated XML file in the savegame.
-- Handles: fill type prices, world event cooldowns, active events, futures contracts,
-- and general mod settings.
--
-- Author: tison (dev-1)

MarketSerializer = {}

local SAVE_PATH_TEMPLATE = "%sFS25_MarketDynamics.xml"

-- Save all market state.
function MarketSerializer:save(coordinator)
    if not g_currentMission or not g_currentMission.missionInfo then
        MDMLog.info("MarketSerializer: g_currentMission or missionInfo not available — cannot save")
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if not savegameDir then
        -- Workaround for dedi or cases where missionInfo doesn't have the path
        savegameDir = ("%ssavegame%d"):format(getUserProfileAppPath(), g_currentMission.missionInfo.savegameIndex)
        local legacyPath = SAVE_PATH_TEMPLATE:format(savegameDir .. "/")
        if not fileExists(legacyPath) then
            -- Check for 'tempsavegame' (standard in some FS25 setups)
            savegameDir = ("%stempsavegame"):format(getUserProfileAppPath())
            if not fileExists(SAVE_PATH_TEMPLATE:format(savegameDir .. "/")) then
                MDMLog.info("MarketSerializer: savegame path not resolved — cannot save")
                return
            end
        end
    end

    local path    = SAVE_PATH_TEMPLATE:format(savegameDir .. "/")
    local xmlFile = XMLFile.create("MDMSave", path, "marketDynamics")

    if not xmlFile then
        MDMLog.error("MarketSerializer: failed to create save file at " .. path)
        return
    end

    -- Schema version stamp
    xmlFile:setString("marketDynamics#version", "2")
    
    -- Store absolute game time at save (v2.1+) to prevent immediate expiration on reload.
    -- Stored as string to prevent 32-bit float parsing truncation bugs in C++ engine.
    xmlFile:setString("marketDynamics#lastGameTime", tostring(MDMUtil.getGameTime()))

    -- ── Futures contracts ────────────────────────────────────────────────
    local contracts = coordinator.futuresMarket and coordinator.futuresMarket.contracts or {}
    local i = 0
    for _, contract in pairs(contracts) do
        local base = "marketDynamics.futures.contract(" .. i .. ")"
        xmlFile:setInt   (base .. "#id",                contract.id)
        xmlFile:setInt   (base .. "#farmId",            contract.farmId)
        xmlFile:setInt   (base .. "#fillTypeIndex",     contract.fillTypeIndex)
        xmlFile:setString(base .. "#fillTypeName",      contract.fillTypeName)
        xmlFile:setFloat (base .. "#quantity",          contract.quantity)
        xmlFile:setFloat (base .. "#lockedPrice",       contract.lockedPrice)
        xmlFile:setString(base .. "#deliveryTime",      tostring(contract.deliveryTime or 0))
        xmlFile:setString(base .. "#deliveryStartTime", tostring(contract.deliveryStartTime or 0))
        xmlFile:setFloat (base .. "#delivered",         contract.delivered or 0)
        xmlFile:setFloat (base .. "#valueReceived",     contract.valueReceived or 0)
        xmlFile:setString(base .. "#status",            contract.status or "active")
        xmlFile:setBool  (base .. "#isRealDays",        contract.isRealDays or false)
        xmlFile:setFloat (base .. "#createdTimeScale",  contract.createdTimeScale or 1)
        if contract.upDealId then
            xmlFile:setString(base .. "#upDealId", tostring(contract.upDealId))
        end
        i = i + 1
    end

    -- ── Market Engine (Prices & History) ────────────────────────────────
    if coordinator.marketEngine then
        local k = 0
        for index, entry in pairs(coordinator.marketEngine.prices) do
            local base = "marketDynamics.prices.price(" .. k .. ")"
            xmlFile:setInt  (base .. "#index",  index)
            xmlFile:setFloat(base .. "#current", entry.current)
            xmlFile:setFloat(base .. "#trend",   entry.trend or 0)
            xmlFile:setFloat(base .. "#volatility", entry.volatility or 0)
            
            -- Save history
            if entry.history and #entry.history > 0 then
                for m, h in ipairs(entry.history) do
                    local hBase = base .. ".history(" .. (m - 1) .. ")"
                    xmlFile:setFloat(hBase .. "#price", h.price)
                    xmlFile:setFloat(hBase .. "#time",  h.time)
                end
            end
            k = k + 1
        end
    end

    -- ── World Events (Cooldowns & Active) ────────────────────────────────
    if coordinator.worldEvents then
        -- Cooldowns
        local j = 0
        for id, event in pairs(coordinator.worldEvents.registry) do
            local base = "marketDynamics.events.event(" .. j .. ")"
            xmlFile:setString(base .. "#id",          id)
            xmlFile:setString(base .. "#lastFiredAt", tostring(event.lastFiredAt))
            j = j + 1
        end

        -- Active events
        local a = 0
        for id, active in pairs(coordinator.worldEvents.active) do
            local base = "marketDynamics.activeEvents.event(" .. a .. ")"
            xmlFile:setString(base .. "#id",        id)
            xmlFile:setString(base .. "#endsAt",    tostring(active.endsAt))
            xmlFile:setFloat (base .. "#intensity", active.intensity)
            -- Persist per-event extra state (e.g. which crops were affected)
            local desc = coordinator.worldEvents.registry[id]
            if desc and desc.getExtraData then
                local extra = desc.getExtraData()
                if extra and extra ~= "" then
                    xmlFile:setString(base .. "#extraData", extra)
                end
            end
            a = a + 1
        end
    end

    -- ── General settings ─────────────────────────────────────────────────
    local s = coordinator.settings
    if s then
        xmlFile:setBool ("marketDynamics.settings#pricesEnabled",  s.pricesEnabled  ~= false)
        xmlFile:setBool ("marketDynamics.settings#debugMode",      s.debugMode      == true)
        xmlFile:setBool ("marketDynamics.settings#eventsEnabled",  s.eventsEnabled  ~= false)
        xmlFile:setFloat("marketDynamics.settings#eventFrequency", s.eventFrequency or 1.0)
        xmlFile:setFloat("marketDynamics.settings#futuresPenalty", s.futuresPenalty or 0.15)
        xmlFile:setBool ("marketDynamics.settings#showEventNotifications", s.showEventNotifications ~= false)
        xmlFile:setBool ("marketDynamics.settings#eventNotificationBanner", s.eventNotificationBanner == true)
        xmlFile:setBool ("marketDynamics.settings#showContractHUD",       s.showContractHUD       ~= false)
        xmlFile:setBool ("marketDynamics.settings#useRealDays",           s.useRealDays           == true)

        -- Disabled events: { [eventId] = true }
        local de = s.disabledEvents or {}
        local di = 0
        for id, _ in pairs(de) do
            local base = "marketDynamics.disabledEvents.event(" .. di .. ")"
            xmlFile:setString(base .. "#id", id)
            di = di + 1
        end

        -- Custom fill types per event: { [eventId] = { name, ... } }
        local cft = s.eventCustomFillTypes or {}
        local ci = 0
        for eventId, list in pairs(cft) do
            if #list > 0 then
                local base = "marketDynamics.eventCustomFillTypes.event(" .. ci .. ")"
                xmlFile:setString(base .. "#id", eventId)
                for fi, name in ipairs(list) do
                    xmlFile:setString(base .. ".fillType(" .. (fi - 1) .. ")#name", name)
                end
                ci = ci + 1
            end
        end
    end

    if coordinator.marketEngine then
        xmlFile:setFloat("marketDynamics.settings#volatilityScale",
            coordinator.marketEngine.volatilityScale or 1.0)
    end

    -- ── Integration state ────────────────────────────────────────────────
    UPIntegration.save(xmlFile, "marketDynamics.upIntegration")

    xmlFile:save()
    xmlFile:delete()
    MDMLog.info("MarketSerializer: saved to " .. path)
end

-- Load and restore market state.
function MarketSerializer:load(coordinator)
    if not g_currentMission or not g_currentMission.missionInfo then
        MDMLog.info("MarketSerializer: g_currentMission or missionInfo not available — starting fresh")
        return
    end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    local xmlFile = nil
    
    if savegameDir then
        local path = SAVE_PATH_TEMPLATE:format(savegameDir .. "/")
        if fileExists(path) then
            xmlFile = XMLFile.load("MDMLoad", path)
        end
    end

    -- Fallback for dedi / manual profile path resolution
    if not xmlFile then
        local profilePath = getUserProfileAppPath()
        local index = g_currentMission.missionInfo.savegameIndex
        
        -- Check both standard savegame and tempsavegame
        local searchPaths = {
            ("%ssavegame%d/FS25_MarketDynamics.xml"):format(profilePath, index),
            ("%stempsavegame/FS25_MarketDynamics.xml"):format(profilePath)
        }
        
        for _, legacyPath in ipairs(searchPaths) do
            if fileExists(legacyPath) then
                xmlFile = XMLFile.load("MDMLoad", legacyPath)
                if xmlFile then
                    MDMLog.info("MarketSerializer: migrating from legacy path " .. legacyPath)
                end
            end
        end
    end

    if not xmlFile then
        MDMLog.info("MarketSerializer: no save file found — starting fresh")
        return
    end

    local version = tonumber(xmlFile:getString("marketDynamics#version") or "1")

    -- Restore last saved game time
    if coordinator then
        local gtStr = xmlFile:getString("marketDynamics#lastGameTime")
        coordinator.lastSavedGameTime = gtStr and tonumber(gtStr) or (xmlFile:getFloat("marketDynamics#lastGameTime") or 0)
    end

    -- ── Restore futures contracts ─────────────────────────────────────────
    local i = 0
    while true do
        local base = "marketDynamics.futures.contract(" .. i .. ")"
        if not xmlFile:hasProperty(base) then break end

        local id = xmlFile:getInt(base .. "#id")

        -- Load as string to bypass C++ float truncation, fallback to getFloat
        local deliveryTimeStr = xmlFile:getString(base .. "#deliveryTime")
        local deliveryTime = deliveryTimeStr and tonumber(deliveryTimeStr) or xmlFile:getFloat(base .. "#deliveryTime")

        local deliveryStartTimeStr = xmlFile:getString(base .. "#deliveryStartTime")
        local deliveryStartTime = deliveryStartTimeStr and tonumber(deliveryStartTimeStr) or (xmlFile:getFloat(base .. "#deliveryStartTime") or 0)

        if id and deliveryTime and deliveryTime > 0 then
            local upDealId = xmlFile:getString(base .. "#upDealId")
            if not upDealId then
                local oldId = xmlFile:getInt(base .. "#upDealId")
                if oldId then upDealId = tostring(oldId) end
            end

            local contract = {
                id                = id,
                farmId            = xmlFile:getInt   (base .. "#farmId"),
                fillTypeIndex     = xmlFile:getInt   (base .. "#fillTypeIndex"),
                fillTypeName      = xmlFile:getString(base .. "#fillTypeName"),
                quantity          = xmlFile:getFloat (base .. "#quantity"),
                lockedPrice       = xmlFile:getFloat (base .. "#lockedPrice"),
                deliveryTime      = deliveryTime,
                deliveryStartTime = deliveryStartTime,
                bcManaged         = xmlFile:getBool  (base .. "#bcManaged") or false,
                delivered         = xmlFile:getFloat (base .. "#delivered") or 0,
                valueReceived     = xmlFile:getFloat (base .. "#valueReceived") or 0,
                status            = xmlFile:getString(base .. "#status") or "active",
                upDealId          = upDealId,
                isRealDays        = xmlFile:getBool  (base .. "#isRealDays") or false,
                createdTimeScale  = xmlFile:getFloat (base .. "#createdTimeScale") or 1,
            }
            if coordinator.futuresMarket then
                coordinator.futuresMarket.contracts[id] = contract
                if id >= coordinator.futuresMarket.nextId then
                    coordinator.futuresMarket.nextId = id + 1
                end
            end
        else
            MDMLog.warn("MarketSerializer: contract entry " .. i .. " has invalid id/deliveryTime — skipping")
        end
        i = i + 1
    end

    -- ── Restore prices ───────────────────────────────────────────────────
    if coordinator.marketEngine then
        local k = 0
        while true do
            local base = "marketDynamics.prices.price(" .. k .. ")"
            if not xmlFile:hasProperty(base) then break end

            local index = xmlFile:getInt(base .. "#index")
            if index then
                local entry = coordinator.marketEngine.prices[index]
                if entry then
                    entry.current    = xmlFile:getFloat(base .. "#current") or entry.current
                    entry.trend      = xmlFile:getFloat(base .. "#trend")   or 0
                    entry.volatility = xmlFile:getFloat(base .. "#volatility") or 0
                    
                    -- Restore history
                    entry.history = {}
                    local m = 0
                    while true do
                        local hBase = base .. ".history(" .. m .. ")"
                        if not xmlFile:hasProperty(hBase) then break end

                        local p = xmlFile:getFloat(hBase .. "#price")
                        local t = xmlFile:getFloat(hBase .. "#time")
                        if p and t then
                            table.insert(entry.history, { price = p, time = t })
                        end
                        m = m + 1
                    end
                    
                    -- Recalculate 'current' (base price was snapshotted in init())
                    coordinator.marketEngine:_recalculate(index)
                end
            end
            k = k + 1
        end
    end

    -- ── Restore event cooldowns ───────────────────────────────────────────
    local j = 0
    while true do
        local base  = "marketDynamics.events.event(" .. j .. ")"
        if not xmlFile:hasProperty(base) then break end

        local evId  = xmlFile:getString(base .. "#id")
        local lfStr = xmlFile:getString(base .. "#lastFiredAt")
        local lastFired = lfStr and tonumber(lfStr) or (xmlFile:getFloat(base .. "#lastFiredAt") or -math.huge)
        
        if evId and coordinator.worldEvents and coordinator.worldEvents.registry[evId] then
            coordinator.worldEvents.registry[evId].lastFiredAt = lastFired
        end
        j = j + 1
    end

    -- ── Restore active events (v2+) ──────────────────────────────────────
    if coordinator.worldEvents and version >= 2 then
        local a = 0
        while true do
            local base = "marketDynamics.activeEvents.event(" .. a .. ")"
            if not xmlFile:hasProperty(base) then break end

            local evId = xmlFile:getString(base .. "#id")
            if evId then
                local endsAtStr = xmlFile:getString(base .. "#endsAt")
                local endsAt    = endsAtStr and tonumber(endsAtStr) or (xmlFile:getFloat(base .. "#endsAt") or 0)
                local intensity = xmlFile:getFloat (base .. "#intensity")
                local extraData = xmlFile:getString(base .. "#extraData") or ""
                coordinator.worldEvents:loadActiveEvent(evId, endsAt, intensity, extraData)
            end
            a = a + 1
        end
    end

    -- ── Restore general settings ──────────────────────────────────────────
    if coordinator.settings then
        local s = coordinator.settings

        local pricesEnabled = xmlFile:getBool("marketDynamics.settings#pricesEnabled")
        if pricesEnabled ~= nil then s.pricesEnabled = pricesEnabled end

        local debugMode = xmlFile:getBool("marketDynamics.settings#debugMode")
        if debugMode ~= nil then
            s.debugMode = debugMode
            MDMLog.debugEnabled = debugMode
        end

        local eventsEnabled = xmlFile:getBool("marketDynamics.settings#eventsEnabled")
        if eventsEnabled ~= nil then s.eventsEnabled = eventsEnabled end

        local eventFrequency = xmlFile:getFloat("marketDynamics.settings#eventFrequency")
        if eventFrequency and eventFrequency > 0 then s.eventFrequency = eventFrequency end

        local futuresPenalty = xmlFile:getFloat("marketDynamics.settings#futuresPenalty")
        if futuresPenalty and futuresPenalty > 0 then s.futuresPenalty = futuresPenalty end

        local showEventNotifications = xmlFile:getBool("marketDynamics.settings#showEventNotifications")
        if showEventNotifications ~= nil then s.showEventNotifications = showEventNotifications end

        local eventNotificationBanner = xmlFile:getBool("marketDynamics.settings#eventNotificationBanner")
        if eventNotificationBanner ~= nil then s.eventNotificationBanner = eventNotificationBanner end

        local showContractHUD = xmlFile:getBool("marketDynamics.settings#showContractHUD")
        if showContractHUD ~= nil then s.showContractHUD = showContractHUD end

        local useRealDays = xmlFile:getBool("marketDynamics.settings#useRealDays")
        if useRealDays ~= nil then s.useRealDays = useRealDays end

        -- Disabled events
        s.disabledEvents = {}
        local di = 0
        while true do
            local base = "marketDynamics.disabledEvents.event(" .. di .. ")"
            if not xmlFile:hasProperty(base) then break end
            local evId = xmlFile:getString("marketDynamics.disabledEvents.event(" .. di .. ")#id")
            if evId then
                s.disabledEvents[evId] = true
            end
            di = di + 1
        end

        -- Custom fill types per event
        s.eventCustomFillTypes = {}
        local ci = 0
        while true do
            local base    = "marketDynamics.eventCustomFillTypes.event(" .. ci .. ")"
            if not xmlFile:hasProperty(base) then break end
            local eventId = xmlFile:getString(base .. "#id")
            if eventId then
                s.eventCustomFillTypes[eventId] = {}
                local fi = 0
                while true do
                    local name = xmlFile:getString(base .. ".fillType(" .. fi .. ")#name")
                    if not name then break end
                    table.insert(s.eventCustomFillTypes[eventId], name)
                    fi = fi + 1
                end
            end
            ci = ci + 1
        end
    end

    if coordinator.marketEngine then
        local vScale = xmlFile:getFloat("marketDynamics.settings#volatilityScale")
        if vScale and vScale > 0 then
            coordinator.marketEngine.volatilityScale = vScale
        end
    end

    -- ── Integration state ─────────────────────────────────────────────────
    UPIntegration.load(xmlFile, "marketDynamics.upIntegration")

    xmlFile:delete()
    MDMLog.info("MarketSerializer: restored version " .. version)
end
