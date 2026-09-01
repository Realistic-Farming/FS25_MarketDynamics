-- BCIntegration.lua
-- Optional integration layer with FS25_FuturesMission (by Mmtrx).
--
-- FS25_FuturesMission is a companion mod that bridges BetterContracts harvest
-- missions with MDM's futures system. When it is installed this module:
--   1. Hooks AbstractMission.finish to detect successful harvest completions
--   2. Applies a short-lived supply-spike price modifier to the harvested crop
--      (large supply hits market → prices dip for ~1 in-game hour)
--   3. Cleans up expired supply-spike modifiers on each update tick
--
-- Futures contract integration (FuturesMission active):
--   FuturesMission silences MDM's own contract-creation dialog and instead calls:
--     BCIntegration.onBCContractCreated(params)   — at player signing
--     BCIntegration.onBCContractFulfilled(id)     — on successful delivery
--     BCIntegration.onBCContractDefaulted(id)     — on expiry without full delivery
--   FuturesMission may also query:
--     BCIntegration.getLockedPrice(fillTypeIndex)       — current MDM price per litre
--     BCIntegration.getPriceChangePercent(fillTypeIndex) — % change from vanilla base price
--     BCIntegration.getPenaltyPercent(farmId)           — effective penalty % (settings + UP credit)
--     BCIntegration.getDeliveryMs(periods)              — period count → absolute game-time ms (midnight)
--     BCIntegration.recordDelivery(contractId, liters)  — record partial delivery toward a contract
--     BCIntegration.getContractsForFarm(farmId)         — active MDM-only contracts (no bcManaged flag) for savegame migration
--
-- Detection: g_modManager:getModByName("FS25_FuturesMission")
-- Author: tison (dev-1)

BCIntegration = BCIntegration or {}

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local SUPPLY_SPIKE_FACTOR    = 0.92   -- -8% price drop on harvest completion
local SUPPLY_SPIKE_DURATION  = 60 * 60 * 1000  -- 1 in-game hour (ms)

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _hooked          = false  -- AbstractMission.finish hook installed?
local _marketEngine    = nil    -- reference set in init()
local _futuresMarket   = nil    -- reference set in init()
local _pendingRemovals = {}     -- { fillTypeIndex, modId, expiresAt }

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns true if FS25_FuturesMission is installed.
function BCIntegration.isAvailable()
    return g_modManager:getModByName("FS25_FuturesMission") ~= nil
end

-- Always active when FuturesMission is installed — no manual opt-in required.
function BCIntegration.isEnabled()
    return BCIntegration.isAvailable()
end

-- Called from MarketDynamics:onMissionLoaded — safe to hook game APIs here.
function BCIntegration.init(marketEngine, futuresMarket)
    _marketEngine  = marketEngine
    _futuresMarket = futuresMarket

    if not BCIntegration.isAvailable() then
        MDMLog.info("BCIntegration: FS25_FuturesMission not detected — integration inactive")
        return
    end

    local fmMod   = g_modManager:getModByName("FS25_FuturesMission")
    local version = (fmMod and fmMod.version) or "?"
    MDMLog.info("BCIntegration: FS25_FuturesMission detected (v" .. version .. ") — supply reactions active")

    BCIntegration._installHook()
end

-- Called from MarketDynamics:update(dt) every frame.
-- Removes supply-spike modifiers that have expired.
function BCIntegration.update()
    if not BCIntegration.isEnabled() or not _marketEngine then return end

    local now = g_currentMission and g_currentMission.time or 0
    local i = #_pendingRemovals
    while i >= 1 do
        local pending = _pendingRemovals[i]
        if now >= pending.expiresAt then
            _marketEngine:removeModifierById(pending.fillTypeIndex, pending.modId)
            MDMLog.info("BCIntegration: supply spike expired for fillType " .. pending.fillTypeIndex)
            table.remove(_pendingRemovals, i)
        end
        i = i - 1
    end
end

-- ---------------------------------------------------------------------------
-- FuturesMission → MDM entry points
-- ---------------------------------------------------------------------------

-- Called by BC at contract signing. Registers the contract in MDM's tracking list
-- and returns the MDM contract id so BC can reference it later.
--
-- params = { farmId, fillTypeIndex, fillTypeName, quantity, lockedPrice, deliveryTimeMs }
-- Returns: contractId (integer), or nil if futuresMarket is not ready.
function BCIntegration.onBCContractCreated(params)
    if not _futuresMarket then
        MDMLog.warn("BCIntegration.onBCContractCreated: futuresMarket not ready")
        return nil
    end

    -- bcManaged=true tells FuturesMarket._fulfillContract/_defaultContract to skip
    -- addMoney — BC handles payout and penalty through the base game mission system.
    params.bcManaged = true
    local id = _futuresMarket:createContract(params)
    MDMLog.info("BCIntegration: BC contract registered as MDM contract #" .. tostring(id))
    return id
end

-- Called by BC when a futures mission is successfully fulfilled.
-- BC has already paid out the locked price; MDM just updates its list and
-- notifies UPIntegration so the player's credit score improves.
function BCIntegration.onBCContractFulfilled(contractId)
    if not _futuresMarket then return end
    local contract = _futuresMarket.contracts[contractId]
    if not contract or contract.status ~= "active" then return end

    contract.status = "fulfilled"
    MDMLog.info("BCIntegration: contract #" .. tostring(contractId) .. " marked fulfilled by BC")
    UPIntegration.onContractFulfilled(contractId, contract.farmId, 0)
end

-- Called by BC when a futures mission expires without full delivery.
-- BC has already applied any penalty; MDM just updates its list and
-- notifies UPIntegration so the player's credit score is affected.
function BCIntegration.onBCContractDefaulted(contractId)
    if not _futuresMarket then return end
    local contract = _futuresMarket.contracts[contractId]
    if not contract or contract.status ~= "active" then return end

    contract.status = "defaulted"
    MDMLog.warn("BCIntegration: contract #" .. tostring(contractId) .. " marked defaulted by BC")
    UPIntegration.onContractDefaulted(contractId, contract.farmId, 0)
end

-- Returns MDM's current dynamic price per litre for a fill type.
-- BC should call this at the moment the player signs a contract to get the
-- locked price that MDM's engine has set (may differ from vanilla base price).
-- Returns nil if MDM has no price data for the fill type.
function BCIntegration.getLockedPrice(fillTypeIndex)
    if not _marketEngine or not _marketEngine.prices then return nil end
    local priceData = _marketEngine.prices[fillTypeIndex]
    return priceData and priceData.current or nil
end

-- Returns MDM's % price change from the vanilla base price for a fill type.
-- Positive values mean MDM is currently above base; negative means below.
-- Returns 0 if the fill type is unknown or the engine is not ready.
function BCIntegration.getPriceChangePercent(fillTypeIndex)
    if not _marketEngine then return 0 end
    return _marketEngine:getPriceChangePercent(fillTypeIndex)
end

-- Returns the effective penalty percent that would apply on a defaulted contract
-- for the given farm. Combines the player's futures-penalty setting with any
-- credit-score modifier from UPIntegration.
-- Example: settings.futuresPenalty=0.15, UP modifier=1.0 → returns 15.0
function BCIntegration.getPenaltyPercent(farmId)
    local settings    = g_MarketDynamics and g_MarketDynamics.settings
    local basePenalty = (settings and settings.futuresPenalty) or 0.15
    local modifier    = UPIntegration.getPenaltyModifier(farmId)
    return basePenalty * modifier * 100
end

-- Records a partial or full crop delivery toward a BC-managed MDM contract.
-- Call this from BC's sell-station hook when the normal delivery counting is
-- bypassed because an active harvest/futures mission is in progress.
-- Returns true if the contract is now fully fulfilled, false otherwise.
function BCIntegration.recordDelivery(contractId, liters)
    if not _futuresMarket then return false end
    return _futuresMarket:recordDelivery(contractId, liters)
end

-- Returns active MDM-native contracts for a farm — i.e. contracts that were
-- created by MDM directly (not via BC/FuturesMission) and are still active.
-- FuturesMission calls this on savegame load when BCIntegration is enabled so
-- it can take over tracking of any contracts that were written before FM was
-- installed.  bcManaged contracts are excluded because FM already owns those.
-- DESTRUCTIVE: each returned contract is removed from _futuresMarket.contracts
-- so that onBCContractCreated cannot create a duplicate when FM re-registers it.
function BCIntegration.getContractsForFarm(farmId)
    if not _futuresMarket then return {} end
    local result = {}
    local toRemove = {}
    for id, contract in pairs(_futuresMarket.contracts) do
        if contract.farmId == farmId
            and contract.status == "active"
            and not contract.bcManaged then
            table.insert(result, contract)
            table.insert(toRemove, id)
        end
    end
    for _, id in ipairs(toRemove) do
        _futuresMarket.contracts[id] = nil
        MDMLog.info("BCIntegration.getContractsForFarm: handed contract #" .. tostring(id) .. " to FM and removed from MDM")
    end
    return result
end

-- Converts a BC period count into an absolute game-time timestamp (ms) that
-- MDM's FuturesMarket uses for delivery deadlines.
--
-- The deadline is set at midnight (end-of-day) of the last day so that it
-- always aligns with BC's contract display, regardless of the time of signing.
-- Formula: skip to end of today, then add the full contract duration.
--
-- Giants calls a game month a "period". The player controls how many real
-- game-days fit in one period (g_currentMission.environment.daysPerPeriod, 1-30).
-- One game-day has a duration of environment.dayDuration milliseconds.
--
-- Example: periods=3, daysPerPeriod=30, dayDuration=3,600,000 ms (1 h/day), dayTime=1h
--   → deliveryTimeMs = now + (3,599,999 - 3,600,000) + 90 * 3,600,000  (midnight of day 90)
function BCIntegration.getDeliveryMs(periods)
    local env           = g_currentMission and g_currentMission.environment
    local daysPerPeriod = (env and env.daysPerSeason) or 30
    local now           = MDMUtil.getGameTime()
    local dayTime       = (env and env.dayTime) or 0
    -- Use game-world day length (86400000 ms), NOT env.dayDuration (real-time speed)
    return now + (86399999 - dayTime) + (periods * daysPerPeriod * 86400000)
end

-- ---------------------------------------------------------------------------
-- Private
-- ---------------------------------------------------------------------------

function BCIntegration._installHook()
    if _hooked then return end
    _hooked = true

    AbstractMission.finish = Utils.appendedFunction(
        AbstractMission.finish,
        BCIntegration._onMissionFinish
    )

    MDMLog.info("BCIntegration: AbstractMission.finish hook installed")
end

-- Appended to AbstractMission.finish — receives (self=mission, finishState).
-- Only reacts to successful harvest missions.
function BCIntegration._onMissionFinish(mission, finishState)
    if not BCIntegration.isEnabled() or not _marketEngine then return end

    if finishState ~= MissionFinishState.SUCCESS then return end

    local fruitTypeIndex = nil
    if mission.fruitType and mission.fruitType.index then
        fruitTypeIndex = mission.fruitType.index
    end
    if not fruitTypeIndex then return end

    if not g_fruitTypeManager then return end
    local fillTypeIndex = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
    if not fillTypeIndex or fillTypeIndex <= 1 then return end

    if not _marketEngine.prices[fillTypeIndex] then return end

    local now   = g_currentMission and g_currentMission.time or 0
    local modId = "bc_supply_" .. fillTypeIndex .. "_" .. tostring(now)

    _marketEngine:addModifier({
        id            = modId,
        fillTypeIndex = fillTypeIndex,
        factor        = SUPPLY_SPIKE_FACTOR,
    })

    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local name     = fillType and fillType.name or tostring(fillTypeIndex)
    MDMLog.info(string.format(
        "BCIntegration: supply spike applied to %s (-%d pct for 1h)",
        name, math.floor((1 - SUPPLY_SPIKE_FACTOR) * 100)))

    table.insert(_pendingRemovals, {
        fillTypeIndex = fillTypeIndex,
        modId         = modId,
        expiresAt     = now + SUPPLY_SPIKE_DURATION,
    })
end
