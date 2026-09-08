-- WorldEventSystem.lua
-- Manages the registry, scheduling, and firing of world events that affect prices.
--
-- Events register themselves via MDM_pendingRegistrations (a standalone global
-- set by each events/*.lua file before MarketDynamics exists). The coordinator
-- drains that table in MarketDynamics:_registerDefaultEvents().
--
-- Event descriptor shape:
--   id            string   unique identifier (e.g. "drought")
--   name          string   human-readable name (shown in HUD/console)
--   probability   number   0-1 chance of firing per CHECK_INTERVAL tick
--   minIntensity  number   0-1 lower bound for intensity roll
--   maxIntensity  number   0-1 upper bound for intensity roll
--   cooldownMs    number   minimum gap between firings of this event (ms)
--   minDurationMs number   minimum active duration (ms)
--   maxDurationMs number   maximum active duration (ms)
--   onFire(intensity)    function   called when event fires
--   onExpire(intensity)  function   called when event expires
--
-- Public API:
--   registerEvent(event)              — add an event descriptor to the registry
--   update(dt)                        — advance timer, expire events, roll for new ones
--   getActiveEvents()                 — list of active event summaries for GUI
--   forceFireEvent(id, intensity)     — fire immediately (admin/testing)
--   forceExpireEvent(id)              — expire immediately (admin/testing)
--
-- Author: tison (dev-1)

WorldEventSystem = WorldEventSystem or {}
WorldEventSystem.__index = WorldEventSystem

local CHECK_INTERVAL_MS = 5 * 60 * 1000   -- check for new events every 5 in-game minutes
local MIN_COOLDOWN_MS   = 20 * 60 * 1000  -- fallback if event descriptor omits cooldownMs

function WorldEventSystem.new()
    local self = setmetatable({}, WorldEventSystem)

    -- { [id] = event descriptor (with lastFiredAt added at registration) }
    self.registry = {}
    -- { [id] = { event, endsAt, intensity } }  — currently active events
    self.active        = {}
    self.timer         = 0
    self.isInitialized = false

    MDMLog.info("WorldEventSystem initialized")
    return self
end

-- Register a new event type. Rejects duplicate IDs.
function WorldEventSystem:registerEvent(event)
    if self.registry[event.id] then
        MDMLog.warn("WorldEventSystem: duplicate event id '" .. event.id .. "' — ignored")
        return
    end
    -- lastFiredAt starts at -math.huge so the first roll is never blocked by cooldown.
    event.lastFiredAt = -math.huge
    -- Canonical cooldown state (RSF-F203): never-fired is a MISSING record, not
    -- a timestamp of zero. Set at firing from current monotonic time.
    event.lastFiredMonotonicMs = nil
    event.cooldownUntilMonotonicMs = nil
    self.registry[event.id] = event
    MDMLog.info("WorldEventSystem: registered event '" .. event.id .. "'")
end

-- Restore an active event from savegame.
-- Called by MarketSerializer:load() after all events are registered.
-- extraData is an optional string persisted by the event's getExtraData() callback;
-- if the event defines onLoad, that is called instead of onFire so per-event state
-- (e.g. which crops were affected) can be deterministically restored.
-- endsAtMonotonicMs is the canonical deadline (v3 saves). When omitted (legacy
-- migration), it is derived from the public endsAt via the current clock offset.
-- Already-expired records are omitted without a new firing/notification.
function WorldEventSystem:loadActiveEvent(id, endsAt, intensity, extraData, endsAtMonotonicMs)
    local event = self.registry[id]
    if not event then
        MDMLog.warn("WorldEventSystem: cannot restore unknown event '" .. tostring(id) .. "'")
        return
    end

    local legacyNow = MDMUtil.getGameTime()
    local monoNow   = MDMUtil.getMonotonicTime()
    local canonicalEndsAt = endsAtMonotonicMs or (monoNow + (endsAt - legacyNow))
    if canonicalEndsAt <= monoNow then
        MDMLog.info("WorldEventSystem: skipping expired restored event '" .. id .. "'")
        return
    end
    -- Public projection at the current clock offset; reprojected by the
    -- coordinator when the offset changes.
    local publicEndsAt = legacyNow + (canonicalEndsAt - monoNow)

    self.active[id] = {
        event = event,
        endsAt = publicEndsAt,
        endsAtMonotonicMs = canonicalEndsAt,
        intensity = intensity,
    }

    -- Prefer onLoad (deterministic restore) over onFire (which may re-roll random state)
    if event.onLoad then
        event.onLoad(intensity, extraData or "")
    elseif event.onFire then
        event.onFire(intensity)
    end

    -- Re-apply UP market modifier with remaining duration.
    UPIntegration.onWorldEventFired(id, intensity, math.max(0, canonicalEndsAt - monoNow))

    MDMLog.info("WorldEventSystem: restored active event '" .. id .. "' (ends in " ..
        string.format("%.1f", (canonicalEndsAt - monoNow) / 60000) .. "m)")
end

-- Expire events whose canonical deadline has passed. Absolute comparison, so a
-- jump removes an already-active event once without recreating it. Returns the
-- number of events removed.
function WorldEventSystem:expireDue(monotonicNow)
    if g_server == nil then return 0 end
    local removed = 0
    for id, active in pairs(self.active) do
        if active.endsAtMonotonicMs and monotonicNow >= active.endsAtMonotonicMs then
            self:_expireEvent(id)
            removed = removed + 1
        end
    end
    return removed
end

-- Roll at most one event opportunity at the current endpoint. The coordinator
-- owns the phase accounting (eventPhase in the calendar block); this only
-- performs the single current roll using existing eligibility and original
-- probabilities. When events are disabled, no roll happens and no backlog is
-- released on re-enable.
function WorldEventSystem:rollOpportunity()
    if g_server == nil then return end
    local settings = g_MarketDynamics and g_MarketDynamics.settings
    if not settings or settings.eventsEnabled == false then return end
    self:_rollForEvents()
end

-- Reproject public endsAt/lastFiredAt from the canonical fields using the
-- current clock offset (legacyNow - monotonicNow). Canonical deadlines and
-- cooldowns are untouched. Called by the coordinator when the offset changes,
-- including at equal or earlier monotonic time.
function WorldEventSystem:reprojectPublic(monotonicNow, legacyNow)
    local offset = legacyNow - monotonicNow
    for id, active in pairs(self.active) do
        if active.endsAtMonotonicMs then
            active.endsAt = active.endsAtMonotonicMs + offset
        end
    end
    for id, event in pairs(self.registry) do
        if event.lastFiredMonotonicMs then
            event.lastFiredAt = event.lastFiredMonotonicMs + offset
        end
    end
end

-- Advance the event tick timer, expire any events past their endsAt, and
-- probabilistically roll for new events when CHECK_INTERVAL elapses.
-- dt is in-game milliseconds.
function WorldEventSystem:update(dt)
    if g_server == nil then return end

    self.timer = self.timer + dt
    local changed = false

    -- Tick active events — expire any that have passed their end time
    local now = MDMUtil.getGameTime()
    for id, active in pairs(self.active) do
        if now >= active.endsAt then
            self:_expireEvent(id)
            changed = true
        end
    end

    -- Probabilistic event roll on a day-length-scaled interval, so per-month
    -- event density stays stable regardless of the days/month setting.
    local checkInterval = CHECK_INTERVAL_MS * MDMUtil.getMonthLengthScale()
    if self.timer >= checkInterval then
        self.timer = 0
        local settings = g_MarketDynamics and g_MarketDynamics.settings
        if not settings or settings.eventsEnabled ~= false then
            local preCount = 0
            for _ in pairs(self.active) do preCount = preCount + 1 end
            self:_rollForEvents()
            local postCount = 0
            for _ in pairs(self.active) do postCount = postCount + 1 end
            if preCount ~= postCount then changed = true end
        end
    end

    if changed and MDMMarketSyncEvent then
        MDMMarketSyncEvent.sendToClients()
    end
end

-- Returns a list of active event summaries for the HUD and GUI.
-- Each entry: { id, name, intensity, endsAt }
function WorldEventSystem:getActiveEvents()
    local result = {}
    for id, active in pairs(self.active) do
        local desc = self.registry[id]
        local name
        if desc ~= nil then
            name = MDMUtil.resolveEventName(desc)
        else
            name = MDMUtil.resolveEventName(nil, nil, id)
        end
        table.insert(result, {
            id        = id,
            name      = name,
            intensity = active.intensity,
            endsAt    = active.endsAt,
        })
    end
    return result
end

-- Force-fire a registered event at a given intensity (0-1). Admin/testing only.
-- intensity defaults to 1.0 (maximum) if omitted.
-- Returns true on success; false + reason string on failure.
function WorldEventSystem:forceFireEvent(id, intensity)
    local event = self.registry[id]
    if not event then
        return false, "unknown event id '" .. tostring(id) .. "'"
    end
    if self.active[id] then
        return false, "event '" .. id .. "' is already active"
    end

    intensity = math.max(0, math.min(1, intensity or 1.0))
    local legacyNow = MDMUtil.getGameTime()
    local monoNow   = MDMUtil.getMonotonicTime()
    local scale  = MDMUtil.getMonthLengthScale()
    local minDur = (event.minDurationMs or (5  * 60 * 1000)) * scale
    local maxDur = (event.maxDurationMs or (15 * 60 * 1000)) * scale
    local duration = minDur + math.random() * (maxDur - minDur)

    event.lastFiredAt = legacyNow
    event.lastFiredMonotonicMs = monoNow
    event.cooldownUntilMonotonicMs = monoNow + (event.cooldownMs or MIN_COOLDOWN_MS) * scale
    self.active[id] = {
        event = event,
        endsAt = legacyNow + duration,
        endsAtMonotonicMs = monoNow + duration,
        intensity = intensity,
    }

    MDMLog.info("WorldEventSystem: FORCED '" .. id .. "' intensity=" .. string.format("%.2f", intensity))

    if event.onFire then
        event.onFire(intensity)
    end

    if UPIntegration and UPIntegration.onWorldEventFired then
        UPIntegration.onWorldEventFired(id, intensity, duration)
    end

    -- Show notification if this is a local player (Host/SP)
    if g_client ~= nil and g_MarketDynamics then
        local name = MDMUtil.resolveEventName(event)
        g_MarketDynamics.pendingEventNotificationName = name
        addTimer(1000, "showEventNotification", g_MarketDynamics)
    end

    return true, nil
end

-- Force-expire an active event immediately. Admin/testing only.
-- Returns true on success; false + reason string if the event is not active.
function WorldEventSystem:forceExpireEvent(id)
    if not self.active[id] then
        return false, "event '" .. tostring(id) .. "' is not active"
    end
    self:_expireEvent(id)
    return true, nil
end

-- ---------------------------------------------------------------------------
-- Private
-- ---------------------------------------------------------------------------

-- Iterate all registered events and roll each one for firing.
-- An event is eligible if: not disabled, not currently active, and cooldown has elapsed.
-- Cooldown uses the canonical monotonic clock; never-fired is a missing record.
function WorldEventSystem:_rollForEvents()
    local monoNow   = MDMUtil.getMonotonicTime()
    local settings  = g_MarketDynamics and g_MarketDynamics.settings
    local freqScale = (settings and settings.eventFrequency) or 1.0
    local disabled  = settings and settings.disabledEvents
    local scale     = MDMUtil.getMonthLengthScale()

    -- Cap at one new event per check to prevent event storms.
    -- Shuffle registry order so no single event is systematically favored.
    local eligible = {}
    for id, event in pairs(self.registry) do
        if not (disabled and disabled[id]) and not self.active[id] then
            local cooldown = (event.cooldownMs or MIN_COOLDOWN_MS) * scale
            local lastFired = event.lastFiredMonotonicMs
            if lastFired == nil then
                -- Legacy fallback (incumbent path / v2 restore): the public
                -- field shares the same epoch in normal operation.
                lastFired = event.lastFiredAt
                if lastFired == nil or lastFired == -math.huge then
                    table.insert(eligible, event)  -- never fired: missing record
                elseif (monoNow - lastFired) >= cooldown then
                    table.insert(eligible, event)
                end
            elseif (monoNow - lastFired) >= cooldown then
                table.insert(eligible, event)
            end
        end
    end
    for i = #eligible, 2, -1 do
        local j = math.random(i)
        eligible[i], eligible[j] = eligible[j], eligible[i]
    end
    for _, event in ipairs(eligible) do
        if math.random() < (event.probability * freqScale) then
            self:_fireEvent(event, monoNow)
            break
        end
    end
end

-- Fire an event: roll intensity and duration, record in active table, call onFire.
-- Sets both the canonical monotonic deadline and the public legacy projection.
function WorldEventSystem:_fireEvent(event, monoNow)
    local intensity = event.minIntensity + math.random() * (event.maxIntensity - event.minIntensity)
    local scale     = MDMUtil.getMonthLengthScale()
    local minDur    = (event.minDurationMs or (5  * 60 * 1000)) * scale
    local maxDur    = (event.maxDurationMs or (15 * 60 * 1000)) * scale
    local duration  = minDur + math.random() * (maxDur - minDur)
    local legacyNow = MDMUtil.getGameTime()

    event.lastFiredAt = legacyNow
    event.lastFiredMonotonicMs = monoNow
    event.cooldownUntilMonotonicMs = monoNow + (event.cooldownMs or MIN_COOLDOWN_MS) * scale
    self.active[event.id] = {
        event = event,
        endsAt = legacyNow + duration,
        endsAtMonotonicMs = monoNow + duration,
        intensity = intensity,
    }

    MDMLog.info("WorldEventSystem: firing '" .. event.id ..
        "' intensity=" .. string.format("%.2f", intensity))

    if event.onFire then
        event.onFire(intensity)
    end

    UPIntegration.onWorldEventFired(event.id, intensity, duration)

    -- Show notification if this is a local player (Host/SP)
    if g_client ~= nil and g_MarketDynamics then
        local desc = self.registry[event.id] or event
        local name = MDMUtil.resolveEventName(desc)
        g_MarketDynamics.pendingEventNotificationName = name
        addTimer(1000, "showEventNotification", g_MarketDynamics)
    end
end

-- Expire an active event: call onExpire, remove from active table.
function WorldEventSystem:_expireEvent(id)
    local active = self.active[id]
    if not active then return end

    MDMLog.info("WorldEventSystem: event '" .. id .. "' expired")

    local event = self.registry[id]
    if event and event.onExpire then
        event.onExpire(active.intensity)
    end

    UPIntegration.onWorldEventExpired(id)
    self.active[id] = nil
end
