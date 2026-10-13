// Mutant battery for MAINTENANCE row 303 (the incumbent's daily work on the game's day change).
// Usage: node tools/test/mutate_maint303.cjs   (run from anywhere; restores every file)
// Each mutant is applied alone, proved to have landed (hash), run against the suite,
// and the file restored and hash-checked. KILLED = MAINT-303 shows a failure or an error.
const fs = require("fs"), cp = require("child_process"), crypto = require("crypto"), path = require("path");
const repo = process.argv[2] || path.resolve(__dirname, "../..");
const h = (s) => crypto.createHash("sha1").update(s).digest("hex").slice(0, 12);

const MD = "src/MarketDynamics.lua", ME = "src/MarketEngine.lua";
const mutants = [
  ["M1 the latch never subscribes", MD,
    "    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self._onIncumbentDayChanged, self)\n", "\n"],
  ["M2 the latch subscribes again on every start", MD,
    "    if self._incumbentDayLatched then return end\n", "\n"],
  ["M3 delete passes unsubscribe's arguments in the old order", MD,
    "g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self, self._onIncumbentDayChanged)",
    "g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self._onIncumbentDayChanged, self)"],
  ["M4 the handler ignores the load phase", MD,
    "    if g_server == nil or self._loadPhase or not self.isActive then return end\n    if self.economicModel ~= \"incumbent\" then return end\n    self.marketEngine:onDayChanged()",
    "    if g_server == nil or not self.isActive then return end\n    if self.economicModel ~= \"incumbent\" then return end\n    self.marketEngine:onDayChanged()"],
  ["M5 the handler ignores an inactive coordinator", MD,
    "    if g_server == nil or self._loadPhase or not self.isActive then return end\n    if self.economicModel ~= \"incumbent\" then return end\n    self.marketEngine:onDayChanged()",
    "    if g_server == nil or self._loadPhase then return end\n    if self.economicModel ~= \"incumbent\" then return end\n    self.marketEngine:onDayChanged()"],
  ["M6 the handler runs on a calendar session", MD,
    "    if self.economicModel ~= \"incumbent\" then return end\n    self.marketEngine:onDayChanged()",
    "    self.marketEngine:onDayChanged()"],
  ["M7 the handler skips the crop-stress check", MD,
    "    self.rweIntegration:onIncumbentDay()\n", "\n"],
  ["M8 the day change skips the base refresh", ME,
    "    self:_applyDailyShift()\n    self:refreshBasePrices(false) -- Sync with seasonal changes daily\n",
    "    self:_applyDailyShift()\n"],
  ["M9 the day change sends nothing", ME,
    "        -- A new daily sample: history included (RSF-F204).\n        MDMMarketSyncEvent.sendToClients(true)\n",
    "        -- A new daily sample: history included (RSF-F204).\n"],
  ["M10 raw dt fires the daily shift again", ME,
    "        self:_applyIntradayVolatility()\n",
    "        self:_applyIntradayVolatility()\n        if dt >= 86400000 then self:_applyDailyShift() end\n"],
];

let killed = 0, ran = 0;
const originals = {};
try {
  for (const [name, rel, rawFrom, rawTo] of mutants) {
    const file = path.join(repo, rel);
    const orig = originals[rel] || (originals[rel] = fs.readFileSync(file, "utf8"));
    const nl = orig.includes("\r\n") ? (x) => x.replace(/\r?\n/g, "\r\n") : (x) => x;
    const from = nl(rawFrom), to = nl(rawTo);
    const n = orig.split(from).length - 1;
    if (n !== 1) { console.log(`${name}: anchor found ${n} times, NOT RUN`); continue; }
    fs.writeFileSync(file, orig.replace(from, to));
    if (h(fs.readFileSync(file, "utf8")) === h(orig)) { console.log(`${name}: did not land, NOT RUN`); continue; }
    ran++;
    let out = "";
    try {
      out = cp.execSync("node run-tests.mjs", { cwd: path.join(repo, "tools/test"), encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) { out = (e.stdout || "") + (e.stderr || ""); }
    fs.writeFileSync(file, orig);
    if (h(fs.readFileSync(file, "utf8")) !== h(orig)) throw new Error(`restore failed for ${rel}`);
    const line = (out.match(/^.*MAINT-303.*$/m) || ["(no MAINT-303 line)"])[0].trim();
    const survived = /\(\d+ passed, 0 failed\)$/.test(line) && !/error/i.test(line);
    if (!survived) killed++;
    const rows = (out.match(/FAIL [A-E]\d+b?/g) || []).slice(0, 5).join(", ");
    console.log(`${name}: ${survived ? "SURVIVED" : "KILLED"} :: ${line}${rows ? " :: " + rows : ""}`);
  }
} finally {
  for (const [rel, text] of Object.entries(originals)) fs.writeFileSync(path.join(repo, rel), text);
  const ok = Object.entries(originals).every(([rel, text]) => h(fs.readFileSync(path.join(repo, rel), "utf8")) === h(text));
  console.log(`restored ${ok ? "OK" : "MISMATCH"}; killed ${killed} of ${ran} run, ${mutants.length} defined`);
}
