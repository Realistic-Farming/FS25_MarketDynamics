MDMMarketScreenGraph = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SAMPLE_INTERVAL_MS = 20000
local MAX_SAMPLES        = 40

local COLOR_BG        = {0.05, 0.05, 0.08, 0.85}
local COLOR_GRID      = {0.25, 0.25, 0.30, 0.40}
local COLOR_LINE      = {0.20, 0.78, 0.85, 1.00}
local COLOR_AREA      = {0.0, 0.0, 0.0, 0.0}
local COLOR_DOT       = {1.00, 1.00, 1.00, 0.90}
local COLOR_LABEL     = {0.80, 0.80, 0.80, 0.90}

local GRID_LINES      = 6
local LINE_THICKNESS  = 3

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _buffers     = {}
local _sampleTimer = 0

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function MDMMarketScreenGraph.reset()
    _buffers     = {}
    _sampleTimer = 0
end

function MDMMarketScreenGraph.update(dt)
    if not g_MarketDynamics or not g_MarketDynamics.isActive then return end

    -- BUILD 19:47: nothing is seeded or logged until the player has entered. The 19:20:43
    -- flood happened during load, so a _loadPhase flag was not enough on its own; the guard
    -- belongs inside this function, ahead of the sample timer, so no buffer is created and
    -- no "seeded buffer" line is written while the machine is still compiling.
    if not (g_currentMission ~= nil and g_currentMission.isMissionStarted == true) then return end

    _sampleTimer = _sampleTimer + dt
    if _sampleTimer < SAMPLE_INTERVAL_MS then return end
    _sampleTimer = _sampleTimer - SAMPLE_INTERVAL_MS

    local engine = g_MarketDynamics.marketEngine
    if not engine then return end

    for fillTypeIndex, entry in pairs(engine.prices) do
        local buf = _buffers[fillTypeIndex]
        if not buf then
            buf = { samples = {}, head = 0, count = 0 }
            _buffers[fillTypeIndex] = buf
            MDMLog.info(string.format("MarketScreenGraph: seeded buffer for fillType %d with price %.2f", fillTypeIndex, entry.current))
        end

        buf.head = buf.head + 1
        if buf.head > MAX_SAMPLES then
            buf.head = 1
        end
        buf.samples[buf.head] = entry.current
        if buf.count < MAX_SAMPLES then
            buf.count = buf.count + 1
        end
    end
end

function MDMMarketScreenGraph.getSampleCount(fillTypeIndex)
    local buf = _buffers[fillTypeIndex]
    if not buf then return 0 end
    return buf.count
end

--- One-time seed of the ring buffer from MarketEngine daily history.
--- Only when the ring has fewer than 2 samples and history has at least 2 real prices.
--- Does not invent samples. Safe to call repeatedly (no-op once seeded / ring warm).
function MDMMarketScreenGraph.seedFromHistory(fillTypeIndex, history)
    if fillTypeIndex == nil or history == nil or #history < 2 then
        return false
    end
    local buf = _buffers[fillTypeIndex]
    if buf ~= nil and (buf.count or 0) >= 2 then
        return false
    end
    local prices = {}
    for _, h in ipairs(history) do
        local p = h and h.price
        if type(p) == "number" then
            prices[#prices + 1] = p
        end
    end
    if #prices < 2 then
        return false
    end
    -- Take the most recent MAX_SAMPLES real prices only.
    local start = math.max(1, #prices - MAX_SAMPLES + 1)
    buf = { samples = {}, head = 0, count = 0 }
    for i = start, #prices do
        buf.head = buf.head + 1
        if buf.head > MAX_SAMPLES then
            buf.head = 1
        end
        buf.samples[buf.head] = prices[i]
        if buf.count < MAX_SAMPLES then
            buf.count = buf.count + 1
        end
    end
    _buffers[fillTypeIndex] = buf
    return buf.count >= 2
end

function MDMMarketScreenGraph.getGlobalSampleCount()
    local maxCount = 0
    for _, buf in pairs(_buffers) do
        if buf and buf.count and buf.count > maxCount then
            maxCount = buf.count
        end
    end
    return maxCount
end

-- ---------------------------------------------------------------------------
-- Extract ordered samples from a ring buffer
-- ---------------------------------------------------------------------------

local function _extractOrdered(buf)
    local ordered = {}
    local count = buf.count
    local start = buf.head - count + 1
    if start < 1 then start = start + MAX_SAMPLES end

    for i = 0, count - 1 do
        local idx = ((start - 1 + i) % MAX_SAMPLES) + 1
        local p = buf.samples[idx]
        if p then
            ordered[#ordered + 1] = p
        end
    end
    return ordered
end

-- ---------------------------------------------------------------------------
-- Draw line chart for a single commodity
-- ---------------------------------------------------------------------------

function MDMMarketScreenGraph.draw(fillTypeIndex, gx, gy, gw, gh)
    local buf = _buffers[fillTypeIndex]
    if not buf or buf.count < 2 then return end

    local ordered = _extractOrdered(buf)
    if #ordered < 2 then return end

    -- BUILD 15:39 (PB-07): name the series and its unit so the chart is
    -- readable on its own instead of being an unlabelled line.
    MDMMarketScreenGraph._drawLineChart(ordered, gx, gy, gw, gh, {
        label   = MDMMarketScreenGraph._fillTypeTitle(fillTypeIndex),
        perHead = MDMMarketScreenGraph._isLivestock(fillTypeIndex),
    })
end

--- BUILD 23:43: the ONE price-trend decision tree, shared by the full Market screen and
--- the Esc Prices page. It was duplicated, and the two copies disagreed: the Esc copy had
--- no getGlobalSampleCount step and no aggregated-median branch, so whenever the selected
--- crop was thin but other crops were warm, Market drew the median and Esc drew nothing.
--- Same data, two answers. Neither caller keeps a private copy any more.
---
--- Returns the branch actually taken, so callers drive their own hint element without
--- re-deciding: "ring" / "median" / "history" all painted something, "thin" did not.
function MDMMarketScreenGraph.drawPriceTrend(fillTypeIndex, gx, gy, gw, gh)
    if gx == nil or gy == nil or gw == nil or gh == nil or gw <= 0 or gh <= 0 then
        return "thin"
    end

    local sampleCount = 0
    if fillTypeIndex ~= nil then
        sampleCount = MDMMarketScreenGraph.getSampleCount(fillTypeIndex) or 0
    end
    if sampleCount < 2 then
        sampleCount = MDMMarketScreenGraph.getGlobalSampleCount() or 0
    end

    if sampleCount >= 2 then
        if fillTypeIndex ~= nil and (MDMMarketScreenGraph.getSampleCount(fillTypeIndex) or 0) >= 2 then
            MDMMarketScreenGraph.draw(fillTypeIndex, gx, gy, gw, gh)
            return "ring"
        end
        MDMMarketScreenGraph.drawAggregatedMedian(gx, gy, gw, gh)
        return "median"
    end

    -- Ring too thin everywhere: fall back to the engine's own daily history for this crop.
    if fillTypeIndex ~= nil then
        local mdm = (g_currentMission ~= nil and g_currentMission.MarketDynamics) or g_MarketDynamics
        local engine = mdm ~= nil and mdm.marketEngine or nil
        if engine ~= nil and type(engine.getPriceHistory) == "function" then
            local history = engine:getPriceHistory(fillTypeIndex)
            if type(history) == "table" and #history >= 2 then
                local series = {}
                for _, h in ipairs(history) do
                    if h ~= nil and type(h.price) == "number" then
                        series[#series + 1] = h.price
                    end
                end
                if #series >= 2 then
                    MDMMarketScreenGraph._drawLineChart(series, gx, gy, gw, gh, {
                        label   = MDMMarketScreenGraph._fillTypeTitle(fillTypeIndex),
                        perHead = MDMMarketScreenGraph._isLivestock(fillTypeIndex),
                    })
                    return "history"
                end
            end
        end
    end

    return "thin"
end

-- ---------------------------------------------------------------------------
-- Aggregated median fallback (when no commodity selected)
-- ---------------------------------------------------------------------------

function MDMMarketScreenGraph.drawAggregatedMedian(gx, gy, gw, gh)
    local arrays = {}
    local maxCount = 0
    for _, buf in pairs(_buffers) do
        if buf and buf.count and buf.count > 0 then
            local ordered = _extractOrdered(buf)
            arrays[#arrays + 1] = ordered
            if #ordered > maxCount then maxCount = #ordered end
        end
    end

    if #arrays == 0 or maxCount < 2 then return end

    local agg = {}
    for i = 1, maxCount do
        local vals = {}
        for _, arr in ipairs(arrays) do
            if arr[i] ~= nil then vals[#vals + 1] = arr[i] end
        end
        if #vals > 0 then
            table.sort(vals)
            local n = #vals
            if n % 2 == 1 then
                agg[#agg + 1] = vals[math.floor((n + 1) / 2)]
            else
                local m = math.floor(n / 2)
                agg[#agg + 1] = (vals[m] + vals[m + 1]) / 2
            end
        end
    end

    if #agg < 2 then return end

    -- The median across every tracked commodity is not one commodity, and
    -- labelling it with a crop name would be a lie about what is plotted.
    local medianLabel = MDMUtil and MDMUtil.getModText("mdm_screen_graph_median")
    if type(medianLabel) ~= "string" or medianLabel == "" then
        medianLabel = "All commodities (median)"
    end
    MDMMarketScreenGraph._drawLineChart(agg, gx, gy, gw, gh, { label = medianLabel })
end

-- ---------------------------------------------------------------------------
-- Circle approximation helper (horizontal scanline approach)
-- ---------------------------------------------------------------------------

local CIRCLE_SLICES = 8

local function _drawFilledCircle(cx, cy, r, cr, cg, cb, ca)
    local step = (2 * r) / CIRCLE_SLICES
    for s = 0, CIRCLE_SLICES - 1 do
        local dy = -r + (s + 0.25) * step
        local halfW = math.sqrt(math.max(r * r - dy * dy, 0))
        drawFilledRect(cx - halfW, cy + dy, halfW * 1.5, step, cr, cg, cb, ca)
    end
end

-- ---------------------------------------------------------------------------
-- Line chart renderer (core) — uses drawFilledRect + drawLine2D
-- ---------------------------------------------------------------------------

-- BUILD 15:39 (PB-07) - graph context.
--
-- The chart drew a line and five bare Y numbers. Brian could not tell which
-- commodity it was, over what period, or in what unit, which makes the trend
-- unreadable however correct the line is. These helpers add the missing frame:
-- the selected commodity's name, the x-axis time window, and Y labels that agree
-- with the table's units and 2dp.
--
-- Nothing here invents data. The label comes from the fill type the caller
-- already resolved, and the window is described from the sample count that is
-- actually plotted - never a fabricated date range or a padded flat point.

local function graphCurrency()
    if g_i18n ~= nil and type(g_i18n.getCurrencySymbol) == "function" then
        local ok, sym = pcall(g_i18n.getCurrencySymbol, g_i18n, true)
        if ok and type(sym) == "string" and sym ~= "" then return sym end
    end
    return ""
end

--- Grouped, forced-2dp axis money. Matches the table (George ENGINE 2026-08-15:
--- formatMoney does not force trailing zeros, formatNumber with forcePrecision
--- does).
local function axisMoney(value)
    local n
    if g_i18n ~= nil and type(g_i18n.formatNumber) == "function" then
        local ok, s = pcall(g_i18n.formatNumber, g_i18n, value, 2, true)
        if ok and type(s) == "string" then n = s end
    end
    if n == nil then n = string.format("%.2f", value or 0) end
    return graphCurrency() .. n
end

--- Display title for a fill type index, or nil when it cannot be resolved.
function MDMMarketScreenGraph._fillTypeTitle(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then return nil end
    local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if ft == nil then return nil end
    return ft.title or ft.name
end

--- Is this index priced per head? Mirrors MarketScreen:_isLivestock so the graph
--- and the table never disagree about the unit.
function MDMMarketScreenGraph._isLivestock(fillTypeIndex)
    local sys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if sys == nil or type(sys.getSubTypeByFillTypeIndex) ~= "function" then
        return false
    end
    local ok, subType = pcall(sys.getSubTypeByFillTypeIndex, sys, fillTypeIndex)
    return ok and subType ~= nil
end

---@param series number[] plotted values (per-litre engine numbers)
---@param ctx table|nil { label, perHead, points, source }
function MDMMarketScreenGraph._drawLineChart(series, gx, gy, gw, gh, ctx)
    local n = #series
    if n < 2 then return end
    ctx = ctx or {}

    -- Reserve a strip at the top for the series label and one at the bottom for
    -- the x-axis window, so neither can overlap the plotted line.
    local titleH = gh * 0.11
    local axisH  = gh * 0.09
    local fullGy, fullGh = gy, gh
    gy = gy + axisH
    gh = math.max(gh - titleH - axisH, 0.001)

    -- Find min/max
    local minP = math.huge
    local maxP = -math.huge
    for _, p in ipairs(series) do
        if p < minP then minP = p end
        if p > maxP then maxP = p end
    end
    if minP == math.huge then return end

    -- Price range with 10% padding
    local priceRange = maxP - minP
    if priceRange < 0.01 then priceRange = 0.01 end
    local padding = priceRange * 0.10
    local yMin = minP - padding
    local yMax = maxP + padding
    local yRange = yMax - yMin

    -- Background
    drawFilledRect(gx, gy, gw, gh, COLOR_BG[1], COLOR_BG[2], COLOR_BG[3], COLOR_BG[4])

    -- Grid lines + Y-axis labels
    local gridLineH = gh / 200  -- thin line
    for i = 0, GRID_LINES do
        local frac = i / GRID_LINES
        local ly = gy + frac * gh
        drawFilledRect(gx, ly, gw, gridLineH, COLOR_GRID[1], COLOR_GRID[2], COLOR_GRID[3], COLOR_GRID[4])

        -- Y-axis label
        local price = yMin + frac * yRange
        setTextColor(COLOR_LABEL[1], COLOR_LABEL[2], COLOR_LABEL[3], COLOR_LABEL[4])
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_RIGHT)

        local labelSize = math.max(gh * 0.020, 0.003)
        -- BUILD 15:39 (PB-07): same unit and same 2dp as the table. Livestock is
        -- per head, so it is NOT multiplied by 1000 - that multiplication on an
        -- animal row is what produced the nonsense figures Brian reported.
        local shown = ctx.perHead and price or (price * 1000)
        local labelStr = axisMoney(shown)
        -- Rotate only when the integer part gets long enough to collide.
        if shown >= 10000 then
            local labelX = gx - 0.005
            setTextRotation(math.rad(30), labelX, ly)
            renderText(labelX, ly, labelSize, labelStr)
            setTextRotation(0, 0, 0)
        else
            renderText(gx - 0.01, ly, labelSize, labelStr)
        end
    end
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Compute screen positions for each data point
    local points = {}
    for i = 1, n do
        points[i] = {
            x = gx + ((i - 1) / (n - 1)) * gw,
            y = gy + ((series[i] - yMin) / yRange) * gh,
        }
    end

    -- Area fill: thin vertical bars from baseline to each point
    local sliceW = math.max(gw / (n - 1), 0.001)
    for i = 1, n do
        local barH = points[i].y - gy
        if barH > 0 then
            drawFilledRect(points[i].x - sliceW * 0.5, gy, sliceW, barH,
                        COLOR_AREA[1], COLOR_AREA[2], COLOR_AREA[3], COLOR_AREA[4])
        end
    end

    -- Line segments (drawLine2D)
    local thick = math.max(LINE_THICKNESS / g_screenHeight, 0.002)
    for i = 1, n - 1 do
        drawLine2D(points[i].x, points[i].y, points[i+1].x, points[i+1].y,
                thick, COLOR_LINE[1], COLOR_LINE[2], COLOR_LINE[3], COLOR_LINE[4])
    end

    -- Data point dots (circle approximation)
    local dotR = thick * 1.8
    for i = 1, n do
        _drawFilledCircle(points[i].x, points[i].y, dotR,
                        COLOR_DOT[1], COLOR_DOT[2], COLOR_DOT[3], COLOR_DOT[4])
    end

    -- ── BUILD 15:39 (PB-07): the frame that makes the line readable ──────────
    setTextColor(COLOR_LABEL[1], COLOR_LABEL[2], COLOR_LABEL[3], COLOR_LABEL[4])
    setTextRotation(0, 0, 0)

    -- Series label. With one series this IS the legend: it names exactly what
    -- the line is and in which unit, which is what a legend is for.
    local titleSize = math.max(fullGh * 0.055, 0.010)
    local label = ctx.label
    if label == nil or label == "" then
        local fb = MDMUtil and MDMUtil.getModText("mdm_screen_price_trend")
        label = (type(fb) == "string" and fb ~= "") and fb or "Price trend"
    end
    local unit
    if ctx.perHead then
        unit = MDMUtil and MDMUtil.getModText("mdm_screen_per_head")
        if type(unit) ~= "string" or unit == "" then unit = "/ head" end
    else
        unit = MDMUtil and MDMUtil.getModText("mdm_screen_per_1000l")
        if type(unit) ~= "string" or unit == "" then unit = "/ 1,000L" end
    end
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(gx, fullGy + fullGh - titleH * 0.85,
               titleSize, string.format("%s  (%s)", label, unit))
    setTextBold(false)

    -- X-axis window. Described from the samples actually plotted, never from an
    -- invented date range: n points, oldest on the left, newest on the right.
    local axisSize = math.max(fullGh * 0.042, 0.008)
    local axisY    = fullGy + axisH * 0.15
    local oldest = MDMUtil and MDMUtil.getModText("mdm_screen_graph_oldest")
    if type(oldest) ~= "string" or oldest == "" then oldest = "oldest" end
    local newest = MDMUtil and MDMUtil.getModText("mdm_screen_graph_newest")
    if type(newest) ~= "string" or newest == "" then newest = "now" end

    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(gx, axisY, axisSize, oldest)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    renderText(gx + gw, axisY, axisSize, newest)
    setTextAlignment(RenderText.ALIGN_CENTER)
    local span = MDMUtil and MDMUtil.getModText("mdm_screen_graph_span")
    if type(span) ~= "string" or span == "" then span = "%d samples" end
    local okSpan, spanTxt = pcall(string.format, span, n)
    renderText(gx + gw * 0.5, axisY, axisSize, okSpan and spanTxt or tostring(n))
    setTextAlignment(RenderText.ALIGN_LEFT)
end
