#!/usr/bin/env python3
"""BUILD 15:39 / PB-08 - player language in place of raw internal identifiers.

Adds the keys the Event Settings dialog needs once the raw TRACKED FILL TYPES
token list is replaced by plain tracked categories:

  mdm_evt_tracked_label   section heading (was a hardcoded English literal in the
                          XML, so this one is REQUIRED: $l10n_ renders
                          "Missing '<key>'" when the key is absent)
  mdm_cat_crops           category labels; the Lua guards these with hasText, so
  mdm_cat_silage          they are additive and safe, but they are shipped in
  mdm_cat_livestock       every language anyway rather than falling back to
  mdm_cat_other           English on 25 of 26 surfaces

Languages without a hand-written translation take English rather than a
machine-mangled sentence. These are single nouns, so coverage is wide.

Files are decoded utf-8-sig and written back as plain UTF-8 with no BOM.
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

KEYS = ("mdm_evt_tracked_label", "mdm_cat_crops", "mdm_cat_silage",
        "mdm_cat_livestock", "mdm_cat_other")

EN = {
    "mdm_evt_tracked_label": "Tracked market categories",
    "mdm_cat_crops": "Crops",
    "mdm_cat_silage": "Silage",
    "mdm_cat_livestock": "Livestock",
    "mdm_cat_other": "Other",
}

TEXTS = {
    "de": ["Erfasste Marktkategorien", "Feldfrüchte", "Silage", "Tierhaltung", "Sonstige"],
    "fr": ["Catégories de marché suivies", "Cultures", "Ensilage", "Élevage", "Autres"],
    "es": ["Categorías de mercado seguidas", "Cultivos", "Ensilado", "Ganado", "Otros"],
    "ea": ["Categorías de mercado seguidas", "Cultivos", "Ensilado", "Ganado", "Otros"],
    "it": ["Categorie di mercato monitorate", "Colture", "Insilato", "Bestiame", "Altro"],
    "nl": ["Gevolgde marktcategorieën", "Gewassen", "Kuilvoer", "Vee", "Overig"],
    "pl": ["Śledzone kategorie rynku", "Uprawy", "Kiszonka", "Zwierzęta", "Inne"],
    "pt": ["Categorias de mercado seguidas", "Culturas", "Silagem", "Gado", "Outros"],
    "br": ["Categorias de mercado monitoradas", "Culturas", "Silagem", "Gado", "Outros"],
    "ru": ["Отслеживаемые категории рынка", "Культуры", "Силос", "Скот", "Прочее"],
    "uk": ["Відстежувані категорії ринку", "Культури", "Силос", "Худоба", "Інше"],
    "cz": ["Sledované kategorie trhu", "Plodiny", "Siláž", "Dobytek", "Ostatní"],
    "da": ["Fulgte markedskategorier", "Afgrøder", "Ensilage", "Husdyr", "Andet"],
    "no": ["Fulgte markedskategorier", "Vekster", "Silo", "Husdyr", "Annet"],
    "sv": ["Följda marknadskategorier", "Grödor", "Ensilage", "Boskap", "Övrigt"],
    "fi": ["Seuratut markkinaluokat", "Viljelykasvit", "Säilörehu", "Karja", "Muut"],
    "hu": ["Követett piaci kategóriák", "Növények", "Szilázs", "Állatok", "Egyéb"],
    "ro": ["Categorii de piață urmărite", "Culturi", "Siloz", "Animale", "Altele"],
    "tr": ["İzlenen pazar kategorileri", "Ürünler", "Silaj", "Hayvancılık", "Diğer"],
}


def read(path):
    return path.read_bytes().decode("utf-8-sig")


def write(path, text):
    path.write_bytes(text.encode("utf-8"))


def esc(v):
    return v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    files = sorted(HERE.glob("translation_*.xml"))
    if not files:
        print("no translation_*.xml found")
        return 1

    # Match the file's own indentation for the entries we insert.
    changed = 0
    for path in files:
        lang = path.stem.split("_", 1)[1]
        body = read(path)
        vals = TEXTS.get(lang)

        entries = []
        for i, key in enumerate(KEYS):
            if 'name="%s"' % key in body:
                continue
            value = vals[i] if vals else EN[key]
            entries.append('        <text name="%s" text="%s" />' % (key, esc(value)))

        if not entries:
            continue

        block = "\n".join(entries) + "\n"
        new = re.sub(r"([ \t]*)</texts>", block + r"\1</texts>", body, count=1)
        if new == body:
            print("could not find </texts> in %s" % path.name)
            return 1
        write(path, new)
        changed += 1

    print("patched %d of %d translation file(s)" % (changed, len(files)))

    bad = []
    for path in files:
        body = read(path)
        for key in KEYS:
            n = body.count('name="%s"' % key)
            if n != 1:
                bad.append("%s: %s x%d" % (path.name, key, n))
    if bad:
        print("VERIFY FAILED:")
        for b in bad:
            print("  " + b)
        return 1
    print("verified: all %d keys present exactly once in all %d files" % (len(KEYS), len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
