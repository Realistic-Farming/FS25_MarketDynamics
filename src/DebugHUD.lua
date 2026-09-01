-- DebugHUD.lua
-- TEMP: Developer overlay for testing MDM systems.
-- Uses renderText only — no XML, no layout files.
-- Toggle with the "mdmHud" console command (off by default).
--
-- Optional developer overlay, off by default.
--
-- Author: tison (dev-1)

MDMDebugHUD = MDMDebugHUD or {}
MDMDebugHUD.__index = MDMDebugHUD

-- Layout
local FONT_HEADER = 0.016
local FONT_BODY   = 0.013
local X           = 0.012
local Y_TOP       = 0.965

-- Colors: { r, g, b, a }
local C_HEADER  = {0.95, 0.85, 0.15, 0.95}  -- yellow
local C_SECTION = {0.55, 0.85, 1.00, 1.00}  -- light blue
local C_NORMAL  = {1.00, 1.00, 1.00, 1.00}  -- white
local C_UP      = {0.30, 1.00, 0.40, 1.00}  -- green (price up)
local C_DOWN    = {1.00, 0.35, 0.35, 1.00}  -- red   (price down)
local C_WARN    = {1.00, 0.60, 0.10, 1.00}  -- orange (events)
local C_DIM     = {0.50, 0.50, 0.50, 1.00}  -- gray

function MDMDebugHUD.new()
    return setmetatable({}, MDMDebugHUD)
end

-- Renders one text line and returns the Y position for the next line.
local function rline(y, size, text, color)
    local c = color or C_NORMAL
    setTextColor(c[1], c[2], c[3], c[4])
    renderText(X, y, size, text)
    return y - size * 1.3
end

function MDMDebugHUD:draw()
    if not g_MarketDynamics or not g_MarketDynamics.isActive then return end

    local mdm = g_MarketDynamics
    setTextAlignment(RenderText.ALIGN_LEFT)

    local y = Y_TOP

    -- ---- Header ----
    setTextBold(true)
    y = rline(y, FONT_HEADER, "[ MDM DEBUG HUD ]", C_HEADER)
    setTextBold(false)

    local pricesOn = mdm.settings.pricesEnabled and "ON" or "OFF"
    local vscale   = string.format("%.1fx", mdm.marketEngine.volatilityScale)
    local bcLabel  = BCIntegration.isEnabled() and "BC mode" or "MDM futures"
    y = rline(y, FONT_BODY,
        "prices:" .. pricesOn .. "  volatility:" .. vscale .. "  contracts:" .. bcLabel,
        C_SECTION)

    y = y - FONT_BODY * 0.5

    -- ---- Top price movers ----
    setTextBold(true)
    y = rline(y, FONT_BODY, "TOP MOVERS  (base -> current)", C_SECTION)
    setTextBold(false)

    local movers = {}
    for idx, entry in pairs(mdm.marketEngine.prices) do
        local ft   = g_fillTypeManager:getFillTypeByIndex(idx)
        local name = ft and (ft.title or ft.name) or ("ft" .. idx)
        local pct  = mdm.marketEngine:getPriceChangePercent(idx)
        table.insert(movers, { name = name, base = entry.base, current = entry.current, pct = pct })
    end
    table.sort(movers, function(a, b) return math.abs(a.pct) > math.abs(b.pct) end)

    if #movers == 0 then
        y = rline(y, FONT_BODY, "  (no prices tracked yet)", C_DIM)
    else
        for i = 1, math.min(10, #movers) do
            local m   = movers[i]
            local sign = m.pct >= 0 and "+" or ""
            local col  = m.pct > 0.5 and C_UP or (m.pct < -0.5 and C_DOWN or C_NORMAL)
            y = rline(y, FONT_BODY,
                string.format("  %-14s  $%.3f -> $%.3f  (%s%.1f%%)",
                    m.name, m.base, m.current, sign, m.pct),
                col)
        end
        if #movers > 10 then
            y = rline(y, FONT_BODY, "  ... +" .. (#movers - 10) .. " more", C_DIM)
        end
    end

    y = y - FONT_BODY * 0.5

    -- ---- World events ----
    setTextBold(true)
    y = rline(y, FONT_BODY, "WORLD EVENTS", C_SECTION)
    setTextBold(false)

    local events = mdm.worldEvents:getActiveEvents()
    if #events == 0 then
        y = rline(y, FONT_BODY, "  (none active)", C_DIM)
    else
        local now = MDMUtil.getGameTime()
        for _, ev in ipairs(events) do
            local rem  = math.max(0, ev.endsAt - now)
            local mins = math.floor(rem / 60000)
            local secs = math.floor((rem % 60000) / 1000)
            y = rline(y, FONT_BODY,
                string.format("  %-22s  intensity:%.0f%%  %dm%02ds left",
                    ev.name, ev.intensity * 100, mins, secs),
                C_WARN)
        end
    end

    y = y - FONT_BODY * 0.5

    -- ---- Futures contracts ----
    setTextBold(true)
    y = rline(y, FONT_BODY, "FUTURES CONTRACTS", C_SECTION)
    setTextBold(false)

    local farmId = (g_currentMission and g_currentMission.player and g_currentMission.player.farmId) or 1
    local contracts = mdm.futuresMarket:getContractsForFarm(farmId)

    local active = {}
    for _, c in ipairs(contracts) do
        if c.status == "active" then table.insert(active, c) end
    end

    if #active == 0 then
        y = rline(y, FONT_BODY, "  (no active contracts)", C_DIM)
    else
        local now = MDMUtil.getGameTime()
        for _, c in ipairs(active) do
            local pct  = c.quantity > 0 and (c.delivered / c.quantity * 100) or 0
            local rem  = math.max(0, c.deliveryTime - now)
            local mins = math.floor(rem / 60000)
            local col  = pct >= 100 and C_UP or C_NORMAL
            y = rline(y, FONT_BODY,
                string.format("  #%d %-10s  %dL @ $%.3f  del:%.0f%%  exp:%dm",
                    c.id, c.fillTypeName, c.quantity, c.lockedPrice, pct, mins),
                col)
        end
    end

    -- Reset state
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end
