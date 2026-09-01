-- UPIntegration.lua
-- Optional integration layer with FS25_UsedPlus (XelaNull).
-- API version targeted: v1.1.0 (FS25_UsedPlus v2.15.4.96)
--
-- When UsedPlus is installed this module automatically:
--   1. Registers MDM futures contracts as external deals → affects credit score
--   2. Reports fulfilled/defaulted contracts → credit score up/down
--   3. Reads credit score at contract creation → scales MDM default penalty rate
--   4. Applies world event market modifiers → affects used equipment prices
--
-- All UsedPlusAPI calls are server-only (isServer guard).
-- See: https://github.com/XelaNull/FS25_UsedPlus/issues/40
--
-- Author: tison (dev-1)

UPIntegration = UPIntegration or {}

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local CREDIT_TIER_EXCELLENT = 750
local CREDIT_TIER_POOR      = 600

local PENALTY_MOD_EXCELLENT = 0.67  -- 10% effective penalty  (vs default 15%)
local PENALTY_MOD_POOR      = 1.33  -- 20% effective penalty  (vs default 15%)
local PENALTY_MOD_DEFAULT   = 1.0   -- 15% — used when UP not active or score unknown

local EVENT_MODIFIERS = {
    drought           = function(i) return 1.0 + i * 0.20 end,  -- +0-20%: farmers need equipment
    geopolitical      = function(i) return 1.0 + i * 0.15 end,  -- +0-15%: can't source new
    trade_disruption  = function(i) return 1.0 + i * 0.12 end,  -- +0-12%: used > new
    bumper_harvest    = function(i) return 1.0 + i * 0.10 end,  -- +0-10%: flush cash, buying
    biofuel_initiative= function(i) return 1.0 + i * 0.08 end,  -- +0-8%: expanding operations
    livestock_boom    = function(i) return 1.0 + i * 0.08 end,  -- +0-8%: need more equipment
    pest_outbreak     = function(i) return 1.0 - i * 0.08 end,  -- -0-8%: economic stress, selling
}

local MOD_NAME = "MarketDynamics"

-- ---------------------------------------------------------------------------
-- API accessor
-- Primary path: g_currentMission.usedPlusAPI (shipped in UP v2.15.4.96).
-- Fallback:     bare UsedPlusAPI global (rawset _G path, older versions).
-- ---------------------------------------------------------------------------
local function getAPI()
    return (g_currentMission and g_currentMission.usedPlusAPI) or UsedPlusAPI
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- Maps contractId → upDealId returned by getAPI().registerExternalDeal().
-- Persisted by save/load so we can report payments/defaults across sessions.
local _dealIds = {}

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function UPIntegration.isAvailable()
    if g_modManager:getModByName("FS25_UsedPlus") == nil then return false end
    return getAPI() ~= nil
end

-- Always active when UP is installed — no manual opt-in required.
function UPIntegration.isEnabled()
    return UPIntegration.isAvailable()
end

-- Called from MarketDynamics:onMissionLoaded.
function UPIntegration.init()
    if not UPIntegration.isAvailable() then
        MDMLog.info("UPIntegration: FS25_UsedPlus not detected — integration inactive")
        return
    end

    local upMod   = g_modManager:getModByName("FS25_UsedPlus")
    local version = (upMod and upMod.version) or "?"
    MDMLog.info("UPIntegration: FS25_UsedPlus detected (v" .. version .. ") — credit bridge and market modifiers active")
end

-- Save deal ID map. Called from MarketSerializer.
function UPIntegration.save(xmlFile, baseKey)
    local i = 0
    for contractId, upDealId in pairs(_dealIds) do
        local base = baseKey .. ".dealIds.entry(" .. i .. ")"
        -- Use modern XMLFile:setInt (v2.1+) and ensure numeric types
        xmlFile:setInt(base .. "#contractId", tonumber(contractId) or 0)
        xmlFile:setString(base .. "#upDealId",   tostring(upDealId))
        i = i + 1
    end
end

-- Load deal ID map. Called from MarketSerializer.
function UPIntegration.load(xmlFile, baseKey)
    _dealIds = {}
    local i = 0
    while true do
        local base = baseKey .. ".dealIds.entry(" .. i .. ")"
        if not xmlFile:hasProperty(base) then break end

        local contractId = xmlFile:getInt(base .. "#contractId")
        local upDealId   = xmlFile:getString(base .. "#upDealId")
        
        -- Fallback for old savegames where upDealId was an Int
        if not upDealId then
            local oldId = xmlFile:getInt(base .. "#upDealId")
            if oldId then upDealId = tostring(oldId) end
        end
        
        if contractId and upDealId then
            _dealIds[contractId] = upDealId
        end
        i = i + 1
    end
    MDMLog.info("UPIntegration: loaded " .. i .. " deal ID(s)")
end

-- Post-load re-registration pass for active contracts.
function UPIntegration.reregisterActiveContracts(contracts)
    if not UPIntegration.isEnabled() then return end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    local count = 0
    for _, contract in pairs(contracts) do
        if contract.status == "active" and not _dealIds[contract.id] then
            local upDealId = getAPI().registerExternalDeal(
                MOD_NAME, contract.id, contract.farmId, {
                    dealType       = "futures",
                    itemName       = contract.fillTypeName .. " Futures Contract",
                    originalAmount = contract.quantity * contract.lockedPrice,
                    monthlyPayment = 0,
                })
            if upDealId then
                _dealIds[contract.id] = upDealId
                count = count + 1
            else
                MDMLog.warn("UPIntegration: re-registration returned nil for contract #" .. contract.id)
            end
        end
    end

    if count > 0 then
        MDMLog.info("UPIntegration: re-registered " .. count .. " active contract(s) after load")
    end
end

-- ---------------------------------------------------------------------------
-- Futures contract hooks (called from FuturesMarket)
-- ---------------------------------------------------------------------------

function UPIntegration.onContractCreated(contractId, farmId, params)
    if not UPIntegration.isEnabled() then return end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    local upDealId = getAPI().registerExternalDeal(
        MOD_NAME, contractId, farmId, {
            dealType       = "futures",
            itemName       = params.fillTypeName .. " Futures Contract",
            originalAmount = params.quantity * params.lockedPrice,
            monthlyPayment = 0,
        })

    if upDealId then
        _dealIds[contractId] = upDealId
        MDMLog.info("UPIntegration: registered deal #" .. upDealId ..
            " for contract #" .. contractId)
    else
        MDMLog.warn("UPIntegration: registerExternalDeal returned nil for contract #" .. contractId)
    end
end

function UPIntegration.onContractFulfilled(contractId, farmId, payoutAmount)
    if not UPIntegration.isEnabled() then return end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    local upDealId = _dealIds[contractId]
    if not upDealId then
        MDMLog.warn("UPIntegration: no upDealId for fulfilled contract #" .. contractId)
        return
    end

    getAPI().reportExternalPayment(upDealId, payoutAmount)
    getAPI().closeExternalDeal(upDealId, "fulfilled")
    _dealIds[contractId] = nil
    MDMLog.info("UPIntegration: reported fulfillment for deal #" .. upDealId)
end

function UPIntegration.onContractDefaulted(contractId, farmId, penaltyAmount)
    if not UPIntegration.isEnabled() then return end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    local upDealId = _dealIds[contractId]
    if not upDealId then
        MDMLog.warn("UPIntegration: no upDealId for defaulted contract #" .. contractId)
        return
    end

    getAPI().reportExternalDefault(upDealId, false)
    getAPI().closeExternalDeal(upDealId, "defaulted")
    _dealIds[contractId] = nil
    MDMLog.info("UPIntegration: reported default for deal #" .. upDealId)
end

-- Returns a penalty multiplier based on the player's credit score.
--   Excellent credit (750+) → 0.67× → effective ~10% penalty
--   Normal credit (600-749) → 1.0×  → effective ~15% penalty
--   Poor credit   (<600)    → 1.33× → effective ~20% penalty
function UPIntegration.getPenaltyModifier(farmId)
    if not UPIntegration.isEnabled() then return PENALTY_MOD_DEFAULT end

    local score = UPIntegration.getCreditScore(farmId)
    if not score then return PENALTY_MOD_DEFAULT end

    if score >= CREDIT_TIER_EXCELLENT then
        return PENALTY_MOD_EXCELLENT
    elseif score < CREDIT_TIER_POOR then
        return PENALTY_MOD_POOR
    end
    return PENALTY_MOD_DEFAULT
end

function UPIntegration.getCreditScore(farmId)
    if not UPIntegration.isEnabled() then return nil end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return nil end
    return getAPI().getCreditScore(farmId)
end

-- ---------------------------------------------------------------------------
-- World event hooks (called from WorldEventSystem)
-- ---------------------------------------------------------------------------

function UPIntegration.onWorldEventFired(eventId, intensity, durationMs)
    if not UPIntegration.isEnabled() then return end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    local modFn = EVENT_MODIFIERS[eventId]
    if not modFn then
        MDMLog.debug("UPIntegration: no UP modifier mapping for event '" .. eventId .. "' — skipped")
        return
    end

    local multiplier    = modFn(intensity)
    local durationHours = durationMs / (60 * 60 * 1000)

    getAPI().applyMarketModifier(
        MOD_NAME, eventId, multiplier, durationHours, "ALL",
        "MDM: " .. eventId)

    MDMLog.info(string.format(
        "UPIntegration: applied market modifier '%s' — x%.3f for %.1fh",
        eventId, multiplier, durationHours))
end

function UPIntegration.onWorldEventExpired(eventId)
    if not UPIntegration.isEnabled() then return end
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    if not EVENT_MODIFIERS[eventId] then return end

    getAPI().removeMarketModifier(eventId)
    MDMLog.info("UPIntegration: removed market modifier for '" .. eventId .. "'")
end
