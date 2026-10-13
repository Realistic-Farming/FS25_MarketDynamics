-- MD-7a-aggregate_excludes_livestock_spec_test.lua - one axis can only carry one unit.
--
-- WHY THIS EXISTS. The aggregated median pooled every tracked commodity. A livestock ring holds
-- a price PER HEAD and a crop ring a price PER LITRE, and drawAggregatedMedian paints with no
-- perHead flag, so the painter multiplies the whole series by 1000. An animal worth twelve
-- thousand a head therefore entered a median beside wheat at well under a unit a litre, and was
-- then scaled. The per-commodity branch was always right, because selecting an animal draws its
-- own ring with perHead set; only the pooled one was wrong.
--
-- The bar starts where production starts: prices go in through seedFromHistory, the graph's own
-- recording path, and come out through drawAggregatedMedian, which is what the screen calls. The
-- series is captured at _drawLineChart, the last point before pixels.
--
-- What it locks:
--   a livestock buffer never reaches the aggregated series
--   the crop values arrive intact, so the exclusion is not just "draws nothing"
--   with crops alone the median is unchanged, and with livestock alone there is nothing to draw
--   the per-commodity path still draws livestock, which is the part that was never broken
--
--!load: src/gui/MarketScreenGraph.lua

-- drawAggregatedMedian asks MDMUtil for the median's label; the bench only needs it to answer.
MDMUtil = MDMUtil or {}
if type(MDMUtil.getModText) ~= "function" then
    MDMUtil.getModText = function(key) return key end
end

local CROP = 11         -- wheat, priced per litre
local LIVESTOCK = 42    -- a cow, priced per head

local CROP_PRICES = { 0.42, 0.55, 0.61, 0.48 }
local HEAD_PRICES = { 12000, 12500, 11800, 12100 }

local function history(prices)
    local h = {}
    for i, p in ipairs(prices) do h[i] = { price = p } end
    return h
end

--- The engine's answer to "is this index priced per head?". Production reaches it through
--- g_currentMission.animalSystem:getSubTypeByFillTypeIndex.
local function claimLivestock(indices)
    g_currentMission = g_currentMission or {}
    g_currentMission.animalSystem = {
        getSubTypeByFillTypeIndex = function(_, fillTypeIndex)
            return indices[fillTypeIndex] and {} or nil
        end,
    }
end

--- Capture what drawAggregatedMedian hands the painter, without drawing.
local function captureAggregate()
    local captured = nil
    local realDraw = MDMMarketScreenGraph._drawLineChart
    MDMMarketScreenGraph._drawLineChart = function(series, _, _, _, _, ctx)
        captured = { series = series, ctx = ctx }
    end
    MDMMarketScreenGraph.drawAggregatedMedian(0, 0, 1, 1)
    MDMMarketScreenGraph._drawLineChart = realDraw
    return captured
end

local function maxOf(t)
    local m = nil
    for _, v in ipairs(t or {}) do if m == nil or v > m then m = v end end
    return m
end

-- ---- 1. a livestock buffer never reaches the pooled series -------------------------------
do
    MDMMarketScreenGraph.reset()
    claimLivestock({ [LIVESTOCK] = true })
    T.ok("the crop history was recorded", MDMMarketScreenGraph.seedFromHistory(CROP, history(CROP_PRICES)))
    T.ok("the livestock history was recorded too",
        MDMMarketScreenGraph.seedFromHistory(LIVESTOCK, history(HEAD_PRICES)))
    T.ok("the engine agrees the livestock index is per head",
        MDMMarketScreenGraph._isLivestock(LIVESTOCK) == true)
    T.ok("and that the crop index is not", MDMMarketScreenGraph._isLivestock(CROP) == false)

    local got = captureAggregate()
    T.ok("the aggregated median was drawn", got ~= nil and type(got.series) == "table")
    if got ~= nil and type(got.series) == "table" then
        -- the decisive one: a per-head price is four orders of magnitude above a per-litre price,
        -- so if any head value survived, the maximum cannot sit in the crop band
        T.ok("no per-head value is in the pooled series", maxOf(got.series) < 10)
        T.ok("and the crop values arrived intact, so this is exclusion and not an empty draw",
            math.abs(maxOf(got.series) - maxOf(CROP_PRICES)) < 1e-9)
        T.eq("one sample per crop point", #got.series, #CROP_PRICES)
    end
end

-- ---- 2. crops alone are unchanged by the exclusion ----------------------------------------
do
    MDMMarketScreenGraph.reset()
    claimLivestock({ [LIVESTOCK] = true })
    MDMMarketScreenGraph.seedFromHistory(CROP, history(CROP_PRICES))
    local got = captureAggregate()
    T.ok("with no livestock tracked the median still draws", got ~= nil)
    if got ~= nil then
        T.ok("and is the crop series itself", math.abs(maxOf(got.series) - maxOf(CROP_PRICES)) < 1e-9)
    end
end

-- ---- 3. livestock alone leaves nothing to pool ---------------------------------------------
do
    MDMMarketScreenGraph.reset()
    claimLivestock({ [LIVESTOCK] = true })
    MDMMarketScreenGraph.seedFromHistory(LIVESTOCK, history(HEAD_PRICES))
    T.eq("a livestock-only graph draws no aggregated median at all", captureAggregate(), nil)
end

-- ---- 4. the per-commodity path is untouched, which was never the bug ----------------------
do
    MDMMarketScreenGraph.reset()
    claimLivestock({ [LIVESTOCK] = true })
    MDMMarketScreenGraph.seedFromHistory(LIVESTOCK, history(HEAD_PRICES))
    T.ok("the livestock buffer still holds its samples",
        (MDMMarketScreenGraph.getSampleCount(LIVESTOCK) or 0) >= 2)
end

-- ---- 5. no animal system at all is not livestock ------------------------------------------
do
    MDMMarketScreenGraph.reset()
    g_currentMission = g_currentMission or {}
    g_currentMission.animalSystem = nil
    T.ok("with no animal system nothing is treated as per head",
        MDMMarketScreenGraph._isLivestock(LIVESTOCK) == false)
    MDMMarketScreenGraph.seedFromHistory(CROP, history(CROP_PRICES))
    local got = captureAggregate()
    T.ok("and the crop median still draws", got ~= nil)
end
