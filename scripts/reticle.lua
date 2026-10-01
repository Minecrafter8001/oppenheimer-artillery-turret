-- scripts/reticle.lua ---------------------------------------------------------------
-- The pad's script-drawn moments. The floor is C.foundation /
-- scripts/placement.lua; this is what happens ON it.
--
--   COMMISSION  last bank + mast linked: masts light in turn, the conduit ring
--               draws itself round the loop, each spur appearing as it passes
--   AIM         a dim line from the gun to the rim, swinging with the barrel
--   CHARGE      bulbs run round the firing ring, spinning up with the charge
--   CONVERGE    the bulbs race to where the aim line crosses the ring, then
--               stream down it into the barrel, landing on the discharge
--   STRIKE      the stage flashes white and keeps one more scorch mark
--
-- STATE: storage.reticle[unit_number] (scripts/schema.lua). Most objects here
-- target POSITIONS (they move), so they do not die with the gun --
-- schema.forget_turret destroys them. The commission record stores mast
-- UNIT NUMBERS, never entities, so nothing in the bag is ever an entity.
--
-- Driven every tick from scripts/turret.lua's loop, which passes the state
-- tests in (render.preview's pattern: requiring turret.lua back is a cycle).
-- A turret with nothing running costs one table lookup.
--------------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local render = require("scripts.render")
local view   = require("scripts.view")

local reticle = {}

local R   = C.reticle
local TAU = 2 * math.pi
-- Clockwise from the upper-left, the order the eye reads a square in.
local START = 0.875

-- =============================================================================
-- Helpers
-- =============================================================================

local function is_obj(o)
  local t = type(o)
  return (t == "table" or t == "userdata") and o.valid == true
end

local function kill(o) if is_obj(o) then o.destroy() end end

local function kill_list(list)
  if list then for _, o in pairs(list) do kill(o) end end
end

--- A point at orientation `o` (0 = north, clockwise) and radius `r` from `c`.
local function at(c, o, r)
  local a = o * TAU
  return {x = c.x + r * math.sin(a), y = c.y - r * math.cos(a)}
end

local function orientation_of(dx, dy)
  local atan2 = math.atan2 or math.atan
  local o = atan2(dx, -dy) / TAU
  if o < 0 then o = o + 1 end
  return o
end

local function bag_for(un)
  local b = storage.reticle[un]
  if not b then
    b = {}
    storage.reticle[un] = b
  end
  return b
end

local function target_bearing(rec)
  local t, p = rec.designated, rec.entity.position
  if not t then return 0 end
  return orientation_of(t.x - p.x, t.y - p.y)
end

--- Where the barrel points now. The same pcall'd read scripts/beam.lua makes
--- (class-gated reads can throw on this chassis); the designation's bearing
--- when it cannot be read.
local function barrel_bearing(rec)
  if not storage.no_orientation then
    local e = rec.entity
    local ok, o = pcall(function() return e.orientation end)
    if ok and type(o) == "number" then return o end
  end
  return target_bearing(rec)
end

local function converge_at()
  local cv = R.converge
  return C.sound.discharge_at - cv.ring_ticks - cv.line_ticks
end

-- =============================================================================
-- AIM: the line
-- =============================================================================

local function aim_line(rec, bag, hot)
  local a = R.aim_line
  local e = rec.entity
  local c = e.position
  local o = barrel_bearing(rec)
  local r0 = C.turret.tile_size / 2 + a.clearance
  local r1 = C.foundation_reach() + 0.5

  if not is_obj(bag.aim) then
    bag.aim = rendering.draw_line{
      color = a.color, width = a.width,
      dash_length = a.dash_length, gap_length = a.gap_length,
      from = at(c, o, r0), to = at(c, o, r1),
      surface = e.surface, draw_on_ground = true,
    }
    bag.aim_o, bag.aim_hot = o, false
  elseif math.abs(o - (bag.aim_o or -1)) > 1e-5 then
    bag.aim.from = at(c, o, r0)
    bag.aim.to   = at(c, o, r1)
    bag.aim_o = o
  end

  if hot ~= bag.aim_hot then
    bag.aim.color = hot and a.hot_color or a.color
    bag.aim_hot = hot
  end
end

local function drop_aim(bag)
  kill(bag.aim)
  bag.aim, bag.aim_o, bag.aim_hot = nil, nil, nil
end

-- =============================================================================
-- THE STORAGE RING: bunches circulating while the banks fill, kicked out
-- along the beam line on the last lap before the strike.
--
-- The physics and why it replaced a turbine spin-up are in C.reticle.chase's
-- own header. What matters here: ONE orbital speed for the whole ring (a beam
-- does not have per-particle speeds), saturating with gamma; bunch tightness
-- climbing with gamma; and extraction happening per bunch AS IT PASSES the
-- kicker, not as a race toward it.
-- =============================================================================

local function drop_chase(bag)
  kill_list(bag.bulbs)
  kill_list(bag.glows)
  bag.bulbs, bag.glows, bag.phase, bag.conv = nil, nil, nil, nil
end

local function paint(o, pos, col, alpha)
  if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end
  o.target = pos
  o.color = {r = col.r, g = col.g, b = col.b, a = alpha}
end

local function mix(a, b, u)
  if u < 0 then u = 0 elseif u > 1 then u = 1 end
  return {r = a.r + (b.r - a.r) * u,
          g = a.g + (b.g - a.g) * u,
          b = a.b + (b.b - a.b) * u}
end

--- The beam's Lorentz factor and speed at charge fraction `unit`.
-- gamma runs 1 -> gamma_max with the charge; beta = sqrt(1 - 1/gamma^2) is
-- what the eye sees, and it is flat over most of that range on purpose.
-- @return beta (0..1), and the energy fraction (gamma - 1)/(gamma_max - 1)
local function beam_state(unit)
  local ch = R.chase
  local gmax = ch.gamma_max
  local gamma = 1 + (gmax - 1) * unit
  local beta = math.sqrt(math.max(0, 1 - 1 / (gamma * gamma)))
  return beta, (gmax > 1) and ((gamma - 1) / (gmax - 1)) or 0
end

local function chase(rec, bag, elapsed)
  local ch, cv = R.chase, R.converge
  local e = rec.entity
  local c = e.position
  local n = ch.count
  local ring_r = C.firing_ring_radius()

  if not bag.bulbs then
    bag.bulbs, bag.glows, bag.phase = {}, {}, 0
    for i = 1, n do
      bag.bulbs[i] = rendering.draw_circle{
        color = {r = 0, g = 0, b = 0, a = 0}, radius = ch.bulb_radius,
        filled = true, target = c, surface = e.surface, draw_on_ground = true,
      }
    end
    for k = 1, ch.packs do
      bag.glows[k] = rendering.draw_light{
        sprite = "utility/light_medium", scale = ch.light_scale, intensity = 0,
        color = ch.color, target = c, surface = e.surface,
      }
    end
  end
  -- Unwatched, the ring holds still; nobody can see it stop.
  if not view.disc(e.surface.index, c.x, c.y, ring_r) then return end

  local conv_at = converge_at()
  local unit = render.charge_unit(rec)
  local beta, energy = beam_state(unit)
  local speed = ch.speed_max * beta                      -- turns per tick
  local level = ch.alpha_min + (ch.alpha_max - ch.alpha_min) * unit
  local col = mix(ch.color, ch.hot_color, energy)
  -- Bunch compression: the packs narrow as the beam's energy rises.
  local sharp = ch.pack_sharpness
                + (ch.pack_sharpness_max - ch.pack_sharpness) * energy

  -- CIRCULATING. The phase is integrated, not computed from elapsed time, so a
  -- speed that follows the charge never makes the ring jump.
  if elapsed < conv_at then
    bag.phase = (bag.phase + speed) % 1
    for i, o in ipairs(bag.bulbs) do
      if is_obj(o) then
        local rel = (i - 1) / n
        local w = math.max(0, math.cos(rel * ch.packs * TAU)) ^ sharp
        paint(o, at(c, bag.phase + rel, ring_r), col,
              level * (ch.alpha_floor + (1 - ch.alpha_floor) * w))
      end
    end
    for k, g in ipairs(bag.glows) do
      if is_obj(g) then
        g.target = at(c, bag.phase + (k - 1) / ch.packs, ring_r)
        g.color = col
        g.intensity = ch.light_intensity * level
      end
    end
    return
  end

  -- EXTRACTION. The ring keeps turning at the speed it reached; the kicker
  -- sits where the aim line crosses it. Each bunch circulates until its own
  -- angular distance to that point has been covered, then leaves the ring and
  -- runs straight down the line into the barrel at the same linear speed it
  -- was orbiting with -- so nothing accelerates, decelerates or overtakes.
  if not bag.conv then
    -- Speed is frozen at the moment the kicker arms: what follows is one
    -- extraction at one energy, not a beam still being fed.
    bag.conv = {phase = bag.phase, target = target_bearing(rec),
                speed = math.max(speed, ch.speed_max * 0.05)}
  end
  local cvs = bag.conv
  local t = elapsed - conv_at
  local r_end = C.turret.tile_size / 2
  local run = math.max(0.5, ring_r - r_end)          -- tiles from ring to barrel
  local v_lin = cvs.speed * TAU * ring_r             -- tiles per tick
  local head

  for i, o in ipairs(bag.bulbs) do
    if is_obj(o) then
      local o0 = cvs.phase + (i - 1) / n
      -- Turns still to travel before this bunch reaches the kicker, and the
      -- tick it gets there.
      local d = (cvs.target - o0) % 1
      local kick_t = d / cvs.speed
      local pos, alpha
      if t < kick_t then
        pos = at(c, o0 + cvs.speed * t, ring_r)
        alpha = ch.alpha_max * level
      else
        local p = (t - kick_t) * v_lin / run
        if p > 1 then p = 1 end
        pos = at(c, cvs.target, ring_r + (r_end - ring_r) * p)
        -- Gone by the time it reaches the barrel: it is inside the machine.
        alpha = ch.alpha_max * level * (1 - math.min(1, p / cv.fade))
        if p < 0.35 and not head then head = pos end
      end
      paint(o, pos, col, alpha)
    end
  end

  for k, g in ipairs(bag.glows) do
    if is_obj(g) then
      g.color = col
      if k == 1 and head then
        g.target = head
        g.intensity = ch.light_intensity
      else
        g.intensity = 0
      end
    end
  end
end

-- =============================================================================
-- STRIKE
-- =============================================================================

--- The discharge landed. Called from turret.lua's discharge, after the lance
--- is confirmed lit.
function reticle.strike(rec)
  if not R.enabled then return end
  local e = rec.entity
  if not (e and e.valid) then return end
  local bag = bag_for(rec.unit_number)

  local s = R.strike
  if s.enabled then
    if bag.flash then
      kill(bag.flash.disc)
      kill(bag.flash.light)
    end
    -- The stage is square (C.foundation), so the flash is too.
    local h = C.foundation.stage_radius
    bag.flash = {
      t0 = game.tick,
      disc = rendering.draw_rectangle{
        color = {r = 1, g = 1, b = 1, a = s.alpha}, filled = true,
        left_top     = {entity = e, offset = {-h, -h}},
        right_bottom = {entity = e, offset = { h,  h}},
        surface = e.surface, draw_on_ground = true,
      },
      light = rendering.draw_light{
        sprite = "utility/light_medium", scale = s.light_scale,
        intensity = s.light_intensity, color = {r = 1, g = 1, b = 1},
        target = e, surface = e.surface,
      },
    }
  end

  local sc = R.scorch
  if sc.enabled and sc.max > 0 then
    local list = {}
    for _, o in ipairs(bag.scorch or {}) do
      if is_obj(o) then list[#list + 1] = o end
    end
    while #list >= sc.max do kill(table.remove(list, 1)) end
    local names = N.sprite.stage_scorch
    local j = sc.jitter
    -- Flipped, never turned: the art is a foreshortened ellipse, and a quarter
    -- turn would stand it on end.
    list[#list + 1] = rendering.draw_sprite{
      sprite = names[math.random(#names)],
      target = {entity = e,
                offset = {(math.random() * 2 - 1) * j, (math.random() * 2 - 1) * j}},
      surface = e.surface,
      render_layer = sc.render_layer,
      orientation = (math.random() < 0.5) and 0 or 0.5,
      tint = {r = sc.tint.r, g = sc.tint.g, b = sc.tint.b, a = sc.alpha},
    }
    bag.scorch = list
  end
end

local function flash_step(bag, tick)
  local f, s = bag.flash, R.strike
  local t = tick - f.t0
  if t >= s.ticks then
    kill(f.disc)
    kill(f.light)
    bag.flash = nil
    return
  end
  local k = 1 - t / s.ticks
  k = k * k
  if is_obj(f.disc) then f.disc.color = {r = 1, g = 1, b = 1, a = s.alpha * k} end
  if is_obj(f.light) then f.light.intensity = s.light_intensity * k end
end

-- =============================================================================
-- COMMISSION
-- =============================================================================

--- Every conduit object render.build made, with the orientation it hangs at.
-- Keys mirror render.build: "spur_<side>" per bank, "spur_m_<un>" per mast.
local function spurs(rec)
  local out = {}
  local c = rec.entity.position
  for side, un in pairs(rec.pylons or {}) do
    local link = storage.pylons[un]
    local p = link and link.entity
    if p and p.valid then
      out[#out + 1] = {key = "spur_" .. side,
                       o = orientation_of(p.position.x - c.x, p.position.y - c.y)}
    end
  end
  for un, m in pairs(rec.masts or {}) do
    if m and m.valid then
      out[#out + 1] = {key = "spur_m_" .. un,
                       o = orientation_of(m.position.x - c.x, m.position.y - c.y)}
    end
  end
  return out
end

local function show_conduit(rec, visible)
  local rbag = storage.render[rec.unit_number]
  if not rbag then return end
  for key, o in pairs(rbag) do
    if type(key) == "string"
       and (key == "bus" or key == "glow" or key:sub(1, 5) == "spur_")
       and is_obj(o) then
      o.visible = visible
    end
  end
end

local function finish_commission(rec, bag)
  local k = bag.commission
  if not k then return end
  kill_list(k.lights)
  kill_list(k.discs)
  kill(k.arc)
  show_conduit(rec, true)
  bag.commission = nil
end

--- The installation is complete. Start the ceremony.
function reticle.commission(rec)
  local cm = R.commission
  if not (R.enabled and cm.enabled) then return end
  local e = rec.entity
  if not (e and e.valid) then return end
  local bag = bag_for(rec.unit_number)
  finish_commission(rec, bag)

  local c = e.position
  local masts = {}
  for un, m in pairs(rec.masts or {}) do
    if m and m.valid then
      masts[#masts + 1] = {
        un = un,
        o = (orientation_of(m.position.x - c.x, m.position.y - c.y) - START) % 1,
      }
    end
  end
  table.sort(masts, function(a, b)
    if a.o ~= b.o then return a.o < b.o end
    return a.un < b.un
  end)
  local order = {}
  for i, m in ipairs(masts) do order[i] = m.un end

  show_conduit(rec, false)
  bag.commission = {t0 = game.tick, masts = order, lights = {}, discs = {}}
end

local function commission_step(rec, bag, tick)
  local cm = R.commission
  local k = bag.commission
  local e = rec.entity
  local t = tick - k.t0
  local n = #k.masts

  -- The masts, in turn. A mast gone since the start is skipped (false), not
  -- retried.
  for i, un in ipairs(k.masts) do
    local lit_at = (i - 1) * cm.mast_step
    if t >= lit_at and k.lights[i] == nil then
      local m = rec.masts and rec.masts[un]
      if m and m.valid then
        k.lights[i] = rendering.draw_light{
          sprite = "utility/light_medium", scale = cm.mast_light_scale,
          intensity = cm.mast_light_intensity, color = cm.mast_color,
          target = m, surface = e.surface,
        }
        k.discs[i] = rendering.draw_circle{
          color = {r = cm.mast_color.r, g = cm.mast_color.g, b = cm.mast_color.b,
                   a = cm.mast_disc_alpha},
          radius = cm.mast_disc_radius, filled = true,
          target = m, surface = e.surface, draw_on_ground = true,
        }
      else
        k.lights[i] = false
      end
    end
    local d = k.discs[i]
    if is_obj(d) then
      local f = 1 - (t - lit_at) / cm.fade_ticks
      if f <= 0 then
        d.destroy()
        k.discs[i] = false
      else
        d.color = {r = cm.mast_color.r, g = cm.mast_color.g, b = cm.mast_color.b,
                   a = cm.mast_disc_alpha * f}
      end
    end
  end

  -- The ring draws itself. Starts at north; `dir` maps the engine's positive
  -- arc angle onto orientation (see C.reticle.commission's UNVERIFIED note).
  local arc_t0 = n * cm.mast_step
  local arc_end = arc_t0 + cm.arc_ticks
  local dir = cm.arc_clockwise and 1 or -1
  if t >= arc_t0 and t < arc_end then
    local ring_r = C.firing_ring_radius()
    if not is_obj(k.arc) then
      k.arc = rendering.draw_arc{
        color = cm.arc_color,
        min_radius = ring_r - cm.arc_half_width,
        max_radius = ring_r + cm.arc_half_width,
        start_angle = -dir * cm.arc_zero_orientation * TAU,
        angle = 0.001,
        target = e, surface = e.surface, draw_on_ground = true,
      }
    end
    local p = (t - arc_t0) / cm.arc_ticks
    p = 1 - (1 - p) * (1 - p)
    k.arc.angle = math.max(0.001, p * TAU)
    local rbag = storage.render[rec.unit_number]
    if rbag then
      for _, s in ipairs(spurs(rec)) do
        local o = rbag[s.key]
        if is_obj(o) and not o.visible and (dir * s.o) % 1 <= p then
          o.visible = true
        end
      end
    end
  elseif t >= arc_end then
    if not k.closed then
      show_conduit(rec, true)
      k.closed = true
    end
    local f = 1 - (t - arc_end) / cm.fade_ticks
    if f <= 0 then
      finish_commission(rec, bag)
      return
    end
    for _, l in pairs(k.lights) do
      if is_obj(l) then l.intensity = cm.mast_light_intensity * f end
    end
    if is_obj(k.arc) then
      k.arc.angle = TAU
      k.arc.color = {r = cm.arc_color.r, g = cm.arc_color.g, b = cm.arc_color.b,
                     a = cm.arc_color.a * f}
    end
  end
end

-- =============================================================================
-- The per-tick driver
-- =============================================================================

--- @param aiming   boolean the installation is in AIM
--- @param charging boolean in FIRE and not yet discharged
function reticle.tick(rec, aiming, charging)
  local un = rec.unit_number
  local bag = storage.reticle[un]
  if not bag then
    if not (R.enabled and (aiming or charging)) then return end
    bag = bag_for(un)
  end
  local tick = game.tick

  if R.enabled and R.aim_line.enabled and (aiming or charging) and rec.designated then
    aim_line(rec, bag, charging and (tick - rec.state_since) >= converge_at())
  elseif bag.aim then
    drop_aim(bag)
  end

  if R.enabled and R.chase.enabled and charging and rec.designated then
    chase(rec, bag, tick - rec.state_since)
  elseif bag.bulbs then
    drop_chase(bag)
  end

  if bag.flash then flash_step(bag, tick) end

  if bag.commission then
    if R.enabled and R.commission.enabled then
      commission_step(rec, bag, tick)
    else
      finish_commission(rec, bag)
    end
  end

  if not (bag.aim or bag.bulbs or bag.flash or bag.commission or bag.scorch) then
    storage.reticle[un] = nil
  end
end

return reticle
