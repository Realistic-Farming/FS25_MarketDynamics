#!/usr/bin/env python3
"""Round 4 Esc chrome assertion gate (2026-08-05).

Asserts the four round-4 edits from ENGINE-George-Esc-round4-2026-08-05:
  E1 RF_SideColUnderlay repainted with vanilla glass slice (baseReference +
     imageSliceId gui.animalScreen_left; NO blank.png, NO imageColor)
  E2 RF_SideInfoShell 10px -148px / 384x300 (10px air law, Soil/CS card)
  E3 rfSideInfoBody inline size 368px 284px (8px pads inside 384 shell)
  E4 RF_WcSideInfoShell 10px -80px / 384x240 (10px air law, WC/MDM card)
plus the round-3 keep list (nest hidden, isCs Lua gates, graph air, pivot pane,
table geometry, WC pages, Soil pH). Round-3 values superseded by round 4
(underlay extends, card X/widths) are asserted at their NEW finals here.
Exit 0 = all pass. Non-zero = at least one FAIL (listed).
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROFILES = ROOT / "xml" / "gui" / "rfEscProfiles.xml"
PAGE = ROOT / "xml" / "gui" / "RfPdaMenuPage.xml"
LUA = ROOT / "src" / "gui" / "RfPdaMenuPage.lua"

failures = []
passes = []


def check(label, cond):
    if cond:
        passes.append(label)
    else:
        failures.append(label)


def profile_map(tree):
    return {p.get("name"): p for p in tree.getroot().iter("Profile")}


def pval(prof, key):
    if prof is None:
        return None
    el = prof.find(key)
    return el.get("value") if el is not None else None


def find_by_id(tree, el_id):
    for el in tree.getroot().iter():
        if el.get("id") == el_id:
            return el
    return None


def find_by_name(tree, name):
    return [el for el in tree.getroot().iter() if el.get("name") == name]


# ---- parse (gate itself proves both files are well-formed XML) ----
ptree = ET.parse(PROFILES)
gtree = ET.parse(PAGE)
profs = profile_map(ptree)
lua_src = LUA.read_text(encoding="utf-8")

# ---- E1: underlay glass repaint ----
under = profs.get("RF_SideColUnderlay")
check("E1 RF_SideColUnderlay extends baseReference",
      under is not None and under.get("extends") == "baseReference")
check("E1 with anchorStretchingYLeft",
      under is not None and under.get("with") == "anchorStretchingYLeft")
check("E1 width 404px", pval(under, "width") == "404px")
check("E1 imageSliceId gui.animalScreen_left",
      pval(under, "imageSliceId") == "gui.animalScreen_left")
check("E1 handleFocus false", pval(under, "handleFocus") == "false")
check("E1 NO blank.png filename on underlay", pval(under, "filename") is None)
check("E1 NO imageColor on underlay (vanilla tone baked in slice)",
      pval(under, "imageColor") is None)
host = find_by_id(gtree, "rfContentHost")
kids = list(host) if host is not None else []
check("E1 underlay Bitmap still FIRST child of rfContentHost",
      len(kids) > 0 and kids[0].tag == "Bitmap" and kids[0].get("profile") == "RF_SideColUnderlay")

# ---- E2: Soil/CS card 10px air law ----
sideinfo = profs.get("RF_SideInfoShell")
check("E2 RF_SideInfoShell position 10px -148px", pval(sideinfo, "position") == "10px -148px")
check("E2 RF_SideInfoShell size 384px 300px", pval(sideinfo, "size") == "384px 300px")

# ---- E3: Soil/CS body narrowed to fit ----
body = find_by_id(gtree, "rfSideInfoBody")
check("E3 rfSideInfoBody size 368px 284px",
      body is not None and body.get("size") == "368px 284px")
check("E3 rfSideInfoBody position 8px -8px held",
      body is not None and body.get("position") == "8px -8px")

# ---- E4: WC/MDM card 10px air law ----
wcshell = profs.get("RF_WcSideInfoShell")
check("E4 RF_WcSideInfoShell position 10px -80px", pval(wcshell, "position") == "10px -80px")
check("E4 RF_WcSideInfoShell size 384px 240px", pval(wcshell, "size") == "384px 240px")
for body_id in ("wcSideInfoBody", "mdSideInfoBody"):
    b = find_by_id(gtree, body_id)
    check(f"E4 {body_id} untouched at 8px -8px / 364x224",
          b is not None and b.get("position") == "8px -8px"
          and b.get("size") == "364px 224px")
mdcard = find_by_id(gtree, "mdSideInfoShell")
check("E4 mdSideInfoShell shares RF_WcSideInfoShell profile (no inline position)",
      mdcard is not None and mdcard.get("profile") == "RF_WcSideInfoShell"
      and mdcard.get("position") is None)
wccard = find_by_id(gtree, "wcSideInfoShell")
check("E4 wcSideInfoShell shares profile (no inline position)",
      wccard is not None and wccard.get("profile") == "RF_WcSideInfoShell"
      and wccard.get("position") is None)

# ---- Keeps (round 3 list) ----
nest = kids[1] if len(kids) > 1 else None
check("KEEP nest ThreePartBitmap still second child",
      nest is not None and nest.tag == "ThreePartBitmap"
      and nest.get("profile") == "RF_SubCategoryContainerBg")
check("KEEP nest visible=false", nest is not None and nest.get("visible") == "false")
arrow_kids = [c for c in (list(nest) if nest is not None else [])
              if c.get("profile") == "fs25_subCategoryContainerArrow"]
check("KEEP arrow child kept under nest, visible=false",
      len(arrow_kids) == 1 and arrow_kids[0].get("visible") == "false")

check("KEEP isCs local defined in _syncHostGuestChrome",
      'local isCs = activeId == "seasonalCropStress"' in lua_src)
check("KEEP rfHostTitle gated with not isCs",
      "setVis(self.rfHostTitle, not isWc and not isMd and not isCs)" in lua_src)
check("KEEP rfHostBlurb gated with not isCs",
      "setVis(self.rfHostBlurb, not isWc and not isMd and not isCs)" in lua_src)
check("KEEP skipHostDuplex includes seasonalCropStress",
      'local skipHostDuplex = active ~= nil and (active.id == "workerCosts"'
      ' or active.id == "marketDynamics" or active.id == "seasonalCropStress")' in lua_src)

graph = profs.get("RF_MdGraphArea")
check("KEEP RF_MdGraphArea position 30px -38px", pval(graph, "position") == "30px -38px")
check("KEEP RF_MdGraphArea size 720px 200px held", pval(graph, "size") == "720px 200px")
hint = find_by_id(gtree, "mdGraphEmptyHint")
check("KEEP mdGraphEmptyHint held at 30px -96px",
      hint is not None and hint.get("position") == "30px -96px")

main = profs.get("RF_MainColShell")
check("KEEP RF_MainColShell with anchorStretchingYLeft pivotBottomLeft",
      main is not None and main.get("with") == "anchorStretchingYLeft pivotBottomLeft")
check("KEEP RF_MainColShell position 404px 40px", pval(main, "position") == "404px 40px")
check("KEEP RF_MainColShell absOff 178px 192px", pval(main, "absoluteSizeOffset") == "178px 192px")

sidebg = profs.get("RF_SideColBg")
check("KEEP RF_SideColBg swatch profile intact (nil-safe, no longer extended)",
      pval(sidebg, "filename") == "$dataS/menu/blank.png"
      and pval(sidebg, "imageColor") == "0.165 0.176 0.157 0.92")

items = [el for el in gtree.getroot().iter("ListItem")]
crop_icons = []
for it in items:
    crop_icons += [b for b in it.iter("Bitmap") if b.get("name") == "cropIcon"]
check("KEEP cropIcon cell in commodity ListItem", len(crop_icons) == 1)
name_cells = find_by_name(gtree, "mdCropRowName")
check("KEEP mdCropRowName 38px indent",
      len(name_cells) == 1 and name_cells[0].get("position") == "38px 0px")
crop_hdr = find_by_id(gtree, "mdColCrop")
check("KEEP mdColCrop header at 54px", crop_hdr is not None and crop_hdr.get("position") == "54px -8px")

mdshell = profs.get("RF_MdTableRegionShell")
check("KEEP RF_MdTableRegionShell absOff 0px 388px", pval(mdshell, "absoluteSizeOffset") == "0px 388px")
mdregion = find_by_id(gtree, "mdTableRegion")
check("KEEP mdTableRegion inline absOff 0px 388px",
      mdregion is not None and mdregion.get("absoluteSizeOffset") == "0px 388px")

blurb = find_by_id(gtree, "rfPageBlurb")
check("KEEP blurb at 40px -24px", blurb is not None and blurb.get("position") == "40px -24px")

for pname in ("RF_PanelContentShell", "RF_HostPlaceholderShell"):
    pr = profs.get(pname)
    check(f"KEEP {pname} -52/36", pval(pr, "position") == "0px -52px"
          and pval(pr, "absoluteSizeOffset") == "0px 36px")

check("KEEP RF_TableRegionShell absOff 0px 392px",
      pval(profs.get("RF_TableRegionShell"), "absoluteSizeOffset") == "0px 392px")
check("KEEP RF_TreatmentStrip height 384px",
      pval(profs.get("RF_TreatmentStrip"), "height") == "384px")

csregion = find_by_id(gtree, "rfHostTableRegion")
check("KEEP CS host region 0px 0px / absOff 0px 404px",
      csregion is not None and csregion.get("position") == "0px 0px"
      and csregion.get("absoluteSizeOffset") == "0px 404px")

sliders = [el for el in gtree.getroot().iter("Slider")]
check("KEEP hideParentWhenEmpty on all 4 Sliders",
      len(sliders) == 4 and all(s.get("hideParentWhenEmpty") == "true" for s in sliders))

for el_id, pos in [("mdDetailCommodity", "770px -32px"), ("mdDetailPrice", "770px -64px"),
                   ("mdDetailPressure", "770px -92px"), ("mdDetailEmpty", "770px -64px"),
                   ("mdOpenMarketBtn", "770px -280px"), ("mdOpenMarketBtnEvents", "770px -280px"),
                   ("mdOpenMarketBtnContracts", "770px -280px")]:
    el = find_by_id(gtree, el_id)
    check(f"KEEP {el_id} at {pos}", el is not None and el.get("position") == pos)

check("KEEP soilColPH header", find_by_id(gtree, "soilColPH") is not None)
check("KEEP fieldRowPH cell", len(find_by_name(gtree, "fieldRowPH")) == 1)

for wc_id in ("wcPageDashboard", "wcPageWages", "wcPageWorkers", "wcPageAbout"):
    check(f"KEEP WC page {wc_id}", find_by_id(gtree, wc_id) is not None)

nestbg = profs.get("RF_SubCategoryContainerBg")
check("KEEP nest Bg profile width-only 404px (texture untouched, hidden via XML attr)",
      pval(nestbg, "width") == "404px" and pval(nestbg, "filename") is None
      and pval(nestbg, "imageColor") is None)

# ---- report ----
print(f"PASS {len(passes)} / FAIL {len(failures)}")
for f in failures:
    print(f"  FAIL: {f}")
sys.exit(1 if failures else 0)
