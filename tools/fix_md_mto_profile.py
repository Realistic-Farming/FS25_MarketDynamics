# -*- coding: utf-8 -*-
from pathlib import Path

OLD = 'profile="RF_MultiTextOption" id="mdMoverSelector"'
NEW = 'profile="RF_WcWageOption" id="mdMoverSelector"'
paths = [
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_MarketDynamics\xml\gui\RfPdaMenuPage.xml"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SoilFertilizer\xml\gui\RfPdaMenuPage.xml"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SeasonalCropStress\xml\gui\RfPdaMenuPage.xml"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_WorkerCosts\xml\gui\RfPdaMenuPage.xml"),
]
for p in paths:
    t = p.read_text(encoding="utf-8")
    if OLD not in t:
        print("no OLD in", p)
        continue
    p.write_text(t.replace(OLD, NEW), encoding="utf-8")
    print("fixed", p)
