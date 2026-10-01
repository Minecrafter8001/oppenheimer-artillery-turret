-- scripts/lightning.lua: the charging sphere's lightning (C.beam.sphere.lightning), run once a tick per strike group by scripts/beam.lua.
-- State lives on the group (g.storm) and ends with it. With Space Age a strike is drawn with prototypes/vfx/lightning.lua; without it, with render lines.

local C       = require("config")
local N       = require("lib.names")
local audio   = require("scripts.audio")
local mapdraw = require("scripts.mapdraw")
local view    = require("scripts.view")
local slay    = require("scripts.slay")

local lightning = {}

local LT  = C.beam.sphere.lightning
local TAU = 2 * math.pi
local AUTHORED = 0.5   -- the sprite scale LT.scale and LT.branch_scale are measured against

-- Each level's figures, from config alone.
local LEVEL = {}
for level = LT.min_level, LT.max_level do LEVEL[level] = C.lightning_level(level) end

local function clamp(x, lo, hi)
  if x < lo then return lo elseif x > hi then return hi end
  return x
end

-- Whether the Space Age prototypes were built. Fixed for the session, so the same on every peer.
local art
local function has_art()
  if art == nil then art = prototypes.entity[N.lightning("bolt", LT.min_level)] ~= nil end
  return art
end

--- The shot's progress through its sustain, 0..1.
local function progress(g)
  return clamp((game.tick - g.at) / math.max(1, g.cut_at - g.at), 0, 1)
end

--- A strike level, weighted ratio^(level - min_level).
local function roll_level(g)
  local tilt = LT.wild_sustain * progress(g)
             + LT.wild_overpower * C.overpower_u(g.omega_group or 1, LT.overpower_exponent)
  local ratio = LT.ratio_calm + (LT.ratio_wild - LT.ratio_calm) * math.min(1, tilt)
  local total, w = 0, 1
  for _ = LT.min_level, LT.max_level do
    total = total + w
    w = w * ratio
  end
  local pick, level = math.random() * total, LT.min_level
  w = 1
  while level < LT.max_level do
    pick = pick - w
    if pick <= 0 then break end
    level = level + 1
    w = w * ratio
  end
  return level
end

--- Ticks to the next strike: exponential, at the rim's current rate.
local function gap(radius)
  local per_s = math.min(LT.rate_max, LT.rate_base + TAU * radius / LT.rim_tiles_per_rate)
  local u = math.max(math.random(), 1e-6)
  return math.max(1, math.floor(-math.log(u) * 60 / per_s + 0.5))
end

--- A bearing on the rim: watched_share of the time on rim a player can see, otherwise anywhere.
local function bearing(si, g, radius, reach)
  if math.random() < LT.watched_share then
    local arcs = view.arcs(si, g.to.x, g.to.y, radius, radius + reach)
    if arcs and arcs ~= true and #arcs > 0 then
      local i = 2 * math.random(math.floor(#arcs / 2)) - 1
      return arcs[i] + (math.random() * 2 - 1) * arcs[i + 1]
    end
  end
  return math.random() * TAU
end

--- A channel's shape apart from its ends: an offset across it at each inner vertex (x segment length) and a bend (x length).
local function new_shape(segs)
  local offs = {}
  for i = 1, segs - 1 do offs[i] = (math.random() * 2 - 1) * LT.jitter end
  return {offs = offs, bow = (math.random() * 2 - 1) * LT.bow}
end

--- The shape's points from (x0, y0) to (x1, y1), and its length; nil if the ends meet.
local function trace(shape, x0, y0, x1, y1)
  local dx, dy = x1 - x0, y1 - y0
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.5 then return nil end
  local px, py = -dy / len, dx / len
  local n = #shape.offs + 1
  local pts = {{x0, y0}}
  for i = 1, n - 1 do
    local t = i / n
    local off = shape.offs[i] * len / n + shape.bow * len * math.sin(math.pi * t)
    pts[i + 1] = {x0 + dx * t + px * off, y0 + dy * t + py * off}
  end
  pts[n + 1] = {x1, y1}
  return pts, len
end

--- Dead branches off inner vertices 2..segs of a channel.
local function new_forks(count, segs)
  local out = {}
  local fr, fa = LT.fork_reach, LT.fork_angle
  for i = 1, count do
    out[i] = {
      at = math.random(2, segs),
      turn = (math.random() < 0.5 and -1 or 1) * (fa.min + math.random() * (fa.max - fa.min)),
      len = fr.min + math.random() * (fr.max - fr.min),
      shape = new_shape(math.random(2, LT.fork_segments_max)),
    }
  end
  return out
end

--- Where strike `s` leaves a ball of `radius`.
local function root_of(s, g, radius)
  local r = math.max(0, radius - LT.root_inset)
  return g.to.x + math.cos(s.bearing) * r, g.to.y + math.sin(s.bearing) * r
end

--- Where strike `s` lands `out` tiles past a rim of `radius`.
local function land_of(s, g, radius, out)
  local a = s.bearing + s.lean
  return g.to.x + math.cos(s.bearing) * radius + math.cos(a) * out,
         g.to.y + math.sin(s.bearing) * radius + math.sin(a) * out
end

local function dose(level, g)
  return C.blast.dose.lethal_dose * LEVEL[level].dose
         * C.overpower_gain(g.omega_group or 1, LT.dose_overpower_max, LT.overpower_exponent)
end

--- The nearest thing within `r` of (x, y) a strike may hit and has not, or nil.
local function nearest(surface, x, y, r, ctx, hit)
  local found = surface.find_entities_filtered{
    position = {x, y}, radius = r, type = LT.types, limit = LT.probe_limit,
  }
  local best, best_d
  for i = 1, #found do
    local v = found[i]
    if v.valid and v.health and v.health > 0 and not ctx.spared(v, ctx.e, ctx.fname) then
      local id = v.unit_number
      if not (id and hit[id]) then
        local p = v.position
        local d = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)
        if not best_d or d < best_d then best, best_d = v, d end
      end
    end
  end
  return best
end

--- Settle what strike `s` lands on: the first probe that finds a target, else the planned ground.
local function acquire(s, g, surface, radius, ctx)
  local seek = LEVEL[s.level].seek
  for _, k in ipairs(LT.probes) do
    local x, y = land_of(s, g, radius, math.min(s.out * k, s.reach))
    local t = nearest(surface, x, y, seek, ctx, s.hit)
    if t then
      local p = t.position
      s.victim, s.tx, s.ty = t, p.x, p.y
      return
    end
  end
  s.tx, s.ty = land_of(s, g, radius, s.out)
end

local function hit(v, amount, ctx, g)
  slay.hit(v, amount, ctx.force, LT.damage_type, ctx.src, ctx.src)
  g.struck = (g.struck or 0) + 1
end

local function beam(surface, name, a, b, ticks)
  surface.create_entity{
    name = name, position = a, source_position = a, target_position = b, duration = ticks,
  }
end

local function light(surface, x, y, tiles, intensity, ticks)
  rendering.draw_light{
    sprite = "utility/light_medium", surface = surface, target = {x, y},
    color = LT.light_color, intensity = intensity, scale = tiles / LT.light_sprite_tiles,
    time_to_live = ticks,
  }
end

--- The main channel for `ticks`. A return stroke draws only the hot core over what is still burning.
local function channel(s, surface, ticks, restroke)
  if not s.seen then return end
  local pts = s.pts
  if has_art() then
    local name = N.lightning("bolt", s.level)
    for i = 2, #pts do beam(surface, name, pts[i - 1], pts[i], ticks) end
    return
  end
  local k = LEVEL[s.level].scale / AUTHORED
  for i = 2, #pts do
    if not restroke then
      rendering.draw_line{color = LT.halo_color, width = LT.halo_width * k,
        from = pts[i - 1], to = pts[i], surface = surface, time_to_live = ticks}
    end
    rendering.draw_line{color = LT.core_color, width = LT.core_width * k,
      from = pts[i - 1], to = pts[i], surface = surface, time_to_live = ticks}
  end
end

local function forks(s, surface)
  if not s.seen then return end
  local v, pts = LEVEL[s.level], s.pts
  local ticks = math.max(2, math.floor(v.stroke_ticks * LT.fork_life + 0.5))
  local name = has_art() and N.lightning("fork", s.level) or nil
  local width = LT.core_width * v.branch_scale / AUTHORED
  for _, f in ipairs(s.forks) do
    local a, p0 = pts[f.at], pts[f.at - 1]
    if a and p0 then
      local dx, dy = a[1] - p0[1], a[2] - p0[2]
      local l = math.sqrt(dx * dx + dy * dy)
      if l > 1e-6 then
        local ux, uy = dx / l, dy / l
        local c, sn = math.cos(f.turn), math.sin(f.turn)
        local flen = f.len * s.len
        local fpts = trace(f.shape, a[1], a[2],
                           a[1] + (ux * c - uy * sn) * flen, a[2] + (ux * sn + uy * c) * flen)
        if fpts then
          for i = 2, #fpts do
            if name then
              beam(surface, name, fpts[i - 1], fpts[i], ticks)
            else
              rendering.draw_line{color = LT.core_color, width = width,
                from = fpts[i - 1], to = fpts[i], surface = surface, time_to_live = ticks}
            end
          end
        end
      end
    end
  end
end

--- The flash where the channel lands and at its root; `intensity` is 1 for the first stroke.
local function pulse(s, surface, intensity)
  if not s.seen then return end
  local v = LEVEL[s.level]
  light(surface, s.tx, s.ty, v.light_size, intensity, LT.restroke_ticks)
  local root = s.pts[1]
  light(surface, root[1], root[2], v.light_size * 0.5, intensity, LT.restroke_ticks)
end

local function impact(s, surface)
  if not s.seen then return end
  local v = LEVEL[s.level]
  if has_art() then
    surface.create_entity{name = N.lightning("impact", s.level), position = {s.tx, s.ty}}
    surface.create_entity{name = N.lightning("streamer", s.level), position = {s.tx, s.ty}}
    return
  end
  rendering.draw_circle{color = LT.core_color, radius = LT.flash_tiles * v.impact_scale,
    filled = true, target = {s.tx, s.ty}, surface = surface, time_to_live = LT.restroke_ticks}
end

--- The channel on the map, one straight line: the jag is below a pixel at chart zoom.
local function chart(s, surface, ticks)
  local root = s.pts[1]
  mapdraw.line({color = LT.core_color, width = LT.core_width, from = root, to = {s.tx, s.ty},
                surface = surface, time_to_live = ticks}, {chart_only = true})
end

--- The leader crawling out toward the landing point, and in its last stretch a streamer rising to meet it.
local function leader(s, g, surface, radius)
  local rx, ry = root_of(s, g, radius)
  local lx, ly = land_of(s, g, radius, s.out)
  if not view.near(surface.index, (rx + lx) / 2, (ry + ly) / 2, C.perf.view.radius + s.out) then
    return
  end
  local pts = trace(s.shape, rx, ry, lx, ly)
  if not pts then return end
  local f = (game.tick - s.lead_at + 1) / math.max(1, s.t0 - s.lead_at)
  local n = #pts - 1
  local reach = f * n
  local col, w = LT.leader_color, LT.leader_width
  local tip = pts[1]
  for i = 1, n do
    local part = reach - (i - 1)
    if part <= 0 then break end
    local a, b = pts[i], pts[i + 1]
    local k = math.min(1, part)
    tip = {a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k}
    rendering.draw_line{color = col, width = w, from = a, to = tip, surface = surface, time_to_live = 2}
  end
  light(surface, tip[1], tip[2], LT.leader_light.tiles, LT.leader_light.intensity, 2)
  local up = (f - (1 - LT.streamer_share)) / LT.streamer_share
  if up > 0 then
    local a, b = pts[n + 1], pts[n]
    local k = math.min(1, up) * LT.streamer_reach
    rendering.draw_line{color = col, width = w, from = a,
      to = {a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k},
      surface = surface, time_to_live = 2}
  end
end

--- Space Age's storm bolt, timed so its strike lands on the flash.
local function sky_bolt(s, surface)
  if not view.near(surface.index, s.tx, s.ty, C.perf.view.radius) then return end
  local name = N.lightning("sky", s.level)
  pcall(function() surface.execute_lightning{name = name, position = {s.tx, s.ty}} end)
end

--- The strike's thunder, `lead` ticks ahead of its flash so the crack lands on it.
local function thunder(s, st, g, surface, radius)
  local now, level = game.tick, s.level
  local v = LEVEL[level]
  local voices = st.voices
  local top = 0
  for i = #voices, 1, -1 do
    if voices[i].till <= now then
      table.remove(voices, i)
    elseif voices[i].level > top then
      top = voices[i].level
    end
  end
  local volume = v.volume
  if #voices >= LT.max_voices and level <= top then
    volume = volume * LT.masked_volume
  else
    voices[#voices + 1] = {till = now + LT.thunder[level].loud, level = level}
  end
  local left = g.cut_at - now
  if left < LT.duck_ticks then
    local k = math.max(0, left) / LT.duck_ticks
    volume = volume * (LT.duck_floor + (1 - LT.duck_floor) * k)
  end
  local x, y = land_of(s, g, radius, s.out)
  audio.broadcast(surface, {x = x, y = y}, N.sound.thunder[level], {
    volume = volume, max_distance = v.hear, full_distance = v.hear_full,
  })
end

--- The return stroke: the channel, forks, impact, and the first victim.
local function flash(s, g, surface, radius, ctx)
  s.flashed = true
  if not s.tx then acquire(s, g, surface, radius, ctx) end
  local victim = s.victim
  s.victim = nil
  if victim and victim.valid then
    local p = victim.position
    s.tx, s.ty = p.x, p.y
  else
    victim = nil
  end
  local rx, ry = root_of(s, g, radius)
  local pts, len = trace(s.shape, rx, ry, s.tx, s.ty)
  if not pts then return end
  s.pts, s.len = pts, len
  s.seen = view.near(surface.index, (rx + s.tx) / 2, (ry + s.ty) / 2, C.perf.view.radius + len / 2)

  local v = LEVEL[s.level]
  channel(s, surface, v.stroke_ticks, false)
  forks(s, surface)
  impact(s, surface)
  pulse(s, surface, 1)
  chart(s, surface, v.stroke_ticks)

  if victim then
    local id = victim.unit_number
    if id then s.hit[id] = true end
    s.victims = 1
    local amount = dose(s.level, g)
    hit(victim, amount, ctx, g)
    s.heads = {{s.tx, s.ty, amount}}
    s.hop_at = game.tick + LT.jump_delay
  end
end

local function draw_hop(s, surface, x0, y0, x1, y1)
  if not view.near(surface.index, x1, y1, C.perf.view.radius) then return end
  local v = LEVEL[s.level]
  if has_art() then
    beam(surface, N.lightning("hop", s.level), {x0, y0}, {x1, y1}, LT.hop_ticks)
    surface.create_entity{name = N.lightning("streamer", s.level), position = {x1, y1}}
  else
    rendering.draw_line{color = LT.core_color, width = LT.core_width * v.branch_scale / AUTHORED,
      from = {x0, y0}, to = {x1, y1}, surface = surface, time_to_live = LT.hop_ticks}
  end
  light(surface, x1, y1, v.light_size * 0.3, 1, LT.hop_ticks)
end

--- One jump down the chain from every live head; a head splits with the level's fork_chance.
local function hop(s, g, surface, ctx)
  local v = LEVEL[s.level]
  local heads = {}
  for _, h in ipairs(s.heads) do
    local splits = (math.random() < v.fork_chance) and 2 or 1
    for _ = 1, splits do
      if s.victims >= v.targets then break end
      local t = nearest(surface, h[1], h[2], v.jump, ctx, s.hit)
      if not t then break end
      local p = t.position
      local id = t.unit_number
      if id then s.hit[id] = true end
      s.victims = s.victims + 1
      local amount = h[3] * LT.hop_falloff
      draw_hop(s, surface, h[1], h[2], p.x, p.y)
      hit(t, amount, ctx, g)
      heads[#heads + 1] = {p.x, p.y, amount}
    end
  end
  s.heads = heads
  s.hop_at = (#heads > 0 and s.victims < v.targets) and (game.tick + LT.jump_delay) or nil
end

--- Plan the next strike: its level, where it lands, and when its thunder, sky bolt, flash and return strokes fall.
local function decide(st, g, surface, radius)
  local level = roll_level(g)
  local v = LEVEL[level]
  local th = LT.thunder[level]
  local reach = v.reach * clamp(math.sqrt(radius / LT.reach_ref_radius), LT.reach_floor, 1)
  local out = reach * (LT.reach_min_share + (1 - LT.reach_min_share) * math.random())
  local segs = clamp(math.floor(out / LT.segment_tiles + 0.5), LT.segments_min, LT.segments_max)
  local lead = math.max(th.lead, LT.leader_min)
  local now = game.tick
  local t0 = math.max(now + lead, st.last_flash + LT.gap_min)
  st.last_flash = t0

  local s = {
    level = level, reach = reach, out = out,
    bearing = bearing(surface.index, g, radius, reach),
    lean = (math.random() * 2 - 1) * LT.slant,
    shape = new_shape(segs),
    forks = new_forks(v.forks, segs),
    t0 = t0, lead_at = t0 - lead, sound_at = t0 - th.lead,
    hit = {}, victims = 0,
  }
  local sk = LT.sky
  if sk.enabled and level >= sk.from_level and has_art() then
    s.sky_at = math.max(now, t0 - sk.time_to_damage)
  end
  local strokes, t = {}, t0
  for _ = 2, v.strokes do
    t = t + math.random(LT.restroke_gap_min, LT.restroke_gap_max)
    strokes[#strokes + 1] = t
  end
  s.strokes = strokes
  st.live[#st.live + 1] = s
  st.next_at = now + gap(radius) + math.floor(math.min(LT.hold_max, LT.hold_fraction * th.loud))
end

--- Advance one strike a tick. True once it has nothing left to do.
local function step(s, st, g, surface, radius, ctx)
  local now = game.tick
  if s.sound_at and now >= s.sound_at then
    s.sound_at = nil
    thunder(s, st, g, surface, radius)
  end
  if s.sky_at and now >= s.sky_at then
    s.sky_at = nil
    acquire(s, g, surface, radius, ctx)
    sky_bolt(s, surface)
  end
  if not s.flashed then
    if now >= s.t0 then
      flash(s, g, surface, radius, ctx)
    elseif now >= s.lead_at then
      leader(s, g, surface, radius)
    end
    return false
  end
  if s.pts and s.strokes[1] and now >= s.strokes[1] then
    table.remove(s.strokes, 1)
    channel(s, surface, LT.restroke_ticks, true)
    pulse(s, surface, LT.restroke_light)
  end
  if s.hop_at and now >= s.hop_at then hop(s, g, surface, ctx) end
  return not ((s.pts and s.strokes[1]) or s.hop_at or s.sound_at or s.sky_at)
end

--- One tick of group `g`'s lightning around a ball of `radius`. `spared` is scripts/beam.lua's friendly-fire test; `grow` false runs strikes already under way and starts none.
function lightning.tick(g, surface, radius, e, spared, grow)
  if not LT.enabled then return end
  local st = g.storm
  if not st then
    st = {next_at = game.tick, last_flash = 0, voices = {}, live = {}}
    g.storm = st
  end
  local live = e and e.valid
  local ctx = {
    e = live and e or nil,
    force = live and e.force or C.blast.rings.default_force,
    fname = live and e.force.name or nil,
    src = live and e or nil,
    spared = spared,
  }
  if grow and radius >= LT.min_radius and game.tick >= st.next_at then
    decide(st, g, surface, radius)
  end
  local strikes = st.live
  for i = #strikes, 1, -1 do
    if step(strikes[i], st, g, surface, radius, ctx) then table.remove(strikes, i) end
  end
end

return lightning
