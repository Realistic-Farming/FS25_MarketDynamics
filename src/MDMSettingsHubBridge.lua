-- =========================================================
-- FS25 Market Dynamics - SettingsHub bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_SettingsHub. Safe if SettingsHub is not
-- installed (register() just no-ops). Purpose: let the FarmTablet
-- System Settings app list Market Dynamics' settings.
--
-- g_MarketDynamics.settings (a plain table, persisted by MarketSerializer
-- on game save) stays the source of truth. This mirrors the scalar
-- settings into SettingsHub for display; table settings (disabledEvents,
-- eventCustomFillTypes) are not exposed. The tablet app is read-only for
-- now, so applyChange only needs to set the value back on that table.
-- =========================================================

MDMSettingsHubBridge = {}

local function applyChange(key, value)
    local mdm = g_MarketDynamics
    if mdm == nil or mdm.settings == nil then return end
    mdm.settings[key] = value
    -- debugMode mirrors onto the logger (see MarketDynamics.new).
    if key == "debugMode" and MDMLog ~= nil then
        MDMLog.debugEnabled = value
    end
end

function MDMSettingsHubBridge.register(mdm)
    -- The reliable cross-mod handle is g_currentMission.settingsHub (the same one
    -- FarmTablet reads). The bare g_settingsHub global is only visible inside
    -- SettingsHub's own mod environment, so it reads back nil from here.
    local hub = (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
    if hub == nil then return end
    if mdm == nil or mdm.settings == nil then return end
    local s = mdm.settings

    local defs = {
        { id = "pricesEnabled",           type = "bool",  default = s.pricesEnabled,           adminOnly = true,  label = "Dynamic Prices Enabled" },
        { id = "eventsEnabled",           type = "bool",  default = s.eventsEnabled,           adminOnly = true,  label = "World Events Enabled" },
        { id = "eventFrequency",          type = "float", default = s.eventFrequency,          adminOnly = true,  min = 0, max = 5, label = "Event Frequency (0.4=Rare, 1=Normal, 2=Frequent)" },
        { id = "futuresPenalty",          type = "float", default = s.futuresPenalty,          adminOnly = true,  min = 0, max = 1, label = "Futures Contract Penalty" },
        { id = "useRealDays",             type = "bool",  default = s.useRealDays,             adminOnly = true,  label = "Contracts Track Real Days" },
        { id = "showEventNotifications",  type = "bool",  default = s.showEventNotifications,  adminOnly = false, label = "Event Notifications" },
        { id = "eventNotificationBanner", type = "bool",  default = s.eventNotificationBanner, adminOnly = false, label = "Notifications As Banner" },
        { id = "showContractHUD",         type = "bool",  default = s.showContractHUD,         adminOnly = false, label = "Contract HUD" },
        { id = "debugMode",               type = "bool",  default = s.debugMode,               adminOnly = false, label = "Debug Mode" },
    }

    local ok, err = pcall(function()
        hub:registerModule("MarketDynamics", {
            adminSettings = defs,
            onChange      = function(key, value, playerId) applyChange(key, value) end,
            -- We own our persistence (MarketSerializer -> FS25_MarketDynamics.xml) and load
            -- it in onStartMission before this registration runs, so the hub must mirror
            -- for display only: never restore its own stale copy and replay it back through
            -- onChange on load. Without this the hub could push a stale value over our real
            -- one every load (the same trap SoilFertilizer hit that silently disabled the mod).
            selfPersisted = true,
        })
    end)

    if ok then
        MDMLog.info("Market Dynamics: Registered with SettingsHub (" .. #defs .. " settings)")
    else
        MDMLog.error("Market Dynamics: SettingsHub registration failed: " .. tostring(err))
    end
end
