-- PriceHook.lua
-- Hooks SellingStation to route sell prices through MDM's modifier stack and
-- to track crop deliveries against active futures contracts.
--
-- Installed at source() time. Uses a sentinel (_G.MDM_PriceHook_installed) so
-- re-sourcing is idempotent.
--
-- Why SellingStation, not EconomyManager:
--   SellingStation caches its fillTypeInfos at map load and then calls its own
--   getPricePerLiter() at sell time — it never calls back into EconomyManager
--   during gameplay.  Hooking EconomyManager.getPricePerLiter therefore has no
--   effect on prices the player actually sees at a selling station.
--
-- Price hook (SellingStation.getEffectiveFillTypePrice):
--   Dormant until g_MarketDynamics.isActive = true.
--   If coordinator.settings.pricesEnabled = false, passes through to vanilla.
--
-- Delivery hook (SellingStation.sellFillType):
--   On every accepted crop delivery, notifies FuturesMarket so partial/full
--   contract fulfillment is tracked without a separate polling loop.
--   Server-only; no-op on pure clients.
--
-- Public helper:
--   MDMGetVanillaPrice(economyManager, fillTypeIndex) → number | nil
--     Returns the vanilla sell price at neutral supply/demand (pressure = 0).
--     Used by MarketEngine:init() for base price snapshotting.
--     Reads directly from EconomyManager (never patched) so it is always safe.
--
-- Author: tison (dev-1)

if _G.MDM_PriceHook_installed then
    MDMLog.info("PriceHook: already installed, skipping")
    return
end
_G.MDM_PriceHook_installed = true


-- ---------------------------------------------------------------------------
-- EconomyManager reference — used only for MDMGetVanillaPrice, never patched.
-- ---------------------------------------------------------------------------

-- We intentionally do NOT capture EconomyManager.getPricePerLiter at source time.
-- Economy mods (e.g. Realistic Economy) hook getPricePerLiter after MDM sources,
-- so a source-time capture would always return vanilla prices regardless of those mods.
-- By calling the live method at init() time we automatically pick up whatever base
-- prices any economy mod has installed.

if EconomyManager and EconomyManager.getPricePerLiter then
    MDMLog.info("PriceHook: EconomyManager.getPricePerLiter available for base price snapshots")
else
    MDMLog.warn("PriceHook: EconomyManager.getPricePerLiter not found — MDMGetVanillaPrice will return nil")
end

-- ---------------------------------------------------------------------------
-- SellingStation price hook
-- ---------------------------------------------------------------------------

if SellingStation and SellingStation.getEffectiveFillTypePrice then
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(
        SellingStation.getEffectiveFillTypePrice,
        function(self, superFunc, fillTypeIndex)
            local price = superFunc(self, fillTypeIndex)
            if type(price) ~= "number" or price <= 0 then return price end

            -- Dormant until MDM is fully initialized
            if not g_MarketDynamics or not g_MarketDynamics.isActive then
                return price
            end

            -- Respect the "Dynamic Prices" setting (ESC > Settings > Market Dynamics)
            if g_MarketDynamics.settings and not g_MarketDynamics.settings.pricesEnabled then
                return price
            end

            -- [MD-16] Inside a qualified paid sale phase, the native body's one
            -- price read (SellingStation.lua:356) takes the material rate. It is
            -- answered once, to this station and this fill type only; every
            -- other read, the futures read after the sale included, falls
            -- through to the ordinary market price below.
            if Md16SalePhase ~= nil then
                local md16Rate = Md16SalePhase.rateFor(self, fillTypeIndex)
                if md16Rate ~= nil then
                    return md16Rate
                end
            end

            local mdmPrice = g_MarketDynamics.marketEngine:getPrice(fillTypeIndex)
            if mdmPrice and mdmPrice > 0 then
                return mdmPrice
            end

            -- Fallback: fillType not tracked by MDM (e.g. added by another mod)
            return price
        end
    )

    MDMLog.info("PriceHook: SellingStation.getEffectiveFillTypePrice hooked")
else
    MDMLog.warn("PriceHook: SellingStation.getEffectiveFillTypePrice not found — price hook disabled")
end

-- ---------------------------------------------------------------------------
-- SellingStation delivery hook (futures contract tracking)
-- ---------------------------------------------------------------------------

-- Pack a call's results with their count, so a value after a nil survives.
local function packResults(...)
    return select("#", ...), { ... }
end

-- The futures delivery report for one accepted sale call (server only).
-- In FS25, we use fillDelta (requested) because result (accepted) can be
-- unreliable in some selling station configurations.
local function reportDelivery(station, farmId, fillDelta, fillTypeIndex, md16Entry)
    if g_server == nil or not g_MarketDynamics or not g_MarketDynamics.isActive
        or not g_MarketDynamics.futuresMarket then
        return
    end

    MDMLog.debug(string.format("PriceHook: SellingStation.sellFillType(farmId=%s, delta=%.1f, ft=%s)",
        tostring(farmId), tostring(fillDelta), tostring(fillTypeIndex)))

    if fillDelta and fillDelta > 0 then
        -- [MD-16] When this call's native read took the material rate, its
        -- contract litres were frozen at the baseline before the sale, and the
        -- tracker is told exactly that (Md16FuturesPlan's optional fifth
        -- argument). Otherwise the unchanged legacy scan runs on the price read
        -- after the sale.
        local allocation = md16Entry ~= nil and Md16SalePhase ~= nil and Md16SalePhase.allocationContext(md16Entry) or nil
        if allocation ~= nil then
            g_MarketDynamics.futuresMarket:onCropDelivered(farmId, fillTypeIndex, fillDelta,
                md16Entry.baselineRate, allocation)
        else
            local pricePerLiter = station:getEffectiveFillTypePrice(fillTypeIndex)
            g_MarketDynamics.futuresMarket:onCropDelivered(farmId, fillTypeIndex, fillDelta, pricePerLiter)
        end
    end
end

if SellingStation and SellingStation.sellFillType then
    SellingStation.sellFillType = Utils.overwrittenFunction(
        SellingStation.sellFillType,
        -- [MD-16] THE NATIVE SALE VECTOR IS FIVE ARGUMENTS, NOT SIX.
        -- This wrapper declared (farmId, fillDelta, fillTypeIndex, fillPositionData,
        -- toolType, extraAttributes). Native sellFillType takes
        -- (farmId, fillDelta, fillTypeIndex, toolType, extraAttributes): there is no
        -- position argument. Forwarding the unchanged positional vector still passed
        -- the native toolType and extraAttributes through in their original slots, so
        -- the pass-through alone did NOT drop them, and saying otherwise would be
        -- wrong. What it did was misname the wrapper's own locals: `fillPositionData`
        -- actually held the tool type and `toolType` actually held the extra
        -- attributes, while `extraAttributes` was always nil. Any MD-16 work that
        -- reads a named local here, and the correctly bound original getter, both
        -- need the real five-slot shape.
        function(self, superFunc, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
            -- [MD-16] Qualify this paid call BEFORE the native body runs, inside
            -- the paid phase StockGuard's station bracket has just opened around
            -- it (Md16SalePhase). Server only; an entry is pushed for every call,
            -- qualified or not, so a nested sale never reads this call's rate.
            local md16Entry = nil
            if g_server ~= nil and Md16SalePhase ~= nil then
                local okOpen, opened = pcall(Md16SalePhase.open, self, farmId, fillDelta, fillTypeIndex)
                if okOpen then md16Entry = opened end
            end

            -- The native body, under protection so the entry is closed on an
            -- error too; the original error then propagates unchanged.
            local count, packed = packResults(pcall(superFunc, self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes))
            if md16Entry ~= nil then pcall(Md16SalePhase.close, md16Entry) end
            if not packed[1] then
                if md16Entry ~= nil then pcall(Md16SalePhase.release, md16Entry) end
                error(packed[2], 0)
            end

            -- The futures report runs with this call's CLOSED entry still on top,
            -- so its own price read can never reach an outer call's rate; the
            -- entry comes off afterwards whether the report returned or raised.
            local okReport, reportErr = pcall(reportDelivery, self, farmId, fillDelta, fillTypeIndex, md16Entry)
            if md16Entry ~= nil then pcall(Md16SalePhase.release, md16Entry) end
            if not okReport then error(reportErr, 0) end

            -- Every value the native body returned, in its own slots.
            return unpack(packed, 2, count)
        end
    )

    MDMLog.info("PriceHook: SellingStation.sellFillType hooked for futures tracking")
else
    MDMLog.warn("PriceHook: SellingStation.sellFillType not found — futures delivery tracking disabled")
end

-- addFillLevelFromTool hook intentionally removed: standard selling stations call both
-- sellFillType and addFillLevelFromTool at the same call-stack level, so the re-entrancy
-- guard never engages and every delivery was double-counted. sellFillType is authoritative.

-- ---------------------------------------------------------------------------
-- Public helper: vanilla price snapshot for MarketEngine:init()
-- ---------------------------------------------------------------------------

-- Returns the base sell price for a fillType at neutral supply/demand (pressure = 0).
-- Calls the live getPricePerLiter so economy mods (e.g. Realistic Economy) that hook
-- it after PriceHook sources are automatically used as MDM's price base.
function MDMGetVanillaPrice(economyManager, fillTypeIndex)
    if economyManager and type(economyManager.getPricePerLiter) == "function" then
        return economyManager:getPricePerLiter(fillTypeIndex, 0)
    end
    return nil
end
