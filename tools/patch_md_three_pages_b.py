# -*- coding: utf-8 -*-
from pathlib import Path

p = Path(r"FS25_MarketDynamics/src/gui/RfPdaMenuPage.lua")
t = p.read_text(encoding="utf-8")

marker = """--- Apply WC secondary page visibility from self.wcSubPageIndex (1..3; About retired).
function RfPdaMenuPage:_syncWcSubPageVisibility()
    local idx = tonumber(self.wcSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.wcSubPageIndex = idx
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == \"function\" then
            el:setVisible(visible)
        end
    end
    setVis(self.wcPageDashboard, idx == 1)
    setVis(self.wcPageWages, idx == 2)
    setVis(self.wcPageWorkers, idx == 3)
    setVis(self.wcPageAbout, false)
end"""

helpers = r'''--- Apply WC secondary page visibility from self.wcSubPageIndex (1..3; About retired).
function RfPdaMenuPage:_syncWcSubPageVisibility()
    local idx = tonumber(self.wcSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.wcSubPageIndex = idx
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.wcPageDashboard, idx == 1)
    setVis(self.wcPageWages, idx == 2)
    setVis(self.wcPageWorkers, idx == 3)
    setVis(self.wcPageAbout, false)
end

--- MDM page selector = sibling left shell under Brand (WC twin).
function RfPdaMenuPage:_mdPageSel()
    return self.mdSubnavSelector
end

function RfPdaMenuPage:_ensureMdSubnavArrowsVisible()
    self:_ensureMtoArrowsVisible(self:_mdPageSel())
end

--- Host-seed MDM page labels once on MDM enter (never forceEvent).
function RfPdaMenuPage:_seedMdSubnavTexts()
    local sel = self:_mdPageSel()
    if sel == nil then
        return
    end
    if self._mdSubnavSeeded then
        return
    end
    local trFn = self._rfTr
    local function t(key, fb)
        if type(trFn) == "function" then
            return trFn(key, fb)
        end
        return fb
    end
    if sel.setVisible then
        sel:setVisible(true)
    end
    sel.disableButtonsOnSingleText = false
    sel.hideLeftRightButtons = false
    if sel.setCanChangeState then
        sel:setCanChangeState(true)
    end
    if sel.setDisabled then
        sel:setDisabled(false)
    end
    local texts = {
        t("md_rf_pda_page_prices", "Prices"),
        t("md_rf_pda_page_events", "Events"),
        t("md_rf_pda_page_contracts", "Contracts"),
    }
    self._mdSubnavSeeding = true
    if sel.setTexts then
        sel:setTexts(texts)
    end
    local idx = tonumber(self.mdSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.mdSubPageIndex = idx
    if sel.setState then
        sel:setState(idx, false)
    end
    self._mdSubnavSeeding = false
    self._mdSubnavSeeded = true
    self:_ensureMdSubnavArrowsVisible()
    self:_rebuildMdSubnavDots(3)
    if self.mdSubnavShell ~= nil and self.mdSubnavShell.updateAbsolutePosition then
        self.mdSubnavShell:updateAbsolutePosition()
    end
    if sel.updateAbsolutePosition then
        sel:updateAbsolutePosition()
    end
end

function RfPdaMenuPage:_rebuildMdSubnavDots(count)
    local dotBox = self.mdSubnavDotBox
    if dotBox == nil or dotBox.elements == nil or #dotBox.elements == 0 then
        return
    end
    if type(dotBox.setVisible) == "function" then
        dotBox:setVisible(true)
    end
    local elements = dotBox.elements
    local expectedCount = math.max(1, count or 1)
    while #elements < expectedCount do
        local seed = elements[1]
        if seed == nil or seed.clone == nil then
            break
        end
        local ok, clone = pcall(function()
            return seed:clone(dotBox)
        end)
        if not ok or clone == nil then
            break
        end
        if FocusManager and FocusManager.loadElementFromCustomValues then
            pcall(FocusManager.loadElementFromCustomValues, FocusManager, clone)
        end
        elements = dotBox.elements
    end
    while #elements > expectedCount do
        local last = elements[#elements]
        if last ~= nil and last.delete then
            last:delete()
        end
        elements = dotBox.elements
    end
    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            local sel = self:_mdPageSel()
            if sel == nil or sel.getState == nil then
                return index == 1
            end
            return sel:getState() == index
        end
        if dot.setVisible then
            dot:setVisible(true)
        end
    end
    if dotBox.invalidateLayout then
        dotBox:invalidateLayout()
    end
    if type(dotBox.updateAbsolutePosition) == "function" then
        dotBox:updateAbsolutePosition()
    end
end

--- Apply MDM secondary page visibility from self.mdSubPageIndex (1..3).
--- TOP mdTableRegion stays visible; only BOTTOM bands swap.
function RfPdaMenuPage:_syncMdSubPageVisibility()
    local idx = tonumber(self.mdSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.mdSubPageIndex = idx
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.mdPricesBand, idx == 1)
    setVis(self.mdEventsBand, idx == 2)
    setVis(self.mdContractsBand, idx == 3)
    setVis(self.mdOpenMarketBtn, idx == 1)
    local btnE = self:getDescendantById("mdOpenMarketBtnEvents")
    local btnC = self:getDescendantById("mdOpenMarketBtnContracts")
    setVis(btnE, idx == 2)
    setVis(btnC, idx == 3)
    if idx == 1 and self.mdGraphArea ~= nil and type(self.mdGraphArea.updateAbsolutePosition) == "function" then
        self.mdGraphArea:updateAbsolutePosition()
    end
end

--- Sibling-shell MDM page MTO. Page index only — never Brand / selectPanel.
function RfPdaMenuPage:onClickMdSubnavSelector()
    if self._mdSubnavSeeding then
        return
    end
    local sel = self:_mdPageSel()
    if sel == nil or sel.getState == nil then
        return
    end
    if sel ~= self.mdSubnavSelector then
        return
    end
    self:_ensureMdSubnavArrowsVisible()
    local idx = sel:getState() or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.mdSubPageIndex = idx
    if sel.setState and sel:getState() ~= idx then
        sel:setState(idx, false)
    end
    self:_syncMdSubPageVisibility()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and active.id == "marketDynamics" and type(active.onShow) == "function" then
        pcall(active.onShow, self.rfHostPlaceholder, true)
    end
end
'''

# Fix marker - the file has real quotes not escaped
marker = marker.replace('\\"', '"')
if marker not in t:
    raise SystemExit("WC sync marker not found")
if "_syncMdSubPageVisibility" in t:
    print("helpers already present")
else:
    t = t.replace(marker, helpers, 1)
    print("helpers inserted")

old4 = """function RfPdaMenuPage:getNumberOfItemsInSection(list, section)
    if list == self.fieldOverviewList then
        return #self.fieldData
    end
    if list == self.csFieldOverviewList then
        return #(self.csFieldData or {})
    end
    if list == self.moduleList then
        return #self._panelCache
    end
    return 0
end"""
new4 = """function RfPdaMenuPage:getNumberOfItemsInSection(list, section)
    if list == self.fieldOverviewList then
        return #self.fieldData
    end
    if list == self.csFieldOverviewList then
        return #(self.csFieldData or {})
    end
    if list == self.mdCommodityList then
        return #(self.mdCommodityData or {})
    end
    if list == self.moduleList then
        return #self._panelCache
    end
    return 0
end"""
if old4 not in t:
    raise SystemExit("getNumberOfItems not found")
t = t.replace(old4, new4, 1)

old5 = """function RfPdaMenuPage:populateCellForItemInSection(list, section, index, cell)
    cell.rowDataIndex = index
    if list == self.fieldOverviewList then
        local panel = soilPanel()
        if panel ~= nil then
            panel.populateFieldRow(self, index, cell)
        end
    elseif list == self.csFieldOverviewList then
        self:_populateCsFieldRow(index, cell)
    elseif list == self.moduleList then
        self:_populateModuleRow(index, cell)
    end
end"""
new5 = r'''function RfPdaMenuPage:populateCellForItemInSection(list, section, index, cell)
    cell.rowDataIndex = index
    if list == self.fieldOverviewList then
        local panel = soilPanel()
        if panel ~= nil then
            panel.populateFieldRow(self, index, cell)
        end
    elseif list == self.csFieldOverviewList then
        self:_populateCsFieldRow(index, cell)
    elseif list == self.mdCommodityList then
        self:_populateMdCommodityRow(index, cell)
    elseif list == self.moduleList then
        self:_populateModuleRow(index, cell)
    end
end

function RfPdaMenuPage:_populateMdCommodityRow(index, cell)
    local entry = (self.mdCommodityData or {})[index]
    if entry == nil then return end
    local nameEl = cell:getDescendantByName("mdCropRowName")
    local priceEl = cell:getDescendantByName("mdCropRowPrice")
    local changeEl = cell:getDescendantByName("mdCropRowChange")
    if nameEl then nameEl:setText(entry.title or "-") end
    local priceText = "-"
    if entry.price ~= nil then
        if g_i18n and g_i18n.formatMoney then
            priceText = g_i18n:formatMoney(entry.price, 0, true, true)
        else
            priceText = string.format("%.0f", entry.price)
        end
    end
    if priceEl then priceEl:setText(priceText) end
    local pct = tonumber(entry.changePct) or 0
    local changeText
    if pct > 0 then
        changeText = string.format("+%.1f%%", pct)
    else
        changeText = string.format("%.1f%%", pct)
    end
    if changeEl then
        changeEl:setText(changeText)
        if type(changeEl.setTextColor) == "function" then
            if pct > 0.5 then
                changeEl:setTextColor(0.30, 0.80, 0.35, 1)
            elseif pct < -0.5 then
                changeEl:setTextColor(0.90, 0.25, 0.20, 1)
            else
                changeEl:setTextColor(0.70, 0.72, 0.75, 1)
            end
        end
    end
end
'''
if old5 not in t:
    raise SystemExit("populateCell not found")
t = t.replace(old5, new5, 1)

old6 = """        if active ~= nil and active.id == \"workerCosts\" then
            self:_seedWcSubnavTexts()
            self:_syncWcSubPageVisibility()
            self:_ensureWcSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
            local pageIdx = tonumber(self.wcSubPageIndex) or 1
            if pageIdx == 2 then
                self:_ensureWcWageArrowsVisible()
            end
        end"""
old6 = old6.replace('\\"', '"')
new6 = """        if active ~= nil and active.id == \"workerCosts\" then
            self:_seedWcSubnavTexts()
            self:_syncWcSubPageVisibility()
            self:_ensureWcSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
            local pageIdx = tonumber(self.wcSubPageIndex) or 1
            if pageIdx == 2 then
                self:_ensureWcWageArrowsVisible()
            end
        end
        if active ~= nil and active.id == \"marketDynamics\" then
            self:_seedMdSubnavTexts()
            self:_syncMdSubPageVisibility()
            self:_ensureMdSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
        end"""
new6 = new6.replace('\\"', '"')
if old6 not in t:
    raise SystemExit("WC seed block not found")
if 'active.id == "marketDynamics"' in t and "_seedMdSubnavTexts()" in t.split('active.id == "marketDynamics"')[1][:400]:
    print("MDM seed already in refresh")
else:
    t = t.replace(old6, new6, 1)
    print("MDM seed added")

old7 = """function RfPdaMenuPage:onClickMdMoverSelector()
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onMoverChanged) == \"function\" then
        MdRfPdaGuest.onMoverChanged(self.rfHostPlaceholder or self)
    end
end

function RfPdaMenuPage:onClickMdOpenMarket()
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onOpenFullMarket) == \"function\" then
        MdRfPdaGuest.onOpenFullMarket()
    elseif MDMMarketScreen ~= nil and type(MDMMarketScreen.show) == \"function\" then
        MDMMarketScreen.show()
    end
end"""
old7 = old7.replace('\\"', '"')
new7 = r'''function RfPdaMenuPage:onClickMdMoverSelector()
    -- Retired movers MTO (kept for nil-safe onClick binding).
    return
end

--- Mirror onClickCsFieldRow for MDM commodities: select row, refresh Prices bottom.
function RfPdaMenuPage:onClickMdCommodityRow(element)
    local index = nil
    if element ~= nil then
        index = element.rowDataIndex or element.indexInSection
        if index == nil and element.parent ~= nil then
            index = element.parent.rowDataIndex or element.parent.indexInSection
        end
    end
    if index == nil and self.mdCommodityList ~= nil and type(self.mdCommodityList.getSelectedIndex) == "function" then
        index = self.mdCommodityList:getSelectedIndex()
    end
    if index == nil or index < 1 then
        return
    end
    if self.mdCommodityList ~= nil and type(self.mdCommodityList.setSelectedIndex) == "function" then
        pcall(function() self.mdCommodityList:setSelectedIndex(index) end)
    end
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.selectCommodityIndex) == "function" then
        MdRfPdaGuest.selectCommodityIndex(index)
    end
end

function RfPdaMenuPage:onClickMdOpenMarket()
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onOpenFullMarket) == "function" then
        MdRfPdaGuest.onOpenFullMarket()
    elseif MDMMarketScreen ~= nil and type(MDMMarketScreen.show) == "function" then
        MDMMarketScreen.show()
    end
end
'''
if old7 not in t:
    raise SystemExit("MDM click handlers not found")
t = t.replace(old7, new7, 1)

# Hook list selection for MDM
old8 = """function RfPdaMenuPage:onListSelectionChanged(list, section, index)"""
# will patch body separately after reading

p.write_text(t, encoding="utf-8")
print("part2 OK", p.stat().st_size)
