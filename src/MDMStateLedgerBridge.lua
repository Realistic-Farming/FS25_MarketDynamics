-- =========================================================
-- FS25 Market Dynamics - StateLedger bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_StateLedger (bedrock). Strictly delegate-when-present,
-- mirroring SoilFertilizer / TaxMod / WorkerCosts:
--
--   * StateLedger installed -> the shared master save file is the LOAD source of
--     truth for the DURABLE market state: futures contracts, prices + history,
--     world-event cooldowns, lastGameTime + volatilityScale. The mod's own
--     modSettings/FS25_MarketDynamics.xml is still written every save as the
--     standalone safety copy, so removing the ledger later never loses data.
--   * StateLedger absent    -> nothing changes; the own XML is primary.
--
-- ONE module: MarketDynamics_State. Settings are NOT a StateLedger module here
-- (SettingsHub owns those; the own XML is their fallback). Active world events and
-- UPIntegration state are left to the own-XML load on purpose - see the notes on
-- MarketSerializer:toTable.
--
-- Load ordering (in MarketDynamics:onStartMission, server only): serializer:load()
-- imports settings + state from the own XML first, THEN, when the shared ledger is
-- present, applyState overrides the state portion. This runs before
-- cleanupStaleEntries + reregisterActiveContracts so the ledger state flows through
-- the same post-load pipeline (UP linkage rebuilt from each contract's upDealId).
--
-- Timing: MDM registers here in onStartMission, a LATER phase than StateLedger's
-- own parse (loadMission00Finished), so registerModule delivers deserialize
-- immediately (the ledger has already parsed). register() still force-triggers the
-- idempotent parseFile as the belt-and-suspenders guard the other bridges use, so
-- hasState() is accurate the moment register() returns regardless of load order.
--
-- The cross-mod handle is g_currentMission.stateLedger (published in Mission00.load).
-- =========================================================

MDMStateLedgerBridge = MDMStateLedgerBridge or {}

-- Provisional persistence key. This is the KEY inside the master file, so it must
-- be locked with Claude(A) before any release (a later rename orphans saved market
-- state). Matches StateLedger's <Mod>_<Thing> convention.
MDMStateLedgerBridge.MODULE_ID = "MarketDynamics_State"

MDMStateLedgerBridge.active       = false   -- ledger present and we registered
MDMStateLedgerBridge.delivered    = false   -- deserialize has fired (once)
MDMStateLedgerBridge.pendingState = nil     -- cached table (nil = new save / no block)

-- True when the ledger is the state load source of truth this session (present,
-- registered, and it delivered an actual block). When present but empty (new save
-- or first load after installing the ledger), serializer:load's own-XML state stands.
function MDMStateLedgerBridge.hasState()
    return MDMStateLedgerBridge.active
        and MDMStateLedgerBridge.delivered
        and MDMStateLedgerBridge.pendingState ~= nil
end

-- Apply the cached state block into the coordinator. Returns true on apply.
function MDMStateLedgerBridge.applyState(mdm)
    if mdm == nil or type(MDMStateLedgerBridge.pendingState) ~= "table" then return false end
    return MarketSerializer:applyTable(mdm, MDMStateLedgerBridge.pendingState)
end

-- Register with StateLedger if present. Called from MarketDynamics:onStartMission
-- (server only), after serializer:load() has imported the own-XML safety copy.
function MDMStateLedgerBridge.register(mdm)
    -- Reset per-load so a map swap / reload starts clean.
    MDMStateLedgerBridge.active       = false
    MDMStateLedgerBridge.delivered    = false
    MDMStateLedgerBridge.pendingState = nil

    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then
        MDMLog.info("Market Dynamics: StateLedger not detected; state uses its own FS25_MarketDynamics.xml")
        return
    end
    if mdm == nil then return end

    local ok, err = pcall(function()
        ledger:registerModule(MDMStateLedgerBridge.MODULE_ID, {
            serialize = function()
                return MarketSerializer:toTable(mdm)
            end,
            deserialize = function(data)
                MDMStateLedgerBridge.delivered    = true
                MDMStateLedgerBridge.pendingState = data   -- nil on a brand-new save
            end,
        })
    end)

    if not ok then
        MDMLog.warn("Market Dynamics: StateLedger registration failed: " .. tostring(err) .. " (falling back to own XML)")
        return
    end

    MDMStateLedgerBridge.active = true

    -- Force the idempotent parse now so deserialize has delivered before the caller
    -- checks hasState(). A no-op if StateLedger already parsed (it loaded first), in
    -- which case deserialize fired at registerModule above.
    if ledger.parseFile ~= nil then
        pcall(function() ledger:parseFile() end)
    end

    MDMLog.info("Market Dynamics: Registered with StateLedger as '" .. MDMStateLedgerBridge.MODULE_ID
        .. "' (FS25_MarketDynamics.xml kept as safety copy)")
end
