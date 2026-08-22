-- =========================================================
-- FS25 Market Dynamics - Release Gate
-- =========================================================
-- The release gate: which systems are released (STABLE) vs experimental (LOCKED).
--
-- Orthogonal to difficulty. The gate is its own explicit opt-in (experimental
-- systems, on at your own risk), independent of difficulty, and the two locks
-- STACK.
--
-- Arissani's certification (2026-08-03, ledger): Market Dynamics carries an
-- EMPTY lock set today. The price-modifier contract is present but inert (its one
-- adopter returns nil or 1.0 and changes no price), and OM-213 the organic premium
-- is unbuilt and owed from the design side. Nothing is gated; the mechanism is
-- wired so a row can be added the moment a system needs locking. Releasing a
-- system for a stable release is a deliberate act, never a default.
-- =========================================================

ReleaseGate = ReleaseGate or {}

-- The certified experimental (LOCKED) set. Each entry: [systemId] = { name, status }.
-- `status` is a SHORT player-facing note on what is not working or implemented yet.
-- A system that is NOT in this table is released (the proven baseline).
ReleaseGate.EXPERIMENTAL = {}

-- Console command -> systemId, so command refusals route through the same registry.
ReleaseGate.COMMAND_TO_SYSTEM = {}

--- A system is released when it is NOT experimental, or the player has explicitly
--- opted into experimental systems. `optIn` is the settings.experimentalSystems boolean.
---@param systemId string
---@param optIn boolean|nil
---@return boolean
function ReleaseGate.isReleased(systemId, optIn)
    if not ReleaseGate.EXPERIMENTAL[systemId] then return true end
    return optIn == true
end

--- The LIVE opt-in: reads the player's current settings.experimentalSystems value
--- through the coordinator. Returns nil when the manager/settings are not
--- available yet (pre-init or the offline test bench); callers decide what nil means.
---@return boolean|nil
function ReleaseGate.liveOptIn()
    local mdm = g_MarketDynamics
    if mdm and mdm.allowsExperimentalSystems then
        return mdm:allowsExperimentalSystems()
    end
    return nil
end

--- A system is LIVE right now: released, or the player has opted in.
--- FAIL-OPEN: when the live settings cannot be read (nil manager, nil settings, or
--- a settings object without the predicate - e.g. the offline test bench), the
--- system counts as live. The gate is an explicit opt-out of NEW systems; it must
--- never silently disable a path just because the opt-in flag is not readable at
--- that moment.
---@param systemId string
---@return boolean
function ReleaseGate.isSystemLive(systemId)
    local optIn = ReleaseGate.liveOptIn()
    if optIn == nil then return true end
    return ReleaseGate.isReleased(systemId, optIn)
end

--- Refusal message when a system is locked; nil when released.
---@param systemId string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.lockMessage(systemId, optIn)
    local entry = ReleaseGate.EXPERIMENTAL[systemId]
    if not entry or optIn == true then return nil end
    return string.format(
        "Locked: %s is not released yet. Enable Experimental Systems to use it at your own risk.",
        entry.name)
end

--- Console command gate. Mirrors the SF bypass-lock pattern but on the release axis.
---@param commandName string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.commandLockMessage(commandName, optIn)
    return ReleaseGate.lockMessage(ReleaseGate.COMMAND_TO_SYSTEM[commandName], optIn)
end

--- Player-friendly gate status, for the status/help surfaces and tests.
---@param optIn boolean|nil
---@return string
function ReleaseGate.status(optIn)
    local lines = { "=== Release gate ===" }
    lines[#lines + 1] = string.format("  Experimental systems: %s",
        optIn == true and "ON (at your own risk)" or "OFF (stable only)")
    local on = optIn == true
    if on then
        lines[#lines + 1] = "  All experimental systems: ON"
        for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
            lines[#lines + 1] = string.format("    [ON] %s", entry.name)
        end
    else
        lines[#lines + 1] = "  Not yet released:"
        for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
            lines[#lines + 1] = string.format("    [LOCKED] %s - %s", entry.name, entry.status)
        end
    end
    return table.concat(lines, "\n")
end

MDMLog.info("Release gate loaded")
