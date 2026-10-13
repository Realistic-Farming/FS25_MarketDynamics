--!load: src/MarketSerializer.lua, src/MarketEngine.lua, src/FuturesMarket.lua, src/MDMHUD.lua, src/events/MDMContractSyncEvent.lua, src/gui/MDMContractDialog.lua, src/gui/MDMContractAdminDialog.lua
-- #170 (Mocskos1230): Market Dynamics wrote some money with a fixed "$". A euro player read
-- "+$1,234 €" in a contract message, and a player on a currency mod (Additional Currencies, HUF)
-- read the mod's symbol beside an amount the mod never converted. Every amount below now goes
-- through the game's own money formatter, g_i18n:formatMoney (MDMHUD.money), so it carries the
-- player's currency, and a currency mod that converts amounts there converts these too.
--
-- THE ENTRY-POINT BAR. The contract messages come from the real FuturesMarket: a delivery through
-- recordDelivery that fills the contract (the fulfilled message) and a deadline through checkExpiry
-- (the defaulted message). The HUD line and the two contract dialogs' amounts come from their real
-- functions (MDMHUD.money, MDMContractDialog:_updateSummary, MDMContractAdminDialog's refresh),
-- with text elements that record what they are given. g_i18n is a currency mod's surface: its
-- formatMoney converts at 400 and writes HUF, and getText answers the English file's real values.
--
-- Groups: N the contract messages, H the HUD line, D the contract dialog, A the admin dialog.

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
end

-- The English file's values for the five money texts, as translations/translation_en.xml ships them
-- (the runner has no file io; tools/test/currency-symbol-check.mjs holds every locale file, English
-- included, to these shapes: no "$", and exactly the placeholders the code fills).
local EN = {
    mdm_current_price_fmt = "Current price:  %s / 1,000L",
    mdm_locked_price_fmt  = "Locked price: %s / 1,000L",
    mdm_delivered_value   = "Delivered value:  %s  (%d%%)",
    mdm_total_value       = "Total value:  ",
    mdm_summary_total     = "Total:  ",
}
local RATE = 400
local FORMATTED = {}
g_i18n = {
    getText = function(_, key) return EN[key] or key end,
    formatMoney = function(_, n, precision, addCurrency, prefix)
        FORMATTED[#FORMATTED + 1] = n
        local s = string.format("%d", math.floor(n * RATE + 0.5))
        if addCurrency == false then return s end
        return s .. " HUF"
    end,
    getCurrencySymbol = function() return "HUF" end,
}

MDMUtil = { getGameTime = function() return MDMUtil.now or 1000 end, getMonotonicTime = function() return 1000 end }
MDMLog = { info = function() end, warn = function() end, debug = function() end, error = function() end }
UPIntegration = { onContractCreated = function() end, onContractFulfilled = function() end, onContractDefaulted = function() end,
                  getPenaltyModifier = function() return 1 end, save = function() end, load = function() end }
MoneyType = MoneyType or { OTHER = 0 }
FSBaseMission = FSBaseMission or {}
FSBaseMission.INGAME_NOTIFICATION_OK, FSBaseMission.INGAME_NOTIFICATION_CRITICAL = 1, 2
g_server = nil
g_localPlayer = { farmId = 1 }
local NOTES = {}
g_currentMission.isServer, g_currentMission.isClient = true, true
g_currentMission.addMoney = function() end
g_currentMission.addIngameNotification = function(_, _, msg) NOTES[#NOTES + 1] = msg end
g_MarketDynamics = { settings = { futuresPenalty = 0.2 } }

local function contract(fm, qty, price)
    return fm:createContract({ farmId = 1, fillTypeIndex = 3, fillTypeName = "WHEAT", quantity = qty, lockedPrice = price, deliveryTimeMs = 5000 })
end
local function noDollar(s) return type(s) == "string" and s:find("$", 1, true) == nil end

group("N", function()
    local fm = FuturesMarket.new()
    local id = contract(fm, 1000, 0.5)                 -- locked value 500
    fm:recordDelivery(id, 1000, 0.3)                    -- market paid 300, so +200 settles
    T.eq("N1 [entry point] NAMED: the fulfilled message carries the amount as the game formats it (200 converted to 80000 HUF), with no '$'",
        tostring(NOTES[1]), "Contract fulfilled: WHEAT - settled at locked price (+80000 HUF)")
    local fm2 = FuturesMarket.new()
    local id2 = contract(fm2, 1000, 0.5)
    fm2:recordDelivery(id2, 400, 0.5)                   -- delivered 400 at the locked price
    MDMUtil.now = 6000
    fm2:checkExpiry()                                   -- 600 L short: penalty 600 x 0.5 x 0.2 = 60, charged
    MDMUtil.now = nil
    T.eq("N2 NAMED: the defaulted message carries the charge as the game formats it, with no '$'",
        tostring(NOTES[2]), "Contract defaulted: WHEAT - 400L/1000L delivered, charged 24000 HUF after penalty")
end)

group("H", function()
    T.eq("H1 NAMED: the HUD's money goes through formatMoney (a currency mod's conversion applies)", MDMHUD.money(125), "50000 HUF")
    local saved = g_i18n.formatMoney
    g_i18n.formatMoney = nil
    T.eq("H2 with no formatMoney the amount is written plain, never with '$'", MDMHUD.money(125.4), "125")
    g_i18n.formatMoney = saved
end)

--- A text element that keeps what it is given.
local function el() return { setText = function(self, s) self.text = s end, setTextColor = function() end } end

group("D", function()
    local d = setmetatable({ commodities = { { title = "Wheat", current = 0.25, base = 0.25 } }, selectedCropIdx = 1, selectedQty = 2000,
                             selectedDelivDays = 30, cropNameEl = el(), cropPriceEl = el(), cropChangeEl = el(), sumCrop = el(), sumQty = el(),
                             sumLocked = el(), sumTotal = el(), sumDeadline = el(), sumPenalty = el(), signalText = el() }, { __index = MDMContractDialog })
    local ok, err = pcall(d._updateSummary, d)
    T.eq("D1 [entry point] the contract dialog's summary runs with the shipped English texts", tostring(ok) .. "/" .. tostring(err), "true/nil")
    T.eq("D2 NAMED: current price, locked price and total are the game's money (250 and 500 converted), with no '$'",
        tostring(d.cropPriceEl.text) .. " | " .. tostring(d.sumLocked.text) .. " | " .. tostring(d.sumTotal.text),
        "Current price:  100000 HUF / 1,000L | Locked price: 100000 HUF / 1,000L | Total:  200000 HUF")
end)

group("A", function()
    local refresh = MDMContractAdminDialog._populate
    local a = setmetatable({ contract = { id = 1, status = "active", fillTypeName = "WHEAT", quantity = 2000, delivered = 500, lockedPrice = 0.25,
                                          deliveryTime = 10 * 24 * 60 * 60000 },
                             isAdmin = false, admCropValue = el(), admQtyValue = el(), admPriceValue = el(), admDelivValue = el(),
                             admDeadlineValue = el(), admStatusValue = el(), admSumTotal = el(), admSumProgress = el() }, { __index = MDMContractAdminDialog })
    T.ok("A0 the admin dialog has its refresh function (_populate)", refresh ~= nil)
    if refresh ~= nil then pcall(refresh, a) end
    T.eq("A1 NAMED: the admin dialog's locked price, total value and delivered value are the game's money, with no '$'",
        tostring(a.admPriceValue.text) .. " | " .. tostring(a.admSumTotal.text) .. " | " .. tostring(a.admSumProgress.text),
        "Locked price: 100000 HUF / 1,000L | Total value:  200000 HUF | Delivered value:  50000 HUF  (25%)")
    T.ok("A2 nothing the dialogs or the messages drew carries a '$'",
        noDollar(a.admPriceValue.text) and noDollar(a.admSumTotal.text) and noDollar(a.admSumProgress.text) and noDollar(NOTES[1]) and noDollar(NOTES[2]))
end)
