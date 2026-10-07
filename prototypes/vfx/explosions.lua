-- prototypes/vfx/explosions.lua ---------------------------------------------------
-- The explosion entities a shockwave dart stamps along its flight path, plus the
-- mushroom cloud, the flash, the distant boom and the fallout field.
-- Backlog #86, #91, #94, #97, #98, #99.
--
-- Read "How the vanilla nuke actually works" in IDEAS.md first. The short
-- version: none of these is "the explosion". Each is one small puff, and a fan
-- of a thousand outward-flying darts stamps thousands of them along their
-- flight paths. The visible expanding ring is emergent -- every dart launched on
-- the same tick at the same speed, so the collective front reads as a wave.
--
-- #91, THE MUSHROOM CLOUD -- corrected assessment. The earlier read was that
-- Factorio has no rising cloud and this would need a scripted stack of entities
-- on staggered delays. Both halves of that were wrong:
--   * base already ships the art -- nuke-explosion-1..4.png, 100 frames of a
--     rising, spreading mushroom (see prototypes/vfx/anims.lua)
--   * ExplosionPrototype grows on its own. Confirmed via
--     `apiq proto ExplosionPrototype`: height, scale_initial, scale_end,
--     scale_increment_per_tick, scale_in_duration, scale_out_duration.
-- So the cap is ONE prototype whose growth fields stack on top of an animation
-- that is already a mushroom cloud.
--------------------------------------------------------------------------------------

local C     = require("config")
local N     = require("lib.names")
local anims = require("prototypes.vfx.anims")

local util = require("util")

local m = C.blast.mushroom

-- =============================================================================
-- THE FLASH PAIR, GENERATED PER YIELD STEP. See the note at its call site.
-- =============================================================================
local function flash_pair()
  local f = C.blast.flash
  local out = {}
  for _, step in ipairs(C.charge.yield_targets) do
    local k = C.yield_factors(step.fraction)
    -- 0..1 for a brightness, so the top of the band does not ask for 150% of a
    -- light that is already at full intensity.
    local lit = f.intensity_floor
                + (1 - f.intensity_floor) * math.min(1, k.unit)

    out[#out + 1] = {
      type = "explosion",
      name = N.ex_flash_for(step.fraction),
      flags = {"not-on-map"},
      hidden = true,
      subgroup = "explosions",
      order = "z[oppenheimer]-d",
      height = 0,
      -- A light and a camera shake only: the sprite is scaled to nothing, and
      -- N.ex_release carries the fireball, created from the control stage.
      -- HAZARD: keep the light capped; uncapped at full yield it is a
      -- radius-1440 full-screen fill every frame.
      scale = f.sprite,
      -- ⚠️ THE LENGTH IS LOAD-BEARING AND IS NOT A FREE CHOICE. An explosion's
      -- light lasts exactly as long as its animation, and every light curve
      -- field below is a FRACTION of it (peak_end = 0.15 of the clip). The old
      -- anims.big() ran 47 frames at animation_speed 0.5 = 94 ticks, so that
      -- is what this holds for -- swapping the artwork out must not silently
      -- shorten the flash to nothing.
      animations = anims.hold(f.ticks),
      light = {
        intensity = f.intensity * lit,
        size = math.min(f.size * k.rad, f.max_light_size),
        color = {r = 1.0, g = 0.96, b = 0.85},
      },
      light_intensity_factor_initial = 1.0,
      light_intensity_factor_final = 0.0,
      light_intensity_peak_start_progress = 0.0,
      light_intensity_peak_end_progress = f.peak_end,
      light_size_factor_initial = 1.0,
      light_size_factor_final = 0.2,
    }

    -- #98b: the SUSTAINED white. This entity is a light source, not artwork --
    -- the sprite is scaled to almost nothing on purpose. The initial flash above
    -- is a 1.6 s camera pop; this holds the sky white while the fans spread.
    out[#out + 1] = {
      type = "explosion",
      name = N.ex_flash_sustain_for(step.fraction),
      flags = {"not-on-map"},
      hidden = true,
      subgroup = "explosions",
      order = "z[oppenheimer]-e",
      height = 0,
      scale = f.sustain_sprite,
      -- The white also LASTS longer for a bigger device, which is most of what
      -- makes one read as bigger -- a brief bright flash and a long bright flash
      -- are different events even at the same peak intensity.
      animations = anims.hold(math.max(6,
        math.floor(f.sustain_ticks * math.min(1, k.unit) + 0.5))),
      -- The worse of the two: this one is HELD for up to eight seconds, so an
      -- uncapped 3120 tile light was not a flash that cost a frame, it was a
      -- sustained full-screen fill. This is the one that produced 15 FPS.
      light = {
        intensity = f.sustain_intensity * lit,
        size = math.min(f.sustain_size * k.rad, f.max_sustain_light_size),
        color = {r = 1.0, g = 1.0, b = 1.0},
      },
      light_intensity_factor_initial = 1.0,
      light_intensity_factor_final = 0.0,
      light_intensity_peak_start_progress = 0.0,
      light_intensity_peak_end_progress = f.sustain_peak_end,
      light_size_factor_initial = 1.0,
      light_size_factor_final = 0.65,
    }
  end
  return out
end

local f = C.blast.flash
local fo = C.blast.fallout
local sf = C.blast.scorch

data:extend({

  -- The mod's own flame (the arc sweep's wall of fire). MUST NOT spread or be
  -- fed: spread_delay, maximum_spread_count and lifetime_increase_by are three
  -- separate mechanisms, all off, so a fire never outlives its own lifetime.
  {
    type = "fire",
    name = N.scorch_flame,
    flags = {"placeable-off-grid", "not-on-map"},
    hidden = true,

    -- Cosmetic: the arc sweep's own kill pass does the killing.
    damage_per_tick = {amount = sf.damage_per_tick, type = sf.damage_type},
    maximum_damage_multiplier = 1,

    initial_lifetime           = sf.lifetime,
    maximum_lifetime           = sf.lifetime,
    lifetime_increase_by       = 0,
    lifetime_increase_cooldown = 0,

    -- A fire on a tree draws this prototype instead of `pictures`. MUST be ours:
    -- base's fire-flame-on-tree spreads (maximum_spread_count 100).
    spawn_entity = N.scorch_flame_tree,

    delay_between_initial_flames = 0,
    initial_flame_count          = 0,
    maximum_spread_count         = 0,
    spread_delay                 = 60 * 60 * 60,
    spread_delay_deviation       = 1,

    fade_in_duration  = sf.fade_in_duration,
    fade_out_duration = sf.fade_out_duration,
    flame_alpha           = 0.55,
    flame_alpha_deviation = 0.12,

    pictures = {
      {
        -- Geometry read from base fire.lua, not guessed -- the same four
        -- fire-flame-0N sheets N.fallout uses: 84x130, 90 frames, line_length
        -- 10. Only 01..04 exist; higher numbers are from an older version.
        filename = "__base__/graphics/entity/fire-flame/fire-flame-01.png",
        line_length = 10,
        width = 84,
        height = 130,
        frame_count = 90,
        blend_mode = "normal",
        animation_speed = 0.5,
        scale = sf.scale,
        tint = sf.tint,
        draw_as_glow = true,
        shift = util.by_pixel(0, -16),
      },
    },

    light = sf.light_enabled and sf.light or nil,

    smoke = {
      {
        name = N.base.nuclear_smoke,
        deviation = {0.4, 0.4},
        frequency = sf.smoke_frequency,
        position = {0.0, -0.8},
        starting_vertical_speed = 0.015,
        starting_frame_deviation = 60,
      },
    },
  },

  -- ===========================================================================
  -- #86: the shockwave puff. Stamped repeatedly along each dart's path by
  -- create-explosion with cycle_while_moving = true.
  -- ===========================================================================
  {
    type = "explosion",
    name = N.ex_shockwave,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-a",
    height = 0,
    animations = anims.shockwave(),
  },

  -- ---- THE SHOCK FRONT, ONE PER YIELD STEP -----------------------
  -- Generated below with data:extend, not here -- see the loop after this block.

  -- ---- #111: THE IMPLOSION GATHER ----------------------------------------
  -- Generated PER YIELD STEP by the loop at the bottom of this file, not here.
  -- an explosion's scale, its animation speed and its light are all
  -- baked at load time, and the gather needs all three to move with the yield.

  -- The fireball core. Grows as it burns so the front is not a flat stamp.
  {
    type = "explosion",
    name = N.ex_fireball,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-b",
    height = 0,
    -- Doubled. The impact flash was reading as small next to the column that
    -- grew out of it -- the bang should be the biggest thing on screen at the
    -- moment it lands, then the mushroom takes over.
    scale_initial = 1.7,
    scale_end = 4.6,
    scale_in_duration = 8,
    scale_out_duration = 24,
    animations = anims.big(),
  },

  -- Secondary detonations scattered through the blast radius.
  {
    type = "explosion",
    name = N.ex_cluster,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-c",
    height = 0,
    scale_initial = 0.6,
    scale_end = 1.6,
    scale_deviation = 0.35,
    animations = anims.medium(),
  },

  -- ===========================================================================
  -- #98 RESOLVED. The open question was "what do the light fields on
  -- ExplosionPrototype actually allow?" Answer, from the 2.0.77 spec: a full
  -- LightDefinition plus four curve controls --
  --   light_intensity_factor_initial / _final   (clamped 0..1)
  --   light_size_factor_initial / _final
  --   light_intensity_peak_start_progress / _end_progress
  -- which is exactly a flash: blow out to full intensity immediately, then fall
  -- to nothing across the animation.
  -- ===========================================================================

  -- ===========================================================================
  -- #91: the mushroom cap.
  -- ===========================================================================
  {
    type = "explosion",
    name = N.ex_cap,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-e",
    -- Factorio is 2D; `height` is a screen offset. Combined with the growth
    -- below and an animation that already climbs, it reads as a cap rising and
    -- spreading over the stem.
    height = m.height,
    scale = m.scale,
    scale_initial = m.scale_initial,
    scale_end = m.scale_end,
    scale_increment_per_tick = m.scale_increment_per_tick,
    scale_in_duration = m.scale_in_duration,
    scale_out_duration = m.scale_out_duration,
    -- FALSE. With this true the playback rate scales with the entity, and this
    -- cap grows to several times its authored size -- which stretched a 4.4 s
    -- animation into the small fire still hovering over the crater ten seconds
    -- later, visible right as the camera comes through the smoke.
    scale_animation_speed = false,
    animations = anims.mushroom(),
    sound = {
      aggregation = {max_count = 1, remove = true},
      variations = {
        {filename = "__base__/sound/fight/large-explosion-1.ogg", volume = 1.0},
        {filename = "__base__/sound/fight/large-explosion-2.ogg", volume = 1.0},
      },
      audible_distance_modifier = C.blast.sound.near_distance_modifier,
    },
  },

  -- ===========================================================================
  -- #94: the invisible carrier. An explosion with an empty sprite whose only
  -- job is to hold a created_effect.
  --
  -- This is not a hack -- it is exactly how base attaches the nuke's terrain
  -- scarring: `nuke-effects-nauvis` is an explosion with
  -- `animations = util.empty_sprite()` and a created_effect carrying set-tile.
  -- Using named carriers keeps the VFX chain readable instead of burying
  -- triggers three levels down a nested-result.
  -- ===========================================================================
  {
    type = "explosion",
    name = N.ex_carrier,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-f",
    height = 0,
    animations = util.empty_sprite(),
  },

  -- ===========================================================================
  -- #97: the distant boom. Flash first, thunder later -- the most convincing
  -- "that was enormous" cue available. Drawn as nothing; it exists only to
  -- carry a sound, and it is spawned from a delayed stage so it arrives after
  -- the light. audible_distance_modifier is what carries it across the map.
  --
  -- THIS IS THE NEAR-FIELD LAYER, and it is deliberately separate from the
  -- broadcast N.sound.boom scripts/detonate.lua's thunder() plays (see the
  -- header of prototypes/sound.lua): a world sound gives a nearby listener a
  -- real position and stereo image the broadcast cannot, and it is inaudible
  -- from the map/zoomed out regardless, so there is nothing to duplicate for a
  -- distant observer.
  --
  -- FILENAME MATCHES THE BROADCAST NOW (was __base__/large-explosion-
  -- 1.ogg -- the stock sound the broadcast layer was already fixed away from
  -- in 0.21.0, missed here, and reported as "still an explosion sound playing
  -- after the new one"). Volume is C.sound.boom_volume_floor, not a flat
  -- constant, so this layer is pinned to the QUIETEST the broadcast layer ever
  -- gets rather than an arbitrary number picked for a different file. It does
  -- NOT climb with yield the way the broadcast does -- an embedded explosion
  -- `sound` is baked at data-stage load with no runtime hook to scale it, the
  -- same wall the broadcast layer hit on duration -- so a near listener's
  -- growth with yield comes entirely from the broadcast half stacking louder
  -- on top of this fixed floor, not from this layer growing too. If that ever
  -- needs to be exact rather than close, the fix is building one variant of
  -- this prototype per C.charge.yield_targets step, the way the flash and the
  -- scorch decal already are -- not done here; this only fixes the file and
  -- the loudness floor that were actually reported.
  {
    type = "explosion",
    name = N.ex_boom,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-g",
    height = 0,
    animations = util.empty_sprite(),
    sound = {
      aggregation = {max_count = 1, remove = true},
      variations = {
        {filename = "__oppenheimer-artillery-turret-forked__/sound/ImplosionBoom.ogg",
         volume = C.sound.boom_volume_floor},
      },
      audible_distance_modifier = C.blast.sound.far_distance_modifier,
    },
  },

  -- ===========================================================================
  -- #99: the fallout zone. The crater stays lethal for minutes -- to biters,
  -- and to you.
  --
  -- A `fire` prototype is the right shape: it already has a lifetime, per-tick
  -- damage, fade in/out and smoke attachment. It is deliberately configured NOT
  -- to spread -- spread_delay is set past any realistic lifetime -- so it sits
  -- in the crater and decays rather than burning across the map.
  -- ===========================================================================
  -- ===========================================================================
  -- #99b: the toxic cloud. THIS is the fallout that does something.
  --
  -- smoke-with-trigger is the right prototype and it is what vanilla's
  -- poison-cloud uses: ONE entity that re-applies an area damage trigger on a
  -- cooldown for its whole lifetime. It covers real ground, unlike a fire
  -- entity, and five of them cost far less than the forty fires they replace.
  -- ===========================================================================
  {
    type = "smoke-with-trigger",
    name = N.fallout_cloud,
    flags = {"not-on-map", "placeable-off-grid"},
    hidden = true,

    duration = fo.lifetime,
    fade_away_duration = 3 * 60,
    spread_duration = 20,
    cyclic = true,
    -- Sooty, not lime green. This is fallout riding inside the black column,
    -- not a poison capsule -- a green blob beside a nuclear cloud reads as a
    -- different mod's effect entirely.
    color = {r = 0.30, g = 0.26, b = 0.19, a = 0.72},

    animation = {
      filename = "__base__/graphics/entity/smoke/smoke.png",
      width = 152,
      height = 120,
      line_length = 5,
      frame_count = 60,
      shift = {-0.53125, -0.4375},
      priority = "high",
      animation_speed = 0.25,
      scale = fo.cloud_scale,
      flags = {"smoke"},
    },

    action = {
      type = "direct",
      action_delivery = {
        type = "instant",
        target_effects = {
          type = "nested-result",
          action = {
            type = "area",
            radius = fo.cloud_radius,
            -- Only things that breathe. Fallout should choke biters, not gnaw
            -- on the player's own walls.
            entity_flags = {"breaths-air"},
            action_delivery = {
              type = "instant",
              target_effects = {
                type = "damage",
                damage = {amount = fo.damage_cloud, type = "poison"},
              },
            },
          },
        },
      },
    },
    action_cooldown = fo.action_cooldown,
  },

  {
    type = "fire",
    name = N.fallout,
    flags = {"placeable-off-grid", "not-on-map"},
    hidden = true,

    damage_per_tick = {amount = fo.damage_per_tick, type = "poison"},
    maximum_damage_multiplier = 1,

    initial_lifetime = fo.lifetime,
    maximum_lifetime = fo.lifetime,
    lifetime_increase_by = 0,
    lifetime_increase_cooldown = 0,

    -- Does not spread. See note above.
    delay_between_initial_flames = 0,
    spread_delay = 60 * 60 * 60,
    spread_delay_deviation = 1,

    fade_in_duration = 60,
    fade_out_duration = 180,
    flame_alpha = 0.35,
    flame_alpha_deviation = 0.1,

    pictures = {
      {
        -- Geometry read from base fire.lua (the fire-sticker animation), not
        -- guessed: fire-flame-01 is 84x130, 90 frames, line_length 10. Only
        -- fire-flame-01..04 exist -- higher numbers are from an older version.
        filename = "__base__/graphics/entity/fire-flame/fire-flame-01.png",
        line_length = 10,
        width = 84,
        height = 130,
        frame_count = 90,
        blend_mode = "normal",
        animation_speed = 0.4,
        scale = 0.7,
        tint = {r = 0.45, g = 1.0, b = 0.45, a = 0.45},
        draw_as_glow = true,
        shift = util.by_pixel(0, -16),
      },
    },

    light = {intensity = 0.35, size = 10, color = {r = 0.4, g = 1.0, b = 0.4}},

    smoke = {
      {
        name = N.base.nuclear_smoke,
        deviation = {0.5, 0.5},
        frequency = 5,
        position = {0.0, -0.8},
        starting_vertical_speed = 0.02,
        starting_frame_deviation = 60,
      },
    },
  },

})

-- =============================================================================
  -- ONE PAIR PER YIELD STEP, and it has to be a pair per step.
  --
  -- `light` on an ExplosionPrototype is baked at load time -- intensity, size and
  -- colour, with no runtime handle -- so a single flash prototype lights the sky
  -- identically for a 5% shot and a 150% one. Reported as "explosion after visual
  -- light fx should scale with energy output, right now it is all the same".
  -- The only way to scale a baked field is to bake several.
  --
  -- SIZE scales with k.rad, the same multiplier every radius in the detonation
  -- uses, so the lit area and the damaged area stay the same shape. INTENSITY
  -- scales with k.unit instead -- deliberately NOT k.rad, which carries
  -- radius_scale and is a distance. A brightness multiplied by a distance is how
  -- a small shot ends up either invisible or blinding.
  --
  -- Intensity keeps a floor: a 5% detonation is still a detonation and should
  -- still light the ground, it just should not white out the screen the way the
  -- full device does.
--
-- A SEPARATE data:extend, because flash_pair returns a LIST of prototypes and
-- data:extend takes an array of them -- nesting the list as one element of the
-- table above would hand the engine a prototype with no `type`, which is a hard
-- load error a long way from its cause.
-- =============================================================================
data:extend(flash_pair())


-- =============================================================================
-- THE SHOCK FRONT PUFF, ONE PROTOTYPE PER YIELD STEP
--
-- scripts/detonate.lua stamps a ring of these at the exact radius the damage
-- front has reached. The sprite is base's nuke-shockwave -- the same white puff
-- vanilla's atomic bomb uses -- and the only thing that changes per step is how
-- big each puff is drawn.
--
-- WHY IT HAS TO BE PER STEP. An ExplosionPrototype's scale is baked at load time;
-- create_entity takes no scale argument. One fixed size therefore cannot serve a
-- front that is 30 tiles across at 1% and 2000 at 150%. At the big end a fixed
-- 6 tile puff spaced along an 11000 tile circumference is a dotted line, and a
-- dotted line is not a shockwave -- reported from the game as "there is no wave".
--
-- THE SIZING RULE. Puff diameter should be a little wider than the gap between
-- puffs, or the ring reads as beads rather than as a wall. detonate.lua caps the
-- stamp count, so at large radii the gap grows and the puff has to grow with it.
-- k.rad is already "how many times wider than the old full-yield event", which is
-- exactly the right curve -- it is clamped because at 150% it reaches 17 and a
-- puff a hundred tiles across stops reading as debris and starts reading as fog.
-- =============================================================================
--- The shock front's animation variations for C.blast.rings.wave.art.
local function wave_art(rgb, alpha)
  local mode = C.blast.rings.wave.art
  local tint = {r = rgb.r, g = rgb.g, b = rgb.b, a = alpha or 1}
  if mode == "smoke" then
    return anims.tinted(anims.shockwave(), tint)
  end
  local fire = anims.tinted(anims.plasma(), tint)
  if mode ~= "both" then return fire end
  return anims.stacked(anims.tinted(anims.shockwave(), tint), fire)
end

do
  local w = C.blast.rings.wave
  local heat = require("lib.heat")
  local steps = heat.steps()
  local out = {}
  for _, step in ipairs(C.charge.yield_targets) do
    local k = C.yield_factors(step.fraction)
    local m = k.rad
    if m < w.stamp_scale_min then m = w.stamp_scale_min end
    if m > w.stamp_scale_max then m = w.stamp_scale_max end

    -- AND ONE PER HEAT STEP INSIDE THAT, which is the second baked field this
    -- puff turned out to need. `tint` is baked at load exactly like `scale` and
    -- the animation speed, and the front COOLS as it travels (blue-white
    -- leaving the fireball, ember red at the rim -- see
    -- C.blast.rings.wave.wall), so one prototype per colour it passes through
    -- is the only way a create_entity can place the right one. The ladder is
    -- lib/heat.lua's, the same ten mired-spaced temperatures the lance is built
    -- at: 8 yields x 10 steps = 80 prototypes, data stage only.
    for hi, kelvin in ipairs(steps) do
      out[#out + 1] = {
        type = "explosion",
        name = N.ex_wave_for(step.fraction, hi),
        flags = {"not-on-map"},
        hidden = true,
        subgroup = "explosions",
        order = "z[oppenheimer]-a3",
        height = 0,
        -- Grows as it plays. The front is expanding, so a puff that expands
        -- with it reads as pressure rather than as a sprite being placed.
        scale_initial = m * w.stamp_scale_in,
        scale_end     = m * w.stamp_scale_out,

        -- THE ART is the mod's own greyscale bake of base's big-explosion
        -- (tools/make_wave_art.py), reshaped by frame_sequence so the fireball
        -- frames are held rather than flashing past -- see anims.plasma() for
        -- both, and for the measured envelope that made them necessary.
        --
        -- THE LIFETIME is a fraction of this yield's own sweep rather than the
        -- clip's fixed 64 ticks. At 5% the whole wave is 45 ticks, so a 64 tick
        -- stamp meant every ring of the sweep was still on screen when it
        -- ended -- one wave with every frame frozen, which renders as static
        -- nested rings. See C.blast.rings.wave.stamp_life.
        --
        -- THE COLOUR is this heat step's, through the same heat.glow_rgb
        -- scripts/detonate.lua draws the polygon wall with -- so the texture
        -- and the surface it is stamped on are the same gas at the same
        -- temperature by construction, not by two numbers kept in step by
        -- hand. C.blast.rings.wave.tint is only a white multiplier on top now
        -- (how loudly the texture reads against the wall), not the colour.
        animations = anims.retimed(
          wave_art(heat.glow_rgb(kelvin, w.tint), w.tint.a),
          w.stamp_life(step.fraction)),
      }
    end
  end
  data:extend(out)
end

-- =============================================================================
-- THE FIRE RING, ONE PROTOTYPE PER YIELD STEP AND HEAT STEP
--
-- The second stamp layer of the same front: scripts/detonate.lua's
-- draw_firewave runs the same stamp_ring the plasma puff above does, tighter
-- and far shorter-lived (C.blast.rings.firewave.lifetime_ticks), so what the
-- wave leaves behind reads as ground catching light rather than as gas.
-- `explosion`, not `fire`: self-terminating on its own animation, with no
-- damage or spread machinery to neuter.
--
-- WHY IT GAINED BOTH DIMENSIONS IN 0.47.0. It was ONE flat prototype at one
-- hand-picked ember tint, and both halves of that were visible from the game:
--   SIZE   -- 2.6 tiles, fixed, stamped around a circumference that reaches
--             11000 tiles. Correct placement, invisible flames: "red fire
--             decals".
--   COLOUR -- {1.00, 0.45, 0.10}, about 1900 K, laid on a wall that
--             wall_kelvin was drawing at 15-48 kK. One point, two
--             temperatures. Baked at load, so neither could be a runtime
--             argument; both have to be a prototype per value, exactly like
--             the puff above.
-- Colour comes from the same heat.glow_rgb call the wall and the plasma puff
-- read, so all three layers of one front agree by construction.
-- =============================================================================
do
  local fw = C.blast.rings.firewave
  local heat = require("lib.heat")
  local steps = heat.steps()
  local out = {}
  for _, step in ipairs(C.charge.yield_targets) do
    local m = C.yield_factors(step.fraction).rad
    if m < fw.stamp_scale_min then m = fw.stamp_scale_min end
    if m > fw.stamp_scale_max then m = fw.stamp_scale_max end

    for hi, kelvin in ipairs(steps) do
      local rgb = heat.glow_rgb(kelvin, fw.tint)
      out[#out + 1] = {
        type = "explosion",
        name = N.ex_firewave_for(step.fraction, hi),
        flags = {"not-on-map"},
        hidden = true,
        subgroup = "explosions",
        order = "z[oppenheimer]-a1",
        height = 0,
        scale_initial = fw.scale_initial * m,
        scale_end     = fw.scale_end * m,
        -- THE ART is the mod's own greyscale bake of base's fire-flame-01
        -- (tools/make_fire_art.py), frame-sequenced down to about one frame
        -- per tick of the decal's life -- see anims.flame() for both, and for
        -- the measurement that made the bake necessary.
        animations = anims.retimed(
          anims.tinted(anims.flame(fw.lifetime_ticks),
                       {r = rgb.r, g = rgb.g, b = rgb.b, a = fw.tint.a}),
          fw.lifetime_ticks),
      }
    end
  end
  data:extend(out)
end

-- The crater's ground fire, per yield step and per heat step up to the ground's
-- own peak: scripts/groundfire.lua lays each at the temperature its patch of
-- crater has cooled to (C.heat.ground).
do
  local gf = C.blast.rings.groundfire
  local out = {}
  if gf.enabled then
    local heat   = require("lib.heat")
    local steps  = heat.steps()
    local peak   = gf.kelvin(0)
    local frames = math.max(2, math.floor(gf.life * gf.frame_rate + 0.5))
    for _, step in ipairs(C.charge.yield_targets) do
      local s = gf.scale_for(step.fraction)
      for hi = 1, heat.step_ceiling(peak) do
        local rgb = heat.glow_rgb(steps[hi], gf.tint, peak)
        out[#out + 1] = {
          type = "explosion",
          name = N.ex_groundfire_for(step.fraction, hi),
          flags = {"not-on-map"},
          hidden = true,
          subgroup = "explosions",
          order = "z[oppenheimer]-a0",
          height = 0,
          render_layer = gf.render_layer,
          scale_initial = s,
          scale_end     = s,
          fade_in_duration  = gf.fade_in,
          fade_out_duration = gf.fade_out,
          animations = anims.retimed(
            anims.tinted(anims.flame_windows(frames, gf.variations, gf.size_spread),
                         {r = rgb.r, g = rgb.g, b = rgb.b, a = gf.tint.a}),
            gf.life),
        }
      end
    end
  end
  data:extend(out)
end

-- =============================================================================
-- THE RELEASE FIREBALL, ONE PROTOTYPE PER YIELD STEP AND HEAT STEP
--
-- The artwork at the centre when the collapse lets go (N.ex_flash_for is its
-- light and shake), on the shock front's sheet. Created from the control stage
-- (scripts/detonate.lua): its colour is the sphere's temperature, which a
-- data-stage trigger cannot know.
-- =============================================================================
do
  local rl = C.blast.release
  local heat = require("lib.heat")
  local steps = heat.steps()
  local out = {}
  if rl.enabled then
    for _, step in ipairs(C.charge.yield_targets) do
      local s = C.blast.release.scale_for(step.fraction)
      for hi, kelvin in ipairs(steps) do
        local rgb = heat.glow_rgb(kelvin, rl.tint)
        out[#out + 1] = {
          type = "explosion",
          name = N.ex_release_for(step.fraction, hi),
          flags = {"not-on-map"},
          hidden = true,
          subgroup = "explosions",
          order = "z[oppenheimer]-d0",
          height = 0,
          scale_initial = s * rl.scale_in,
          scale_end     = s * rl.scale_out,
          animations = anims.retimed(
            anims.tinted(anims.plasma(rl.hold),
                         {r = rgb.r, g = rgb.g, b = rgb.b, a = rl.tint.a}),
            rl.ticks),
        }
      end
    end
  end
  data:extend(out)
end

-- The implosion gather: shell puff and core, per yield step and per heat step.
-- An ExplosionPrototype bakes scale, animation speed (its lifetime), light and
-- tint at load and create_entity sets none of them, so each is a prototype per
-- value. Scale and lifetime come off the yield, colour off lib/heat.lua, since
-- the collapse heats as it converges (C.heat.collapse_gain).
do
  local imp   = C.blast.implosion
  local heat  = require("lib.heat")
  local steps = heat.steps()
  local out   = {}
  for _, step in ipairs(C.charge.yield_targets) do
    local f  = step.fraction
    local sm = imp.stamp_mult(f)
    local cm = imp.core_mult(f)
    local stamp_life = imp.stamp_life(f)
    -- total_ticks_for, not ticks_for: an explosion lives exactly as long as its
    -- animation plays, and the release does not fire until settle + beat after
    -- the shell closes.
    local core_life  = imp.total_ticks_for(f)

    for hi, kelvin in ipairs(steps) do
      -- rgb, not glow_rgb: glow dims by how far a temperature has fallen, which
      -- is the shock front's law across its span of radius. The collapse is one
      -- body, drawn at the undimmed hue by scripts/implode.lua's rim.
      local rgb = heat.rgb(kelvin)

      -- scale_initial > scale_end: every stamp shrinks while it plays, so the
      -- puff and the shell it belongs to point the same way.
      out[#out + 1] = {
        type = "explosion",
        name = N.ex_gather_for(f, hi),
        flags = {"not-on-map"},
        hidden = true,
        subgroup = "explosions",
        order = "z[oppenheimer]-a2",
        height = 0,
        scale_initial = sm * imp.stamp_scale_initial,
        scale_end     = sm * imp.stamp_scale_end,
        animations = anims.retimed(
          anims.tinted(anims.plasma_hot(stamp_life),
                       {r = rgb.r * imp.tint.r, g = rgb.g * imp.tint.g,
                        b = rgb.b * imp.tint.b, a = imp.tint.a}),
          stamp_life),
      }

      -- The point it collapses onto: one entity at ground zero held through the
      -- whole gather, growing while the shells fall into it.
      local core = {
        type = "explosion",
        name = N.ex_gather_core_for(f, hi),
        flags = {"not-on-map"},
        hidden = true,
        subgroup = "explosions",
        order = "z[oppenheimer]-a3",
        height = 0,
        scale_initial = cm * imp.core_scale_initial,
        scale_end     = cm * imp.core_scale_end,
        -- Half the puff's frame rate: a body this size boiling a frame a tick
        -- reads as jitter, and it is the cadence the release fireball plays at.
        animations = anims.retimed(
          anims.tinted(anims.plasma_hot(core_life / 2),
                       {r = rgb.r * imp.core_tint.r, g = rgb.g * imp.core_tint.g,
                        b = rgb.b * imp.core_tint.b, a = imp.core_tint.a}),
          core_life),
      }

      -- It lights the ground on a curve opposite the flash's: the flash blows
      -- out and falls away, the core climbs and peaks at the release. Size is
      -- capped -- a Factorio light is a screen-space fill.
      local cl = imp.core_light
      if cl and cl.enabled then
        local lit = cl.intensity_floor
                    + (cl.intensity - cl.intensity_floor)
                      * math.min(1, C.yield_factors(f).unit)
        core.light = {
          intensity = lit,
          size = math.min(cl.size * cm, cl.max_size),
          color = rgb,
        }
        core.light_intensity_factor_initial      = cl.factor_initial
        core.light_intensity_factor_final        = cl.factor_final
        core.light_intensity_peak_start_progress = cl.peak_start
        core.light_intensity_peak_end_progress   = cl.peak_end
        core.light_size_factor_initial           = cl.factor_initial
        core.light_size_factor_final             = cl.factor_final
        core.light_size_peak_start_progress      = cl.peak_start
        core.light_size_peak_end_progress        = cl.peak_end
      end

      out[#out + 1] = core
    end
  end
  data:extend(out)
end

-- =============================================================================
-- THE GROUND-ZERO DECAL, ONE PER YIELD STEP.
--
-- Fourth instance of the baked-field problem and the last one in the detonation.
-- The release stage created base's `huge-scorchmark` -- a nine tile sprite, at
-- every yield, in the middle of a crater that is 30 tiles across at one end of
-- the dial and 2000 at the other. Reported from the game as "the implosion
-- visual explosion fx has a tiny decal".
--
-- CLONED FROM BASE RATHER THAN REBUILT. The base prototype is four layered
-- sprite sheets with hand-placed shifts and a dice_y on the big one; retyping
-- that is four chances to get a number wrong for no gain. deepcopy and multiply
-- what needs multiplying -- the layer scales, their shifts (a shift is in tiles,
-- so scaling the art without scaling the shift slides the mark off centre), and
-- the boxes.
--
-- TWO DELIBERATE DIVERGENCES FROM BASE:
--
--   remove_on_tile_placement = FALSE. Base's is true, and true is a trap here:
--   scripts/detonate.lua paints the crater outward from radius zero, so the
--   first paint pass of every shot lands directly on top of the decal that was
--   created a few ticks earlier. A scorchmark that deletes itself when the
--   crater arrives is a scorchmark nobody ever sees.
--
--   time_before_removed is an hour, not ten minutes. The tile paint underneath
--   is permanent; a centre that expires while the crater stays would make ground
--   zero the cleanest-looking part of the hole.
-- =============================================================================
do
  local sc = C.blast.scar

  if sc.decal_enabled then
    local base = data.raw["corpse"] and data.raw["corpse"]["huge-scorchmark"]

    -- IF BASE EVER RENAMES IT, SAY SO AT LOAD TIME. A nil here would otherwise
    -- produce zero variants, which loads perfectly cleanly -- and then every
    -- release stage names a prototype that does not exist, which throws at the
    -- moment a shell lands, in someone's save, a long way from the cause.
    --
    -- Inside the enabled check, not above it: a user who has turned the scaled
    -- decal off has said they do not need this prototype, and refusing to load
    -- over something they opted out of is the wrong failure.
    assert(base, "base prototype corpse/huge-scorchmark not found -- "
              .. "set C.blast.scar.decal_enabled = false to fall back to it")

    local out = {}
    for _, step in ipairs(C.charge.yield_targets) do
      local frac = step.fraction
      local mult = sc.decal_mult(frac)

      local d = util.table.deepcopy(base)
      d.name = N.ex_scorch_for(frac)
      d.localised_name = base.localised_name or {"entity-name.huge-scorchmark"}
      d.hidden = true
      d.hidden_in_factoriopedia = true
      d.time_before_removed = sc.decal_lifetime
      d.remove_on_tile_placement = false

      -- Scale every layer of the ground patch, and its shift with it -- a shift
      -- is in TILES, so scaling the art without scaling the shift slides the
      -- mark off the point it is supposed to be centred on. `scale` defaults to
      -- 1 when a layer omits it, which some of base's layers do.
      --
      -- Both shift forms are handled because a Vector is either. base writes
      -- util.by_pixel here, which returns the array form -- but that is base's
      -- current choice, not a guarantee, and indexing [1] on {x=,y=} is nil
      -- arithmetic at load with a message that names neither this file nor a
      -- reason.
      local gp = d.ground_patch
      if gp and gp.layers then
        for _, l in ipairs(gp.layers) do
          l.scale = (l.scale or 1) * mult
          local sh = l.shift
          if sh then
            if sh.x then
              l.shift = {x = sh.x * mult, y = sh.y * mult}
            else
              l.shift = {sh[1] * mult, sh[2] * mult}
            end
          end
        end
      end

      -- THE COLLISION BOX IS DELIBERATELY LEFT AT BASE'S SIZE, and scaling it
      -- was the first thing tried.
      --
      -- The scorchmark collides on the `doodad` layer and the release stage
      -- creates it with check_buildability = true (base's nuke does the same).
      -- Scaling the box to match a 63 tile decal therefore asks the engine to
      -- find 63 clear tiles of doodad layer at ground zero -- and if it cannot,
      -- the decal is silently not created at all. Trading "the mark is drawn
      -- bigger than its footprint" for "the mark sometimes does not appear" is
      -- a bad trade, and the footprint of a flat sprite nobody can select is not
      -- load-bearing for anything.
      out[#out + 1] = d
    end
    data:extend(out)
  end
end

-- =============================================================================
-- THE SAME FLAME, ON A TREE.
--
-- WHY THIS PROTOTYPE HAS TO EXIST. Factorio does not draw fire on a tree using
-- the fire's own `pictures`. Base's `fire-flame` names a second prototype in
-- `spawn_entity` -- `fire-flame-on-tree` -- which carries
-- `small_tree_fire_pictures`, its own alpha and a `tree_dying_factor`, and THAT
-- is the prototype responsible for the burning-canopy look. A fire without one
-- draws a generic ground flame on top of a still-green tree, which reads as a
-- sprite standing in a forest rather than as a forest alight.
--
-- CLONED, NOT REBUILT. The tree flame art is generated by base's own fire-util
-- (`create_small_tree_flame_animations`), and reproducing that by hand is a
-- large table of numbers to get subtly wrong for no gain. deepcopy and change
-- the four things that matter.
--
-- AND IT KILLS THE SPREAD, which is the entire reason we cannot simply name
-- base's. `fire-flame-on-tree` has `maximum_spread_count = 100`,
-- `spread_delay = 300` and `spawn_entity` pointing at ITSELF -- so one tree
-- catching is a forest fire that propagates for as long as there is forest. That
-- is the runaway N.scorch_flame was created to prevent, and it would have come
-- back in through a field whose name says nothing about spreading.
-- =============================================================================
do
  local base = data.raw["fire"] and data.raw["fire"]["fire-flame-on-tree"]

  -- If base ever renames it, fail at LOAD with a reason. A nil here would leave
  -- N.scorch_flame.spawn_entity naming a prototype that does not exist, which is
  -- a load error whose message points at the fire rather than at this block.
  assert(base, "base prototype fire/fire-flame-on-tree not found -- "
            .. "N.scorch_flame.spawn_entity has nothing to name")

  local d = util.table.deepcopy(base)
  d.name = N.scorch_flame_tree
  d.localised_name = {"entity-name.fire-flame"}
  d.hidden = true

  -- The same three mechanisms, off, for the same reason as N.scorch_flame.
  -- spawn_entity is pointed at ITSELF exactly as base does -- a tree fire that
  -- lands on another tree should still be a tree fire -- which is safe here only
  -- because the spread that would do the landing is disabled.
  d.spawn_entity                 = N.scorch_flame_tree
  d.maximum_spread_count         = 0
  d.spread_delay                 = 60 * 60 * 60
  d.spread_delay_deviation       = 1
  d.delay_between_initial_flames = 0

  -- Bounded life, like its parent: base's tree fire has no maximum_lifetime at
  -- all (the field defaults to max uint32), so a tree lit by this would burn
  -- until something else stopped it.
  d.initial_lifetime           = sf.lifetime
  d.maximum_lifetime           = sf.lifetime
  d.lifetime_increase_by       = 0
  d.lifetime_increase_cooldown = 0

  -- Base's tree fire does 35/60 per tick, which is nearly three times what
  -- fire-flame does and would quietly make this the mod's largest damage source
  -- over the twelve seconds it burns. Same rounding error as the ground flame.
  d.damage_per_tick = {amount = sf.damage_per_tick, type = sf.damage_type}
  d.maximum_damage_multiplier = 1

  -- the same two cost multipliers as its parent. base's tree fire ships
  -- its own smoke table and a smoke_source_pictures set, and inheriting those at
  -- our flame counts is the frame-rate problem wearing base's clothes.
  d.light = sf.light_enabled and sf.light or nil
  if d.smoke then
    for _, sm in ipairs(d.smoke) do sm.frequency = sf.smoke_frequency end
  end

  data:extend({d})
end
