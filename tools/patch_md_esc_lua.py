# -*- coding: utf-8 -*-
"""Patch RfPdaMenuPage.lua carriers for Market Dynamics chrome sync + graph draw."""
from pathlib import Path

PATHS = [
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_MarketDynamics\src\gui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SoilFertilizer\src\ui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SeasonalCropStress\src\ui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_WorkerCosts\src\gui\RfPdaMenuPage.lua"),
]

BIND_NEEDLE = "self.csDetailStrip = self:getDescendantById(\"csDetailStrip\") or self.csDetailStrip"
BIND_INSERT = """self.csDetailStrip = self:getDescendantById("csDetailStrip") or self.csDetailStrip
    self.mdGraphRegion = self:getDescendantById("mdGraphRegion") or self.mdGraphRegion
    self.mdGraphArea = self:getDescendantById("mdGraphArea") or self.mdGraphArea
    self.mdDetailStrip = self:getDescendantById("mdDetailStrip") or self.mdDetailStrip
    self.mdMoverSelector = self:getDescendantById("mdMoverSelector") or self.mdMoverSelector
    self.mdEventsBand = self:getDescendantById("mdEventsBand") or self.mdEventsBand
    self.mdOpenMarketBtn = self:getDescendantById("mdOpenMarketBtn") or self.mdOpenMarketBtn"""

SYNC_NEEDLE = """    local isSoil = activeId == nil or activeId == "soilFertilizer"
    local isCs = activeId == "seasonalCropStress"
    local isWc = activeId == "workerCosts\""""

SYNC_REPL = """    local isSoil = activeId == nil or activeId == "soilFertilizer"
    local isCs = activeId == "seasonalCropStress"
    local isWc = activeId == "workerCosts"
    local isMd = activeId == "marketDynamics\""""

# After setVis(csDetailStrip...) add md visibility. Find a unique anchor.
HIDE_CS_ANCHOR = "    setVis(self.csDetailStrip, isCs)"
HIDE_CS_REPL = """    setVis(self.csDetailStrip, isCs)
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
    end"""

SIDE_ANCHOR = "    setVis(self.rfSideInfoShell, isSoil or isCs)"
SIDE_REPL = "    setVis(self.rfSideInfoShell, isSoil or isCs or isMd)"

BODY_ANCHOR = "    setVis(self.rfHostBody, not isWc and not isCs)"
BODY_REPL = "    setVis(self.rfHostBody, not isWc and not isCs and not isMd)"

BODY_CLEAR_ANCHOR = "    if (isWc or isCs) and self.rfHostBody and self.rfHostBody.setText then"
BODY_CLEAR_REPL = "    if (isWc or isCs or isMd) and self.rfHostBody and self.rfHostBody.setText then"

REFRESH_SIDE_NEEDLE = """        elseif isCs then
            self.rfSideInfoBody:setText(tr("rf_pda_side_info_crop_stress",
                "Crop Stress"""

# We'll inject MD branch before the final else that clears body.
SIDE_ELSE_ANCHOR = """        else
            self.rfSideInfoBody:setText("")
        end
    end
end

--- Show/hide CS table+detail twins and WC subnav/page shells by active guest panel id."""

SIDE_ELSE_REPL = """        elseif isMd then
            self.rfSideInfoBody:setText(tr("rf_pda_side_info_market_dynamics",
                "Market Dynamics\\n\\nThis is a pause market glance, not the full Market desk.\\n\\nGraph = price path for the crop you pick.\\n\\nMovers = biggest swings right now. Click one to change the graph.\\n\\nEvents = world events still driving prices. Empty means nothing active (normal).\\n\\nBottom strip = facts for the crop you selected.\\n\\nContracts line = open count only. Full contracts live deeper.\\n\\nOpen full Market when you need Prices / Events / Contracts admin."))
        else
            self.rfSideInfoBody:setText("")
        end
    end
end

--- Show/hide CS table+detail twins and WC subnav/page shells by active guest panel id."""

DRAW_NEEDLE = """function RfPdaMenuPage:draw(clipX1, clipY1, clipX2, clipY2)
    RfPdaMenuPage:superClass().draw(self, clipX1, clipY1, clipX2, clipY2)
    if not self._frameDebug then
        return
    end"""

DRAW_REPL = """function RfPdaMenuPage:draw(clipX1, clipY1, clipX2, clipY2)
    RfPdaMenuPage:superClass().draw(self, clipX1, clipY1, clipX2, clipY2)
    -- Market Dynamics Esc glance graph (after chrome). Reuse MDMMarketScreenGraph.draw.
    do
        local host = self:_getHost()
        local active = host and host.getActivePanel and host:getActivePanel()
        if active ~= nil and active.id == "marketDynamics"
                and self.mdGraphRegion ~= nil and self.mdGraphRegion.getIsVisible
                and self.mdGraphRegion:getIsVisible()
                and MDMMarketScreenGraph ~= nil and type(MDMMarketScreenGraph.draw) == "function" then
            local area = self.mdGraphArea or self.mdGraphRegion
            if area ~= nil and area.absPosition ~= nil and area.absSize ~= nil then
                local ft = self.mdSelectedFillType
                if ft == nil and MdRfPdaGuest ~= nil and type(MdRfPdaGuest.getSelectedFillType) == "function" then
                    ft = MdRfPdaGuest.getSelectedFillType()
                end
                if ft ~= nil then
                    MDMMarketScreenGraph.draw(ft, area.absPosition[1], area.absPosition[2], area.absSize[1], area.absSize[2])
                end
            end
        end
    end
    if not self._frameDebug then
        return
    end"""

UPDATE_MD_NEEDLE = """    local isWc = active ~= nil and active.id == "workerCosts"

    -- WC Dashboard/Workers: 500ms text-only live refresh (George FULL PORT ACK).
    if isWc then"""

UPDATE_MD_REPL = """    local isWc = active ~= nil and active.id == "workerCosts"
    local isMd = active ~= nil and active.id == "marketDynamics"

    -- Market Dynamics: light text/graph refresh; never SmoothList thrash.
    if isMd then
        self._mdLiveTimer = (self._mdLiveTimer or 0) + dt
        if self._mdLiveTimer >= REFRESH_INTERVAL then
            self._mdLiveTimer = 0
            if active ~= nil and type(active.onShow) == "function" then
                pcall(active.onShow, self.rfHostPlaceholder, true)
            end
        end
        return
    end

    -- WC Dashboard/Workers: 500ms text-only live refresh (George FULL PORT ACK).
    if isWc then"""

CLICK_HANDLERS = """
function RfPdaMenuPage:onClickMdMoverSelector()
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onMoverChanged) == "function" then
        MdRfPdaGuest.onMoverChanged(self.rfHostPlaceholder or self)
    end
end

function RfPdaMenuPage:onClickMdOpenMarket()
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onOpenFullMarket) == "function" then
        MdRfPdaGuest.onOpenFullMarket()
    elseif MDMMarketScreen ~= nil and type(MDMMarketScreen.show) == "function" then
        MDMMarketScreen.show()
    end
end
"""


def patch_one(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    notes = []
    if 'self.mdGraphRegion =' in text:
        notes.append("bindings already present")
    else:
        if BIND_NEEDLE not in text:
            notes.append("FAIL bind needle")
            return notes
        text = text.replace(BIND_NEEDLE, BIND_INSERT, 1)
        notes.append("bindings")

    if 'local isMd = activeId == "marketDynamics"' in text:
        notes.append("sync vars already")
    else:
        if SYNC_NEEDLE not in text:
            notes.append("FAIL sync needle")
        else:
            text = text.replace(SYNC_NEEDLE, SYNC_REPL, 1)
            notes.append("sync vars")

    if "setVis(self.mdGraphRegion, isMd)" in text:
        notes.append("md vis already")
    else:
        if HIDE_CS_ANCHOR not in text:
            notes.append("FAIL hide cs anchor")
        else:
            text = text.replace(HIDE_CS_ANCHOR, HIDE_CS_REPL, 1)
            notes.append("md vis")

    if SIDE_ANCHOR in text and "isMd)" not in text[text.find(SIDE_ANCHOR):text.find(SIDE_ANCHOR)+80]:
        text = text.replace(SIDE_ANCHOR, SIDE_REPL, 1)
        notes.append("side vis")
    elif "isSoil or isCs or isMd" in text:
        notes.append("side vis already")
    else:
        # try replace if still old form
        if SIDE_ANCHOR in text:
            text = text.replace(SIDE_ANCHOR, SIDE_REPL, 1)
            notes.append("side vis")

    if BODY_ANCHOR in text:
        text = text.replace(BODY_ANCHOR, BODY_REPL, 1)
        notes.append("body vis")
    if BODY_CLEAR_ANCHOR in text:
        text = text.replace(BODY_CLEAR_ANCHOR, BODY_CLEAR_REPL, 1)
        notes.append("body clear")

    if 'rf_pda_side_info_market_dynamics' in text and "elseif isMd then" in text:
        notes.append("side text already")
    elif SIDE_ELSE_ANCHOR in text:
        text = text.replace(SIDE_ELSE_ANCHOR, SIDE_ELSE_REPL, 1)
        notes.append("side text")
    else:
        # Alternate: find shorter else clear pattern inside _refreshSideInfo
        alt = """        else
            self.rfSideInfoBody:setText(\"\")
        end
    end
end

--- Show/hide CS table+detail twins"""
        if alt in text and "elseif isMd then" not in text:
            text = text.replace(alt, SIDE_ELSE_REPL.split("--- Show/hide")[0] + "--- Show/hide CS table+detail twins", 1)
            notes.append("side text alt")
        else:
            notes.append("WARN side text pattern")

    if "MDMMarketScreenGraph.draw" in text:
        notes.append("draw already")
    else:
        if DRAW_NEEDLE not in text:
            notes.append("FAIL draw needle")
        else:
            text = text.replace(DRAW_NEEDLE, DRAW_REPL, 1)
            notes.append("draw")

    if "local isMd = active ~= nil and active.id == \"marketDynamics\"" in text:
        notes.append("update already")
    else:
        if UPDATE_MD_NEEDLE not in text:
            notes.append("FAIL update needle")
        else:
            text = text.replace(UPDATE_MD_NEEDLE, UPDATE_MD_REPL, 1)
            notes.append("update")

    if "function RfPdaMenuPage:onClickMdMoverSelector" in text:
        notes.append("clicks already")
    else:
        # append before last return or end of file after onClickCsFieldRow
        anchor = "function RfPdaMenuPage:onClickCsFieldRow(element)"
        if anchor in text:
            # insert after that function ends — append near end before last few functions
            text = text + "\n" + CLICK_HANDLERS
            notes.append("clicks appended")
        else:
            text = text + "\n" + CLICK_HANDLERS
            notes.append("clicks appended eof")

    # Also paint movers label on sync when MD: set mdMoversLabel via guest (guest paints).
    path.write_text(text, encoding="utf-8")
    return notes


def main():
    for p in PATHS:
        print(p)
        print(" ", ", ".join(patch_one(p)))


if __name__ == "__main__":
    main()
