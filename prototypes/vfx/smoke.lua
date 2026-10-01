-- prototypes/vfx/smoke.lua ----------------------------------------------------------
-- The mushroom cloud's stem and cap, and the long smoulder that outlives both.
-- Backlog #92, #93.
--
-- The cap ANIMATION (prototypes/vfx/explosions.lua, N.ex_cap) is already a
-- rising mushroom -- base ships 100 frames of it. What that animation does not
-- give you is persistence: it plays for a few seconds and it is gone. These
-- trivial-smoke prototypes are what make the column stand there afterwards and
-- then shear away downwind.
--
-- trivial-smoke fields that matter here (all confirmed via
-- `apiq proto TrivialSmokePrototype`):
--   duration            ticks the puff lives
--   spread_duration     ticks over which it expands
--   start_scale/end_scale
--   fade_in_duration / fade_away_duration
--   affected_by_wind    #93: this is what makes the cap drift
--   cyclic              loop the animation rather than play once
--
-- Base's own `nuclear-smoke` is the template -- duration 30, spread 100,
-- start_scale 2, end_scale 0.2, affected_by_wind true, cyclic true. Ours run
-- far longer, because a detonation this size should still be visible on the
-- horizon a minute later.
--------------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local m = C.blast.mushroom

--- The smoke sheet base uses for nuclear smoke.
-- base/prototypes/entity/atomic-bomb.lua builds `nuclear-smoke` from
-- smoke_animations.trivial_smoke_fast, which is smoke-fast.png at 50x50,
-- 16 frames, animation_speed 16/60. Those exact values are reproduced here
-- rather than cross-mod requiring smoke-animations.lua (see anims.lua for why).
-- Note it is smoke-fast/smoke-fast.png -- NOT smoke/smoke.png, which is a
-- different sheet with different geometry.
local function smoke_sheet(scale, speed)
  return {
    filename = "__base__/graphics/entity/smoke-fast/smoke-fast.png",
    flags = {"smoke", "linear-magnification"},
    priority = "high",
    width = 50,
    height = 50,
    frame_count = 16,
    animation_speed = speed or (16 / 60),
    scale = scale or 2.5,
  }
end

data:extend({

  -- ===========================================================================
  -- #92: THE STEM. A narrow, tall, slow column at ground zero. It does NOT
  -- drift -- a mushroom stem stands still while the cap above it shears away,
  -- which is exactly the contrast that reads as "mushroom cloud" rather than
  -- "big smoke".
  -- ===========================================================================
  {
    type = "trivial-smoke",
    name = N.smoke_stem,
    duration = m.stem_duration,
    spread_duration = 240,
    fade_in_duration = 30,
    fade_away_duration = 180,
    start_scale = 3.0,
    end_scale = 5.0,
    render_layer = "higher-object-above",
    color = {r = 0.55, g = 0.42, b = 0.30, a = 0.62},
    affected_by_wind = false,   -- the stem holds; the cap moves
    cyclic = true,
    movement_slow_down_factor = 0.96,
    animation = smoke_sheet(3.0, 1 / 8),
  },

  -- ===========================================================================
  -- #93: THE CAP. Wide, high, and wind-driven, so over the next minute the
  -- cloud shears off downwind and the whole thing stops looking like a sphere.
  -- Vanilla already does this on nuclear-smoke; it just does not last long
  -- enough to notice.
  -- ===========================================================================
  {
    type = "trivial-smoke",
    name = N.smoke_cap,
    duration = m.cap_duration,
    spread_duration = 400,
    fade_in_duration = 60,
    fade_away_duration = 300,
    start_scale = 2.0,
    end_scale = 9.0,
    render_layer = "higher-object-above",
    color = {r = 0.62, g = 0.50, b = 0.38, a = 0.50},
    affected_by_wind = true,    -- #93: the drift
    cyclic = true,
    movement_slow_down_factor = 0.99,
    animation = smoke_sheet(4.0, 1 / 10),
  },

  -- Fast dark smoke thrown out by the shockwave fan itself.
  {
    type = "trivial-smoke",
    name = N.smoke_smoulder,
    duration = 120,
    spread_duration = 100,
    fade_in_duration = 10,
    fade_away_duration = 40,
    start_scale = 1.6,
    end_scale = 0.3,
    render_layer = "higher-object-under",
    color = {r = 0.60, g = 0.47, b = 0.34, a = 0.50},
    affected_by_wind = true,
    cyclic = true,
    animation = smoke_sheet(2.5),
  },

  -- ===========================================================================
  -- BARREL VENTING (scripts/installfx.lua). Pale steam off the muzzle
  -- after a shot: small at birth, swelling and thinning, drifting downwind.
  -- Above the head (higher-object-above), since it leaves from the barrel tip.
  -- ===========================================================================
  {
    type = "trivial-smoke",
    name = N.smoke_vent,
    duration = 150,
    spread_duration = 150,
    fade_in_duration = 6,
    fade_away_duration = 110,
    start_scale = 0.6,
    end_scale = 3.2,
    render_layer = "higher-object-above",
    color = {r = 0.84, g = 0.85, b = 0.87, a = 0.42},
    affected_by_wind = true,
    cyclic = true,
    animation = smoke_sheet(2.0, 1 / 6),
  },

  -- ===========================================================================
  -- THE IGNITION SHOCK's dust (scripts/installfx.lua). Short and low:
  -- kicked up off the concrete, gone in a little over a second. Under the
  -- installation's hardware (lower-object-above-shadow), so it rolls round the
  -- banks rather than veiling them.
  -- ===========================================================================
  {
    type = "trivial-smoke",
    name = N.smoke_dust,
    duration = 80,
    spread_duration = 80,
    fade_in_duration = 3,
    fade_away_duration = 60,
    start_scale = 0.9,
    end_scale = 2.4,
    render_layer = "lower-object-above-shadow",
    color = {r = 0.60, g = 0.55, b = 0.47, a = 0.55},
    affected_by_wind = false,
    cyclic = true,
    animation = smoke_sheet(2.0),
  },

  -- ===========================================================================
  -- The long burn. A particle-source seeded across the crater that keeps
  -- emitting for a full minute after everything else has faded -- the detail
  -- that sells "something happened here" once the spectacle is over.
  -- Modelled on base's `nuclear-smouldering-smoke-source`.
  -- ===========================================================================
  {
    type = "particle-source",
    name = N.smoke_source,
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "particles",
    order = "z[oppenheimer]-a",
    time_to_live = 60 * 90,
    time_to_live_deviation = 30 * 60,
    time_before_start = 90,
    time_before_start_deviation = 60,
    height = 0.4,
    height_deviation = 0.1,
    vertical_speed = 0,
    vertical_speed_deviation = 0,
    horizontal_speed = 0,
    horizontal_speed_deviation = 0,
    smoke = {
      {
        name = "soft-fire-smoke",   -- base prototype, by name
        frequency = 0.10,
        position = {0.0, 0},
        starting_frame_deviation = 60,
        starting_vertical_speed = 0.01,
        starting_vertical_speed_deviation = 0.005,
        vertical_speed_slowdown = 1,
      },
    },
  },

})
