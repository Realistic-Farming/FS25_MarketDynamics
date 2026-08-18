-- MDMEventSettingsDialog.lua
-- Event settings dialog: global toggles + per-event on/off + custom fill type editor.
--
-- Global section:
--   Events Enabled (on/off)
--   Event Frequency (Rare / Normal / Frequent)
--
-- Per-event section (10 rows, alphabetically sorted):
--   Event name | Enabled/Disabled toggle | Custom fill type count | [Edit] | [Force Fire / Stop]
--   [Edit] opens MDMEventFillTypeDialog for that specific event.
--   [Force Fire] immediately fires the event at full intensity for testing.
--   [Stop]       immediately expires an active event.
--
-- All settings are applied immediately to g_MarketDynamics.settings and
-- persisted on the next game save via MarketSerializer.
--
-- Opened by MDMMarketScreen:onEventSettingsClick() from the Events tab.

MDMEventSettingsDialog = {}
local MDMEventSettingsDialog_mt = Class(MDMEventSettingsDialog, MessageDialog)

local MAX_EVENT_ROWS = 10
local FREQ_RARE      = 0.4
local FREQ_NORMAL    = 1.0
local FREQ_HIGH      = 2.0

function MDMEventSettingsDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or MDMEventSettingsDialog_mt)

    self.isOpen       = false
    self._onClose     = nil
    self.fillTypeHint = nil

    -- Global section elements
    self.globalOffBg   = nil; self.globalOffBtn  = nil; self.globalOffTxt  = nil
    self.globalOnBg    = nil; self.globalOnBtn   = nil; self.globalOnTxt   = nil
    self.freqRareBg    = nil; self.freqRareBtn   = nil; self.freqRareTxt   = nil
    self.freqNormalBg  = nil; self.freqNormalBtn = nil; self.freqNormalTxt = nil
    self.freqHighBg    = nil; self.freqHighBtn   = nil; self.freqHighTxt   = nil

    -- Per-event row elements (indexed 0..9)
    self.rowNames      = {}
    self.rowTogBgs     = {}
    self.rowTogBtns    = {}
    self.rowTogTxts    = {}
    self.rowCounts     = {}
    self.rowEditBgs    = {}
    self.rowEditBtns   = {}
    self.rowEditTxts   = {}
    self.rowForceBgs   = {}
    self.rowForceBtns  = {}
    self.rowForceTxts  = {}

    -- Sorted event list built at onOpen
    self._eventOrder = {}

    return self
end

function MDMEventSettingsDialog:setData(params)
    self._onClose = params and params.onClose
end

function MDMEventSettingsDialog:onCreate()
    local ok, err = pcall(function() MDMEventSettingsDialog:superClass().onCreate(self) end)
    if not ok then MDMLog.warn("MDMEventSettingsDialog:onCreate error: " .. tostring(err)) end
end

function MDMEventSettingsDialog:onGuiSetupFinished()
    MDMEventSettingsDialog:superClass().onGuiSetupFinished(self)

    -- Global elements
    self.globalOffBg  = self:getDescendantById("evtGlobalOffBg")
    self.globalOffBtn = self:getDescendantById("evtGlobalOffBtn")
    self.globalOffTxt = self:getDescendantById("evtGlobalOffTxt")
    self.globalOnBg   = self:getDescendantById("evtGlobalOnBg")
    self.globalOnBtn  = self:getDescendantById("evtGlobalOnBtn")
    self.globalOnTxt  = self:getDescendantById("evtGlobalOnTxt")

    self.freqRareBg    = self:getDescendantById("evtFreqRareBg")
    self.freqRareBtn   = self:getDescendantById("evtFreqRareBtn")
    self.freqRareTxt   = self:getDescendantById("evtFreqRareTxt")
    self.freqNormalBg  = self:getDescendantById("evtFreqNormalBg")
    self.freqNormalBtn = self:getDescendantById("evtFreqNormalBtn")
    self.freqNormalTxt = self:getDescendantById("evtFreqNormalTxt")
    self.freqHighBg    = self:getDescendantById("evtFreqHighBg")
    self.freqHighBtn   = self:getDescendantById("evtFreqHighBtn")
    self.freqHighTxt   = self:getDescendantById("evtFreqHighTxt")

    -- Fill type reference hint
    self.fillTypeHint  = self:getDescendantById("evtSFillTypeHint")
    -- BUILD 15:39 (PB-08): dev-only Test column header.
    self.colHdrTest    = self:getDescendantById("evtSColHdrTest")
    self.fillTypeLabel = self:getDescendantById("evtSFillTypeLabel")

    -- Per-event rows
    for i = 0, MAX_EVENT_ROWS - 1 do
        self.rowNames[i]     = self:getDescendantById("evtRowName"     .. i)
        self.rowTogBgs[i]    = self:getDescendantById("evtRowTogBg"    .. i)
        self.rowTogBtns[i]   = self:getDescendantById("evtRowTogBtn"   .. i)
        self.rowTogTxts[i]   = self:getDescendantById("evtRowTogTxt"   .. i)
        self.rowCounts[i]    = self:getDescendantById("evtRowCount"    .. i)
        self.rowEditBgs[i]   = self:getDescendantById("evtRowEditBg"   .. i)
        self.rowEditBtns[i]  = self:getDescendantById("evtRowEditBtn"  .. i)
        self.rowEditTxts[i]  = self:getDescendantById("evtRowEditTxt"  .. i)
        self.rowForceBgs[i]  = self:getDescendantById("evtRowForceBg"  .. i)
        self.rowForceBtns[i] = self:getDescendantById("evtRowForceBtn" .. i)
        self.rowForceTxts[i] = self:getDescendantById("evtRowForceTxt" .. i)
    end
end

function MDMEventSettingsDialog:onOpen()
    MDMEventSettingsDialog:superClass().onOpen(self)
    self.isOpen     = true
    self._isPending = false

    -- Build sorted event list
    self._eventOrder = {}
    if g_MarketDynamics and g_MarketDynamics.worldEvents then
        for id, ev in pairs(g_MarketDynamics.worldEvents.registry) do
            local name = MDMUtil.resolveEventName(ev)
            table.insert(self._eventOrder, { id = id, name = name })
        end
        table.sort(self._eventOrder, function(a, b) return a.name < b.name end)
    end

    self:_refreshGlobal()
    self:_refreshEventRows()
    self:_refreshFillTypeHint()

    -- Security: Disable all buttons for non-admins.
    -- isMasterUser covers the ESC "Master Admin" role on dedicated servers
    -- where isAdmin may not be set at dialog-open time.
    local isAdmin = g_currentMission:getIsServer()
        or g_currentMission.isAdmin
        or g_currentMission.isMasterUser
    if not isAdmin then
        if self.globalOffBtn  then self.globalOffBtn:setDisabled(true)  end
        if self.globalOnBtn   then self.globalOnBtn:setDisabled(true)   end
        if self.freqRareBtn   then self.freqRareBtn:setDisabled(true)   end
        if self.freqNormalBtn then self.freqNormalBtn:setDisabled(true) end
        if self.freqHighBtn   then self.freqHighBtn:setDisabled(true)   end

        for i = 0, MAX_EVENT_ROWS - 1 do
            if self.rowTogBtns[i]   then self.rowTogBtns[i]:setDisabled(true)   end
            if self.rowEditBtns[i]  then self.rowEditBtns[i]:setDisabled(true)  end
            if self.rowForceBtns[i] then self.rowForceBtns[i]:setDisabled(true) end
        end
    end
end

function MDMEventSettingsDialog:onClose()
    self.isOpen     = false
    self._isPending = false
    MDMEventSettingsDialog:superClass().onClose(self)
    if self._onClose then self._onClose() end
end

function MDMEventSettingsDialog:onCloseClick()
    self:close()
end

-- ── Global section ────────────────────────────────────────────────────────────

function MDMEventSettingsDialog:_refreshGlobal()
    local s = g_MarketDynamics and g_MarketDynamics.settings
    if not s then return end

    local enabled = s.eventsEnabled ~= false
    local freq    = s.eventFrequency or FREQ_NORMAL

    -- Events enabled toggle
    self:_styleToggle(self.globalOffBg, self.globalOffTxt, not enabled, false)
    self:_styleToggle(self.globalOnBg,  self.globalOnTxt,  enabled,     true)

    -- Frequency
    local isRare   = math.abs(freq - FREQ_RARE)   < 0.05
    local isNormal = math.abs(freq - FREQ_NORMAL) < 0.05
    local isHigh   = not isRare and not isNormal

    self:_styleToggle(self.freqRareBg,   self.freqRareTxt,   isRare,   true)
    self:_styleToggle(self.freqNormalBg, self.freqNormalTxt, isNormal, true)
    self:_styleToggle(self.freqHighBg,   self.freqHighTxt,   isHigh,   true)
end

-- Active: MDM green bg + white text. Inactive: dim bg + dim text.
function MDMEventSettingsDialog:_styleToggle(bgEl, txtEl, isActive, isPositive)
    if bgEl then
        if isActive then
            local r, g, b = isPositive and 0.0 or 0.35, isPositive and 0.42 or 0.08, isPositive and 0.22 or 0.08
            bgEl:setImageColor(nil, r, g, b, 1.0)
        else
            bgEl:setImageColor(nil, 0.14, 0.14, 0.14, 0.9)
        end
    end
    if txtEl then
        if isActive then
            txtEl:setTextColor(1.0, 1.0, 1.0, 1.0)
        else
            txtEl:setTextColor(0.50, 0.50, 0.50, 1.0)
        end
    end
end

function MDMEventSettingsDialog:onGlobalOffClick()
    if not g_MarketDynamics then return end
    g_MarketDynamics.settings.eventsEnabled = false
    self:_refreshGlobal()

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

function MDMEventSettingsDialog:onGlobalOnClick()
    if not g_MarketDynamics then return end
    g_MarketDynamics.settings.eventsEnabled = true
    self:_refreshGlobal()

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

function MDMEventSettingsDialog:onFreqRareClick()
    if not g_MarketDynamics then return end
    g_MarketDynamics.settings.eventFrequency = FREQ_RARE
    self:_refreshGlobal()

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

function MDMEventSettingsDialog:onFreqNormalClick()
    if not g_MarketDynamics then return end
    g_MarketDynamics.settings.eventFrequency = FREQ_NORMAL
    self:_refreshGlobal()

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

function MDMEventSettingsDialog:onFreqHighClick()
    if not g_MarketDynamics then return end
    g_MarketDynamics.settings.eventFrequency = FREQ_HIGH
    self:_refreshGlobal()

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

-- ── Fill type reference hint ──────────────────────────────────────────────────

--- BUILD 15:39 (PB-08). Is this dialog being shown on a developer surface?
---
--- `settings.debugMode` is the player-visible developer switch Market Dynamics
--- already ships (Settings ▸ Display ▸ Debug Mode). Off, which is the default
--- and what every normal save runs, this is a player surface: no dev triggers,
--- no internal identifiers. On, the developer view comes back in full.
---@return boolean
function MDMEventSettingsDialog:_isDevSurface()
    local s = g_MarketDynamics and g_MarketDynamics.settings
    return s ~= nil and s.debugMode == true
end

-- Populate the tracked-fill-type section at the bottom of the dialog.
--
-- BUILD 15:39 (PB-08). This used to print every tracked fill type's INTERNAL
-- name, sorted and dot-joined - a long line of raw uppercase-ish engine keys
-- that ran past the edge of its box and truncated mid-token. That is a
-- developer reference on a player screen. Players now get the plain categories
-- the engine tracks and a count; the raw key list is still there verbatim on the
-- dev surface, because typing a name into the fill type editor is exactly the
-- job it was written for.
function MDMEventSettingsDialog:_refreshFillTypeHint()
    if not self.fillTypeHint then return end
    if self:_isDevSurface() then
        local list = self:_buildAvailableFillTypeList()
        self.fillTypeHint:setText(list ~= "" and list or "-")
        return
    end
    self.fillTypeHint:setText(self:_buildTrackedCategorySummary())
end

--- Player-language summary: which categories are tracked, and how many types.
--- Categories come from the fill type's own title, never its internal name.
function MDMEventSettingsDialog:_buildTrackedCategorySummary()
    if not g_fillTypeManager or not g_MarketDynamics then return "-" end
    local engine = g_MarketDynamics.marketEngine
    if engine == nil or engine.prices == nil then return "-" end

    -- The categories Market Dynamics prices, in the order a player thinks about
    -- them. `match` is checked against the fill type's own category/name, so a
    -- mod crop lands in Crops rather than in a bucket of its own.
    local CATEGORIES = {
        { key = "mdm_cat_crops",     fb = "Crops",     n = 0 },
        { key = "mdm_cat_silage",    fb = "Silage",    n = 0 },
        { key = "mdm_cat_livestock", fb = "Livestock", n = 0 },
        { key = "mdm_cat_other",     fb = "Other",     n = 0 },
    }
    local SILAGE    = { silage = true, chaff = true, grass_windrow = true, drygrass_windrow = true, hay = true, straw = true }
    local LIVESTOCK = { cow = true, sheep = true, pig = true, chicken = true, horse = true, goat = true, milk = true, egg = true, wool = true }

    local total = 0
    for _, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        if ft and ft.index and ft.index > 1 and ft.name and ft.name ~= ""
           and engine.prices[ft.index] then
            total = total + 1
            local n = string.lower(ft.name)
            local slot
            if LIVESTOCK[n] then slot = 3
            elseif SILAGE[n] then slot = 2
            elseif ft.showOnPriceTable ~= false then slot = 1
            else slot = 4 end
            CATEGORIES[slot].n = CATEGORIES[slot].n + 1
        end
    end

    if total == 0 then return "-" end

    local parts = {}
    for _, c in ipairs(CATEGORIES) do
        if c.n > 0 then
            local label = (g_i18n and g_i18n:hasText(c.key)) and g_i18n:getText(c.key) or c.fb
            table.insert(parts, string.format("%s (%d)", label, c.n))
        end
    end
    return table.concat(parts, "   ")
end

function MDMEventSettingsDialog:_buildAvailableFillTypeList()
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
    return table.concat(names, "  ·  ")
end

-- ── Per-event rows ────────────────────────────────────────────────────────────

function MDMEventSettingsDialog:_refreshEventRows()
    -- BUILD 15:39 (PB-08): the Test column header follows its buttons.
    if self.colHdrTest ~= nil then
        self.colHdrTest:setVisible(self:_isDevSurface())
    end

    local s        = g_MarketDynamics and g_MarketDynamics.settings
    local disabled = (s and s.disabledEvents)         or {}
    local cft      = (s and s.eventCustomFillTypes)   or {}
    local active   = (g_MarketDynamics and g_MarketDynamics.worldEvents and
                      g_MarketDynamics.worldEvents.active) or {}

    for i = 0, MAX_EVENT_ROWS - 1 do
        local entry  = self._eventOrder[i + 1]
        local hasRow = entry ~= nil

        -- Visibility: all row elements together
        local function setVis(el) if el then el:setVisible(hasRow) end end
        setVis(self.rowNames[i]);    setVis(self.rowTogBgs[i]);   setVis(self.rowTogBtns[i])
        setVis(self.rowTogTxts[i]);  setVis(self.rowCounts[i]);   setVis(self.rowEditBgs[i])
        setVis(self.rowEditBtns[i]); setVis(self.rowEditTxts[i])

        -- BUILD 15:39 (PB-08). The Test column is a developer trigger: it fires
        -- a world event at full intensity on demand. It stays on the dev surface
        -- and is not shipped to players. `mdmForceEvent` in AdminCommands is the
        -- unchanged console route, so nothing is lost for the people who use it.
        local devSurface = self:_isDevSurface()
        local function setDevVis(el) if el then el:setVisible(hasRow and devSurface) end end
        setDevVis(self.rowForceBgs[i]); setDevVis(self.rowForceBtns[i]); setDevVis(self.rowForceTxts[i])

        if hasRow then
            local id          = entry.id
            local isDisabled  = disabled[id] == true
            local isActive    = active[id] ~= nil
            local customCount = cft[id] and #cft[id] or 0

            -- Name
            if self.rowNames[i] then
                self.rowNames[i]:setText(entry.name)
                if isDisabled then
                    self.rowNames[i]:setTextColor(0.45, 0.45, 0.45, 1.0)
                else
                    self.rowNames[i]:setTextColor(1.0, 1.0, 1.0, 1.0)
                end
            end

            -- Toggle button
            if self.rowTogBgs[i] then
                if isDisabled then
                    self.rowTogBgs[i]:setImageColor(nil, 0.35, 0.08, 0.08, 0.9)
                else
                    self.rowTogBgs[i]:setImageColor(nil, 0.05, 0.38, 0.20, 0.9)
                end
            end
            if self.rowTogTxts[i] then
                if isDisabled then
                    self.rowTogTxts[i]:setText(g_i18n:getText("mdm_label_disabled") or "Disabled")
                    self.rowTogTxts[i]:setTextColor(0.85, 0.38, 0.38, 1.0)
                else
                    self.rowTogTxts[i]:setText(g_i18n:getText("mdm_label_enabled") or "Enabled")
                    self.rowTogTxts[i]:setTextColor(0.25, 0.82, 0.48, 1.0)
                end
            end

            -- Custom fill type count badge
            if self.rowCounts[i] then
                if customCount > 0 then
                    self.rowCounts[i]:setText("+" .. customCount)
                    self.rowCounts[i]:setTextColor(0.25, 0.72, 0.48, 1.0)
                else
                    self.rowCounts[i]:setText("")
                end
            end

            -- Force Fire / Stop button: green = idle (fire), amber = active (stop)
            if self.rowForceBgs[i] then
                if isActive then
                    self.rowForceBgs[i]:setImageColor(nil, 0.45, 0.22, 0.04, 0.9)
                else
                    self.rowForceBgs[i]:setImageColor(nil, 0.05, 0.30, 0.15, 0.9)
                end
            end
            if self.rowForceTxts[i] then
                if isActive then
                    self.rowForceTxts[i]:setText(g_i18n:getText("mdm_evt_stop") or "Stop Event")
                    self.rowForceTxts[i]:setTextColor(1.0, 0.68, 0.20, 1.0)
                else
                    self.rowForceTxts[i]:setText(g_i18n:getText("mdm_evt_force_fire") or "Force Fire")
                    self.rowForceTxts[i]:setTextColor(0.25, 0.88, 0.50, 1.0)
                end
            end
        end
    end
end

function MDMEventSettingsDialog:_handleToggle(rowIndex)
    local entry = self._eventOrder[rowIndex + 1]
    if not entry or not g_MarketDynamics then return end

    local s = g_MarketDynamics.settings
    s.disabledEvents = s.disabledEvents or {}

    if s.disabledEvents[entry.id] then
        s.disabledEvents[entry.id] = nil
        MDMLog.info("MDMEventSettingsDialog: enabled event '" .. entry.id .. "'")
    else
        s.disabledEvents[entry.id] = true
        MDMLog.info("MDMEventSettingsDialog: disabled event '" .. entry.id .. "'")
    end

    self:_refreshEventRows()

    if g_server ~= nil then
        MDMSettingsSyncEvent.sendToClients()
    else
        MDMSettingsSyncEvent.sendToServer()
    end
end

function MDMEventSettingsDialog:_handleEdit(rowIndex)
    local entry = self._eventOrder[rowIndex + 1]
    if not entry then return end

    MDMDialogLoader.show("MDMEventFillTypeDialog", "setData", {
        eventId   = entry.id,
        eventName = entry.name,
        onDone    = function()
            self:_refreshEventRows()
        end,
    })
end

-- Force-fire if the event is idle; force-expire if it is currently active.
function MDMEventSettingsDialog:_handleForce(rowIndex)
    -- BUILD 15:39 (PB-08). The buttons are hidden off the dev surface, but the
    -- onClick callbacks still exist on the dialog, so the gate is enforced here
    -- too rather than relying on the control being invisible.
    if not self:_isDevSurface() then
        MDMLog.info("MDMEventSettingsDialog: force ignored (player surface; use mdmForceEvent)")
        return
    end

    local entry = self._eventOrder[rowIndex + 1]
    if not entry or not g_MarketDynamics then return end

    local ws = g_MarketDynamics.worldEvents
    if ws.active[entry.id] then
        ws:forceExpireEvent(entry.id)
        MDMLog.info("MDMEventSettingsDialog: force-expired '" .. entry.id .. "'")
    else
        ws:forceFireEvent(entry.id, 1.0)
        MDMLog.info("MDMEventSettingsDialog: force-fired '" .. entry.id .. "'")
    end

    if MDMMarketSyncEvent then
        MDMMarketSyncEvent.sendToClients()
    end

    self:_refreshEventRows()
end

-- ── Per-row click handlers ────────────────────────────────────────────────────

function MDMEventSettingsDialog:onToggle0() self:_handleToggle(0) end
function MDMEventSettingsDialog:onToggle1() self:_handleToggle(1) end
function MDMEventSettingsDialog:onToggle2() self:_handleToggle(2) end
function MDMEventSettingsDialog:onToggle3() self:_handleToggle(3) end
function MDMEventSettingsDialog:onToggle4() self:_handleToggle(4) end
function MDMEventSettingsDialog:onToggle5() self:_handleToggle(5) end
function MDMEventSettingsDialog:onToggle6() self:_handleToggle(6) end
function MDMEventSettingsDialog:onToggle7() self:_handleToggle(7) end
function MDMEventSettingsDialog:onToggle8() self:_handleToggle(8) end
function MDMEventSettingsDialog:onToggle9() self:_handleToggle(9) end

function MDMEventSettingsDialog:onEdit0() self:_handleEdit(0) end
function MDMEventSettingsDialog:onEdit1() self:_handleEdit(1) end
function MDMEventSettingsDialog:onEdit2() self:_handleEdit(2) end
function MDMEventSettingsDialog:onEdit3() self:_handleEdit(3) end
function MDMEventSettingsDialog:onEdit4() self:_handleEdit(4) end
function MDMEventSettingsDialog:onEdit5() self:_handleEdit(5) end
function MDMEventSettingsDialog:onEdit6() self:_handleEdit(6) end
function MDMEventSettingsDialog:onEdit7() self:_handleEdit(7) end
function MDMEventSettingsDialog:onEdit8() self:_handleEdit(8) end
function MDMEventSettingsDialog:onEdit9() self:_handleEdit(9) end

function MDMEventSettingsDialog:onForce0() self:_handleForce(0) end
function MDMEventSettingsDialog:onForce1() self:_handleForce(1) end
function MDMEventSettingsDialog:onForce2() self:_handleForce(2) end
function MDMEventSettingsDialog:onForce3() self:_handleForce(3) end
function MDMEventSettingsDialog:onForce4() self:_handleForce(4) end
function MDMEventSettingsDialog:onForce5() self:_handleForce(5) end
function MDMEventSettingsDialog:onForce6() self:_handleForce(6) end
function MDMEventSettingsDialog:onForce7() self:_handleForce(7) end
function MDMEventSettingsDialog:onForce8() self:_handleForce(8) end
function MDMEventSettingsDialog:onForce9() self:_handleForce(9) end
