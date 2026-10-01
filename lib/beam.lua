-- lib/beam: lance beam prototypes, derived to avoid hand-tuning scale and segment length.

local util = require("util")

local beam = {}

-- Source art: base laser turret and lance sprite sheets.
local ART = {
  path         = "__base__/graphics/entity/laser-turret/",
  -- The greyscale bake of laser-body.png / laser-end.png. Same sheet layout
  -- (body_px/body_h/body_frames/end_w/end_h below describe both).
  hot_path     = "__oppenheimer-artillery-turret__/graphics/lance/",
  base_scale   = 0.5,    -- what base renders this art at
  body_px      = 64,     -- laser-body.png width; 32 px = 1 tile
  body_h       = 12,
  body_frames  = 8,
  end_w        = 110,    -- laser-end.png
  end_h        = 62,
  end_shift_px = {11.5, 1},
  ground_px    = 256,
  ground_body_w = 64,
}

local PX_PER_TILE = 32

local function shift_ratio(scale) return scale / ART.base_scale end

function beam.segment_length(scale)
  return ART.body_px * scale / PX_PER_TILE
end

function beam.body_thickness(scale)
  return ART.body_h * scale / PX_PER_TILE
end

--- Tiles along the beam the end-cap sprite covers at `scale`.
function beam.end_length(scale)
  return ART.end_w * scale / PX_PER_TILE
end

--- One layer of the visible beam: the hot sprite plus its light twin.
local function body_layers(scale, tint, light_tint, blend)
  return {
    {
      filename       = ART.hot_path .. "lance-body.png",
      line_length    = ART.body_frames,
      width          = ART.body_px,
      height         = ART.body_h,
      frame_count    = ART.body_frames,
      scale          = scale,
      animation_speed = 0.5,
      tint           = tint,
      blend_mode     = blend,
    },
    {
      filename       = ART.path .. "laser-body-light.png",
      draw_as_light  = true,
      flags          = {"light"},
      line_length    = ART.body_frames,
      width          = ART.body_px,
      height         = ART.body_h,
      frame_count    = ART.body_frames,
      scale          = scale,
      animation_speed = 0.5,
      tint           = light_tint,
    },
  }
end

local function tail_layers(scale, tint, light_tint, blend)
  local r = shift_ratio(scale)
  local sx, sy = ART.end_shift_px[1] * r, ART.end_shift_px[2] * r
  return {
    {
      filename       = ART.hot_path .. "lance-end.png",
      width          = ART.end_w,
      height         = ART.end_h,
      frame_count    = ART.body_frames,
      shift          = util.by_pixel(sx, sy),
      scale          = scale,
      animation_speed = 0.5,
      tint           = tint,
      blend_mode     = blend,
    },
    {
      filename       = ART.path .. "laser-end-light.png",
      draw_as_light  = true,
      flags          = {"light"},
      width          = ART.end_w,
      height         = ART.end_h,
      frame_count    = ART.body_frames,
      shift          = util.by_pixel(sx, sy),
      scale          = scale,
      animation_speed = 0.5,
      tint           = light_tint,
    },
  }
end

local function ground_set(scale, tint, kind, head_disc)
  local r = shift_ratio(scale)
  local off = 32 * r     -- base shifts the head/tail pools +/- 32 px
  local common = {
    draw_as_light = true,
    flags         = {"light"},
    line_length   = 1,
    repeat_count  = ART.body_frames,
    scale         = scale,
    animation_speed = 0.5,
    tint          = tint,
  }
  local function pool(file, w, h, shift_px)
    local t = {filename = ART.path .. file, width = w, height = h}
    for k, v in pairs(common) do t[k] = v end
    if shift_px then t.shift = util.by_pixel(shift_px, 0) end
    return t
  end
  local function strip() return pool("laser-ground-light-body.png", ART.ground_body_w, ART.ground_px, nil) end
  local mid = kind == "mid"
  return {
    head = (mid or not head_disc)
           and strip() or pool("laser-ground-light-head.png", ART.ground_px, ART.ground_px, -off),
    tail = mid and strip() or pool("laser-ground-light-tail.png", ART.ground_px, ART.ground_px, off),
    body = strip(),
  }
end

--- Build one beam prototype. Carries no action; damage is done by scripts/beam.lua.
function beam.lance(o)
  local scale = o.scale
  local blend = o.blend or "additive"
  return {
    type   = "beam",
    name   = o.name,
    localised_name = o.localised_name,
    flags  = {"not-on-map"},
    hidden = true,

    width           = o.width,
    damage_interval = 60,
    action_triggered_automatically = false,
    random_target_offset = false,

    graphics_set = {
      desired_segment_length = beam.segment_length(scale),
      randomize_animation_per_segment = true,
      beam = {
        head = {layers = body_layers(scale, o.tint, o.light_tint, blend)},
        body = {{layers = body_layers(scale, o.tint, o.light_tint, blend)}},
        tail = {layers = o.kind == "mid" and body_layers(scale, o.tint, o.light_tint, blend)
                                             or tail_layers(scale, o.tint, o.light_tint, blend)},
      },
      ground = o.ground_scale
               and ground_set(o.ground_scale, o.light_tint, o.kind, o.head_disc) or nil,
    },
  }
end

return beam
