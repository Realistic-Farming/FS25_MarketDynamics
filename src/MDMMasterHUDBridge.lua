-- =========================================================
-- FS25 Market Dynamics - MasterHUD bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_MasterHUD (bedrock). Market Dynamics ships standalone,
-- so this is delegate-when-present, mirroring SoilFertilizer / TaxMod:
--   * MasterHUD installed -> MDM registers its HUD draw stack (the contract HUD
--     g_MDMHud + the settings panel) as a self-draw. MasterHUD then owns the
--     single draw loop, the menu/dialog suspend and cross-mod ordering, so MDM's
--     HUD stacks cleanly with the rest of the ecosystem instead of every mod
--     hooking FSBaseMission.draw independently.
--   * MasterHUD absent -> MarketDynamics:draw runs the exact same stack via its
--     own FSBaseMission.draw hook, exactly as before.
--
-- drawStack() is the single source of the draw body, shared with the fallback in
-- MarketDynamics:draw so the two paths can never diverge. Only DRAW moves here;
-- mouse/scroll events stay on MDM's own FSBaseMission.mouseEvent hook (MasterHUD
-- owns ordering + suspend, not input).
--
-- The cross-mod handle is g_currentMission.masterHUD (published in Mission00.load).
-- =========================================================

MDMMasterHUDBridge = {}

MDMMasterHUDBridge.HUD_ID = "MarketDynamics_HUD"
MDMMasterHUDBridge.active = false   -- MasterHUD present and we registered

-- The MDM HUD draw stack. Byte-for-byte the same body as MarketDynamics:draw.
-- Resolves the coordinator from the canonical global so it can be driven either by
-- MasterHUD or by MDM's own draw hook.
function MDMMasterHUDBridge.drawStack()
    local mdm = g_MarketDynamics
    if mdm == nil or not mdm.isActive then return end
    if g_MDMHud then
        g_MDMHud:draw()
    end
    if mdm.settingsPanel then
        mdm.settingsPanel:draw()
    end
end

-- Register with MasterHUD if present. Called from MarketDynamics:onMissionLoaded,
-- after the HUD has published its g_currentMission handle (Mission00.load).
function MDMMasterHUDBridge.register(mdm)
    MDMMasterHUDBridge.active = false

    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if hud == nil then
        MDMLog.info("Market Dynamics: MasterHUD not detected; HUD uses its own draw hook")
        return
    end

    local ok, err = pcall(function()
        hud:subscribe(MDMMasterHUDBridge.HUD_ID, {
            draw = MDMMasterHUDBridge.drawStack,
        })
    end)

    if ok then
        MDMMasterHUDBridge.active = true
        MDMLog.info("Market Dynamics: Registered HUD with MasterHUD (single draw loop + menu-suspend)")
    else
        MDMLog.warn("Market Dynamics: MasterHUD registration failed: " .. tostring(err) .. " (using own draw hook)")
    end
end
