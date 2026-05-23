MDMMarketScreen = {}

MDMMarketScreen.CLASS_NAME = "MDMMarketScreen"
MDMMarketScreen.MENU_PAGE_NAME = "menuMarketDynamics"
MDMMarketScreen.XML_FILENAME = "xml/gui/MarketScreen.xml"

MDMMarketScreen.MENU_ICON_PATH = "images/menuIcon.dds"

MDMMarketScreen._mt = Class(MDMMarketScreen, TabbedMenuFrameElement)

local TAB_PRICES    = 1
local TAB_EVENTS    = 2
local TAB_CONTRACTS = 3

local REFRESH_INTERVAL = 1000

-- Commodity list sort fields
local SORT_NAME   = "name"
local SORT_PRICE  = "price"
local SORT_CHANGE = "change"

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function MDMMarketScreen.new()
    local self = MDMMarketScreen:superClass().new(nil, MDMMarketScreen._mt)

    self.name       = "MDMMarketScreen"
    self.className  = "MDMMarketScreen"

    self.activeTab              = TAB_PRICES
    self.commodities            = {}
    self.selectedCropIndex      = 1
    self.eventData              = {}
    self.contractData           = {}
    self.selectedContractIndex  = 0
    self.refreshTimer           = 0
    self.returnScreenName  = ""
    self.menuButtonInfo    = {}
    self.sortField         = SORT_NAME
    self.sortAscending     = true
    -- (dialogOpen and inline dialog state removed — MDMContractDialog handles its own state)

    return self
end

function MDMMarketScreen:initialize()
    MDMLog.info("MarketScreen: initializing")

    MDMMarketScreen:superClass().initialize(self)

    self:setMenuButtonInfo({
        {inputAction = "MENU_EXTRA_1", text = g_i18n:getText("mdm_futures_create") or "New Contract",
         callback = function() self:onNewContractClick() end},
        {inputAction = "MENU_EXTRA_2", text = g_i18n:getText("mdm_evt_settings_title") or "Event Settings",
         callback = function() self:onEventSettingsClick() end},
        {inputAction = "MENU_BACK"},
    })
end

-- ---------------------------------------------------------------------------
-- Static methods
-- ---------------------------------------------------------------------------

function MDMMarketScreen.register(modDir)
    if MDMMarketScreen._performRegistration(modDir) then
        return
    end

    _pendingRegistration = true
    _pendingModDir = modDir
    MDMLog.info("MarketScreen: deferred registration until GUI/InGameMenu ready")
end

function MDMMarketScreen.show()
    if g_gui and g_gui.currentGuiName ~= nil and g_gui.currentGuiName ~= "" and g_gui.currentGuiName ~= "InGameMenu" then
        return
    end
    local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil then
        MDMLog.info("MarketScreen.show: inGameMenu is nil — cannot open")
        return
    end
    local page = inGameMenu[MDMMarketScreen.MENU_PAGE_NAME]
    if page == nil then
        MDMLog.info("MarketScreen.show: page '" .. MDMMarketScreen.MENU_PAGE_NAME .. "' not registered — cannot open")
        return
    end
    MDMLog.info("MarketScreen.show: opening screen")
    g_gui:showGui("InGameMenu")
    inGameMenu:goToPage(page)
end

function MDMMarketScreen.toggle()
    MDMLog.info("MarketScreen.toggle: called")
    if g_gui.currentGuiName == "InGameMenu" then
        local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
        if inGameMenu and inGameMenu.currentPage == inGameMenu[MDMMarketScreen.MENU_PAGE_NAME] then
            g_gui:changeScreen(nil)
            return
        end
    end
    MDMMarketScreen.show()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MDMMarketScreen:onGuiSetupFinished()
    MDMMarketScreen:superClass().onGuiSetupFinished(self)

    self.commodityList   = self:getDescendantById("commodityList")
    self.eventList       = self:getDescendantById("eventList")
    self.contractList    = self:getDescendantById("contractList")

    self.pricesContent   = self:getDescendantById("pricesContent")
    self.eventsContent   = self:getDescendantById("eventsContent")
    self.contractsContent = self:getDescendantById("contractsContent")

    self.categoryHeaderText = self:getDescendantById("categoryHeaderText")

    self.commoditiesHeader = self:getDescendantById("commoditiesHeader")
    self.colHeaderCrop = self:getDescendantById("colHeaderCrop")
    self.colHeaderPrice = self:getDescendantById("colHeaderPrice")
    self.colHeaderChange = self:getDescendantById("colHeaderChange")

    self.detailCropName    = self:getDescendantById("detailCropName")
    self.detailCurrentPrice = self:getDescendantById("detailCurrentPrice")
    self.detailBasePrice   = self:getDescendantById("detailBasePrice")
    self.detailChange      = self:getDescendantById("detailChange")
    self.detailVolatility  = self:getDescendantById("detailVolatility")
    self.detailModifiers   = self:getDescendantById("detailModifiers")

    self.currentBalanceText = self:getDescendantById("currentBalanceText")
    self.shopMoneyBox   = self:getDescendantById("shopMoneyBox")
    self.shopMoneyBoxBg = self:getDescendantById("shopMoneyBoxBg")

    self.graphArea = self:getDescendantById("graphArea")
    self.graphTitle = self:getDescendantById("graphTitle")
    self.graphHint = self:getDescendantById("graphHint")

    self.eventsHeader    = self:getDescendantById("eventsHeader")
    self.noEventsText    = self:getDescendantById("noEventsText")

    self.tabLabelPrices    = self:getDescendantById("tabLabelPrices")
    self.tabLabelEvents    = self:getDescendantById("tabLabelEvents")
    self.tabLabelContracts = self:getDescendantById("tabLabelContracts")

    self.tabUnderlinePrices    = self:getDescendantById("tabUnderlinePrices")
    self.tabUnderlineEvents    = self:getDescendantById("tabUnderlineEvents")
    self.tabUnderlineContracts = self:getDescendantById("tabUnderlineContracts")

    self.contractsHeader = self:getDescendantById("contractsHeader")
    self.contractsColCrop      = self:getDescendantById("contractsColCrop")
    self.contractsColQty       = self:getDescendantById("contractsColQty")
    self.contractsColLocked    = self:getDescendantById("contractsColLocked")
    self.contractsColDelivered = self:getDescendantById("contractsColDelivered")
    self.contractsColDeadline  = self:getDescendantById("contractsColDeadline")
    self.contractsColStatus    = self:getDescendantById("contractsColStatus")
    self.noContractsText = self:getDescendantById("noContractsText")
    self.newContractHint = self:getDescendantById("newContractHint")

    if self.commodityList then
        self.commodityList.dataSource = self
        self.commodityList.delegate   = self
    end
    if self.eventList then
        self.eventList.dataSource = self
        self.eventList.delegate   = self
    end
    if self.contractList then
        self.contractList.dataSource = self
        self.contractList.delegate   = self
    end

    local function _setTextSafe(el, key, fallback)
        if el == nil then return end
        local ok, txt = pcall(function() return g_i18n and g_i18n:getText(key) end)
        if ok and txt and txt ~= "" then
            el:setText(txt)
        else
            el:setText(fallback or tostring(key))
        end

        MDMLog.debug("MarketScreen: set text '" .. tostring(key) .. "'")
    end

    _setTextSafe(self.categoryHeaderText, "mdm_screen_title", "Market Dynamics")
    _setTextSafe(self.currentBalanceText, nil, "")
    _setTextSafe(self.commoditiesHeader, "mdm_screen_commodities", "COMMODITIES")
    _setTextSafe(self.colHeaderCrop, "mdm_label_crop", "Crop")
    _setTextSafe(self.colHeaderPrice, "mdm_label_price", "Price")
    _setTextSafe(self.colHeaderChange, "mdm_label_change", "Change")
    self:_updateSortHeaders()
    _setTextSafe(self.graphTitle, "mdm_screen_session_trend", "Session Price Trend")
    _setTextSafe(self.graphHint, "mdm_screen_collecting", "Collecting data...")
    _setTextSafe(self.eventsHeader, "mdm_screen_events_hdr", "ACTIVE EVENTS")
    _setTextSafe(self.noEventsText, "mdm_screen_no_events", "No events")
    _setTextSafe(self.contractsHeader, "mdm_screen_contracts_hdr", "FUTURES CONTRACTS")
    _setTextSafe(self.contractsColCrop,      "mdm_label_crop",      "Crop")
    _setTextSafe(self.contractsColQty,       "mdm_label_qty",       "Qty")
    _setTextSafe(self.contractsColLocked,    "mdm_screen_col_locked",    "Locked")
    _setTextSafe(self.contractsColDelivered, "mdm_screen_col_delivered", "Delivered")
    _setTextSafe(self.contractsColDeadline,  "mdm_screen_col_deadline",  "Deadline")
    _setTextSafe(self.contractsColStatus,    "mdm_label_status",    "Status")
    if BCIntegration.isEnabled() then
        _setTextSafe(self.noContractsText, "mdm_screen_no_contracts_bc",
            "Futures contracts are managed by FS25_FuturesMission (by Mmtrx).\n\n" ..
            "Please use the Contracts tab in the ESC menu.")
        if self.newContractHint then self.newContractHint:setVisible(false) end
    else
        _setTextSafe(self.noContractsText, "mdm_screen_no_contracts", "No contracts yet. Press X to create one.")
        _setTextSafe(self.newContractHint, "mdm_screen_new_contract_btn", "New Contract [X]")
        if self.newContractHint then self.newContractHint:setVisible(true) end
    end
end

function MDMMarketScreen:onOpen()
    MDMMarketScreen:superClass().onOpen(self)

    -- Hide the Event Settings button for regular clients on a dedicated server.
    -- In singleplayer and for admins/master users the button stays visible.
    -- g_currentMission:getIsServer() is true in SP and on the host process.
    -- g_currentMission.isAdmin is true for admin AND master users on a dedi server.
    -- g_currentMission.isMasterUser covers the ESC "Master Admin" role on dedi
    -- servers where isAdmin may not be set until after the first frame open.
    local isAdmin = g_currentMission:getIsServer()
        or g_currentMission.isAdmin
        or g_currentMission.isMasterUser
    if not isAdmin then
        self:setMenuButtonInfo({
            {inputAction = "MENU_EXTRA_1", text = g_i18n:getText("mdm_futures_create") or "New Contract",
             callback = function() self:onNewContractClick() end},
            {inputAction = "MENU_BACK"},
        })
    end

    self:onMoneyChange()
    self:rebuildAllData()
    self:reloadAllLists()

    self:setActiveTab(TAB_PRICES)
    if self.selectedCropIndex > 0 and #self.commodities > 0 then
        self:refreshPricesDetail()
    end

end

function MDMMarketScreen:onClose()
    MDMMarketScreen:superClass().onClose(self)
end

-- Called by the "Event Settings" button in the Events tab.
-- Only the server host, admins, and master users may open this dialog.
-- Regular clients on a dedicated server are blocked here (not just inside the dialog).
function MDMMarketScreen:onEventSettingsClick()
    local isAdmin = g_currentMission:getIsServer()
        or g_currentMission.isAdmin
        or g_currentMission.isMasterUser
    if not isAdmin then
        MDMLog.debug("MarketScreen: onEventSettingsClick ignored — player is not an admin/master")
        return
    end

    MDMDialogLoader.show("MDMEventSettingsDialog", "setData", {
        onClose = function() end,
    })
end

-- Called by the "New Contract" footer button (always visible, any tab)
function MDMMarketScreen:onNewContractClick()
    MDMLog.info("MarketScreen: New Contract button clicked — openContractDialog")
    if self.activeTab ~= TAB_CONTRACTS then
        self:setActiveTab(TAB_CONTRACTS)
    end
    self:openContractDialog()
end

function MDMMarketScreen:onMoneyChange()
    if g_localPlayer == nil or g_farmManager == nil then return end
    local farm = g_farmManager:getFarmById(g_localPlayer.farmId)
    if farm == nil then return end

    local isNegative = farm.money <= -1
    local profileName = "fs25_shopMoney"

    if ShopMenu and ShopMenu.GUI_PROFILE then
        profileName = isNegative
            and ShopMenu.GUI_PROFILE.SHOP_MONEY_NEGATIVE
            or  ShopMenu.GUI_PROFILE.SHOP_MONEY
    elseif isNegative then
        profileName = "fs25_shopMoneyNegative"
    end

    if self.currentBalanceText then
        self.currentBalanceText:applyProfile(profileName, nil, true)
        self.currentBalanceText:setText(g_i18n:formatMoney(farm.money, 0, true, false))
    end

    if self.shopMoneyBox ~= nil and self.shopMoneyBoxBg ~= nil then
        self.shopMoneyBox:invalidateLayout()
        self.shopMoneyBoxBg:setSize(self.shopMoneyBox.flowSizes[1] + 60 * g_pixelSizeScaledX)
    end
end

function MDMMarketScreen:update(dt)
    MDMMarketScreen:superClass().update(self, dt)

    self.refreshTimer = self.refreshTimer + dt
    if self.refreshTimer >= REFRESH_INTERVAL then
        self.refreshTimer = 0
        self:rebuildAllData()
        self:reloadAllLists()
        self:onMoneyChange()

        if self.activeTab == TAB_PRICES then
            self:refreshPricesDetail()
        end
    end
end

MDMMarketScreen._graphAreaLogDone = false

function MDMMarketScreen:draw()
    MDMMarketScreen:superClass().draw(self)

    if self.activeTab == TAB_PRICES and self.graphArea then
        local pos = self.graphArea.absPosition
        local sz  = self.graphArea.absSize

        if not pos or not sz or not pos[1] or not pos[2] or not sz[1] or not sz[2] then
            return
        end

        if not MDMMarketScreen._graphAreaLogDone then
            MDMLog.info("MarketScreen: graphArea pos=(" .. tostring(pos[1]) .. ", " .. tostring(pos[2]) .. ") size=(" .. tostring(sz[1]) .. ", " .. tostring(sz[2]) .. ")")
            MDMMarketScreen._graphAreaLogDone = true
        end

        local crop = self.commodities[self.selectedCropIndex]
        local fillIdx = crop and crop.idx or nil

        local sampleCount = 0
        if fillIdx then
            sampleCount = MDMMarketScreenGraph.getSampleCount(fillIdx)
        end
        if sampleCount < 2 then
            sampleCount = MDMMarketScreenGraph.getGlobalSampleCount()
        end

        if sampleCount >= 2 then
            if self.graphHint then
                self.graphHint:setVisible(false)
            end

            if fillIdx and MDMMarketScreenGraph.getSampleCount(fillIdx) >= 2 then
                MDMMarketScreenGraph.draw(fillIdx, pos[1], pos[2], sz[1], sz[2])
            else
                MDMMarketScreenGraph.drawAggregatedMedian(pos[1], pos[2], sz[1], sz[2])
            end
        elseif fillIdx and g_MarketDynamics and g_MarketDynamics.marketEngine then
            local history = g_MarketDynamics.marketEngine:getPriceHistory(fillIdx)
            if history and #history >= 2 then
                if self.graphHint then
                    self.graphHint:setVisible(false)
                end
                local series = {}
                for _, h in ipairs(history) do
                    series[#series + 1] = h.price
                end
                MDMMarketScreenGraph._drawLineChart(series, pos[1], pos[2], sz[1], sz[2])
            else
                if self.graphHint then
                    self.graphHint:setVisible(true)
                end
            end
        else
            if self.graphHint then
                self.graphHint:setVisible(true)
            end
        end
    end
end

function MDMMarketScreen:delete()
    MDMMarketScreen:superClass().delete(self)
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function MDMMarketScreen:onClickBack()
    self:changeScreen(nil)
end

function MDMMarketScreen:inputEvent(action, value, eventUsed)
    -- Handle tab-cycling BEFORE super
    if not eventUsed and value > 0 then
        if action == InputAction.MENU_PAGE_PREV then
            local newTab = self.activeTab - 1
            if newTab < TAB_PRICES then newTab = TAB_CONTRACTS end
            self:setActiveTab(newTab)
            return true
        end
        if action == InputAction.MENU_PAGE_NEXT then
            local newTab = self.activeTab + 1
            if newTab > TAB_CONTRACTS then newTab = TAB_PRICES end
            self:setActiveTab(newTab)
            return true
        end
    end

    return MDMMarketScreen:superClass().inputEvent(self, action, value, eventUsed)
end

-- ---------------------------------------------------------------------------
-- SmoothList Data Source
-- ---------------------------------------------------------------------------

function MDMMarketScreen:getNumberOfItemsInSection(list, section)
    if list == self.commodityList then
        return #self.commodities
    elseif list == self.eventList then
        return #self.eventData
    elseif list == self.contractList then
        return #self.contractData
    end
    return 0
end

function MDMMarketScreen:populateCellForItemInSection(list, section, index, cell)
    if list == self.commodityList then
        self:_populateCommodityCell(index, cell)
    elseif list == self.eventList then
        self:_populateEventCell(index, cell)
    elseif list == self.contractList then
        self:_populateContractCell(index, cell)
    end
end

-- ---------------------------------------------------------------------------
-- SmoothList Delegate — selection & click
-- ---------------------------------------------------------------------------

function MDMMarketScreen:onListSelectionChanged(list, section, index)
    if list == self.commodityList and index > 0 then
        self.selectedCropIndex = index
        self:refreshPricesDetail()
    elseif list == self.contractList and index > 0 then
        -- Only track the selection index here. The dialog is opened exclusively
        -- by onContractRowClick (real user click), never by programmatic reloads.
        self.selectedContractIndex = index
    end
end

function MDMMarketScreen:onClickCommodity(element)
    -- onListSelectionChanged handles selection; nothing extra needed
end

-- Opens the contract admin dialog. Called only on real user click via XML onClick,
-- never by programmatic list reloads — this is the sole gatekeeper for the dialog.
function MDMMarketScreen:onContractRowClick(element)
    if BCIntegration.isEnabled() then return end

    local index = self.selectedContractIndex
    if index <= 0 then return end

    local contract = self.contractData[index]
    if not contract then return end

    -- Security: Allow if Admin OR if the player owns the farm associated with the contract
    local isAdmin = g_currentMission:getIsServer() or g_currentMission.isAdmin or g_currentMission.isMasterUser
    local isOwner = g_localPlayer and g_localPlayer.farmId == contract.farmId

    if not isAdmin and not isOwner then
        MDMLog.debug("MarketScreen: onContractRowClick ignored — player is not an admin or owner")
        return
    end

    MDMDialogLoader.show("MDMContractAdminDialog", "setData", {
        contract   = contract,
        onComplete = function(contractId)
            self:_onContractAdminAction("complete", contractId)
        end,
        onCancel   = function(contractId)
            self:_onContractAdminAction("cancel", contractId)
        end,
    })
end

-- Refresh the contracts list after an admin action.
function MDMMarketScreen:_onContractAdminAction(action, contractId)
    MDMLog.info(string.format("MarketScreen: admin %s contract #%s", action, tostring(contractId)))
    self._lastAdminDialogTime = 0  -- reset debounce so the next click is never blocked
    self.selectedContractIndex = 0  -- reset selection so next click re-resolves via onListSelectionChanged
    self:_buildContractData()
    self:reloadAllLists()
end

-- ---------------------------------------------------------------------------
-- Tab Switching
-- ---------------------------------------------------------------------------

function MDMMarketScreen:onClickTabPrices()
    MDMLog.info("MarketScreen: tab click -> PRICES")
    self:setActiveTab(TAB_PRICES)
end

function MDMMarketScreen:onClickTabEvents()
    MDMLog.info("MarketScreen: tab click -> EVENTS")
    self:setActiveTab(TAB_EVENTS)
end

function MDMMarketScreen:onClickTabContracts()
    MDMLog.info("MarketScreen: tab click -> CONTRACTS")
    self:setActiveTab(TAB_CONTRACTS)
end

-- Manual mouse-click detection for tab labels.
-- FS25 doesn't always route Button onClick through TabbedMenuFrameElement custom pages,
-- so we hit-test the confirmed-visible label elements directly.
function MDMMarketScreen:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    -- Block tab hit-testing while the contract dialog is open to prevent click-through
    local dlg = MDMDialogLoader and MDMDialogLoader.getDialog and MDMDialogLoader.getDialog("MDMContractDialog")
    if dlg and dlg.isOpen then
        return MDMMarketScreen:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
    end

    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        local tabs = {
            { el = self.tabLabelPrices,    cb = MDMMarketScreen.onClickTabPrices    },
            { el = self.tabLabelEvents,    cb = MDMMarketScreen.onClickTabEvents    },
            { el = self.tabLabelContracts, cb = MDMMarketScreen.onClickTabContracts },
        }
        for _, t in ipairs(tabs) do
            if t.el then
                local ap = t.el.absPosition
                local as = t.el.absSize
                if ap and as and
                   posX >= ap[1] and posX <= ap[1] + as[1] and
                   posY >= ap[2] and posY <= ap[2] + as[2] then
                    t.cb(self)
                    return true
                end
            end
        end

        -- Column header sort clicks (Prices tab only)
        if self.activeTab == TAB_PRICES then
            local cols = {
                { el = self.colHeaderCrop,   field = SORT_NAME,   defaultAsc = true  },
                { el = self.colHeaderPrice,  field = SORT_PRICE,  defaultAsc = false },
                { el = self.colHeaderChange, field = SORT_CHANGE, defaultAsc = false },
            }
            for _, col in ipairs(cols) do
                if col.el then
                    local ap = col.el.absPosition
                    local as = col.el.absSize
                    if ap and as and
                       posX >= ap[1] and posX <= ap[1] + as[1] and
                       posY >= ap[2] and posY <= ap[2] + as[2] then
                        if self.sortField == col.field then
                            self.sortAscending = not self.sortAscending
                        else
                            self.sortField    = col.field
                            self.sortAscending = col.defaultAsc
                        end
                        self:_buildCommodityData()
                        self:_updateSortHeaders()
                        if self.commodityList then self.commodityList:reloadData() end
                        if self.selectedCropIndex > 0 then self:refreshPricesDetail() end
                        return true
                    end
                end
            end
        end
    end
    return MDMMarketScreen:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, eventUsed)
end

function MDMMarketScreen:setActiveTab(tab)
    self.activeTab = tab

    if self.pricesContent then
        self.pricesContent:setVisible(tab == TAB_PRICES)
    end
    if self.eventsContent then
        self.eventsContent:setVisible(tab == TAB_EVENTS)
        if tab == TAB_EVENTS then
            if type(self.eventsContent.updateAbsolutePosition) == "function" then
                self.eventsContent:updateAbsolutePosition()
            end
            if self.eventList then self.eventList:reloadData() end
        end
    end
    if self.contractsContent then
        self.contractsContent:setVisible(tab == TAB_CONTRACTS)
        if tab == TAB_CONTRACTS then
            if type(self.contractsContent.updateAbsolutePosition) == "function" then
                self.contractsContent:updateAbsolutePosition()
            end
            if self.contractList then self.contractList:reloadData() end
        end
    end

    -- Color tab indicator labels: active = MDM green, inactive = dim white
    local function _tabColor(el, isActive)
        if not el then return end
        if isActive then
            el:setTextColor(0.0, 0.82, 0.48, 1.0)
        else
            el:setTextColor(1.0, 1.0, 1.0, 0.40)
        end
    end
    _tabColor(self.tabLabelPrices,    tab == TAB_PRICES)
    _tabColor(self.tabLabelEvents,    tab == TAB_EVENTS)
    _tabColor(self.tabLabelContracts, tab == TAB_CONTRACTS)

    -- Show underline only under the active tab
    if self.tabUnderlinePrices    then self.tabUnderlinePrices:setVisible(tab == TAB_PRICES) end
    if self.tabUnderlineEvents    then self.tabUnderlineEvents:setVisible(tab == TAB_EVENTS) end
    if self.tabUnderlineContracts then self.tabUnderlineContracts:setVisible(tab == TAB_CONTRACTS) end

end

-- ---------------------------------------------------------------------------
-- Data Gathering
-- ---------------------------------------------------------------------------

function MDMMarketScreen:rebuildAllData()
    self:_buildCommodityData()
    self:_updateSortHeaders()
    self:_buildEventData()
    self:_buildContractData()
end

function MDMMarketScreen:_buildCommodityData()
    self.commodities = {}

    if not g_MarketDynamics or not g_MarketDynamics.marketEngine then return end
    local engine = g_MarketDynamics.marketEngine

    for fillTypeIndex, entry in pairs(engine.prices) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType then
            -- Show everything tracked by the engine (anything with a sell price).
            -- This includes modded fill types (Compost, Wood products) that
            -- are excluded by the strict FruitType check.
            local changePct = engine:getPriceChangePercent(fillTypeIndex)
            table.insert(self.commodities, {
                idx        = fillTypeIndex,
                name       = fillType.name,
                title      = fillType.title or fillType.name,
                current    = entry.current,
                base       = entry.base,
                changePct  = changePct,
                volatility = entry.volatilityFactor,
                modifiers  = entry.modifiers,
                hudOverlay = fillType.hudOverlayFilename,
            })
        end
    end

    local sortField = self.sortField
    local sortAsc   = self.sortAscending
    table.sort(self.commodities, function(a, b)
        if sortField == SORT_PRICE then
            if sortAsc then return a.current < b.current else return a.current > b.current end
        elseif sortField == SORT_CHANGE then
            if sortAsc then return a.changePct < b.changePct else return a.changePct > b.changePct end
        else
            if sortAsc then return a.title < b.title else return a.title > b.title end
        end
    end)

    if self.selectedCropIndex > #self.commodities then
        self.selectedCropIndex = math.max(1, #self.commodities)
    end
end

function MDMMarketScreen:_updateSortHeaders()
    local asc = self.sortAscending and " \226\150\178" or " \226\150\188"  -- ▲ / ▼ (UTF-8)
    local function hdr(key, fallback, isActive)
        local txt = (g_i18n and g_i18n:getText(key)) or fallback
        return isActive and (txt .. asc) or txt
    end
    if self.colHeaderCrop then
        self.colHeaderCrop:setText(hdr("mdm_screen_col_crop", "Crop", self.sortField == SORT_NAME))
    end
    if self.colHeaderPrice then
        self.colHeaderPrice:setText(hdr("mdm_screen_col_price", "Price", self.sortField == SORT_PRICE))
    end
    if self.colHeaderChange then
        self.colHeaderChange:setText(hdr("mdm_screen_col_change", "Change", self.sortField == SORT_CHANGE))
    end
end

function MDMMarketScreen:_buildEventData()
    self.eventData = {}

    if not g_MarketDynamics or not g_MarketDynamics.worldEvents then return end

    local events = g_MarketDynamics.worldEvents:getActiveEvents()
    for _, ev in ipairs(events) do
        table.insert(self.eventData, ev)
    end

    if self.noEventsText then
        self.noEventsText:setVisible(#self.eventData == 0)
    end
end

function MDMMarketScreen:_buildContractData()
    self.contractData = {}

    if not g_MarketDynamics or not g_MarketDynamics.futuresMarket then return end
    if not g_localPlayer then return end

    local farmId = g_localPlayer.farmId
    if not farmId then return end

    local contracts = g_MarketDynamics.futuresMarket:getContractsForFarm(farmId)
    for _, c in ipairs(contracts) do
        table.insert(self.contractData, c)
    end

    if self.noContractsText then
        self.noContractsText:setVisible(#self.contractData == 0)
    end
end

-- ---------------------------------------------------------------------------
-- List Reload
-- ---------------------------------------------------------------------------

function MDMMarketScreen:reloadAllLists()
    if self.commodityList then
        self.commodityList:reloadData()
    end
    if self.eventList then
        self.eventList:reloadData()
    end
    if self.contractList then
        self._reloadingContracts = true
        self.contractList:reloadData()
        self._reloadingContracts = false
    end
end

-- ---------------------------------------------------------------------------
-- Contract Dialog — Open / Close / Update
-- ---------------------------------------------------------------------------

function MDMMarketScreen:openContractDialog()
    -- When BetterContracts is active it owns the futures contract flow entirely.
    -- Show the player a brief info dialog so they know why nothing happened,
    -- then return. InfoDialog's OK button (and ESC) closes it cleanly.
    if BCIntegration.isEnabled() then
        MDMLog.info("MarketScreen.openContractDialog: BC active — showing info dialog")
        InfoDialog.show(g_i18n:getText("mdm_bc_dialog_suppressed") or "FS25_FuturesMission is active — contracts are created via the Contracts page (ESC menu).")
        return
    end

    MDMLog.info("MarketScreen.openContractDialog: commodities=" .. #self.commodities .. " selectedIdx=" .. self.selectedCropIndex)
    MDMDialogLoader.show("MDMContractDialog", "setData", {
        commodities = self.commodities,
        selectedIdx = self.selectedCropIndex,
        onConfirmed = function(crop, qty, delivDays, isRealDays, createdTimeScale)
            self:_onContractConfirmed(crop, qty, delivDays, isRealDays, createdTimeScale)
        end,
    })
end

function MDMMarketScreen:_onContractConfirmed(crop, qty, delivDays, isRealDays, createdTimeScale)
    if not g_MarketDynamics or not g_MarketDynamics.futuresMarket then return end
    if not g_localPlayer or not g_localPlayer.farmId then return end

    local now            = MDMUtil.getGameTime()
    local deliveryTimeMs = now + (delivDays * 24 * 60 * 60000)

    MDMContractRequestEvent.sendToServer(MDMContractRequestEvent.ACTION_CREATE, {
        farmId           = g_localPlayer.farmId,
        fillTypeIndex    = crop.idx,
        fillTypeName     = crop.title,
        quantity         = qty,
        lockedPrice      = crop.current,
        deliveryTimeMs   = deliveryTimeMs,
        isRealDays       = isRealDays or false,
        createdTimeScale = createdTimeScale or 1,
    })

    MDMLog.info(string.format("MarketScreen: sent contract request — %s %dL @ $%.2f deliver in %dd",
        crop.title, qty, crop.current, delivDays))

    self:setActiveTab(TAB_CONTRACTS)
    -- UI will update when server broadcasts the new contract
end


function MDMMarketScreen:_populateCommodityCell(index, cell)
    local data = self.commodities[index]
    if not data then return end

    local iconEl   = cell:getDescendantByName("cropIcon")
    local nameEl   = cell:getDescendantByName("cropName")
    local priceEl  = cell:getDescendantByName("cropPrice")
    local changeEl = cell:getDescendantByName("cropChange")

    if iconEl then
        if data.hudOverlay and data.hudOverlay ~= "" then
            iconEl:setImageFilename(data.hudOverlay)
            iconEl:setVisible(true)
        else
            iconEl:setVisible(false)
        end
    end

    if nameEl then
        nameEl:setText(data.title)
    end
    if priceEl then
        priceEl:setText(string.format("$%.0f / 1,000L", data.current * 1000))
    end
    if changeEl then
        local sign = data.changePct >= 0 and "+" or ""
        changeEl:setText(string.format("%s%.1f%%", sign, data.changePct))

        if data.changePct > 0.5 then
            changeEl:setTextColor(0.20, 0.72, 0.35, 1.0)
        elseif data.changePct < -0.5 then
            changeEl:setTextColor(0.85, 0.22, 0.22, 1.0)
        else
            changeEl:setTextColor(0.80, 0.80, 0.80, 1.0)
        end
    end
end

function MDMMarketScreen:_populateEventCell(index, cell)
    local data = self.eventData[index]
    if not data then return end

    local nameEl      = cell:getDescendantByName("eventName")
    local intensityEl = cell:getDescendantByName("eventIntensity")
    local timeEl      = cell:getDescendantByName("eventTimeLeft")

    if nameEl then
        nameEl:setText(data.name)
    end

    if intensityEl then
        local label
        if data.intensity >= 0.7 then
            label = g_i18n:getText("mdm_hud_event_severe")
        elseif data.intensity >= 0.4 then
            label = g_i18n:getText("mdm_hud_event_moderate")
        else
            label = g_i18n:getText("mdm_hud_event_mild")
        end
        intensityEl:setText(label)

        if data.intensity >= 0.7 then
            intensityEl:setTextColor(0.85, 0.22, 0.22, 1.0)
        elseif data.intensity >= 0.4 then
            intensityEl:setTextColor(0.95, 0.75, 0.10, 1.0)
        else
            intensityEl:setTextColor(0.60, 0.80, 0.60, 1.0)
        end
    end

    if timeEl then
        local now = MDMUtil.getGameTime()
        local remaining = math.max(0, data.endsAt - now)
        local mins = math.floor(remaining / 60000)
        if mins > 60 then
            local hrs = math.floor(mins / 60)
            local fmt = g_i18n:getText("mdm_time_fmt_hm") or "%dh %dm"
            timeEl:setText(string.format(fmt, hrs, mins % 60))
        else
            local fmt = g_i18n:getText("mdm_time_fmt_m") or "%d min"
            timeEl:setText(string.format(fmt, mins))
        end
    end
end

function MDMMarketScreen:_populateContractCell(index, cell)
    local data = self.contractData[index]
    if not data then
        MDMLog.warn("MarketScreen: _populateContractCell index=" .. tostring(index) .. " data=nil")
        return
    end

    local cropEl     = cell:getDescendantByName("contractCrop")
    local qtyEl      = cell:getDescendantByName("contractQty")
    local priceEl    = cell:getDescendantByName("contractPrice")
    local progressEl = cell:getDescendantByName("contractProgress")
    local deadlineEl = cell:getDescendantByName("contractDeadline")
    local statusEl   = cell:getDescendantByName("contractStatus")

    if cropEl then
        cropEl:setText(data.fillTypeName or "?")
    end
    if qtyEl then
        local fmt = g_i18n:getText("mdm_qty_fmt") or "%.0fL"
        qtyEl:setText(string.format(fmt, data.quantity))
    end
    if priceEl then
        priceEl:setText(string.format("$%.0f / 1,000L", data.lockedPrice * 1000))
    end
    if progressEl then
        local pct = 0
        if data.quantity > 0 then
            pct = (data.delivered / data.quantity) * 100
        end
        progressEl:setText(string.format("%.0f%%", pct))
    end
    if deadlineEl then
        local now = MDMUtil.getGameTime()
        local remaining = math.max(0, data.deliveryTime - now)
        local days = math.floor(remaining / (24 * 60 * 60000))
        if days > 0 then
            local fmt = g_i18n:getText("mdm_deadline_fmt_d") or "%d days"
            deadlineEl:setText(string.format(fmt, days))
        else
            local hrs = math.floor(remaining / (60 * 60000))
            local fmt = g_i18n:getText("mdm_deadline_fmt_h") or "%d hrs"
            deadlineEl:setText(string.format(fmt, hrs))
        end
    end
    if statusEl then
        local status = data.status or "active"
        if status == "active" then
            local now = MDMUtil.getGameTime()
            local remaining = math.max(0, data.deliveryTime - now)
            local pctDelivered = data.quantity > 0 and (data.delivered / data.quantity) or 0

            if remaining < 86400000 and pctDelivered < 0.5 then
                statusEl:setText(g_i18n:getText("mdm_screen_at_risk"))
                statusEl:setTextColor(0.85, 0.22, 0.22, 1.0)
            else
                statusEl:setText(g_i18n:getText("mdm_futures_active"))
                statusEl:setTextColor(0.20, 0.72, 0.35, 1.0)
            end
        elseif status == "fulfilled" then
            statusEl:setText(g_i18n:getText("mdm_futures_fulfill"))
            statusEl:setTextColor(0.20, 0.72, 0.35, 1.0)
        elseif status == "defaulted" then
            statusEl:setText(g_i18n:getText("mdm_futures_defaulted"))
            statusEl:setTextColor(0.85, 0.22, 0.22, 1.0)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Price Detail (right panel, Prices tab)
-- ---------------------------------------------------------------------------

function MDMMarketScreen:refreshPricesDetail()
    local crop = self.commodities[self.selectedCropIndex]
    if not crop then
        if self.detailCropName then
            self.detailCropName:setText(g_i18n:getText("mdm_screen_select_crop"))
        end
        return
    end

    if self.detailCropName then
        self.detailCropName:setText(crop.title)
    end
    if self.detailCurrentPrice then
        self.detailCurrentPrice:setText(
            g_i18n:getText("mdm_screen_current_price") .. ": " ..
            string.format("$%.0f / 1,000L", crop.current * 1000)
        )
    end
    if self.detailBasePrice then
        self.detailBasePrice:setText(
            g_i18n:getText("mdm_screen_base_price") .. ": " ..
            string.format("$%.0f / 1,000L", crop.base * 1000)
        )
    end
    if self.detailChange then
        local sign = crop.changePct >= 0 and "+" or ""
        self.detailChange:setText(
            g_i18n:getText("mdm_screen_change") .. ": " ..
            string.format("%s%.1f%%", sign, crop.changePct)
        )
        if crop.changePct > 0.5 then
            self.detailChange:setTextColor(0.20, 0.72, 0.35, 1.0)
        elseif crop.changePct < -0.5 then
            self.detailChange:setTextColor(0.85, 0.22, 0.22, 1.0)
        else
            self.detailChange:setTextColor(0.80, 0.80, 0.80, 1.0)
        end
    end
    if self.detailVolatility then
        self.detailVolatility:setText(
            g_i18n:getText("mdm_screen_volatility") .. ": " ..
            string.format("%.3f", crop.volatility)
        )
    end
    if self.detailModifiers then
        local modCount = crop.modifiers and #crop.modifiers or 0
        self.detailModifiers:setText(
            g_i18n:getText("mdm_screen_modifiers") .. ": " .. modCount
        )
    end

    if self.graphTitle then
        self.graphTitle:setText(crop.title .. " — " .. g_i18n:getText("mdm_screen_session_trend"))
    end
end

-- ---------------------------------------------------------------------------
-- Module-level lifecycle hooks
-- Wired at source() time. MarketScreen manages its own registration.
-- ---------------------------------------------------------------------------

local _modDir = g_currentModDirectory
local _pendingRegistration = false
local _pendingModDir = nil

local function _onMissionLoaded(mission)
    MDMMarketScreen.register(_modDir)
end

function MDMMarketScreen._performRegistration(modDir)
    if g_gui == nil or g_inGameMenu == nil then
        return false
    end

    if g_inGameMenu[MDMMarketScreen.MENU_PAGE_NAME] ~= nil then
        MDMLog.info("MarketScreen: page already registered, skipping")
        return true
    end

    local screen = MDMMarketScreen.new()

    MDMLog.info("MarketScreen: loading GUI '" .. tostring(modDir .. MDMMarketScreen.XML_FILENAME) .. "'")
    g_gui:loadGui(modDir .. MDMMarketScreen.XML_FILENAME, MDMMarketScreen.CLASS_NAME, screen, true)

    local function _applyGuiLocalization(scr)
        if scr == nil then return end
        local function _setById(id, key, fallback)
            local ok, el = pcall(function() return scr:getDescendantById(id) end)
            if not ok or el == nil then
                MDMLog.info("MarketScreen: applyGuiLocalization - control '" .. tostring(id) .. "' not found")
                return
            end
            local okTxt, txt = false, nil
            if key ~= nil then
                okTxt, txt = pcall(function() return g_i18n and g_i18n:getText(key) end)
            end
            if okTxt and txt and txt ~= "" then
                pcall(function() el:setText(txt) end)
            else
                pcall(function() el:setText(fallback or (key and tostring(key) or "")) end)
            end
        end

        _setById("categoryHeaderText", "mdm_screen_title", "Market Dynamics")
        _setById("commoditiesHeader", "mdm_screen_commodities", "COMMODITIES")
        _setById("colHeaderCrop", "mdm_label_crop", "Crop")
        _setById("colHeaderPrice", "mdm_label_price", "Price")
        _setById("colHeaderChange", "mdm_label_change", "Change")

        _setById("graphHint", "mdm_screen_collecting", "Collecting data...")
        _setById("noEventsText", "mdm_screen_no_events", "No events")
        if BCIntegration.isEnabled() then
            _setById("noContractsText", "mdm_screen_no_contracts_bc",
                "Futures contracts are managed by FS25_FuturesMission (by Mmtrx).\n\n" ..
                "Please use the Contracts tab in the ESC menu.")
            local hint = screen:getDescendantById("newContractHint")
            if hint then hint:setVisible(false) end
        else
            _setById("noContractsText", "mdm_screen_no_contracts", "No contracts yet. Press X to create one.")
            local hint = screen:getDescendantById("newContractHint")
            if hint then hint:setVisible(true) end
        end
        _setById("graphTitle", "mdm_screen_session_trend", "Session Timeline")

        _setById("eventsHeader", "mdm_screen_events_hdr", "ACTIVE EVENTS")
        _setById("contractsHeader", "mdm_screen_contracts_hdr", "FUTURES CONTRACTS")

        _setById("contractsColCrop",      "mdm_label_crop",      "Crop")
        _setById("contractsColQty",       "mdm_label_qty",       "Qty")
        _setById("contractsColLocked",    "mdm_screen_col_locked",    "Locked")
        _setById("contractsColDelivered", "mdm_screen_col_delivered", "Delivered")
        _setById("contractsColDeadline",  "mdm_screen_col_deadline",  "Deadline")
        _setById("contractsColStatus",    "mdm_label_status",    "Status")
        if not BCIntegration.isEnabled() then
            _setById("newContractHint", "mdm_screen_new_contract_btn", "New Contract  [X]")
        end

        _setById("detailCropName", "mdm_screen_select_crop", "Select a commodity")
        _setById("detailCurrentPrice", nil, "")
        _setById("detailBasePrice", nil, "")
        _setById("detailChange", nil, "")
        _setById("detailVolatility", nil, "")
        _setById("detailModifiers", nil, "")

        -- Apply initial sort header indicators
        pcall(function() scr:_updateSortHeaders() end)
        return
    end

    local okLoc, errLoc = pcall(_applyGuiLocalization, screen)
    if not okLoc then
        MDMLog.error("MarketScreen: applyGuiLocalization failed: " .. tostring(errLoc))
    end

    local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu ~= nil and inGameMenu.pagingElement ~= nil and inGameMenu.pagingElement.elements ~= nil then
        -- Ensure controlIDs cleared for this page name (prevents conflicts)
        if g_inGameMenu ~= nil and g_inGameMenu.controlIDs ~= nil then
            for _, v in pairs({ MDMMarketScreen.MENU_PAGE_NAME }) do
                g_inGameMenu.controlIDs[v] = nil
            end
        end

        inGameMenu[MDMMarketScreen.MENU_PAGE_NAME] = screen

        local alreadyAdded = false
        for _, el in ipairs(inGameMenu.pagingElement.elements) do
            if el == inGameMenu[MDMMarketScreen.MENU_PAGE_NAME] then
                alreadyAdded = true
                break
            end
        end
        if not alreadyAdded then
            inGameMenu.pagingElement:addElement(inGameMenu[MDMMarketScreen.MENU_PAGE_NAME])
        else
            MDMLog.info("MarketScreen: pagingElement already contains the page, not adding")
        end

        if type(inGameMenu.exposeControlsAsFields) == "function" then
            local ok, err = pcall(inGameMenu.exposeControlsAsFields, inGameMenu, MDMMarketScreen.MENU_PAGE_NAME)
            if not ok then
                MDMLog.error("MarketScreen: exposeControlsAsFields failed: " .. tostring(err))
            else
                MDMLog.info("MarketScreen: exposeControlsAsFields OK")
            end
        else
            MDMLog.info("MarketScreen: exposeControlsAsFields not present")
        end

        if type(inGameMenu.pagingElement.updateAbsolutePosition) == "function" then
            pcall(inGameMenu.pagingElement.updateAbsolutePosition, inGameMenu.pagingElement)
        end
        if type(inGameMenu.pagingElement.updatePageMapping) == "function" then
            pcall(inGameMenu.pagingElement.updatePageMapping, inGameMenu.pagingElement)
        end

        if type(inGameMenu.registerPage) == "function" then
            local ok, err = pcall(inGameMenu.registerPage, inGameMenu, inGameMenu[MDMMarketScreen.MENU_PAGE_NAME], nil, function() return true end)
            if not ok then
                MDMLog.error("MarketScreen: registerPage failed: " .. tostring(err))
            else
                MDMLog.info("MarketScreen: registerPage OK")
            end
        else
            MDMLog.info("MarketScreen: registerPage not present")
        end

        local iconFile = Utils.getFilename(MDMMarketScreen.MENU_ICON_PATH, modDir)
        local uvs = {0, 0, 1024, 1024}
        if iconFile ~= nil and type(inGameMenu.addPageTab) == "function" and GuiUtils ~= nil then
            local ok, err = pcall(inGameMenu.addPageTab, inGameMenu, inGameMenu[MDMMarketScreen.MENU_PAGE_NAME], iconFile, GuiUtils.getUVs(uvs))
            if not ok then
                MDMLog.error("MarketScreen: addPageTab failed: " .. tostring(err))
            else
                MDMLog.info("MarketScreen: addPageTab OK (iconFile=" .. tostring(iconFile) .. ")")
            end
        else
            MDMLog.info("MarketScreen: addPageTab skipped (iconFile=" .. tostring(iconFile) .. ")")
        end

        if type(inGameMenu.rebuildTabList) == "function" then
            pcall(inGameMenu.rebuildTabList, inGameMenu)
        end

        if type(screen.initialize) == "function" then
            local ok, err = pcall(screen.initialize, screen)
            if not ok then
                MDMLog.error("MarketScreen: screen.initialize failed: " .. tostring(err))
            else
                MDMLog.info("MarketScreen: screen.initialize OK")
            end
        end
    end

    MDMLog.info("MarketScreen: GUI loaded and registered")
    return true
end

function MDMMarketScreen._attemptDeferredRegister(dt)
    if not _pendingRegistration then return end
    if MDMMarketScreen._performRegistration(_pendingModDir or _modDir) then
        _pendingRegistration = false
        _pendingModDir = nil
    end
end

function MDMMarketScreen.onGlobalCreateContract()
    if g_gui.currentGuiName == "InGameMenu" then
        local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
        if inGameMenu and inGameMenu.currentPage == inGameMenu[MDMMarketScreen.MENU_PAGE_NAME] then
            inGameMenu.currentPage:openContractDialog()
        end
    end
end

local function _onUpdate(mission, dt)
    MDMMarketScreenGraph.update(dt)
    MDMMarketScreen._attemptDeferredRegister(dt)
end

local function _onDelete(mission)
    MDMMarketScreenGraph.reset()
end

Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, _onMissionLoaded)
FSBaseMission.update            = Utils.appendedFunction(FSBaseMission.update, _onUpdate)
FSBaseMission.delete            = Utils.appendedFunction(FSBaseMission.delete, _onDelete)

MDMLog.info("MarketScreen: lifecycle hooks installed")