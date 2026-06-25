-- FuturesMarket.lua
-- Handles futures contract creation, tracking, and fulfillment.
-- Players lock in a price + quantity + delivery date.
-- True-futures settlement: every committed (delivered) liter nets EXACTLY the
-- locked price. The player is paid the live market rate at the selling station;
-- the contract then settles the difference — topping up when the market was below
-- the locked price, or clawing back the excess when the market was above it.
-- On delivery date: if fulfilled → committed quantity nets exactly the locked value;
--                   if defaulted → delivered portion settles at the locked price,
--                                  minus a penalty on the unfulfilled portion.
--
-- UPIntegration hooks:
--   onContractCreated   — notified when a new contract is written
--   onContractFulfilled — notified on full delivery (for credit score up)
--   onContractDefaulted — notified on default (for credit score down)
--   getPenaltyModifier  — scales DEFAULT_PENALTY per player credit score
--
-- Author: tison (dev-1)

FuturesMarket = {}
FuturesMarket.__index = FuturesMarket

-- Base penalty rate for defaulting on a contract (fraction of unfulfilled contract value).
-- UPIntegration.getPenaltyModifier() may scale this up or down based on credit score.
local DEFAULT_PENALTY = 0.15

function FuturesMarket.new()
    local self = setmetatable({}, FuturesMarket)

    -- { [contractId] = Contract }
    self.contracts  = {}
    self.nextId     = 1

    -- Tracks the last known timeScale so we can detect mid-session changes that
    -- affect real-days contract deadlines.
    self._lastKnownTimeScale = nil

    MDMLog.info("FuturesMarket initialized")
    return self
end

-- Create a new futures contract.
-- params = { farmId, fillTypeIndex, fillTypeName, quantity, lockedPrice, deliveryTimeMs }
-- Returns contractId.
function FuturesMarket:createContract(params)
    local id = self.nextId
    self.nextId = self.nextId + 1

    local now = MDMUtil.getGameTime()
    local contract = {
        id                = id,
        farmId            = params.farmId,
        fillTypeIndex     = params.fillTypeIndex,
        fillTypeName      = params.fillTypeName,
        quantity          = params.quantity,       -- in liters
        lockedPrice       = params.lockedPrice,    -- per liter at contract creation
        deliveryTime      = params.deliveryTimeMs, -- absolute game time (ms)
        deliveryStartTime = now,                   -- can start delivering immediately
        delivered         = 0,                     -- liters delivered so far
        valueReceived     = 0,                     -- total money received during unloading at stations
        status            = "active",              -- active | fulfilled | defaulted
        isRealDays        = params.isRealDays or false,
        createdTimeScale  = params.createdTimeScale or 1,
    }

    self.contracts[id] = contract
    MDMLog.info("FuturesMarket: contract #" .. id .. " created — " .. params.fillTypeName ..
        " x" .. params.quantity .. "L @ " .. params.lockedPrice)

    -- Notify UPIntegration so it can register this as an external deal if UP mode is on.
    UPIntegration.onContractCreated(id, params.farmId, params)

    -- Broadcast new contract to all connected clients so they see it immediately.
    if g_server ~= nil then
        MDMContractSyncEvent.sendToClients(MDMContractSyncEvent.SYNC_UPDATE, contract)
    end

    return id
end

-- Record a partial or full delivery toward an active contract.
-- Returns true if the contract is now fully fulfilled, false otherwise.
function FuturesMarket:recordDelivery(contractId, liters, pricePerLiter)
    local contract = self.contracts[contractId]
    if not contract or contract.status ~= "active" then return false end

    contract.delivered = contract.delivered + liters
    
    -- Track value already received by the player at the selling station so we can
    -- subtract it from the final payout. This prevents "double pay" where the
    -- player gets the market price PLUS the full contract price.
    if pricePerLiter and pricePerLiter > 0 then
        contract.valueReceived = (contract.valueReceived or 0) + (liters * pricePerLiter)
    end

    if contract.delivered >= contract.quantity then
        self:_fulfillContract(contractId)
        return true
    end

    if g_server ~= nil then
        MDMContractSyncEvent.sendToClients(MDMContractSyncEvent.SYNC_UPDATE, contract)
    end

    return false
end

-- Check all active contracts for delivery deadline expiry.
-- Called every frame from MarketDynamics:update().
function FuturesMarket:checkExpiry()
    local now = MDMUtil.getGameTime()

    for id, contract in pairs(self.contracts) do
        -- Safety: ensure contract.deliveryTime exists and is not zero (corrupt load)
        if contract.status == "active" and contract.deliveryTime and contract.deliveryTime > 0 then
            if now >= contract.deliveryTime then
                if contract.delivered >= contract.quantity then
                    self:_fulfillContract(id)
                else
                    self:_defaultContract(id)
                end
            end
        end
    end
end

-- Warn once per timeScale change if any active real-days contracts exist.
-- Called every frame from MarketDynamics:update(). A perfect fix is impossible
-- since os.time() is unavailable in FS25 — this at least makes the drift visible.
function FuturesMarket:checkTimeScaleDrift()
    local ts = g_currentMission and g_currentMission.timeScale or 1
    if self._lastKnownTimeScale == nil then
        self._lastKnownTimeScale = ts
        return
    end
    if ts == self._lastKnownTimeScale then return end

    -- timeScale changed — check if any active real-days contracts are affected
    for _, contract in pairs(self.contracts) do
        if contract.status == "active" and contract.isRealDays then
            MDMLog.warn(string.format(
                "FuturesMarket: time scale changed (%.0f→%.0f) while real-day contracts are active — deadlines will drift",
                self._lastKnownTimeScale, ts))
            if g_localPlayer then
                local msg = g_i18n:getText("mdm_timescale_drift_warning")
                    or "Time scale changed — real-day contract deadlines may be affected."
                g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, msg)
            end
            break
        end
    end
    self._lastKnownTimeScale = ts
end

-- Called from the SellingStation delivery hook on every accepted crop sale.
-- Routes liters to all active contracts matching this farm + fillType, oldest first.
-- Excess liters (beyond what contracts need) are silently ignored — normal selling.
-- Deliveries before the contract's deliveryStartTime do not count toward the contract
-- (the locked price applies to future production, not existing inventory).
function FuturesMarket:onCropDelivered(farmId, fillTypeIndex, liters, pricePerLiter)
    local now = MDMUtil.getGameTime()
    local remaining = liters
    
    MDMLog.debug(string.format("FuturesMarket:onCropDelivered(farmId=%s, ft=%s, liters=%.1f, price=%.4f) now=%s",
        tostring(farmId), tostring(fillTypeIndex), liters, pricePerLiter or 0, tostring(now)))

    local foundMatch = false
    for id, contract in pairs(self.contracts) do
        if remaining <= 0 then break end
        
        local timeMatch = now >= (contract.deliveryStartTime or 0)
        local farmMatch = contract.farmId == farmId
        local typeMatch = contract.fillTypeIndex == fillTypeIndex
        local statusMatch = contract.status == "active"
        
        if statusMatch and farmMatch and typeMatch and timeMatch then
            foundMatch = true
            local needed   = contract.quantity - contract.delivered
            local applying = math.min(remaining, needed)
            
            MDMLog.debug(string.format("  -> Matching contract #%d: applying %.1fL (needed %.1fL)",
                id, applying, needed))
                
            self:recordDelivery(id, applying, pricePerLiter)
            remaining = remaining - applying
        end
    end
    
    if not foundMatch then
        MDMLog.debug("  -> No matching active contract found for this delivery.")
    end
end

-- Returns all contracts belonging to a given farm (for GUI display).
function FuturesMarket:getContractsForFarm(farmId)
    local result = {}
    for _, contract in pairs(self.contracts) do
        if contract.farmId == farmId then
            table.insert(result, contract)
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Private
-- ---------------------------------------------------------------------------

-- Pay out the full locked-price value for a fulfilled contract.
-- Guard against double-pay: recordDelivery() and checkExpiry() can both
-- reach this function for the same contract on the same frame. The status
-- check ensures the payout only ever happens once.
function FuturesMarket:_fulfillContract(id)
    local contract = self.contracts[id]
    if not contract then return end
    if contract.status ~= "active" then return end  -- already settled; skip
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    contract.status = "fulfilled"

    -- BC-managed contracts: payout is handled by the base game mission system.
    -- MDM must not pay a second time; just update state and notify UP.
    if contract.bcManaged then
        MDMLog.info("FuturesMarket: contract #" .. id .. " FULFILLED (BC-managed — no MDM payout)")
        UPIntegration.onContractFulfilled(id, contract.farmId, 0)
        return
    end

    -- True-futures settlement: the committed quantity always nets exactly the
    -- locked value. The player already received market-rate money at the selling
    -- station (tracked in valueReceived); the contract settles the difference.
    -- A positive settlement tops up a below-locked market; a negative settlement
    -- claws back the excess from an above-locked market. Either way the final
    -- total received for the committed crop is (quantity * lockedPrice). (issue #92)
    local totalTarget = contract.quantity * contract.lockedPrice
    local settlement  = totalTarget - (contract.valueReceived or 0)

    if settlement ~= 0 then
        g_currentMission:addMoney(settlement, contract.farmId, MoneyType.OTHER, true, true)
    end

    MDMLog.info(string.format("FuturesMarket: contract #%d FULFILLED — locked value $%.2f, received at market $%.2f, settlement $%.2f",
        id, totalTarget, (contract.valueReceived or 0), settlement))

    -- HUD notification (only show to the owning farm's local player)
    if g_localPlayer and g_localPlayer.farmId == contract.farmId then
        local amtStr = g_i18n:formatMoney(math.floor(math.abs(settlement) + 0.5), 0, true, false)
        local msg
        if settlement >= 0 then
            msg = string.format("Contract fulfilled: %s — settled at locked price (+$%s)",
                contract.fillTypeName, amtStr)
        else
            msg = string.format("Contract fulfilled: %s — settled at locked price (-$%s, market was higher)",
                contract.fillTypeName, amtStr)
        end
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, msg)
    end

    -- Notify UPIntegration for credit score reporting (report the full contract value).
    UPIntegration.onContractFulfilled(id, contract.farmId, totalTarget)

    -- Broadcast fulfilled status to all connected clients.
    if g_server ~= nil then
        MDMContractSyncEvent.sendToClients(MDMContractSyncEvent.SYNC_UPDATE, contract)
    end
end

-- Settle a defaulted contract: the delivered portion settles at the locked price
-- (true futures — same as a fulfilled contract, just for fewer liters), minus a
-- penalty on the unfulfilled portion.
--
-- Effective penalty rate = DEFAULT_PENALTY * UPIntegration.getPenaltyModifier()
--   Excellent credit (750+) → ~10% effective penalty
--   Normal credit           → ~15% effective penalty  (no UP or unknown score)
--   Poor credit    (<600)   → ~20% effective penalty
--
-- The net settlement is NOT floored at 0 and may be negative. This is required for
-- consistency with the fulfilled path: if completing a contract claws back market
-- excess but defaulting did not, players could deliberately default whenever the
-- market rose above the locked price and keep the windfall — making a default more
-- profitable than completing. Allowing the clawback (and a real penalty on a pure
-- default) closes that exploit and gives the futuresPenalty setting teeth. (issue #92)
function FuturesMarket:_defaultContract(id)
    local contract = self.contracts[id]
    if not contract then return end
    if contract.status ~= "active" then return end  -- already settled; skip
    if g_currentMission and g_currentMission.isClient and not g_currentMission.isServer then return end

    contract.status = "defaulted"

    -- BC-managed contracts: penalty is handled by the base game mission system.
    if contract.bcManaged then
        MDMLog.warn("FuturesMarket: contract #" .. id .. " DEFAULTED (BC-managed — no MDM penalty)")
        UPIntegration.onContractDefaulted(id, contract.farmId, 0)
        return
    end

    local delivered   = contract.delivered
    local unfulfilled = contract.quantity - delivered

    -- Delivered liters settle at the locked price (true futures), same as a
    -- fulfilled contract: locked value for what was delivered, minus the market
    -- money the player already received at the station.
    local deliveredSettlement = (delivered * contract.lockedPrice) - (contract.valueReceived or 0)

    -- Base penalty comes from player settings; UP credit score may scale it further.
    local settings    = g_MarketDynamics and g_MarketDynamics.settings
    local basePenalty = (settings and settings.futuresPenalty) or DEFAULT_PENALTY
    local penaltyRate = basePenalty * UPIntegration.getPenaltyModifier(contract.farmId)
    local penalty     = unfulfilled * contract.lockedPrice * penaltyRate

    -- Net settlement = delivered-portion adjustment minus the shortfall penalty.
    -- May be negative (a charge) — see the note above _defaultContract.
    local net = deliveredSettlement - penalty

    if net ~= 0 then
        g_currentMission:addMoney(net, contract.farmId, MoneyType.OTHER, true, true)
    end

    MDMLog.warn(string.format(
        "FuturesMarket: contract #%d DEFAULTED — delivered settlement $%.2f, penalty -$%.2f, received at market $%.2f, net $%.2f",
        id, deliveredSettlement, penalty, (contract.valueReceived or 0), net))

    -- HUD notification (only show to the owning farm's local player)
    if g_localPlayer and g_localPlayer.farmId == contract.farmId then
        local amtStr = g_i18n:formatMoney(math.floor(math.abs(net) + 0.5), 0, true, false)
        local msg
        if net >= 0 then
            msg = string.format("Contract defaulted: %s — %dL/%dL delivered, settled +$%s after penalty",
                contract.fillTypeName, delivered, contract.quantity, amtStr)
        else
            msg = string.format("Contract defaulted: %s — %dL/%dL delivered, charged $%s after penalty",
                contract.fillTypeName, delivered, contract.quantity, amtStr)
        end
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msg)
    end

    -- Notify UPIntegration for credit score reporting.
    UPIntegration.onContractDefaulted(id, contract.farmId, penalty)

    if g_server ~= nil then
        MDMContractSyncEvent.sendToClients(MDMContractSyncEvent.SYNC_UPDATE, contract)
    end
end

-- ---------------------------------------------------------------------------
-- Admin actions (called from MDMContractAdminDialog)
-- ---------------------------------------------------------------------------

--- Force-complete an active contract: pays out full locked price * quantity
--- regardless of how much has actually been delivered.
--- Safe to call if contract is already settled (no-op).
function FuturesMarket:adminComplete(contractId)
    local contract = self.contracts[contractId]
    if not contract then return end
    if contract.status ~= "active" then return end
    -- Mark as fully delivered so _fulfillContract pays the full amount.
    contract.delivered = contract.quantity
    self:_fulfillContract(contractId)
    MDMLog.info("FuturesMarket: admin forced completion of contract #" .. contractId)
end

--- Remove an active contract with no payout and no penalty.
function FuturesMarket:adminCancel(contractId)
    local contract = self.contracts[contractId]
    if not contract then return end
    if contract.status ~= "active" then return end
    self.contracts[contractId] = nil
    MDMLog.info("FuturesMarket: admin cancelled (removed) contract #" .. contractId)
    if g_server ~= nil then
        MDMContractSyncEvent.sendToClients(MDMContractSyncEvent.SYNC_REMOVE, {id = contractId})
    end
end

--- Player-initiated forfeit: immediately defaults the contract, applying
--- the standard penalty rate to the unfulfilled portion.
function FuturesMarket:playerForfeit(contractId)
    local contract = self.contracts[contractId]
    if not contract then return end
    if contract.status ~= "active" then return end
    
    MDMLog.info("FuturesMarket: player forfeited contract #" .. contractId)
    self:_defaultContract(contractId)
end

--- Remove a settled (fulfilled or defaulted) contract from the list.
function FuturesMarket:adminDelete(contractId)
    local contract = self.contracts[contractId]
    if not contract then return end
    if contract.status == "active" then return end
    self.contracts[contractId] = nil
    MDMLog.info("FuturesMarket: admin deleted settled contract #" .. contractId)
    if g_server ~= nil then
        MDMContractSyncEvent.sendToClients(MDMContractSyncEvent.SYNC_REMOVE, {id = contractId})
    end
end

