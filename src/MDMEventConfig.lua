-- MDMEventConfig.lua
-- Manages per-event custom fill type configuration.
-- Fill types are stored in g_MarketDynamics.settings.eventCustomFillTypes and
-- edited via the in-game Event Settings dialog (MDMEventSettingsDialog).
--
-- MDMEventConfig.load() handles a one-time migration from the legacy XML config
-- file (FS25_MarketDynamics_eventConfig.xml) written by v1.1.6.0 and earlier.
-- After migration the XML file is ignored; the UI and MarketSerializer own the data.
--
-- Per-event extra fill types get the PRIMARY factor for that event.
-- (For multi-factor events like Protein Premium, that is the higher-intensity group.)
--
-- Author: tison (dev-1)

MDMEventConfig = MDMEventConfig or {}

-- Returns the active extra fill type list for an event from settings.
local function _getList(eventId)
    if not g_MarketDynamics or not g_MarketDynamics.settings then return {} end
    local cft = g_MarketDynamics.settings.eventCustomFillTypes
    if not cft then return {} end
    return cft[eventId] or {}
end

-- Migrate legacy XML config into settings (one-time, only for entries not yet in settings).
-- Called by MarketDynamics:onStartMission() once the savegame path is known.
function MDMEventConfig.load(savegameDir)
    if not savegameDir or savegameDir == "" then return end

    local path    = savegameDir .. "/FS25_MarketDynamics_eventConfig.xml"
    if not fileExists(path) then return end

    local xmlFile = XMLFile.load("MDMEventConfig", path)
    if not xmlFile then return end

    local settings = g_MarketDynamics and g_MarketDynamics.settings
    if not settings then xmlFile:delete(); return end
    settings.eventCustomFillTypes = settings.eventCustomFillTypes or {}

    local total = 0
    local i = 0
    while true do
        local base = "MDMEventConfig.event(" .. i .. ")"
        if not xmlFile:hasProperty(base) then break end

        local eventId = xmlFile:getString(base .. "#id")
        if not eventId then break end

        -- Only seed if the player hasn't yet configured this event via the UI
        if not settings.eventCustomFillTypes[eventId] then
            settings.eventCustomFillTypes[eventId] = {}
            local j = 0
            while true do
                local ftBase = base .. ".fillType(" .. j .. ")"
                if not xmlFile:hasProperty(ftBase) then break end

                local name = xmlFile:getString(ftBase .. "#name")
                if not name then break end
                table.insert(settings.eventCustomFillTypes[eventId], name)
                total = total + 1
                j = j + 1
            end
        end

        i = i + 1
    end

    xmlFile:delete()
    if total > 0 then
        MDMLog.info(string.format("MDMEventConfig: migrated %d fill type(s) from legacy XML config", total))
    end
end

-- Returns the list of custom extra fill type names for an event.
function MDMEventConfig.getExtraFillTypes(eventId)
    return _getList(eventId)
end

-- Apply extra fill type modifiers for an event at the given factor.
-- Called from each event's onFire (and onLoad for events with state tracking).
function MDMEventConfig.applyExtra(eventId, factor)
    if not g_MarketDynamics then return end
    for _, name in ipairs(_getList(eventId)) do
        local ft = g_fillTypeManager:getFillTypeByName(name)
        if ft then
            g_MarketDynamics.marketEngine:addModifier({
                id            = eventId .. "_cfg_" .. name,
                fillTypeIndex = ft.index,
                factor        = factor,
            })
        end
    end
end

-- Remove extra fill type modifiers for an event.
-- Called from each event's onExpire.
function MDMEventConfig.removeExtra(eventId)
    if not g_MarketDynamics then return end
    for _, name in ipairs(_getList(eventId)) do
        local ft = g_fillTypeManager:getFillTypeByName(name)
        if ft then
            g_MarketDynamics.marketEngine:removeModifierById(ft.index, eventId .. "_cfg_" .. name)
        end
    end
end

-- Validate stored custom fill type names after save-game load.
-- Removes names that no longer resolve in g_fillTypeManager — e.g. because a
-- third-party mod that provided them was uninstalled between sessions.
-- Logs every removed entry so the player can see what was cleaned up.
function MDMEventConfig.validateAndClean()
    if not g_MarketDynamics or not g_MarketDynamics.settings then return end
    local cft = g_MarketDynamics.settings.eventCustomFillTypes
    if not cft then return end

    local removed = 0
    for eventId, list in pairs(cft) do
        for i = #list, 1, -1 do
            local name = list[i]
            local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(name)
            if not ft then
                MDMLog.warn(string.format(
                    "MDMEventConfig: removing stale fill type '%s' from event '%s' (fill type no longer exists — mod removed?)",
                    tostring(name), tostring(eventId)))
                table.remove(list, i)
                removed = removed + 1
            end
        end
        if #list == 0 then
            cft[eventId] = nil
        end
    end

    if removed > 0 then
        MDMLog.info(string.format("MDMEventConfig: cleaned %d stale fill type entry(s)", removed))
    end
end
