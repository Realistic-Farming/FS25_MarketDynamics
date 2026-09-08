--!load: src/MarketEngine.lua
-- MD-15 / RSF-F203: calendar paced quote specification.
--
-- Group A witnesses the repaired MarketEngine against its real source: the
-- raw-dt timer path is retired (update(dt) is inert, no timer accumulation, no
-- tick firing) and the calendar methods (applyHourlyMovement / appendDailyHistory)
-- are the only drivers. Groups B and C are reference contracts for the repair.
-- They model pure arithmetic/admission only; no game, network, save-file,
-- rendering, or performance behavior is proved here.

MDMLog = { info=function() end, warn=function() end, debug=function() end, error=function() end }
MDMUtil = { getGameTime=function() return 0 end }
MDMMarketSyncEvent = { sends=0, sendToClients=function() MDMMarketSyncEvent.sends = MDMMarketSyncEvent.sends + 1 end }
g_fillTypeManager = nil
g_currentMission = nil
g_server = nil

T.ok("A1 real MarketEngine.lua loads under the bench shim", type(MarketEngine) == "table")
if type(MarketEngine) ~= "table" then return end

local function freshEngine()
  local e = MarketEngine.new()
  e.prices[1] = { base=100, current=100, volatilityFactor=1, modifiers={}, history={} }
  e._applyIntradayVolatility = function(self) self._intradayCalls = (self._intradayCalls or 0) + 1 end
  e._applyDailyShift = function(self) self._dailyCalls = (self._dailyCalls or 0) + 1 end
  e._intradayCalls, e._dailyCalls = 0, 0
  return e
end

-- Group A: post-repair source witness. The raw-dt timer path is retired: the
-- coordinator drives economic work from the canonical monotonic clock, so
-- MarketEngine:update(dt) is inert and no raw-dt accumulation or tick firing
-- survives. The calendar methods are the only drivers.
do
  local e = freshEngine()
  g_server = nil
  e:update(60000)
  T.eq("A2 client update is server guarded", e._intradayCalls, 0)
  T.eq("A3 client update leaves the timer untouched", e.intradayTimer, 0)

  g_server = {}
  e:update(60000)
  T.eq("A4 raw dt no longer fires intraday ticks", e._intradayCalls, 0)
  T.eq("A5 raw dt no longer accumulates in the timer", e.intradayTimer, 0)
  e:update(86400000)
  T.eq("A6 a full raw day no longer fires daily ticks", e._dailyCalls, 0)
  T.eq("A7 raw dt no longer emits syncs", MDMMarketSyncEvent.sends, 0)

  -- Calendar admission drives: one crossed hour = one quote step.
  local c = freshEngine()
  g_server = {}
  c:applyHourlyMovement(1, function() return 0.5 end)
  T.near("A8 one crossed hour moves the quote by the equation", c.prices[1].current, 101, 1e-9)
  T.eq("A9 zero crossed hours is inert", c.prices[1].current, 101)
  c:applyHourlyMovement(1.5, function() return 0.5 end)
  T.eq("A10 non-integer hour count is rejected", c.prices[1].current, 101)
  c:applyHourlyMovement(0, function() return 0.5 end)
  T.eq("A11 zero-step consumes no shock draw", c.prices[1].current, 101)

  -- appendDailyHistory appends one endpoint sample per call.
  local d = freshEngine()
  d.prices[1].current = 123
  d:appendDailyHistory()
  T.eq("A12 appendDailyHistory records one endpoint sample", #d.prices[1].history, 1)
  T.eq("A13 the sample carries the current quote", d.prices[1].history[1].price, 123)
  d:appendDailyHistory()
  T.eq("A14 a second call appends a second sample", #d.prices[1].history, 2)
end

-- Group B: MD-15 quoteStep reference contract. This is deliberately not wired
-- into MarketEngine: it defines the temporal repair before implementation exists.
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end
local function quoteStep(v, n, scale, u)
  if not finite(v) or v < 0.5 or v > 2.0
      or not finite(n) or n < 0 or n ~= math.floor(n)
      or not finite(scale) or scale < 0 then
    return nil
  end
  if type(u) == "function" then
    if n == 0 then return v end
    u = u()
  end
  if not finite(u) or u < -1 or u > 1 then return nil end
  if n == 0 then return v end
  local a = 2 ^ (-1 / 24)
  local gain = math.sqrt((1 - a ^ (2 * n)) / (1 - a * a))
  local result = 1 + (v - 1) * a ^ n + 0.02 * scale * gain * u
  return math.max(0.5, math.min(2.0, result))
end

do
  local a = 2 ^ (-1 / 24)
  local one = quoteStep(1, 1, 1, 0)
  T.near("B1 one-hour zero shock follows the decay factor", one, 1, 1e-12)
  T.near("B2 one-hour deviation decays by a", quoteStep(1.4, 1, 1, 0), 1 + 0.4 * a, 1e-12)
  T.near("B3 24 hours halves deviation", quoteStep(1.8, 24, 1, 0), 1.4, 1e-12)
  T.near("B4 48 hours quarters deviation", quoteStep(1.8, 48, 1, 0), 1.2, 1e-12)
  T.near("B5 scale changes shock magnitude only", quoteStep(1, 1, 2, 1) - quoteStep(1, 1, 1, 1), 0.02, 1e-12)
  T.eq("B6 n zero returns the unchanged factor", quoteStep(1.37, 0, 4, 1), 1.37)
  T.eq("B7 invalid non-integer hour count is rejected", quoteStep(1, 1.5, 1, 0), nil)
  T.eq("B8 invalid shock is rejected", quoteStep(1, 1, 1, 1.1), nil)
  T.eq("B9 invalid factor is rejected", quoteStep("1", 1, 1, 0), nil)
  T.eq("B10 negative scale is rejected", quoteStep(1, 1, -1, 0), nil)
  T.eq("B11 NaN factor is rejected", quoteStep(0/0, 1, 1, 0), nil)
  T.eq("B12 infinite hour count is rejected", quoteStep(1, math.huge, 1, 0), nil)
  T.eq("B13 out-of-range factor is rejected", quoteStep(2.1, 0, 1, 0), nil)
  T.eq("B14 lower clamp is enforced", quoteStep(0.5, 1, 10, -1), 0.5)
  T.eq("B15 upper clamp is enforced", quoteStep(1.99, 1, 10, 1), 2.0)

  local function gainSquared(n)
    local sum, decay = 0, a * a
    for i = 0, n - 1 do sum = sum + decay ^ i end
    return sum
  end
  local g24 = (1 - a ^ (2 * 24)) / (1 - a * a)
  local g48 = (1 - a ^ (2 * 48)) / (1 - a * a)
  T.near("B16 24-hour shock gain equals its squared decay sum", g24, gainSquared(24), 1e-12)
  T.near("B17 48-hour shock gain equals its squared decay sum", g48, gainSquared(48), 1e-12)
  T.ok("B18 huge finite n remains finite and bounded", quoteStep(1, 1000000, 2, 1) <= 2 and quoteStep(1, 1000000, 2, 1) >= 0.5)
  T.near("B19 one reference result uses one supplied shock draw", quoteStep(1, 24, 1, 0.5), 1 + 0.02 * math.sqrt(g24) * 0.5, 1e-12)
  local draws = 0
  local function countedShock()
    draws = draws + 1
    return 0.5
  end
  quoteStep(1, 24, 1, countedShock)
  T.eq("B20 one current result consumes one shock draw", draws, 1)
  draws = 0
  T.eq("B21 zero-step keeps the factor with a supplied RNG callback", quoteStep(1, 0, 1, countedShock), 1)
  T.eq("B22 rejected scale returns nil before drawing", quoteStep(1, 1, -1, countedShock), nil)
  T.eq("B23 zero-step and rejected inputs consume no draw", draws, 0)
  local repeated = 1
  for _ = 1, 24 do repeated = quoteStep(repeated, 1, 1, 0.5) end
  T.ok("B24 aggregated path differs from a true 24-step hourly path", quoteStep(1, 24, 1, 0.5) ~= repeated)
  -- Matching the squared-weight sum is not full-distribution or path equivalence.
end

-- Group C: minimal reference admission. It uses monotonic calendar milliseconds,
-- a high-water observation, one crossed-hour quote endpoint, and one endpoint-day
-- snapshot. It is a model of the requested contract, not production code.
-- Its return value admits ORDINARY quote work only. False must not return from
-- the whole coordinator: F203's paired spec separately checks clock-offset and
-- actual stack-change publication at equal or earlier monotonic time.
local HOUR = 3600000
local function admission()
  return { lastObservedMs=nil, processedHour=nil, refreshDay=nil, lastHistoryDay=nil,
           quoteCalls=0, lastN=nil, refreshCalls=0, history={} }
end
local function observe(s, monotonicMs, isServer, loading, valid)
  if not isServer or loading or not valid or type(monotonicMs) ~= "number" then return false end
  if not finite(monotonicMs) or monotonicMs < 0 then return false end
  local h = math.floor(monotonicMs / HOUR)
  local day = math.floor(monotonicMs / (24 * HOUR))
  if s.lastObservedMs == nil then
    s.lastObservedMs, s.processedHour, s.refreshDay, s.lastHistoryDay = monotonicMs, h, day, day
    return false
  end
  if monotonicMs <= s.lastObservedMs then return false end
  s.lastObservedMs = math.max(s.lastObservedMs, monotonicMs)
  if h <= s.processedHour then return false end
  local n = h - s.processedHour
  s.processedHour, s.quoteCalls, s.lastN = h, s.quoteCalls + 1, n
  if day > s.refreshDay then
    s.refreshDay, s.refreshCalls = day, s.refreshCalls + 1
  end
  if day > s.lastHistoryDay then
    s.lastHistoryDay = day
    s.history[#s.history + 1] = { day=day, hour=h }
    if #s.history > 7 then table.remove(s.history, 1) end
  end
  return true
end

do
  local s = admission()
  T.ok("C1 first valid observation only anchors cursors", not observe(s, 18 * HOUR, true, false, true))
  T.eq("C2 first anchor has no quote work", s.quoteCalls, 0)
  T.eq("C3 first anchor has no history", #s.history, 0)
  T.ok("C4 same hour does not duplicate work", not observe(s, 18 * HOUR + HOUR - 1, true, false, true))
  T.ok("C5 older time does not duplicate work", not observe(s, 18 * HOUR, true, false, true))
  T.ok("C6 twelve-hour skip crosses midnight in one endpoint update", observe(s, 30 * HOUR, true, false, true))
  T.eq("C7 twelve-hour skip carries n=12", s.lastN, 12)
  T.eq("C8 twelve-hour skip records one endpoint-day snapshot", #s.history, 1)
  T.eq("C9 derived endpoint day advances from day zero to one", s.history[1].day, 1)
  T.eq("C10 twelve-hour skip performs one quote update", s.quoteCalls, 1)
  T.ok("C11 exact next hour resumes", observe(s, 31 * HOUR, true, false, true))
  T.eq("C12 exact next hour carries n=1", s.lastN, 1)
  T.ok("C13 duplicate callback at the same endpoint is inert", not observe(s, 31 * HOUR, true, false, true))

  local saved = { lastObservedMs=s.lastObservedMs, processedHour=s.processedHour,
                  refreshDay=s.refreshDay, lastHistoryDay=s.lastHistoryDay,
                  quoteCalls=s.quoteCalls, lastN=s.lastN, refreshCalls=s.refreshCalls, history=s.history }
  local copiedHistory = {}
  for i, row in ipairs(s.history) do copiedHistory[i] = { day=row.day, hour=row.hour } end
  saved.history = copiedHistory -- in-memory cursor copy, not actual serializer proof
  T.ok("C14 saved cursor roundtrip at the same hour is inert", not observe(saved, 31 * HOUR, true, false, true))
  T.ok("C15 backward then forward below old high-water is inert", not observe(saved, 25 * HOUR, true, false, true) and not observe(saved, 29 * HOUR, true, false, true))
  T.ok("C16 client guard makes no mutation", not observe(saved, 32 * HOUR, false, false, true))
  T.ok("C17 load guard makes no mutation", not observe(saved, 32 * HOUR, true, true, true))
  T.ok("C18 invalid environment guard makes no mutation", not observe(saved, 32 * HOUR, true, false, false))
  T.ok("C18a negative timestamp is rejected", not observe(saved, -1, true, false, true))
  T.ok("C18b NaN timestamp is rejected", not observe(saved, 0/0, true, false, true))
  T.ok("C18c infinite timestamp is rejected", not observe(saved, math.huge, true, false, true))
  T.eq("C18d invalid and unavailable observations retain high-water", saved.lastObservedMs, 31 * HOUR)
  T.ok("C18e first new hour after rewind resumes once", observe(saved, 32 * HOUR, true, false, true))
  T.eq("C18f resumed hour advances by one", saved.lastN, 1)

  local left, right = admission(), admission()
  observe(left, 18 * HOUR, true, false, true)
  observe(right, 18 * HOUR, true, false, true)
  observe(left, 18 * HOUR + 10 * 60 * 1000, true, false, true)
  observe(left, 19 * HOUR + 10 * 60 * 1000, true, false, true)
  observe(right, 18 * HOUR + 50 * 60 * 1000, true, false, true)
  observe(right, 19 * HOUR + 50 * 60 * 1000, true, false, true)
  T.eq("C19 different sub-hour partitions admit identical hourly endpoint counts", left.quoteCalls, right.quoteCalls)
  T.eq("C20 different sub-hour partitions end on the same processed hour", left.processedHour, right.processedHour)
  for d = 2, 9 do observe(saved, d * 24 * HOUR, true, false, true) end
  T.eq("C21 history retains exactly seven actual endpoint rows", #saved.history, 7)
  T.eq("C22 history retains the current endpoint day", saved.history[#saved.history].day, 9)
end

g_server = nil
T.summary()
