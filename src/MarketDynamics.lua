-- MarketDynamics.lua
-- Central coordinator. Creates and owns all subsystems, drives the update loop.
-- Global reference: g_MarketDynamics
--
-- Subsystem ownership:
--   marketEngine   MarketEngine       price state, volatility, modifier stack
--   worldEvents    WorldEventSystem   event registry, scheduling, expiry
--   futuresMarket  FuturesMarket      contract creation and settlement
--   serializer     MarketSerializer   save/load to modSettings XML
--
-- Lifecycle (hooks installed at the bottom of this file at source time):
--   Mission00.load              — create coordinator, set g_MarketDynamics
--   Mission00.loadMission00Finished — init engine, register events, activate
--   Mission00.onStartMission    — load saved state from XML
--   FSBaseMission.update        — tick all subsystems
--   FSBaseMission.draw          — delegate to g_MDMHud if market screen is open
--   FSCareerMissionInfo.saveToXMLFile — persist state
--   FSBaseMission.delete        — cleanup
--
-- Author: tison (dev-1)

MarketDynamics = {}
MarketDynamics.__index = MarketDynamics

function MarketDynamics.new(modDir, modName)
    local self = setmetatable({}, MarketDynamics)

    self.modDir   = modDir
    self.modName  = modName
    self.isActive = false
    self._loadPhase = true

    -- Player-configurable settings (persisted by MarketSerializer, edited via SettingsUI)
    -- Add new settings here and wire them in MarketSerializer + SettingsUI.
    self.settings = {
        pricesEnabled        = true,   -- When false, PriceHook passes through to vanilla prices
        debugMode            = false,  -- MDMLog.debugEnabled mirror (also set directly on MDMLog)
        eventsEnabled        = true,   -- When false, WorldEventSystem skips probability rolls
        eventFrequency       = 1.0,   -- Probability scale: 0.4=Rare, 1.0=Normal, 2.0=Frequent
        futuresPenalty       = 0.15,  -- Default penalty fraction on unfulfilled contracts
        showEventNotifications = true, -- Master on/off for world-event alerts
        eventNotificationBanner = false, -- false = pop-up dialog (default), true = discreet banner (#94)
        showContractHUD       = true,  -- Show custom HUD for active contracts
        useRealDays          = false, -- When true, contract delivery windows track real-world time
        disabledEvents       = {},    -- { [eventId] = true } — events that won't roll
        eventCustomFillTypes = {},    -- { [eventId] = { fillTypeName, ... } }
        -- Release-gate opt-in (default false), orthogonal to difficulty. See ReleaseGate.lua.
        experimentalSystems  = false,
    }

    -- Subsystems
    self.marketEngine  = MarketEngine.new()
    self.worldEvents   = WorldEventSystem.new()
    self.futuresMarket = FuturesMarket.new()
    self.serializer    = MarketSerializer

    -- Consumer price modifier registry: external mods register multiplier callbacks
    -- via registerPriceModifier(name, fn). Each registered fn receives a context table
    -- and returns a multiplier that is applied to the final price.
    self.priceModifiers = {}

    -- Expose BCIntegration so external mods (e.g. BetterContracts) can reach it via
    -- g_MarketDynamics.bcIntegration without depending on the global table name.
    self.bcIntegration = BCIntegration

    self.rweIntegration = MDMRWEIntegration.new(self.marketEngine)

    local modInfo = g_modManager:getModByName(modName)
    MDMLog.info("MarketDynamics created — v" .. (modInfo and modInfo.version or "?"))
    return self
end

--- Release-gate opt-in. True when the player has explicitly enabled experimental
--- (LOCKED) systems. Orthogonal to difficulty: the two locks stack, see ReleaseGate.lua.
---@return boolean
function MarketDynamics:allowsExperimentalSystems()
    return self.settings.experimentalSystems == true
end

-- Called after mission is fully loaded. Safe to access all game APIs from here.
-- Initialisation order matters: engine must be inited before isActive=true so
-- that PriceHook's vanilla-price snapshot happens without MDM interference.
function MarketDynamics:onMissionLoaded(mission)
    self.marketEngine:init()         -- snapshot vanilla base prices
    self:_registerDefaultEvents()    -- drain MDM_pendingRegistrations
    self.isActive = true             -- PriceHook now routes through MDM
    BCIntegration.init(self.marketEngine, self.futuresMarket)
    UPIntegration.init()
    self.settingsPanel = MDMSettingsPanel.new(self.settings)
    
    MDMAdminCommands_register()

    -- Dialog loader: init + register modal dialogs (client only — no GUI on dedicated servers)
    -- Use g_client ~= nil rather than g_currentMission.isServer: the .isServer property
    -- is unreliable on headless dedicated servers and can be nil during onMissionLoaded.
    if g_client ~= nil then
        MDMDialogLoader.init(self.modDir)
        MDMDialogLoader.register("MDMContractDialog",        MDMContractDialog,        "xml/gui/MDMContractDialog.xml")
        MDMDialogLoader.register("MDMContractAdminDialog",   MDMContractAdminDialog,   "xml/gui/MDMContractAdminDialog.xml")
        MDMDialogLoader.register("MDMCustomInputDialog",     MDMCustomInputDialog,     "xml/gui/MDMCustomInputDialog.xml")
        MDMDialogLoader.register("MDMEventSettingsDialog",   MDMEventSettingsDialog,   "xml/gui/MDMEventSettingsDialog.xml")
        MDMDialogLoader.register("MDMEventFillTypeDialog",   MDMEventFillTypeDialog,   "xml/gui/MDMEventFillTypeDialog.xml")
        MDMDialogLoader.register("MDMBrowseFillTypesDialog", MDMBrowseFillTypesDialog, "xml/gui/MDMBrowseFillTypesDialog.xml")
    end

    -- Detect optional companion mods
    self.rweIntegration:detect()

    -- Register the HUD with MasterHUD (if installed) so it owns the single
    -- suspend-aware draw loop. No-ops safely if MasterHUD is absent; the own
    -- FSBaseMission.draw path (MarketDynamics:draw) stands down when this is active.
    MDMMasterHUDBridge.register(self)

    -- Route the client-initiated contract action through NetworkSync's server-authoritative
    -- action channel when present; the own MDMContractRequestEvent is the fallback. No-op if
    -- NetworkSync is absent. Server->client state broadcasts stay on their own events.
    MDMNetworkSyncBridge.register(self)

    -- OM-213 organic market premium: register the "OrganicPremium" price modifier
    -- (reads SoilFertilizer's organic provenance; a no-op when SF is absent).
    OrganicPremiumBridge.register()

    MDMLog.info("MarketDynamics: mission loaded, system active")
end

-- Called when the player's savegame session actually starts (load saved data here)
function MarketDynamics:onStartMission(mission)
    -- Use g_server ~= nil as the authoritative server check.
    -- g_currentMission.isServer is unreliable on headless dedicated servers — it can be
    -- nil or false during onStartMission even though the process IS the server, causing
    -- the server to skip loading its XML and instead send a sync-request to itself,
    -- which leaves all contracts empty after every rejoin (issue #51).
    -- Load user event config (extra fill types per event) before loading savegame state
    -- so that any config-based modifiers from active events are applied correctly.
    local savegameDir = (g_currentMission and g_currentMission.missionInfo and
                         g_currentMission.missionInfo.savegameDirectory) or ""
    MDMEventConfig.load(savegameDir)

    if g_server ~= nil then
        self.serializer:load(self)

        -- StateLedger (bedrock) override: when the shared master file carries a
        -- MarketDynamics_State block, it is the load source of truth for the durable
        -- market state (contracts, prices, cooldowns, lastGameTime). It overrides the
        -- state just imported from FS25_MarketDynamics.xml (kept as the safety copy).
        -- Runs before cleanupStaleEntries + reregisterActiveContracts so the ledger
        -- state flows through the same post-load pipeline. No-ops when StateLedger is
        -- absent or the block is empty (own XML stays primary).
        MDMStateLedgerBridge.register(self)
        if MDMStateLedgerBridge.hasState() then
            MDMStateLedgerBridge.applyState(self)
        end

        -- Remove stale entries from removed mods before anything uses the data.
        self.marketEngine:cleanupStaleEntries()
        MDMEventConfig.validateAndClean()
        UPIntegration.reregisterActiveContracts(self.futuresMarket.contracts)
        MDMLog.info("MarketDynamics: savegame data loaded")
    else
        -- When NetworkSync is active it delivers the full state to joining clients, so the
        -- own contract-sync request is only the fallback path.
        if not (MDMNetworkSyncBridge ~= nil and MDMNetworkSyncBridge.stateActive) then
            MDMContractSyncRequestEvent.sendToServer()
            MDMLog.info("MarketDynamics: requested contract sync from server")
        end
    end

    -- Register with SettingsHub (if installed) so FarmTablet's System Settings
    -- app can list Market Dynamics' settings. No-ops safely if SettingsHub is absent.
    MDMSettingsHubBridge.register(self)

    self._loadPhase = false
end

-- Per-frame tick. dt = in-game milliseconds from FSBaseMission.update.
function MarketDynamics:update(dt)
    if not self.isActive then return end
    
    -- Wait at least 1 second for session sync, and ensure environment is valid
    if g_currentMission and g_currentMission.time < 1000 then return end
    
    local now = MDMUtil.getGameTime()
    if now <= 0 then return end -- environment not yet initialized

    -- Safety: If we just loaded, wait until 'now' has caught up to 'lastSavedGameTime'
    -- This prevents immediate contract defaults if the day/time hasn't finished syncing.
    if self.lastSavedGameTime and now < self.lastSavedGameTime then
        return
    end

    -- Load-phase guard: skip all expire/restore/price-shift logic during the
    -- initial join/load window. The onStartMission() clears this flag once all
    -- saved state is restored. Without this guard, events can expire and contracts
    -- can default prematurely on MP join because the simulation catches up to saved
    -- timestamps before the client has received its full initial state.
    if self._loadPhase then
        -- Zero timers so they don't accumulate during loading and fire on resume
        self.marketEngine.intradayTimer = 0
        self.marketEngine.dailyTimer = 0
        return
    end

    self.marketEngine:update(dt)              -- intraday and daily price ticks

    -- BUILD 22:27b: warm the price-trend ring here rather than only inside a GUI.
    -- MDMMarketScreenGraph.update samples one point per 20s, and draw needs 2, but it
    -- was called ONLY from MarketScreen:update and the Esc Prices page - both of which
    -- run only while that screen is open. So the trend could not plot until the player
    -- had stared at the page for 40 continuous seconds, which is exactly the "PRICE
    -- TREND still empty" report. Sampling beside the engine tick that moves the prices
    -- means the ring is already warm when a screen opens. Same 20s interval, same real
    -- prices from engine.prices - no invented samples, no extra sampling rate.
    if MDMMarketScreenGraph ~= nil and type(MDMMarketScreenGraph.update) == "function" then
        pcall(MDMMarketScreenGraph.update, dt)
    end
    self.worldEvents:update(dt)               -- event expiry and probability rolls
    self.rweIntegration:update(dt)            -- sync RWE world events + CS stress → price modifiers
    self.futuresMarket:checkExpiry()          -- settle contracts past delivery date
    self.futuresMarket:checkTimeScaleDrift()  -- warn if timeScale changed mid real-day contract
    BCIntegration.update()                    -- expire BC supply-spike modifiers
    
    if self.settingsPanel then
        self.settingsPanel:update(dt)
    end
end

-- Per-frame draw. Delegates to g_MDMHud if the market screen registers one.
-- When MasterHUD is present it owns the draw loop (MDMMasterHUDBridge.drawStack
-- runs the identical body), so this hook stands down to avoid drawing twice.
function MarketDynamics:draw()
    if not self.isActive then return end
    if MDMMasterHUDBridge and MDMMasterHUDBridge.active then return end
    if MDMMasterHUDBridge then
        MDMMasterHUDBridge.drawStack()
        return
    end
    if g_MDMHud then
        g_MDMHud:draw()
    end
    if self.settingsPanel then
        self.settingsPanel:draw()
    end
end

-- Mouse event pass-through
function MarketDynamics:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.isActive then return end
    if g_MDMHud then
        if button == Input.MOUSE_BUTTON_WHEEL_UP or button == Input.MOUSE_BUTTON_WHEEL_DOWN then
            g_MDMHud:scrollEvent(posX, posY, button)
        else
            g_MDMHud:mouseEvent(posX, posY, isDown, isUp, button)
        end
    end
    if self.settingsPanel then
        self.settingsPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    end
end

-- Toggle Settings Panel
function MarketDynamics:toggleSettings()
    MDMLog.info("[MDM] MarketDynamics:toggleSettings triggered")
    if self.settingsPanel then
        self.settingsPanel:toggle()
    else
        MDMLog.warn("[MDM] MarketDynamics:toggleSettings called but settingsPanel is nil")
    end
end

-- Triggered by FSCareerMissionInfo.saveToXMLFile.
function MarketDynamics:save(xmlFile)
    if not self.isActive then return end
    -- Contracts are server-authoritative. On a dedicated server both the headless
    -- process and each connected client receive the saveToXMLFile hook. If clients
    -- are allowed to write, they overwrite the server's correct contract list with
    -- their own (empty or stale) copy. Guard to server only.
    if g_server == nil then return end
    self.serializer:save(self)
end

function MarketDynamics:delete()
    self.isActive = false
    self.rweIntegration:cleanup()
    MDMAdminCommands_remove()
    MDMDialogLoader.cleanup()
    if g_MDMHud then
        g_MDMHud:delete()
    end
    OrganicPremiumBridge.unregister()
    MDMLog.info("MarketDynamics: deleted")
end

-- ---------------------------------------------------------------------------
-- Price Modifier Registry
-- ---------------------------------------------------------------------------

---Register a consumer price modifier. The callback receives a context table and must
---return a positive number (multiplier) or nil to opt out of this fill type.
---@param name string  Unique identifier (e.g. mod name or system name)
---@param fn   function(ctx) -> number|nil
function MarketDynamics:registerPriceModifier(name, fn)
    self.priceModifiers[name] = fn
    MDMLog.info("MarketDynamics: registered price modifier '" .. tostring(name) .. "'")
end

---Remove a previously registered consumer price modifier by name.
---@param name string
function MarketDynamics:unregisterPriceModifier(name)
    self.priceModifiers[name] = nil
    MDMLog.info("MarketDynamics: unregistered price modifier '" .. tostring(name) .. "'")
end

-- ---------------------------------------------------------------------------
-- UI Helpers
-- ---------------------------------------------------------------------------

---Shows a YesNoDialog when a world event starts.
---@param eventListString string Concatenated list of event names.
function MarketDynamics:showEventNotification(eventListString)
    -- If eventListString is not a string (e.g. nil or self from addTimer), 
    -- try to use the stored pending name.
    if type(eventListString) ~= "string" then
        eventListString = self.pendingEventNotificationName
    end
    self.pendingEventNotificationName = nil

    MDMLog.info("MarketDynamics:showEventNotification triggered for: " .. tostring(eventListString))
    
    if not eventListString or eventListString == "" then
        MDMLog.warn("MarketDynamics: notification triggered but event name is nil/empty")
        return
    end

    if not self.settings.showEventNotifications then 
        MDMLog.info("MarketDynamics: notifications disabled in settings")
        return 
    end
    -- Guard against dedicated server (no GUI)
    if g_client == nil or g_gui == nil then 
        MDMLog.info("MarketDynamics: g_client or g_gui is nil")
        return 
    end

    -- getText returns truthy "Missing '…'" when l10n failed to load; never paint that.
    local title = (MDMUtil and MDMUtil.getModText("mdm_screen_title")) or "Market Dynamics"

    if self.settings.eventNotificationBanner then
        -- Discreet, non-modal banner: a quiet in-game notification in the corner
        -- instead of a full-screen modal that dims everything black. Preferred while
        -- driving or working a field (issue #94). The active event is also listed in
        -- the Market Screen's Events tab.
        local msg = string.format("%s: %s", title, eventListString)
        if g_currentMission and g_currentMission.addIngameNotification then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, msg)
            MDMLog.info("MarketDynamics: event notification banner shown")
        else
            MDMLog.warn("MarketDynamics: addIngameNotification unavailable — notification skipped")
        end
    else
        -- Full pop-up dialog (default): asks whether to open the Market Screen.
        local fmt = (MDMUtil and MDMUtil.getModText("mdm_msg_event_started"))
            or "A new world event has started: %s\n\nWould you like to open the Market Screen to see the impact?"
        local text = string.format(fmt, eventListString)

        MDMLog.info("MarketDynamics: calling YesNoDialog.show")
        YesNoDialog.show(function(yes)
            if yes then
                MDMMarketScreen.show()
            end
        end, nil, text, title)
    end
end

-- ---------------------------------------------------------------------------
-- Private
-- ---------------------------------------------------------------------------

function MarketDynamics:_registerDefaultEvents()
    -- Events are self-registering — this just ensures they're called
    -- Each event file calls WorldEventSystem:registerEvent on g_MarketDynamics.worldEvents
    -- Registration happens in events/*.lua after this coordinator is created

    -- Drain deferred registrations pushed by event files at source() time.
    -- Uses MDM_pendingRegistrations (standalone global) because MarketDynamics
    -- didn't exist yet when those files were sourced.
    if MDM_pendingRegistrations then
        for _, reg in ipairs(MDM_pendingRegistrations) do
            self.worldEvents:registerEvent(reg)
        end
        MDM_pendingRegistrations = nil
    end
end
