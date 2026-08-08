# -*- coding: utf-8 -*-
from pathlib import Path

paths = [
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_MarketDynamics\src\gui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SoilFertilizer\src\ui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SeasonalCropStress\src\ui\RfPdaMenuPage.lua"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_WorkerCosts\src\gui\RfPdaMenuPage.lua"),
]

old = '    setVis(self.rfSideInfoShell, isSoil or isCs)'
new = '    setVis(self.rfSideInfoShell, isSoil or isCs or isMd)'

for p in paths:
    t = p.read_text(encoding="utf-8")
    t = t.replace(old, new)
    t = t.replace("isSoil or isCs or isMd or isMd", "isSoil or isCs or isMd")
    # Drop fragile getIsVisible guard — activeModuleId + region nil-check is enough.
    t = t.replace(
        "and self.mdGraphRegion ~= nil and self.mdGraphRegion.getIsVisible\n"
        "                and self.mdGraphRegion:getIsVisible()\n"
        "                and MDMMarketScreenGraph",
        "and self.mdGraphRegion ~= nil\n"
        "                and MDMMarketScreenGraph",
    )
    # Ensure _syncHostGuestChrome declares isMd (already done) and _refreshSideInfo side vis uses isMd.
    # Also ensure _refreshSideInfo declares isMd
    needle = (
        '    local isSoil = activeId == nil or activeId == "soilFertilizer"\n'
        '    local isCs = activeId == "seasonalCropStress"\n'
        '    local isWc = activeId == "workerCosts"\n'
        "    local function setVis(el, visible)"
    )
    repl = (
        '    local isSoil = activeId == nil or activeId == "soilFertilizer"\n'
        '    local isCs = activeId == "seasonalCropStress"\n'
        '    local isWc = activeId == "workerCosts"\n'
        '    local isMd = activeId == "marketDynamics"\n'
        "    local function setVis(el, visible)"
    )
    if needle in t and 'local isMd = activeId == "marketDynamics"\n    local function setVis' not in t:
        # Only first occurrence in _refreshSideInfo may still lack isMd if sync already has it elsewhere
        pass
    # Count how many times isMd is declared vs needed
    p.write_text(t, encoding="utf-8")
    print(p.parent.parent.parent.name, "side old leftover", t.count(old), "getIsVisible", t.count("getIsVisible"))
