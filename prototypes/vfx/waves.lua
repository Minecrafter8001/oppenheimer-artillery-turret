-- prototypes/vfx/waves.lua ---------------------------------------------------------
-- The shockwave: per selectable yield, the wave darts and the detonation tree,
-- exported as `M.variants[tag]` for prototypes/vfx/carriers.lua. A detonation is
-- data-stage only, so each yield is its own tree (~100 hidden prototypes).
-- No ring entity: an `area` trigger (target_entities = false) throws a dart at
-- each of repeat_count random points, and each dart stamps explosions along its
-- flight. lib/blast.lua enforces target_entities = false and repeat_count on the
-- trigger item. MUST NOT squash Y: the ground plane is square (C.blast.iso_y).
--------------------------------------------------------------------------------------

local C     = require("config")
local N     = require("lib.names")
local blast = require("lib.blast")

local b = C.blast
local d = b.damage
local s = b.stages

local M = {}

-- ===========================================================================
-- Scaling
-- ===========================================================================

--- The three multipliers one yield step applies to everything below.
-- MOVED TO config.C.yield_factors in 0.13.0, so the flash light generated in
-- prototypes/vfx/explosions.lua scales on the same curve as the blast it lights.
local factors = C.yield_factors

--- Dart counts are repeat_count: an integer, and never zero.
local function count(n, k)
  return math.max(1, math.floor(n * k.cnt + 0.5))
end

-- ===========================================================================
-- One complete detonation, at one yield
-- ===========================================================================

-- The seven darts. `kind` becomes part of the prototype name; `damage` is the
-- full-yield value that gets scaled per variant.
local dart_kinds = {
  {kind = "core",      spawns = N.ex_fireball,  damage = d.dart_core},
  {kind = "main",      spawns = N.ex_shockwave, damage = d.dart_main},
  {kind = "cluster",   spawns = N.ex_cluster,   damage = d.dart_cluster},
  {kind = "dust",      spawns = N.ex_shockwave, damage = d.dart_dust},
  {kind = "over",      spawns = N.ex_shockwave, damage = d.dart_over},
  {kind = "reflected", spawns = N.ex_shockwave, damage = d.dart_reflect},
}

--- Build every prototype for one yield step and return its detonation effects.
-- Everything that positions or sizes anything is a closure over `k`, so there is
-- no way to add an effect later and forget to scale it -- the scaled value is
-- the only one in scope.
-- @param fraction number  the yield step, e.g. 0.25
-- @return table   a flat target_effects list
local function build(fraction)
  local tag = N.yield_tag(fraction)
  local k   = factors(fraction)

  -- The builder accumulates the delayed-active-trigger prototypes that staging
  -- requires. DelayedTriggerDelivery does not take a tick count -- it names a
  -- prototype that carries the delay AND the action -- so those have to be
  -- generated and extended. Forgetting the data:extend at the bottom is a load
  -- error, not a silent no-op. Namespaced per yield so two variants cannot
  -- collide on a generated name.
  local builder = blast.new(N.strike .. "-" .. tag)

  -- ---- 1. WAVE PROJECTILES -----------------------------------------------
  local projectiles = {}
  for _, w in ipairs(dart_kinds) do
    projectiles[#projectiles + 1] = blast.wave_projectile{
      name   = N.wave_at(tag, w.kind),
      spawns = w.spawns,
      damage = w.damage * k.dmg,
      -- How far the stamped explosion trails the dart.
      max_distance = b.wave_max_distance * k.rad,
      max_distance_deviation = b.wave_max_distance_deviation * k.rad,
      -- Falloff is measured from ground zero, so it shrinks with the blast or
      -- a quarter-size detonation does full damage everywhere inside itself.
      dart_radius  = d.dart_radius * k.rad,
      falloff_near = d.falloff_near * k.rad,
      falloff_far  = d.falloff_far * k.rad,
    }
  end

  -- The smoke fan throws smoke rather than explosions, so it gets an explicit
  -- effects list instead of the default create-explosion.
  projectiles[#projectiles + 1] = blast.wave_projectile{
    name = N.wave_at(tag, "smoke"),
    effects = {
      {
        type = "create-trivial-smoke",
        smoke_name = N.smoke_smoulder,
        offset_deviation = {{-2 * k.rad, -2 * k.rad}, {2 * k.rad, 2 * k.rad}},
        speed_from_center = 0.02,
        max_radius = 4 * k.rad,
        repeat_count = count(3, k),
      },
    },
  }

  data:extend(projectiles)

  -- ---- 2. THE DETONATION -------------------------------------------------

  --- Append every non-nil argument to a list.
  --
  -- EXISTS BECAUSE fan() CAN NOW RETURN NIL. A Lua table literal containing nils
  -- has holes, and `#` on a table with holes is undefined -- so
  -- `{fan("main"), fan("cluster"), damage_at(...), scar[1]}` with the fans
  -- omitted is not a three-element list, it is a coin flip. Building by append
  -- is the only version of this that is correct rather than usually correct.
  local function push(list, ...)
    for i = 1, select("#", ...) do
      local v = select(i, ...)
      if v ~= nil then list[#list + 1] = v end
    end
    return list
  end

  --- A fan straight from C.blast.fans, scaled to this yield.
  -- Returns NIL when the fans are off (C.blast.fans_enabled), so the caller drops
  -- the effect rather than emitting a token one. See the note in config: a
  -- collapsed fan still flies, and a flying dart still lays a trail of smoke.
  local function fan(key, kind)
    if not b.fans_enabled then return nil end
    local f = b.fans[key]
    assert(f, "no fan named '" .. tostring(key) .. "' in config.blast.fans")
    return blast.fan{
      projectile = N.wave_at(tag, kind),
      count  = count(f.count, k),
      radius = f.radius * k.rad,
      -- Speed is deliberately NOT scaled. The front moves at the same pace; a
      -- smaller blast simply stops sooner, which is what a smaller blast does.
      speed  = f.speed,
    }
  end

  --- Damage in a radius. Two types, because biters resist them differently and
  --- physical alone leaves armoured nests standing.
  local function damage_at(radius, amount)
    -- Falloff across the circle's own radius: full value at the centre,
    -- d.centre_falloff at the rim. A flat circle reads as a hard edge -- things
    -- one tile apart either evaporate or are untouched.
    local r = radius * k.rad
    local function mk(fraction_of, kind)
      return {
        type = "damage",
        vaporize = false,
        lower_distance_threshold = d.falloff_near * k.rad,
        upper_distance_threshold = r,
        lower_damage_modifier = 1,
        upper_damage_modifier = d.centre_falloff,
        damage = {amount = amount * k.dmg * fraction_of, type = kind},
      }
    end
    return blast.damage{
      radius = r,
      effects = {mk(0.4, "physical"), mk(0.6, "explosion")},
    }
  end

  --- Seed the crater with fallout patches (#99).
  local function fallout()
    return {
      type = "nested-result",
      action = {
        type = "area",
        target_entities = false,
        trigger_from_target = true,
        show_in_tooltip = false,
        repeat_count = count(b.fallout.count, k),
        radius = b.fallout.radius * k.rad,
        action_delivery = {
          type = "instant",
          target_effects = {
            {
              type = "create-fire",
              entity_name = N.fallout,
              check_buildability = true,
              initial_ground_flame_count = 1,
            },
          },
        },
      },
    }
  end

  --- #99b: seed the toxic clouds. Separate from fallout() because these are the
  --- part that actually damages -- the embers are decoration.
  local function fallout_cloud()
    return {
      type = "nested-result",
      action = {
        type = "area",
        target_entities = false,
        trigger_from_target = true,
        show_in_tooltip = false,
        repeat_count = count(b.fallout.cloud_count, k),
        radius = b.fallout.cloud_spread * k.rad,
        action_delivery = {
          type = "instant",
          target_effects = {
            {
              type = "create-entity",
              entity_name = N.fallout_cloud,
              check_buildability = false,
            },
          },
        },
      },
    }
  end

  --- Scatter the long-burning smoulder sources (#92 tail).
  local function smoulder()
    return {
      type = "nested-result",
      action = {
        type = "area",
        target_entities = false,
        trigger_from_target = true,
        show_in_tooltip = false,
        repeat_count = count(14, k),
        radius = 20 * k.rad,
        action_delivery = {
          type = "instant",
          target_effects = {
            {
              type = "create-entity",
              entity_name = N.smoke_source,
              tile_collision_mask = {layers = {water_tile = true}},
            },
          },
        },
      },
    }
  end

  --- The mushroom column: the cap explosion plus the standing stem (#91, #92, #93).
  local function mushroom()
    local m = b.mushroom
    return {
      {type = "create-entity", entity_name = N.ex_cap},
      {
        type = "create-trivial-smoke",
        smoke_name = N.smoke_stem,
        offset_deviation = {{-3 * k.rad, -3 * k.rad}, {3 * k.rad, 3 * k.rad}},
        speed_from_center = 0.005,
        max_radius = 5 * k.rad,
        initial_height = 0,
        repeat_count = count(m.stem_count, k),
      },
      {
        type = "create-trivial-smoke",
        smoke_name = N.smoke_cap,
        offset_deviation = {{-10 * k.rad, -10 * k.rad}, {10 * k.rad, 10 * k.rad}},
        speed_from_center = 0.02,
        max_radius = 16 * k.rad,
        initial_height = 2.5,
        repeat_count = count(m.cap_count, k),
      },
    }
  end

  -- Terrain scarring off the blast radius itself, not k.rad (a visual multiplier). A zero radius omits
  -- an effect: with C.blast.scar.instant off, scripts/crater.lua lays tiles, cliffs and decoratives behind the front.
  local blast_r = C.yield.radius(fraction * C.charge.cost_per_shot)
  local instant = b.scar.instant
  local scar = blast.scar{
    tile_radius       = instant and math.min(blast_r * b.scar.tile_fraction,
                                             b.scar.max_tile_radius) or 0,
    decorative_radius = instant and math.min(blast_r * b.scar.decorative_fraction,
                                             b.scar.max_decorative_radius) or 0,
    cliff_radius      = instant and math.min(blast_r * b.scar.cliff_fraction,
                                             b.scar.max_cliff_radius) or 0,
  }

  -- -------------------------------------------------------------------------
  -- #90: the staging. Vanilla fires every fan on the same tick, which is why it
  -- reads as one bang. Spread across ~2 seconds it reads as an event.
  --
  --   flash        light + camera + chart, instantly
  --   overpressure the tight fast ring
  --   fireball     the core
  --   shockwave    the main wave + cluster detonations + terrain scarring
  --   mushroom     the cap starts climbing once the wave has left
  --   dust         the enormous slow outer ring
  --   boom         #97: thunder, long after the light
  --   smoulder     the long burn and the fallout field
  --
  -- The DELAYS are not scaled. They are the shape of the event, and a quarter
  -- yield is a smaller explosion, not a faster one.
  -- -------------------------------------------------------------------------
  -- ---- 3. THE EVENT ------------------------------------------------------
  --
  -- Two shapes, chosen by C.blast.style. The RELEASE is shared -- both end with
  -- the same flash, the same fans, the same crater -- and what differs is what
  -- comes before it and what is left behind after.
  --
  --   "atomic"     release, then a mushroom column, a smoulder and a fallout
  --                field. A bomb.
  --   "implosion"  a gather first: a shell of glow converging onto a point that
  --                brightens, a held beat, and then the release -- with the
  --                column, the smoulder and the fallout dropped, because a
  --                rising fire column and lingering contamination are the two
  --                things that say "nuclear" no matter what colour the rest of
  --                it is.
  --
  -- THE GATHER IS NO LONGER BUILT HERE. It moved to the control stage
  -- (scripts/implode.lua) because every one of its four defects was a trigger
  -- tree not knowing a number until runtime -- the real circumference of the
  -- shell, the real radius the charging sphere reached, an arbitrary radius law.
  -- See the header of C.blast.implosion for the measurements.
  --
  -- WHAT STAYS HERE IS THE OFFSET. The release must not fire until the collapse
  -- has finished, and that duration is now per yield, so `shift` is a function
  -- of the fraction this variant is being built for. scripts/detonate.lua delays
  -- the damage sweep by the SAME call -- two numbers that must agree to the
  -- tick, one owner.
  local imp     = b.implosion
  local implode = (b.style == "implosion")
  local shift   = implode and imp.total_ticks_for(fraction) or 0

  local stages = {}

  --- A release stage. Offset by the gather so the two phases cannot overlap.
  local function stage(delay, fx)
    stages[#stages + 1] = {delay = delay + shift, effects = fx}
  end

  -- THE GATHER, tick 0 .. shift: nothing here fills it. scripts/implode.lua draws
  -- the converging shell, the sphere's collapse and the infall streaks.

  -- THE PRE-SHAKE: the ground moves before the light arrives. Timed from the
  -- release, not the gather, so it stays on the flash at every yield.
  if implode and b.camera.pre_shake_ticks > 0 then
    stages[#stages + 1] = {
      delay = math.max(0, shift - b.camera.pre_shake_ticks),
      effects = {blast.camera{
        strength = b.camera.pre_shake_strength * k.dmg,
        duration = b.camera.pre_shake_ticks,
        ease_in_duration = b.camera.pre_shake_ticks,
        ease_out_duration = 0,
        full_strength_max_distance = b.camera.full_strength_max_distance * k.rad,
        max_distance = b.camera.max_distance,
      }},
    }
  end

  -- ---- THE RELEASE (both styles) -----------------------------------------
  stage(s.flash, {
      -- PER YIELD STEP. One flash prototype lit a 5% shot exactly as
      -- hard as a 150% one, because a prototype's `light` is baked at load
      -- time. prototypes/vfx/explosions.lua bakes one pair per step instead,
      -- and `fraction` is what picks this shot's pair.
      {type = "create-entity", entity_name = N.ex_flash_for(fraction)},
      -- #98b: the long white, fired on the same tick as the pop.
      {type = "create-entity", entity_name = N.ex_flash_sustain_for(fraction)},
      blast.camera{
        strength = b.camera.strength * k.dmg,
        duration = b.camera.duration,
        ease_in_duration = b.camera.ease_in_duration,
        ease_out_duration = b.camera.ease_out_duration,
        full_strength_max_distance = b.camera.full_strength_max_distance * k.rad,
        max_distance = b.camera.max_distance,
      },
      blast.chart(b.chart_scale * k.rad),
      damage_at(d.ground_zero_radius, d.ground_zero),
  })

  -- #89: a fast, tight overpressure ring vanilla does not have.
  stage(s.overpressure, push({},
      fan("over", "over"),
      fan("inner", "core")))

  -- The fireball fan is the FIRE, and fire is the other thing that says bomb.
  -- The implosion keeps the tight inner fan and drops it.
  stage(s.fireball, implode
      and push({}, fan("core", "core"))
      or  push({}, fan("fireball", "core"), fan("core", "core")))

  -- THE FOG ARTEFACTS. The smoke fan throws 400 darts that each stamp a
  -- trivial-smoke cloud wherever they stop -- and the darts scatter to the FAN's
  -- radius while the crater is drawn at ground zero's, so they land as isolated
  -- tan puffs sitting well outside the blast with nothing between them and it.
  -- Reported exactly that way. It is also smoke, which is on the list of things
  -- that say "bomb", so the implosion has none of it.
  --
  -- Built as a list and appended to, NOT `implode and nil or fan(...)`: in Lua
  -- `x and nil or y` is always y, because `and nil` is falsy. That idiom cannot
  -- conditionally omit a table element and would have silently kept the smoke.
  -- THE MIXED STAGE, and the one that made push() necessary: the fans here sit
  -- in the same list as the damage circle and the four scar effects, so omitting
  -- them from a table literal would leave holes in front of elements that matter.
  local shockwave_fx = push({},
      fan("main", "main"),
      fan("cluster", "cluster"),
      damage_at(d.wave_radius, d.wave),
      -- #95: permanent terrain scarring. blast.scar returns a LIST, so it is
      -- unpacked into this stage rather than nested. Kept for BOTH styles: an
      -- implosion absolutely scars ground, it just does not irradiate it.
      scar[1], scar[2], scar[3], scar[4],
      -- The scorch decal is sized for this yield: one prototype per step, by tag.
      {type = "create-entity",
       entity_name = b.scar.decal_enabled and N.ex_scorch_for(fraction)
                     or N.base.scorchmark_huge,
       check_buildability = true})
  if not implode then
    push(shockwave_fx, fan("smoke", "smoke"))
  end
  stage(s.shockwave, shockwave_fx)

  -- #89: the enormous slow dust ring, and the wave that comes back inward.
  stage(s.dust, push({}, fan("dust", "dust")))
  stage(s.dust + 30, push({}, fan("reflect", "reflected")))

  -- #96: the SECOND camera shake, timed to the wave's arrival, so a distant
  -- player feels it land after they saw the flash.
  stage(b.camera.arrival_delay, {
      blast.camera{
        strength = b.camera.arrival_strength * k.dmg,
        duration = b.camera.arrival_duration,
        full_strength_max_distance = b.camera.max_distance,
        max_distance = b.camera.max_distance,
      },
  })

  -- #97: thunder.
  stage(s.boom, {{type = "create-entity", entity_name = N.ex_boom}})

  -- ---- THE ATOMIC TAIL ---------------------------------------------------
  -- The column, the burn and the contamination. These are the three that make
  -- the event read as a nuclear weapon rather than a very large release of
  -- energy, so the implosion has none of them.
  if not implode then
    stage(s.mushroom, mushroom())
    stage(s.smoulder, {fallout(), smoulder()})
    -- #99b: the fallout cloud, timed to be inside the black wave rather than
    -- ahead of it.
    stage(s.fallout, {fallout_cloud()})
  end

  local effects = builder:detonation{stages = stages}

  -- The delayed-active-trigger prototypes the staging above generated. Without
  -- this the delayed_trigger names resolve to nothing and the mod fails to load.
  data:extend(builder:prototypes())

  return effects
end

-- ===========================================================================
-- Every variant the yield selector can ask for
-- ===========================================================================

-- [tag] = target_effects list. Keyed by the same tag the carrier name uses, so
-- prototypes/vfx/carriers.lua and scripts/impact.lua cannot disagree about
-- which detonation belongs to which percentage.
M.variants = {}

for _, step in ipairs(C.charge.yield_targets) do
  M.variants[N.yield_tag(step.fraction)] = build(step.fraction)
end

-- The standard shot, for anything that wants "a detonation" without choosing.
-- Falls back to the largest built variant if 100% is ever removed from the
-- selector, so this is never nil.
M.detonation = M.variants[N.yield_tag(C.charge.yield_default)]
  or M.variants[N.yield_tag(C.charge.yield_targets[#C.charge.yield_targets].fraction)]

return M
