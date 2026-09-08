-- MarketEngine.lua
-- Manages per-fillType dynamic prices.
-- Tracks base prices, applies modifier stacks, handles intraday + daily volatility.
-- Maintains price history (last 7 in-game days) per fillType.
--
-- Price model per fillType:
--   current = base * volatilityFactor * product(eventModifiers)
--
--   base             — vanilla sell price, refreshed daily to track seasons
--   volatilityFactor — running intraday + daily drift, clamped to [0.50, 2.00]
--   modifiers        — event modifier stack: { id, fillTypeIndex, factor }
--                      added by WorldEvent.onFire, removed by WorldEvent.onExpire
--   current          — effective price returned to the game via PriceHook
--   history          — last HISTORY_MAX_ENTRIES daily price samples: { price, time }
--
-- Public API (called externally):
--   init()                                 — snapshot base prices from economy
--   update(dt)                             — advance intraday/daily timers
--   refreshBasePrices()                    — sync base prices with vanilla seasonal curves
--   addModifier(modifier)                  — push an event modifier onto the stack
--   removeModifierById(fillTypeIndex, id)  — pop a modifier by id
--   getPrice(fillTypeIndex)                — current effective price (or nil)
--   getPriceHistory(fillTypeIndex)         — array of { price, time } samples
--   getPriceChangePercent(fillTypeIndex)   — % change from base (positive = above)
--
-- Author: tison (dev-1)

MarketEngine = MarketEngine or {}
MarketEngine.__index = MarketEngine

-- Update intervals (ms of in-game time)
local INTRADAY_INTERVAL_MS = 60 * 1000       -- every in-game minute
local DAILY_INTERVAL_MS    = 24 * 60 * 60 * 1000  -- every in-game day (86,400,000 ms)

-- Volatility parameters
local INTRADAY_MAGNITUDE   = 0.020  -- ±2.0% per intraday tick
local DAILY_MAGNITUDE      = 0.015  -- ±1.5% per daily shift (realistic commodity range)
local INTRADAY_REVERSION   = 0.003  -- 0.3% pull toward 1.0 per tick
local DAILY_REVERSION      = 0.02   -- 2% pull toward 1.0 per day (gentle, allows trends to persist)
local VOLATILITY_MIN       = 0.50   -- hard floor: never less than 50% of base
local VOLATILITY_MAX       = 2.00   -- hard ceiling: never more than 200% of base

-- Price history
local HISTORY_MAX_ENTRIES  = 7      -- last 7 in-game days

function MarketEngine.new()
    local self = setmetatable({}, MarketEngine)

    -- { [fillTypeIndex] = { base, volatilityFactor, modifiers, current, history } }
    self.prices        = {}
    self.intradayTimer = 0
    self.dailyTimer    = 0

    -- Scales both intraday and daily drift magnitudes.
    -- 0.5 = Low, 1.0 = Normal (default), 1.5 = High, 2.0 = Extreme.
    -- Written directly by SettingsUI; serialized by MarketSerializer.
    self.volatilityScale = 1.0

    MDMLog.info("MarketEngine initialized")
    return self
end

-- Called once after mission load — snapshots base prices from the vanilla economy.
function MarketEngine:init()
    if not g_fillTypeManager then
        MDMLog.warn("MarketEngine:init() — g_fillTypeManager not available")
        return
    end
    self:refreshBasePrices(true)
    MDMLog.info("MarketEngine:init() — initialized fill type prices")
end

-- Sync base prices with current vanilla seasonal curves.
-- If isInitial is true, it populates the table; otherwise it just updates 'base'.
function MarketEngine:refreshBasePrices(isInitial)
    if not g_currentMission or not g_currentMission.economyManager then return end

    local fillTypes = g_fillTypeManager:getFillTypes()
    local count     = 0

    for _, fillType in ipairs(fillTypes) do
        if fillType and fillType.index and fillType.index > 1 then
            local basePrice = MDMGetVanillaPrice(g_currentMission.economyManager, fillType.index)
            if basePrice and basePrice > 0 then
                if isInitial and not self.prices[fillType.index] then
                    self.prices[fillType.index] = {
                        base             = basePrice,
                        volatilityFactor = 1.0,
                        modifiers        = {},
                        current          = basePrice,
                        history          = {},
                    }
                elseif self.prices[fillType.index] then
                    self.prices[fillType.index].base = basePrice
                    self:_recalculate(fillType.index)
                end
                count = count + 1
            end
        end
    end

    if isInitial then
        MDMLog.info("MarketEngine: snapshotted " .. count .. " base prices")
    end
end

-- Retired raw-dt timer path (MD-15 / RSF-F203). The coordinator no longer calls
-- this: economic work is admitted from the canonical monotonic clock via
-- applyHourlyMovement / appendDailyHistory / refreshBasePrices. Kept as an inert
-- no-op so any stale caller cannot reintroduce raw-dt accumulation.
function MarketEngine:update(dt)
    if g_server == nil then return end
    if not MarketEngine._rawDtPathWarned then
        MarketEngine._rawDtPathWarned = true
        MDMLog.warn("MarketEngine:update(dt) is retired — calendar admission drives prices (MD-15)")
    end
end

-- ---------------------------------------------------------------------------
-- Calendar path (MD-15 / RSF-F203)
-- ---------------------------------------------------------------------------

-- MD-15 quote equation. Pure arithmetic, shared by the hourly movement and the
-- production tests.
--
--   a = 2 ^ (-1 / 24)                       (24-hour deviation half-life)
--   gain(n) = sqrt((1 - a^(2n)) / (1 - a*a))
--   vNext = clamp(1 + (v - 1) * a^n + 0.02 * s * gain(n) * u, 0.50, 2.00)
--
-- v: stored volatility factor in [0.50, 2.00]; n: nonnegative integer count of
-- newly crossed farming hours; s: price-volatility scale >= 0; u: one uniform
-- signed sample in [-1,1] (or an RNG callback returning one). n == 0 preserves
-- the factor and draws nothing. Invalid input returns nil and preserves the
-- last valid state.
function MarketEngine.quoteStep(v, n, scale, u)
    local function finite(x)
        return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
    end
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
    local a    = 2 ^ (-1 / 24)
    local gain = math.sqrt((1 - a ^ (2 * n)) / (1 - a * a))
    local result = 1 + (v - 1) * a ^ n + 0.02 * scale * gain * u
    return math.max(0.5, math.min(2.0, result))
end

-- Apply one hourly quote step to every tracked fill type. nHours is the whole
-- count of newly crossed farming hours; a skipped interval computes the
-- equation once with one uniform draw per fill type (deliberate endpoint
-- approximation — no replay of the skipped interval). nHours == 0 is inert.
function MarketEngine:applyHourlyMovement(nHours, shockFn)
    if g_server == nil then return end
    if type(nHours) ~= "number" or nHours < 0 or nHours ~= math.floor(nHours) then
        MDMLog.warn("MarketEngine:applyHourlyMovement — invalid hour count rejected")
        return
    end
    if nHours == 0 then return end

    local scale = self.volatilityScale or 1.0
    for fillTypeIndex, entry in pairs(self.prices) do
        local u = shockFn and shockFn() or (math.random() * 2 - 1)
        local nextFactor = MarketEngine.quoteStep(entry.volatilityFactor, nHours, scale, u)
        if nextFactor then
            entry.volatilityFactor = nextFactor
            self:_recalculate(fillTypeIndex)
        end
    end
end

-- Append one actual endpoint-day price sample per fill type. Uses the existing
-- public timestamp convention: history.time = MDMUtil.getGameTime() at the
-- actual final observation. Private monotonic history-day state (coordinator)
-- controls duplicate admission; old samples are never relabelled.
function MarketEngine:appendDailyHistory()
    local now = MDMUtil.getGameTime()
    for fillTypeIndex, entry in pairs(self.prices) do
        table.insert(entry.history, { price = entry.current, time = now })
        if #entry.history > HISTORY_MAX_ENTRIES then
            table.remove(entry.history, 1)
        end
    end
end

-- Compose the final quote for every tracked fill type (server-side composition;
-- pure clients retain the authoritative received quote via _recalculate).
function MarketEngine:composeAll()
    for fillTypeIndex in pairs(self.prices) do
        self:_recalculate(fillTypeIndex)
    end
end

-- Request final quote publication through the coordinator's pending flags.
-- Pure clients cannot create authoritative mutations or outgoing quote work.
function MarketEngine:_requestQuotePublication()
    local mdm = g_MarketDynamics
    if mdm ~= nil and type(mdm.requestQuotePublication) == "function" then
        mdm:requestQuotePublication()
    end
end

-- Push an event modifier onto a fillType's modifier stack.
-- Requests final quote publication for every successful server stack mutation
-- (RSF-F203: the common add/remove methods are the single request path for all
-- server writers, including BC, RWE/SCS, event config and forced actions).
function MarketEngine:addModifier(modifier)
    local entry = self.prices[modifier.fillTypeIndex]
    if not entry then return end

    table.insert(entry.modifiers, modifier)
    self:_recalculate(modifier.fillTypeIndex)
    self:_requestQuotePublication()
end

-- Remove a modifier by id from a fillType's modifier stack.
-- A removal that removes nothing does not mark work.
function MarketEngine:removeModifierById(fillTypeIndex, id)
    local entry = self.prices[fillTypeIndex]
    if not entry then return end

    local removed = false
    for i = #entry.modifiers, 1, -1 do
        if entry.modifiers[i].id == id then
            table.remove(entry.modifiers, i)
            removed = true
        end
    end
    if removed then
        self:_recalculate(fillTypeIndex)
        self:_requestQuotePublication()
    end
end

-- Returns the current effective price for a fillType, or nil if not tracked.
function MarketEngine:getPrice(fillTypeIndex)
    local entry = self.prices[fillTypeIndex]
    if entry then return entry.current end
    return nil
end

-- Returns price history array for GUI display.
function MarketEngine:getPriceHistory(fillTypeIndex)
    local entry = self.prices[fillTypeIndex]
    if entry then return entry.history end
    return {}
end

-- Remove price entries for fill type indices that no longer exist in g_fillTypeManager.
-- Called after save-game load to purge stale data left by removed third-party mods.
function MarketEngine:cleanupStaleEntries()
    if not g_fillTypeManager then return end

    local validIndices = {}
    for _, ft in ipairs(g_fillTypeManager:getFillTypes()) do
        if ft and ft.index then validIndices[ft.index] = true end
    end

    local removed = 0
    for index in pairs(self.prices) do
        if not validIndices[index] then
            self.prices[index] = nil
            removed = removed + 1
            MDMLog.warn(string.format(
                "MarketEngine: purged stale price entry for fill type index %d (fill type no longer exists)",
                index))
        end
    end

    if removed > 0 then
        MDMLog.info(string.format("MarketEngine: cleaned %d stale price entry(s)", removed))
    end
end

-- Returns the percentage change of the current price relative to the base price.
function MarketEngine:getPriceChangePercent(fillTypeIndex)
    local entry = self.prices[fillTypeIndex]
    if not entry or entry.base <= 0 then return 0 end
    return (entry.current - entry.base) / entry.base * 100
end

-- ---------------------------------------------------------------------------
-- Private
-- ---------------------------------------------------------------------------

-- Small random walk + mean reversion toward 1.0 (dampened).
function MarketEngine:_applyIntradayVolatility()
    local scale     = self.volatilityScale or 1.0
    local magnitude = INTRADAY_MAGNITUDE * scale
    local reversion = INTRADAY_REVERSION

    for fillTypeIndex, entry in pairs(self.prices) do
        local vf = entry.volatilityFactor
        -- Pull toward 1.0 (mean reversion)
        local revDelta  = (1.0 - vf) * reversion
        -- Random jitter
        local randDelta = (math.random() * 2 - 1) * magnitude
        
        local newFactor = vf + revDelta + randDelta
        entry.volatilityFactor = math.max(VOLATILITY_MIN, math.min(VOLATILITY_MAX, newFactor))
        self:_recalculate(fillTypeIndex)
    end
end

-- Daily shift: mean-reversion toward 1.0 + random trend (±3% scaled).
function MarketEngine:_applyDailyShift()
    local now            = MDMUtil.getGameTime()
    local scale          = self.volatilityScale or 1.0
    local dailyMagnitude = DAILY_MAGNITUDE * scale
    local dailyReversion = DAILY_REVERSION

    for fillTypeIndex, entry in pairs(self.prices) do
        local vf = entry.volatilityFactor
        -- Stronger daily pull toward equilibrium
        local reversion = (1.0 - vf) * dailyReversion
        -- Daily market trend
        local trend     = (math.random() * 2 - 1) * dailyMagnitude
        
        local newFactor = vf + reversion + trend
        entry.volatilityFactor = math.max(VOLATILITY_MIN, math.min(VOLATILITY_MAX, newFactor))
        self:_recalculate(fillTypeIndex)

        -- Record daily price snapshot for GUI history chart
        table.insert(entry.history, { price = entry.current, time = now })
        if #entry.history > HISTORY_MAX_ENTRIES then
            table.remove(entry.history, 1)
        end
    end
end

-- Recompute current = base * volatilityFactor * product(all event modifier factors).
-- On a pure client the received authoritative quote is retained: local modifier
-- callbacks, seasonal reads and later RWE/SCS polling must not overwrite it
-- (RSF-F203). Server-side composition is unchanged.
function MarketEngine:_recalculate(fillTypeIndex)
    local entry = self.prices[fillTypeIndex]
    if not entry then return end

    if g_server == nil and entry.current ~= nil then
        return entry.current
    end

    local factor = entry.volatilityFactor
    for _, mod in ipairs(entry.modifiers) do
        factor = factor * mod.factor
    end
    local currentPrice = entry.base * factor

    -- Consumer composition: product of all registered modifier multipliers
    if g_MarketDynamics and g_MarketDynamics.priceModifiers then
        local consumerMult = 1.0
        for name, fn in pairs(g_MarketDynamics.priceModifiers) do
            local ok, mult = pcall(fn, {
                fillTypeIndex = fillTypeIndex,
                basePrice = entry.base,
                marketPrice = currentPrice,
            })
            if ok and type(mult) == "number" and mult > 0 then
                consumerMult = consumerMult * mult
            end
        end
        -- Clamp B: consumer composition band (ruled 0.5-3.0, authority #3)
        consumerMult = math.max(0.5, math.min(3.0, consumerMult))
        currentPrice = currentPrice * consumerMult
    end

    entry.current = currentPrice
end
