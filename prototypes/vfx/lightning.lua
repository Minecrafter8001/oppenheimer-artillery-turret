-- prototypes/vfx/lightning.lua: the sphere lightning's channels, impacts and sky bolts, one set per strike level.
-- Space Age only. The art is Space Age's tesla and storm sheets, referenced in place and never copied; without it scripts/lightning.lua draws each strike itself.

if not mods["space-age"] then return end

local C    = require("config")
local N    = require("lib.names")
local util = require("util")

local LT   = C.beam.sphere.lightning
local BEAM = "__space-age__/graphics/entity/beam/"
local STORM = "__space-age__/graphics/entity/lightning/"
local AUTHORED = 0.5   -- the scale Space Age draws these sheets at

-- LightningPrototype.damage is a number before 2.1 and DamageParameters from 2.1.
local base_major, base_minor = string.match(mods["base"] or "", "^(%d+)%.(%d+)")
local DAMAGE_IS_TABLE = tonumber(base_major) > 2 or (tonumber(base_major) == 2 and tonumber(base_minor) >= 1)

--- One Space Age sheet at `scale`; its authored shift is scaled with it.
local function sheet(path, scale, o)
  return util.sprite_load(path, {
    frame_count     = o.frames,
    repeat_count    = o.repeat_count,
    animation_speed = o.speed or 0.5,
    draw_as_glow    = true,
    blend_mode      = o.blend,
    flags           = o.flags,
    tint            = o.tint,
    scale           = scale,
    multiply_shift  = scale / AUTHORED,
  })
end

local ENDS = {"trilinear-filtering"}

--- The tesla turret's channel: a crackling body under its lightning loop.
local function tesla_body(i, scale)
  return {layers = {
    sheet(BEAM .. "tesla-body-" .. i, scale, {frames = 20, repeat_count = 4, blend = "additive"}),
    sheet(BEAM .. "lightning-loop-" .. i, scale, {frames = 80, blend = "additive"}),
  }}
end

--- The tesla chain's thinner arc: a hairline core under its crackle.
local function chain_body(i, scale)
  return {layers = {
    sheet(BEAM .. "chain-body-0", scale, {frames = 1, repeat_count = 40, blend = "additive"}),
    sheet(BEAM .. "chain-body-" .. i, scale, {frames = 40, blend = "additive"}),
  }}
end

local function bodies(make, scale)
  local out = {}
  for i = 1, 6 do out[i] = make(i, scale) end
  return out
end

--- The channel's light on the ground: base's laser ground strip, 64 x 256 px.
local function ground_strip(scale)
  return {
    filename = "__base__/graphics/entity/laser-turret/laser-ground-light-body.png",
    draw_as_light = true,
    flags = {"light"},
    line_length = 1,
    width = 64,
    height = 256,
    scale = scale,
    animation_speed = 0.5,
    tint = LT.ground_tint,
  }
end

local function title(kind, level)
  return {"entity-name.oppenheimer-lightning", kind, tostring(level)}
end

--- A beam carrying no action; scripts/lightning.lua does the damage.
local function channel(kind, level, scale, set, ground)
  return {
    type = "beam",
    name = N.lightning(kind, level),
    localised_name = title(kind, level),
    flags = {"not-on-map"},
    hidden = true,
    width = scale,
    damage_interval = 60,
    action_triggered_automatically = false,
    random_target_offset = false,
    graphics_set = {
      -- A 64 px body sheet covers 2 x scale tiles; segments any shorter overlap.
      desired_segment_length = 2 * scale,
      randomize_animation_per_segment = true,
      beam = set,
      ground = ground,
    },
  }
end

local function camera(level, s)
  local cam = LT.camera
  if level < cam.from_level then return nil end
  return {
    type = "direct",
    action_delivery = {
      type = "instant",
      target_effects = {{
        type = "camera-effect",
        duration = cam.duration,
        ease_in_duration = cam.ease_in,
        ease_out_duration = cam.duration - cam.ease_in,
        strength = C.range_at(cam.strength, s),
        full_strength_max_distance = cam.full_distance,
        max_distance = math.floor(C.range_at(cam.max_distance, s) + 0.5),
      }},
    },
  }
end

local function explosion(kind, level, animations, extra)
  local e = {
    type = "explosion",
    name = N.lightning(kind, level),
    localised_name = title(kind, level),
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = "z[oppenheimer]-l",
    height = 0,
    animations = animations,
  }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

local function storm_anims(names, scale)
  local out = {}
  for i, n in ipairs(names) do
    out[i] = sheet(STORM .. n, scale, {frames = 36, speed = 1})
  end
  return out
end

local BURSTS = {"lightning-explosion", "lightning-explosion-2"}
local STREAMERS = {}
for i = 1, 8 do STREAMERS[i] = "lightning-streamer-" .. i end

--- Space Age's storm bolt, falling from `height` tiles onto the flash.
local function sky(level)
  local sk = LT.sky
  local s = (level - sk.from_level) / math.max(1, LT.max_level - sk.from_level)
  local look = util.table.deepcopy(sk.look)
  look.bolt_half_width = C.range_at(sk.bolt_half_width, s)
  look.light = {intensity = sk.light_intensity, size = C.range_at(sk.light_size, s),
                color = sk.light_color}
  look.cloud_background = util.sprite_load(STORM .. "lightning-cloud", {
    draw_as_glow = true, scale = 1, frame_count = 4, tint = sk.cloud_tint,
  })
  look.explosion = storm_anims(BURSTS, AUTHORED)
  look.ground_streamers = storm_anims(STREAMERS, AUTHORED)
  look.attractor_hit_animation = util.sprite_load(STORM .. "lightning-attractor-hit-anim", {
    draw_as_glow = true, scale = 1, frame_count = 36,
  })
  return {
    type = "lightning",
    name = N.lightning("sky", level),
    localised_name = title("sky", level),
    icon = "__space-age__/graphics/icons/lightning.png",
    flags = {"not-on-map"},
    hidden = true,
    damage = DAMAGE_IS_TABLE and {amount = sk.damage, type = "electric"} or sk.damage,
    energy = sk.energy,
    time_to_damage = sk.time_to_damage,
    effect_duration = math.floor(C.range_at(sk.effect_duration, s) + 0.5),
    source_offset = {0, -C.range_at(sk.height, s)},
    source_variance = sk.variance,
    graphics_set = look,
  }
end

local out = {}
local il = LT.impact_light
for level = LT.min_level, LT.max_level do
  local v = C.lightning_level(level)
  local bs = v.branch_scale

  out[#out + 1] = channel("bolt", level, v.scale, {
    head = tesla_body(1, v.scale),
    tail = tesla_body(6, v.scale),
    body = bodies(tesla_body, v.scale),
  }, {
    head = ground_strip(v.scale),
    tail = ground_strip(v.scale),
    body = {ground_strip(v.scale)},
  })

  out[#out + 1] = channel("fork", level, bs, {
    head = chain_body(1, bs),
    tail = chain_body(6, bs),
    body = bodies(chain_body, bs),
  })

  out[#out + 1] = channel("hop", level, bs, {
    start  = sheet(BEAM .. "chain-beam-START", bs, {frames = 20, flags = ENDS}),
    ending = sheet(BEAM .. "chain-beam-END", bs, {frames = 20, flags = ENDS}),
    head = chain_body(1, bs),
    tail = chain_body(6, bs),
    body = bodies(chain_body, bs),
  })

  out[#out + 1] = explosion("impact", level, storm_anims(BURSTS, v.impact_scale), {
    light = {intensity = il.intensity, size = v.light_size, color = LT.light_color},
    light_intensity_factor_initial = 1,
    light_intensity_factor_final = 0,
    light_intensity_peak_start_progress = 0,
    light_intensity_peak_end_progress = il.peak_end,
    light_size_factor_initial = 1,
    light_size_factor_final = il.size_final,
    light_size_peak_start_progress = 0,
    light_size_peak_end_progress = il.peak_end,
    created_effect = camera(level, v.s),
  })

  out[#out + 1] = explosion("streamer", level, storm_anims(STREAMERS, v.streamer_scale))

  if LT.sky.enabled and level >= LT.sky.from_level then
    out[#out + 1] = sky(level)
  end
end

data:extend(out)
