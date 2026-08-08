# -*- coding: utf-8 -*-
from pathlib import Path

paths = [
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_MarketDynamics\src\gui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SoilFertilizer\src\ui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SeasonalCropStress\src\ui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_WorkerCosts\src\gui\RfPdaMenuPage.lua"),
]

needle = '''function RfPdaMenuPage:_syncHostGuestChrome(activeId)
    local isSoil = activeId == nil or activeId == "soilFertilizer"
    local isCs = activeId == "seasonalCropStress"
    local isWc = activeId == "workerCosts"
    local function setVis(el, visible)'''

repl = '''function RfPdaMenuPage:_syncHostGuestChrome(activeId)
    local isSoil = activeId == nil or activeId == "soilFertilizer"
    local isCs = activeId == "seasonalCropStress"
    local isWc = activeId == "workerCosts"
    local isMd = activeId == "marketDynamics"
    local function setVis(el, visible)'''

for p in paths:
    t = p.read_text(encoding="utf-8")
    if needle not in t:
        if 'function RfPdaMenuPage:_syncHostGuestChrome(activeId)' in t and 'local isMd = activeId == "marketDynamics"' in t.split('_syncHostGuestChrome')[1][:400]:
            print("already ok", p)
            continue
        print("FAIL needle", p)
        # show snippet
        i = t.find("_syncHostGuestChrome")
        print(repr(t[i:i+280]))
        continue
    t = t.replace(needle, repl, 1)
    # fix side shell in sync if still missing isMd
    # After wcSideInfoShell lines in sync, side shell should include isMd
    t = t.replace("setVis(self.rfSideInfoShell, isSoil or isCs)\n    -- On WC:", "setVis(self.rfSideInfoShell, isSoil or isCs or isMd)\n    -- On WC:")
    t = t.replace("setVis(self.rfSideInfoShell, isSoil or isCs)\n    setVis(self.rfPanelDotBox", "setVis(self.rfSideInfoShell, isSoil or isCs or isMd)\n    setVis(self.rfPanelDotBox")
    p.write_text(t, encoding="utf-8")
    print("fixed sync isMd", p.parent.parent.parent.name)
