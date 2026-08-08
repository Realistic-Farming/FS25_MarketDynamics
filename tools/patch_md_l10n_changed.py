# -*- coding: utf-8 -*-
from pathlib import Path
import re

root = Path("FS25_MarketDynamics/translations")
updates = {
    "md_rf_pda_blurb": (
        "Pause Market glance: Prices, Events, Contracts. Top table stays; bottom swaps. "
        "Open full Market for the deep desk."
    ),
    "rf_pda_side_info_market_dynamics": (
        "Market Dynamics&#10;&#10;Pause Market glance with three pages: Prices, Events, Contracts."
        "&#10;&#10;Top table = crops, prices, and swings. On Prices, pick a crop to drive the graph."
        "&#10;&#10;Events page = what is hitting the market now, how strong, and how long left."
        "&#10;&#10;Contracts page = your open deals (read-only). Manage them in full Market."
        "&#10;&#10;Open full Market (SPACE) for the deep desk."
    ),
}

for path in sorted(root.glob("translation_*.xml")):
    if path.name == "translation_en.xml":
        continue
    text = path.read_text(encoding="utf-8")
    orig = text
    for key, en in updates.items():
        pat = re.compile(r'(<text name="' + re.escape(key) + r'"\s+text=")(?:[^"]*)(")')

        def do_repl(m, _en=en):
            return m.group(1) + "[EN] " + _en + m.group(2)

        text, n = pat.subn(do_repl, text, count=1)
        if n == 0:
            print("missing", path.name, key)
    if text != orig:
        path.write_text(text, encoding="utf-8")
        print("updated", path.name)
print("done")
