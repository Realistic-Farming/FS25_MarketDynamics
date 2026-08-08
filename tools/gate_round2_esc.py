#!/usr/bin/env python3
"""Round 2 Esc chrome assertion gate (2026-08-04).

Parses xml/gui/rfEscProfiles.xml + xml/gui/RfPdaMenuPage.xml and asserts:
  D1 pane pivot swap, D2 side column underlay, D3 card centring, D4 graph pair nudge,
  plus the full keep list from George's ENGINE note.
Exit 0 = all pass. Non-zero = at least one FAIL (listed).
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROFILES = ROOT / "xml" / "gui" / "rfEscProfiles.xml"
PAGE = ROOT / "xml" / "gui" / "RfPdaMenuPage.xml"

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
    """Value of a <key value='...'/> child of a Profile, or None."""
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

# ---- D1: pane pivot swap ----
main = profs.get("RF_MainColShell")
check("D1 RF_MainColShell exists", main is not None)
check("D1 with = anchorStretchingYLeft pivotBottomLeft",
      main is not None and main.get("with") == "anchorStretchingYLeft pivotBottomLeft")
check("D1 position 404px 40px unchanged", pval(main, "position") == "404px 40px")
check("D1 absOff 178px 192px unchanged", pval(main, "absoluteSizeOffset") == "178px 192px")

# ---- D2: side column underlay ----
under = profs.get("RF_SideColUnderlay")
check("D2 RF_SideColUnderlay exists", under is not None)
check("D2 extends RF_SideColBg", under is not None and under.get("extends") == "RF_SideColBg")
check("D2 with anchorStretchingYLeft", under is not None and under.get("with") == "anchorStretchingYLeft")
check("D2 width 404px", pval(under, "width") == "404px")
sidebg = profs.get("RF_SideColBg")
check("D2 parent RF_SideColBg blank.png", pval(sidebg, "filename") == "$dataS/menu/blank.png")
check("D2 parent RF_SideColBg swatch 0.165 0.176 0.157 0.92",
      pval(sidebg, "imageColor") == "0.165 0.176 0.157 0.92")

host = find_by_id(gtree, "rfContentHost")
check("D2 rfContentHost exists", host is not None)
kids = list(host) if host is not None else []
check("D2 underlay Bitmap is FIRST child of rfContentHost",
      len(kids) > 0 and kids[0].tag == "Bitmap" and kids[0].get("profile") == "RF_SideColUnderlay")
check("D2 underlay painted before ThreePartBitmap nest",
      len(kids) > 1 and kids[1].tag == "ThreePartBitmap"
      and kids[1].get("profile") == "RF_SubCategoryContainerBg")

# ---- D3: card centring ----
wcshell = profs.get("RF_WcSideInfoShell")
check("D3 RF_WcSideInfoShell position 0px -367px", pval(wcshell, "position") == "0px -367px")
check("D3 RF_WcSideInfoShell size 380px 240px held", pval(wcshell, "size") == "380px 240px")
mdcard = find_by_id(gtree, "mdSideInfoShell")
check("D3 mdSideInfoShell exists", mdcard is not None)
check("D3 mdSideInfoShell inline position REMOVED",
      mdcard is not None and mdcard.get("position") is None)
check("D3 mdSideInfoShell keeps RF_WcSideInfoShell profile",
      mdcard is not None and mdcard.get("profile") == "RF_WcSideInfoShell")
wccard = find_by_id(gtree, "wcSideInfoShell")
check("D3 wcSideInfoShell has no inline position (shares profile)",
      wccard is not None and wccard.get("position") is None)

# ---- D4: graph pair nudge ----
graph = profs.get("RF_MdGraphArea")
check("D4 RF_MdGraphArea position 30px -28px (X nudged, Y HELD)",
      pval(graph, "position") == "30px -28px")
check("D4 RF_MdGraphArea size 720px 200px held", pval(graph, "size") == "720px 200px")
hint = find_by_id(gtree, "mdGraphEmptyHint")
check("D4 mdGraphEmptyHint x 30", hint is not None and hint.get("position") == "30px -96px")
for el_id, pos in [("mdDetailCommodity", "770px -32px"), ("mdDetailPrice", "770px -64px"),
                   ("mdDetailPressure", "770px -92px"), ("mdDetailEmpty", "770px -64px"),
                   ("mdOpenMarketBtn", "770px -280px"), ("mdOpenMarketBtnEvents", "770px -280px"),
                   ("mdOpenMarketBtnContracts", "770px -280px")]:
    el = find_by_id(gtree, el_id)
    check(f"D4 {el_id} at {pos}", el is not None and el.get("position") == pos)

# ---- Keeps ----
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

nestbg = profs.get("RF_SubCategoryContainerBg")
check("KEEP nest Bg width-only 404px", pval(nestbg, "width") == "404px")
check("KEEP nest Bg vanilla texture (no filename/imageColor override)",
      nestbg is not None and pval(nestbg, "filename") is None and pval(nestbg, "imageColor") is None)

sliders = [el for el in gtree.getroot().iter("Slider")]
check("KEEP hideParentWhenEmpty on all 4 Sliders",
      len(sliders) == 4 and all(s.get("hideParentWhenEmpty") == "true" for s in sliders))

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

arrows = [el for el in gtree.getroot().iter("Bitmap")
          if el.get("profile") == "fs25_subCategoryContainerArrow"]
check("KEEP nest arrow visible=false",
      len(arrows) == 1 and arrows[0].get("visible") == "false")

check("KEEP soilColPH header", find_by_id(gtree, "soilColPH") is not None)
check("KEEP fieldRowPH cell", len(find_by_name(gtree, "fieldRowPH")) == 1)

for wc_id in ("wcPageDashboard", "wcPageWages", "wcPageWorkers", "wcPageAbout"):
    check(f"KEEP WC page {wc_id}", find_by_id(gtree, wc_id) is not None)

# ---- report ----
print(f"PASS {len(passes)} / FAIL {len(failures)}")
for f in failures:
    print(f"  FAIL: {f}")
sys.exit(1 if failures else 0)
