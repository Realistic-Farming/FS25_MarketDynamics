#!/usr/bin/env python3
"""Pack smoke for the deployed My Games zip (round 4 Esc chrome, 2026-08-05).

Checks: testzip clean; every modDesc sourceFile present; entry count; version 1.2.2.13;
chrome XML pair + src/gui/RfPdaMenuPage.lua byte-match the tree modulo line endings;
SHA256 + size. Optional argv[1] = zip path override (e.g. .zip.new when game locks).
"""

import hashlib
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ZIP = Path.home() / "Documents" / "My Games" / "FarmingSimulator2025" / "mods" / "FS25_MarketDynamics.zip"
ZIP = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ZIP

failures = []


def check(label, cond):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        failures.append(label)


print(f"INFO zip under test: {ZIP}")
zf = zipfile.ZipFile(ZIP)

bad = zf.testzip()
check("testzip clean", bad is None)

names = zf.namelist()
print(f"INFO zip entries: {len(names)}")
check("entry count ~93", 90 <= len(names) <= 96)

md = ET.fromstring(zf.read("modDesc.xml"))
version = md.find("version").text
print(f"INFO modDesc version in zip: {version}")
check("version 1.2.2.13", version == "1.2.2.13")

sources = [el.get("filename") for el in md.iter("sourceFile")]
print(f"INFO sourceFiles in modDesc: {len(sources)}")
check("48 sourceFiles", len(sources) == 48)
missing = [s for s in sources if s not in names]
check("all sourceFiles present in zip", not missing)
for m in missing:
    print(f"  MISSING: {m}")

for rel in ("xml/gui/rfEscProfiles.xml", "xml/gui/RfPdaMenuPage.xml",
            "src/gui/RfPdaMenuPage.lua", "modDesc.xml"):
    tree_bytes = (ROOT / rel).read_bytes().replace(b"\r\n", b"\n")
    zip_bytes = zf.read(rel).replace(b"\r\n", b"\n")
    check(f"zip matches tree (modulo EOL): {rel}", tree_bytes == zip_bytes)

data = ZIP.read_bytes()
print(f"INFO SHA256: {hashlib.sha256(data).hexdigest().upper()}")
print(f"INFO size: {len(data)} bytes")

print(f"RESULT: {'FAIL' if failures else 'PASS'} ({len(failures)} failures)")
sys.exit(1 if failures else 0)
