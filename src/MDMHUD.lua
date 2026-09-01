-- MDMHUD.lua
-- On-screen HUD for tracking active futures contracts.
-- Shows fill type, progress bar, delivery status, and time remaining.
--
-- Visual style follows the base-game HUD extension and fill-level display.
-- Falls back to a single pixel overlay when MasterHUD is unavailable.
--
-- Author: tison (dev-1)

MDMHUD = MDMHUD or {}
local MDMHUD_mt = Class(MDMHUD)

-- ── Base dimensions at scale 1.0 ─────────────────────────
MDMHUD.BASE_W = 0.185
MDMHUD.BASE_H = 0.088
MDMHUD.PAD    = 0.006

-- ── Layout constants ─────────────────────────────────────
MDMHUD.TITLE_H   = 0.022
MDMHUD.BAR_H     = 0.005556
MDMHUD.BAR_W     = 0.165
MDMHUD.LINE_H    = 0.016

-- ── Colors ───────────────────────────────────────────────
MDMHUD.C_BG         = {0.05, 0.05, 0.05, 0.82}   -- dark, semi-transparent
MDMHUD.C_TITLE_BG   = {0.10, 0.10, 0.10, 0.90}   -- header bg
MDMHUD.C_BORDER     = {0.20, 0.20, 0.20, 0.40}   -- subtle border
MDMHUD.C_SHADOW     = {0.00, 0.00, 0.00, 0.30}
MDMHUD.C_BAR_BG     = {0.18, 0.18, 0.18, 0.90}   -- bar track
MDMHUD.C_MDM_GREEN  = {0.00, 0.82, 0.48, 1.00}   -- MDM theme color
MDMHUD.C_LABEL      = {0.72, 0.72, 0.72, 1.00}   -- neutral gray
MDMHUD.C_VALUE      = {1.00, 1.00, 1.00, 1.00}
MDMHUD.C_WARN       = {1.00, 0.35, 0.35, 1.00}   -- red for urgent deadlines

function MDMHUD.new()
    local self = setmetatable({}, MDMHUD_mt)
    
    self.initialized = false
    self.fillOverlay = nil
    self.iconOverlays = {} -- { [filename] = overlayHandle }
    self.scale       = 1.0  -- Base scale
    
    -- Default position (bottom-right, above vanilla info)
    self.panelX = 0.800
    self.panelY = 0.135

    -- Drag state
    self.isDragging  = false
    self.dragOffsetX = 0
    self.dragOffsetY = 0

    return self
end

function MDMHUD:initialize()
    if self.initialized then return end
    
    if createImageOverlay ~= nil then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end

    self.initialized = true
    return true
end

function MDMHUD:delete()
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    if self.iconOverlays then
        for _, handle in pairs(self.iconOverlays) do
            delete(handle)
        end
        self.iconOverlays = {}
    end
    self.initialized = false
end

-- ── Draw helper ──────────────────────────────────────────
function MDMHUD:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay then return end
    local alpha = a or c[4] or 1.0
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], alpha)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

local function getBaseGameRenderer()
    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    return hud ~= nil and hud.renderer or nil
end

function MDMHUD:getIconOverlay(filename)
    if not filename or filename == "" then return nil end
    if not self.iconOverlays[filename] then
        local handle = createImageOverlay(filename)
        if handle and handle ~= 0 then
            self.iconOverlays[filename] = handle
        else
            return nil
        end
    end
    return self.iconOverlays[filename]
end

function MDMHUD:draw()
    if not self.initialized then self:initialize() end
    if not g_currentMission or not g_currentMission.hud or not g_currentMission.hud.isVisible then return end
    if not g_MarketDynamics or not g_MarketDynamics.settings.showContractHUD then return end
    if g_gui:getIsGuiVisible() then return end

    local farmId = (g_currentMission and g_currentMission.player and g_currentMission.player.farmId) or 1
    local contracts = g_MarketDynamics.futuresMarket:getContractsForFarm(farmId)
    
    -- Find the most urgent active contract
    local urgent = nil
    for _, c in ipairs(contracts) do
        if c.status == "active" then
            if not urgent or c.deliveryTime < urgent.deliveryTime then
                urgent = c
            end
        end
    end

    if not urgent then return end

    self:drawPanel(urgent)
end

function MDMHUD:drawPanel(contract)
    local s   = self.scale
    local px  = self.panelX
    local py  = self.panelY
    local pw  = MDMHUD.BASE_W * s
    local ph  = MDMHUD.BASE_H * s
    local pad = MDMHUD.PAD * s

    local titleH = MDMHUD.TITLE_H * s
    local renderer = getBaseGameRenderer()
    local usedNativePanel = renderer ~= nil and renderer.renderPanel ~= nil
        and renderer:renderPanel(px, py, pw, ph)
    if not usedNativePanel then
        -- Compatibility fallback for standalone use without MasterHUD.
        self:drawRect(px + 0.002*s, py - 0.002*s, pw, ph, MDMHUD.C_SHADOW)
        self:drawRect(px, py, pw, ph, MDMHUD.C_BG)
        self:drawRect(px, py + ph - titleH, pw, titleH, MDMHUD.C_TITLE_BG)

        local bw = 0.0006 * s
        self:drawRect(px,           py,            pw, bw, MDMHUD.C_BORDER)
        self:drawRect(px,           py + ph - bw,   pw, bw, MDMHUD.C_BORDER)
        self:drawRect(px,           py,            bw, ph, MDMHUD.C_BORDER)
        self:drawRect(px + pw - bw,  py,            bw, ph, MDMHUD.C_BORDER)
    end

    -- The crop and completion value are the header row, matching the native
    -- fill-level panel. A second generic title used to occupy this exact same
    -- baseline and overprint both values.
    local tx = px + pad
    local ty = py + ph - titleH * 0.5
    
    -- Icon
    local iconX = tx
    local iconSize = 0.016 * s
    local ft = g_fillTypeManager:getFillTypeByIndex(contract.fillTypeIndex)
    if ft and ft.hudOverlayFilename then
        local handle = self:getIconOverlay(ft.hudOverlayFilename)
        if handle then
            local screenW, screenH = getScreenMode()
            local iconW = iconSize
            local aspectRatio = (screenW ~= nil and screenH ~= nil and screenH > 0) and (screenW / screenH) or (16 / 9)
            local iconH = iconSize * aspectRatio
            setOverlayColor(handle, 1, 1, 1, 1)
            renderOverlay(handle, iconX, ty - iconH * 0.5, iconW, iconH)
            iconX = iconX + iconW + 0.004 * s
        end
    end

    -- Title (Crop Name)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(iconX, ty - 0.005 * s, 0.011 * s, contract.fillTypeName:upper())
    
    -- Progress %
    local pct = contract.quantity > 0 and (contract.delivered / contract.quantity) or 0
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(MDMHUD.C_MDM_GREEN[1], MDMHUD.C_MDM_GREEN[2], MDMHUD.C_MDM_GREEN[3], 1.0)
    renderText(px + pw - pad, ty - 0.005 * s, 0.011 * s, string.format("%.0f%%", pct * 100))
    setTextBold(false)

    -- Y Cursor
    local cy = py + ph - titleH - pad * 1.5

    -- Progress Bar
    local barX = px + (pw - MDMHUD.BAR_W * s) * 0.5
    local barY = cy - MDMHUD.BAR_H * s
    local usedNativeBar = renderer ~= nil and renderer.renderProgressBar ~= nil
        and renderer:renderProgressBar(barX, barY, MDMHUD.BAR_W * s,
            MDMHUD.BAR_H * s, pct, MDMHUD.C_MDM_GREEN)
    if not usedNativeBar then
        self:drawRect(barX, barY, MDMHUD.BAR_W * s, MDMHUD.BAR_H * s, MDMHUD.C_BAR_BG)
        if pct > 0 then
            self:drawRect(barX, barY, MDMHUD.BAR_W * s * math.min(1, pct), MDMHUD.BAR_H * s, MDMHUD.C_MDM_GREEN)
        end
    end
    
    cy = barY - pad * 1.2

    -- Info Line 1: Quantity
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(MDMHUD.C_LABEL[1], MDMHUD.C_LABEL[2], MDMHUD.C_LABEL[3], 1.0)
    renderText(tx, cy - 0.008 * s, 0.009 * s, g_i18n:getText("mdm_label_quantity") .. ":")
    
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(MDMHUD.C_VALUE[1], MDMHUD.C_VALUE[2], MDMHUD.C_VALUE[3], 1.0)
    local qtyStr = string.format("%.0f L @ $%.0f", contract.quantity, contract.lockedPrice * 1000)
    renderText(px + pw - pad, cy - 0.008 * s, 0.009 * s, qtyStr)

    cy = cy - MDMHUD.LINE_H * s

    -- Info Line 2: Deadline
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(MDMHUD.C_LABEL[1], MDMHUD.C_LABEL[2], MDMHUD.C_LABEL[3], 1.0)
    renderText(tx, cy - 0.008 * s, 0.009 * s, g_i18n:getText("mdm_screen_col_deadline") .. ":")
    
    local now = MDMUtil.getGameTime()
    local remaining = math.max(0, contract.deliveryTime - now)
    local days = math.floor(remaining / (24 * 60 * 60000))
    local hrs = math.floor((remaining % (24 * 60 * 60000)) / (60 * 60000))
    local mins = math.floor((remaining % (60 * 60000)) / 60000)
    
    local timeColor = MDMHUD.C_VALUE
    if remaining < 86400000 then timeColor = MDMHUD.C_WARN end
    
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(timeColor[1], timeColor[2], timeColor[3], 1.0)
    local timeStr = string.format("%d d %d h %d m", days, hrs, mins)
    renderText(px + pw - pad, cy - 0.008 * s, 0.009 * s, timeStr)

    -- Reset state
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
end

-- ── Mouse interaction ────────────────────────────────────
-- Returns true if (mx, my) is inside the HUD panel
function MDMHUD:_isHovered(mx, my)
    local pw = MDMHUD.BASE_W * self.scale
    local ph = MDMHUD.BASE_H * self.scale
    return mx >= self.panelX and mx <= self.panelX + pw
       and my >= self.panelY and my <= self.panelY + ph
end

-- Call this from MarketDynamics:mouseEvent
function MDMHUD:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.initialized then return end
    if not g_MarketDynamics or not g_MarketDynamics.settings.showContractHUD then return end
    if g_gui:getIsGuiVisible() then return end

    -- Left mouse button = button 1
    if button == Input.MOUSE_BUTTON_LEFT then
        if isDown and self:_isHovered(posX, posY) then
            self.isDragging  = true
            self.dragOffsetX = posX - self.panelX
            self.dragOffsetY = posY - self.panelY
        elseif isUp then
            self.isDragging = false
        end
    end

    if self.isDragging then
        self.panelX = posX - self.dragOffsetX
        self.panelY = posY - self.dragOffsetY
        -- Clamp to screen
        local pw = MDMHUD.BASE_W * self.scale
        local ph = MDMHUD.BASE_H * self.scale
        self.panelX = math.max(0, math.min(1 - pw, self.panelX))
        self.panelY = math.max(0, math.min(1 - ph, self.panelY))
    end
end

-- Call this from MarketDynamics:mouseEvent (scroll wheel = button 4 up / 5 down in FS25)
function MDMHUD:scrollEvent(posX, posY, button)
    if not self.initialized then return end
    if not g_MarketDynamics or not g_MarketDynamics.settings.showContractHUD then return end
    if g_gui:getIsGuiVisible() then return end
    if not self:_isHovered(posX, posY) then return end

    if button == Input.MOUSE_BUTTON_WHEEL_UP then
        self.scale = math.min(2.0, self.scale + 0.05)
    elseif button == Input.MOUSE_BUTTON_WHEEL_DOWN then
        self.scale = math.max(0.5, self.scale - 0.05)
    end
end

-- Global singleton. Preserve and patch the live instance during script reloads.
if g_MDMHud == nil then
    g_MDMHud = MDMHUD.new()
else
    for key, value in pairs(MDMHUD) do
        if type(value) == "function" then
            g_MDMHud[key] = value
        end
    end
    print("[MarketDynamics] MDMHUD live instance patched")
end
