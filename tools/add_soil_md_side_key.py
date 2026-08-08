# -*- coding: utf-8 -*-
from pathlib import Path

p = Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SoilFertilizer\translations\translation_en.xml")
t = p.read_text(encoding="utf-8")
key = "rf_pda_side_info_market_dynamics"
if key in t:
    print("already in soil en")
else:
    marker = "rf_pda_side_info_crop_stress"
    i = t.find(marker)
    if i < 0:
        raise SystemExit("marker missing")
    end = t.find("/>", i) + 2
    line = (
        '\n    <e k="rf_pda_side_info_market_dynamics" v="Market Dynamics&#10;&#10;'
        "This is a pause market glance, not the full Market desk.&#10;&#10;"
        "Graph = price path for the crop you pick.&#10;&#10;"
        "Movers = biggest swings right now. Click one to change the graph.&#10;&#10;"
        "Events = world events still driving prices. Empty means nothing active (normal).&#10;&#10;"
        "Bottom strip = facts for the crop you selected.&#10;&#10;"
        "Contracts line = open count only. Full contracts live deeper.&#10;&#10;"
        'Open full Market when you need Prices / Events / Contracts admin." />'
    )
    t = t[:end] + line + t[end:]
    p.write_text(t, encoding="utf-8")
    print("added to soil en")
