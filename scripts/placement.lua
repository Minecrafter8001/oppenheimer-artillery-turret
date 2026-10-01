-- scripts/placement.lua -------------------------------------------------------------
-- Placement rules for the turret assembly. Backlog #61, #69.
--
-- #69 is the one that decides whether the four-pylon design is a good idea or an
-- annoyance. Hand-placing four accumulators at exact offsets around every gun,
-- every time, would make the whole mechanic tedious enough that a player would
-- rather not build the turret. So placing the turret ghosts in all four pylons
-- at the right spots, and the player just lets bots (or their own hands) fill
-- them in.
--
-- #61 stops these being used as a hedge. A 9x9 gun that levels a nest from
-- across the map should be a landmark you build a few of, not a wall you spam.
--
-- GROUNDBREAKING IS A SEQUENCE. Placing the gun lays an outline, ghosts
-- the hardware in order, then pours the reticle floor outward from the centre
-- (C.foundation). The job lives in storage.groundworks so a save taken halfway
-- finishes it. placement.foundation / ghost_pylons stay as the INSTANT versions
-- for migrations and the configuration-change re-lay.
--------------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
local pylon  = require("scripts.pylon")
local foundation_plan = require("lib.foundation_plan")

local placement = {}

local LAMP_SET = {[N.ground_lamp] = true}

-- =============================================================================
-- The reticle floor plan
-- =============================================================================

--- Every tile of the pad as {dx, dy, name, d}, relative to the turret's own
--- tile, sorted by distance from the centre (the pour order), from
--- lib/foundation_plan.lua. Built once: identical on every client, not game state.
-- MUST require foundation_plan at file scope: `require` fails inside an event handler.
local plan_cache
local function floor_plan()
  if plan_cache then return plan_cache end
  if not (C.foundation and C.foundation.enabled) then
    plan_cache = {}
    return plan_cache
  end

  local out = {}
  for _, row in ipairs(foundation_plan.rows) do
    local dy = row[1]
    for _, run in ipairs(row[2]) do
      local a, b, name = run[1], run[2], run[3]
      for dx = a, b do
        out[#out + 1] = {dx = dx, dy = dy, name = name,
                          d = math.sqrt(dx * dx + dy * dy)}
      end
    end
  end
  -- A total order, so every client pours the same tile on the same tick.
  table.sort(out, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.dy ~= b.dy then return a.dy < b.dy end
    return a.dx < b.dx
  end)
  plan_cache = out
  return out
end

local function tile_origin(turret)
  return math.floor(turret.position.x), math.floor(turret.position.y)
end

--- Lay the whole pad in ONE call. Tile correction re-runs after every step, so
--- setting them individually both costs more and makes the transitions redo
--- themselves.
function placement.foundation(turret)
  local f = C.foundation
  if not (f and f.enabled) then return 0 end
  if not (turret and turret.valid) then return 0 end
  local cx, cy = tile_origin(turret)
  local tiles = {}
  for i, t in ipairs(floor_plan()) do
    tiles[i] = {name = t.name, position = {cx + t.dx, cy + t.dy}}
  end
  turret.surface.set_tiles(tiles, true)
  return #tiles
end

-- =============================================================================
-- #69: auto-ghost the hardware
-- =============================================================================

--- Ghost one piece of hardware into one slot, unless something that counts as
--- occupying it is already there.
-- @param names table  set of prototype names that count as already occupying
-- @param name  string what to ghost into an empty slot
local function ghost_one(turret, names, name, pos, tol)
  local surface = turret.surface
  for _, e in pairs(surface.find_entities_filtered{position = pos, radius = tol}) do
    if e.valid and (names[e.name]
        or (e.name == "entity-ghost" and names[e.ghost_name])) then
      return false
    end
  end
  -- ghost_place: a ghost may legally sit where a real entity currently cannot
  -- (on top of a tree that will be cleared, for instance).
  if not surface.can_place_entity{
    name = name, position = pos, force = turret.force,
    build_check_type = defines.build_check_type.ghost_place,
  } then
    return false
  end
  return surface.create_entity{
    name = "entity-ghost", inner_name = name, position = pos,
    force = turret.force, raise_built = false,
  } ~= nil
end

local function family(kind)
  if kind == "mast" then
    return pylon.MAST_NAMES, N.substation, C.substation.link_tolerance
  elseif kind == "bank" then
    return pylon.NAMES, N.pylon, C.pylon.link_tolerance
  end
  return LAMP_SET, N.ground_lamp, C.lamp.link_tolerance
end

local function orientation_of(x, y)
  local atan2 = math.atan2 or math.atan
  local o = atan2(x, -y) / (2 * math.pi)
  if o < 0 then o = o + 1 end
  return o
end

-- Clockwise from upper-left: the order the eye reads a square in.
local START = 0.875
local CLUSTER_ORDER = {nw = 1, ne = 2, se = 3, sw = 4,
                       north = 1, east = 2, south = 3, west = 4}

--- Every ghost the survey places, in order, with the tick offset it lands on:
--- {kind, ox, oy, t}. Masts first, then each cluster's banks clockwise, then
--- the runway lamps a whole row at a time, outward from the gun.
local schedule_cache
local function survey_schedule()
  if schedule_cache then return schedule_cache end
  local sv = C.foundation.survey
  local staged = sv and sv.enabled
  local out, t = {}, staged and sv.outline_ticks or 0
  local function add(kind, ox, oy) out[#out + 1] = {kind = kind, ox = ox, oy = oy, t = t} end
  local function advance(n) if staged then t = t + n end end
  local function clockwise(defs, cx, cy)
    local sorted = {}
    for i, d in ipairs(defs) do sorted[i] = d end
    table.sort(sorted, function(a, b)
      local oa = (orientation_of(a.ox - cx, a.oy - cy) - START) % 1
      local ob = (orientation_of(b.ox - cx, b.oy - cy) - START) % 1
      if oa ~= ob then return oa < ob end
      return a.key < b.key
    end)
    return sorted
  end

  if C.substation and C.substation.enabled and C.substation.auto_ghost then
    for _, d in ipairs(clockwise(C.substation_slot_defs(), 0, 0)) do
      add("mast", d.ox, d.oy)
      advance(sv and sv.mast_step or 0)
    end
  end

  if C.pylon.auto_ghost then
    local groups, keys = {}, {}
    for _, d in ipairs(C.pylon_slot_defs()) do
      if not groups[d.side] then groups[d.side] = {}; keys[#keys + 1] = d.side end
      local g = groups[d.side]
      g[#g + 1] = d
    end
    table.sort(keys, function(a, b)
      return (CLUSTER_ORDER[a] or 99) < (CLUSTER_ORDER[b] or 99)
    end)
    for _, side in ipairs(keys) do
      local g = groups[side]
      local cx, cy = 0, 0
      for _, d in ipairs(g) do cx, cy = cx + d.ox / #g, cy + d.oy / #g end
      for _, d in ipairs(clockwise(g, cx, cy)) do
        add("bank", d.ox, d.oy)
        advance(sv and sv.bank_step or 0)
      end
      advance(sv and sv.cluster_gap or 0)
    end
  end

  -- C.lamp_slot_defs is already row by row outward; a row lands on one tick.
  if C.lamp and C.lamp.enabled and C.lamp.auto_ghost then
    local row
    for _, l in ipairs(C.lamp_slot_defs()) do
      if row and l.row ~= row then advance(sv and sv.lamp_step or 0) end
      row = l.row
      add("lamp", l.ox, l.oy)
    end
  end

  schedule_cache = out
  return out
end

--- Put a construction ghost in every empty slot around a new turret, all at
--- once: sixteen capacitor banks, four masts, and the lamps.
function placement.ghost_pylons(turret)
  if not (turret and turret.valid) then return 0 end
  local placed = 0
  for _, job in ipairs(survey_schedule()) do
    local names, name, tol = family(job.kind)
    local pos = {x = turret.position.x + job.ox, y = turret.position.y + job.oy}
    if ghost_one(turret, names, name, pos, tol) then placed = placed + 1 end
  end
  return placed
end

--- Move every lamp around a turret onto the current lamp slots (schema steps
--- 11 and 12, each time the lamp layout changed).
--
-- The player built these, so they are MOVED, never deleted: each real lamp is
-- teleported to the nearest slot nothing else has claimed. Ghosts cost nothing
-- and are simply cleared. Whatever slots are still empty afterwards are
-- ghosted. A lamp that will not teleport (something standing on its slot) is
-- left where it is -- still a working lamp, just in the old place.
-- @param old_reach number  search radius for lamps in the OLD layout
-- @return moved, left
function placement.relocate_lamps(turret, old_reach)
  if not (C.lamp and C.lamp.enabled and turret and turret.valid) then return 0, 0 end
  local surface, c = turret.surface, turret.position
  local slots = {}
  for i, d in ipairs(C.lamp_slot_defs()) do
    slots[i] = {x = c.x + d.ox, y = c.y + d.oy}
  end
  local taken = {}

  local found = surface.find_entities_filtered{position = c, radius = old_reach}
  local lamps = {}
  for _, e in pairs(found) do
    if e.valid then
      if e.name == N.ground_lamp then
        lamps[#lamps + 1] = e
      elseif e.name == "entity-ghost" and e.ghost_name == N.ground_lamp then
        e.destroy()
      end
    end
  end
  -- Deterministic order: nearest-to-gun first, then by unit_number.
  table.sort(lamps, function(a, b)
    local da = (a.position.x - c.x) ^ 2 + (a.position.y - c.y) ^ 2
    local db = (b.position.x - c.x) ^ 2 + (b.position.y - c.y) ^ 2
    if da ~= db then return da < db end
    return (a.unit_number or 0) < (b.unit_number or 0)
  end)

  local moved, left = 0, 0
  for _, l in ipairs(lamps) do
    local best, best_d
    for i, s in ipairs(slots) do
      if not taken[i] then
        local d = (l.position.x - s.x) ^ 2 + (l.position.y - s.y) ^ 2
        if not best_d or d < best_d then best, best_d = i, d end
      end
    end
    if best then
      if best_d < 0.01 or l.teleport(slots[best]) then
        taken[best] = true
        moved = moved + 1
      else
        left = left + 1
      end
    else
      left = left + 1
    end
  end

  for i, s in ipairs(slots) do
    if not taken[i] then
      ghost_one(turret, LAMP_SET, N.ground_lamp, s, C.lamp.link_tolerance)
    end
  end
  return moved, left
end

-- =============================================================================
-- Groundbreaking: survey, then pour
-- =============================================================================

--- Tick offset the pour starts on.
local function pour_start()
  local s = survey_schedule()
  local p = C.foundation.pour
  local last = (#s > 0) and s[#s].t or 0
  return last + (p and p.delay or 0)
end

local function pour_ticks()
  local p = C.foundation.pour
  if not (p and p.enabled and C.foundation.enabled) then return 0 end
  return p.ticks
end

--- Start the groundbreaking sequence for a new turret.
function placement.groundbreak(turret)
  if not (turret and turret.valid and turret.unit_number) then return end
  local f = C.foundation
  local staged = (f.survey and f.survey.enabled) or (f.pour and f.pour.enabled)
  if not staged then
    placement.foundation(turret)
    placement.ghost_pylons(turret)
    return
  end
  -- No pour means the floor goes down at once; the survey still stages.
  if f.enabled and not (f.pour and f.pour.enabled) then
    placement.foundation(turret)
  end

  local cx, cy = tile_origin(turret)
  storage.groundworks[turret.unit_number] = {
    entity  = turret,
    cx = cx, cy = cy,
    started = game.tick,
    ghost_i = 1,
    -- Past the end of the plan = nothing to pour (no inf in a save).
    tile_i  = (f.enabled and f.pour and f.pour.enabled) and 1 or (#floor_plan() + 1),
  }

  -- The outline: construction lines for the pad and the firing ring, gone when
  -- the pour finishes. Anchored to the gun so they die with it.
  local sv = f.survey
  if sv and sv.enabled then
    local reach = C.foundation_reach() + 0.5
    local ttl = pour_start() + pour_ticks()
    if ttl > 0 then
      rendering.draw_rectangle{
        color = sv.outline_color, width = sv.outline_width, filled = false,
        left_top     = {entity = turret, offset = {-reach, -reach}},
        right_bottom = {entity = turret, offset = { reach,  reach}},
        surface = turret.surface, time_to_live = ttl, draw_on_ground = true,
      }
      rendering.draw_circle{
        color = sv.outline_color, width = sv.outline_width, filled = false,
        radius = C.firing_ring_radius(), target = turret,
        surface = turret.surface, time_to_live = ttl, draw_on_ground = true,
      }
    end
  end
end

--- Advance every groundworks job one tick.
local function works_tick(event)
  local works = storage.groundworks
  if not (works and next(works)) then return end
  local tick = event.tick
  local sched = survey_schedule()
  local plan = floor_plan()
  local p = C.foundation.pour
  local start = pour_start()
  local span = math.max(1, pour_ticks())
  local max_d = plan[#plan].d

  for un, job in pairs(works) do
    local e = job.entity
    if not (e and e.valid) then
      works[un] = nil
    else
      local t = tick - job.started

      while job.ghost_i <= #sched and sched[job.ghost_i].t <= t do
        local g = sched[job.ghost_i]
        local names, name, tol = family(g.kind)
        ghost_one(e, names, name,
                  {x = e.position.x + g.ox, y = e.position.y + g.oy}, tol)
        job.ghost_i = job.ghost_i + 1
      end

      if job.tile_i <= #plan and t >= start
         and ((t - start) % (p.interval or 1) == 0 or t - start >= span) then
        local front = max_d * math.min(1, (t - start) / span)
        local tiles = {}
        while job.tile_i <= #plan and plan[job.tile_i].d <= front do
          local pt = plan[job.tile_i]
          tiles[#tiles + 1] = {name = pt.name, position = {job.cx + pt.dx, job.cy + pt.dy}}
          job.tile_i = job.tile_i + 1
        end
        if #tiles > 0 then e.surface.set_tiles(tiles, true) end
      end

      if job.ghost_i > #sched and job.tile_i > #plan then works[un] = nil end
    end
  end
end

-- =============================================================================
-- #61: exclusion zone
-- =============================================================================

--- Is there already one of these too close?
-- Returns the offending entity, or nil.
function placement.too_close(surface, position, force, ignore)
  if C.turret.exclusion_radius <= 0 then return nil end
  local found = surface.find_entities_filtered{
    name = N.turret,
    position = position,
    radius = C.turret.exclusion_radius,
    force = force,
  }
  for _, e in pairs(found) do
    if e.valid and e ~= ignore then return e end
  end
  return nil
end

--- Installations `force` owns, a just-built one included.
local function owned(force)
  local n = 0
  for _, rec in pairs(storage.turrets or {}) do
    local e = rec.entity
    if e and e.valid and e.force == force then n = n + 1 end
  end
  return n
end

--- Refuse the placement and give the item back.
-- Never silently delete a player's turret: it costs 400 steel and 400 concrete.
local function reject(event, entity, reason)
  local player = event.player_index and game.get_player(event.player_index)

  if player then
    player.create_local_flying_text{text = reason, position = entity.position}
    player.play_sound{path = "utility/cannot_build"}
  end

  -- Return the item. mine_entity into the player's inventory does the right
  -- thing for a manually placed entity; for a bot-built one, spill it so it is
  -- picked back up rather than destroyed.
  if player and player.mine_entity(entity, true) then return end

  local surface, position, force = entity.surface, entity.position, entity.force
  entity.destroy{raise_destroy = true}
  surface.spill_item_stack{
    position = position,
    stack = {name = N.turret, count = 1},
    enable_looted = false,
    force = force,
    allow_belts = false,
  }
end

-- =============================================================================
-- Events
-- =============================================================================

function placement.on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end

  local clash = placement.too_close(entity.surface, entity.position,
                                    entity.force, entity)
  if clash then
    reject(event, entity, {"oppenheimer.too-close",
                           tostring(C.turret.exclusion_radius)})
    return
  end

  -- Installations already standing past the capacity (an older save) are kept;
  -- only a new one is refused.
  local cap = C.capacity(entity.force)
  if owned(entity.force) > cap then
    reject(event, entity, {"oppenheimer.capacity-full", tostring(cap)})
    return
  end

  placement.groundbreak(entity)
end

local turret_filter = {{filter = "name", name = N.turret}}

-- Registered AFTER scripts/turret.lua requires, so the turret record already
-- exists by the time this runs -- the dispatcher preserves registration order
-- per event (see scripts/events.lua).
events.on(defines.events.on_built_entity,       placement.on_built, turret_filter)
events.on(defines.events.on_robot_built_entity, placement.on_built, turret_filter)
events.on(defines.events.script_raised_built,   placement.on_built, turret_filter)
events.on(defines.events.script_raised_revive,  placement.on_built, turret_filter)

events.on_nth_tick(1, works_tick)

return placement
