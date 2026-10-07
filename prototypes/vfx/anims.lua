-- prototypes/vfx/anims.lua ---------------------------------------------------------
-- Animation tables for the detonation VFX, inlined from the base game's
-- `explosion_animations` lualib.
--
-- WHY INLINED RATHER THAN REQUIRED
-- `require("__base__.prototypes.entity.explosion-animations")` would work today,
-- but the project contract (FactorioMods/CLAUDE.md section 9) calls cross-mod
-- requires into base internals a silent-failure trap: it may resolve to a shared
-- cache entry carrying base's own relative requires, or re-execute the file in
-- our context and drag transitive dependencies with it. Every value below was
-- read out of
--   <install>/data/base/prototypes/entity/explosion-animations.lua
-- and is reproduced field for field, so the geometry is verified rather than
-- guessed. The .png paths still point at __base__, so this mod ships no art.
--
-- If any of these ever render wrong, diff against that file -- do not adjust by
-- eye.
--------------------------------------------------------------------------------------

local util = require("util")

local anims = {}

--- Frames a layer plays per cycle: its frame_sequence's length, else frame_count.
local function played(layer)
  return layer.frame_sequence and #layer.frame_sequence or (layer.frame_count or 1)
end

--- Shallow copy of an animation list with `edit` run on every leaf layer's copy.
-- CRITICAL: descend into `layers`; the engine ignores every field beside it.
local function each_layer(list, edit)
  local out = {}
  for i, layer in ipairs(list) do
    local copy = {}
    for k, v in pairs(layer) do copy[k] = v end
    if layer.layers then
      copy.layers = each_layer(layer.layers, edit)
    else
      edit(copy)
    end
    out[i] = copy
  end
  return out
end

--- Copy of an animation list with `tint` on every layer.
function anims.tinted(layers, tint)
  return each_layer(layers, function(copy) copy.tint = tint end)
end

--- Copy of an animation list whose every layer plays out in `ticks`, an explosion's lifetime.
function anims.retimed(layers, ticks)
  return each_layer(layers, function(copy)
    copy.animation_speed = played(copy) / math.max(1, ticks)
  end)
end

--- Each variation of `under` beneath every layer of `over`, one Animation apiece.
-- CRITICAL: all layers run at the first layer's speed, so each is resampled to over[1]'s length.
function anims.stacked(under, over)
  local n = played(over[1])
  local function resampled(layer)
    local len, src, seq = played(layer), layer.frame_sequence, {}
    for i = 0, n - 1 do
      local f = 1 + math.floor(i * (len - 1) / math.max(1, n - 1) + 0.5)
      seq[i + 1] = src and src[f] or f
    end
    local copy = {}
    for k, v in pairs(layer) do copy[k] = v end
    copy.frame_sequence = seq
    return copy
  end
  local out = {}
  for i, u in ipairs(under) do
    local layers = {resampled(u)}
    for _, o in ipairs(over) do layers[#layers + 1] = resampled(o) end
    out[i] = {layers = layers}
  end
  return out
end

--- The ring puff a shockwave dart stamps along its flight path.
-- Two variations, exactly as base's explosion_animations.nuke_shockwave().
function anims.shockwave()
  return {
    {
      filename = "__base__/graphics/entity/smoke/nuke-shockwave-1.png",
      draw_as_glow = true,
      priority = "high",
      flags = {"smoke"},
      line_length = 8,
      width = 132,
      height = 136,
      frame_count = 32,
      animation_speed = 0.5,
      shift = util.by_pixel(-0.5, 0),
      scale = 1.5,
      usage = "explosion",
    },
    {
      filename = "__base__/graphics/entity/smoke/nuke-shockwave-2.png",
      draw_as_glow = true,
      priority = "high",
      flags = {"smoke"},
      line_length = 8,
      width = 110,
      height = 128,
      frame_count = 32,
      animation_speed = 0.5,
      shift = util.by_pixel(0, 3),
      scale = 1.5,
      usage = "explosion",
    },
  }
end

--- Single-sheet big explosion. Note the non-obvious shift and line_length 6 --
--- 47 frames laid out 6 wide, not one long strip.
--- A ONE-FRAME animation held for `ticks`. Used by the sustained flash: an
--- explosion's light lasts exactly as long as its animation, so the only way to
--- hold a light open is to hold a frame open. animation_speed is frames/tick, so
--- 1/ticks plays a single frame across the whole duration.
function anims.hold(ticks)
  return {
    {
      filename = "__base__/graphics/entity/big-explosion/big-explosion.png",
      draw_as_glow = true,
      width = 197,
      height = 245,
      frame_count = 1,
      line_length = 1,
      shift = {0.1875, -0.75},
      animation_speed = 1 / ticks,
      usage = "explosion",
    },
  }
end

--- A BALL OF PLASMA, NOT A PUFF OF SMOKE.
--
-- WHY THIS EXISTS. The shock front was built out of anims.shockwave(), which is
-- base's `nuke-shockwave-1/2.png` -- and those are literally files under
-- graphics/entity/**smoke**/ carrying `flags = {"smoke"}`. 0.14.10 tinted them
-- hot on the argument that "the frames are the right SHAPE and Factorio's fire
-- sprites are vertical flames meant to be stood in, not travelled outward".
--
-- That argument was half right and the wrong half was load-bearing: tinting
-- smoke red produces RED SMOKE. Reported in exactly those words -- "ITS NOT A
-- RING OF FIRE. ITS RED SMOKE PARTICLES." A billowing grey cloud with a red
-- multiply on it does not become plasma, because what makes something read as
-- plasma is that it EMITS rather than scatters, and no tint adds emission to art
-- that was painted as a shadowed volume.
--
-- big-explosion IS a fireball -- white-hot core falling off to orange, already
-- painted as a light source. Forty of them overlapping along a front is a wall of
-- burning gas rather than a wall of coloured fog. It is also cheaper than the
-- alternatives: massive-explosion is 656x634 per frame against this one's
-- 197x245, which at 900 stamps a tick is the difference between a wave and a
-- stall.
--
-- Same GEOMETRY anims.big() uses for the detonation flash, deliberately: the
-- front should look like the same material as the thing that threw it.
--
-- THE SHEET IS THE MOD'S OWN GREYSCALE BAKE of that art (tools/make_wave_art.py
-- -> graphics/wave/plasma.png), same lesson as the lance: base's sheet averages
-- (48, 37, 25) over its opaque pixels -- orange-brown smoke around a small
-- white core -- and a tint multiplies, so the black-body colours the front is
-- now drawn at (C.blast.rings.wave.wall) could never have shown through it.
-- Alpha and frame layout are byte-identical to base's, so every shift and
-- scale below still applies.
--
-- THE ENVELOPE, and why this is not just anims.big() retimed. Measured per
-- frame (summed luminance x alpha, as a fraction of the peak):
--     frames  1- 4   0.21 0.50 0.67 0.86    rising
--     frames  5- 9   0.96 1.00 1.00 0.98 0.93    THE FIREBALL
--     frames 10-14   0.84 0.71 0.52 0.36 0.29    falling off
--     frames 15-40   0.13-0.24                   a long dim smoulder
--     frames 41-47   under 0.05                  gone
-- The clip is a BURST: one fifth of its length is bright and two thirds is
-- smoke at an eighth of the peak. Stamped as a sustained wall element and
-- retimed to 20-150 ticks, that meant four fifths of the puffs on screen at
-- any instant were on their smoulder frames -- the ring read as sparse dots
-- with a few bright ones, at every density the config could ask for. That is
-- the reported "weak" wave, and no stamp count fixes a duty cycle.
--
-- frame_sequence (AnimationParameters, 2.0.77 spec) plays the listed frames in
-- order, so the played clip is: the rise, the fireball frames HELD by
-- alternating between them (an alternation, not a freeze -- a frozen frame is
-- a sticker), a short fall-off, and a few smoulder frames as the tail. The
-- smoulder is still there, it is just no longer most of the puff's life.
-- Frames the sequence never names are not loaded into VRAM.
--
-- @param hold number|nil how many fireball-frame pairs to hold (default from
--        the caller; 8 pairs makes the bright part ~50% of the clip)
function anims.plasma(hold)
  hold = hold or 8
  local seq = {2, 3, 4}
  for _ = 1, hold do
    seq[#seq + 1] = 6
    seq[#seq + 1] = 7
    seq[#seq + 1] = 5
    seq[#seq + 1] = 8
  end
  for f = 9, 14 do seq[#seq + 1] = f end
  for _, f in ipairs({17, 22, 28, 34, 40}) do seq[#seq + 1] = f end
  return {
    {
      filename = "__oppenheimer-artillery-turret-forked__/graphics/wave/plasma.png",
      -- THE FIELD THAT DOES THE WORK. draw_as_glow composites additively, so
      -- overlapping stamps ADD instead of occluding each other -- which is what
      -- makes a dense ring read as one continuous hot mass rather than as a
      -- collage of separate sprites. The smoke art set this too, but on frames
      -- that had nothing to emit.
      draw_as_glow = true,
      priority = "high",
      width = 197,
      height = 245,
      frame_count = 47,
      line_length = 6,
      frame_sequence = seq,
      -- base's own shift for this sheet. NOT util.by_pixel -- it is already in
      -- tiles in explosion-animations.lua, and running it through by_pixel again
      -- would divide it by 32 and drop the fireball onto the floor.
      shift = {0.1875, -0.75},
      animation_speed = 0.5,
      usage = "explosion",
    },
  }
end

--- The plasma sheet's fireball band alone, `frames` long.
-- A collapsing shell is compressed on the way in, so it brightens: the rise and
-- smoulder frames anims.plasma wraps around the burst are a decay.
function anims.plasma_hot(frames)
  local band = {6, 7, 5, 8}
  local n = math.max(2, math.floor(frames or 8))
  local seq = {}
  for i = 1, n do seq[i] = band[(i - 1) % #band + 1] end
  return {
    {
      filename = "__oppenheimer-artillery-turret-forked__/graphics/wave/plasma.png",
      draw_as_glow = true,
      priority = "high",
      width = 197,
      height = 245,
      frame_count = 47,
      line_length = 6,
      frame_sequence = seq,
      shift = {0.1875, -0.75},
      animation_speed = 0.5,
      usage = "explosion",
    },
  }
end

--- THE FIRE RING'S FLAME, TINTABLE. Geometry field-for-field from base's
--- fire-flame-01 (the sheet N.scorch_flame's own `pictures` uses), pointed at
--- the mod's own greyscale bake of it.
--
-- WHY THE BAKE (tools/make_fire_art.py). Measured over the sheet's opaque
-- pixels base's art averages (139, 83, 37) -- green capped at 59% of any tint,
-- blue at 27%. The ring is now drawn at the black-body colour of the gas at
-- its own radius, the same lib/heat.lua ladder as the polygon wall it is
-- stamped on, and against that art a 20000 K tint could only ever come out
-- orange. Red confetti on a blue-white wall was that multiply, nothing else.
--
-- WHY A FRAME SEQUENCE. The sheet is 90 frames and the decal lives 15 ticks
-- (C.blast.rings.firewave.lifetime_ticks), so retiming the whole clip into
-- that window played six frames a tick -- a strobe, not a flame. This samples
-- `frames` frames evenly across the sheet instead, so retimed() lands on about
-- one frame per tick and the flame flickers. Frames the sequence never names
-- are not loaded into VRAM, which is most of the sheet.
--
-- @param frames number|nil how many frames to sample (default 15)
function anims.flame(frames)
  local total = 90
  local n = math.max(2, math.min(total, math.floor(frames or 15)))
  local seq = {}
  for i = 0, n - 1 do
    seq[#seq + 1] = 1 + math.floor(i * (total - 1) / (n - 1) + 0.5)
  end
  return {
    {
      filename = "__oppenheimer-artillery-turret-forked__/graphics/wave/flame.png",
      -- Additive, so a dense stretch of ring ADDS into one hot mass instead of
      -- a hundred sprites occluding each other -- the same reason anims.plasma
      -- sets it.
      draw_as_glow = true,
      priority = "high",
      line_length = 10,
      width = 84,
      height = 130,
      frame_count = total,
      frame_sequence = seq,
      shift = util.by_pixel(0, -16),
      usage = "explosion",
    },
  }
end

--- The same bake as `count` variations, each a contiguous `frames`-frame
--- window from its own point in the loop and drawn at its own size across
--- 1 -/+ `spread`, so flames laid together neither flicker in step nor match.
function anims.flame_windows(frames, count, spread)
  local total = 90
  local n = math.max(2, math.min(total, math.floor(frames)))
  count = math.max(1, math.floor(count or 1))
  spread = spread or 0
  local out = {}
  for v = 0, count - 1 do
    local start = math.floor(v * total / count)
    local seq = {}
    for i = 0, n - 1 do seq[i + 1] = (start + i) % total + 1 end
    local size = (count > 1) and (1 - spread + 2 * spread * v / (count - 1)) or 1
    out[v + 1] = {
      filename = "__oppenheimer-artillery-turret-forked__/graphics/wave/flame.png",
      draw_as_glow = true,
      priority = "high",
      line_length = 10,
      width = 84,
      height = 130,
      frame_count = total,
      frame_sequence = seq,
      scale = size,
      shift = util.by_pixel(0, -16 * size),
      usage = "explosion",
    }
  end
  return out
end

function anims.big()
  return {
    {
      filename = "__base__/graphics/entity/big-explosion/big-explosion.png",
      draw_as_glow = true,
      width = 197,
      height = 245,
      frame_count = 47,
      line_length = 6,
      shift = {0.1875, -0.75},
      animation_speed = 0.5,
      usage = "explosion",
    },
  }
end

--- The largest conventional explosion in the base game. Striped across two
--- files because a single sheet would be enormous.
function anims.massive(shift)
  shift = shift or {0, 0}
  return {
    width = 656,
    height = 634,
    frame_count = 57,
    shift = util.add_shift(util.by_pixel(-45, -91), shift),
    animation_speed = 0.5,
    scale = 0.5,
    allow_forced_downscale = true,
    draw_as_glow = true,
    stripes = {
      {
        filename = "__base__/graphics/entity/massive-explosion/massive-explosion-1.png",
        width_in_frames = 6,
        height_in_frames = 5,
      },
      {
        filename = "__base__/graphics/entity/massive-explosion/massive-explosion-2.png",
        width_in_frames = 6,
        height_in_frames = 5,
      },
    },
    usage = "explosion",
  }
end

--- THE MUSHROOM CLOUD ART. 100 frames, 628x720 each, striped across four files.
-- This is what vanilla's `nuke-explosion` entity draws, and it is already a
-- rising mushroom -- the cloud is painted into the animation. Base's comment on
-- the shift is worth keeping: the -122.5px vertical offset is "shifted by 60 due
-- to scaling and centering", i.e. it is what lifts the cap off the ground.
--
-- Backlog #91 stacks the prototype's own growth fields (scale_initial /
-- scale_end / scale_increment_per_tick / height) ON TOP of this, so the cap
-- swells beyond its authored size as it climbs.
function anims.mushroom()
  return {
    width = 628,
    height = 720,
    frame_count = 100,
    draw_as_glow = true,
    priority = "very-low",
    flags = {"linear-magnification"},
    shift = util.by_pixel(0.5, -122.5),
    animation_speed = 0.5 * 0.75,
    scale = 1,
    dice_y = 5,
    allow_forced_downscale = true,
    stripes = {
      {
        filename = "__base__/graphics/entity/nuke-explosion/nuke-explosion-1.png",
        width_in_frames = 5, height_in_frames = 5,
      },
      {
        filename = "__base__/graphics/entity/nuke-explosion/nuke-explosion-2.png",
        width_in_frames = 5, height_in_frames = 5,
      },
      {
        filename = "__base__/graphics/entity/nuke-explosion/nuke-explosion-3.png",
        width_in_frames = 5, height_in_frames = 5,
      },
      {
        filename = "__base__/graphics/entity/nuke-explosion/nuke-explosion-4.png",
        width_in_frames = 5, height_in_frames = 5,
      },
    },
    usage = "explosion",
  }
end

--- Medium explosion, three variations. Used for the cluster fan.
-- Each variation has DIFFERENT dimensions and shift -- they are not a series
-- with one shared geometry, so they are written out rather than generated.
function anims.medium()
  local function v(i, w, h, frames, sx, sy)
    return {
      filename = "__base__/graphics/entity/medium-explosion/medium-explosion-" .. i .. ".png",
      draw_as_glow = true,
      width = w,
      height = h,
      frame_count = frames,
      line_length = 6,
      shift = util.by_pixel(sx, sy),
      animation_speed = 0.5,
      usage = "explosion",
    }
  end
  return {
    v(1, 124, 224, 30, -1,   -36),
    v(2, 154, 212, 41, -13,  -34),
    v(3, 126, 236, 39,  0.5, -37),
  }
end

return anims
