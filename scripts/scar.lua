-- =============================================================================
-- SCARS -- the blast outlives its own shock wave.
--
-- WHY THIS EXISTS. Past C.blast.rings.generate_ahead_radius the detonation does
-- not build ground. It cannot afford to: force_generate_chunk_requests() blocks
-- and drains the whole queue (measured at 83% of a full-dial tick), and the
-- chunks it leaves behind are permanent save file -- a 10000 tile disc is about
-- 307000 of them, which is several times an entire megabase map.
--
-- Not building it costs nothing in damage, because AN UNGENERATED CHUNK HOLDS
-- NO ENTITIES. Its contents have not been decided yet; the map seed decides
-- them at generation time. There is no biter there to miss.
--
-- What it WOULD cost, without this file, is permanence. Chart toward an old
-- crater a week later and the ground would generate fresh -- pristine, full
-- nests, as though nothing had happened. The crater would heal the moment
-- anyone looked at it, which is the one outcome that actually defeats the
-- weapon.
--
-- So every wide shot writes a footprint (scripts/detonate.lua), and this file
-- replays it: a chunk that materialises inside a past footprint takes that
-- shot's dose, at the distance it actually sits, through the same
-- detonate.hit the live sweep used. One payout implementation, two callers.
--
-- COST. One squared-distance test per recorded scar per chunk generated,
-- against a generation step that costs orders of magnitude more. Scars are
-- capped at C.blast.scars.max_records and a record is seven numbers.
--
-- on_chunk_generated fires exactly ONCE per chunk, ever, so a biter that walks
-- into the crater afterwards correctly survives. The blast is over; the ground
-- remembers it.
-- =============================================================================

local C      = require("config")
local events = require("scripts.events")
local slay   = require("scripts.slay")
local detonate = require("scripts.detonate")
local crater   = require("scripts.crater")
local flora    = require("scripts.flora")
local front    = require("scripts.front")
local profile  = require("scripts.profile")

local scar = {}

--- Shortest distance from (x, y) to a chunk's box -- the same "nearest point"
--- scripts/front.lua's each_ring_run acquires a chunk by, so the two agree on
--- which side of a radius a chunk falls.
local function near_of(a, x, y)
  local lx, ly = a.left_top.x, a.left_top.y
  local rx, ry = a.right_bottom.x, a.right_bottom.y
  local dx, dy = 0, 0
  if x < lx then dx = lx - x elseif x > rx then dx = x - rx end
  if y < ly then dy = ly - y elseif y > ry then dy = y - ry end
  return math.sqrt(dx * dx + dy * dy)
end

--- WHO PAYS A CHUNK THAT APPEARS WHILE A SWEEP IS STILL IN FLIGHT: the front, or
--- this file. Decided by RADIUS, never by the clock.
--
-- The front acquires a ring exactly once, the tick it comes within lead of it,
-- and pays only what exists THEN. An ungenerated chunk it acquires holds nothing,
-- and the front does not come back. So:
--   near > acq   the front has not searched it yet and will find whatever
--                generation puts there -- the front's, we must not pay it twice.
--   near <= acq  the front already went past it empty -- ours, pay it now.
-- The old rule ("nothing before ready_tick") was true only for the first case and
-- dropped the second on the floor: a chunk generated mid-flight behind the front's
-- search -- most easily by a camera zooming out over unexplored ground -- was
-- paid by nobody, and its nests stood untouched inside a disc that had been
-- "obliterated". Whether they died depended on where a player happened to look.
--
-- After ready_tick the front owns nothing. A record without `acq` (saved before
-- it existed) keeps the old, coarser rule.
local function front_owns(s, near, tick)
  if tick >= (s.ready_tick or 0) then return false end
  local acq = s.acq
  if acq == nil then return true end
  return near > acq
end

--- Pay one freshly generated chunk for one scar.
local function apply(surface, area, s, budget)
  local ents = surface.find_entities_filtered{area = area}
  local inner = s.inner or 0
  local paid = 0

  -- A sweep-shaped record, because detonate.hit reads a sweep. The counters are
  -- real fields rather than nil: hit() increments them and a nil would throw on
  -- a path nobody watches.
  local sw = {
    radius = s.radius, variant = s.variant, crater = s.crater,
    force = s.force, destroyed = 0, damaged = 0,
  }

  -- TREES AND ROCKS ARE NOT CHARGED THE BUDGET. This is the only payer for
  -- every chunk past generate_ahead_radius, so a forested chunk metering its
  -- trees against 400 would spend the lot and leave its nests standing -- and
  -- flora.treat is a stage-index write or a destroy, not the corpse,
  -- statistics and death-effect path the budget exists to meter. The live
  -- sweep does not charge them either: the wave excludes flora types from its
  -- search engine-side and scripts/flora.lua runs on its own front.
  local touched = 0
  for k = 1, #ents do
    if paid >= budget then break end
    local e = ents[k]
    if e.valid and e.health then
      local p = e.position
      local dx, dy = p.x - s.x, p.y - s.y
      local d = math.sqrt(dx * dx + dy * dy)
      -- OUTSIDE THE THEATRE ONLY. Everything within `inner` was generated and
      -- paid by the front as it passed, so treating it here would damage it a
      -- second time. The annulus is exactly the ground the sweep declined to
      -- build.
      if d > inner and d <= s.radius then
        local free = flora.enabled() and flora.owns(e)
        detonate.hit(sw, e, d)
        touched = touched + 1
        if not free then paid = paid + 1 end
      end
    end
  end
  return touched
end

--- Apply every past blast that covers a scar record's chunk.
local function replay(surface, event, scars, sc)
  local si = surface.index
  local a  = event.area
  local cp = event.position
  local tick = event.tick or game.tick
  local any = false
  for k = 1, #scars do
    local s = scars[k]
    if s.surface == si then
      local near = near_of(a, s.x, s.y)
      -- A chunk whose nearest point is inside `inner` was generated by the front
      -- itself (front.lua builds everything with near <= generate_to) and paid
      -- whole, entities beyond `inner` included -- it is never ours.
      if near <= s.radius and near > (s.inner or 0)
         and not front_owns(s, near, tick) then
        local paid = apply(surface, a, s, sc.budget_per_chunk or 400)
        any = true
        -- A chunk charted before it was generated (deleted, then regenerated) keeps its old picture.
        if paid > 0 then
          local force = game.forces[s.force]
          if force and force.is_chunk_charted(surface, cp) then
            force.chart(surface, front.chunk_box(cp.x, cp.x, cp.y))
          end
        end
      end
      if s.crater then crater.replay(surface, a, s) end
    end
  end
  -- MUST flush in-tick: slay credits kills by hand, and an unflushed batch is lost.
  if any then slay.flush() end
end

--- A chunk has just come into existence: past blasts covering it are applied, then
--- a running wave that has charted past it charts it.
local function on_chunk_generated(event)
  local surface = event.surface
  if not (surface and surface.valid) then return end
  local sc = C.blast.scars
  local scars = storage.scars
  if sc and sc.enabled and scars and #scars > 0 then
    profile.start("scar/on_chunk_generated")
    replay(surface, event, scars, sc)
    profile.stop("scar/on_chunk_generated")
  end
  detonate.reveal(surface, event.position)
end

events.on(defines.events.on_chunk_generated, on_chunk_generated)

--- Forget everything recorded against a deleted surface: its index can be
--- reused, and a stale scar would replay an old blast onto the new surface.
local function on_surface_deleted(event)
  local si = event.surface_index
  for _, list in ipairs({storage.scars, storage.shots}) do
    for i = #list, 1, -1 do
      if list[i].surface == si then table.remove(list, i) end
    end
  end
  if storage.strike_cells then storage.strike_cells[si] = nil end
  local prefix = si .. ":"
  for k in pairs(storage.flora or {}) do
    if k:sub(1, #prefix) == prefix then storage.flora[k] = nil end
  end
  local suffix = ":" .. si
  for k in pairs(storage.alpha_order or {}) do
    if type(k) == "string" and k:sub(-#suffix) == suffix then storage.alpha_order[k] = nil end
  end
end

events.on(defines.events.on_surface_deleted, on_surface_deleted)

--- How many footprints are on record, for /oppenheimer-status.
function scar.count()
  local s = storage.scars
  return s and #s or 0
end

return scar
