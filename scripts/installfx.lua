-- scripts/installfx.lua ------------------------------------------------------------
-- The installation's own physical reactions to a shot. C.installfx.
--
--   ARCS    lightning pinging bank to bank while the gun charges
--   HEAT    the banks glow (black body, I^2 R) and boil off coolant with it
--   DUST    on the strike, a shock of dust races across the pad to its rim
--   VENT    after the shot, steam pours off the muzzle for exactly as long as
--           the gun stays in VENTING, so the smoke IS the reload timer
--
-- NOTHING HERE IS STORED. Every bolt, front line and light is a render object
-- with a few ticks' time_to_live, and every puff is a trivial smoke, so there is
-- no bag to clean up when a turret dies and nothing to migrate. The schedule
-- rides on timestamps the record already has (rec.discharged_at) or plain
-- numbers added to it (rec.vent_since, rec.fx_arc_next, rec.vent_next) --
-- stale values are harmless, since each only ever asks "is now past it".
--
-- Driven every tick from scripts/turret.lua's loop, which passes the state test
-- in (the render.preview / reticle.tick pattern: requiring turret.lua back is a
-- cycle). An idle turret costs a few nil checks, and nothing is drawn for an
-- installation no player can see (scripts/view.lua).
--------------------------------------------------------------------------------------

local C       = require("config")
local N       = require("lib.names")
local boltlib = require("lib.bolt")
local heatlib = require("lib.heat")
local render  = require("scripts.render")
local beam    = require("scripts.beam")
local view    = require("scripts.view")

local installfx = {}

local FX  = C.installfx
local TAU = 2 * math.pi

-- =============================================================================
-- ARCS
-- =============================================================================

--- Which quadrant of the gun a point is in, as two signs.
local function quadrant(c, p)
  return (p.x < c.x) and -1 or 1, (p.y < c.y) and -1 or 1
end

--- The linked banks, each with its quadrant. Rebuilt per ping (at most 36
--- entries, a few times a second) rather than cached: a file-scope cache of
--- game state is exactly what the determinism rules forbid.
local function banks_of(rec)
  local c = rec.entity.position
  local out = {}
  for _, un in pairs(rec.pylons or {}) do
    local link = storage.pylons[un]
    local p = link and link.entity
    if p and p.valid then
      local qx, qy = quadrant(c, p.position)
      out[#out + 1] = {e = p, x = p.position.x, y = p.position.y, qx = qx, qy = qy}
    end
  end
  return out
end

--- A partner for bank `a`: a random cluster-mate, or -- `cross_chance` of the
--- time -- the nearest bank of a NEIGHBOURING cluster (one axis shared, never
--- the diagonal one across the gun). Falls back to whichever exists.
local function partner(banks, a, cross_chance)
  local mates, neigh = {}, {}
  for _, b in ipairs(banks) do
    if b ~= a then
      if b.qx == a.qx and b.qy == a.qy then
        mates[#mates + 1] = b
      elseif b.qx == a.qx or b.qy == a.qy then
        neigh[#neigh + 1] = b
      end
    end
  end
  local cross = #neigh > 0 and (#mates == 0 or math.random() < cross_chance)
  if not cross then
    if #mates == 0 then return nil, false end
    return mates[math.random(#mates)], false
  end
  local best, best_d
  for _, b in ipairs(neigh) do
    local d = (b.x - a.x) ^ 2 + (b.y - a.y) ^ 2
    if not best_d or d < best_d then best, best_d = b, d end
  end
  return best, true
end

local function terminal(b, a)
  return b.x + (math.random() * 2 - 1) * a.terminal_jitter,
         b.y - a.terminal_lift + (math.random() * 2 - 1) * a.terminal_jitter * 0.5
end

local function arcs(rec, surface)
  local a = FX.arcs
  if not (a and a.enabled) then return end
  local unit = render.charge_unit(rec)
  if unit < a.threshold then return end
  local tick = game.tick
  if tick < (rec.fx_arc_next or 0) then return end

  local u = (unit - a.threshold) / math.max(1e-6, 1 - a.threshold)
  if u > 1 then u = 1 end
  rec.fx_arc_next = tick + math.floor(a.interval_slow + (a.interval_fast - a.interval_slow) * u + 0.5)

  local banks = banks_of(rec)
  if #banks < 2 then return end

  local count = math.floor(a.count_min + (a.count_max - a.count_min) * u + 0.5)
  for _ = 1, count do
    local from = banks[math.random(#banks)]
    local to, cross = partner(banks, from, a.cross_chance)
    if to then
      local x0, y0 = terminal(from, a)
      local x1, y1 = terminal(to, a)
      local pts = boltlib.path(x0, y0, x1, y1,
                               cross and a.cross_segments or a.segments, a.jitter)
      if pts then
        -- Body first, then the core over it, on the same path.
        for pass = 1, 2 do
          local col = (pass == 1) and a.color or a.core_color
          local w   = (pass == 1) and a.width or a.core_width
          for i = 2, #pts do
            rendering.draw_line{
              color = col, width = w, from = pts[i - 1], to = pts[i],
              surface = surface, time_to_live = a.ttl,
            }
          end
        end
        for _, p in ipairs({pts[1], pts[#pts]}) do
          rendering.draw_light{
            sprite = "utility/light_medium", surface = surface, target = p,
            color = a.color, intensity = a.spark_light_intensity,
            scale = a.spark_light_scale, time_to_live = a.ttl,
          }
        end
      end
    end
  end
end

-- =============================================================================
-- WASTE HEAT: the banks glow while they take charge
--
-- I^2 R. See C.installfx.heat for why `drive` is squared and why the colour
-- comes from lib/heat.lua rather than from a hand-picked orange.
-- =============================================================================

--- How hard this installation is being driven right now, 0..1: how far
--- through the ordered charge it is, times how big that order is against a
--- standard shot, squared -- current squared is the dissipation.
local function heat_drive(rec)
  local unit = render.charge_unit(rec)
  local load = (rec.rate or C.power.default_rate) / C.power.reference_rate
  if load > 1 then load = 1 elseif load < 0 then load = 0 end
  local d = unit * load
  return d * d
end

local function bank_heat(rec, surface)
  local h = FX.heat
  if not (h and h.enabled) then return end
  local tick = game.tick
  if tick < (rec.fx_heat_next or 0) then return end
  rec.fx_heat_next = tick + h.interval

  local drive = heat_drive(rec)
  if drive < h.threshold then return end

  local kelvin = h.t_min + (h.t_max - h.t_min) * drive
  local c = heatlib.rgb(kelvin)
  local steam = (tick >= (rec.fx_steam_next or 0))
  if steam then rec.fx_steam_next = tick + h.steam_interval end

  for _, un in pairs(rec.pylons or {}) do
    local link = storage.pylons[un]
    local p = link and link.entity
    if p and p.valid then
      local pos = p.position
      rendering.draw_light{
        sprite = "utility/light_medium", surface = surface, target = pos,
        color = {r = c.r, g = c.g, b = c.b},
        intensity = h.light_intensity * drive,
        scale = h.light_scale,
        -- Outlives its own repaint by a tick so the glow never blinks
        -- between frames; nothing to store or clean up either way.
        time_to_live = h.interval + 1,
      }
      if steam and math.random() < h.steam_chance * drive then
        surface.create_trivial_smoke{
          name = N.smoke_vent,
          position = {
            pos.x + (math.random() * 2 - 1) * h.steam_jitter,
            pos.y - math.random() * h.steam_rise,
          },
        }
      end
    end
  end
end

-- =============================================================================
-- DUST: the ignition shock
-- =============================================================================

local function dust_radius(d, tt)
  local r0 = C.foundation.stage_radius
  local r1 = C.foundation_reach() + 0.5
  local u = tt / math.max(1, d.ticks)
  if u > 1 then u = 1 end
  return r0 + (r1 - r0) * (1 - (1 - u) * (1 - u)), r0
end

local function dust(rec, surface)
  local d = FX.dust
  -- rec.lance, not rec.discharged: a misfire marks the strike but lit nothing.
  if not (d and d.enabled and rec.lance and rec.discharged_at) then return end
  local t = game.tick - rec.discharged_at
  if t < 0 or t > d.ticks then return end

  local c = rec.entity.position
  local cur, r0 = dust_radius(d, t)
  local prev = (t == 0) and -math.huge or dust_radius(d, t - 1)

  -- Every stamp radius the front crossed since last tick.
  local k0 = math.max(0, math.floor((prev - r0) / d.stamp_spacing) + 1)
  if t == 0 then k0 = 0 end
  local k1 = math.floor((cur - r0) / d.stamp_spacing + 1e-9)
  for k = k0, k1 do
    local r = r0 + k * d.stamp_spacing
    local n = math.max(6, math.floor(TAU * r / d.puff_spacing))
    local phase = math.random() * TAU
    for i = 1, n do
      local ang = phase + (i - 1) / n * TAU
      surface.create_trivial_smoke{
        name = N.smoke_dust,
        position = {c.x + math.cos(ang) * r, c.y + math.sin(ang) * r},
      }
    end
  end

  local fade = 1 - t / math.max(1, d.ticks)
  local fc = d.front_color
  rendering.draw_circle{
    color = {r = fc.r, g = fc.g, b = fc.b, a = fc.a * fade},
    radius = cur, width = d.front_width, filled = false,
    target = c, surface = surface, time_to_live = 2, draw_on_ground = true,
  }
end

-- =============================================================================
-- VENT: steam off the muzzle
-- =============================================================================

--- A real shot ended. Called from turret.stand_down, only when the lance had
--- actually discharged -- a scrubbed charge has nothing to vent.
function installfx.vent_start(rec)
  rec.vent_since = game.tick
  rec.vent_next = nil
end

local function vent(rec, surface, charging)
  local v = FX.vent
  if not rec.vent_since then return end
  if not (v and v.enabled) then
    rec.vent_since, rec.vent_next = nil, nil
    return
  end
  -- research-adjusted, same fraction C.charge.cooldown_for shortens
  -- the cooldown state by -- see that function's header in config.lua. Read
  -- once per tick rather than cached on rec: cheap (one table lookup, no
  -- entity search) and always correct if research completes mid-vent.
  local ticks = C.installfx.vent_ticks_for(rec.entity.force)
  local tick = game.tick
  local t = tick - rec.vent_since
  if charging or t > ticks or t < 0 then
    rec.vent_since, rec.vent_next = nil, nil
    return
  end
  if tick < (rec.vent_next or 0) then return end
  local u = t / math.max(1, ticks)
  rec.vent_next = tick + math.floor(v.interval_start + (v.interval_end - v.interval_start) * u + 0.5)

  -- The muzzle along the barrel's own bearing -- where the lance left from --
  -- or along the last aim if the barrel cannot be read.
  local e = rec.entity
  local at = beam.barrel_point(e, beam.tip_distance(), 0)
  if not at and rec.aim then at = beam.muzzle(e.position, rec.aim) end
  if not at then return end

  local n = math.max(1, math.floor(v.burst * (1 - u) + 0.5))
  for _ = 1, n do
    surface.create_trivial_smoke{
      name = N.smoke_vent,
      position = {
        at.x + (math.random() * 2 - 1) * v.jitter,
        at.y - math.random() * v.rise,
      },
    }
  end
end

-- =============================================================================
-- The per-tick driver
-- =============================================================================

--- @param charging boolean in FIRE and not yet discharged
function installfx.tick(rec, charging)
  local e = rec.entity
  if not (e and e.valid) then return end
  if not (charging or rec.discharged or rec.vent_since) then return end
  local surface = e.surface
  local p = e.position
  if not view.disc(surface.index, p.x, p.y, C.installation_extent()) then return end
  if charging then
    arcs(rec, surface)
    bank_heat(rec, surface)
  end
  if rec.discharged then dust(rec, surface) end
  if rec.vent_since then vent(rec, surface, charging) end
end

return installfx
