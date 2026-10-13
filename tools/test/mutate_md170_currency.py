# #170: targeted mutation battery for money written through the game's formatter, never a fixed "$".
# Each mutation breaks one part of the change, runs the bars (the Lua benches through run-tests.mjs,
# then tools/test/currency-symbol-check.mjs over every locale file), and expects a named FAIL; the file
# is restored byte-identical (sha256-checked) after each one. The bars must be green before any run.
#
# NOT RUN, and why:
#   - MDMHUD.money's pcall around formatMoney: a raising formatMoney is not a case any formatter here
#     produces; H2 pins the fallback when there is none;
#   - the developer log lines (MDMLog) that still write "$": not player-facing, left as they were;
#   - the comment lines.
# Usage: py -u tools/test/mutate_md170_currency.py [id-prefix ...]
import hashlib, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def one(old, new):
    def f(t):
        assert t.count(old) == 1, (old[:60], t.count(old))
        return t.replace(old, new, 1)
    return f

MUTATIONS = [
    ("C1-fixed-dollar-message", "src/FuturesMarket.lua", one("settled at locked price (+%s)", "settled at locked price (+$%s)"),
     "the fulfilled message writes '$' before the formatted amount again (N1, A2)"),
    ("C2-money-bypasses-formatter", "src/MDMHUD.lua",
     one("    if g_i18n ~= nil and type(g_i18n.formatMoney) == \"function\" then\n        local ok, s = pcall(",
         "    if false then\n        local ok, s = pcall("),
     "the HUD and the dialogs write a plain number, so a currency mod never converts it (H1, D2, A1)"),
    ("C3-dialog-raw-price", "src/gui/MDMContractDialog.lua",
     one("MDMHUD.money(crop.current * 1000)", "tostring(crop.current * 1000)"),
     "the contract dialog's current price skips the formatter (D2)"),
    ("C4-admin-raw-total", "src/gui/MDMContractAdminDialog.lua",
     one("self.admSumTotal:setText(lbl .. MDMHUD.money(totalValue))", "self.admSumTotal:setText(lbl .. self:_fmt(totalValue))"),
     "the admin dialog's total skips the formatter (A1)"),
    ("C5-locale-number-spec", "translations/translation_de.xml",
     one('name="mdm_locked_price_fmt" text="[EN] Locked price: %s / 1,000L"', 'name="mdm_locked_price_fmt" text="[EN] Locked price: %.0f / 1,000L"'),
     "a locale keeps a number specifier, which a formatted amount makes string.format raise on (the locale check)"),
    ("C6-locale-dollar", "translations/translation_fr.xml",
     one('name="mdm_summary_total" text="Total : "', 'name="mdm_summary_total" text="Total : $"'),
     "a locale keeps its fixed '$' (the locale check)"),
]

def sha(path):
    with open(path, "rb") as f: return hashlib.sha256(f.read()).hexdigest()
def run_bar():
    t = os.path.join(ROOT, "tools", "test")
    out, rc = [], 0
    for cmd in (["node", os.path.join(t, "run-tests.mjs")], ["node", os.path.join(t, "currency-symbol-check.mjs")]):
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", cwd=t)
        rc = rc or r.returncode
        out += (r.stdout + r.stderr).strip().splitlines()
    return rc, out

only = sys.argv[1:]
rc, out = run_bar()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in out[-8:]: print("   " + l)
    sys.exit(2)
print("baseline green")
killed = survived = bad = 0
for mid, rel, fn, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only): continue
    path = os.path.join(ROOT, rel)
    before = sha(path)
    raw = open(path, "rb").read()
    crlf = b"\r\n" in raw
    t = raw.decode("utf-8").replace("\r\n", "\n")
    try:
        t2 = fn(t)
    except AssertionError as e:
        print("  BAD EDIT %s (%s)" % (mid, e)); bad += 1; continue
    if t2 == t:
        print("  BAD EDIT %s (the edit changed nothing)" % mid); bad += 1; continue
    open(path, "wb").write((t2.replace("\n", "\r\n") if crlf else t2).encode("utf-8"))
    try:
        rc, out = run_bar()
    finally:
        open(path, "wb").write(raw)
        assert sha(path) == before, "restore failed for " + rel
    named = [l.strip() for l in out if l.strip().startswith("FAIL ") and not l.strip().startswith("FAIL -")]
    if rc != 0 and named:
        killed += 1
        print("  KILLED   %s  (%s)" % (mid, why))
        for l in named[:3]: print("        " + l[:200])
    elif rc != 0:
        bad += 1
        print("  CRASHED  %s: the bars failed without naming a case (not a kill)" % mid)
        for l in out[-4:]: print("        " + l)
    else:
        survived += 1
        print("  SURVIVED %s  (%s)" % (mid, why))
print("mutations: %d killed, %d survived, %d bad edit or crash" % (killed, survived, bad))
sys.exit(0 if survived == 0 and bad == 0 else 1)
