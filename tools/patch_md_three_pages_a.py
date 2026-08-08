# -*- coding: utf-8 -*-
from pathlib import Path

p = Path(r"FS25_MarketDynamics/src/gui/RfPdaMenuPage.lua")
t = p.read_text(encoding="utf-8")

old = """    setVis(self.rfHostTableRegion, isCs)
    setVis(self.csFieldOverviewList, isCs)
    setVis(self.csDetailStrip, isCs)
    setVis(self.mdGraphRegion, isMd)
    setVis(self.mdDetailStrip, isMd)
    setVis(self.mdMoverSelector, isMd)
    setVis(self.mdOpenMarketBtn, isMd)
    if self.mdMoverSelector ~= nil then
        self.mdMoverSelector.disableButtonsOnSingleText = false
        self.mdMoverSelector.hideLeftRightButtons = not isMd
        if type(self.mdMoverSelector.setDisabled) == "function" then
            self.mdMoverSelector:setDisabled(not isMd)
        end
        if isMd and type(self._ensureMtoArrowsVisible) == "function" then
            self:_ensureMtoArrowsVisible(self.mdMoverSelector)
        end
        if isMd and self.mdGraphRegion ~= nil and type(self.mdGraphRegion.updateAbsolutePosition) == "function" then
            self.mdGraphRegion:updateAbsolutePosition()
        end
        if isMd and self.mdGraphArea ~= nil and type(self.mdGraphArea.updateAbsolutePosition) == "function" then
            self.mdGraphArea:updateAbsolutePosition()
        end
    end
    if not isCs then
        setVis(self.csFieldsEmptyHint, false)
    end
    -- Fresh WC: page MTO lives in sibling wcSubnavShell (NOT rfFilterBox). Brand alone in filter.
    setVis(self.wcSubnavShell, isWc)
    setVis(self.wcSubnavSelector, isWc)
    setVis(self.wcSubnavDotBox, isWc)"""

new = """    setVis(self.rfHostTableRegion, isCs)
    setVis(self.csFieldOverviewList, isCs)
    setVis(self.csDetailStrip, isCs)
    -- MDM three-page chrome (TOP table + BOTTOM bands + secondary subnav).
    setVis(self.mdTableRegion, isMd)
    setVis(self.mdCommodityList, isMd)
    setVis(self.mdPageBand, isMd)
    setVis(self.mdGraphRegion, false)
    setVis(self.mdDetailStrip, false)
    setVis(self.mdMoverSelector, false)
    if self.mdMoverSelector ~= nil then
        self.mdMoverSelector.hideLeftRightButtons = true
        if type(self.mdMoverSelector.setDisabled) == "function" then
            self.mdMoverSelector:setDisabled(true)
        end
    end
    if isMd then
        if self.mdTableRegion ~= nil and type(self.mdTableRegion.updateAbsolutePosition) == "function" then
            self.mdTableRegion:updateAbsolutePosition()
        end
        if self.mdPageBand ~= nil and type(self.mdPageBand.updateAbsolutePosition) == "function" then
            self.mdPageBand:updateAbsolutePosition()
        end
        if self.mdGraphArea ~= nil and type(self.mdGraphArea.updateAbsolutePosition) == "function" then
            self.mdGraphArea:updateAbsolutePosition()
        end
        if type(self._seedMdSubnavTexts) == "function" then
            self:_seedMdSubnavTexts()
        end
        if type(self._syncMdSubPageVisibility) == "function" then
            self:_syncMdSubPageVisibility()
        end
    else
        setVis(self.mdPricesBand, false)
        setVis(self.mdEventsBand, false)
        setVis(self.mdContractsBand, false)
        setVis(self.mdOpenMarketBtn, false)
        local btnE = self:getDescendantById("mdOpenMarketBtnEvents")
        local btnC = self:getDescendantById("mdOpenMarketBtnContracts")
        setVis(btnE, false)
        setVis(btnC, false)
    end
    if not isCs then
        setVis(self.csFieldsEmptyHint, false)
    end
    -- Fresh WC: page MTO lives in sibling wcSubnavShell (NOT rfFilterBox). Brand alone in filter.
    setVis(self.wcSubnavShell, isWc)
    setVis(self.wcSubnavSelector, isWc)
    setVis(self.wcSubnavDotBox, isWc)
    -- MDM subnav twin (Prices | Events | Contracts); exclusive with WC subnav.
    setVis(self.mdSubnavShell, isMd)
    setVis(self.mdSubnavSelector, isMd)
    setVis(self.mdSubnavDotBox, isMd)
    if self.mdSubnavSelector ~= nil then
        if isMd then
            self.mdSubnavSelector.disableButtonsOnSingleText = false
            self.mdSubnavSelector.hideLeftRightButtons = false
            if type(self.mdSubnavSelector.setDisabled) == "function" then
                self.mdSubnavSelector:setDisabled(false)
            end
            if type(self.mdSubnavSelector.setCanChangeState) == "function" then
                self.mdSubnavSelector:setCanChangeState(true)
            end
            if self.mdSubnavShell ~= nil and type(self.mdSubnavShell.updateAbsolutePosition) == "function" then
                self.mdSubnavShell:updateAbsolutePosition()
            end
            if type(self.mdSubnavSelector.updateAbsolutePosition) == "function" then
                self.mdSubnavSelector:updateAbsolutePosition()
            end
            if type(self._ensureMdSubnavArrowsVisible) == "function" then
                self:_ensureMdSubnavArrowsVisible()
            end
        else
            self.mdSubnavSelector.hideLeftRightButtons = true
            if type(self.mdSubnavSelector.setDisabled) == "function" then
                self.mdSubnavSelector:setDisabled(true)
            end
            if type(self.mdSubnavSelector.setCanChangeState) == "function" then
                self.mdSubnavSelector:setCanChangeState(false)
            end
            self._mdSubnavSeeded = false
        end
    end"""

if old not in t:
    raise SystemExit("OLD BLOCK1 not found")
t = t.replace(old, new, 1)

old2 = """    -- On WC: hide Brand mid chrome so page sibling band owns that Y; Modules dock stays.
    setVis(self.rfPanelDotBox, not isWc)"""
new2 = """    -- On WC or MDM: hide Brand mid chrome so page sibling band owns that Y; Modules dock stays.
    setVis(self.rfPanelDotBox, not isWc and not isMd)"""
if old2 not in t:
    raise SystemExit("OLD BLOCK2 not found")
t = t.replace(old2, new2, 1)

old3 = """    if (isWc or isCs or isMd) and self.rfHostBody and self.rfHostBody.setText then
        self.rfHostBody:setText(\"\")
    end
    -- NEVER shrink MODULES dock below workable height (George: >=220)."""
new3 = """    if (isWc or isCs or isMd) and self.rfHostBody and self.rfHostBody.setText then
        self.rfHostBody:setText(\"\")
    end
    -- Bottom bar: SPACE opens full Market while MDM is active.
    if isMd and self.btnOpenMarket ~= nil then
        self.menuButtonInfo = { self.btnBack, self.btnOpenMarket }
        local trFn = self._rfTr
        if type(trFn) == \"function\" then
            self.btnOpenMarket.text = trFn(\"md_rf_pda_open_market\", \"Open full Market\")
        end
    else
        self.menuButtonInfo = { self.btnBack, self.btnHelp }
    end
    if type(self.setMenuButtonInfoDirty) == \"function\" then
        self:setMenuButtonInfoDirty()
    end
    -- NEVER shrink MODULES dock below workable height (George: >=220)."""
if old3 not in t:
    raise SystemExit("OLD BLOCK3 not found")
t = t.replace(old3, new3, 1)

p.write_text(t, encoding="utf-8")
print("part1 OK")
