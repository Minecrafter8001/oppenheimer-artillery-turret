-- scripts/targeting.lua -------------------------------------------------------------
-- Who the gun shoots, and how often it wastes a shell. Backlog #31, #32, #33.
--
--   #31  nest-priority targeting -- shoot the worst thing first, not the nearest
--   #32  search-and-destroy sweep -- flare unexplored ground on its own
--   #33  overkill prevention -- six turrets should not all volley one dead nest
--
-- HOW TARGETING WORKS HERE
-- Vanilla artillery picks its own targets, in an order that is close to
-- arbitrary, and has no idea that another turret already has a shell in the air
-- toward the same nest. That is why a battery of vanilla artillery feels stupid:
-- it kills the first nest six times and ignores the second.
--
-- So this mod turns vanilla auto-targeting OFF and does the choosing itself.
--
-- IT NO LONGER DOES THE CHOOSING AT ALL. C.targeting.enabled has been false
-- since #103 -- every shot is designated by a player and released by a player --
-- and targeting.flare places nothing, because there is no longer a
-- hold on the gun to stop a flare firing it for real. What survives here is the
-- scoring and the overkill bookkeeping, kept for a future automatic mode that
-- would have to command the LANCE rather than the engine's own gun.
--
-- Read the warning on targeting.flare before re-arming any of this.
--------------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
local schema = require("scripts.schema")

local targeting = {}

local t = C.targeting

-- =============================================================================
-- #33: overkill prevention
--
-- The whole mechanic is one table: every flare we create is recorded with its
-- position and the tick it expires. Before creating another, we check whether
-- an existing pending strike already covers that spot. Cheap, and it is the
-- difference between a battery that clears a map and one that carpet-bombs a
-- crater.
-- =============================================================================

--- Key a position to a coarse grid so lookups do not need a linear scan.
local function cell_key(pos)
  local s = t.grid_size
  return math.floor(pos.x / s) .. ":" .. math.floor(pos.y / s)
end

--- Is a strike already inbound at this position?
function targeting.strike_pending(surface_index, pos)
  local per_surface = storage.strike_cells and storage.strike_cells[surface_index]
  if not per_surface then return false end

  local s = t.grid_size
  local cx, cy = math.floor(pos.x / s), math.floor(pos.y / s)
  -- Check the neighbouring cells too, or a target sitting just over a cell
  -- boundary from a pending strike looks unclaimed.
  for dx = -1, 1 do
    for dy = -1, 1 do
      local bucket = per_surface[(cx + dx) .. ":" .. (cy + dy)]
      if bucket then
        for _, s2 in pairs(bucket) do
          local ddx, ddy = s2.x - pos.x, s2.y - pos.y
          if (ddx * ddx + ddy * ddy) <= (t.overkill_radius * t.overkill_radius) then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Record a strike so nothing else targets the same ground until it lands.
function targeting.record_strike(surface_index, pos, tick)
  storage.strike_cells = storage.strike_cells or {}
  storage.strike_cells[surface_index] = storage.strike_cells[surface_index] or {}
  local per_surface = storage.strike_cells[surface_index]
  local key = cell_key(pos)
  per_surface[key] = per_surface[key] or {}
  table.insert(per_surface[key], {
    x = pos.x, y = pos.y, expires = tick + t.strike_ttl,
  })
end

--- Drop strikes whose shells have long since landed.
-- Runs on its own slow timer rather than per strike: sweeping a small table
-- every few seconds is far cheaper than scheduling a cleanup per shell.
function targeting.expire_strikes(tick)
  if not storage.strike_cells then return end
  for si, per_surface in pairs(storage.strike_cells) do
    for key, bucket in pairs(per_surface) do
      for i = #bucket, 1, -1 do
        if bucket[i].expires <= tick then table.remove(bucket, i) end
      end
      if #bucket == 0 then per_surface[key] = nil end
    end
    if not next(per_surface) then storage.strike_cells[si] = nil end
  end
end

-- =============================================================================
-- #31: nest-priority targeting
-- =============================================================================

-- What each kind of target is worth hitting. A spawner keeps producing biters
-- forever, so it is worth far more than the worm next to it; a worm that can
-- reach your wall is worth more than one that cannot.
local function score_for(entity)
  local ty = entity.type
  if ty == "unit-spawner" then return t.score_spawner end
  if ty == "turret" then return t.score_worm end
  return t.score_other
end

--- Pick the best thing in range that nothing is already shooting at.
function targeting.best_target(rec)
  local e = rec.entity
  local surface = e.surface
  local range = C.gun.range

  local candidates = surface.find_entities_filtered{
    position = e.position,
    radius = range,
    force = t.enemy_forces,
    type = {"unit-spawner", "turret"},
  }

  local best, best_score
  for _, c in pairs(candidates) do
    if c.valid then
      local dx, dy = c.position.x - e.position.x, c.position.y - e.position.y
      local dist = math.sqrt(dx * dx + dy * dy)
      -- The 32-tile dead zone: the gun physically cannot hit closer than this.
      if dist >= C.gun.min_range and dist <= range then
        if not targeting.strike_pending(surface.index, c.position) then
          -- Value first, then proximity as a tiebreak -- so a battery works
          -- outward through a nest cluster instead of ping-ponging across it.
          local score = score_for(c) - dist * t.distance_penalty
          if not best_score or score > best_score then
            best, best_score = c, score
          end
        end
      end
    end
  end
  return best
end

-- =============================================================================
-- #32: search-and-destroy sweep
--
-- The actual power fantasy: the gun clears the map on its own while you build.
-- It walks outward in a ring, chunk by chunk, and flares any nest it finds in
-- ground it has not swept recently.
-- =============================================================================

--- Advance the sweep one step and return a target if the new ground has one.
function targeting.sweep_step(rec)
  if not t.sweep_enabled then return nil end
  local e = rec.entity
  local surface = e.surface

  rec.sweep = rec.sweep or {ring = 1, index = 0}
  local sw = rec.sweep

  -- Ring of chunk offsets at radius `ring`, walked one index per step.
  local ring = sw.ring
  local per_ring = math.max(1, ring * 8)
  sw.index = sw.index + 1
  if sw.index > per_ring then
    sw.index = 1
    sw.ring = ring + 1
    -- Past the gun's reach there is nothing to find; start over.
    if sw.ring * 32 > C.gun.range then sw.ring = 1 end
  end

  -- Turn (ring, index) into a chunk offset by walking the ring's perimeter.
  local side = math.ceil(sw.index / math.max(1, (per_ring / 4)))
  local step = sw.index % math.max(1, math.floor(per_ring / 4))
  local ox, oy
  if side == 1 then ox, oy = -ring + step, -ring
  elseif side == 2 then ox, oy = ring, -ring + step
  elseif side == 3 then ox, oy = ring - step, ring
  else ox, oy = -ring, ring - step end

  local pos = {
    x = e.position.x + ox * 32,
    y = e.position.y + oy * 32,
  }

  if not surface.is_chunk_generated{x = math.floor(pos.x / 32),
                                    y = math.floor(pos.y / 32)} then
    return nil
  end

  local found = surface.find_entities_filtered{
    area = {{pos.x - 16, pos.y - 16}, {pos.x + 16, pos.y + 16}},
    force = t.enemy_forces,
    type = {"unit-spawner", "turret"},
    limit = 8,
  }

  for _, c in pairs(found) do
    if c.valid then
      local dx, dy = c.position.x - e.position.x, c.position.y - e.position.y
      local dist = math.sqrt(dx * dx + dy * dy)
      if dist >= C.gun.min_range and dist <= C.gun.range
         and not targeting.strike_pending(surface.index, c.position) then
        return c
      end
    end
  end
  return nil
end

-- =============================================================================
-- Firing
-- =============================================================================

--- Records the intent; places nothing. Nothing calls it (C.targeting.enabled is false).
-- NEVER PUT THE create_entity BACK: a flare is a firing order, and this loaded,
-- undisabled gun would fire a real shell at it outside the sequence. Automatic
-- targeting, if revived, must command the LANCE (scripts/beam.lua).
function targeting.flare(rec, position)
  local e = rec.entity
  if not (e and e.valid) then return nil end
  targeting.record_strike(e.surface.index, position, game.tick)
  return nil
end

--- Called from the turret FSM when a charged gun may pick something to hit.
function targeting.acquire(rec)
  if not t.enabled then return nil end
  if not schema.valid(rec) then return nil end

  -- #31 first: anything valuable already in range.
  local target = targeting.best_target(rec)
  -- #32: nothing nearby, so go looking.
  if not target then target = targeting.sweep_step(rec) end
  if not target or not target.valid then return nil end

  local flare = targeting.flare(rec, target.position)
  if flare then
    -- #65 needs a firing bearing. `shooting_target` is the obvious source and is
    -- NOT readable on an artillery turret (see scripts/pylon.lua bearing()), but
    -- this mod picked the target itself -- so it already knows where the gun is
    -- pointed. Plain {x, y}: goes into storage, stays serialisable.
    rec.aim = {x = target.position.x, y = target.position.y}
  end
  return flare
end

-- =============================================================================
-- Events
-- =============================================================================

-- Strike expiry runs on a slow timer of its own. There is no reason to sweep
-- this table at the turret update rate.
events.on_nth_tick(t.expire_interval, function(event)
  targeting.expire_strikes(event.tick)
end)

return targeting
