-- scripts/events.lua ------------------------------------------------------------
-- The event dispatcher (ARCHITECTURE.md rule 4): modules call events.on(...) at
-- require time, every load, unconditionally; control.lua calls events.install()
-- once. script.on_event keeps ONE handler per id, so registering directly drops
-- every module's handler but the last.
-- The engine registration carries the union of every registrant's filters.
-- MUST narrow on the way out: a handler with pure name filters is called only for
-- those names, or it is handed other modules' entities. A registrant with no
-- filter makes the event unfiltered; the rest are still narrowed.
----------------------------------------------------------------------------------

local events = {}

-- [event_id] = { handlers = {{fn = f, names = set|nil}, ...},
--                filters = {f, ...} or nil, unfiltered = bool }
local registry = {}
-- [tick_interval] = { fn, ... }
local nth_tick = {}
local installed = false

--- The set of entity names a filter list restricts to, or nil if it doesn't.
-- Only a pure name-filter list can be re-checked cheaply at dispatch time. Any
-- other filter kind (or an empty list) returns nil, and that handler keeps taking
-- whatever the engine hands it -- same behaviour as before, no silent narrowing.
local function name_set(filters)
  if not filters or #filters == 0 then return nil end
  local names = {}
  for _, f in ipairs(filters) do
    if f.filter ~= "name" or not f.name then return nil end
    names[f.name] = true
  end
  return names
end

--- Register a handler for an event.
-- @param id      defines.events.* (or a custom-input name string)
-- @param handler function(event)
-- @param filters table|nil  event filter list; omit for unfiltered
function events.on(id, handler, filters)
  assert(id ~= nil, "events.on: nil event id (typo in defines.events.*?)")
  assert(type(handler) == "function", "events.on: handler must be a function")
  assert(not installed,
         "events.on called after events.install() -- register at require time")

  local slot = registry[id]
  if not slot then
    slot = {handlers = {}, filters = nil, unfiltered = false}
    registry[id] = slot
  end

  slot.handlers[#slot.handlers + 1] = {fn = handler, names = name_set(filters)}

  if filters == nil then
    -- One unfiltered registrant forces the whole event unfiltered.
    slot.unfiltered = true
    slot.filters = nil
  elseif not slot.unfiltered then
    slot.filters = slot.filters or {}
    for _, f in ipairs(filters) do
      slot.filters[#slot.filters + 1] = f
    end
  end
end

--- Register a handler that runs every `interval` ticks.
function events.on_nth_tick(interval, handler)
  assert(type(interval) == "number" and interval > 0,
         "events.on_nth_tick: interval must be > 0")
  assert(type(handler) == "function", "events.on_nth_tick: handler must be a function")
  assert(not installed, "events.on_nth_tick called after install()")

  nth_tick[interval] = nth_tick[interval] or {}
  local t = nth_tick[interval]
  -- Same entry shape as the event registry: fan_out is shared, and a bare
  -- function here would be indexed as `entry.fn` the moment two modules pick
  -- the same interval. `names` is nil, so the handler always runs.
  t[#t + 1] = {fn = handler}
end

--- Does this entry want this event? A name-filtered handler is called only for
-- the names it registered; anything else keeps the engine's decision.
local function wants(entry, event)
  if not entry.names then return true end
  local e = event.entity
  if not e then return true end
  return entry.names[e.name] == true
end

local function fan_out(entries)
  -- Closure over the handler list; one real engine handler per event id.
  -- Registration order is preserved -- scripts/placement.lua depends on it.
  return function(event)
    for i = 1, #entries do
      local entry = entries[i]
      if wants(entry, event) then entry.fn(event) end
    end
  end
end

--- Wire everything into the engine. Call once, from control.lua, last.
function events.install()
  assert(not installed, "events.install() called twice")
  installed = true

  for id, slot in pairs(registry) do
    local fn = (#slot.handlers == 1) and slot.handlers[1].fn or fan_out(slot.handlers)
    if slot.unfiltered or not slot.filters then
      script.on_event(id, fn)
    else
      script.on_event(id, fn, slot.filters)
    end
  end

  for interval, handlers in pairs(nth_tick) do
    local fn = (#handlers == 1) and handlers[1].fn or fan_out(handlers)
    script.on_nth_tick(interval, fn)
  end
end

--- Introspection, for debugging "did my handler get registered".
function events.summary()
  local out = {}
  for id, slot in pairs(registry) do
    out[#out + 1] = string.format("event %s: %d handler(s), %s",
      tostring(id), #slot.handlers,
      slot.unfiltered and "unfiltered"
        or (slot.filters and (#slot.filters .. " filter(s)") or "no filters"))
  end
  for interval, handlers in pairs(nth_tick) do
    out[#out + 1] = string.format("nth_tick %d: %d handler(s)", interval, #handlers)
  end
  return out
end

return events
