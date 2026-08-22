-- MDMBrowseFillTypesDialog.lua
-- Scrollable list of all available fill types tracked by the market.
-- Opened from MDMEventFillTypeDialog footer.
-- Includes a real-time search/filter input for servers with many fill types.

MDMBrowseFillTypesDialog = MDMBrowseFillTypesDialog or {}
local MDMBrowseFillTypesDialog_mt = Class(MDMBrowseFillTypesDialog, MessageDialog)

function MDMBrowseFillTypesDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or MDMBrowseFillTypesDialog_mt)

    self.isOpen        = false
    self.scrollingLayout = nil
    self.searchInput   = nil
    self._allButtons   = {}  -- { btn = ButtonElement, name = string, title = string }

    return self
end

function MDMBrowseFillTypesDialog:onCreate()
    MDMBrowseFillTypesDialog:superClass().onCreate(self)
end

function MDMBrowseFillTypesDialog:onGuiSetupFinished()
    MDMBrowseFillTypesDialog:superClass().onGuiSetupFinished(self)
    self.scrollingLayout = self:getDescendantById("scrollingLayout")
    self.searchInput     = self:getDescendantById("browseSearchInput")
end

function MDMBrowseFillTypesDialog:onOpen()
    MDMBrowseFillTypesDialog:superClass().onOpen(self)
    self.isOpen = true
    self._isPending = false

    -- Clear stale search text and show all items
    if self.searchInput then
        self.searchInput:setText("")
    end
    self:_populate()
    self:_applyFilter("")
end

function MDMBrowseFillTypesDialog:setCallback(callback)
    self.callback = callback
end

function MDMBrowseFillTypesDialog:onClose()
    self.isOpen = false
    self._isPending = false
    self.callback = nil
    MDMBrowseFillTypesDialog:superClass().onClose(self)
end

function MDMBrowseFillTypesDialog:onCloseClick()
    self:close()
end

-- Called by the XML TextInput's onTextChanged and onEnterPressed callbacks.
function MDMBrowseFillTypesDialog:onSearchChanged(element, text)
    self:_applyFilter(text or "")
end

-- Show/hide buttons based on filter text (real-time, no element recreation).
function MDMBrowseFillTypesDialog:_applyFilter(filterText)
    if not self.scrollingLayout then return end
    local pattern = filterText:lower()
    for _, entry in ipairs(self._allButtons) do
        local matches = pattern == ""
            or entry.title:lower():find(pattern, 1, true)
            or entry.name:lower():find(pattern, 1, true)
        entry.btn:setVisible(matches)
    end
    self.scrollingLayout:invalidateLayout()
end

function MDMBrowseFillTypesDialog:_populate()
    if not self.scrollingLayout then return end

    -- Only build the element list once per session (fill types are static)
    if #self._allButtons > 0 then return end

    if not g_fillTypeManager or not g_MarketDynamics then return end
    local engine = g_MarketDynamics.marketEngine

    local fillTypes = {}
    for _, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        if ft and ft.index and ft.index > 1 and ft.name and ft.name ~= ""
           and engine and engine.prices[ft.index] then
            table.insert(fillTypes, { name = ft.name, title = ft.title or ft.name })
        end
    end
    table.sort(fillTypes, function(a, b) return a.title < b.title end)

    for _, data in ipairs(fillTypes) do
        local el = ButtonElement.new(self)
        el:loadProfile(g_gui:getProfile("mdmFt_row"), true)
        el:setText(string.format("%s  [%s]", data.title, data.name))

        -- Suppress visual overlays (prevents white-box artefact in Giants Engine)
        el.overlay = { color = {0,0,0,0}, colorFocused = {0,0,0,0}, colorPressed = {0,0,0,0}, colorDisabled = {0,0,0,0}, colorHighlighted = {0,0,0,0} }
        el.icon    = { color = {0,0,0,0}, colorFocused = {0,0,0,0}, colorPressed = {0,0,0,0}, colorDisabled = {0,0,0,0}, colorHighlighted = {0,0,0,0} }
        el.textColor        = {1, 1, 1, 1}
        el.textFocusedColor = {1, 0.85, 0.1, 1}

        local capName  = data.name
        local callback = self.callback
        el.onClickCallback = function()
            if self.callback then
                self.callback(capName)
            end
            self:close()
        end

        self.scrollingLayout:addElement(el)
        el:onGuiSetupFinished()

        table.insert(self._allButtons, { btn = el, name = data.name, title = data.title })
    end

    self.scrollingLayout:invalidateLayout()
end
