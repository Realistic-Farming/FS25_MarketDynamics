-- =========================================================
-- MdRfPdaGuest
-- Esc RF PDA Module: Market Dynamics (host-capable + guest).
-- Stage-8 BUILD 2026-08-04 three pages: Prices | Events | Contracts
-- (Samantha DESIGN + George ENGINE ACK + Wizard say-build).
-- Join: g_currentMission.rfEscModules + RfEscBootstrap.ensureDoor (NO rfPdaHost).
-- TOP: commodities SmoothList under GuiElement; quiet reload.
-- BOTTOM: mdPricesBand / mdEventsBand / mdContractsBand via mdSubnav.
-- HARD VETO: never reintroduce addPageTab + raw stand-down product path.
-- =========================================================

MdRfPdaGuest = MdRfPdaGuest or {}

local MOD_DIR = (MarketDynamicsModDirectory or g_currentModDirectory)
local MD_RF_MOD_NAME = (MarketDynamicsModName or g_currentModName)
local PANEL_ID = "marketDynamics"
local PANEL_ORDER = 40
-- BUILD 16:42: eight fixed rows in the 550px left Events card (24px pitch, George measured).
local MAX_EVENT_ROWS = 8
local MAX_CONTRACT_ROWS = 5

local PAGE_PRICES = 1
local PAGE_EVENTS = 2
local PAGE_CONTRACTS = 3
-- BUILD 16:42 (George CLOSED DESIGN 16:25): three pages. The Event Settings summary and its dialog
-- plate are the right card of the Events page; the 800x800 dialog is never inlined.
-- New Contract card presets: the same buttons MDMContractDialog offers (dlgQty*, dlgDel*).
local NC_QTY_PRESETS = { 500, 1000, 5000, 10000, 25000, 50000 }
local NC_DAY_PRESETS = { 30, 60, 90, 120 }
-- BUILD 15:34 (George CLOSED DESIGN 15:20): the quantity / day plates and Confirm paint as vanilla
-- ButtonOverlay key chips, the CsRfPdaGuest pivot-remote pattern. The Button's own text stays "",
-- so no SPACE glyph can ever sit on a label; the chip is drawn in the card's draw wrap.
local NC_CHIP_IDS = {
    "mdNcQty500", "mdNcQty1000", "mdNcQty5000", "mdNcQty10000", "mdNcQty25000", "mdNcQty50000",
    "mdNcDays30", "mdNcDays60", "mdNcDays90", "mdNcDays120",
    "mdNewContractBtn",
}
-- BUILD 20:36: the Event settings plate (mdEsSummaryCard on the Events page) paints the same way.
local ES_CHIP_IDS = { "mdEventSettingsBtn" }
-- Vanilla wideButton chip tints (guiProfiles: icon = colorMainHighlight, icon background =
-- colorGreenDark), the same numbers CsRfPdaGuest.lua uses so both cards read as one family.
local NC_CHIP_TEXT = { 0.22323, 0.40724, 0.00368 }
local NC_CHIP_BG   = { 0.00913, 0.01033, 0.00651 }
-- Gated: zero green, so "locked" never reads as "live but faint".
local NC_CHIP_GATED_TEXT = { 0.62, 0.64, 0.66 }
local NC_CHIP_GATED_BG   = { 0.06, 0.06, 0.065 }

local COLOR_UP = {0.30, 0.80, 0.35, 1}
local COLOR_DOWN = {0.90, 0.25, 0.20, 1}
local COLOR_FLAT = {0.70, 0.72, 0.75, 1}
local COLOR_LIME = {0.659, 0.878, 0.290, 1}

--- BUILD 21:41: defensive cross-env resolve. Inside this mod MarketScreenGraph.lua is
--- sourced at modDesc line 38, ahead of this file, so the bare global already resolves -
--- the real out-of-scope failure was host-side. Kept anyway so a future modDesc reorder
--- cannot silently take the graph away, and so guest and host read the same way.
local function mdGraphClass()
    if MDMMarketScreenGraph ~= nil then
        return MDMMarketScreenGraph
    end
    local env = g_modEnvironments ~= nil and g_modEnvironments[MD_RF_MOD_NAME] or nil
    return env ~= nil and env.MDMMarketScreenGraph or nil
end

local _registered = false
local _legacyStoodDown = false
local _selectedFillType = nil
-- Set only while we programmatically restore the list highlight, so the delegate's
-- selection callback does not treat our own restore as a fresh player pick.
local _suppressSelectionCallback = false
local _commoditySig = nil
local _lastEventsSig = nil
local _lastContractsSig = nil
-- BUILD 10:47: New Contract card state (Esc subset of MDMContractDialog: quantity + window +
-- confirm for the crop picked in the top table) and its one feedback line.
local _ncQty = 5000
local _ncDays = 30
local _ncFeedback = nil
-- One-time ring seeds from MarketEngine history (fillTypeIndex → true). Never invent samples.
local _historySeeded = {}
-- Set by MarketScreen when deep-only load skipped Esc rail inject (prefer never stand-down mutate).
MdRfPdaGuest._legacyNeverInjected = false

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[MD_RF_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            local lower = text:lower()
            if lower ~= tostring(key):lower()
                and text ~= ("$l10n_" .. key)
                and not lower:find("^missing%s")
                and not lower:find("^missing_")
            then
                return text
            end
        end
    end
    return fallback or key
end

local function getMdm()
    if g_currentMission ~= nil and g_currentMission.MarketDynamics ~= nil then
        return g_currentMission.MarketDynamics
    end
    return g_MarketDynamics
end

local function getHost()
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules
    end
    local env = getfenv(0)
    if env ~= nil and env.g_rfEscModules ~= nil then
        return env.g_rfEscModules
    end
    if RfEscModules ~= nil then
        return RfEscModules.getOrCreate()
    end
    return nil
end

local function getHostPage()
    if g_inGameMenu == nil then
        return nil
    end
    return g_inGameMenu.menuRealisticFarming
end

local function findDescendant(root, id)
    if root == nil or id == nil then
        return nil
    end
    if root.getDescendantById then
        local el = root:getDescendantById(id)
        if el ~= nil then
            return el
        end
    end
    local page = getHostPage()
    if page and page.getDescendantById then
        return page:getDescendantById(id)
    end
    return nil
end

local function setText(el, text)
    if el ~= nil and type(el.setText) == "function" then
        el:setText(text or "")
    end
end

local function setVis(el, visible)
    if el ~= nil and type(el.setVisible) == "function" then
        el:setVisible(visible)
    end
end

-- BUILD 20:36 (George CLOSED DESIGN 19:03, live crash 18:59:25 x1192): the engine's own text
-- colour setter, captured BEFORE the element helper below shadows the name. The chip draw wrap
-- resets the global render colour with this one; calling the helper with a number threw
-- "attempt to index number with 'setTextColor'" every frame and killed the Market page draw.
local engineSetTextColor = setTextColor

local function setTextColor(el, r, g, b, a)
    if el ~= nil and type(el.setTextColor) == "function" then
        el:setTextColor(r, g, b, a)
    end
end

local function fillTypeTitle(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then
        return "-"
    end
    local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if ft == nil then
        return "-"
    end
    if ft.title ~= nil and ft.title ~= "" then
        return ft.title
    end
    if ft.name ~= nil then
        return ft.name
    end
    return tostring(fillTypeIndex)
end

local function formatMoney(amount)
    if amount == nil then
        return "-"
    end
    if g_i18n and g_i18n.formatMoney then
        return g_i18n:formatMoney(amount, 0, true, true)
    end
    return string.format("%.0f", amount)
end

local function formatSignedPct(pct)
    pct = tonumber(pct) or 0
    if pct > 0 then
        return string.format("+%.1f%%", pct)
    end
    return string.format("%.1f%%", pct)
end

local function intensityBand(intensity)
    local v = tonumber(intensity) or 0
    if v >= 0.66 then
        return tr("mdm_hud_event_severe", "Severe")
    end
    if v >= 0.33 then
        return tr("mdm_hud_event_moderate", "Moderate")
    end
    return tr("mdm_hud_event_mild", "Mild")
end

local function formatRemaining(endsAt)
    if endsAt == nil or MDMUtil == nil or type(MDMUtil.getGameTime) ~= "function" then
        return nil
    end
    local now = MDMUtil.getGameTime()
    if now == nil or now == 0 then
        return nil
    end
    local rem = endsAt - now
    if rem <= 0 then
        return tr("md_rf_pda_remaining_done", "ending")
    end
    local totalMin = math.floor(rem / 60000)
    local days = math.floor(totalMin / (24 * 60))
    local hours = math.floor((totalMin % (24 * 60)) / 60)
    local mins = totalMin % 60
    if days > 0 then
        return string.format(tr("md_rf_pda_remaining_dh", "%dd %dh left"), days, hours)
    end
    if hours > 0 then
        return string.format(tr("md_rf_pda_remaining_hm", "%dh %dm left"), hours, mins)
    end
    return string.format(tr("md_rf_pda_remaining_m", "%dm left"), math.max(1, mins))
end

local function pressureCoach(pct)
    pct = tonumber(pct) or 0
    local abs = math.abs(pct)
    if abs < 2 then
        return tr("md_rf_pda_pressure_near", "near base"), COLOR_FLAT
    end
    if pct >= 8 then
        return tr("md_rf_pda_pressure_up_sharp", "up sharply vs base"), COLOR_UP
    end
    if pct <= -8 then
        return tr("md_rf_pda_pressure_down_sharp", "down sharply vs base"), COLOR_DOWN
    end
    if pct > 0 then
        return tr("md_rf_pda_pressure_up", "softly up vs base"), COLOR_UP
    end
    return tr("md_rf_pda_pressure_soft", "soft vs base"), COLOR_DOWN
end

local function farmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end
    if g_currentMission ~= nil and type(g_currentMission.getFarmId) == "function" then
        return g_currentMission:getFarmId()
    end
    return nil
end

local function clampPageIndex(idx)
    idx = tonumber(idx) or PAGE_PRICES
    if idx < PAGE_PRICES then
        return PAGE_PRICES
    end
    if idx > PAGE_CONTRACTS then
        return PAGE_CONTRACTS
    end
    return idx
end

local function currentPageIndex()
    local page = getHostPage()
    if page ~= nil and page.mdSubPageIndex ~= nil then
        return clampPageIndex(page.mdSubPageIndex)
    end
    return PAGE_PRICES
end

--- Build full commodities list (sorted by |change %| desc). Used for TOP table.
---@return table array of { fillTypeIndex, changePct, price, title, hudOverlay }
function MdRfPdaGuest.buildCommodities()
    local out = {}
    local mdm = getMdm()
    local engine = mdm and mdm.marketEngine
    if engine == nil or engine.prices == nil then
        return out
    end
    for fillTypeIndex, _ in pairs(engine.prices) do
        local pct = 0
        local price = nil
        local hudOverlay = nil
        if type(engine.getPriceChangePercent) == "function" then
            pct = engine:getPriceChangePercent(fillTypeIndex) or 0
        end
        if type(engine.getPrice) == "function" then
            price = engine:getPrice(fillTypeIndex)
        end
        if g_fillTypeManager ~= nil then
            local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if ft ~= nil and type(ft.hudOverlayFilename) == "string" and ft.hudOverlayFilename ~= "" then
                hudOverlay = ft.hudOverlayFilename
            end
        end
        table.insert(out, {
            fillTypeIndex = fillTypeIndex,
            changePct = pct,
            price = price,
            title = fillTypeTitle(fillTypeIndex),
            hudOverlay = hudOverlay,
        })
    end
    -- Stable title order for the Esc list. This used to sort by biggest absolute price
    -- move, so the list re-ordered under the player on every refresh and the highlight
    -- chased it (eyes-on FAIL 2026-08-07). Title first, fill type id as tiebreak, so the
    -- order is fully deterministic and does not depend on prices at all.
    table.sort(out, function(a, b)
        local at, bt = a.title or "", b.title or ""
        if at ~= bt then
            return at < bt
        end
        return (a.fillTypeIndex or 0) < (b.fillTypeIndex or 0)
    end)
    return out
end

-- Back-compat for any host still calling buildMovers. buildCommodities is title-sorted
-- now, so this does its own biggest-mover sort rather than truncating an alphabetical
-- list and quietly returning the wrong thing.
function MdRfPdaGuest.buildMovers(limit)
    local all = MdRfPdaGuest.buildCommodities()
    table.sort(all, function(a, b)
        local aa = math.abs(a.changePct or 0)
        local bb = math.abs(b.changePct or 0)
        if aa ~= bb then
            return aa > bb
        end
        return (a.title or "") < (b.title or "")
    end)
    limit = limit or 5
    while #all > limit do
        table.remove(all)
    end
    return all
end

--- Identity of the commodity SET, deliberately order-independent.
-- Row order changes every time prices move, so an order-sensitive signature forced a
-- reloadData on every light refresh and SmoothList reset the highlight to row 1 (the
-- "always snaps back to ADS Coolant Premium" eyes-on FAIL, Wizard 2026-08-07). Only a
-- genuinely different set of fill types should cost a reload.
local function commoditiesSignature(rows)
    if rows == nil or #rows == 0 then
        return "empty"
    end
    local seen, ids = {}, {}
    for _, r in ipairs(rows) do
        local id = tostring(r.fillTypeIndex)
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return table.concat(ids, "|")
end

local function defaultSelection(rows)
    if rows ~= nil and rows[1] ~= nil then
        return rows[1].fillTypeIndex
    end
    return nil
end

local function paintSideInfo(container)
    local body = tr("rf_pda_side_info_market_dynamics",
        "Market Dynamics\n\nPause Market glance with three pages: Prices, Events, Contracts.\n\nTop table = crop icons, prices, and swings. On Prices, pick a crop to drive the graph. Graph under the table = price path for the crop you pick. A new crop's line appears once it has price history.\n\nEvents page = what is hitting the market now on the left, the Event Settings summary and its dialog plate on the right.\n\nContracts page = your open deals on the left, New Contract on the right for the crop you picked above.")
    -- Nest under mdSubnavShell (WC twin). Never force Soil rfSideInfoShell on MDM.
    setVis(findDescendant(container, "rfSideInfoShell"), false)
    local shell = findDescendant(container, "mdSideInfoShell")
    local bodyEl = findDescendant(container, "mdSideInfoBody")
    if shell == nil then
        -- Nil-safe if older Soil-first door XML lacks the MDM nest.
        return
    end
    setVis(shell, true)
    setText(bodyEl, body)
end

-- BUILD 12:05 (George CLOSED DESIGN 09:45): the Esc full-Market door is gone. Prices, Events and
-- Contracts are the whole Market on this page; the standalone Market screen keeps its keybind
-- and the Control Center toggle.

local function paintTableHeaders(container)
    -- Shared deep Market keys + Missing-reject (tr); EN Crop/Price/Change locked.
    setText(findDescendant(container, "mdColCrop"), tr("mdm_screen_col_crop", "Crop"))
    setText(findDescendant(container, "mdColPrice"), tr("mdm_screen_col_price", "Price"))
    setText(findDescendant(container, "mdColChange"), tr("mdm_screen_col_change", "Change"))
end

local function syncCommodityList(container, rows, forceReload)
    local page = getHostPage()
    if page == nil then
        return
    end
    page.mdCommodityData = rows or {}
    local list = page.mdCommodityList or findDescendant(container, "mdCommodityList")
    if list == nil then
        return
    end
    page.mdCommodityList = list
    if list.dataSource ~= page then
        list.dataSource = page
        list.delegate = page
    end

    local sig = commoditiesSignature(rows)
    local needReload = forceReload or sig ~= _commoditySig
    _commoditySig = sig

    local emptyEl = findDescendant(container, "mdCommoditiesEmptyHint")
    if rows == nil or #rows == 0 then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_commodities_empty", "no market prices yet"))
    else
        setVis(emptyEl, false)
        setText(emptyEl, "")
    end

    -- Hang fence + scroll stability (BUILD 10:10): a light tick NEVER reloads.
    -- reloadData → updateView(nil, true) clamps viewOffset and jumps the list to top.
    if not forceReload then
        needReload = false
    end
    if needReload and type(list.reloadData) == "function" then
        -- Full pass: reload is legitimate; save/restore scroll so re-enter keeps place.
        -- BUILD 21:41: viewOffset is PIXELS. SmoothListElement clamps it against
        -- contentSize - absSize[lengthAxis]; the old restore clamped it to #rows - 1, a
        -- ROW COUNT, so with 20 commodities any scroll position collapsed to 19 pixels
        -- and the list read as "jumps to top". Restore both offsets raw and let
        -- updateView apply the element's own correct clamp - no hand-rolled maximum.
        local savedOffset = list.viewOffset
        local savedTarget = list.targetViewOffset
        list:reloadData()
        if savedOffset ~= nil then
            list.viewOffset = savedOffset
        end
        if savedTarget ~= nil then
            list.targetViewOffset = savedTarget
        end
        if (savedOffset ~= nil or savedTarget ~= nil) and type(list.updateView) == "function" then
            pcall(function() list:updateView(true) end)
        end
    elseif not forceReload and page ~= nil and type(page._populateMdCommodityRow) == "function" then
        -- Light: data table already replaced; repaint visible cell texts in place.
        local elements = list.elements
        if type(elements) == "table" then
            for _, cell in pairs(elements) do
                local idx = cell and cell.rowDataIndex
                if type(idx) == "number" and idx >= 1 then
                    pcall(function() page:_populateMdCommodityRow(idx, cell) end)
                end
            end
        end
    end

    -- Selection highlight: quiet index only (no reload), suppressed so restoring the
    -- highlight cannot echo back through the delegate as a new player selection, and
    -- skipped entirely when the list already sits on the right row. Re-asserting the
    -- index on every 2s light tick was itself a way for the highlight to get nudged.
    if _selectedFillType ~= nil and rows ~= nil then
        for i, r in ipairs(rows) do
            if r.fillTypeIndex == _selectedFillType then
                -- getSelectedIndex does not exist on SmoothListElement; the real probe is
                -- getSelectedIndexInSection, so this test was always false and the branch
                -- below ran on every light tick. With a working probe it runs only when the
                -- list is genuinely on the wrong row.
                local already = false
                if type(list.getSelectedIndexInSection) == "function" then
                    local ok, cur = pcall(function() return list:getSelectedIndexInSection() end)
                    already = ok and cur == i
                end
                -- NOTE: SmoothListElement publishes no setter either - its API is
                -- getSelectedIndexInSection / getSelectedPath / applyElementSelection. This
                -- guarded call has therefore always been inert. Left in place because it
                -- costs nothing and becomes correct if a setter ever appears; the highlight
                -- itself is owned by the element via activateInput.
                if not already and type(list.setSelectedIndex) == "function" then
                    _suppressSelectionCallback = true
                    pcall(function() list:setSelectedIndex(i) end)
                    _suppressSelectionCallback = false
                end
                break
            end
        end
    end
end

local function paintDetail(container)
    local cropEl = findDescendant(container, "mdDetailCommodity")
    local priceEl = findDescendant(container, "mdDetailPrice")
    local pressEl = findDescendant(container, "mdDetailPressure")
    local emptyEl = findDescendant(container, "mdDetailEmpty")

    local mdm = getMdm()
    local engine = mdm and mdm.marketEngine
    local ft = _selectedFillType
    local has = ft ~= nil and engine ~= nil

    for _, el in ipairs({ cropEl, priceEl, pressEl }) do
        setVis(el, has)
    end
    setVis(emptyEl, false)
    setText(emptyEl, "")
    if not has then
        -- Pick-crop lives on mdGraphEmptyHint only (no H1 / dual shout).
        return
    end

    local pct = engine:getPriceChangePercent(ft) or 0
    local price = engine:getPrice(ft)

    setText(cropEl, fillTypeTitle(ft))
    setTextColor(cropEl, unpack(COLOR_LIME))

    -- PB-02. The selected-crop line reads the same as the row it came from. Before this it
    -- printed the raw per-litre engine number through formatMoney, which is the same zero-
    -- decimal, no-unit reading that made the table say "£0". MDMPriceFormat is the one place
    -- that decides how a market price is written; the guard keeps the old string if the
    -- helper file ever fails to load rather than blanking the line.
    local priceText = formatMoney(price)
    if MDMPriceFormat ~= nil then
        priceText = MDMPriceFormat.price(ft, price)
    end
    local priceLine = string.format("%s  ·  %s", priceText, formatSignedPct(pct))
    setText(priceEl, priceLine)
    if pct > 0.5 then
        setTextColor(priceEl, unpack(COLOR_UP))
    elseif pct < -0.5 then
        setTextColor(priceEl, unpack(COLOR_DOWN))
    else
        setTextColor(priceEl, unpack(COLOR_FLAT))
    end

    local coach, coachColor = pressureCoach(pct)
    setText(pressEl, coach)
    setTextColor(pressEl, unpack(coachColor or COLOR_FLAT))
end

local function ensureGraphHistorySeed(fillTypeIndex)
    if fillTypeIndex == nil or _historySeeded[fillTypeIndex] then
        return
    end
    local graph = mdGraphClass()
    if graph == nil or type(graph.seedFromHistory) ~= "function" then
        return
    end
    local count = 0
    if type(graph.getSampleCount) == "function" then
        count = graph.getSampleCount(fillTypeIndex) or 0
    end
    if count >= 2 then
        _historySeeded[fillTypeIndex] = true
        return
    end
    local mdm = getMdm()
    local engine = mdm and mdm.marketEngine
    if engine == nil or type(engine.getPriceHistory) ~= "function" then
        return
    end
    local history = engine:getPriceHistory(fillTypeIndex)
    if history ~= nil and #history >= 2 then
        -- One-time only; never invent samples (George G3).
        if graph.seedFromHistory(fillTypeIndex, history) then
            _historySeeded[fillTypeIndex] = true
        end
    end
end

local function paintGraphHints(container)
    local titleEl = findDescendant(container, "mdGraphTitle")
    local emptyEl = findDescendant(container, "mdGraphEmptyHint")
    setText(titleEl, tr("md_rf_pda_graph_title", "Price trend"))

    local count = 0
    if _selectedFillType ~= nil then
        ensureGraphHistorySeed(_selectedFillType)
        local graph = mdGraphClass()
        if graph ~= nil and type(graph.getSampleCount) == "function" then
            count = graph.getSampleCount(_selectedFillType) or 0
        end
        -- Brief: samples OR MarketEngine history length >= 2 hides the empty hint.
        if count < 2 then
            local mdm = getMdm()
            local engine = mdm and mdm.marketEngine
            if engine ~= nil and type(engine.getPriceHistory) == "function" then
                local history = engine:getPriceHistory(_selectedFillType)
                if type(history) == "table" then
                    count = math.max(count, #history)
                end
            end
        end
    end
    -- Graph draws under the table (BUILD 10:10). Honest empties only: pick crop /
    -- not enough history. Never deny with "open full Market for the chart".
    if _selectedFillType == nil then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_esc_graph_pick",
            "Pick a crop in the table to see its price trend."))
    elseif count < 2 then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_esc_graph_thin",
            "Not enough price history yet - the trend line appears as prices build across in-game days."))
    else
        -- Hide the hint and let MDMMarketScreenGraph.draw own the area.
        setVis(emptyEl, false)
        setText(emptyEl, "")
    end
end

local function eventsSignature(events)
    if events == nil or #events == 0 then
        return "empty"
    end
    local parts = {}
    for _, e in ipairs(events) do
        table.insert(parts, string.format("%s:%.2f:%s", tostring(e.id), tonumber(e.intensity) or 0, tostring(e.endsAt)))
    end
    return table.concat(parts, "|")
end


local function clearPricesBandGhosts(container)
    -- Events/Contracts must not show Prices empty/detail leftovers.
    for _, id in ipairs({
        "mdGraphTitle", "mdDetailCommodity", "mdDetailPrice", "mdDetailPressure",
        "mdDetailEmpty", "mdGraphEmptyHint",
    }) do
        local el = findDescendant(container, id)
        setText(el, "")
        if id == "mdDetailEmpty" or id == "mdGraphEmptyHint" then
            setVis(el, false)
        end
    end
end

local function paintEventsBand(container)
    clearPricesBandGhosts(container)
    setText(findDescendant(container, "mdEventsTitle"), tr("md_rf_pda_page_events", "Events"))
    setText(findDescendant(container, "mdEvColName"), tr("md_rf_pda_ev_col_name", "Event"))
    setText(findDescendant(container, "mdEvColIntensity"), tr("md_rf_pda_ev_col_intensity", "Intensity"))
    setText(findDescendant(container, "mdEvColTime"), tr("md_rf_pda_ev_col_time", "Time left"))

    local mdm = getMdm()
    local worldEvents = mdm and mdm.worldEvents
    local events = {}
    if worldEvents ~= nil and type(worldEvents.getActiveEvents) == "function" then
        events = worldEvents:getActiveEvents() or {}
    end
    _lastEventsSig = eventsSignature(events)

    local emptyEl = findDescendant(container, "mdEventsEmpty")
    if #events == 0 then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_events_none", "no active market events"))
        for i = 1, MAX_EVENT_ROWS do
            setVis(findDescendant(container, "mdEvRow" .. i .. "Name"), false)
            setVis(findDescendant(container, "mdEvRow" .. i .. "Intensity"), false)
            setVis(findDescendant(container, "mdEvRow" .. i .. "Time"), false)
        end
        setText(findDescendant(container, "mdEvMore"), "")
        return
    end

    setVis(emptyEl, false)
    setText(emptyEl, "")
    local show = math.min(#events, MAX_EVENT_ROWS)
    for i = 1, MAX_EVENT_ROWS do
        local nameEl = findDescendant(container, "mdEvRow" .. i .. "Name")
        local intEl = findDescendant(container, "mdEvRow" .. i .. "Intensity")
        local timeEl = findDescendant(container, "mdEvRow" .. i .. "Time")
        if i <= show then
            local e = events[i]
            setVis(nameEl, true)
            setVis(intEl, true)
            setVis(timeEl, true)
            setText(nameEl, tostring(e.name or e.id or "?"))
            setText(intEl, intensityBand(e.intensity))
            local rem = formatRemaining(e.endsAt)
            setText(timeEl, rem or tr("md_rf_pda_remaining_unknown", "time unknown"))
            setTextColor(nameEl, unpack(COLOR_LIME))
        else
            setVis(nameEl, false)
            setVis(intEl, false)
            setVis(timeEl, false)
        end
    end
    local moreEl = findDescendant(container, "mdEvMore")
    if #events > MAX_EVENT_ROWS then
        setText(moreEl, string.format(tr("md_rf_pda_events_more", "and %d more"), #events - MAX_EVENT_ROWS))
    else
        setText(moreEl, "")
    end
end

local function contractStatusLabel(contract)
    if contract == nil then
        return "-"
    end
    local status = contract.status or "active"
    if status == "fulfilled" then
        return tr("mdm_futures_fulfill", "Fulfilled")
    end
    if status == "defaulted" then
        return tr("mdm_futures_defaulted", "Defaulted")
    end
    local delivered = tonumber(contract.delivered) or 0
    local qty = tonumber(contract.quantity) or 0
    local pct = qty > 0 and (delivered / qty) or 0
    if MDMUtil ~= nil and type(MDMUtil.getGameTime) == "function" and contract.deliveryTime ~= nil then
        local now = MDMUtil.getGameTime()
        if now ~= nil and now > 0 then
            local remaining = math.max(0, contract.deliveryTime - now)
            if remaining < (3 * 24 * 60 * 60000) and pct < 0.5 then
                return tr("mdm_screen_at_risk", "At risk")
            end
        end
    end
    return tr("mdm_futures_active", "Active")
end

local function contractsSignature(list)
    if list == nil or #list == 0 then
        return "empty"
    end
    local parts = {}
    for _, c in ipairs(list) do
        table.insert(parts, string.format("%s:%s:%s",
            tostring(c.id or c.fillTypeIndex), tostring(c.status), tostring(c.quantity)))
    end
    return table.concat(parts, "|")
end

local function paintContractsBand(container)
    clearPricesBandGhosts(container)
    local mdm = getMdm()
    local fm = mdm and mdm.futuresMarket
    local fid = farmId()
    local list = {}
    if fm ~= nil and fid ~= nil and fid ~= 0 and type(fm.getContractsForFarm) == "function" then
        list = fm:getContractsForFarm(fid) or {}
    end
    -- Prefer open/active for Esc glance; still show others if only those exist.
    local open = {}
    for _, c in ipairs(list) do
        local st = c.status or "active"
        if st == "active" then
            table.insert(open, c)
        end
    end
    if #open == 0 then
        open = list
    end
    _lastContractsSig = contractsSignature(open)

    local n = #open
    local title = findDescendant(container, "mdContractsTitle")
    -- Steady RF_SectionTitle; empty coach stays on mdContractsEmpty only (FAIL B).
    setText(title, string.format(tr("md_rf_pda_contracts_open", "Open contracts: %d"), n))
    setText(findDescendant(container, "mdCtColCrop"), tr("md_rf_pda_col_crop", "Crop"))
    setText(findDescendant(container, "mdCtColQty"), tr("md_rf_pda_ct_col_qty", "Quantity"))
    setText(findDescendant(container, "mdCtColPrice"), tr("md_rf_pda_ct_col_price", "Locked price"))
    setText(findDescendant(container, "mdCtColStatus"), tr("md_rf_pda_ct_col_status", "Status"))

    local emptyEl = findDescendant(container, "mdContractsEmpty")
    if n <= 0 then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_contracts_none", "no open contracts"))
        for i = 1, MAX_CONTRACT_ROWS do
            setVis(findDescendant(container, "mdCtRow" .. i .. "Crop"), false)
            setVis(findDescendant(container, "mdCtRow" .. i .. "Qty"), false)
            setVis(findDescendant(container, "mdCtRow" .. i .. "Price"), false)
            setVis(findDescendant(container, "mdCtRow" .. i .. "Status"), false)
        end
        setText(findDescendant(container, "mdCtMore"), "")
        return
    end

    setVis(emptyEl, false)
    setText(emptyEl, "")
    local show = math.min(n, MAX_CONTRACT_ROWS)
    for i = 1, MAX_CONTRACT_ROWS do
        local cropEl = findDescendant(container, "mdCtRow" .. i .. "Crop")
        local qtyEl = findDescendant(container, "mdCtRow" .. i .. "Qty")
        local priceEl = findDescendant(container, "mdCtRow" .. i .. "Price")
        local statusEl = findDescendant(container, "mdCtRow" .. i .. "Status")
        if i <= show then
            local c = open[i]
            setVis(cropEl, true)
            setVis(qtyEl, true)
            setVis(priceEl, true)
            setVis(statusEl, true)
            setText(cropEl, tostring(c.fillTypeName or fillTypeTitle(c.fillTypeIndex) or "?"))
            local qty = tonumber(c.quantity) or 0
            setText(qtyEl, string.format("%.0f L", qty))
            local locked = tonumber(c.lockedPrice) or 0
            setText(priceEl, string.format("%s / 1,000L", formatMoney(locked * 1000)))
            setText(statusEl, contractStatusLabel(c))
            setTextColor(cropEl, unpack(COLOR_LIME))
        else
            setVis(cropEl, false)
            setVis(qtyEl, false)
            setVis(priceEl, false)
            setVis(statusEl, false)
        end
    end
    local moreEl = findDescendant(container, "mdCtMore")
    if n > MAX_CONTRACT_ROWS then
        setText(moreEl, string.format(tr("md_rf_pda_contracts_more", "and %d more open deals not shown here"), n - MAX_CONTRACT_ROWS))
    else
        setText(moreEl, "")
    end
end

-- =========================================================
-- BUILD 10:47 (George CLOSED DESIGN 10:37): page D Event Settings + New Contract card.
-- Everything below is fixed Text / Button elements in the 432px strip: no SmoothList, no
-- reloadData, no dialog inlined. Gates are the same ones full Market uses.
-- =========================================================

--- Same gate as MarketScreen:onEventSettingsClick / MDMEventSettingsDialog:onOpen.
local function isEventAdmin()
    if g_currentMission == nil then
        return false
    end
    local isServer = false
    if type(g_currentMission.getIsServer) == "function" then
        isServer = g_currentMission:getIsServer() == true
    end
    return isServer or g_currentMission.isAdmin == true or g_currentMission.isMasterUser == true
end

--- Same gate as MarketScreen:openContractDialog: BetterContracts owns the futures flow.
local function bcOwnsContracts()
    return BCIntegration ~= nil and type(BCIntegration.isEnabled) == "function" and BCIntegration.isEnabled() == true
end

local function fmtInt(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    local s = tostring(n)
    local rev = s:reverse():gsub("(%d%d%d)", "%1,")
    local out = rev:reverse()
    if out:sub(1, 1) == "," then
        out = out:sub(2)
    end
    return out
end

--- The crop the New Contract card contracts for: the top-table pick, priced by the engine
--- entry the full Market screen uses (entry.current is the locked price there too).
local function ncSelectedCrop()
    local mdm = getMdm()
    local engine = mdm and mdm.marketEngine
    local ft = _selectedFillType
    if ft == nil or engine == nil or engine.prices == nil then
        return nil
    end
    local entry = engine.prices[ft]
    if entry == nil or entry.current == nil then
        return nil
    end
    return { fillTypeIndex = ft, title = fillTypeTitle(ft), current = entry.current, base = entry.base }
end

--- Store the chip state on the element and blank its TextElement label: the label and the
--- chip must never draw at once (CsRfPdaGuest setPivotBtn). No "dead" state here: the card
--- always has a market behind it; BetterContracts / no futures market is gated grey.
local function setNcBtn(container, id, label, enabled, latched)
    local el = findDescendant(container, id)
    if el == nil then return end
    if el.setVisible then el:setVisible(true) end
    if el.setText then el:setText("") end
    el.rfNcChipLabel = label
    el.rfNcChipEnabled = enabled and true or false
    el.rfNcChipLatched = latched and true or false
    if type(el.setDisabled) == "function" then
        el:setDisabled(not enabled)
    end
end

--- Paint one plate as a vanilla key chip, centred in its hit box (CsRfPdaGuest renderPivotChip).
local function renderNcChip(el, overlay)
    local label = el.rfNcChipLabel
    if label == nil or label == "" then return end
    if el.absPosition == nil or el.absSize == nil then return end
    if el.visible == false then return end
    -- Chip height rides the hit box: 0.72 of the 32px row lands on the vanilla 30px icon feel.
    local height = el.absSize[2] * 0.72
    if height <= 0 then return end
    local enabled = el.rfNcChipEnabled
    local t, b, ta, ba
    if enabled and el.rfNcChipLatched then
        -- LATCHED (the selected quantity / window): true invert, dark text on lime fill.
        t, b, ta, ba = NC_CHIP_BG, NC_CHIP_TEXT, 1.0, 1.0
    elseif enabled then
        t, b, ta, ba = NC_CHIP_TEXT, NC_CHIP_BG, 1.0, 1.0
    else
        -- GATED: legible, nothing green.
        t, b, ta, ba = NC_CHIP_GATED_TEXT, NC_CHIP_GATED_BG, 0.45, 0.55
    end
    overlay:setColor(t[1], t[2], t[3], ta, b[1], b[2], b[3], ba)
    -- getButtonWidth hugs the label. The overlay is SHARED with the rest of the game UI, so
    -- never setMinWidth here. The chip sits centred in the XML box; clicks route on the box.
    local width = overlay:getButtonWidth(label, height)
    local x = el.absPosition[1] + (el.absSize[1] - width) * 0.5
    local y = el.absPosition[2] + (el.absSize[2] - height) * 0.5
    overlay:renderButton(label, x, y, height, true)
end

--- Wrap the New Contract card's draw once so the chips repaint every frame while the card is
--- visible. The light tick only refreshes labels and enable state; nothing is re-wrapped.
local function wireChipPaint(container, cardId, ids, flag)
    local card = findDescendant(container, cardId)
    if card == nil or card[flag] then return end
    card[flag] = true
    local prevDraw = card.draw
    function card:draw(...)
        if prevDraw ~= nil then prevDraw(self, ...) end
        local idm = g_inputDisplayManager
        if idm == nil or type(idm.getKeyboardKeyOverlay) ~= "function" then return end
        local overlay = idm:getKeyboardKeyOverlay()
        if overlay == nil or type(overlay.renderButton) ~= "function" then return end
        for _, id in ipairs(ids) do
            local el = findDescendant(self, id) or findDescendant(container, id)
            if el ~= nil then
                pcall(renderNcChip, el, overlay)
            end
        end
        -- renderButton leaves global text state set; this draws outside the vanilla order,
        -- so put the defaults back. BUILD 20:36: the colour reset is the ENGINE global
        -- (captured as engineSetTextColor above), never the element helper.
        setTextBold(false)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
        if type(engineSetTextColor) == "function" then
            engineSetTextColor(1, 1, 1, 1)
        end
    end
end

local function wireNcChipPaint(container)
    wireChipPaint(container, "mdNewContractCard", NC_CHIP_IDS, "_rfNcChipWired")
end

local function wireEsChipPaint(container)
    wireChipPaint(container, "mdEsSummaryCard", ES_CHIP_IDS, "_rfEsChipWired")
end

local function paintNewContractCard(container)
    setText(findDescendant(container, "mdNewContractTitle"), tr("md_rf_pda_nc_title", "New contract"))
    local crop = ncSelectedCrop()
    local cropEl = findDescendant(container, "mdNcCrop")
    local priceEl = findDescendant(container, "mdNcPrice")
    if crop == nil then
        setText(cropEl, tr("md_rf_pda_nc_pick_crop", "Pick a crop in the table above"))
        setTextColor(cropEl, unpack(COLOR_FLAT))
        setText(priceEl, "")
    else
        setText(cropEl, crop.title)
        setTextColor(cropEl, unpack(COLOR_LIME))
        local priceText = formatMoney(crop.current)
        if MDMPriceFormat ~= nil and type(MDMPriceFormat.price) == "function" then
            priceText = MDMPriceFormat.price(crop.fillTypeIndex, crop.current)
        end
        local pct = 0
        if crop.base ~= nil and crop.base > 0 then
            pct = ((crop.current - crop.base) / crop.base) * 100
        end
        setText(priceEl, string.format(tr("md_rf_pda_nc_price", "Locked price %s (%s vs base)"), priceText, formatSignedPct(pct)))
    end
    setText(findDescendant(container, "mdNcQtyLabel"), tr("md_rf_pda_nc_qty", "Quantity (L)"))
    local mdm = getMdm()
    -- BUILD 15:34: the chips gate together. Futures market present and BetterContracts not owning
    -- contracts = live chips; otherwise every chip paints grey and is disabled, so a gated click
    -- never reaches onNcQty / onNewContract. The selected quantity and window are latched;
    -- Confirm also needs a picked crop and is never latched.
    local chipsLive = mdm ~= nil and mdm.futuresMarket ~= nil and not bcOwnsContracts()
    for _, q in ipairs(NC_QTY_PRESETS) do
        setNcBtn(container, "mdNcQty" .. q, fmtInt(q), chipsLive, q == _ncQty)
    end
    local isRealDays = mdm ~= nil and mdm.settings ~= nil and mdm.settings.useRealDays == true
    local unit = isRealDays and tr("mdm_unit_real_days", "Real Days") or tr("mdm_unit_game_days", "In-Game Days")
    -- The unit rides the Deliver in label (full card width in the XML) so it never sits on the
    -- 120 plate; mdNcDaysUnit stays in the XML for the id binding and is kept empty.
    setText(findDescendant(container, "mdNcDaysLabel"), string.format(tr("md_rf_pda_nc_window_unit", "Deliver in (%s)"), unit))
    for _, d in ipairs(NC_DAY_PRESETS) do
        setNcBtn(container, "mdNcDays" .. d, tostring(d), chipsLive, d == _ncDays)
    end
    setText(findDescendant(container, "mdNcDaysUnit"), "")
    -- BUILD 11:42: the total is six adjacent Text nodes so only the money and the days number
    -- paint yellow (RF_ProductCell); a Giants TextElement is one colour.
    local money = ""
    if crop ~= nil then
        local total = crop.current * _ncQty
        money = formatMoney(total)
        if MDMPriceFormat ~= nil and type(MDMPriceFormat.money) == "function" then
            money = MDMPriceFormat.money(total)
        end
    end
    setText(findDescendant(container, "mdNcSumLabel"), crop ~= nil and tr("md_rf_pda_nc_total_label", "Total") or "")
    setText(findDescendant(container, "mdNcSumMoney"), money)
    setText(findDescendant(container, "mdNcSumFor"), crop ~= nil and string.format(tr("md_rf_pda_nc_total_for", "for %s L"), fmtInt(_ncQty)) or "")
    setText(findDescendant(container, "mdNcSumWinLabel"), tr("md_rf_pda_nc_window", "Deliver in"))
    setText(findDescendant(container, "mdNcSumDays"), tostring(_ncDays))
    setText(findDescendant(container, "mdNcSumUnit"), unit)
    local hint = _ncFeedback
    if hint == nil then
        if bcOwnsContracts() then
            hint = tr("md_rf_pda_nc_bc_active", "FS25_FuturesMission is active and owns contract creation; this card is off.")
        elseif mdm == nil or mdm.futuresMarket == nil then
            hint = tr("md_rf_pda_nc_no_market", "Futures market unavailable.")
        else
            hint = tr("mdm_default_penalty_hint", "Default penalty: 15% on unfulfilled qty")
        end
    end
    setText(findDescendant(container, "mdNcHint"), hint)
    setNcBtn(container, "mdNewContractBtn", tr("md_rf_pda_nc_confirm", "Confirm contract"), chipsLive and crop ~= nil, false)
end

local function paintEventSettingsBand(container)
    clearPricesBandGhosts(container)
    local mdm = getMdm()
    local s = mdm and mdm.settings or nil
    local we = mdm and mdm.worldEvents or nil
    -- BUILD 16:42: the right card names itself (no Event Settings tab any more).
    setText(findDescendant(container, "mdEventSettingsTitle"), tr("md_rf_pda_es_title", "Event settings"))
    local onOff = (s ~= nil and s.eventsEnabled ~= false) and tr("md_rf_pda_on", "On") or tr("md_rf_pda_off", "Off")
    setText(findDescendant(container, "mdEsGlobal"), string.format(tr("md_rf_pda_es_global", "Market events: %s"), onOff))
    -- Same thresholds as MDMEventSettingsDialog:_refreshGlobal (0.4 / 1.0 / 2.0).
    local freq = (s ~= nil and tonumber(s.eventFrequency)) or 1.0
    local freqLabel
    if math.abs(freq - 0.4) < 0.05 then
        freqLabel = tr("mdm_freq_rare", "Rare")
    elseif math.abs(freq - 1.0) < 0.05 then
        freqLabel = tr("mdm_freq_normal", "Normal")
    else
        freqLabel = tr("mdm_freq_frequent", "Frequent")
    end
    setText(findDescendant(container, "mdEsFreq"), string.format(tr("md_rf_pda_es_freq", "Frequency: %s"), freqLabel))
    local rows = {}
    local disabled = (s ~= nil and s.disabledEvents) or {}
    local active = (we ~= nil and we.active) or {}
    if we ~= nil and type(we.registry) == "table" then
        for id, ev in pairs(we.registry) do
            local name = nil
            if MDMUtil ~= nil and type(MDMUtil.resolveEventName) == "function" then
                local ok, n = pcall(MDMUtil.resolveEventName, ev)
                if ok and type(n) == "string" and n ~= "" then
                    name = n
                end
            end
            if name == nil then
                name = tostring((type(ev) == "table" and ev.name) or id)
            end
            table.insert(rows, { id = id, name = name, disabled = disabled[id] == true, active = active[id] ~= nil })
        end
        table.sort(rows, function(a, b) return a.name < b.name end)
    end
    local total, enabledCount, activeNames = #rows, 0, {}
    for _, r in ipairs(rows) do
        if not r.disabled then
            enabledCount = enabledCount + 1
        end
        if r.active then
            table.insert(activeNames, r.name)
        end
    end
    setText(findDescendant(container, "mdEsEnabled"), string.format(tr("md_rf_pda_es_enabled", "Events enabled: %d of %d"), enabledCount, total))
    local activeText = (#activeNames > 0) and table.concat(activeNames, ", ") or tr("md_rf_pda_es_active_none", "none")
    setText(findDescendant(container, "mdEsActive"), string.format(tr("md_rf_pda_es_active", "Active now: %s"), activeText))
    -- BUILD 16:42: the per-event EVENT / STATE list does not fit the 550px card (George measured);
    -- it lives in the dialog behind the plate. The summary lines above carry the counts.
    local hintEl = findDescendant(container, "mdEsHint")
    if isEventAdmin() then
        setText(hintEl, tr("md_rf_pda_es_hint_admin", "Read-only here. Event settings... opens the full dialog: global on/off, frequency, per-event rules and fill types."))
    else
        setText(hintEl, tr("md_rf_pda_es_hint_host_only", "Host only: the server host or an admin changes market events. This page stays read-only for everyone else."))
    end
    -- BUILD 20:36: the plate paints as an overlay chip (idle = lime text on dark, gated grey when
    -- the player is not host / admin / master), never a white text link. Button text stays "".
    setNcBtn(container, "mdEventSettingsBtn", tr("md_rf_pda_es_open_btn", "Event settings..."), isEventAdmin(), false)
end

--- The one request path: MDMContractRequestEvent ACTION_CREATE with the same params
--- MarketScreen:_onContractConfirmed sends. delivDays arrives already converted for
--- real-days mode (MDMContractDialog:onConfirmClick does that before its callback; the
--- compact card does the same conversion in onNewContract).
local function ncSendRequest(crop, qty, delivDays, isRealDays, ts)
    local mdm = getMdm()
    if mdm == nil or mdm.futuresMarket == nil then
        return false, tr("md_rf_pda_nc_no_market", "Futures market unavailable.")
    end
    if MDMContractRequestEvent == nil or type(MDMContractRequestEvent.sendToServer) ~= "function" then
        return false, tr("md_rf_pda_nc_no_market", "Futures market unavailable.")
    end
    local fid = farmId()
    if fid == nil or fid == 0 then
        return false, tr("md_rf_pda_nc_no_farm", "No farm to contract for.")
    end
    local now = 0
    if MDMUtil ~= nil and type(MDMUtil.getGameTime) == "function" then
        now = MDMUtil.getGameTime() or 0
    end
    local deliveryTimeMs = now + (delivDays * 24 * 60 * 60000)
    MDMContractRequestEvent.sendToServer(MDMContractRequestEvent.ACTION_CREATE, {
        farmId           = fid,
        fillTypeIndex    = crop.fillTypeIndex,
        fillTypeName     = crop.title,
        quantity         = qty,
        lockedPrice      = crop.current,
        deliveryTimeMs   = deliveryTimeMs,
        isRealDays       = isRealDays or false,
        createdTimeScale = ts or 1,
    })
    print(string.format("[MarketDynamics] Esc New Contract: request sent %s %dL @ %.4f/L deliver in %d days (realDays=%s)",
        tostring(crop.title), qty, crop.current or 0, delivDays, tostring(isRealDays)))
    return true
end

local function ncBlockedByBc(container)
    if not bcOwnsContracts() then
        return false
    end
    local msg = tr("mdm_bc_dialog_suppressed",
        "FS25_FuturesMission is active and handles contract creation. Use the Contracts page (ESC menu) to create futures contracts.")
    if InfoDialog ~= nil and type(InfoDialog.show) == "function" then
        pcall(InfoDialog.show, msg)
    end
    _ncFeedback = msg
    paintNewContractCard(container)
    return true
end

function MdRfPdaGuest.onNcQty(container, element)
    local id = element ~= nil and element.id or nil
    local q = id ~= nil and tonumber(string.match(tostring(id), "^mdNcQty(%d+)$")) or nil
    if q == nil then
        return
    end
    _ncQty = q
    _ncFeedback = nil
    paintNewContractCard(container)
end

function MdRfPdaGuest.onNcDays(container, element)
    local id = element ~= nil and element.id or nil
    local d = id ~= nil and tonumber(string.match(tostring(id), "^mdNcDays(%d+)$")) or nil
    if d == nil then
        return
    end
    _ncDays = d
    _ncFeedback = nil
    paintNewContractCard(container)
end

--- Compact confirm: crop from the top table, quantity + window from the chips. The only
--- create path on Esc since BUILD 11:42 (Full form dropped); the 920x850 dialog stays full Market only.
function MdRfPdaGuest.onNewContract(container)
    if ncBlockedByBc(container) then
        return
    end
    local crop = ncSelectedCrop()
    if crop == nil then
        _ncFeedback = tr("md_rf_pda_nc_pick_crop", "Pick a crop in the table above")
        paintNewContractCard(container)
        return
    end
    local mdm = getMdm()
    local isRealDays = mdm ~= nil and mdm.settings ~= nil and mdm.settings.useRealDays == true
    local ts = (g_currentMission ~= nil and g_currentMission.timeScale) or 1
    local delivDays = _ncDays
    if isRealDays then
        -- 1 real day = timeScale game days (MDMContractDialog:onConfirmClick).
        delivDays = delivDays * ts
    end
    local ok, why = ncSendRequest(crop, _ncQty, delivDays, isRealDays, ts)
    if ok then
        _ncFeedback = string.format(tr("md_rf_pda_nc_sent", "Contract request sent: %s, %s L. It shows on the left when the server confirms."),
            crop.title, fmtInt(_ncQty))
    else
        _ncFeedback = why
    end
    paintNewContractCard(container)
end

--- Page D button. Non-admins get the host-only hint, never the dialog (George #3).
function MdRfPdaGuest.onEventSettings(container)
    if not isEventAdmin() then
        setText(findDescendant(container, "mdEsHint"),
            tr("md_rf_pda_es_hint_host_only", "Host only: the server host or an admin changes market events. This page stays read-only for everyone else."))
        return
    end
    if MDMDialogLoader == nil or type(MDMDialogLoader.show) ~= "function" then
        return
    end
    MDMDialogLoader.show("MDMEventSettingsDialog", "setData", {
        onClose = function() end,
    })
end

local function paintBottomByPage(container)
    local idx = currentPageIndex()
    if idx == PAGE_PRICES then
        paintDetail(container)
        paintGraphHints(container)
        local area = findDescendant(container, "mdGraphArea")
        if area ~= nil and type(area.updateAbsolutePosition) == "function" then
            area:updateAbsolutePosition()
        end
    elseif idx == PAGE_EVENTS then
        -- BUILD 16:42: the Events page is two cards; the right one is the Event Settings summary.
        paintEventsBand(container)
        paintEventSettingsBand(container)
    else
        paintContractsBand(container)
        paintNewContractCard(container)
    end
end

---@param container table|nil
---@param lightOnly boolean|nil
function MdRfPdaGuest.onShow(container, lightOnly)
    setText(findDescendant(container, "rfHostBody"), "")
    -- One header voice: rfPageTitle / rfPageBlurb only. Do not dual-paint host strip.
    local hostTitle = findDescendant(container, "rfHostTitle")
    local hostBlurb = findDescendant(container, "rfHostBlurb")
    setText(hostTitle, "")
    setText(hostBlurb, "")
    setVis(hostTitle, false)
    setVis(hostBlurb, false)

    paintSideInfo(container)
    paintTableHeaders(container)
    -- BUILD 15:34: idempotent (guard flag on the card element); the chips then repaint each frame.
    wireNcChipPaint(container)
    -- BUILD 20:36: the Event settings plate on the Events card paints the same way.
    wireEsChipPaint(container)

    local page = getHostPage()
    if page ~= nil then
        page.mdSubPageIndex = clampPageIndex(page.mdSubPageIndex or PAGE_PRICES)
        if type(page._seedMdSubnavTexts) == "function" then
            page:_seedMdSubnavTexts()
        end
        if type(page._syncMdSubPageVisibility) == "function" then
            page:_syncMdSubPageVisibility()
        end
    end

    local rows = MdRfPdaGuest.buildCommodities()
    -- Only ever fall back to row 1 when there is genuinely nothing to keep. A valid
    -- selection is never re-defaulted, because with a title sort row 1 is ADS Coolant
    -- Premium and any stray re-default reads to the player as the old ADS snap.
    if _selectedFillType == nil then
        _selectedFillType = defaultSelection(rows)
    else
        local still = false
        for _, r in ipairs(rows) do
            if r.fillTypeIndex == _selectedFillType then
                still = true
                break
            end
        end
        if not still then
            print(string.format("[MarketDynamics] selection %s no longer in commodity list - falling back to first row",
                tostring(_selectedFillType)))
            _selectedFillType = defaultSelection(rows)
        end
    end

    if page ~= nil then
        page.mdSelectedFillType = _selectedFillType
    end

    -- Table: full reload only when not lightOnly or signature changed.
    syncCommodityList(container, rows, not lightOnly)
    paintBottomByPage(container)

    local region = findDescendant(container, "mdTableRegion")
    if region ~= nil and type(region.updateAbsolutePosition) == "function" then
        region:updateAbsolutePosition()
    end
    local band = findDescendant(container, "mdPageBand")
    if band ~= nil and type(band.updateAbsolutePosition) == "function" then
        band:updateAbsolutePosition()
    end
end

--- BUILD 22:27: the 2s price refresh, and nothing else.
---
--- The host used to call onShow(container, true) on this timer. That path runs three
--- updateAbsolutePosition calls (mdTableRegion, mdPageBand, mdGraphArea), re-seeds the
--- subnav, re-runs the page visibility sync, rebuilds the commodity table and re-asserts
--- the selection - twice a second. Re-laying out the table that often is what kept
--- nudging the scroll position, and none of it is needed to make digits current.
---
--- So this does the minimum: fresh rows into the data source, repaint the cells that are
--- actually on screen, then the detail and graph hint text. No UAP, no visibility sync,
--- no subnav seed, no reloadData, and no selection write of any kind - the player owns
--- the highlight between full shows.
function MdRfPdaGuest.onLightTick(container)
    local page = getHostPage()
    if page == nil then
        return
    end
    if currentPageIndex() == PAGE_PRICES then
        local rows = MdRfPdaGuest.buildCommodities()
        page.mdCommodityData = rows or {}
        -- Signature kept current so the next FULL show does not see a phantom change
        -- and reload a table that is already correct.
        _commoditySig = commoditiesSignature(rows)
        local list = page.mdCommodityList
        if list ~= nil and type(page._populateMdCommodityRow) == "function" then
            local elements = list.elements
            if type(elements) == "table" then
                for _, cell in pairs(elements) do
                    local idx = cell and cell.rowDataIndex
                    if type(idx) == "number" and idx >= 1 then
                        pcall(function() page:_populateMdCommodityRow(idx, cell) end)
                    end
                end
            end
        end
        paintDetail(container)
        paintGraphHints(container)
    elseif currentPageIndex() == PAGE_EVENTS then
        paintEventsBand(container)
        paintEventSettingsBand(container)
    else
        paintContractsBand(container)
        -- Price and window can move between ticks; the summary line follows them.
        paintNewContractCard(container)
    end
end

function MdRfPdaGuest.onHide()
    _commoditySig = nil
    _lastEventsSig = nil
    _lastContractsSig = nil
    _ncFeedback = nil
end

function MdRfPdaGuest.getSelectedFillType()
    return _selectedFillType
end

function MdRfPdaGuest.selectCommodityIndex(index)
    -- Ignore selection callbacks raised by our own highlight restore during a sync.
    -- Without this, restoring the highlight can echo back through the delegate and
    -- overwrite the player's real choice with whatever row the list settled on.
    if _suppressSelectionCallback then
        return
    end
    local page = getHostPage()
    local rows = (page and page.mdCommodityData) or {}
    local row = rows[index]
    if row == nil or row.fillTypeIndex == nil then
        return
    end
    _selectedFillType = row.fillTypeIndex
    if page ~= nil then
        page.mdSelectedFillType = _selectedFillType
    end
    local container = (page and page.rfHostPlaceholder) or page
    if currentPageIndex() == PAGE_PRICES then
        paintDetail(container)
        paintGraphHints(container)
    end
end

-- Retired movers MTO path (kept as no-op safe hook).
function MdRfPdaGuest.onMoverChanged(_container)
    return
end

--- Stand down legacy Esc rail if it was injected; prefer never-injected path.
--- When cleaning a stale inject: use PagingElement:removeElement (clears idPageHash) and
--- clear TabbedMenu pageTabs / pageEnablingPredicates / pageRoots / pageTypeControllers
--- left by registerPage+addPageTab (ENGINE George 2026-08-04). Do NOT only table.remove.
function MdRfPdaGuest.standDownLegacyEsc()
    if _legacyStoodDown then
        return true
    end
    -- Preferred path: MarketScreen never called addPageTab (RF door hosts).
    if MdRfPdaGuest._legacyNeverInjected then
        _legacyStoodDown = true
        return true
    end
    if g_gui == nil then
        return false
    end

    local inGameMenu = g_gui.screenControllers and g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil then
        return false
    end

    local pageName = MDMMarketScreen and MDMMarketScreen.MENU_PAGE_NAME or "menuMarketDynamics"
    local screen = inGameMenu[pageName]
    if screen == nil then
        if MDMMarketScreen ~= nil and MDMMarketScreen._retainedDeepScreen ~= nil then
            _legacyStoodDown = true
            return true
        end
        return false
    end

    if MDMMarketScreen ~= nil then
        MDMMarketScreen._retainedDeepScreen = screen
    end

    local ok = pcall(function()
        if inGameMenu.pageTabs ~= nil then
            inGameMenu.pageTabs[screen] = nil
        end
        if inGameMenu.pageEnablingPredicates ~= nil then
            inGameMenu.pageEnablingPredicates[screen] = nil
        end
        if inGameMenu.pageRoots ~= nil then
            inGameMenu.pageRoots[screen] = nil
        end
        if inGameMenu.pageTypeControllers ~= nil and type(screen.class) == "function" then
            inGameMenu.pageTypeControllers[screen:class()] = nil
        end

        if inGameMenu.pageFrames ~= nil then
            for i = #inGameMenu.pageFrames, 1, -1 do
                if inGameMenu.pageFrames[i] == screen then
                    table.remove(inGameMenu.pageFrames, i)
                end
            end
        end

        if inGameMenu.pagingElement ~= nil then
            local pe = inGameMenu.pagingElement
            local inPaging = false
            if pe.elements ~= nil then
                for _, el in ipairs(pe.elements) do
                    if el == screen then
                        inPaging = true
                        break
                    end
                end
            end
            if not inPaging and pe.pages ~= nil then
                for _, pg in ipairs(pe.pages) do
                    if pg ~= nil and pg.element == screen then
                        inPaging = true
                        break
                    end
                end
            end
            if inPaging and type(pe.removeElement) == "function" then
                pe:removeElement(screen)
            elseif inPaging then
                if pe.elements ~= nil then
                    for i = #pe.elements, 1, -1 do
                        if pe.elements[i] == screen then
                            table.remove(pe.elements, i)
                        end
                    end
                end
                if type(pe.removePageByElement) == "function" then
                    pe:removePageByElement(screen)
                elseif pe.pages ~= nil then
                    for i = #pe.pages, 1, -1 do
                        local pg = pe.pages[i]
                        if pg ~= nil and pg.element == screen then
                            if pe.idPageHash ~= nil and pg.id ~= nil then
                                pe.idPageHash[pg.id] = nil
                            end
                            table.remove(pe.pages, i)
                        end
                    end
                end
            end
            if type(pe.updateAbsolutePosition) == "function" then
                pe:updateAbsolutePosition()
            end
            if type(pe.updatePageMapping) == "function" then
                pe:updatePageMapping()
            end
        end

        if g_inGameMenu ~= nil and g_inGameMenu.controlIDs ~= nil then
            g_inGameMenu.controlIDs[pageName] = nil
        end

        inGameMenu[pageName] = nil

        if type(inGameMenu.rebuildTabList) == "function" then
            inGameMenu:rebuildTabList()
        end
        if type(inGameMenu.updatePages) == "function" then
            inGameMenu:updatePages()
        end
    end)

    if ok then
        _legacyStoodDown = true
        print("[MDM] MdRfPdaGuest: stood down legacy Esc menuMarketDynamics (Giants-safe remove; deep Market retained)")
        return true
    end
    print("[MDM] MdRfPdaGuest: legacy Esc stand-down failed (will retry)")
    return false
end

--- BUILD 12:59: re-publish on every register attempt, not only at mission onLoad.
--- onLoad publishes once; if the door bootstraps later, or a reload re-creates these
--- tables, the published handle can go stale while registration succeeds. Cheap, and it
--- keeps the mission handle true whenever the guest is actually live. getfenv is braced
--- by the mission publish rather than trusted on its own.
local function mdPublishHandles()
    local okEnv, root = pcall(getfenv, 0)
    if okEnv and type(root) == "table" then
        root["MdRfPdaGuest"] = MdRfPdaGuest
        if MDMMarketScreenGraph ~= nil then
            root["MDMMarketScreenGraph"] = MDMMarketScreenGraph
        end
        -- BUILD 14:04 (Vera FAIL SUBMIT 10:16, George TASK 10:53): MDMPriceFormat joins the
        -- publish list. It was the one cross-env class the host needed that was NOT here,
        -- so on a Dairy-hosted door every mdResolve belt missed it live (Vera's gate:
        -- via=mission is the belt that works, and this list is what feeds that belt) and
        -- the Prices rows fell to the rounded fallback. Guarded like the graph: the row
        -- cells only paint under a registered guest, and every register attempt runs this,
        -- so a painted row implies a published formatter.
        if MDMPriceFormat ~= nil then
            root["MDMPriceFormat"] = MDMPriceFormat
        end
    end
    if g_currentMission ~= nil then
        g_currentMission.MdRfPdaGuest = MdRfPdaGuest
        if MDMMarketScreenGraph ~= nil then
            g_currentMission.MDMMarketScreenGraph = MDMMarketScreenGraph
        end
        if MDMPriceFormat ~= nil then
            g_currentMission.MDMPriceFormat = MDMPriceFormat
        end
    end
end

function MdRfPdaGuest.tryRegister()
    mdPublishHandles()
    if RfEscBootstrap ~= nil then
        if MOD_DIR == nil then
            print("[MDM] MdRfPdaGuest: WARNING MOD_DIR nil - cannot ensureDoor")
        else
            local doorOk = RfEscBootstrap.ensureDoor(MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
            if not doorOk then
                print("[MDM] MdRfPdaGuest: WARNING ensureDoor failed (will retry)")
            end
        end
    end

    local host = getHost()
    local registerFn = nil
    if host ~= nil then
        if type(host.registerModule) == "function" then
            registerFn = host.registerModule
        elseif type(host.registerPanel) == "function" then
            registerFn = host.registerPanel
        end
    end
    if host == nil or registerFn == nil then
        return false
    end

    if not _registered then
        local ok = registerFn(host, {
            id = PANEL_ID,
            title = tr("md_rf_pda_module_title", "Market Dynamics"),
            -- BUILD 16:24: one line under the hero title; the long teach is paintSideInfo.
            blurb = tr("md_rf_pda_blurb", "Prices, events and contracts at a glance: pick a crop above, act below."),
            order = PANEL_ORDER,
            isAvailable = function()
                return getMdm() ~= nil
            end,
            onShow = MdRfPdaGuest.onShow,
            -- BUILD 23:51: registered so the host can take the quiet 2s path. Adding the
            -- function to this table is only half the job - registerModule whitelists.
            onLightTick = MdRfPdaGuest.onLightTick,
            -- BUILD 12:59: registered so a foreign door can drive selection without
            -- resolving this table at all.
            selectCommodityIndex = MdRfPdaGuest.selectCommodityIndex,
            onHide = MdRfPdaGuest.onHide,
            onMoverChanged = MdRfPdaGuest.onMoverChanged,
            -- BUILD 12:05: the open-full-market handler is gone with the Esc full-Market door.
        })
        if ok then
            _registered = true
            print("[MDM] MdRfPdaGuest: registered module marketDynamics on rfEscModules")
        else
            return false
        end
    end

    local doorPresent = g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
    if doorPresent then
        MdRfPdaGuest.standDownLegacyEsc()
    end
    return _registered and doorPresent
end

function MdRfPdaGuest.isHostPresent()
    return getHost() ~= nil
end

function MdRfPdaGuest.isRegistered()
    return _registered
end

function MdRfPdaGuest.reset()
    _registered = false
    _legacyStoodDown = false
    MdRfPdaGuest._legacyNeverInjected = false
    _selectedFillType = nil
    _commoditySig = nil
    _lastEventsSig = nil
    _lastContractsSig = nil
    _ncQty = 5000
    _ncDays = 30
    _ncFeedback = nil
end
