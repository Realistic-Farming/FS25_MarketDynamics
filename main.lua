-- FS25_MarketDynamics / main.lua
-- Entry point. Loads all modules in dependency order, then hooks into the game lifecycle.
-- Log prefix: [MDM]  |  Global: g_MarketDynamics
--
-- Authors: TheCodingDad (tison) — core systems
--          LeGrizzly             — GUI systems

local modDirectory = (MarketDynamicsModDirectory or g_currentModDirectory)
local modName      = (MarketDynamicsModName or g_currentModName)

source(modDirectory .. "src/integrations/OptionScalingResolver.lua")

-- Menu icon global (resolved by XML imageFilename via hook below)
g_MDMIconMenu = Utils.getFilename("images/menuIcon.dds", (MarketDynamicsModDirectory or g_currentModDirectory))

-- Resolve mod icon globals in XML imageFilename attributes (EmployeeManager pattern)
local MDM_ICON_GLOBALS = {
    g_MDMIconMenu = true,
}

local function mdmResolveFilename(self, superFunc)
    local filename = superFunc(self)
    if MDM_ICON_GLOBALS[filename] then
        return _G[filename]
    end
    return filename
end

GuiOverlay.resolveFilename = Utils.overwrittenFunction(GuiOverlay.resolveFilename, mdmResolveFilename)

-- ---------------------------------------------------------------------------
-- Lifecycle hooks
-- ---------------------------------------------------------------------------

local mdm = nil  -- will hold the MarketDynamics instance

local function onLoad(mission)
    mdm = MarketDynamics.new(modDirectory, modName)
    getfenv(0)["g_MarketDynamics"] = mdm
    if g_currentMission then
        g_currentMission.MarketDynamics = mdm
    end
    -- BUILD 11:43: publish the graph class the same way the instance is published above.
    -- The Esc door is hosted by whichever suite mod bootstrapped first, and from that
    -- environment a bare MDMMarketScreenGraph is nil. It was reachable only by guessing
    -- our g_modEnvironments key, which is exactly what failed on the Dairy door
    -- (GATE log: graph=false). Putting it in the real global table and on the mission
    -- makes it findable without anyone knowing our mod name.
    if MDMMarketScreenGraph ~= nil then
        getfenv(0)["MDMMarketScreenGraph"] = MDMMarketScreenGraph
        if g_currentMission then
            g_currentMission.MDMMarketScreenGraph = MDMMarketScreenGraph
        end
    end
    -- BUILD 12:32: the guest needs the same treatment. It sits in exactly the position
    -- the graph class was in before 11:43 - reachable from a foreign door only through
    -- belts that evidently do not reach - so the host resolved nil, selectCommodityIndex
    -- never fired, and picking a row moved the highlight without moving the trend.
    if MdRfPdaGuest ~= nil then
        getfenv(0)["MdRfPdaGuest"] = MdRfPdaGuest
        if g_currentMission then
            g_currentMission.MdRfPdaGuest = MdRfPdaGuest
        end
    end
end

local function onLoadFinished(mission)
    if mdm then
        mdm:onMissionLoaded(mission)
    end
end

local function onStartMission(mission)
    if mdm then
        mdm:onStartMission(mission)
    end
end

local function onUpdate(mission, dt)
    if mdm then
        mdm:update(dt)
    end
end

local function onDraw(mission)
    if mdm then
        mdm:draw()
    end
end

local function onMouseEvent(mission, posX, posY, isDown, isUp, button)
    if mdm then
        mdm:mouseEvent(posX, posY, isDown, isUp, button, false)
    end
end

local function onSave(mission, xmlFile)
    if mdm then
        mdm:save(xmlFile)
    end
end

local function onDelete(mission)
    if mdm then
        mdm:delete()
        mdm = nil
        getfenv(0)["g_MarketDynamics"] = nil
        getfenv(0)["MDMMarketScreenGraph"] = nil
        getfenv(0)["MdRfPdaGuest"] = nil
        if g_currentMission then
            g_currentMission.MarketDynamics = nil
            g_currentMission.MDMMarketScreenGraph = nil
            g_currentMission.MdRfPdaGuest = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Input Handling (RVB Pattern)
-- ---------------------------------------------------------------------------

local function mdmSettingsActionCallback(self, actionName, inputValue, callbackState, isAnalog)
    if inputValue <= 0 then return end
    if not mdm then return end
    -- Don't open while another dialog is showing
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then return end
    mdm:toggleSettings()
end

local function mdmMarketScreenActionCallback(self, actionName, inputValue, callbackState, isAnalog)
    if inputValue <= 0 then return end
    MDMMarketScreen.toggle()
end

local function mdmCreateContractActionCallback(self, actionName, inputValue, callbackState, isAnalog)
    if inputValue <= 0 then return end
    MDMMarketScreen.onGlobalCreateContract()
end

local function hookMDMInput()
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then
        print("[MDM] PlayerInputComponent.registerActionEvents not available")
        return
    end

    local originalRegister = PlayerInputComponent.registerActionEvents
    PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
        originalRegister(inputComponent, ...)

        if inputComponent.player ~= nil and inputComponent.player.isOwner then
            g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

            -- Market Screen (F10)
            local screenActionId = InputAction.MDM_MARKET_SCREEN
            if screenActionId ~= nil then
                local success, eventId = g_inputBinding:registerActionEvent(
                    screenActionId, nil, mdmMarketScreenActionCallback,
                    false, true, false, true
                )
                if success and eventId then
                    g_inputBinding:setActionEventTextVisibility(eventId, false)
                end
            end

            -- Create Contract (N)
            local contractActionId = InputAction.MDM_CREATE_CONTRACT
            if contractActionId ~= nil then
                local success, eventId = g_inputBinding:registerActionEvent(
                    contractActionId, nil, mdmCreateContractActionCallback,
                    false, true, false, true
                )
                if success and eventId then
                    g_inputBinding:setActionEventTextVisibility(eventId, false)
                end
            end

            -- Settings (F5)
            local settingsActionId = InputAction.MDM_OPEN_SETTINGS
            if settingsActionId ~= nil then
                local success, eventId = g_inputBinding:registerActionEvent(
                    settingsActionId, nil, mdmSettingsActionCallback,
                    false, true, false, true
                )
                if success and eventId then
                    g_inputBinding:setActionEventTextVisibility(eventId, false)
                    g_inputBinding:setActionEventActive(eventId, true)
                    MDMLog.info("[MDM] F5 Settings panel toggle registered via hook")
                end
            end

            g_inputBinding:endActionEventsModification()
        end
    end
end

-- Call hook at source time
hookMDMInput()

-- Attach to game hooks
Mission00.load                  = Utils.prependedFunction(Mission00.load,                  onLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished,  onLoadFinished)
Mission00.onStartMission        = Utils.appendedFunction(Mission00.onStartMission,         onStartMission)
FSBaseMission.update            = Utils.appendedFunction(FSBaseMission.update,             onUpdate)
FSBaseMission.draw              = Utils.appendedFunction(FSBaseMission.draw,               onDraw)
FSBaseMission.mouseEvent        = Utils.appendedFunction(FSBaseMission.mouseEvent,         onMouseEvent)
FSBaseMission.saveSavegame      = Utils.appendedFunction(FSBaseMission.saveSavegame,       onSave)
FSBaseMission.delete            = Utils.appendedFunction(FSBaseMission.delete,             onDelete)
