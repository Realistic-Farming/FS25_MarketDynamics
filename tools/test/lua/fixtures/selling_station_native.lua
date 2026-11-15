-- selling_station_native.lua - the native sale path the MD-16 sale bar runs on.
--
-- Loaded BEFORE src/PriceHook.lua so PriceHook wraps this class at its own
-- source time, exactly as it wraps the engine's in game. Each body copies the
-- 1.24.0.0 decompile (D:\FS25_Decoded\dataS\scripts_decompiled) where MD-16
-- depends on it, and says where it simplifies.

-- utils/Utils.lua:394-401: superFunc is the old function, called with self.
Utils = Utils or {}
function Utils.overwrittenFunction(oldFunc, newFunc)
    if oldFunc == nil then
        return function(self, ...) return newFunc(self, nil, ...) end
    end
    return function(self, ...) return newFunc(self, oldFunc, ...) end
end

-- PriceHook only probes EconomyManager.getPricePerLiter at load.
EconomyManager = EconomyManager or { getPricePerLiter = function() return 1 end }

SellingStation = {}
local SellingStation_mt = { __index = SellingStation }

function SellingStation.newBench(name, nativePrices)
    local self = setmetatable({}, SellingStation_mt)
    self.name = name
    self.nativePrices = nativePrices or {}
    self.priceReads = {}        -- every value getEffectiveFillTypePrice returned, in order
    self.paid = {}              -- every price sellFillType paid
    self.extraReadInside = false
    return self
end

-- objects/SellingStation.lua:343-348.
function SellingStation:getStoreGoods(_farmId, _fillTypeIndex) return false end
function SellingStation:getSkipSell(_farmId, _fillTypeIndex) return false end

-- objects/SellingStation.lua:370-381, reduced to the station's own price: the
-- seasonal and economy factors are native arithmetic PriceHook replaces on its
-- tracked branch, and the bench only needs the value to be positive and known.
function SellingStation:getEffectiveFillTypePrice(fillType, _toolType)
    return self.nativePrices[fillType] or 0
end

-- objects/SellingStation.lua:349-369. The price is read ONCE (:356) and paid as
-- fillDelta * pricePerLiter (:360) through addMoney (:364). The price drop and
-- statistics are left out; they do not touch the rate. extraReadInside adds a
-- second read after the native one, foreignReadInside a read for another
-- station or type before it: neither may receive the material rate.
function SellingStation:sellFillType(farmId, fillDelta, fillTypeIndex, toolType, _extraAttributes)
    if self.throwInside then error("native body failed", 0) end
    -- A foreign mod's sale nested inside this one, before this call's own read.
    if self.nestedSaleInside ~= nil then
        local n = self.nestedSaleInside
        self.nestedSaleInside = nil
        -- Through the CLASS method, as a foreign mod calling it directly would:
        -- StockGuard's instance bracket never sees it and opens no phase for it.
        SellingStation.sellFillType(n.station, n.farmId, n.fillDelta, n.fillTypeIndex, toolType, nil)
    end
    -- A foreign read BEFORE this call's own read, so it is the first chance to
    -- take the rate: it must not.
    if self.foreignReadInside ~= nil then
        local other = self.foreignReadInside
        self.foreignReads = self.foreignReads or {}
        self.foreignReads[#self.foreignReads + 1] = other.station:getEffectiveFillTypePrice(other.fillTypeIndex, toolType)
    end
    local pricePerLiter = self:getEffectiveFillTypePrice(fillTypeIndex, toolType)
    self.priceReads[#self.priceReads + 1] = pricePerLiter
    if self.extraReadInside then
        self.priceReads[#self.priceReads + 1] = self:getEffectiveFillTypePrice(fillTypeIndex, toolType)
    end
    local price = fillDelta * pricePerLiter
    self.paid[#self.paid + 1] = price
    g_currentMission:addMoney(price, farmId, nil, true)
    return price
end

-- objects/SellingStation.lua:305-340, the ordinary paid branch only: no
-- mission, storeGoods false, skipSell false, so the delivery goes straight to
-- sellFillType. This is the production entry point UnloadTrigger reaches.
function SellingStation:addFillLevelFromTool(farmId, deltaFillLevel, fillTypeIndex, _fillInfo, toolType, extraAttributes)
    if deltaFillLevel > 0 then
        if not self:getSkipSell(farmId, fillTypeIndex) and deltaFillLevel > 0.001 then
            self:sellFillType(farmId, deltaFillLevel, fillTypeIndex, toolType, extraAttributes)
        end
    end
    return deltaFillLevel
end
