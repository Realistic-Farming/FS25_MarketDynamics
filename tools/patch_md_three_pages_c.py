# -*- coding: utf-8 -*-
from pathlib import Path

p = Path(r"FS25_MarketDynamics/src/gui/RfPdaMenuPage.lua")
t = p.read_text(encoding="utf-8")

if "function RfPdaMenuPage:_syncMdSubPageVisibility" in t:
    print("already has definitions")
else:
    anchor = """function RfPdaMenuPage:_syncWcSubPageVisibility()
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
"""
    if anchor not in t:
        raise SystemExit("anchor missing")
    helpers = r'''
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

--- Sibling-shell MDM page MTO. Page index only - never Brand / selectPanel.
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
    t = t.replace(anchor, anchor + helpers, 1)
    print("inserted helpers")

# Fix list selection + commodity click to use resolveListRowIndex
old_sel = """    elseif list == self.csFieldOverviewList and index ~= nil and index > 0 then
        local entry = (self.csFieldData or {})[index]
        if entry ~= nil then
            self.csSelectedIndex = index
            self.csSelectedFieldId = entry.fieldId
            self:_refreshGuestDetail()
        end
    elseif list == self.moduleList then"""
new_sel = """    elseif list == self.csFieldOverviewList and index ~= nil and index > 0 then
        local entry = (self.csFieldData or {})[index]
        if entry ~= nil then
            self.csSelectedIndex = index
            self.csSelectedFieldId = entry.fieldId
            self:_refreshGuestDetail()
        end
    elseif list == self.mdCommodityList and index ~= nil and index > 0 then
        if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.selectCommodityIndex) == "function" then
            MdRfPdaGuest.selectCommodityIndex(index)
        end
    elseif list == self.moduleList then"""
if old_sel not in t:
    raise SystemExit("list selection anchor missing")
if "list == self.mdCommodityList and index" not in t:
    t = t.replace(old_sel, new_sel, 1)
    print("list selection hooked")
else:
    print("list selection already hooked")

old_click = """--- Mirror onClickCsFieldRow for MDM commodities: select row, refresh Prices bottom.
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
end"""
new_click = """--- Mirror onClickCsFieldRow for MDM commodities: select row, refresh Prices bottom.
function RfPdaMenuPage:onClickMdCommodityRow(element)
    local index = resolveListRowIndex(element)
    if index == nil or index < 1 then
        return
    end
    if self.mdCommodityList and self.mdCommodityList.setSelectedIndex then
        pcall(function() self.mdCommodityList:setSelectedIndex(index) end)
    end
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.selectCommodityIndex) == "function" then
        MdRfPdaGuest.selectCommodityIndex(index)
    end
end"""
if old_click in t:
    t = t.replace(old_click, new_click, 1)
    print("click simplified")
else:
    print("click pattern mismatch; leaving as-is")

# Fix em dash corruption if any
t = t.replace("â€”", "-")
t = t.replace("—", "-")

p.write_text(t, encoding="utf-8")
print("done", "function RfPdaMenuPage:_syncMdSubPageVisibility" in t)
