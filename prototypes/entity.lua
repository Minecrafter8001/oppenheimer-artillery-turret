-- prototypes/entity.lua -------------------------------------------------------
-- The turret itself and the invisible "flare" the targeting remote drops on
-- the ground to mark a strike.
--
-- CHASSIS: "electric-turret", not "artillery-turret" -- a laser-turret's whole
-- prototype family is built for a beam leaving a housing, which is what this
-- weapon actually is. Costs the resonance-cell chamber's world-visible ammo
-- badge (no ammo inventory exists on this chassis at all; the fire-control
-- panel's own readout is unaffected). Graphics/sound point entirely at
-- __base__'s laser-turret sheets; the only shipped image is the placement preview.
--
-- THE SAFETY MODEL: electric-turret has genuine native attack AI with no
-- "off" switch (no artillery_auto_targeting equivalent). This mod still fires
-- its own lance entirely by hand (scripts/beam.lua) and never wants the
-- entity's own attack to fire at all, so `range` below is kept far too short
-- to ever find anything -- CLAUDE.md's standing "lock at the effect, not the
-- authority" rule, not a state-detection scheme (which is the fragile pattern
-- that has bitten this mod twice already).
--
-- ROTATION MECHANISM survives unchanged: LuaEntity.orientation is documented
-- as "the orientation of the weapon" for turrets (confirmed via apiq), and
-- scripts/turret.lua's read/write_orientation already fall back to it
-- whenever relative_turret_orientation is unavailable (always, on this
-- chassis) -- so turret.slew needed no changes.
--
-- THE ROTATING ART: Gate 09 came back negative -- the engine does not
-- re-render a folded turret's sheet against scripted `.orientation` writes. So
-- the rotating visual is script-drawn: N.anim.turret_head (+ _glow, _shadow)
-- below, drawn by scripts/render.lua with rendering.draw_animation.
--
-- THE DOUBLE BARREL, TWO BUGS STACKED. Reported in game as "another
-- sprite pasted on, rotated at a weird angle".
--   1. The native folded_animation was still drawn, frozen at one facing, and
--      0.26.0 claimed the script head "covers" it. A transparent sprite only
--      covers an identical one pointing the SAME way -- any other facing shows
--      both barrels. The native rotating layers are now EMPTY (folded_animation
--      is mandatory, so it stays, as a 1x1 transparent frame) and
--      energy_glow_animation, the same frozen sheet in additive, is gone.
--   2. The head itself was wrong. AnimationPrototype has NO direction_count
--      (apiq), so the 64-facing sheet loaded as frame 0 only -- the north
--      facing -- and writing LuaRenderObject.orientation ROTATES THAT BITMAP
--      (perspective, lighting and the pixel shift all spun with it). It is
--      now a 64-frame strip, and render.sync_head picks the facing by
--      animation_offset; the object's own orientation is never written.
-- The shadow is script-drawn too now, from an AnimationPrototype carrying
-- draw_as_shadow (a real field on that prototype, apiq) -- UNVERIFIED that the
-- script-render path honours it; C.turret.head.shadow turns it off.
--
-- graphics_set.base_visualisation, corpse and dying_explosion are all
-- laser-turret's own (base_visualisation dimensions/shift copied from
-- <install>/data/base/prototypes/entity/turrets.lua, nothing guessed) --
-- fully replaced, not an artillery turret wearing a different hat.
--
-- source_offset = {0, -3.423489/4} on vanilla's own attack_parameters is
-- real, art-directed data for where this sheet's beam leaves the housing,
-- scaled by shift_ratio() into C.beam.muzzle_forward_mult/_lift_mult's
-- starting guess -- still wants live confirmation via /oppenheimer-muzzle.
------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local util = require("util")

-- Sets up two globals for the whole data stage:
--   circuit_connector_definitions  -- per-entity wire attachment points/sprites
--   default_circuit_wire_max_distance  (= 9)
-- `base` already required this file; require() caches, so this is a cheap
-- "make sure those globals exist" and does not re-run the file.
require("circuit-connector-sprites")

-- ---------------------------------------------------------------------------
-- SCALING (#52). The base artillery art is authored for a 3x3 turret at
-- scale 0.5. This mod draws it at C.turret.sprite_scale.
--
-- The trap: util.sprite_load reads `shift` straight out of each sprite's
-- metadata file and does NOT scale it with `scale`. It takes a separate
-- `multiply_shift`. Miss that and a scaled-up turret silently comes apart --
-- barrel, barrel shadow, cannon base and turret base each drift away from the
-- pivot by a different amount, and nothing errors. Every sprite_load below
-- passes multiply_shift; every hand-written shift goes through px().
-- ---------------------------------------------------------------------------
local SCALE  = C.turret.sprite_scale
local RATIO  = C.shift_ratio()

--- by_pixel, scaled with the sprite.
local function px(x, y) return util.by_pixel(x * RATIO, y * RATIO) end

--- One `type = "animation"` prototype holding a 64-facing laser-turret sheet
--- as a 64-frame strip, at THIS installation's scale. See the header, bug 2.
local function head_strip(name, path, w, h, sx, sy, extra)
  local hd = C.turret.head
  local o = {
    type = "animation",
    name = name,
    filename = path,
    priority = "very-low",
    frame_count = hd.directions,
    line_length = hd.line_length,
    animation_speed = hd.frame_speed,
    width = w,
    height = h,
    shift = px(sx, sy),
    scale = SCALE,
  }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

data:extend({
  {
    type = "electric-turret",
    name = N.turret,
    -- The charge window and the reference shot are DERIVED, so the description
    -- that quotes them is parameterised rather than typed in locale beside them.
    -- The charge window is quoted twice in the text and a LocalisedString is
    -- positional, so it goes in twice: naming __1__ again renders it raw.
    localised_description = (function()
      local secs = string.format("%.1f", C.charge_window())
      return {
        "entity-description." .. N.turret,
        secs, secs,
        C.fmt_rate(C.power.reference_rate),
        tostring(math.floor(C.yield.reference_radius + 0.5)),
      }
    end)(),
    icon = "__base__/graphics/icons/laser-turret.png",
    flags = {"placeable-neutral", "placeable-player", "player-creation"},
    -- The full pad, shown only while placing (C.preview).
    radius_visualisation_specification = C.preview.enabled and {
      sprite = {
        filename = "__oppenheimer-artillery-turret-forked__/graphics/installation-preview.png",
        size = C.preview.sprite_px,
        priority = "extra-high",
      },
      distance = C.preview_distance(),
      draw_in_cursor = true,
      draw_on_selection = false,
    } or nil,
    alert_when_attacking = false,
    -- MANDATORY on TurretPrototype -- the shipped spec's own field dump did
    -- not mark it "(optional)" but the load error confirmed it directly:
    -- "Key call_for_help_radius not found in property tree". Vanilla
    -- laser-turret's own figure; irrelevant in practice since this turret
    -- never takes fire that would trigger it under normal play the way a
    -- defensive laser turret does, but the prototype loader wants a real
    -- number regardless.
    call_for_help_radius = 40,

    -- ---- placement / mining -----------------------------------------------
    minable = {mining_time = 0.5, result = N.turret},
    fast_replaceable_group = N.turret,
    collision_box = C.collision_box(),
    selection_box = C.selection_box(),
    drawing_box_vertical_extension = C.turret.vertical_extension,

    -- ---- health / durability ---------------------------------------------
    max_health = C.turret.max_health,
    -- laser-turret's own death FX, not artillery's leftover wreck --
    -- see this file's header.
    corpse = N.base.laser_turret_remnants,
    dying_explosion = N.base.laser_turret_explosion,
    resistances = C.turret.resistances,

    -- ---- circuit network -------------------------------------------------
    circuit_connector = circuit_connector_definitions["laser-turret"],
    circuit_wire_max_distance = default_circuit_wire_max_distance,

    -- ---- power: VOID, DELIBERATELY --------------------------------------
    -- electric-turret REQUIRES an energy_source even though this mod never
    -- wants the entity's own native attack to draw real power or to fire --
    -- every joule this installation actually spends is metered through the
    -- sixteen capacitor banks (scripts/pylon.lua), same as always. A void
    -- source needs no wiring, always reports full, and cannot add a second,
    -- untracked power draw alongside the banks'.
    energy_source = {type = "void"},

    -- ---- THE NATIVE ATTACK, KEPT PERMANENTLY UNREACHABLE ------------------
    -- See this file's header. `range` is what actually holds the lock: a
    -- turret with nothing in reach never leaves its folded state, never
    -- rotates on its own, and never fires -- regardless of ammo_type or
    -- targets_something below, which exist only because the field is
    -- mandatory and must parse. N.inert_category is the same dead category
    -- the old flare used, chosen for the same reason: nothing in the game can
    -- answer it even if something upstream of `range` ever changed.
    attack_parameters = {
      type = "beam",
      range = C.turret.attack_range,
      cooldown = C.turret.attack_cooldown,
      ammo_category = N.inert_category,
      ammo_type = {
        energy_consumption = "1J",
        action = {
          type = "direct",
          action_delivery = {
            type = "beam",
            beam = "laser-beam",   -- base's own; never reachable at range 0.5
            max_length = 1,
            duration = 1,
          },
        },
      },
    },

    -- ---- the rotating housing: EMPTY ON PURPOSE -------
    -- Mandatory field, so a single transparent frame. Anything drawn here is
    -- frozen at one facing underneath the script-drawn head and shows as a
    -- second barrel. preparing/prepared/attacking stay unset: unreachable.
    folded_animation = {
      filename = "__core__/graphics/empty.png",
      priority = "extra-high",
      width = 1,
      height = 1,
      direction_count = 1,
    },
    folded_animation_is_stateless = true,

    graphics_set = {
      base_visualisation = {
        animation = {
          layers = {
            -- #55: laser-turret's own base art (see this file's header) --
            -- an oversized tinted copy under a normal one, to sell scale
            -- without blur.
            {
              filename = "__base__/graphics/entity/laser-turret/laser-turret-base.png",
              priority = "high",
              line_length = 1,
              width = 138,
              height = 104,
              scale = SCALE * 1.18,
              shift = px(-0.5, 2),
              tint = {r = 0.42, g = 0.44, b = 0.46, a = 1.0},
            },
            {
              filename = "__base__/graphics/entity/laser-turret/laser-turret-base.png",
              priority = "high",
              line_length = 1,
              width = 138,
              height = 104,
              scale = SCALE,
              shift = px(-0.5, 2),
            },
            {
              filename = "__base__/graphics/entity/laser-turret/laser-turret-base-shadow.png",
              priority = "high",
              line_length = 1,
              width = 132,
              height = 82,
              shift = px(6, 3),
              draw_as_shadow = true,
              scale = SCALE,
            },
          },
        },
      },
    },

    -- FRACTION OF A FULL TURN per tick, not radians. The engine does not
    -- actually drive this: scripts/turret.slew turns the barrel itself at
    -- C.turret.slew_speed, and the two are set to the same number on purpose
    -- so the gun would move identically whichever thing were driving it (it
    -- also never gets the chance to, per the range lock above).
    rotation_speed = C.turret.rotation_speed,

    -- ---- sound --------------------------------------------------------
    -- Inlined from __base__/prototypes/entity/sounds.lua (sounds.artillery_open /
    -- artillery_close) so we don't have to require that file cross-mod. Kept
    -- from the artillery chassis on purpose -- these are generic open/close
    -- cues, not tied to the cannon art the chassis swap replaced.
    open_sound  = {filename = "__base__/sound/artillery-open.ogg",  volume = 0.57},
    close_sound = {filename = "__base__/sound/artillery-close.ogg", volume = 0.6},
    rotating_sound = {
      sound         = {filename = "__base__/sound/fight/artillery-rotation-loop.ogg", volume = 0.6},
      stopped_sound = {filename = "__base__/sound/fight/artillery-rotation-stop.ogg"},
    },

    -- ---- #59: water reflection, scaled with the hull ------------------
    -- laser-turret's own reflection art (20x32, native shift (0, 40)
    -- per base source), not artillery's leftover 28x32 sprite.
    water_reflection = {
      pictures = {
        filename = "__base__/graphics/entity/laser-turret/laser-turret-reflection.png",
        priority = "extra-high",
        width = 20,
        height = 32,
        shift = px(0, 40),
        variation_count = 1,
        scale = 5 * RATIO,
      },
      rotate = false,
      orientation_to_variation = false,
    },

    -- HAZARD: a prototype has ONE `working_sound` key; a second assignment
    -- silently replaces the first. The standby hum and the charge whine are both
    -- `main_sounds` entries, as on base's accumulator, and share
    -- `max_sounds_per_prototype`.
    working_sound = {
      max_sounds_per_prototype = 3,
      main_sounds = {
        { -- #105: the standby hum
          -- The engine butt-loops this file with no crossfade, so it must stay
          -- a true loop: any head/tail fade stacks into a dropout every wrap.
          -- Re-cut it with tools/seamless_loop.py, never with a plain trim.
          sound = {
            filename = "__oppenheimer-artillery-turret-forked__/sound/standby-hum.ogg",
            volume = C.sound.hum_volume,
            audible_distance_modifier = C.sound.hum_distance,
          },
          fade_in_ticks  = 20,
          fade_out_ticks = 40,
        },
        { -- #77: the charge whine
          sound = {
            variations = {
              {filename = "__base__/sound/accumulator-working-01.ogg"},
              {filename = "__base__/sound/accumulator-working-02.ogg"},
              {filename = "__base__/sound/accumulator-working-03.ogg"},
              {filename = "__base__/sound/accumulator-working-04.ogg"},
            },
            volume = C.turret.charge_sound_volume,
            audible_distance_modifier = 1.6,
          },
          fade_in_ticks  = 20,
          fade_out_ticks = 40,
        },
      },
    },

    -- ---- #60: permanent light. In Factorio, lit reads as important. ----
    light = C.turret.light,

    -- ---- #62: oversized map presence ----------------------------------
    map_color = {r = 0.85, g = 0.55, b = 0.15},
  },

  -- THE SCRIPT-DRAWN HEAD. Standalone
  -- `type = "animation"` prototypes -- rendering.draw_animation takes a
  -- prototype NAME. Each is the 64-facing sheet as a 64-FRAME strip, since
  -- AnimationPrototype has no direction_count; render.sync_head selects the
  -- facing by frame. Dims/shifts are vanilla's laser_turret_shooting*()
  -- (base turrets.lua), scaled like every other layer in this file.
  head_strip(N.anim.turret_head,
             "__base__/graphics/entity/laser-turret/laser-turret-shooting.png",
             126, 120, 0, -35, {tint = C.turret.tint}),
  head_strip(N.anim.turret_head_glow,
             "__base__/graphics/entity/laser-turret/laser-turret-shooting-light.png",
             122, 116, -0.5, -35, {blend_mode = "additive"}),
  head_strip(N.anim.turret_head_shadow,
             "__base__/graphics/entity/laser-turret/laser-turret-shooting-shadow.png",
             170, 92, 50.5, 2.5, {draw_as_shadow = true}),

  -- The flare: an invisible, short-lived marker entity. The targeting remote
  -- (prototypes/item.lua) spawns one where you click; artillery turrets in range
  -- then fire at it. Copied from the vanilla artillery-flare, unchanged except
  -- the name.
  {
    type = "artillery-flare",
    name = N.flare,
    icon = "__base__/graphics/icons/artillery-targeting-remote.png",
    flags = {"placeable-off-grid", "not-on-map"},
    hidden = true,
    
    -- THE MOST DANGEROUS LINE IN THIS MOD. Read the block in
    -- prototypes/ammo-category.lua before changing it -- do not point this at
    -- N.shell (the cannon's own, live category). N.flare is kept only for a
    -- pre-0.8.0 save with a round already in the air (this mod's own
    -- designator is a selection-tool, on_player_selected_area, and never
    -- creates one); an ordinary artillery-remote elsewhere in the game could
    -- still drop one, and it must never be a live firing order.
    shot_category = N.inert_category,
    
    map_color = {1, 0.5, 0},
    life_time = 60 * 60,          -- ticks the flare lasts (1 minute)
    initial_height = 0,
    initial_vertical_speed = 0,
    initial_frame_speed = 1,
    shots_per_flare = 1,          -- shells fired per flare before it clears
    early_death_ticks = 3 * 60,   -- clears this long after the last shot lands
    pictures = {
      {
        filename = "__core__/graphics/shoot-cursor-red.png",
        priority = "low",
        width = 258,
        height = 183,
        scale = 1,
        flags = {"icon"},
      },
    },
  },
})
