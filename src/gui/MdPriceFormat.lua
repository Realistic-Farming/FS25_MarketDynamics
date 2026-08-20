-- =========================================================
-- FS25_MarketDynamics - MdPriceFormat
-- =========================================================
-- Author: TisonK
-- =========================================================
-- BUILD 23:47 - one place that decides how a market price is written.
--
-- Three surfaces used to answer this question separately and disagreed. The
-- Esc Prices table printed the raw per-litre number with no decimals and no
-- unit, the full Market table printed the same number times a thousand with a
-- litre suffix, and the Esc selected-crop line printed the raw number again.
-- Same price, three readings, and the animal rows on the full Market table read
-- like a tanker price for a single cow.
--
-- Engine numbers stay per litre. MarketEngine.current, the history samples,
-- PriceHook and contract settlement are untouched. The thousand is a display
-- multiply and it lives here, once.
--
-- Animals are the exception, and the test is an existing AnimalSystem lookup
-- rather than an invented fill-type flag: a fill type that names an animal
-- subtype is one animal per unit, so multiplying it by a thousand would be
-- nonsense. Milk, wool, eggs, manure and feed are subtype OUTPUTS, not cargo
-- identities, so the lookup returns nil for them and they stay on the litre
-- path with no list to maintain.
-- =========================================================

MDMPriceFormat = MDMPriceFormat or {}

-- Verbatim the suffix the full Market table already shipped, so the Esc table
-- and the full Market table print the same string and not two dialects of it.
MDMPriceFormat.LITRE_SUFFIX = " / 1,000L"
MDMPriceFormat.LITRE_FACTOR = 1000
MDMPriceFormat.PRECISION = 2

--- True when this fill type is an animal cargo identity rather than a bulk good.
function MDMPriceFormat.isAnimalCargo(fillTypeIndex)
    if fillTypeIndex == nil then
        return false
    end

    local animalSystem = nil
    if g_currentMission ~= nil then
        animalSystem = g_currentMission.animalSystem
    end

    return animalSystem ~= nil
        and type(animalSystem.getSubTypeByFillTypeIndex) == "function"
        and animalSystem:getSubTypeByFillTypeIndex(fillTypeIndex) ~= nil
end

-- Only reached when there is no I18N object at all, which means there is no
-- locale to respect in the first place.
MDMPriceFormat.FALLBACK_SEPARATOR = "."

--- Currency with both decimals always printed, including a trailing 00.
---
--- BUILD 00:16, Vera F2. The first version of this asked formatNumber for the
--- digits with forcePrecision set, on the understanding that the flag forces
--- them. It does not. formatNumber rounds and then calls tostring, and tostring
--- of a whole number writes no decimal point at all, so the decimal branch
--- never runs and the flag is never consulted: 512 prints as "512". Even when
--- there IS a fraction the flag only keeps what tostring already wrote, so
--- 512.5 prints as one decimal place and never as two. There is no I18N helper
--- that pads, and formatMoney is worse because it does not pass the flag at
--- all. So the digits are built here.
---
--- The one engine call left is grouping. formatNumber is handed an integer and
--- precision 0, purely so the thousands separator is the locale's own, and it
--- is structurally incapable of adding decimals to an integer.
function MDMPriceFormat.money(value)
    if value == nil then
        return "-"
    end

    local rounded = value
    if MathUtil ~= nil and type(MathUtil.round) == "function" then
        rounded = MathUtil.round(value, MDMPriceFormat.PRECISION)
    end

    -- Split toward zero with the sign carried separately. math.floor on a
    -- negative rounds away from zero, which would turn -0.50 into -1 and 50.
    local negative = rounded < 0
    local magnitude = negative and -rounded or rounded
    local whole = math.floor(magnitude)
    local frac = math.floor((magnitude - whole) * 100 + 0.5)
    if frac >= 100 then
        -- A magnitude that rounds up at the hundredths, 512.999 and the like.
        whole = whole + 1
        frac = frac - 100
    end

    local wholeStr = tostring(whole)
    local separator = MDMPriceFormat.FALLBACK_SEPARATOR
    local symbol = ""

    if g_i18n ~= nil then
        if type(g_i18n.formatNumber) == "function" then
            wholeStr = g_i18n:formatNumber(whole, 0)
        end
        -- The locale's own mark, never a hardcoded dot. German groups with "."
        -- and separates with ",", so a dot appended to a grouped integer would
        -- read 1.234.00 and mean nothing.
        if type(g_i18n.decimalSeparator) == "string" and g_i18n.decimalSeparator ~= "" then
            separator = g_i18n.decimalSeparator
        end
        if type(g_i18n.getCurrencySymbol) == "function" then
            symbol = g_i18n:getCurrencySymbol(true) or ""
        end
    end

    -- %02d pads the fraction to two digits and writes no separator of its own,
    -- which is the same shape the vanilla fill-level readouts use.
    local out = symbol .. wholeStr .. separator .. string.format("%02d", frac)
    if negative then
        out = "-" .. out
    end

    return out
end

--- The number a price axis should plot for this fill type. Animal cargo is not
--- multiplied, everything else is, and the caller uses this for the label and
--- for any threshold that keys off the displayed magnitude so the two cannot
--- drift apart.
function MDMPriceFormat.displayValue(fillTypeIndex, current)
    if current == nil then
        return nil
    end

    if MDMPriceFormat.isAnimalCargo(fillTypeIndex) then
        return current
    end

    return current * MDMPriceFormat.LITRE_FACTOR
end

--- The full string a price cell should show.
function MDMPriceFormat.price(fillTypeIndex, current)
    if current == nil then
        return "-"
    end

    if MDMPriceFormat.isAnimalCargo(fillTypeIndex) then
        return MDMPriceFormat.money(current)
    end

    return MDMPriceFormat.money(current * MDMPriceFormat.LITRE_FACTOR) .. MDMPriceFormat.LITRE_SUFFIX
end

-- =========================================================
-- BUILD 14:04 (Vera FAIL SUBMIT 10:16, George TASK 10:53 GO): publish on load.
--
-- The class table above is a global in THIS mod's environment only. The shared Esc host
-- executes inside whichever mod won the door race, and Vera's live gate showed that of the
-- host's cross-env belts only the mission handle actually resolves on the live engine
-- (via=mission) - g_modEnvironments carries nothing there and getfenv(0) is the per-mod
-- sandbox. So the formatter announces itself instead of waiting to be found:
--   _G            - resolves through the sandbox chain; where the engine backs it with the
--                   real global table this write is visible to every mod's _G probe, and
--                   where the sandbox loops _G onto itself it is a harmless self-write.
--                   pcall-guarded because a locked global table must not kill the source.
--   getfenv(0)    - the sandbox root, same target mdPublishHandles already uses.
--   mission       - the proven live channel. Nil at source time on a cold boot, which is
--                   why MdRfPdaGuest.mdPublishHandles re-publishes this class on every
--                   register attempt: no Prices row can paint before a register succeeded.
-- =========================================================
pcall(function()
    if _G ~= nil then
        _G.MDMPriceFormat = MDMPriceFormat
    end
end)
do
    local okEnv, root = pcall(getfenv, 0)
    if okEnv and type(root) == "table" then
        root.MDMPriceFormat = MDMPriceFormat
    end
    if g_currentMission ~= nil then
        g_currentMission.MDMPriceFormat = MDMPriceFormat
    end
end
