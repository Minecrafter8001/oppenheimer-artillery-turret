-- scripts/impact.lua -------------------------------------------------------------
-- What happens where a strike lands.
--
-- A detonation is a data-stage trigger tree with no runtime handle (there is
-- no LuaEntity.blast_radius to multiply for a 25% shot), so it is built once
-- per selectable yield (prototypes/vfx/waves.lua) and wrapped in an invisible
-- carrier explosion (prototypes/vfx/carriers.lua) whose created_effect fires
-- the whole staged detonation. impact.detonate is the one place that creates
-- one, called directly by scripts/beam.lua at the cut (the live path) and, for
-- a pre-0.8.0 save with a shell already in flight, via the vestigial
-- on_script_trigger_effect/nearest-pending-strike matching below -- kept
-- because a round that lands and does nothing is a worse bug than one that
-- detonates at the wrong (100%, unmatched) yield.
----------------------------------------------------------------------------------

local C        = require("config")
local N        = require("lib.names")
local events   = require("scripts.events")
local detonate = require("scripts.detonate")
local implode  = require("scripts.implode")

local impact = {}

-- =============================================================================
-- Strikes in flight
-- =============================================================================

--- Record a strike so the shell can be matched to its yield when it arrives.
-- Called from turret.discharge, at the moment the round is committed.
-- @param surface_index number
-- @param pos    table   where it was aimed
-- @param power  number  yield as a fraction of a standard shot
-- @param tick   number
function impact.expect(surface_index, pos, power, tick)
  storage.shots = storage.shots or {}
  storage.shots[#storage.shots + 1] = {
    surface = surface_index,
    x = pos.x, y = pos.y,
    power = power,
    expires = tick + C.charge.impact_ttl,
  }
end

--- Drop strikes whose shells were never going to arrive.
-- Reverse iteration, because table.remove shifts everything after the index.
local function expire(tick)
  local shots = storage.shots
  if not shots then return end
  for i = #shots, 1, -1 do
    if shots[i].expires <= tick then table.remove(shots, i) end
  end
end

--- Claim the pending strike nearest this landing, and return its yield.
-- Claiming removes it: two shells must not both spend the same order.
-- @return number|nil power, as a fraction of a standard shot
local function claim(surface_index, pos)
  local shots = storage.shots
  if not shots or #shots == 0 then return nil end

  local limit = C.charge.impact_match_radius * C.charge.impact_match_radius
  local best, best_d2

  for i = 1, #shots do
    local s = shots[i]
    if s.surface == surface_index then
      local dx, dy = s.x - pos.x, s.y - pos.y
      local d2 = dx * dx + dy * dy
      if d2 <= limit and (not best_d2 or d2 < best_d2) then
        best, best_d2 = i, d2
      end
    end
  end

  if not best then return nil end
  local power = shots[best].power
  table.remove(shots, best)
  return power
end

-- =============================================================================
-- Choosing a carrier
-- =============================================================================

--- Which built variant a given power gets. The variants exist only at the
--- selectable steps, so anything between them rounds DOWN to the step at or
--- below it -- a shot never detonates bigger than it was paid for.
--
-- SNAPPING: rounded against power/stall_fraction, not power itself, so a shot
-- a hair under its order still detonates at the yield selected rather than
-- dropping a whole tier for a rounding error. Same tolerance that decides
-- "stalled", so the two rules can't disagree -- any shot that didn't warn
-- detonates at what the player chose. Steps are 25% apart and the tolerance
-- is 5%, so nothing can snap up a tier it didn't nearly reach.
-- @param power number|nil
-- @return number the fraction of a variant that was actually built
function impact.variant_for(power)
  local steps = C.charge.yield_targets
  local fallback = C.charge.yield_default
  if not power then return fallback end

  local reach = power / math.max(0.01, C.charge.stall_fraction)

  local best = nil
  for _, step in ipairs(steps) do
    if reach >= step.fraction - 1e-6 then
      if not best or step.fraction > best then best = step.fraction end
    end
  end
  -- Below every step: a shot so starved it did not reach even the smallest
  -- variant still detonates, at the smallest one that exists.
  if not best then
    best = steps[1].fraction
    for _, step in ipairs(steps) do
      if step.fraction < best then best = step.fraction end
    end
  end
  return best
end

-- =============================================================================
-- Settling the ground the shot will land on
-- =============================================================================

--- Queue generation of the square of chunks around a shot, capped at
--- C.blast.rings.pregen.max_chunks; past it only scripts/scar.lua pays the blast.
-- @param surface      LuaSurface
-- @param pos          MapPosition  blast centre
-- @param radius_tiles number       blast radius in tiles (C.yield.radius)
-- @param blocking     boolean      the strike: also flush the queue when pregen.force_at_strike is set
function impact.settle_terrain(surface, pos, radius_tiles, blocking)
  local pg = C.blast.rings.pregen
  if not (pg and pg.enabled) then return end
  if not (surface and surface.valid and pos) then return end
  if not (radius_tiles and radius_tiles > 0) then return end

  local cr = math.ceil(radius_tiles / 32) + (pg.margin_chunks or 1)
  local cap = pg.max_chunks
  if cap and cr > cap then cr = cap end
  surface.request_to_generate_chunks(pos, cr)
  if blocking and pg.force_at_strike then
    surface.force_generate_chunk_requests()
  end
end

-- =============================================================================
-- Detonating
-- =============================================================================

--- PUT THE DETONATION ON THE GROUND. The one place in the mod that does. The
--- carrier is an explosion whose created_effect IS the staged detonation, so
--- creating it is the entire delivery -- same pattern base uses for the
--- nuke's terrain scarring. Called directly by the beam at ignition (no
--- flight, nothing to match) and, for the vestigial shell path, from the
--- trigger handler below.
-- @param power number|nil fraction of a standard shot; nil detonates at the
--        default yield rather than not at all
-- @param force ForceID|nil who gets the kill credit for the sweep
-- @param kelvin number|nil the sphere's temperature at the cut (C.heat), so the
--        collapse starts from the ball's own colour
-- @param radius number|nil the radius the sphere reached, so the collapse starts
--        at the size on screen; nil derives it from `power`
-- `power` is the DIALLED yield: it sizes the crater, the variant and the
-- collapse. `delivered` is what the converged group actually released, and only
-- the damage sweep reads it.
function impact.detonate(surface, pos, power, force, kelvin, radius, delivered)
  if not (surface and surface.valid and pos) then return end

  -- ONE VARIANT, READ ONCE: the carrier, the collapse and the sweep all have
  -- to be built for the same yield step or the picture and the damage come
  -- apart.
  local variant = impact.variant_for(power)

  -- THE VISUALS. The carrier's own dart fans carry no damage (see the
  -- derived block in config.lua) -- purely decorative, so their counts are
  -- kept low as a frame-rate cost, not a gameplay one.
  surface.create_entity{
    name = N.detonation(variant),
    position = pos,
  }

  -- THE COLLAPSE. The carrier's own stages are all offset by
  -- total_ticks_for(variant); this is what fills those ticks. It runs in the
  -- control stage because a data-stage trigger tree cannot be told the shell's
  -- circumference, the radius the charging sphere actually reached, or a shape.
  --
  -- `power` goes in RAW, not as the variant: the ball was drawn at the real
  -- continuous radius all the way through the sustain, so the collapse has to
  -- start there or it steps size on the frame the beam cuts -- which is the
  -- discontinuity the whole rework is about. The variant only names prototypes.
  implode.begin(surface, pos, power or C.charge.yield_default, variant, force,
                kelvin, radius)

  -- THE DAMAGE. One query, one binning pass, paid out as the front passes --
  -- scripts/detonate.lua. It is scheduled from the same call as the visuals so
  -- there is still exactly one place in this mod that puts a detonation on the
  -- ground, which is the property this function existed for in the first place.
  --
  -- `power` is a fraction of a standard shot; the sweep needs the TRIGGER ENERGY
  -- in joules, because that is what the yield model is a function of. One
  -- multiplication, done here rather than inside detonate.begin, so the sweep
  -- never has to know what a "standard shot" is.
  -- The variant is the yield step this shot rounds DOWN to, and the sweep needs
  -- it to name the shock-front puff built at that size. Same call that names the
  -- carrier, so the wave and the carrier can never be built for different steps.
  -- THE TEMPERATURE THE WAVE STARTS AT is the ball's at the moment it let go,
  -- not at the cut: the collapse compresses the same energy into a shrinking
  -- volume and keeps heating it, which is what C.heat.collapse_gain is, and
  -- scripts/implode.lua draws the ball at exactly this value on its last tick.
  -- So the shock wall's first colour is the last colour of the thing that
  -- threw it -- one temperature thread from the lance through the sphere and
  -- the collapse to the rim of the crater, instead of three palettes tuned
  -- separately and drifting apart.
  local release_k = kelvin and (kelvin * (1 + C.heat.collapse_gain)) or nil
  detonate.begin(surface, pos,
                 (power or C.charge.yield_default) * C.charge.cost_per_shot,
                 force, variant, release_k, delivered or power)
end

-- =============================================================================
-- Events
-- =============================================================================

--- Something landed and raised our trigger. Detonate at the yield it carried.
--- The vestigial shell path (see this file's header) -- the lance never
--- raises this.
function impact.on_trigger(event)
  if event.effect_id ~= N.fx.detonated then return end

  local pos = event.target_position or event.source_position
  if not pos then return end

  local surface = game.get_surface(event.surface_index)
  if not (surface and surface.valid) then return end

  impact.detonate(surface, pos, claim(event.surface_index, pos))
end

events.on(defines.events.on_script_trigger_effect, impact.on_trigger)

-- Expiry runs on a slow timer of its own; there is no reason to sweep a table
-- this small at the turret update rate.
events.on_nth_tick(C.charge.impact_ttl, function(event)
  expire(event.tick)
end)

return impact
