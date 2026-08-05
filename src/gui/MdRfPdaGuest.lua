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

MdRfPdaGuest = {}

local MOD_DIR = g_currentModDirectory
local MD_RF_MOD_NAME = g_currentModName
local PANEL_ID = "marketDynamics"
local PANEL_ORDER = 40
local MAX_EVENT_ROWS = 6
local MAX_CONTRACT_ROWS = 5

local PAGE_PRICES = 1
local PAGE_EVENTS = 2
local PAGE_CONTRACTS = 3

local COLOR_UP = {0.30, 0.80, 0.35, 1}
local COLOR_DOWN = {0.90, 0.25, 0.20, 1}
local COLOR_FLAT = {0.70, 0.72, 0.75, 1}
local COLOR_LIME = {0.659, 0.878, 0.290, 1}

local _registered = false
local _legacyStoodDown = false
local _selectedFillType = nil
local _commoditySig = nil
local _lastEventsSig = nil
local _lastContractsSig = nil
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
    table.sort(out, function(a, b)
        local aa = math.abs(a.changePct or 0)
        local bb = math.abs(b.changePct or 0)
        if aa ~= bb then
            return aa > bb
        end
        return (a.title or "") < (b.title or "")
    end)
    return out
end

-- Back-compat for any host still calling buildMovers.
function MdRfPdaGuest.buildMovers(limit)
    local all = MdRfPdaGuest.buildCommodities()
    limit = limit or 5
    while #all > limit do
        table.remove(all)
    end
    return all
end

local function commoditiesSignature(rows)
    if rows == nil or #rows == 0 then
        return "empty"
    end
    local parts = {}
    for _, r in ipairs(rows) do
        table.insert(parts, tostring(r.fillTypeIndex))
    end
    return table.concat(parts, "|")
end

local function defaultSelection(rows)
    if rows ~= nil and rows[1] ~= nil then
        return rows[1].fillTypeIndex
    end
    return nil
end

local function paintSideInfo(container)
    local body = tr("rf_pda_side_info_market_dynamics",
        "Market Dynamics\n\nPause Market glance with three pages: Prices, Events, Contracts.\n\nTop table = crop icons, prices, and swings. Icons help you spot the crop fast. On Prices, pick a crop to drive the graph.\n\nEvents page = what is hitting the market now, how strong, and how long left.\n\nContracts page = your open deals (read-only). Manage them in full Market.\n\nOpen full Market (SPACE) for the deep desk.")
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

local function paintOpenMarketButtons(container)
    local label = tr("md_rf_pda_open_market", "Open full Market")
    for _, id in ipairs({ "mdOpenMarketBtn", "mdOpenMarketBtnEvents", "mdOpenMarketBtnContracts" }) do
        local btn = findDescendant(container, id)
        if btn ~= nil and btn.setText then
            btn:setText(label)
        end
    end
end

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

    -- Hang fence: reloadData only on full show or commodity id signature change.
    if needReload and type(list.reloadData) == "function" then
        list:reloadData()
    end

    -- Selection highlight: quiet index only (no reload).
    if _selectedFillType ~= nil and rows ~= nil then
        for i, r in ipairs(rows) do
            if r.fillTypeIndex == _selectedFillType then
                if type(list.setSelectedIndex) == "function" then
                    pcall(function() list:setSelectedIndex(i) end)
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
    setVis(emptyEl, not has)
    if not has then
        setText(emptyEl, tr("md_rf_pda_select_crop", "Pick a crop in the table to see the graph."))
        return
    end

    local pct = engine:getPriceChangePercent(ft) or 0
    local price = engine:getPrice(ft)

    setText(cropEl, fillTypeTitle(ft))
    setTextColor(cropEl, unpack(COLOR_LIME))

    local priceLine = string.format("%s  ·  %s", formatMoney(price), formatSignedPct(pct))
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

local function paintGraphHints(container)
    local titleEl = findDescendant(container, "mdGraphTitle")
    local emptyEl = findDescendant(container, "mdGraphEmptyHint")
    setText(titleEl, tr("md_rf_pda_graph_title", "Price trend"))

    local count = 0
    if _selectedFillType ~= nil and MDMMarketScreenGraph ~= nil
            and type(MDMMarketScreenGraph.getSampleCount) == "function" then
        count = MDMMarketScreenGraph.getSampleCount(_selectedFillType) or 0
    end
    if _selectedFillType == nil then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_select_crop", "Pick a crop in the table to see the graph."))
    elseif count < 2 then
        setVis(emptyEl, true)
        setText(emptyEl, tr("md_rf_pda_building_history", "Building price history..."))
    else
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

local function paintEventsBand(container)
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
        setText(moreEl, string.format(tr("md_rf_pda_contracts_more", "and %d more in full Market"), n - MAX_CONTRACT_ROWS))
    else
        setText(moreEl, "")
    end
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
        paintEventsBand(container)
    else
        paintContractsBand(container)
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
    paintOpenMarketButtons(container)

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

function MdRfPdaGuest.onHide()
    _commoditySig = nil
    _lastEventsSig = nil
    _lastContractsSig = nil
end

function MdRfPdaGuest.getSelectedFillType()
    return _selectedFillType
end

function MdRfPdaGuest.selectCommodityIndex(index)
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

function MdRfPdaGuest.onOpenFullMarket()
    if MDMMarketScreen ~= nil and type(MDMMarketScreen.show) == "function" then
        MDMMarketScreen.show()
    end
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

function MdRfPdaGuest.tryRegister()
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
            blurb = tr("md_rf_pda_blurb",
                "Pause Market glance: Prices, Events, Contracts. Top table stays; bottom swaps. Open full Market for the deep desk."),
            order = PANEL_ORDER,
            isAvailable = function()
                return getMdm() ~= nil
            end,
            onShow = MdRfPdaGuest.onShow,
            onHide = MdRfPdaGuest.onHide,
            onMoverChanged = MdRfPdaGuest.onMoverChanged,
            onOpenFullMarket = MdRfPdaGuest.onOpenFullMarket,
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
end
