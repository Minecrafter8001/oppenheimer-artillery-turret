-- scripts/flora.lua --------------------------------------------------------------
-- TREES AND ROCKS: WHAT THE HEAT DOES TO THEM, WITHOUT THE ENGINE'S DEBRIS STORM.
--
-- WHY THEY ARE NEVER damage()d OR die()d BY THE BLAST. A base tree variation
-- emits leaves_when_damaged (200) x the fraction of health lost, and on death
-- another 35 leaves and 16 branches -- branch-particle lives 1200 ticks, and all
-- of it is spawned inside the damage() call. One blast dose kills a 50 HP tree
-- outright, so every tree the wave paid was ~250 particles, and at the 600/tick
-- payout budget a forest cost ~150k particles a tick: F4 "Particle update" at
-- 160 ms/tick, plus most of this mod's own script time. Base rocks do the same
-- on death (big-rock: ~17 stone particles), though nothing on damage.
--
-- WHAT HAPPENS INSTEAD. Under C.blast.rings.flora.vaporize_all (the default)
-- everything the front reaches is destroyed, to the full blast radius, so no
-- later phase has flora left to search or re-treat. With it off:
--   swallowed by the charging sphere                           destroyed
--   inside the fireball ring (u <= C.blast.rings.fireball_u)   destroyed
--   outside both trees are CHARRED -- last growth stage (leafless), last gray
--                stage -- and left standing; other simple-entities (rocks) are
--                destroyed if the ring law's dose would kill them (resistances
--                ignored -- they only ever lower damage, so this can over-kill
--                a resistant rock but never spare one that would have died),
--                otherwise damaged.
-- The real debris is a separate FIXED trickle at the shock front: flora.debris.
--
-- WHO DRIVES IT. One front per detonation point (surface + position), fed by
-- whichever phase owns the radius: the charging sphere's rim while the lance
-- sustains (scripts/beam.lua), then the shock front (scripts/detonate.lua).
-- The sphere grows to the full blast radius under an opaque fill, so its front
-- VAPORIZES (st.vaporize): nothing is visible inside the ball, so a plain
-- destroy on the rim is both the cheapest treatment and the physical one, and
-- the collapse reveals bare ground. Charring only applies where the wave alone
-- reaches. A detonation with no sphere (the shell path, detonate_at "ignite")
-- is fed by the wave alone. Either way the wave's own entity search excludes
-- these types engine-side, so a tree never crosses into Lua twice.
--
-- WHAT IT OWNS is decided from the prototype (is_flora below), not from a list
-- of type names, so modded trees and scrub are covered without this file
-- knowing which mods are loaded. Ground past C.blast.rings.generate_ahead_radius
-- is not this module's: nothing builds it during the shot, and scripts/scar.lua
-- replays the blast onto it through detonate.hit, which routes flora back here.
--
-- NO ENTITY HANDLES ARE STORED. Trees and rocks do not move, so a front is a
-- pair of radii: each pass searches the chunks the annulus (done, target]
-- touches and treats exactly the things whose distance falls inside it --
-- half-open, so nothing is treated twice. The price is re-searching a chunk
-- while the annulus crosses it, bounded by min_step; the alternative is
-- millions of tree references held in storage on a forested full-yield shot.
--
-- DETERMINISM: arithmetic, find_entities_filtered, math.random (deterministic in
-- the control stage), game.connected_players (synced). The debris counter is
-- scratch keyed by game.tick, never state.
----------------------------------------------------------------------------------

local C     = require("config")
local front = require("scripts.front")

local flora = {}

local DIAG = 46   -- a chunk's diagonal, rounded up
local atan2 = math.atan2 or math.atan

--- IS THIS PROTOTYPE FLORA. Decided from what the prototype IS, so a mod's
--- trees and scrub are covered without this file knowing the mod exists.
--
--   tree / plant   every TreePrototype, and PlantPrototype which inherits it
--                  but carries its OWN data.raw key -- a "tree"-only filter
--                  silently misses every Space Age crop and anything else
--                  built on `plant`.
--   rock           count_as_rock_for_filtered_deconstruction, the same flag
--                  the deconstruction planner's "trees and rocks" filter uses.
--   scenery        a simple-entity the map generator places and no force can
--                  build: modded undergrowth, coral, bones, scrub.
local function is_flora(p)
  local t = p.type
  if t == "tree" or t == "plant" then return true end
  if t == "simple-entity" then
    if p.count_as_rock_for_filtered_deconstruction then return true end
    return p.autoplace_specification ~= nil and not p.is_building
  end
  -- ⚠️ NOT simple-entity-with-owner/-with-force. Ownership below is at TYPE
  -- level, and mods use those two for placeable scripted entities: claiming
  -- the type for one autoplaced shrub would exclude every other member from
  -- the wave's search and leave it damaged by nobody.
  return false
end

-- SCRATCH, built once on first use in the control stage: the types holding any
-- flora prototype, and the set form of the same. Ownership stays at TYPE level
-- because the wave excludes these types from its search engine-side -- a type
-- half in and half out would leave its other half paid by nobody.
local TYPES, OWNED

local function classify()
  if TYPES then return end
  TYPES, OWNED = {}, {}
  for _, p in pairs(prototypes.entity) do
    local t = p.type
    if not OWNED[t] and is_flora(p) then
      OWNED[t] = true
      TYPES[#TYPES + 1] = t
    end
  end
end

--- The types this module owns. The wave excludes them from its own search.
--- Every name comes out of prototypes.entity, so find_entities_filtered can
--- never throw on one.
function flora.types()
  classify()
  return TYPES
end

function flora.enabled()
  local fc = C.blast.rings.flora
  return fc and fc.enabled or false
end

function flora.owns(e)
  classify()
  return OWNED[e.type] == true
end

-- =============================================================================
-- One thing
-- =============================================================================

--- Last growth stage, last gray stage: a leafless, burnt-out tree.
local function char(e)
  local sm = e.tree_stage_index_max
  if sm and sm > 0 and e.tree_stage_index ~= sm then e.tree_stage_index = sm end
  local gm = e.tree_gray_stage_index_max
  if gm and gm > 0 and e.tree_gray_stage_index ~= gm then e.tree_gray_stage_index = gm end
end

--- Treat one tree or rock at distance d from a blast of radius `radius`.
-- @param force ForceID  credited for a rock's damage
-- @param vaporize boolean  destroy regardless of distance (inside the sphere)
function flora.treat(e, d, radius, force, vaporize)
  if not e.valid then return end
  local rings = C.blast.rings
  local u = (radius > 0) and (d / radius) or 0

  -- BEFORE the destructible gate. `destructible` governs damage, and this path
  -- takes none -- it removes the entity outright. A mod that ships indestructible
  -- scenery left trees standing inside an opaque fireball.
  --
  -- vaporize_all: leave NOTHING on the disc. char() only recolours a tree whose
  -- prototype ships dying/gray stages (TreeVariation deduces them from the
  -- shadow/trunk frame count), so a mod's single-stage tree was charred to no
  -- visible effect and stood there for every later phase to find and re-treat.
  if vaporize or rings.flora.vaporize_all or u <= rings.fireball_u then
    e.destroy{raise_destroy = true}
    return
  end

  if not e.destructible then return end

  -- Charred and left standing. `plant` inherits TreePrototype and carries the
  -- same stage indices; pcall because a class-gated attribute read can throw
  -- instead of returning nil, and a tree this far out is never damaged anyway,
  -- so a failure costs the colour and nothing else.
  local t = e.type
  if t == "tree" or t == "plant" then
    pcall(char, e)
    return
  end

  local hp = e.health
  if not hp then return end
  -- HIT POINTS from dose_at directly (see C.blast.dose). No yield fraction
  -- threaded here on purpose: flora.advance is four call sites deep and this is
  -- trees and rocks, so the full-dial thermal reach is the right default -- it
  -- only ever means a small shot scorches its own scrub slightly further out.
  local amount = rings.dose_at(u)
  if amount >= hp then
    e.destroy{raise_destroy = true}
  elseif amount > 0 then
    e.damage(amount, force, rings.damage_type)
  end
end

-- =============================================================================
-- The front
-- =============================================================================

local function key(surface_index, x, y)
  return string.format("%d:%.2f:%.2f", surface_index, x, y)
end

--- Drop fronts nobody has fed for stale_ticks. Run when a front is created, so
--- the table never outgrows the shots actually in flight.
local function prune(fl, stale)
  local now = game.tick
  for k, st in pairs(fl) do
    if now - st.fed > stale then fl[k] = nil end
  end
end

--- Feed the front for the blast at (x, y) up to radius r, and do one pass.
-- Created on first call. Calls after it has finished are a table lookup -- the
-- finished front is kept (until stale) so the wave arriving after the sphere
-- does not start a second pass over the same disc.
-- NEVER GENERATES GROUND. A pass stops just short of the nearest ungenerated
-- chunk (a tree in it is at least that chunk's nearest distance away, so
-- everything nearer is exact) and retries after `retry` ticks. The sphere
-- phase generated nothing before this module existed; the wave's own search
-- generates the ground just ahead of itself, so the front always completes.
-- @param radius number  the BLAST radius (C.yield.radius), not the sphere's
-- @param r      number  how far the driving phase has reached
-- @param retry  number  ticks to wait after hitting ungenerated ground
-- @param vaporize boolean  the sphere's front: destroy everything it reaches.
--   Sticky on the front, so the wave finishing a pass the sphere started
--   (ungenerated ground) treats the rest of the disc the same way.
function flora.advance(surface, x, y, radius, r, force, retry, vaporize)
  local fc = C.blast.rings.flora
  if not (fc and fc.enabled) then return end
  if not (surface and surface.valid) or not radius or radius <= 0 then return end

  local fl = storage.flora   -- created by schema.ensure (ARCHITECTURE rule 5)
  if not fl then return end
  local k = key(surface.index, x, y)
  local st = fl[k]
  if not st then
    prune(fl, fc.stale_ticks)
    st = {
      x = x, y = y, radius = radius,
      done = -1,               -- treated: everything with d <= done
      goal = 0,                -- the farthest any driver has asked for
      cap = fc.max_step,       -- adaptive annulus width, tiles
      force = force or C.blast.rings.default_force,
      fed = game.tick,
      found = 0, passes = 0,
    }
    fl[k] = st
  end
  if vaporize then st.vaporize = true end
  st.fed = game.tick
  if radius > st.radius then st.radius = radius end
  if r > st.goal then st.goal = r end
  local goal = st.goal
  if goal > st.radius then goal = st.radius end

  local done = st.done
  if goal <= done then return end
  -- The wave (retry 0) never waits out a retry the sphere set.
  if st.retry_at and retry ~= 0 and game.tick < st.retry_at then return end
  local target = done + st.cap
  if target > goal then target = goal end
  -- Wait for min_step of travel, except to finish the rim.
  if target < st.radius and target - math.max(done, 0) < fc.min_step then return end

  local cx, cy, R = st.x, st.y, st.radius
  local fname, fvap = st.force, st.vaporize
  -- flora.types(), never the file-local: a nil `type` is not an empty filter,
  -- it is NO filter, so the pass returns every entity in the annulus, doses the
  -- player's own buildings and collapses `cap` to min_step on the count.
  local types = flora.types()
  local n = 0

  -- Chunks whose NEAREST point is within target and whose FARTHEST point is
  -- beyond done: nearest in (done - DIAG, target].
  --
  -- UNGENERATED GROUND, AND WHO COMES BACK FOR IT. `done` is one scalar radius,
  -- so a hole anywhere in the annulus holds the front back in every direction --
  -- which is right only while something is still going to build that hole.
  --
  --   inside generate_ahead_radius   the fronts build it, within a tick or two.
  --                                  Stop short and retry: those trees are ours.
  --   beyond it                      nothing will ever build it during this
  --                                  shot. scripts/scar.lua pays those chunks on
  --                                  generation, through the same
  --                                  detonate.hit -> flora.treat. Skipping them
  --                                  costs nothing (an ungenerated chunk holds
  --                                  no trees) and waiting costs everything:
  --                                  `done` would never reach `radius`,
  --                                  flora.finished would never return true, and
  --                                  the sweep it gates would never tear down.
  local built = C.blast.rings.generate_ahead_radius or 0
  local blocked
  front.each_ring_run(cx, cy, done - DIAG, target, function(j, i0, i1)
    for i = i0, i1 do
      if not surface.is_chunk_generated({i, j}) then
        local x0, y0 = i * 32, j * 32
        local dx = math.max(x0 - cx, 0, cx - (x0 + 32))
        local dy = math.max(y0 - cy, 0, cy - (y0 + 32))
        local nd = math.sqrt(dx * dx + dy * dy)
        if nd <= built and (not blocked or nd < blocked) then blocked = nd end
      end
    end
  end)
  st.retry_at = nil
  if blocked then
    target = blocked - 0.01
    if target <= done then
      st.retry_at = game.tick + (retry or fc.sphere_retry_ticks)
      return
    end
  end

  front.each_ring_run(cx, cy, done - DIAG, target, function(j, i0, i1)
    local x0, x1 = i0 * 32, (i1 + 1) * 32
    local y0, y1 = j * 32, (j + 1) * 32
    local ents = surface.find_entities_filtered{
      area = {{x0, y0}, {x1, y1}},
      type = types,
    }
    n = n + #ents
    for i = 1, #ents do
      local e = ents[i]
      if e.valid then
        local p = e.position
        if p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1 then
          local dx, dy = p.x - cx, p.y - cy
          local d = math.sqrt(dx * dx + dy * dy)
          if d > done and d <= target and d <= R then
            flora.treat(e, d, R, fname, fvap)
          end
        end
      end
    end
  end)

  st.done = target
  st.found = st.found + n
  st.passes = st.passes + 1

  -- Size the next annulus by what this one cost.
  if n > fc.budget then
    st.cap = math.max(fc.min_step, st.cap * 0.5)
  elseif n * 2 < fc.budget then
    st.cap = math.min(fc.max_step, st.cap * 2)
  end
end

--- Has the front for the blast at (x, y) reached its rim? True when there is no
--- front (disabled, or never fed), so it can never hold a caller open forever.
function flora.finished(surface_index, x, y)
  local fl = storage.flora
  local st = fl and fl[key(surface_index, x, y)]
  return not st or st.done >= st.radius
end

-- =============================================================================
-- The real debris
-- =============================================================================

-- SCRATCH: trees still allowed to die with their own effects this tick, across
-- every sweep. Reset on the first call of each tick.
local DEBRIS_TICK, DEBRIS_LEFT = -1, 0

--- Knock a few trees down properly at the shock front, where someone can see it.
-- Base leaf/branch particles are only_when_visible, so a probe spent off-screen
-- buys nothing: aim_fraction of the probes go to the stretch of front nearest a
-- connected player (player.position -- whether that follows remote view in
-- 2.0.77 is UNVERIFIED; if not, a player watching from the map gets uniform
-- probes only).
function flora.debris(surface, x, y, radius, r, force)
  local fc = C.blast.rings.flora
  local db = fc and fc.enabled and fc.debris
  if not (db and db.enabled) then return end
  if r < 1 or r <= C.blast.rings.fireball_u * radius then return end

  local tick = game.tick
  if DEBRIS_TICK ~= tick then DEBRIS_TICK, DEBRIS_LEFT = tick, db.per_tick end
  if DEBRIS_LEFT <= 0 then return end

  local aims = nil
  local sidx = surface.index
  for _, pl in pairs(game.connected_players) do
    if pl.surface_index == sidx then
      local pp = pl.position
      local dx, dy = pp.x - x, pp.y - y
      local pd = math.sqrt(dx * dx + dy * dy)
      if math.abs(pd - r) <= db.aim_tiles and pd > 0 then
        aims = aims or {}
        aims[#aims + 1] = atan2(dy, dx)
      end
    end
  end

  local spread = db.aim_tiles / r
  for _ = 1, db.probes do
    if DEBRIS_LEFT <= 0 then return end
    local a
    if aims and math.random() < db.aim_fraction then
      a = aims[math.random(#aims)] + (math.random() * 2 - 1) * spread
    else
      a = math.random() * 2 * math.pi
    end
    local t = surface.find_entities_filtered{
      position = {x + math.cos(a) * r, y + math.sin(a) * r},
      radius = db.probe_radius, type = "tree", limit = 1,
    }[1]
    if t and t.valid and t.destructible then
      t.die(force)
      DEBRIS_LEFT = DEBRIS_LEFT - 1
    end
  end
end

return flora
