-- scripts/groundfire.lua: the painted crater's fire, drawn as the ground's own
-- temperature (C.heat.ground) cooling after the front has crossed it.

local C       = require("config")
local N       = require("lib.names")
local events  = require("scripts.events")
local heat    = require("lib.heat")
local profile = require("scripts.profile")
local view    = require("scripts.view")
local crater  = require("scripts.crater")

local groundfire = {}

local TAU = 2 * math.pi

-- Derived from config on first use, identical on every client; never state.
local PEAK, TOP
local function peak()
  if not PEAK then
    PEAK = C.blast.rings.groundfire.kelvin(0)
    TOP  = heat.step_ceiling(PEAK)
  end
  return PEAK, TOP
end

local kelvin_at = heat.ground_kelvin

--- Outermost normalised radius inside u_max where any patch still glows; 0 when none does.
local function glow_extent(rec, now, u_max)
  local floor = C.heat.t_min
  local cap = 1 + C.heat.ground.patch_spread
  if kelvin_at(rec, 0, now, cap) < floor then return 0 end
  if kelvin_at(rec, u_max, now, cap) >= floor then return u_max end
  local lo, hi = 0, u_max
  for _ = 1, 16 do
    local mid = (lo + hi) * 0.5
    if kelvin_at(rec, mid, now, cap) >= floor then lo = mid else hi = mid end
  end
  return lo
end

--- Heat capacity of the patch under (x, y), 1 -/+ patch_spread: fixed per patch and per shot, so the same spots hold their heat pass after pass.
local function patch(rec, x, y)
  local s = C.blast.rings.groundfire.patch_tiles
  local v = math.sin(math.floor(x / s) * 12.9898 + math.floor(y / s) * 78.233 + rec.salt)
            * 43758.5453
  return 1 + C.heat.ground.patch_spread * (2 * (v - math.floor(v)) - 1)
end

--- One pass: flames at random points of the glowing ground, each at the heat step its point has cooled to, only where a player can see.
local function lay(rec, surface, now)
  local gf = C.blast.rings.groundfire
  local R  = rec.radius
  rec.glow_r = glow_extent(rec, now, rec.paint_r / R) * R
  local rg = rec.glow_r
  if rg < 1 then return end

  -- Sampling discs: the glowing disc when one view holds it, else each
  -- watcher's own view of it.
  local si   = surface.index
  local vr   = C.perf.view.radius
  local cull = C.perf.view.enabled
  local whole = (not cull) or rg <= vr
  local discs = {}
  if whole then
    if view.disc(si, rec.x, rec.y, rg) then discs = {rec.x, rec.y, rg} end
  else
    local w = view.watchers()
    local reach = (rg + vr) * (rg + vr)
    for i = 1, #w, 3 do
      local dx, dy = w[i + 1] - rec.x, w[i + 2] - rec.y
      if w[i] == si and dx * dx + dy * dy < reach then
        discs[#discs + 1] = w[i + 1]
        discs[#discs + 1] = w[i + 2]
        discs[#discs + 1] = vr
      end
    end
  end
  if #discs == 0 then return end

  local width    = gf.sprite_tiles * gf.scale_for(rec.variant)
  local per_tile = gf.coverage * gf.interval / (gf.life * width * width)
  local share    = gf.max_per_pass / (#discs / 3)
  local test     = cull and whole
  local _, top   = peak()
  local floor    = C.heat.t_min
  local rg2      = rg * rg
  local laid     = 0

  for d = 1, #discs, 3 do
    local cx, cy, rd = discs[d], discs[d + 1], discs[d + 2]
    local n = math.floor(math.min(share, per_tile * math.pi * rd * rd) + math.random())
    for _ = 1, n do
      local a  = math.random() * TAU
      local rr = rd * math.sqrt(math.random())
      local px, py = cx + math.cos(a) * rr, cy + math.sin(a) * rr
      local dx, dy = px - rec.x, py - rec.y
      local d2 = dx * dx + dy * dy
      if d2 <= rg2 and (not test or view.near(si, px, py, vr)) then
        local k = kelvin_at(rec, math.sqrt(d2) / R, now, patch(rec, px, py))
        local tile = (k >= floor) and surface.get_tile(px, py)
        if tile and (not tile.collides_with("water_tile") or crater.molten(tile.name)) then
          local hi = heat.step_dither(k, math.random())
          if hi > top then hi = top end
          surface.create_entity{
            name = N.ex_groundfire_for(rec.variant, hi),
            position = {px, py},
          }
          laid = laid + 1
        end
      end
    end
  end
  rec.laid = rec.laid + laid
  profile.count("ground fire: flames", laid)
end

--- The crater's light at ground zero, sized to the glowing radius, redrawn every tick.
local function light(rec, surface, now)
  local lt = C.blast.rings.groundfire.light
  local rg = rec.glow_r
  if not (lt.enabled and rg >= 1) then return end
  if not view.disc(surface.index, rec.x, rec.y, rg) then return end
  local k = kelvin_at(rec, 0, now, 1)
  if k < C.heat.t_min then return end
  local scale = rg * lt.scale_per_r
  if scale < lt.scale_min then scale = lt.scale_min end
  if scale > lt.scale_max then scale = lt.scale_max end
  local c  = heat.rgb(k)
  local pk = peak()
  rendering.draw_light{
    sprite = lt.sprite, surface = surface, target = {rec.x, rec.y},
    color = {r = c.r, g = c.g, b = c.b, a = 1},
    intensity = lt.intensity * heat.glow(k, pk), scale = scale,
    time_to_live = 2,
  }
end

--- Start a crater's fire under a sweep of a `kt` kilotonne device; the sweep writes paint_r into the record as its paint spreads.
function groundfire.begin(surface, pos, radius, started, ticks, variant, kt)
  local gf = C.blast.rings.groundfire
  if not (gf.enabled and surface and surface.valid and radius > 0) then return nil end
  local rec = {
    surface = surface.index,
    x = pos.x, y = pos.y,
    radius  = radius,
    started = started,
    ticks   = ticks,
    variant = variant or 1,
    hold    = heat.glaze_start(ticks),
    glaze   = heat.glaze_mm(kt),
    salt    = math.random() * 1000,
    paint_r = 0,
    glow_r  = 0,
    laid    = 0,
  }
  local deepest = heat.glaze_at(rec.glaze, 0) * (1 + C.heat.ground.patch_spread)
  rec.ends = math.max(rec.hold + 60 * heat.glaze_seconds(deepest, C.heat.t_min),
                      ticks + 60 * heat.skin_seconds(C.heat.t_min)) + gf.life
  local list = storage.groundfires
  list[#list + 1] = rec
  return rec
end

local function step()
  local list = storage.groundfires
  if not list or #list == 0 then return end
  local interval = C.blast.rings.groundfire.interval
  profile.start("ground fire (total)")
  for i = #list, 1, -1 do
    local rec = list[i]
    local now = game.tick - rec.started
    repeat
      if now < 0 then break end
      local surface = game.get_surface(rec.surface)
      if not (surface and surface.valid) or now > rec.ends then
        table.remove(list, i)
        break
      end
      if now % interval == 0 then
        lay(rec, surface, now)
        if rec.paint_r >= 1 and rec.glow_r < 1 and now > rec.hold then
          table.remove(list, i)
          break
        end
      end
      light(rec, surface, now)
    until true
  end
  profile.stop("ground fire (total)")
end

events.on_nth_tick(1, step)

return groundfire
