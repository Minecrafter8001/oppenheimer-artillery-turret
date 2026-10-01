-- lib/blast.lua: Parametric detonation builder for trigger prototypes.

local C = require("config")

local blast = {}

-- =============================================================================
-- Builder
-- =============================================================================

local Builder = {}
Builder.__index = Builder

--- Create a detonation builder.
-- @param namespace string prefix for any prototype this builder has to invent.
--        Must be unique per detonation so two builders cannot collide.
function blast.new(namespace)
  assert(type(namespace) == "string" and namespace ~= "",
         "blast.new needs a namespace string")
  return setmetatable({
    namespace = namespace,
    generated = {},
    counter   = 0,
  }, Builder)
end

--- Every prototype this builder invented. Feed to data:extend.
function Builder:prototypes()
  return self.generated
end

function Builder:_name(kind)
  self.counter = self.counter + 1
  return string.format("%s-%s-%d", self.namespace, kind, self.counter)
end

-- =============================================================================
-- Wave projectiles -- the invisible darts a fan throws
-- =============================================================================

--- Build the projectile prototype that a fan throws.
-- Returns a prototype table; extend it yourself, or let detonation() do it.
-- @param o.name          string  prototype name
-- @param o.spawns        string  explosion entity laid down along the flight
-- @param o.max_distance  number  how far the spawned explosion may travel
-- @param o.effects       table   OPTIONAL: replace the default create-explosion
--                                with an arbitrary target_effects list
-- @param o.dart_radius      number OPTIONAL: area radius the dart damages
-- @param o.falloff_near     number OPTIONAL: full damage inside this, from GZ
-- @param o.falloff_far      number OPTIONAL: minimum damage beyond this, from GZ
-- @param o.falloff_far_mult number OPTIONAL: the multiplier at falloff_far
--        The four overrides exist for the yield variants (#83): a scaled-down
--        blast needs scaled-down falloff, or it is only smaller on paper.
function blast.wave_projectile(o)
  assert(o.name, "wave_projectile needs a name")
  assert(o.spawns or o.effects, "wave_projectile needs spawns or effects")

  local effects = o.effects
  if not effects then
    effects = {
      {
        type = "create-explosion",
        entity_name = o.spawns,
        max_movement_distance = o.max_distance or C.blast.wave_max_distance,
        max_movement_distance_deviation =
          o.max_distance_deviation or C.blast.wave_max_distance_deviation,
        -- The two fields that make the explosion trail the dart instead of
        -- appearing once at the end.
        inherit_movement_distance_from_projectile = true,
        cycle_while_moving = true,
      },
    }
  end

  -- INVARIANT 4: a dart that is meant to hurt must carry an `area` DAMAGE
  -- trigger of its own. `create-explosion` spawns a visual entity and nothing
  -- more -- explosions in Factorio do not damage anything. Vanilla's
  -- atomic-bomb-wave rides a radius-3 area damage trigger along with every dart,
  -- with falloff keyed to distance from ground zero, and that -- not the
  -- explosions -- is where a nuke's spreading damage comes from.
  local action = {
    {
      type = "direct",
      action_delivery = {
        type = "instant",
        target_effects = effects,
      },
    },
  }

  if o.damage and o.damage > 0 then
    local d = C.blast.damage
    -- The falloff thresholds are distances from GROUND ZERO, so a yield variant
    -- that shrinks the fan radius has to shrink these with it -- otherwise every
    -- dart in a quarter-size blast sits inside `falloff_near` and lands at full
    -- damage, and the small shot hits as hard as the big one over less ground.
    action[#action + 1] = {
      type = "area",
      radius = o.dart_radius or d.dart_radius,
      -- Terrain must not shield the blast front.
      ignore_collision_condition = true,
      show_in_tooltip = false,
      action_delivery = {
        type = "instant",
        target_effects = {
          {
            type = "damage",
            vaporize = false,
            -- Falloff is measured from GROUND ZERO, not from the dart, so one
            -- dart prototype is lethal near the centre and a scratch at the rim.
            lower_distance_threshold = o.falloff_near or d.falloff_near,
            upper_distance_threshold = o.falloff_far  or d.falloff_far,
            lower_damage_modifier = 1,
            upper_damage_modifier = o.falloff_far_mult or d.falloff_far_mult,
            damage = {amount = o.damage, type = "explosion"},
          },
        },
      },
    }
  end

  return {
    type  = "projectile",
    name  = o.name,
    flags = {"not-on-map"},
    hidden = true,
    acceleration = 0,
    -- C.blast.iso_y is 1.0 -- there is no isometric projection in Factorio, so
    -- the darts fly in a plain circle. Read from config rather than hardcoded
    -- {1, 1} only so a future ground-plane correction has one place to land.
    speed_modifier = {1, o.iso_y or C.blast.iso_y},
    action = action,
    animation = nil,
    shadow = nil,
  }
end

-- =============================================================================
-- Fans -- the shotgun blast of darts
-- =============================================================================

--- One fan: `count` darts thrown outward to random points within `radius`.
-- Returns a single TriggerEffect (nested-result) ready to drop into a
-- target_effects list.
-- @param o.projectile string  name of the wave projectile to throw
-- @param o.count      number  dart count (this is repeat_count)
-- @param o.radius     number  scatter radius
-- @param o.speed      number  tiles/tick
function blast.fan(o)
  assert(o.projectile, "fan needs a projectile")
  assert(o.count and o.count > 0, "fan needs a positive count")
  assert(o.radius and o.radius > 0, "fan needs a positive radius")

  return {
    type = "nested-result",
    action = {
      type = "area",
      -- INVARIANT 2: pick raw points, not entities. The whole effect hangs here.
      target_entities = false,
      trigger_from_target = true,
      show_in_tooltip = o.show_in_tooltip or false,
      -- INVARIANT 3: dart count lives on the TriggerItem.
      repeat_count = o.count,
      radius = o.radius,
      action_delivery = {
        type = "projectile",
        projectile = o.projectile,
        starting_speed = o.speed,
        starting_speed_deviation = o.speed_deviation or C.blast.speed_deviation,
      },
    },
  }
end

-- =============================================================================
-- Staging -- delayed deliveries
-- =============================================================================

--- Wrap a list of effects so they fire `delay` ticks later.
-- Generates the delayed-active-trigger prototype this requires and stashes it
-- on the builder; call :prototypes() and data:extend the result.
-- @param delay   number ticks, must be > 0
-- @param effects table  list of TriggerEffect
function Builder:delayed(delay, effects)
  assert(type(delay) == "number" and delay > 0,
         "delayed() needs a delay > 0 (the prototype rejects 0)")
  assert(type(effects) == "table" and #effects > 0,
         "delayed() needs a non-empty effects list")

  local name = self:_name("delay" .. tostring(delay))

  self.generated[#self.generated + 1] = {
    type  = "delayed-active-trigger",
    name  = name,
    delay = delay,
    action = {
      type = "direct",
      action_delivery = {
        type = "instant",
        target_effects = effects,
      },
    },
  }

  -- The effect that actually references it.
  return {
    type = "nested-result",
    action = {
      type = "direct",
      action_delivery = {
        type = "delayed",
        delayed_trigger = name,
      },
    },
  }
end

--- Compose a full detonation from staged groups of effects.
-- @param o.stages array of { delay = ticks, effects = { TriggerEffect, ... } }
--        delay 0 (or absent) fires immediately; anything else is wrapped.
-- Returns a flat target_effects list.
function Builder:detonation(o)
  assert(o and o.stages, "detonation needs a stages list")
  local out = {}
  for _, stage in ipairs(o.stages) do
    local effects = stage.effects or {}
    if #effects == 0 then
      -- nothing to do
    elseif not stage.delay or stage.delay == 0 then
      for _, e in ipairs(effects) do out[#out + 1] = e end
    else
      out[#out + 1] = self:delayed(stage.delay, effects)
    end
  end
  return out
end

-- =============================================================================
-- Flat ground-zero effects -- thin, documented wrappers
-- These exist so config numbers reach the right field names, and so the field
-- sets stay in one place when the API is the only source of truth for them.
-- =============================================================================

--- Area damage at ground zero.
function blast.damage(o)
  return {
    type = "nested-result",
    action = {
      type = "area",
      radius = o.radius,
      -- A hill or a wall must not put a biter in cover from a nuclear blast.
      ignore_collision_condition = true,
      action_delivery = {
        type = "instant",
        target_effects = o.effects,
      },
    },
  }
end

--- Screen shake. `duration` is NOT optional on CameraEffectTriggerEffectItem.
function blast.camera(o)
  o = o or {}
  local c = C.blast.camera
  return {
    type = "camera-effect",
    duration = o.duration or 60,
    ease_in_duration = o.ease_in_duration or c.ease_in_duration,
    ease_out_duration = o.ease_out_duration or 0,
    delay = o.delay or 0,
    strength = o.strength or c.strength,
    full_strength_max_distance = o.full_strength_max_distance
      or c.full_strength_max_distance,
    max_distance = o.max_distance or c.max_distance,
  }
end

--- Which tile the crater is paved with, resolved ONCE at the data stage.
--
-- Space Age's volcanic-folds -- cracked, folded black rock -- is what the crater
-- should look like, and it is also OPTIONAL: this mod does not require Space Age
-- and a `set-tile` naming a tile that does not exist is a hard load error, not a
-- missing texture. So the preferred name is checked against data.raw and the
-- vanilla nuclear ground is the fallback.
--
-- data.raw is only readable in the data stage, which is where every caller of
-- this function runs. Do not move this to the control stage.
local function scar_tile()
  local N = require("lib.names")
  local want = C.blast.scar.tile_name
  if want and data and data.raw and data.raw.tile and data.raw.tile[want] then
    return want
  end
  return N.base.nuclear_ground
end

blast.scar_tile = scar_tile

--- Permanent terrain scarring at [1] tiles, [2] cliffs, [3] decoratives, [4] the tile trigger. An effect with radius 0 is left nil.
function blast.scar(o)
  o = o or {}
  local s = C.blast.scar
  local tr = o.tile_radius or s.tile_radius
  local cr = o.cliff_radius or s.cliff_radius
  local dr = o.decorative_radius or s.decorative_radius
  local out = {}
  if tr > 0 then
    out[1] = {
      type = "set-tile",
      tile_name = o.tile_name or scar_tile(),
      radius = tr,
      -- The spec ships no description for apply_projection: unverified, so no transform is asked for.
      apply_projection = s.apply_projection,
      tile_collision_mask = {layers = {water_tile = true}},
    }
  end
  if cr > 0 then
    out[2] = {
      type = "destroy-cliffs",
      radius = cr,
      explosion_at_cliff = o.cliff_explosion,
    }
  end
  if dr > 0 then
    out[3] = {
      type = "destroy-decoratives",
      radius = dr,
      from_render_layer = "decorative",
      to_render_layer = "object",
      include_soft_decoratives = true,
      include_decals = false,
      invoke_decorative_trigger = true,
      decoratives_with_trigger_only = false,
    }
  end
  out[4] = {
    type = "invoke-tile-trigger",
    repeat_count = 1,
  }
  return out
end

--- Map-view bloom.
function blast.chart(scale)
  return {type = "show-explosion-on-chart", scale = scale or 1}
end

--- Call into control.lua from a data-stage detonation.
-- ScriptTriggerEffectItem raises on_script_trigger_effect with source_position,
-- target_position, source_entity, target_entity, cause_entity, surface_index.
-- Base game never uses this, which is why it looks unavailable if you only read
-- base source -- but it is in the 2.0.77 spec.
function blast.script_fx(effect_id)
  assert(type(effect_id) == "string", "script_fx needs an effect_id string")
  return {type = "script", effect_id = effect_id}
end

return blast
