-- MDMContractAdminDialog.lua
-- Contract admin panel — view details and force-complete or cancel an active contract.
-- Opened by clicking any row in the Contracts tab of the Market screen.
--
-- params = {
--   contract   = contract table (from FuturesMarket.contracts),
--   onComplete = function(contractId)  called after admin force-complete,
--   onCancel   = function(contractId)  called after admin cancel/remove,
-- }

MDMContractAdminDialog = MDMContractAdminDialog or {}
local MDMContractAdminDialog_mt = Class(MDMContractAdminDialog, MessageDialog)

-- -----------------------------------------------------------------------
-- Constructor
-- -----------------------------------------------------------------------

function MDMContractAdminDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or MDMContractAdminDialog_mt)

    self.contract     = nil
    self._onComplete  = nil
    self._onCancel    = nil

    self.isOpen       = false

    -- Detail elements
    self.admCropValue      = nil
    self.admQtyValue       = nil
    self.admPriceValue     = nil
    self.admDelivValue     = nil
    self.admDeadlineValue  = nil
    self.admStatusValue    = nil
    self.admSumTotal       = nil
    self.admSumProgress    = nil
    self.admActionHint     = nil
    self.admSettledNotice  = nil

    -- Action buttons (native buttonBox elements)
    self.admCompleteBtn  = nil
    self.admCompleteSep  = nil
    self.admCancelBtn    = nil
    self.admCancelSep    = nil
    self.admDeleteBtn    = nil
    self.admDeleteSep    = nil
    self.admCloseBtn     = nil

    return self
end

-- -----------------------------------------------------------------------
-- Data setter — called by MDMDialogLoader before showDialog()
-- -----------------------------------------------------------------------

function MDMContractAdminDialog:setData(params)
    self.contract    = params.contract
    self._onComplete = params.onComplete
    self._onCancel   = params.onCancel
end

-- -----------------------------------------------------------------------
-- GUI lifecycle
-- -----------------------------------------------------------------------

function MDMContractAdminDialog:onCreate()
    local ok, err = pcall(function() MDMContractAdminDialog:superClass().onCreate(self) end)
    if not ok then MDMLog.warn("MDMContractAdminDialog:onCreate error: " .. tostring(err)) end
end

function MDMContractAdminDialog:onGuiSetupFinished()
    MDMContractAdminDialog:superClass().onGuiSetupFinished(self)

    self.admCropValue     = self:getDescendantById("admCropValue")
    self.admQtyValue      = self:getDescendantById("admQtyValue")
    self.admPriceValue    = self:getDescendantById("admPriceValue")
    self.admDelivValue    = self:getDescendantById("admDelivValue")
    self.admDeadlineValue = self:getDescendantById("admDeadlineValue")
    self.admStatusValue   = self:getDescendantById("admStatusValue")
    self.admSumTotal      = self:getDescendantById("admSumTotal")
    self.admSumProgress   = self:getDescendantById("admSumProgress")
    self.admActionHint    = self:getDescendantById("admActionHint")
    self.admSettledNotice = self:getDescendantById("admSettledNotice")

    self.admCompleteBtn   = self:getDescendantById("admCompleteBtn")
    self.admCompleteSep   = self:getDescendantById("admCompleteSep")
    self.admCancelBtn     = self:getDescendantById("admCancelBtn")
    self.admCancelSep     = self:getDescendantById("admCancelSep")
    self.admDeleteBtn     = self:getDescendantById("admDeleteBtn")
    self.admDeleteSep     = self:getDescendantById("admDeleteSep")
    self.admCloseBtn      = self:getDescendantById("admCloseBtn")

    MDMLog.info("MDMContractAdminDialog:onGuiSetupFinished OK")
end

function MDMContractAdminDialog:onOpen()
    MDMContractAdminDialog:superClass().onOpen(self)
    self.isOpen = true
    self._isPending = false  -- clear the synchronous pending flag

    self.isAdmin = g_currentMission:getIsServer() or g_currentMission.isAdmin or g_currentMission.isMasterUser

    self:_populate()
    if self.admCloseBtn then
        FocusManager:setFocus(self.admCloseBtn)
    end
end

function MDMContractAdminDialog:onClose()
    self.isOpen = false
    self._isPending = false
    MDMContractAdminDialog:superClass().onClose(self)
end

-- -----------------------------------------------------------------------
-- Button callbacks
-- -----------------------------------------------------------------------

function MDMContractAdminDialog:onCompleteClick()
    local c = self.contract
    if not c or c.status ~= "active" then self:close(); return end
    
    -- Security: only admins can force complete
    if not self.isAdmin then return end

    MDMContractRequestEvent.sendToServer(MDMContractRequestEvent.ACTION_ADMIN_COMPLETE, { contractId = c.id })
    if self._onComplete then self._onComplete(c.id) end
    self:close()
end

function MDMContractAdminDialog:onCancelContractClick()
    local c = self.contract
    if not c then self:close(); return end
    -- Both admCancelBtn (active) and admDeleteBtn (settled) route here.
    -- Determine the correct network action from the actual contract status and user role.
    if c.status == "active" then
        if self.isAdmin then
            MDMContractRequestEvent.sendToServer(MDMContractRequestEvent.ACTION_ADMIN_CANCEL, { contractId = c.id })
        else
            -- Player initiated forfeit
            MDMContractRequestEvent.sendToServer(MDMContractRequestEvent.ACTION_PLAYER_FORFEIT, { contractId = c.id })
        end
    else
        -- Only admins can delete settled contracts from the list
        if self.isAdmin then
            MDMContractRequestEvent.sendToServer(MDMContractRequestEvent.ACTION_ADMIN_DELETE, { contractId = c.id })
        end
    end
    if self._onCancel then self._onCancel(c.id) end
    self:close()
end

function MDMContractAdminDialog:onCloseClick()
    self:close()
end

-- -----------------------------------------------------------------------
-- Internal: populate elements from contract data
-- -----------------------------------------------------------------------

function MDMContractAdminDialog:_populate()
    local c = self.contract
    if not c then
        if self.admCropValue then self.admCropValue:setText("—") end
        return
    end

    local isActive = (c.status == "active")
    local isAdmin  = self.isAdmin

    -- Left column details
    if self.admCropValue     then self.admCropValue:setText(c.fillTypeName or "?") end
    if self.admQtyValue      then self.admQtyValue:setText(self:_fmt(c.quantity) .. " L") end
    if self.admPriceValue    then
        local fmt = g_i18n:getText("mdm_locked_price_fmt") or "$%.0f / 1,000L"
        self.admPriceValue:setText(string.format(fmt, (c.lockedPrice or 0) * 1000))
    end

    local delivPct = 0
    if c.quantity and c.quantity > 0 then
        delivPct = math.min(100, math.floor(((c.delivered or 0) / c.quantity) * 100))
    end
    if self.admDelivValue then
        self.admDelivValue:setText(string.format("%s / %s L  (%d%%)",
            self:_fmt(c.delivered or 0), self:_fmt(c.quantity), delivPct))
    end

    -- Deadline (convert ms to in-game days remaining)
    if self.admDeadlineValue then
        local now = MDMUtil.getGameTime()
        local remaining = math.max(0, (c.deliveryTime or 0) - now)
        local daysLeft  = math.floor(remaining / (24 * 60 * 60000))
        if isActive then
            local fmt = g_i18n:getText("mdm_days_remaining") or "%d day(s) remaining"
            self.admDeadlineValue:setText(string.format(fmt, daysLeft))
            if daysLeft <= 5 then
                self.admDeadlineValue:setTextColor(0.85, 0.22, 0.22, 1.0)
            elseif daysLeft <= 14 then
                self.admDeadlineValue:setTextColor(0.95, 0.75, 0.10, 1.0)
            else
                self.admDeadlineValue:setTextColor(0.80, 0.80, 0.80, 1.0)
            end
        else
            self.admDeadlineValue:setText(g_i18n:getText("mdm_settled") or "Settled")
            self.admDeadlineValue:setTextColor(0.65, 0.65, 0.65, 1.0)
        end
    end

    -- Status with colour
    if self.admStatusValue then
        local statusStr = c.status or "unknown"
        local displayStatus = statusStr:upper()
        if statusStr == "active" then
            displayStatus = g_i18n:getText("mdm_futures_active") or displayStatus
            self.admStatusValue:setTextColor(0.20, 0.72, 0.35, 1.0)
        elseif statusStr == "fulfilled" then
            displayStatus = g_i18n:getText("mdm_futures_fulfill") or displayStatus
            self.admStatusValue:setTextColor(0.40, 0.60, 1.00, 1.0)
        else
            displayStatus = g_i18n:getText("mdm_futures_defaulted") or displayStatus
            self.admStatusValue:setTextColor(0.85, 0.30, 0.22, 1.0)
        end
        self.admStatusValue:setText(displayStatus)
    end

    -- Right column summary
    local totalValue = math.floor((c.lockedPrice or 0) * (c.quantity or 0))
    if self.admSumTotal then
        local lbl = g_i18n:getText("mdm_total_value") or "Total value:  $"
        self.admSumTotal:setText(lbl .. self:_fmt(totalValue))
    end
    if self.admSumProgress then
        local delivValue = math.floor((c.lockedPrice or 0) * (c.delivered or 0))
        local fmt = g_i18n:getText("mdm_delivered_value") or "Delivered value:  $%s  (%d%%)"
        self.admSumProgress:setText(string.format(fmt, self:_fmt(delivValue), delivPct))
    end

    -- Show/hide action buttons based on contract status and user role.
    if isActive then
        -- Active contract: show Cancel/Forfeit + Complete (if admin)
        if self.admCancelBtn then 
            self.admCancelBtn:setVisible(true)
            local cancelText = isAdmin and (g_i18n:getText("mdm_adm_btn_cancel") or "Cancel (No Penalty)")
                                     or (g_i18n:getText("mdm_adm_btn_forfeit") or "Forfeit (Penalty)")
            self.admCancelBtn:setText(cancelText)
        end
        if self.admCancelSep then self.admCancelSep:setVisible(true) end
        
        if self.admDeleteBtn  then self.admDeleteBtn:setVisible(false) end
        if self.admDeleteSep  then self.admDeleteSep:setVisible(false) end
        
        if self.admCompleteBtn then 
            self.admCompleteBtn:setVisible(isAdmin)
            self.admCompleteBtn:setDisabled(not isAdmin)
        end
        if self.admCompleteSep then self.admCompleteSep:setVisible(isAdmin) end
    else
        -- Settled contract: show Delete only (if admin)
        if self.admDeleteBtn then self.admDeleteBtn:setVisible(isAdmin) end
        if self.admDeleteSep then self.admDeleteSep:setVisible(isAdmin) end
        
        if self.admCancelBtn  then self.admCancelBtn:setVisible(false) end
        if self.admCancelSep  then self.admCancelSep:setVisible(false) end
        
        if self.admCompleteBtn then self.admCompleteBtn:setVisible(false) end
        if self.admCompleteSep then self.admCompleteSep:setVisible(false) end
    end

    -- Hint / settled notice
    if self.admActionHint then
        self.admActionHint:setVisible(isActive)
        if isActive then
            if isAdmin then
                local completeHint = g_i18n:getText("mdm_adm_hint_complete") or "Complete: force full payout now at locked price."
                local cancelHint   = g_i18n:getText("mdm_adm_hint_cancel") or "Cancel: remove contract — no payout, no penalty."
                self.admActionHint:setText(completeHint .. "\n\n" .. cancelHint)
            else
                local forfeitHint = g_i18n:getText("mdm_adm_hint_forfeit") or "Forfeit: terminate contract immediately. A penalty will be applied to the undelivered portion."
                self.admActionHint:setText(forfeitHint)
            end
        end
    end
    if self.admSettledNotice then
        self.admSettledNotice:setVisible(not isActive)
    end
end

-- -----------------------------------------------------------------------
-- Utility
-- -----------------------------------------------------------------------

function MDMContractAdminDialog:_fmt(n)
    local s      = tostring(math.floor(n or 0))
    local result = ""
    local count  = 0
    for i = #s, 1, -1 do
        if count > 0 and count % 3 == 0 then result = "," .. result end
        result = s:sub(i, i) .. result
        count  = count + 1
    end
    return result
end
