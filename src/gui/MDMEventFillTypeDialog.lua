-- MDMEventFillTypeDialog.lua
-- Per-event custom fill type editor.
-- Players add/remove fill type names that should also be affected when
-- a specific world event fires. The list is stored in
-- g_MarketDynamics.settings.eventCustomFillTypes[eventId].
--
-- Up to 8 custom fill types per event.
-- Names are validated against g_fillTypeManager at add time.
-- Changes take effect on the NEXT firing of the event.
--
-- Opened by MDMEventSettingsDialog:_handleEdit(rowIndex).

MDMEventFillTypeDialog = MDMEventFillTypeDialog or {}
local MDMEventFillTypeDialog_mt = Class(MDMEventFillTypeDialog, MessageDialog)

local MAX_ROWS = 8

function MDMEventFillTypeDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or MDMEventFillTypeDialog_mt)

    self.eventId   = nil
    self.eventName = nil
    self._onDone   = nil
    self.isOpen    = false

    self.dlgTitle   = nil
    self.dlgHint    = nil
    self.emptyText  = nil
    self.addInput   = nil
    self.addBtn     = nil
    self.addBtnTxt  = nil

    -- Row element tables, indexed 0..MAX_ROWS-1
    self.rowNames   = {}
    self.rowRemBgs  = {}
    self.rowRemBtns = {}
    self.rowRemTxts = {}

    return self
end

function MDMEventFillTypeDialog:setData(params)
    self.eventId   = params.eventId
    self.eventName = params.eventName
    self._onDone   = params.onDone
end

function MDMEventFillTypeDialog:onCreate()
    local ok, err = pcall(function() MDMEventFillTypeDialog:superClass().onCreate(self) end)
    if not ok then MDMLog.warn("MDMEventFillTypeDialog:onCreate error: " .. tostring(err)) end
end

function MDMEventFillTypeDialog:onGuiSetupFinished()
    MDMEventFillTypeDialog:superClass().onGuiSetupFinished(self)

    self.dlgTitle  = self:getDescendantById("evtFtTitle")
    self.dlgHint   = self:getDescendantById("evtFtHint")
    self.emptyText = self:getDescendantById("evtFtEmpty")
    self.addInput  = self:getDescendantById("evtFtInput")
    self.addBtn    = self:getDescendantById("evtFtAddBtn")
    self.addBtnTxt = self:getDescendantById("evtFtAddBtnTxt")

    for i = 0, MAX_ROWS - 1 do
        self.rowNames[i]   = self:getDescendantById("evtFtName"   .. i)
        self.rowRemBgs[i]  = self:getDescendantById("evtFtRemBg"  .. i)
        self.rowRemBtns[i] = self:getDescendantById("evtFtRemBtn" .. i)
        self.rowRemTxts[i] = self:getDescendantById("evtFtRemTxt" .. i)
    end
end

function MDMEventFillTypeDialog:onOpen()
    MDMEventFillTypeDialog:superClass().onOpen(self)
    self.isOpen     = true
    self._isPending = false

    if self.dlgTitle then
        local suffix = g_i18n:getText("mdm_evt_ft_title_suffix")
        self.dlgTitle:setText((self.eventName or "Event") .. suffix)
    end
    self:_showIdleHint()
    if self.addInput then
        self.addInput:setText("")
    end

    self:_refreshRows()

    -- Security: Disable buttons for non-admins
    local isAdmin = g_currentMission:getIsServer() or g_currentMission.isAdmin or g_currentMission.isMasterUser
    if not isAdmin then
        if self.addBtn then self.addBtn:setDisabled(true) end
        for i = 0, MAX_ROWS - 1 do
            if self.rowRemBtns[i] then self.rowRemBtns[i]:setDisabled(true) end
        end
    end
end

function MDMEventFillTypeDialog:onClose()
    self.isOpen     = false
    self._isPending = false
    MDMEventFillTypeDialog:superClass().onClose(self)
    if self._onDone then self._onDone() end
end

function MDMEventFillTypeDialog:onCloseClick()
    self:close()
end

function MDMEventFillTypeDialog:onBrowseClick()
    MDMDialogLoader.show("MDMBrowseFillTypesDialog", "setCallback", function(fillTypeName)
        if self.isOpen and self.addInput then
            self.addInput:setText(fillTypeName)
        end
    end)
end

function MDMEventFillTypeDialog:setFillType(fillTypeName)
    if self.addInput then
        self.addInput:setText(fillTypeName)
    end
end

-- ── Hint helpers ──────────────────────────────────────────────────────────────

-- Show the idle hint: instructions + a list of all price-tracked fill types so
-- players can discover the correct names for third-party mod crops.
function MDMEventFillTypeDialog:_showIdleHint()
    if not self.dlgHint then return end
    local hint = g_i18n:getText("mdm_evt_ft_hint")
    local browseList = self:_buildAvailableFillTypeList()
    if browseList ~= "" then
        hint = hint .. "\n" .. g_i18n:getText("mdm_evt_ft_browse") .. browseList
    end
    self.dlgHint:setText(hint)
    self.dlgHint:setTextColor(0.65, 0.65, 0.65, 1.0)
end

-- Return a compact comma-separated string of all fill types currently tracked
-- by MarketEngine — this includes every vanilla and third-party mod crop that
-- the game loaded, so players know exactly which names are valid to add.
function MDMEventFillTypeDialog:_buildAvailableFillTypeList()
    if not g_fillTypeManager or not g_MarketDynamics then return "" end
    local engine = g_MarketDynamics.marketEngine
    local names  = {}
    for _, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        if ft and ft.index and ft.index > 1 and ft.name and ft.name ~= ""
           and engine and engine.prices[ft.index] then
            table.insert(names, ft.name)
        end
    end
    table.sort(names)
    local LIMIT = 15
    local result = table.concat(names, ", ", 1, math.min(LIMIT, #names))
    if #names > LIMIT then
        result = result .. " (+" .. (#names - LIMIT) .. " more)"
    end
    return result
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

function MDMEventFillTypeDialog:_getCurrentList()
    if not g_MarketDynamics or not g_MarketDynamics.settings then return {} end
    local cft = g_MarketDynamics.settings.eventCustomFillTypes
    if not cft then return {} end
    return cft[self.eventId] or {}
end

function MDMEventFillTypeDialog:_setList(list)
    if not g_MarketDynamics or not g_MarketDynamics.settings then return end
    g_MarketDynamics.settings.eventCustomFillTypes = g_MarketDynamics.settings.eventCustomFillTypes or {}
    g_MarketDynamics.settings.eventCustomFillTypes[self.eventId] = list
end

function MDMEventFillTypeDialog:_refreshRows()
    local list  = self:_getCurrentList()
    local count = #list

    if self.emptyText then
        self.emptyText:setVisible(count == 0)
    end

    for i = 0, MAX_ROWS - 1 do
        local hasEntry = (i + 1) <= count

        if self.rowNames[i] then
            self.rowNames[i]:setText(hasEntry and list[i + 1] or "")
            self.rowNames[i]:setVisible(hasEntry)
        end
        if self.rowRemBgs[i]  then self.rowRemBgs[i]:setVisible(hasEntry)  end
        if self.rowRemBtns[i] then self.rowRemBtns[i]:setVisible(hasEntry) end
        if self.rowRemTxts[i] then self.rowRemTxts[i]:setVisible(hasEntry) end
    end

    -- Disable Add button when at capacity
    if self.addBtn then
        self.addBtn:setDisabled(count >= MAX_ROWS)
    end
    if self.addBtnTxt then
        if count >= MAX_ROWS then
            self.addBtnTxt:setTextColor(0.45, 0.45, 0.45, 1.0)
        else
            self.addBtnTxt:setTextColor(1.0, 1.0, 1.0, 1.0)
        end
    end
end

function MDMEventFillTypeDialog:_removeAt(rowIndex)
    local list = self:_getCurrentList()
    local idx  = rowIndex + 1
    if idx > #list then return end

    local removed = list[idx]
    table.remove(list, idx)
    self:_setList(list)
    self:_refreshRows()
    MDMLog.info("MDMEventFillTypeDialog: removed '" .. tostring(removed) .. "' from event '" .. tostring(self.eventId) .. "'")

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

-- ── Add handler ───────────────────────────────────────────────────────────────

function MDMEventFillTypeDialog:onAddClick()
    if not self.addInput then return end

    local raw  = self.addInput:getText() or ""
    local name = raw:upper():match("^%s*(.-)%s*$")  -- trim + uppercase

    if name == "" then return end

    -- Validate: fill type must exist in the game
    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(name)
    if not ft then
        if self.dlgHint then
            self.dlgHint:setText(g_i18n:getText("mdm_evt_ft_not_found") .. name)
            self.dlgHint:setTextColor(0.9, 0.3, 0.2, 1.0)
        end
        return
    end

    -- Check duplicate
    local list = self:_getCurrentList()
    for _, existing in ipairs(list) do
        if existing == name then
            if self.dlgHint then
                self.dlgHint:setText(g_i18n:getText("mdm_evt_ft_duplicate") .. name)
                self.dlgHint:setTextColor(0.9, 0.78, 0.1, 1.0)
            end
            return
        end
    end

    -- Capacity check
    if #list >= MAX_ROWS then return end

    table.insert(list, name)
    self:_setList(list)
    self.addInput:setText("")

    if self.dlgHint then
        self.dlgHint:setText(g_i18n:getText("mdm_evt_ft_added") .. (ft.title or name))
        self.dlgHint:setTextColor(0.25, 0.82, 0.48, 1.0)
    end

    self:_refreshRows()
    MDMLog.info("MDMEventFillTypeDialog: added '" .. name .. "' to event '" .. tostring(self.eventId) .. "'")

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

-- ── Per-row remove handlers ───────────────────────────────────────────────────

function MDMEventFillTypeDialog:onRemove0() self:_removeAt(0) end
function MDMEventFillTypeDialog:onRemove1() self:_removeAt(1) end
function MDMEventFillTypeDialog:onRemove2() self:_removeAt(2) end
function MDMEventFillTypeDialog:onRemove3() self:_removeAt(3) end
function MDMEventFillTypeDialog:onRemove4() self:_removeAt(4) end
function MDMEventFillTypeDialog:onRemove5() self:_removeAt(5) end
function MDMEventFillTypeDialog:onRemove6() self:_removeAt(6) end
function MDMEventFillTypeDialog:onRemove7() self:_removeAt(7) end
