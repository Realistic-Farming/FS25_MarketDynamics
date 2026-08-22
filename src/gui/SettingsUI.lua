-- MDMSettingsPanel.lua
-- Self-contained, drawn settings panel for Market Dynamics.
-- Pattern based on SoilSettingsPanel (FS25_SoilFertilizer).

---@class MDMSettingsPanel
MDMSettingsPanel = MDMSettingsPanel or {}
local MDMSettingsPanel_mt = Class(MDMSettingsPanel)

local MDM_MOD_NAME = (MarketDynamicsModName or g_currentModName)

-- ── i18n helper ───────────────────────────────────────────
local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[MDM_MOD_NAME]
    local i18n   = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Panel geometry (normalized, Y=0 at bottom) ────────────
local PW   = 0.62
local PH   = 0.76
local PX   = (1 - PW) / 2
local PY   = (1 - PH) / 2

local TB_H = 0.052
local IB_H = 0.046
local PAD  = 0.018

local CX     = PX + PAD
local CW     = PW - PAD * 2
local CY_BOT = PY + IB_H + 0.010
local CY_TOP = PY + PH - TB_H - 0.008
local CH     = CY_TOP - CY_BOT

-- Landing: category cards
local CARD_GAP = 0.012
local CARD_W   = (CW - CARD_GAP * 1) / 2 -- 2 cards wide for MDM
local CARD_H   = 0.30
local CARD_Y   = CY_BOT + (CH - CARD_H) / 2

-- Category page rows
local ROW_H    = 0.038
local SEC_H    = 0.026
local TOGGLE_W = 0.048
local TOGGLE_H = 0.026
local TOGGLE_GAP = 0.004
local MULTI_W  = 0.175

-- Text sizes
local TS_TITLE = 0.018
local TS_BODY  = 0.015
local TS_SMALL = 0.013
local TS_TINY  = 0.011

-- ── Colors ────────────────────────────────────────────────
local C = {
    bg          = {0.04, 0.05, 0.09, 0.97},
    title_bg    = {0.06, 0.08, 0.12, 1.0},
    info_bg     = {0.03, 0.04, 0.07, 1.0},
    border      = {0.90, 0.72, 0.20, 0.40}, -- Amber
    shadow      = {0.00, 0.00, 0.00, 0.45},
    divider     = {0.20, 0.22, 0.28, 0.55},
    row_alt     = {1.00, 1.00, 1.00, 0.025},
    row_hover   = {0.90, 0.72, 0.20, 0.08},
    white       = {1.00, 1.00, 1.00, 1.0},
    dim         = {0.55, 0.55, 0.60, 1.0},
    hint        = {0.38, 0.38, 0.46, 1.0},
    on_bg       = {0.22, 0.75, 0.33, 1.0},
    off_bg      = {0.15, 0.16, 0.20, 1.0},
    on_text     = {0.00, 0.00, 0.00, 1.0},
    off_text    = {0.45, 0.46, 0.52, 1.0},
    lock_bg     = {0.22, 0.14, 0.05, 0.70},
    lock_text   = {0.88, 0.60, 0.18, 1.0},
    card_hover  = {1.00, 1.00, 1.00, 0.04},
    accent      = {0.90, 0.72, 0.20, 1.0},
    accent_dim  = {0.55, 0.45, 0.12, 1.0},
    close_hover = {0.88, 0.25, 0.25, 0.80},
    back_hover  = {0.90, 0.72, 0.20, 0.18},
    info_admin  = {0.32, 0.88, 0.44, 1.0},
    info_no_adm = {0.88, 0.60, 0.18, 1.0},
    info_mode   = {0.55, 0.55, 0.62, 1.0},
}

-- ── Multi-option definitions ───────────────────────────────
local MULTI_OPTS = {
    eventFrequency = {
        values = { 0.15, 1.0, 2.0 },
        labels = { "mdm_freq_rare", "mdm_freq_normal", "mdm_freq_frequent" },
        i18n   = true,
    },
    futuresPenalty = {
        values = { 0.08, 0.15, 0.25 },
        labels = { "8%", "15%", "25%" },
    }
}

-- ── Setting definitions ────────────────────────────────────
local SETTING_DEFS = {
    pricesEnabled          = { label = "mdm_set_prices_enabled",   desc = "mdm_desc_prices_enabled",   type = "bool" },
    useRealDays            = { label = "mdm_set_use_real_days",    desc = "mdm_desc_use_real_days",    type = "bool" },
    futuresPenalty         = { label = "mdm_set_futures_penalty",  desc = "mdm_desc_futures_penalty",  type = "multi" },
    eventsEnabled          = { label = "mdm_set_events_enabled",   desc = "mdm_desc_events_enabled",   type = "bool" },
    eventFrequency         = { label = "mdm_set_event_freq",       desc = "mdm_desc_event_freq",       type = "multi" },
    showEventNotifications = { label = "mdm_set_event_notify",     desc = "mdm_desc_event_notify",     type = "bool" },
    eventNotificationBanner = { label = "mdm_set_event_banner",    desc = "mdm_desc_event_banner",     type = "bool",
                                labelText = "Compact Event Banner",
                                descText  = "Show world events as a small corner banner instead of a pop-up dialog." },
    showContractHUD        = { label = "mdm_set_contract_hud",     desc = "mdm_desc_contract_hud",     type = "bool" },
    debugMode              = { label = "mdm_set_debug_mode",       desc = "mdm_desc_debug_mode",       type = "bool" },
    experimentalSystems    = { label = "mdm_set_experimental",     desc = "mdm_desc_experimental",     type = "bool",
                               labelText = "Experimental Systems",
                               descText  = "Enable experimental (not yet released) systems at your own risk" },
}

-- ── Category definitions ───────────────────────────────────
local CATEGORIES = {
    {
        id       = "market",
        labelKey = "mdm_cat_market",
        descKey  = "mdm_cat_market_desc",
        accent   = C.accent,
        sections = {
            { headerKey = "mdm_hdr_engine",   items = { "pricesEnabled", "useRealDays" } },
            { headerKey = "mdm_hdr_futures",  items = { "futuresPenalty" } },
        },
    },
    {
        id       = "simulation",
        labelKey = "mdm_cat_sim",
        descKey  = "mdm_cat_sim_desc",
        accent   = {0.32, 0.88, 0.44, 1.0}, -- Green for sim
        sections = {
            { headerKey = "mdm_hdr_events",   items = { "eventsEnabled", "eventFrequency", "showEventNotifications", "eventNotificationBanner" } },
            { headerKey = "mdm_hdr_display",  items = { "showContractHUD", "debugMode", "experimentalSystems" } },
        },
    },
}

-- Pages
local PAGE_LANDING  = "landing"
local PAGE_CATEGORY = "category"
local PAGE_ADMIN    = "admin"

-- ── Constructor ───────────────────────────────────────────
function MDMSettingsPanel.new(settings)
    local self = setmetatable({}, MDMSettingsPanel_mt)
    self.settings     = settings
    self.fillOverlay  = nil
    self.isVisible    = false
    self.initialized  = false
    self.page         = PAGE_LANDING
    self.activeCatIdx = nil
    self.mouseX       = 0
    self.mouseY       = 0
    self._clickRects  = {}
    self.pageScrollPx = 0
    return self
end

function MDMSettingsPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    self.initialized = true
end

function MDMSettingsPanel:delete()
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Visibility ────────────────────────────────────────────
function MDMSettingsPanel:open()
    if not self.initialized then self:initialize() end
    self.isVisible    = true
    self.page         = PAGE_LANDING
    self.activeCatIdx = nil
    self.pageScrollPx = 0
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
end

function MDMSettingsPanel:close()
    self.isVisible = false
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
end

function MDMSettingsPanel:toggle()
    if self.isVisible then self:close() else self:open() end
end

-- ── Update / Main loop ────────────────────────────────────
function MDMSettingsPanel:update(dt)
    if not self.isVisible then return end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    -- Auto-close when a game menu opens
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        self:close()
    end
end

-- ── Admin helper ──────────────────────────────────────────
function MDMSettingsPanel:isAdmin()
    if g_server ~= nil then return true end
    if g_currentMission and g_currentMission.missionDynamicInfo then
        if not g_currentMission.missionDynamicInfo.isMultiplayer then
            return true
        end
    end
    if g_localPlayer and g_localPlayer.getIsAdmin then
        return g_localPlayer:getIsAdmin()
    end
    return false
end

function MDMSettingsPanel:getValue(id)
    return self.settings and self.settings[id]
end

function MDMSettingsPanel:requestChange(id, value)
    if not id or not self.settings then return end
    
    -- Local only vs Synced logic could go here
    -- For now, apply directly and assume serializer handles sync/save
    self.settings[id] = value
    
    if id == "debugMode" then
        if MDMLog then MDMLog.debugEnabled = value end
    end

    -- Reset world event timer so frequency/enabled changes take effect at the next check
    -- rather than waiting out the remainder of the current 5-minute interval.
    if id == "eventFrequency" or id == "eventsEnabled" then
        if g_MarketDynamics and g_MarketDynamics.worldEvents then
            g_MarketDynamics.worldEvents.timer = 0
        end
    end
end

-- ── Drawing helpers ───────────────────────────────────────
function MDMSettingsPanel:drawRect(x, y, w, h, col, alpha)
    if not self.fillOverlay then return end
    local a = alpha or col[4] or 1.0
    setOverlayColor(self.fillOverlay, col[1], col[2], col[3], a)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

function MDMSettingsPanel:drawText(x, y, size, text, col, align, bold)
    setTextColor(col[1], col[2], col[3], col[4] or 1.0)
    setTextBold(bold == true)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, tostring(text))
    -- Reset
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

function MDMSettingsPanel:registerClick(id, x, y, w, h, data)
    table.insert(self._clickRects, {id = id, x = x, y = y, w = w, h = h, data = data})
end

function MDMSettingsPanel:hitTest(rx, ry, rw, rh, mx, my)
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

-- ── Main draw entry ───────────────────────────────────────
function MDMSettingsPanel:draw()
    if not self.isVisible then return end
    if not self.initialized then return end

    self._clickRects = {}

    -- Dark screen fade
    self:drawRect(0, 0, 1, 1, {0, 0, 0, 1}, 0.38)

    -- Panel shadow
    self:drawRect(PX + 0.004, PY - 0.004, PW, PH, C.shadow, 0.55)

    -- Panel background
    self:drawRect(PX, PY, PW, PH, C.bg)

    -- Border
    local bw = 0.0015
    local bc = self.activeCatIdx and CATEGORIES[self.activeCatIdx].accent or C.border
    self:drawRect(PX,           PY,           PW, bw, bc)
    self:drawRect(PX,           PY + PH - bw, PW, bw, bc)
    self:drawRect(PX,           PY,           bw, PH, bc)
    self:drawRect(PX + PW - bw, PY,           bw, PH, bc)

    if self.page == PAGE_LANDING then
        self:drawLandingPage()
    elseif self.page == PAGE_CATEGORY then
        self:drawCategoryPage()
    elseif self.page == PAGE_ADMIN then
        self:drawAdminPage()
    end

    self:drawTitleBar()
    self:drawInfoBar()
end

-- ── Title bar ─────────────────────────────────────────────
function MDMSettingsPanel:drawTitleBar()
    local ty = PY + PH - TB_H
    self:drawRect(PX, ty, PW, TB_H, C.title_bg)

    local acc = (self.page == PAGE_ADMIN) and {0.88, 0.25, 0.25, 1.0}
             or (self.activeCatIdx and CATEGORIES[self.activeCatIdx].accent)
             or C.border
    self:drawRect(PX, ty, 0.004, TB_H, acc)

    local title = "MARKET DYNAMICS SETTINGS"
    if self.page == PAGE_ADMIN then
        title = title .. "  /  ADMIN"
    elseif self.activeCatIdx then
        local cat = CATEGORIES[self.activeCatIdx]
        title = title .. "  /  " .. string.upper(tr(cat.labelKey, cat.id))
    end
    self:drawText(PX + 0.018, ty + TB_H * 0.32, TS_TITLE, title, C.white, RenderText.ALIGN_LEFT, true)

    -- [X] close button
    local cbW = 0.038
    local cbH = TB_H * 0.60
    local cbX = PX + PW - cbW - 0.010
    local cbY = ty + (TB_H - cbH) / 2
    local chov = self:hitTest(cbX, cbY, cbW, cbH, self.mouseX, self.mouseY)
    self:drawRect(cbX, cbY, cbW, cbH, chov and C.close_hover or C.off_bg)
    self:drawText(cbX + cbW * 0.5, cbY + cbH * 0.18, TS_SMALL, "X", C.white, RenderText.ALIGN_CENTER, true)
    self:registerClick("close", cbX, cbY, cbW, cbH)
end

-- ── Info bar ──────────────────────────────────────────────
function MDMSettingsPanel:drawInfoBar()
    local iy = PY
    self:drawRect(PX, iy, PW, IB_H, C.info_bg)
    self:drawRect(PX, iy + IB_H - 0.001, PW, 0.001, C.divider)

    local isAdmin = self:isAdmin()
    local isMP    = g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer

    local adminText  = isAdmin and tr("mdm_panel_admin_yes", "Admin: Yes") or tr("mdm_panel_admin_no", "Admin: No")
    local adminColor = isAdmin and C.info_admin or C.info_no_adm
    local modeText   = isMP and tr("mdm_panel_multiplayer", "Multiplayer") or tr("mdm_panel_singleplayer", "Singleplayer")

    local textY = iy + IB_H * 0.25
    self:drawText(PX + PAD, textY, TS_SMALL, adminText, adminColor, RenderText.ALIGN_LEFT, true)
    self:drawText(PX + PAD + 0.095, textY, TS_SMALL, "·  " .. modeText, C.info_mode, RenderText.ALIGN_LEFT, false)

    if self.page == PAGE_CATEGORY or self.page == PAGE_ADMIN then
        local bbW = 0.085
        local bbH = IB_H * 0.62
        local bbX = PX + PW - bbW - 0.014
        local bbY = iy + (IB_H - bbH) / 2
        local bhov = self:hitTest(bbX, bbY, bbW, bbH, self.mouseX, self.mouseY)
        self:drawRect(bbX, bbY, bbW, bbH, bhov and C.back_hover or C.off_bg)
        self:drawRect(bbX, bbY, 0.002, bbH, C.accent)
        self:drawText(bbX + bbW * 0.5, bbY + bbH * 0.18, TS_SMALL, tr("mdm_btn_back", "Back"), C.white, RenderText.ALIGN_CENTER, false)
        self:registerClick("back", bbX, bbY, bbW, bbH)
    else
        self:drawText(PX + PW - PAD, textY, TS_SMALL, "F5 TO CLOSE", C.hint, RenderText.ALIGN_RIGHT, false)
    end
end

-- ── Landing page ──────────────────────────────────────────
function MDMSettingsPanel:drawLandingPage()
    local headerY = CY_BOT + CH - 0.040
    self:drawText(PX + PW * 0.5, headerY, TS_SMALL, tr("mdm_panel_select_cat", "Select a category to configure"), C.hint, RenderText.ALIGN_CENTER, false)

    for i, cat in ipairs(CATEGORIES) do
        local cardX = CX + (i - 1) * (CARD_W + CARD_GAP)
        self:drawCategoryCard(cardX, CARD_Y, CARD_W, CARD_H, cat, i)
    end
    
    -- Admin button
    local btnW = 0.090
    local btnH = 0.030
    local btnX = CX + CW - btnW
    local btnY = CY_BOT + 0.005
    local bhov = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(btnX, btnY, btnW, btnH, bhov and {0.55, 0.08, 0.08, 0.95} or {0.22, 0.05, 0.05, 0.88})
    self:drawRect(btnX, btnY, 0.003, btnH, {0.88, 0.25, 0.25, 1.0})
    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.22, TS_SMALL, "ADMIN", bhov and C.white or {0.85, 0.35, 0.35, 1.0}, RenderText.ALIGN_CENTER, true)
    self:registerClick("open_admin", btnX, btnY, btnW, btnH)
end

function MDMSettingsPanel:drawCategoryCard(x, y, w, h, cat, idx)
    local hovered = self:hitTest(x, y, w, h, self.mouseX, self.mouseY)
    self:drawRect(x, y, w, h, C.bg)
    if hovered then self:drawRect(x, y, w, h, C.card_hover) end

    -- Border
    local bw = 0.0012
    self:drawRect(x,         y,         w, bw, cat.accent, 0.30)
    self:drawRect(x,         y + h - bw, w, bw, cat.accent, 0.30)
    self:drawRect(x,         y,         bw, h,  cat.accent, 0.30)
    self:drawRect(x + w - bw, y,         bw, h,  cat.accent, 0.30)

    -- Accent bar
    self:drawRect(x, y + h - 0.018, w, 0.018, cat.accent, hovered and 0.85 or 0.65)

    -- Title
    local titleY = y + h - 0.018 - 0.042
    self:drawText(x + w * 0.5, titleY, TS_BODY, string.upper(tr(cat.labelKey, cat.id)), C.white, RenderText.ALIGN_CENTER, true)

    -- Description
    local descY = titleY - 0.036
    local descStr = tr(cat.descKey, "")
    for line in (descStr .. "\n"):gmatch("([^\n]*)\n") do
        self:drawText(x + w * 0.5, descY, TS_SMALL, line, C.dim, RenderText.ALIGN_CENTER, false)
        descY = descY - 0.020
    end

    -- Button
    local bW = w - 0.024
    local bH = 0.028
    local bX = x + 0.012
    local bY = y + 0.006
    self:drawRect(bX, bY, bW, bH, hovered and cat.accent or C.off_bg, hovered and 0.20 or 1.0)
    self:drawText(bX + bW * 0.5, bY + bH * 0.18, TS_SMALL, hovered and tr("mdm_btn_open", "Open") or tr("mdm_btn_configure", "Configure"), hovered and cat.accent or C.hint, RenderText.ALIGN_CENTER, false)

    self:registerClick("cat_" .. idx, x, y, w, h)
end

-- ── Category page ─────────────────────────────────────────
function MDMSettingsPanel:drawCategoryPage()
    if not self.activeCatIdx then return end
    local cat = CATEGORIES[self.activeCatIdx]
    if not cat then return end

    local curY = CY_TOP
    local isAdmin = self:isAdmin()
    local rowIdx = 0

    for _, sec in ipairs(cat.sections) do
        curY = curY - SEC_H
        if curY < CY_BOT then break end

        self:drawRect(CX, curY, CW, SEC_H, C.title_bg, 0.60)
        self:drawRect(CX, curY, 0.003, SEC_H, cat.accent)
        self:drawText(CX + 0.012, curY + SEC_H * 0.25, TS_SMALL, string.upper(tr(sec.headerKey, "")), cat.accent, RenderText.ALIGN_LEFT, true)

        for _, sid in ipairs(sec.items) do
            curY = curY - ROW_H
            if curY < CY_BOT then break end
            rowIdx = rowIdx + 1
            self:drawSettingRow(CX, curY, CW, sid, rowIdx, isAdmin, cat.accent)
        end
        curY = curY - 0.005
    end
end

-- ── Admin page ────────────────────────────────────────────
function MDMSettingsPanel:drawAdminPage()
    self:drawText(CX + CW * 0.5, CY_TOP - 0.100, TS_BODY, "ADMIN TOOLS COMING SOON", C.dim, RenderText.ALIGN_CENTER, true)
end

-- ── Setting row ───────────────────────────────────────────
function MDMSettingsPanel:drawSettingRow(x, y, w, sid, rowIdx, isAdmin, accent)
    local def = SETTING_DEFS[sid]
    if not def then return end

    if rowIdx % 2 == 0 then self:drawRect(x, y, w, ROW_H, C.row_alt) end
    if self:hitTest(x, y, w, ROW_H, self.mouseX, self.mouseY) then self:drawRect(x, y, w, ROW_H, C.row_hover) end

    local locked = false -- MDM might not need per-setting locking yet
    local lx = x + 0.008
    self:drawText(lx, y + ROW_H * 0.54, TS_BODY, tr(def.label, def.labelText or sid), C.white, RenderText.ALIGN_LEFT, true)
    self:drawText(lx, y + ROW_H * 0.15, TS_TINY, tr(def.desc, def.descText or ""), C.dim, RenderText.ALIGN_LEFT, false)

    local ctrlX = x + w - 0.012
    local ctrlY = y + (ROW_H - TOGGLE_H) / 2

    if def.type == "multi" then
        self:drawMultiControl(ctrlX, ctrlY, sid, locked)
    else
        self:drawToggleControl(ctrlX, ctrlY, sid, locked)
    end

    self:drawRect(x, y, w, 0.0005, C.divider, 0.35)
end

-- ── Toggle control [OFF] [ON] ─────────────────────────────
function MDMSettingsPanel:drawToggleControl(rightX, y, sid, locked)
    local val = self:getValue(sid)
    local isOn = val == true

    local offX = rightX - TOGGLE_W * 2 - TOGGLE_GAP
    local onX  = rightX - TOGGLE_W

    self:drawRect(offX, y, TOGGLE_W, TOGGLE_H, (not isOn) and C.dim or C.off_bg, (not isOn) and 0.90 or 0.60)
    self:drawText(offX + TOGGLE_W * 0.5, y + TOGGLE_H * 0.20, TS_TINY, "OFF", (not isOn) and C.white or C.off_text, RenderText.ALIGN_CENTER, not isOn)

    self:drawRect(onX, y, TOGGLE_W, TOGGLE_H, isOn and C.on_bg or C.off_bg, isOn and 1.0 or 0.60)
    self:drawText(onX + TOGGLE_W * 0.5, y + TOGGLE_H * 0.20, TS_TINY, "ON", isOn and C.on_text or C.off_text, RenderText.ALIGN_CENTER, isOn)

    if not locked then
        self:registerClick("toggle_off_" .. sid, offX, y, TOGGLE_W, TOGGLE_H, {id = sid, value = false})
        self:registerClick("toggle_on_"  .. sid, onX,  y, TOGGLE_W, TOGGLE_H, {id = sid, value = true})
    end
end

-- ── Multi-select control [< Option >] ────────────────────
function MDMSettingsPanel:drawMultiControl(rightX, y, sid, locked)
    local opt = MULTI_OPTS[sid]
    if not opt then return end

    local curVal = self:getValue(sid)
    local curIdx = 1
    for i, v in ipairs(opt.values) do
        if v == curVal then curIdx = i; break end
    end
    local rawLabel = opt.labels[curIdx] or "?"
    local label    = (opt.i18n and tr(rawLabel, rawLabel)) or rawLabel

    local arrowW = 0.022
    local labelW = MULTI_W - arrowW * 2
    local totalX = rightX - MULTI_W
    local leftX  = totalX
    local midX   = totalX + arrowW
    local rightBX = totalX + arrowW + labelW

    local lHov = not locked and self:hitTest(leftX, y, arrowW, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(leftX, y, arrowW, TOGGLE_H, lHov and C.back_hover or C.off_bg)
    self:drawText(leftX + arrowW * 0.5, y + TOGGLE_H * 0.18, TS_TINY, "<", lHov and C.accent or C.dim, RenderText.ALIGN_CENTER, true)

    self:drawRect(midX, y, labelW, TOGGLE_H, {0.10, 0.11, 0.15, 0.90})
    self:drawText(midX + labelW * 0.5, y + TOGGLE_H * 0.18, TS_TINY, label, C.white, RenderText.ALIGN_CENTER, false)

    local rHov = not locked and self:hitTest(rightBX, y, arrowW, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(rightBX, y, arrowW, TOGGLE_H, rHov and C.back_hover or C.off_bg)
    self:drawText(rightBX + arrowW * 0.5, y + TOGGLE_H * 0.18, TS_TINY, ">", rHov and C.accent or C.dim, RenderText.ALIGN_CENTER, true)

    if not locked then
        self:registerClick("multi_prev_" .. sid, leftX,   y, arrowW, TOGGLE_H, {id = sid, dir = -1})
        self:registerClick("multi_next_" .. sid, rightBX, y, arrowW, TOGGLE_H, {id = sid, dir =  1})
    end
end

-- ── Mouse event ───────────────────────────────────────────
function MDMSettingsPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.isVisible then return false end

    self.mouseX = posX
    self.mouseY = posY

    if not isDown then return true end
    if button ~= Input.MOUSE_BUTTON_LEFT then return true end

    for _, r in ipairs(self._clickRects) do
        if self:hitTest(r.x, r.y, r.w, r.h, posX, posY) then
            self:handleClick(r.id, r.data)
            return true
        end
    end

    if not self:hitTest(PX, PY, PW, PH, posX, posY) then
        self:close()
    end

    return true
end

function MDMSettingsPanel:handleClick(id, data)
    if id == "close" then
        self:close()
    elseif id == "back" then
        self.page = PAGE_LANDING
        self.activeCatIdx = nil
    elseif id:sub(1, 4) == "cat_" then
        local idx = tonumber(id:sub(5))
        if idx and CATEGORIES[idx] then
            self.activeCatIdx = idx
            self.page = PAGE_CATEGORY
        end
    elseif id == "open_admin" then
        self.page = PAGE_ADMIN
    elseif id:sub(1, 11) == "toggle_off_" then
        if data then self:requestChange(data.id, false) end
    elseif id:sub(1, 10) == "toggle_on_" then
        if data then self:requestChange(data.id, true) end
    elseif id:sub(1, 10) == "multi_prev" or id:sub(1, 10) == "multi_next" then
        if data then
            local opt = MULTI_OPTS[data.id]
            if opt then
                local curVal = self:getValue(data.id)
                local curIdx = 1
                for i, v in ipairs(opt.values) do
                    if v == curVal then curIdx = i; break end
                end
                local nxtIdx = curIdx + (data.dir or 0)
                if nxtIdx < 1 then nxtIdx = #opt.values end
                if nxtIdx > #opt.values then nxtIdx = 1 end
                self:requestChange(data.id, opt.values[nxtIdx])
            end
        end
    end
end
