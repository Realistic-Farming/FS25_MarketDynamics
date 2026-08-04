-- AdminCommands.lua
-- In-game developer console commands for testing and debugging MDM.
-- Commands are registered against the g_MarketDynamics coordinator instance
-- so FS25's console calls them as coordinator:cmdMdmXxx(arg).
--
-- Registered in MarketDynamics:onMissionLoaded via MDMAdminCommands_register().
-- Removed in MarketDynamics:delete()         via MDMAdminCommands_remove().
--
-- Available commands (open console with the tilde key):
--   mdmStatus              system health, active events, price count
--   mdmEvent  <eventId>    force-fire a registered event at full intensity
--   mdmExpire <eventId>    force-expire an active event immediately
--   mdmPrice  <cropName>   show current vs base price for a crop (e.g. mdmPrice wheat)
--   mdmEvents              list all registered events with status and cooldown
--
-- Author: tison (dev-1)

-- ---------------------------------------------------------------------------
-- Command handlers
-- Stored as methods on g_MarketDynamics at registration time so the console
-- can call them as coordinator:cmdMdmXxx(arg). 'self' = coordinator instance.
-- ---------------------------------------------------------------------------

local function cmdStatus(self)
    if not g_MarketDynamics or not g_MarketDynamics.isActive then
        print("[MDM] System is not active")
        return
    end

    local mdm = g_MarketDynamics
    local priceCount = 0
    for _ in pairs(mdm.marketEngine.prices) do priceCount = priceCount + 1 end

    local activeEvents  = mdm.worldEvents:getActiveEvents()
    local registryCount = 0
    for _ in pairs(mdm.worldEvents.registry) do registryCount = registryCount + 1 end

    print("=== MDM Status ===")
    print("  Active:         " .. tostring(mdm.isActive))
    print("  Prices tracked: " .. priceCount .. " fill types")
    print("  Events:         " .. #activeEvents .. " active / " .. registryCount .. " registered")

    if #activeEvents > 0 then
        local now = MDMUtil.getGameTime()
        for _, ev in ipairs(activeEvents) do
            local remaining = math.max(0, ev.endsAt - now)
            local mins      = math.floor(remaining / 60000)
            print(string.format("    [ACTIVE] %-20s  intensity=%.2f  ~%d min remaining",
                ev.name, ev.intensity, mins))
        end
    end
    print("==================")
end

local function cmdRelease(self)
    if not ReleaseGate then
        print("[MDM] Release gate not loaded")
        return
    end
    local optIn = g_MarketDynamics and g_MarketDynamics:allowsExperimentalSystems()
    print(ReleaseGate.status(optIn))
end

local function cmdEvent(self, eventId)
    if not eventId or eventId == "" then
        print("[MDM] Usage: mdmEvent <eventId>")
        print("[MDM] Run 'mdmEvents' to see available IDs")
        return
    end
    if not g_MarketDynamics or not g_MarketDynamics.isActive then
        print("[MDM] System not active")
        return
    end

    local ok, err = g_MarketDynamics.worldEvents:forceFireEvent(eventId, 1.0)
    if ok then
        print("[MDM] Fired event '" .. eventId .. "' at full intensity")
        -- Sync to clients (also triggers the event notification dialog on the host)
        if MDMMarketSyncEvent then
            MDMMarketSyncEvent.sendToClients()
        end
    else
        print("[MDM] Failed: " .. (err or "unknown error"))
    end
end

local function cmdExpire(self, eventId)
    if not eventId or eventId == "" then
        print("[MDM] Usage: mdmExpire <eventId>")
        return
    end
    if not g_MarketDynamics or not g_MarketDynamics.isActive then
        print("[MDM] System not active")
        return
    end

    local ok, err = g_MarketDynamics.worldEvents:forceExpireEvent(eventId)
    if ok then
        print("[MDM] Expired event '" .. eventId .. "'")
    else
        print("[MDM] Failed: " .. (err or "unknown error"))
    end
end

local function cmdPrice(self, cropName)
    if not cropName or cropName == "" then
        print("[MDM] Usage: mdmPrice <cropName>  (e.g. mdmPrice wheat)")
        return
    end
    if not g_MarketDynamics or not g_MarketDynamics.isActive then
        print("[MDM] System not active")
        return
    end

    local fillType = g_fillTypeManager:getFillTypeByName(cropName:upper())
    if not fillType then
        print("[MDM] Unknown crop: '" .. cropName .. "'")
        return
    end

    local entry = g_MarketDynamics.marketEngine.prices[fillType.index]
    if not entry then
        print("[MDM] No price data for '" .. cropName .. "' (fillTypeIndex=" .. fillType.index .. ")")
        return
    end

    local changePct = g_MarketDynamics.marketEngine:getPriceChangePercent(fillType.index)
    local modCount  = #entry.modifiers
    print(string.format("[MDM] %s — base: $%.2f  current: $%.2f  (%+.1f%%)  volatility: %.3f  event mods: %d",
        cropName:upper(), entry.base, entry.current, changePct, entry.volatilityFactor, modCount))
end

local function cmdEvents(self)
    if not g_MarketDynamics or not g_MarketDynamics.isActive then
        print("[MDM] System not active")
        return
    end

    local now = MDMUtil.getGameTime()
    print("=== MDM Registered Events ===")
    for id, event in pairs(g_MarketDynamics.worldEvents.registry) do
        local active = g_MarketDynamics.worldEvents.active[id]
        local status
        if active then
            local mins = math.floor(math.max(0, active.endsAt - now) / 60000)
            status = string.format("ACTIVE (%.2f intensity, ~%d min left)", active.intensity, mins)
        else
            local cooldownLeft = math.max(0, (event.lastFiredAt + (event.cooldownMs or 0)) - now)
            if cooldownLeft > 0 then
                status = string.format("cooldown (~%d min)", math.floor(cooldownLeft / 60000))
            else
                status = "ready"
            end
        end
        print(string.format("  %-22s  p=%.2f  %s", id, event.probability, status))
    end
    print("=============================")
end

-- ---------------------------------------------------------------------------
-- mdmReloadGui — hot-reload all MDM dialogs without restarting the game.
--
-- What it does:
--   1. Closes any open MDM dialog gracefully.
--   2. Clears the MDMDialogLoader registry (sets loaded=false, instance=nil)
--      so the next show() call re-runs g_gui:loadGui() from disk.
--   3. Re-registers the three modal dialogs so they are ready for use again.
--
-- What it does NOT do:
--   - It does not reload MarketScreen (the InGameMenu tab frame).
--     Reloading a TabbedMenuFrameElement requires re-running
--     MDMMarketScreen.register(), which hooks into InGameMenu and is only
--     safe to do once per session. Move/resize those elements in XML and
--     reload the full session instead.
--   - It does not reload SettingsUI, which is similarly a one-time init.
--
-- Usage (tilde console):
--   mdmReloadGui
-- ---------------------------------------------------------------------------

local function cmdReloadGui(self)
    if not g_MarketDynamics or not g_MarketDynamics.isActive then
        print("[MDM] mdmReloadGui: system not active")
        return
    end

    if not g_currentMission or not (not g_currentMission.isServer or g_currentMission.isClient) then
        print("[MDM] mdmReloadGui: no GUI on dedicated server — nothing to reload")
        return
    end

    print("[MDM] mdmReloadGui: closing open dialogs ...")

    -- Close whichever modal is currently visible (safe to call even if closed)
    MDMDialogLoader.close("MDMContractDialog")
    MDMDialogLoader.close("MDMContractAdminDialog")
    MDMDialogLoader.close("MDMCustomInputDialog")

    -- Wipe the loader state so the next show() call forces a fresh loadGui()
    MDMDialogLoader.cleanup()

    -- Re-register all three modal dialogs (same list as onMissionLoaded)
    local modDir = g_MarketDynamics.modDir
    MDMDialogLoader.init(modDir)
    MDMDialogLoader.register("MDMContractDialog",      MDMContractDialog,      "xml/gui/MDMContractDialog.xml")
    MDMDialogLoader.register("MDMContractAdminDialog", MDMContractAdminDialog, "xml/gui/MDMContractAdminDialog.xml")
    MDMDialogLoader.register("MDMCustomInputDialog",   MDMCustomInputDialog,   "xml/gui/MDMCustomInputDialog.xml")
    MDMDialogLoader.register("MDMBrowseFillTypesDialog", MDMBrowseFillTypesDialog, "xml/gui/MDMBrowseFillTypesDialog.xml")
    MDMDialogLoader.register("MDMEventSettingsDialog", MDMEventSettingsDialog, "xml/gui/MDMEventSettingsDialog.xml")
    MDMDialogLoader.register("MDMEventFillTypeDialog", MDMEventFillTypeDialog, "xml/gui/MDMEventFillTypeDialog.xml")

    print("[MDM] mdmReloadGui: done — 4 dialogs will reload from XML on next open")
    print("[MDM]   MDMContractDialog      -> xml/gui/MDMContractDialog.xml")
    print("[MDM]   MDMContractAdminDialog -> xml/gui/MDMContractAdminDialog.xml")
    print("[MDM]   MDMCustomInputDialog   -> xml/gui/MDMCustomInputDialog.xml")
    print("[MDM]   MDMBrowseFillTypesDialog -> xml/gui/MDMBrowseFillTypesDialog.xml")
    print("[MDM] Tip: MarketScreen tab and SettingsUI require a full session restart.")
end

-- ---------------------------------------------------------------------------
-- Registration / removal — called from MarketDynamics lifecycle
-- ---------------------------------------------------------------------------

function MDMAdminCommands_register()
    g_MarketDynamics.cmdMdmStatus    = cmdStatus
    g_MarketDynamics.cmdMdmEvent     = cmdEvent
    g_MarketDynamics.cmdMdmExpire    = cmdExpire
    g_MarketDynamics.cmdMdmPrice     = cmdPrice
    g_MarketDynamics.cmdMdmEvents    = cmdEvents
    g_MarketDynamics.cmdMdmReloadGui = cmdReloadGui
    g_MarketDynamics.cmdMdmRelease   = cmdRelease

    addConsoleCommand("mdmStatus",    "MDM: system health and active events",          "cmdMdmStatus",    g_MarketDynamics)
    addConsoleCommand("mdmEvent",     "MDM: force-fire event (arg: eventId)",          "cmdMdmEvent",     g_MarketDynamics)
    addConsoleCommand("mdmExpire",    "MDM: force-expire active event (arg: eventId)", "cmdMdmExpire",    g_MarketDynamics)
    addConsoleCommand("mdmPrice",     "MDM: show price for a crop (arg: cropName)",    "cmdMdmPrice",     g_MarketDynamics)
    addConsoleCommand("mdmEvents",    "MDM: list all registered events and status",    "cmdMdmEvents",    g_MarketDynamics)
    addConsoleCommand("mdmReloadGui", "MDM: hot-reload modal dialog XML without restart", "cmdMdmReloadGui", g_MarketDynamics)
    addConsoleCommand("mdmRelease",   "MDM: release gate status (STABLE vs LOCKED)",   "cmdMdmRelease",   g_MarketDynamics)

    MDMLog.info("AdminCommands: registered 7 console commands")
end

function MDMAdminCommands_remove()
    removeConsoleCommand("mdmStatus")
    removeConsoleCommand("mdmEvent")
    removeConsoleCommand("mdmExpire")
    removeConsoleCommand("mdmPrice")
    removeConsoleCommand("mdmEvents")
    removeConsoleCommand("mdmReloadGui")
    removeConsoleCommand("mdmRelease")
end