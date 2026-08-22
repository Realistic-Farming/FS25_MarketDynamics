-- MDMContractDialog.lua
-- Futures contract creation dialog — MessageDialog subclass.
-- Opened via MDMDialogLoader.show("MDMContractDialog", "setData", params).
--
-- params = {
--   commodities  = table of commodity data (from MarketScreen.commodities),
--   onConfirmed  = function(crop, qty, delivDays)  called on confirm,
--   selectedIdx  = pre-selected crop index,
-- }
--
-- NOTE: No SmoothList is used — SmoothList inside fs25_dialogContentContainer
-- causes a layout stack overflow during showDialog. Crop selection happens in
-- the main MarketScreen price list; the dialog operates on the selected crop.

MDMContractDialog = MDMContractDialog or {}
local MDMContractDialog_mt = Class(MDMContractDialog, MessageDialog)

-- -----------------------------------------------------------------------
-- Constructor
-- -----------------------------------------------------------------------

function MDMContractDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or MDMContractDialog_mt)

    self.commodities       = {}
    self.selectedCropIdx   = 1
    self.selectedQty       = 5000
    self.selectedDelivDays = 30
    self._onConfirmed      = nil

    -- isOpen is checked by MarketScreen.mouseEvent to block click-through
    self.isOpen = false

    -- Left column: selected crop display
    self.cropNameEl   = nil
    self.cropPriceEl  = nil
    self.cropChangeEl = nil
    self.noCropsText  = nil

    -- Right column
    self.signalText   = nil
    self.confirmBtn   = nil
    self.confirmText  = nil
    self.sumCrop      = nil
    self.sumQty       = nil
    self.sumLocked    = nil
    self.sumTotal     = nil
    self.sumDeadline  = nil
    self.sumPenalty   = nil

    -- Hit-area buttons (for click identity comparison)
    self.qtyBtns = {}
    self.delBtns = {}

    -- Text elements (for setTextColor on selection change)
    self.qtyBtnTexts = {}
    self.delBtnTexts = {}

    return self
end

-- -----------------------------------------------------------------------
-- Data setter — called by DialogLoader before showDialog()
-- -----------------------------------------------------------------------

function MDMContractDialog:setData(params)
    self.commodities       = params.commodities  or {}
    self._onConfirmed      = params.onConfirmed
    self.selectedCropIdx   = params.selectedIdx  or 1
    self.selectedQty       = 5000
    self.selectedDelivDays = 30
    self.isCustomQty       = false
    self.isCustomDel       = false
end

-- -----------------------------------------------------------------------
-- GUI lifecycle
-- -----------------------------------------------------------------------

function MDMContractDialog:onCreate()
    local ok, err = pcall(function() MDMContractDialog:superClass().onCreate(self) end)
    if not ok then MDMLog.warn("MDMContractDialog:onCreate superClass error: " .. tostring(err)) end
end

function MDMContractDialog:onGuiSetupFinished()
    MDMContractDialog:superClass().onGuiSetupFinished(self)

    -- Left column
    self.cropNameEl   = self:getDescendantById("dlgCropName")
    self.cropPriceEl  = self:getDescendantById("dlgCropPrice")
    self.cropChangeEl = self:getDescendantById("dlgCropChange")
    self.noCropsText  = self:getDescendantById("dlgNoCrops")

    -- Right column
    self.signalText   = self:getDescendantById("dlgSignal")
    self.confirmBtn   = self:getDescendantById("dlgConfirmBtn")
    self.confirmText  = self:getDescendantById("dlgConfirmText")
    self.sumCrop      = self:getDescendantById("dlgSumCrop")
    self.sumQty       = self:getDescendantById("dlgSumQty")
    self.sumLocked    = self:getDescendantById("dlgSumLocked")
    self.sumTotal     = self:getDescendantById("dlgSumTotal")
    self.sumDeadline  = self:getDescendantById("dlgSumDeadline")
    self.sumPenalty   = self:getDescendantById("dlgSumPenalty")

    -- Qty hit buttons and text labels
    self.qtyBtns = {
        [500]   = self:getDescendantById("dlgQty500"),
        [1000]  = self:getDescendantById("dlgQty1000"),
        [5000]  = self:getDescendantById("dlgQty5000"),
        [10000] = self:getDescendantById("dlgQty10000"),
        [25000] = self:getDescendantById("dlgQty25000"),
        [50000] = self:getDescendantById("dlgQty50000"),
    }
    self.qtyCustomBtn  = self:getDescendantById("dlgQtyCustom")
    self.qtyCustomText = self:getDescendantById("dlgQtyCustomText")

    self.delBtns = {
        [30]  = self:getDescendantById("dlgDel30"),
        [60]  = self:getDescendantById("dlgDel60"),
        [90]  = self:getDescendantById("dlgDel90"),
        [120] = self:getDescendantById("dlgDel120"),
    }
    self.delCustomBtn  = self:getDescendantById("dlgDelCustom")
    self.delCustomText = self:getDescendantById("dlgDelCustomText")

    self.qtyBtnTexts = {
        [500]   = self:getDescendantById("dlgQty500Text"),
        [1000]  = self:getDescendantById("dlgQty1000Text"),
        [5000]  = self:getDescendantById("dlgQty5000Text"),
        [10000] = self:getDescendantById("dlgQty10000Text"),
        [25000] = self:getDescendantById("dlgQty25000Text"),
        [50000] = self:getDescendantById("dlgQty50000Text"),
    }
    self.delBtnTexts = {
        [30]  = self:getDescendantById("dlgDel30Text"),
        [60]  = self:getDescendantById("dlgDel60Text"),
        [90]  = self:getDescendantById("dlgDel90Text"),
        [120] = self:getDescendantById("dlgDel120Text"),
    }

    local qtyCount = 0; for _ in pairs(self.qtyBtns) do qtyCount = qtyCount + 1 end
    MDMLog.info("MDMContractDialog:onGuiSetupFinished — confirmBtn=" .. tostring(self.confirmBtn ~= nil)
        .. " cropNameEl=" .. tostring(self.cropNameEl ~= nil)
        .. " qtyBtns=" .. qtyCount)
end

function MDMContractDialog:onOpen()
    MDMContractDialog:superClass().onOpen(self)
    self.isOpen = true
    self._isPending = false

    local hasCrops = #self.commodities > 0

    if self.noCropsText then self.noCropsText:setVisible(not hasCrops) end
    if self.signalText  then self.signalText:setVisible(hasCrops) end
    if self.confirmBtn  then self.confirmBtn:setDisabled(not hasCrops) end

    self:_updateSummary()
    self:_updateButtonStates()

    -- Explicit focus prevents FS25 from auto-traversing all focusable elements
    if self.confirmBtn then
        FocusManager:setFocus(self.confirmBtn)
    end
end

function MDMContractDialog:onClose()
    self.isOpen = false
    self._isPending = false
    MDMContractDialog:superClass().onClose(self)
end

-- -----------------------------------------------------------------------
-- Button callbacks (bound via XML onClick)
-- -----------------------------------------------------------------------

function MDMContractDialog:onQtyClick(element)
    self.isCustomQty = false
    for qty, btn in pairs(self.qtyBtns) do
        if btn == element then
            self.selectedQty = qty
            self:_updateSummary()
            self:_updateButtonStates()
            return
        end
    end
end

function MDMContractDialog:onQtyCustomClick()
    MDMDialogLoader.show("MDMCustomInputDialog", "setData", {
        mode = "amount",
        currentValue = self.selectedQty,
        onConfirmed = function(val, _)
            self.isCustomQty = true
            self.selectedQty = val
            if self.qtyCustomText then self.qtyCustomText:setText(string.format("%s L", self:_fmtNum(val))) end
            self:_updateSummary()
            self:_updateButtonStates()
        end
    })
end

function MDMContractDialog:onDelivClick(element)
    self.isCustomDel = false
    for days, btn in pairs(self.delBtns) do
        if btn == element then
            self.selectedDelivDays = days
            self:_updateSummary()
            self:_updateButtonStates()
            return
        end
    end
end

function MDMContractDialog:onDelCustomClick()
    local isRealDays = g_MarketDynamics and g_MarketDynamics.settings and g_MarketDynamics.settings.useRealDays
    MDMDialogLoader.show("MDMCustomInputDialog", "setData", {
        mode = "days",
        currentValue = self.selectedDelivDays,
        onConfirmed = function(val)
            self.isCustomDel = true
            self.selectedDelivDays = val
            local suffix = isRealDays and (g_i18n:getText("mdm_unit_real_days") or "Real Days") or (g_i18n:getText("mdm_unit_game_days") or "Game Days")
            if self.delCustomText then self.delCustomText:setText(tostring(val) .. " " .. suffix) end
            self:_updateSummary()
            self:_updateButtonStates()
        end
    })
end

function MDMContractDialog:onConfirmClick()
    local crop = self.commodities[self.selectedCropIdx]
    if not crop then return end
    
    local cb = self._onConfirmed
    local qty = self.selectedQty
    local delivDays = self.selectedDelivDays
    local isRealDays = g_MarketDynamics and g_MarketDynamics.settings and g_MarketDynamics.settings.useRealDays
    local ts = (g_currentMission and g_currentMission.timeScale) or 1

    -- Real-days conversion: 1 real day = 86,400,000 real-ms.
    -- Game time advances at timeScale × real speed, so 1 real day = timeScale game-days.
    -- MarketScreen computes: deliveryTimeMs = now + (delivDays * 86,400,000 game-ms).
    -- Multiplying delivDays by timeScale makes that equation anchor to real time.
    if isRealDays then
        delivDays = delivDays * ts
    end

    self:close()

    if cb then
        cb(crop, qty, delivDays, isRealDays, ts)
    end
end

function MDMContractDialog:onCancelClick()
    self:close()
end

-- -----------------------------------------------------------------------
-- Internal helpers
-- -----------------------------------------------------------------------

function MDMContractDialog:_updateButtonStates()
    local SEL   = {0.0,  0.83, 0.49, 1.0}
    local UNSEL = {0.75, 0.75, 0.75, 1.0}

    for qty, txt in pairs(self.qtyBtnTexts) do
        if txt then
            local c = (not self.isCustomQty and qty == self.selectedQty) and SEL or UNSEL
            txt:setTextColor(c[1], c[2], c[3], c[4])
        end
    end
    if self.qtyCustomText then
        local c = self.isCustomQty and SEL or UNSEL
        self.qtyCustomText:setTextColor(c[1], c[2], c[3], c[4])
        if not self.isCustomQty then
            self.qtyCustomText:setText(g_i18n:getText("mdm_custom_amount") or "Custom Amount")
        end
    end

    for days, txt in pairs(self.delBtnTexts) do
        if txt then
            local c = (not self.isCustomDel and days == self.selectedDelivDays) and SEL or UNSEL
            txt:setTextColor(c[1], c[2], c[3], c[4])
        end
    end
    if self.delCustomText then
        local c = self.isCustomDel and SEL or UNSEL
        self.delCustomText:setTextColor(c[1], c[2], c[3], c[4])
        if not self.isCustomDel then
            self.delCustomText:setText(g_i18n:getText("mdm_custom_days") or "Custom Days")
        end
    end
end

function MDMContractDialog:_updateSummary()
    local crop = self.commodities[self.selectedCropIdx]

    if not crop then
        -- Left column
        if self.cropNameEl   then self.cropNameEl:setText("—") end
        if self.cropPriceEl  then self.cropPriceEl:setText("") end
        if self.cropChangeEl then self.cropChangeEl:setText("") end
        -- Right column
        local blank = "—"
        if self.sumCrop     then self.sumCrop:setText(blank) end
        if self.sumQty      then self.sumQty:setText(blank) end
        if self.sumLocked   then self.sumLocked:setText(blank) end
        if self.sumTotal    then self.sumTotal:setText(blank) end
        if self.sumDeadline then self.sumDeadline:setText(blank) end
        if self.sumPenalty  then self.sumPenalty:setText("") end
        if self.signalText  then self.signalText:setText("") end
        return
    end

    -- Left column: selected crop info
    if self.cropNameEl then
        self.cropNameEl:setText(crop.title)
    end
    if self.cropPriceEl then
        local fmt = g_i18n:getText("mdm_current_price_fmt") or "Current price:  $%.0f / 1,000L"
        self.cropPriceEl:setText(string.format(fmt, crop.current * 1000))
    end
    if self.cropChangeEl and crop.base and crop.base > 0 then
        local pct  = ((crop.current - crop.base) / crop.base) * 100
        local sign = pct >= 0 and "+" or ""
        local fmt  = g_i18n:getText("mdm_change_from_base_fmt") or "Change from base:  %s%.1f%%"
        self.cropChangeEl:setText(string.format(fmt, sign, pct))
        if pct > 0.5 then
            self.cropChangeEl:setTextColor(0.20, 0.72, 0.35, 1.0)
        elseif pct < -0.5 then
            self.cropChangeEl:setTextColor(0.85, 0.22, 0.22, 1.0)
        else
            self.cropChangeEl:setTextColor(0.65, 0.65, 0.65, 1.0)
        end
    end

    -- Right column: contract summary
    local lockedPrice = crop.current
    local totalValue  = math.floor(lockedPrice * self.selectedQty)

    if self.sumCrop    then self.sumCrop:setText((g_i18n:getText("mdm_summary_crop") or "Crop:         ") .. crop.title) end
    if self.sumQty     then self.sumQty:setText((g_i18n:getText("mdm_summary_qty") or "Quantity:     ") .. self:_fmtNum(self.selectedQty) .. " L") end
    if self.sumLocked  then 
        local fmt = g_i18n:getText("mdm_locked_price_fmt") or "Locked price: $%.0f / 1,000L"
        self.sumLocked:setText(string.format(fmt, lockedPrice * 1000)) 
    end
    if self.sumTotal   then self.sumTotal:setText((g_i18n:getText("mdm_summary_total") or "Total:  $") .. self:_fmtNum(totalValue)) end
    if self.sumDeadline then
        local isRealDays = g_MarketDynamics and g_MarketDynamics.settings and g_MarketDynamics.settings.useRealDays
        local unit = isRealDays and (g_i18n:getText("mdm_unit_real_days") or "real days") or (g_i18n:getText("mdm_unit_game_days") or "game days")
        self.sumDeadline:setText((g_i18n:getText("mdm_deliver_in") or "Deliver in:   ") .. self.selectedDelivDays .. " " .. unit)
    end
    if self.sumPenalty  then self.sumPenalty:setText(g_i18n:getText("mdm_default_penalty_hint") or "Default penalty: 15% on unfulfilled qty") end

    if self.signalText and crop.base and crop.base > 0 then
        local pct = ((lockedPrice - crop.base) / crop.base) * 100
        if pct > 5 then
            local fmt = g_i18n:getText("mdm_signal_above") or "[+] %.1f%% above base - good time to lock in"
            self.signalText:setText(string.format(fmt, pct))
            self.signalText:setTextColor(0.20, 0.72, 0.35, 1.0)
        elseif pct < -5 then
            local fmt = g_i18n:getText("mdm_signal_below") or "[-] %.1f%% below base - consider waiting"
            self.signalText:setText(string.format(fmt, math.abs(pct)))
            self.signalText:setTextColor(0.85, 0.30, 0.22, 1.0)
        else
            local fmt = g_i18n:getText("mdm_signal_neutral") or "[~] Near baseline (%.1f%%) - neutral"
            self.signalText:setText(string.format(fmt, pct))
            self.signalText:setTextColor(0.90, 0.72, 0.15, 1.0)
        end
    end
end

function MDMContractDialog:_fmtNum(n)
    local s      = tostring(math.floor(n))
    local result = ""
    local count  = 0
    for i = #s, 1, -1 do
        if count > 0 and count % 3 == 0 then result = "," .. result end
        result = s:sub(i, i) .. result
        count  = count + 1
    end
    return result
end
