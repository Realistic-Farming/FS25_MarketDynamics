#!/usr/bin/env python3
"""BUILD 15:39 / PB-07 - price units and graph context strings.

Every key here is read through MDMUtil.getModText, which rejects the engine's
"Missing '<key>'" placeholder and falls back to the English literal in the Lua.
So none of these are load-bearing the way PB-08's XML-referenced key is - but
shipping them means 25 of 26 languages do not silently fall back to English on a
player surface.

  mdm_screen_per_head        unit suffix for livestock rows (priced per animal)
  mdm_screen_per_1000l       unit suffix for litre rows
  mdm_screen_price_trend     graph title when no commodity is selected
  mdm_screen_graph_oldest    x-axis left end
  mdm_screen_graph_newest    x-axis right end
  mdm_screen_graph_span      x-axis centre, "%d samples" (keep the %d)
  mdm_screen_graph_median    graph title for the all-commodities median series

Files are decoded utf-8-sig and written back as plain UTF-8 with no BOM.
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

ORDER = ("mdm_screen_per_head", "mdm_screen_per_1000l", "mdm_screen_price_trend",
         "mdm_screen_graph_oldest", "mdm_screen_graph_newest",
         "mdm_screen_graph_span", "mdm_screen_graph_median")

EN = ["/ head", "/ 1,000L", "Price trend", "oldest", "now", "%d samples",
      "All commodities (median)"]

TEXTS = {
    "de": ["/ Tier", "/ 1.000 l", "Preisverlauf", "älteste", "jetzt", "%d Messwerte", "Alle Waren (Median)"],
    "fr": ["/ tête", "/ 1 000 L", "Tendance des prix", "plus ancien", "maintenant", "%d relevés", "Toutes les marchandises (médiane)"],
    "es": ["/ cabeza", "/ 1.000 L", "Tendencia de precios", "más antiguo", "ahora", "%d muestras", "Todas las mercancías (mediana)"],
    "ea": ["/ cabeza", "/ 1.000 L", "Tendencia de precios", "más antiguo", "ahora", "%d muestras", "Todas las mercancías (mediana)"],
    "it": ["/ capo", "/ 1.000 L", "Andamento prezzi", "meno recente", "ora", "%d campioni", "Tutte le merci (mediana)"],
    "nl": ["/ dier", "/ 1.000 L", "Prijsverloop", "oudste", "nu", "%d metingen", "Alle goederen (mediaan)"],
    "pl": ["/ szt.", "/ 1000 l", "Trend cen", "najstarsze", "teraz", "%d próbek", "Wszystkie towary (mediana)"],
    "pt": ["/ cabeça", "/ 1.000 L", "Tendência de preços", "mais antigo", "agora", "%d amostras", "Todas as mercadorias (mediana)"],
    "br": ["/ cabeça", "/ 1.000 L", "Tendência de preços", "mais antigo", "agora", "%d amostras", "Todas as mercadorias (mediana)"],
    "ru": ["/ голову", "/ 1 000 л", "Динамика цен", "ранее", "сейчас", "%d замеров", "Все товары (медиана)"],
    "uk": ["/ голову", "/ 1 000 л", "Динаміка цін", "раніше", "зараз", "%d замірів", "Усі товари (медіана)"],
    "cz": ["/ kus", "/ 1 000 l", "Vývoj cen", "nejstarší", "nyní", "%d vzorků", "Všechny komodity (medián)"],
    "da": ["/ dyr", "/ 1.000 L", "Prisudvikling", "ældste", "nu", "%d målinger", "Alle varer (median)"],
    "no": ["/ dyr", "/ 1 000 L", "Prisutvikling", "eldste", "nå", "%d målinger", "Alle varer (median)"],
    "sv": ["/ djur", "/ 1 000 L", "Prisutveckling", "äldsta", "nu", "%d mätvärden", "Alla varor (median)"],
    "fi": ["/ eläin", "/ 1 000 l", "Hintakehitys", "vanhin", "nyt", "%d näytettä", "Kaikki tuotteet (mediaani)"],
    "hu": ["/ állat", "/ 1000 l", "Ártrend", "legrégebbi", "most", "%d minta", "Minden áru (medián)"],
    "ro": ["/ cap", "/ 1.000 L", "Tendința prețurilor", "cel mai vechi", "acum", "%d probe", "Toate mărfurile (mediană)"],
    "tr": ["/ baş", "/ 1.000 L", "Fiyat eğilimi", "en eski", "şimdi", "%d örnek", "Tüm ürünler (medyan)"],
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

    changed = 0
    for path in files:
        lang = path.stem.split("_", 1)[1]
        body = read(path)
        vals = TEXTS.get(lang, EN)

        entries = []
        for i, key in enumerate(ORDER):
            if 'name="%s"' % key in body:
                continue
            entries.append('        <text name="%s" text="%s" />' % (key, esc(vals[i])))

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
        for key in ORDER:
            n = body.count('name="%s"' % key)
            if n != 1:
                bad.append("%s: %s x%d" % (path.name, key, n))
        # The span string must keep its %d or string.format silently drops the count.
        m = re.search(r'name="mdm_screen_graph_span" text="([^"]*)"', body)
        if m and "%d" not in m.group(1):
            bad.append("%s: graph_span lost its %%d" % path.name)
    if bad:
        print("VERIFY FAILED:")
        for b in bad:
            print("  " + b)
        return 1
    print("verified: all %d keys present exactly once in all %d files" % (len(ORDER), len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
