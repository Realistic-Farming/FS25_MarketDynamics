// #170: every locale file's five money texts carry no fixed "$" and exactly the placeholders the code
// fills (src/gui/MDMContractDialog.lua, src/gui/MDMContractAdminDialog.lua): the two price texts one
// %s (a formatted amount) and no number specifier, which a formatted amount would make string.format
// raise on; the delivered text one %s and one %d; the two totals no placeholder (the amount is appended).
// Usage: node tools/test/currency-symbol-check.mjs   (exit 1 on any failure)
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DIR = join(ROOT, "translations");
const SHAPES = {
  mdm_current_price_fmt: { s: 1, d: 0 },
  mdm_locked_price_fmt: { s: 1, d: 0 },
  mdm_delivered_value: { s: 1, d: 1 },
  mdm_total_value: { s: 0, d: 0 },
  mdm_summary_total: { s: 0, d: 0 },
};
const files = readdirSync(DIR).filter((f) => /^translation_[a-z]{2}\.xml$/.test(f)).sort();
let fails = 0, checked = 0;
for (const f of files) {
  const text = readFileSync(join(DIR, f), "utf8");
  for (const [key, want] of Object.entries(SHAPES)) {
    const m = text.match(new RegExp(`name="${key}"[ \\t\\r\\n]+text="([^"]*)"`));
    if (!m) { console.log(`FAIL ${f} ${key}: missing`); fails++; continue; }
    const v = m[1];
    checked++;
    const specs = v.replace(/%%/g, "").match(/%[-+ #0]*\d*(?:\.\d+)?[a-zA-Z]/g) || [];
    const s = specs.filter((x) => x.endsWith("s")).length;
    const d = specs.filter((x) => x.endsWith("d")).length;
    const other = specs.filter((x) => !x.endsWith("s") && !x.endsWith("d"));
    if (v.includes("$")) { console.log(`FAIL ${f} ${key}: a fixed "$" in "${v}"`); fails++; }
    if (s !== want.s || d !== want.d || other.length) { console.log(`FAIL ${f} ${key}: placeholders ${JSON.stringify(specs)} in "${v}", want ${want.s} %s and ${want.d} %d`); fails++; }
  }
}
console.log(`${fails ? "FAIL" : "PASS"} - ${checked} money texts in ${files.length} locale files, ${fails} failed.`);
process.exit(fails ? 1 : 0);
