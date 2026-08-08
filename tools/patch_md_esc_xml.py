# -*- coding: utf-8 -*-
"""Insert MDM Esc RF PDA zone twins into RfPdaMenuPage.xml carriers."""
from pathlib import Path

BLOCK = """
                    <!-- MDM Market Dynamics glance: graph region + detail strip (GuiElement; no SmoothList primary). -->
                    <GuiElement profile="RF_TableRegionShell" id="mdGraphRegion" position="0px -90px"
                                absoluteSizeOffset="0px 434px" visible="false">
                        <Text profile="RF_SectionTitle" id="mdGraphTitle" position="16px -8px" size="700px 24px" text=""/>
                        <GuiElement id="mdGraphArea" position="16px -40px" size="700px 260px"/>
                        <Text profile="RF_EmptyHint" id="mdGraphEmptyHint" position="16px -120px" size="700px 40px"
                              visible="false" text=""/>
                        <Text profile="RF_ColHeader" id="mdMoversLabel" position="740px -8px" size="380px 24px" text=""/>
                        <MultiTextOption profile="RF_MultiTextOption" id="mdMoverSelector"
                                         position="740px -40px" size="380px 36px"
                                         disableButtonsOnSingleText="false"
                                         onClick="onClickMdMoverSelector"/>
                        <Text profile="RF_HintText" id="mdEventsBand" position="16px -320px" size="1100px 72px"
                              textMaxNumLines="4" textVerticalAlignment="top" text=""/>
                        <Button profile="buttonText" id="mdOpenMarketBtn" position="740px -280px" size="380px 36px"
                                onClick="onClickMdOpenMarket"/>
                    </GuiElement>

                    <GuiElement profile="RF_TreatmentStrip" id="mdDetailStrip" visible="false">
                        <Bitmap profile="RF_TreatmentBoxBg"/>
                        <Text profile="RF_SectionTitle" id="mdDetailTitle" position="10px -6px" size="700px 24px" text=""/>
                        <Text profile="RF_TreatSelected" id="mdDetailCommodity" position="10px -52px" size="900px 22px"
                              textAlignment="left" text=""/>
                        <Text profile="RF_TreatTargetLine" id="mdDetailPrice" position="10px -88px" size="900px 20px" text=""/>
                        <Text profile="RF_TreatTargetLine" id="mdDetailPressure" position="10px -112px" size="900px 20px" text=""/>
                        <Text profile="RF_TreatTargetLine" id="mdDetailContracts" position="10px -136px" size="900px 20px" text=""/>
                        <Text profile="RF_HintText" id="mdDetailEmpty" position="10px -52px" size="1000px 44px"
                              textMaxNumLines="2" visible="false" text=""/>
                    </GuiElement>
"""

TARGETS = [
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_MarketDynamics\xml\gui\RfPdaMenuPage.xml"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SoilFertilizer\xml\gui\RfPdaMenuPage.xml"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_SeasonalCropStress\xml\gui\RfPdaMenuPage.xml"),
    Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_WorkerCosts\xml\gui\RfPdaMenuPage.xml"),
]

WC_SRC = Path(r"C:\Users\Graham\Documents\Realistic-Farming\FS25_WorkerCosts\xml\gui\RfPdaMenuPage.xml")


def patch(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    if 'id="mdGraphRegion"' in text:
        return f"SKIP {path.name} @ {path.parent.parent.parent.name} (already has)"
    marker = 'id="csDetailEmpty"'
    i = text.find(marker)
    if i < 0:
        return f"FAIL {path} (csDetailEmpty missing)"
    close = text.find("</GuiElement>", i)
    if close < 0:
        return f"FAIL {path} (close missing)"
    insert_at = close + len("</GuiElement>")
    text = text[:insert_at] + "\n" + BLOCK + text[insert_at:]
    path.write_text(text, encoding="utf-8")
    return f"OK {path.parent.parent.parent.name}/{path.name}"


def main():
    mdm = TARGETS[0]
    mdm.write_text(WC_SRC.read_text(encoding="utf-8"), encoding="utf-8")
    print("restored MDM XML from WC")
    for p in TARGETS:
        print(patch(p))


if __name__ == "__main__":
    main()
