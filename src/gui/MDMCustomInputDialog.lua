-- MDMCustomInputDialog.lua
-- Number-entry popup for custom quantity or custom delivery days.
-- Time unit (game/real days) is controlled by the toggle in MDMContractDialog.
--
-- params = {
--   mode         = "amount" | "days",
--   currentValue = number,
--   onConfirmed  = function(value)
-- }

MDMCustomInputDialog = MDMCustomInputDialog or {}
local MDMCustomInputDialog_mt = Class(MDMCustomInputDialog, MessageDialog)

function MDMCustomInputDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or MDMCustomInputDialog_mt)
    self.mode = "amount"
    self.currentValue = 0
    self._onConfirmed = nil

    self.dlgTitle      = nil
    self.dlgInputLabel = nil
    self.textInput     = nil
    self.dlgHint       = nil
    self.btnConfirm    = nil

    self.isOpen = false
    return self
end

function MDMCustomInputDialog:setData(params)
    self.mode         = params.mode or "amount"
    self.currentValue = params.currentValue or 0
    self._onConfirmed = params.onConfirmed
end

function MDMCustomInputDialog:onCreate()
    local ok, err = pcall(function() MDMCustomInputDialog:superClass().onCreate(self) end)
    if not ok then MDMLog.warn("MDMCustomInputDialog:onCreate error: " .. tostring(err)) end
end

function MDMCustomInputDialog:onGuiSetupFinished()
    MDMCustomInputDialog:superClass().onGuiSetupFinished(self)

    self.dlgTitle      = self:getDescendantById("dlgTitle")
    self.dlgInputLabel = self:getDescendantById("dlgInputLabel")
    self.textInput     = self:getDescendantById("textInput")
    self.dlgHint       = self:getDescendantById("dlgHint")
    self.btnConfirm    = self:getDescendantById("btnConfirm")
end

function MDMCustomInputDialog:onOpen()
    MDMCustomInputDialog:superClass().onOpen(self)
    self.isOpen = true
    self._isPending = false

    if self.textInput then
        local displayVal = self.currentValue
        if displayVal <= 0 then displayVal = "" end
        self.textInput:setText(tostring(displayVal))
        FocusManager:setFocus(self.textInput)
    end

    if self.mode == "amount" then
        if self.dlgTitle      then self.dlgTitle:setText(g_i18n:getText("mdm_custom_amount")) end
        if self.dlgInputLabel then self.dlgInputLabel:setText(g_i18n:getText("mdm_enter_amount")) end
        if self.dlgHint       then self.dlgHint:setText(g_i18n:getText("mdm_custom_amount_hint") or "Enter the quantity in liters.") end
    else
        if self.dlgTitle      then self.dlgTitle:setText(g_i18n:getText("mdm_custom_days")) end
        if self.dlgInputLabel then self.dlgInputLabel:setText(g_i18n:getText("mdm_enter_days")) end
        if self.dlgHint       then self.dlgHint:setText(g_i18n:getText("mdm_custom_days_hint") or "Enter the delivery window length. Time unit is set in the contract dialog.") end
    end

    self:_validateInput()
end

function MDMCustomInputDialog:onClose()
    self.isOpen = false
    self._isPending = false
    MDMCustomInputDialog:superClass().onClose(self)
end

function MDMCustomInputDialog:onTextChanged(element, text)
    self:_validateInput()
end

function MDMCustomInputDialog:_validateInput()
    if not self.textInput then return end
    local val = tonumber(self.textInput:getText())

    local isValid = false
    if val and val > 0 then
        if self.mode == "amount" and val <= 100000000 then
            isValid = true
        elseif self.mode == "days" and val <= 3650 then
            isValid = true
        end
    end

    if self.btnConfirm then
        self.btnConfirm:setDisabled(not isValid)
    end
end

function MDMCustomInputDialog:onConfirmClick()
    if self.btnConfirm and self.btnConfirm.disabled then return end

    local val = tonumber(self.textInput:getText())
    if not val or val <= 0 then return end

    local cb = self._onConfirmed
    self:close()
    if cb then cb(val) end
end

function MDMCustomInputDialog:onCancelClick()
    self:close()
end
