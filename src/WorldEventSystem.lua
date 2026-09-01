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
    self.registry[event.id] = event
    MDMLog.info("WorldEventSystem: registered event '" .. event.id .. "'")
end

-- Restore an active event from savegame.
-- Called by MarketSerializer:load() after all events are registered.
-- extraData is an optional string persisted by the event's getExtraData() callback;
-- if the event defines onLoad, that is called instead of onFire so per-event state
-- (e.g. which crops were affected) can be deterministically restored.
function WorldEventSystem:loadActiveEvent(id, endsAt, intensity, extraData)
    local event = self.registry[id]
    if not event then
        MDMLog.warn("WorldEventSystem: cannot restore unknown event '" .. tostring(id) .. "'")
        return
    end

    self.active[id] = { event = event, endsAt = endsAt, intensity = intensity }

    -- Prefer onLoad (deterministic restore) over onFire (which may re-roll random state)
    if event.onLoad then
        event.onLoad(intensity, extraData or "")
    elseif event.onFire then
        event.onFire(intensity)
    end

    -- Re-apply UP market modifier with remaining duration.
    local now = MDMUtil.getGameTime()
    UPIntegration.onWorldEventFired(id, intensity, math.max(0, endsAt - now))

    MDMLog.info("WorldEventSystem: restored active event '" .. id .. "' (ends in " ..
        string.format("%.1f", (endsAt - now) / 60000) .. "m)")
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
    local now    = MDMUtil.getGameTime()
    local scale  = MDMUtil.getMonthLengthScale()
    local minDur = (event.minDurationMs or (5  * 60 * 1000)) * scale
    local maxDur = (event.maxDurationMs or (15 * 60 * 1000)) * scale
    local duration = minDur + math.random() * (maxDur - minDur)

    event.lastFiredAt = now
    self.active[id]   = { event = event, endsAt = now + duration, intensity = intensity }

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
function WorldEventSystem:_rollForEvents()
    local now       = MDMUtil.getGameTime()
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
            if (now - event.lastFiredAt) >= cooldown then
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
            self:_fireEvent(event, now)
            break
        end
    end
end

-- Fire an event: roll intensity and duration, record in active table, call onFire.
function WorldEventSystem:_fireEvent(event, now)
    local intensity = event.minIntensity + math.random() * (event.maxIntensity - event.minIntensity)
    local scale     = MDMUtil.getMonthLengthScale()
    local minDur    = (event.minDurationMs or (5  * 60 * 1000)) * scale
    local maxDur    = (event.maxDurationMs or (15 * 60 * 1000)) * scale
    local duration  = minDur + math.random() * (maxDur - minDur)

    event.lastFiredAt         = now
    self.active[event.id]     = { event = event, endsAt = now + duration, intensity = intensity }

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
