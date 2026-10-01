-- scripts/beam: lance creation, sustain, and cut. Damage via scripts/beam.lua and scripts/impact.lua.

local C      = require("config")
local N      = require("lib.names")
local impact = require("scripts.impact")
local mapdraw = require("scripts.mapdraw")
local implode  = require("scripts.implode")
local front    = require("scripts.front")
local flora    = require("scripts.flora")
local audio    = require("scripts.audio")
local boltlib  = require("lib.bolt")
local blib     = require("lib.beam")
local heat     = require("lib.heat")
local slay     = require("scripts.slay")
local profile  = require("scripts.profile")
local view     = require("scripts.view")
local lance    = require("scripts.lance")
local lightning = require("scripts.lightning")

local beam = {}

local B = C.beam

-- Which of this mod's explosions the contact sequence cycles through. The config
-- names them by short tag so C.beam.contact reads as intent rather than as a
-- list of prototype names -- ARCHITECTURE.md rule 2 keeps the strings here.
local CONTACT = {
  shockwave = N.ex_shockwave,
  fireball  = N.ex_fireball,
  cluster   = N.ex_cluster,
}

-- =============================================================================
-- Geometry
-- =============================================================================

--- Where the beam leaves the gun -- along the FIRING BEARING, not the
--- barrel's actual orientation, so a stuck barrel (storage.no_orientation)
--- stays cosmetic: the lance leaves from the correct side of the gun
--- regardless of whether the sprite got there.
--
-- muzzle_forward_mult/muzzle_lift_mult exist because the barrel tip can't be
-- derived from the sprite metadata (a 256-direction sheet with dice=4) --
-- only settled by looking. Read a runtime override first, /oppenheimer-muzzle
-- writes them live with an on-screen marker, and the settled pair gets baked
-- back into config.lua.
local function forward_mult()
  return (storage and storage.muzzle_forward) or B.muzzle_forward_mult or 1
end

local function lift_mult()
  return (storage and storage.muzzle_lift) or B.muzzle_lift_mult or 1
end

beam.forward_mult = forward_mult
beam.lift_mult    = lift_mult

--- Muzzle tip distance in tiles along barrel (scaled by forward_mult + muzzle_clear).
function beam.tip_distance()
  return C.muzzle_distance() * forward_mult() + B.muzzle_clear
end

function beam.muzzle(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then return {x = from.x, y = from.y} end
  local k = beam.tip_distance() / d
  local lift = C.cannon_base_shift()[3] * lift_mult()
  return {x = from.x + dx * k, y = from.y + dy * k - lift}
end

--- The DRAWN channel's origin: beam.muzzle pushed along the firing bearing by
--- C.beam_draw_standoff, so an overpressure lance's near end clears the
--- installation. Art only -- the damage origin is beam.muzzle_ground, which
--- does not move, so what the lance scours is unchanged.
function beam.muzzle_draw(from, to, power)
  local m = beam.muzzle(from, to)
  local s = C.beam_draw_standoff(power)
  if s <= 0 then return m end
  local dx, dy = to.x - from.x, to.y - from.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then return m end
  return {x = m.x + dx / d * s, y = m.y + dy / d * s}
end

--- Same point, without tower lift. Used for damage calculation instead of rendering.
function beam.muzzle_ground(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then return {x = from.x, y = from.y} end
  local k = beam.tip_distance() / d
  return {x = from.x + dx * k, y = from.y + dy * k}
end

--- Unit vector along barrel orientation (0=north), or nil if unreadable.
local function barrel_vector(e)
  local ok, o = pcall(function() return e.orientation end)
  if not (ok and o) then return nil end
  local a = o * 2 * math.pi
  return {x = math.sin(a), y = -math.cos(a)}
end

--- Point offset along barrel bearing plus lateral offset, lifted like beam.muzzle.
function beam.barrel_point(e, forward, lateral)
  local v = barrel_vector(e)
  if not v then return nil end
  local px, py = -v.y, v.x
  local lift = C.cannon_base_shift()[3] * lift_mult()
  return {
    x = e.position.x + v.x * forward + px * (lateral or 0),
    y = e.position.y + v.y * forward + py * (lateral or 0) - lift,
  }
end

--- Draw or move the tuning marker for one installation.
--
-- Deliberately NOT a persistent render object in the bag: it is a debugging aid
-- that should leave nothing behind in a save when it is switched off, so it is
-- redrawn with a short time_to_live and simply stops appearing. Costs nothing
-- when storage.muzzle_debug is false, which is every ordinary game.
function beam.marker(rec)
  if not (storage and storage.muzzle_debug) then return end
  local e = rec.entity
  if not (e and e.valid) then return end

  local v = barrel_vector(e)
  if not v then return end
  -- A point far enough along the barrel that muzzle() sees a real bearing; the
  -- distance is divided out, so any length gives the same answer.
  local aim = {x = e.position.x + v.x * 100, y = e.position.y + v.y * 100}

  local lifted = beam.muzzle(e.position, aim)
  local ground = beam.muzzle_ground(e.position, aim)
  local ttl = C.control.muzzle_marker_interval + 2

  -- WHERE THE SPRITE STARTS -- the one that has to land on the barrel tip.
  rendering.draw_circle{
    color = {r = 1, g = 0.2, b = 0.2, a = 0.9},
    radius = 0.55, width = 3, filled = false,
    target = lifted, surface = e.surface, time_to_live = ttl,
  }
  -- WHERE THE WEAPON CUTS -- the same point without the tower lift. The gap
  -- between the two circles IS muzzle_lift_mult, drawn to scale.
  rendering.draw_circle{
    color = {r = 0.3, g = 0.8, b = 1.0, a = 0.7},
    radius = 0.4, width = 2, filled = false,
    target = ground, surface = e.surface, time_to_live = ttl,
  }
  -- And the line back to the turret centre, so "is it too far out" is a question
  -- about a line rather than about two dots.
  rendering.draw_line{
    color = {r = 1, g = 1, b = 0.3, a = 0.5}, width = 2,
    from = e.position, to = lifted,
    surface = e.surface, time_to_live = ttl,
  }
end

-- =============================================================================
-- STRIKE GROUPS (C.beam.convergence)
--
-- A lance igniting within convergence.radius of a live strike joins it. The
-- group owns the sphere (clock, radius, heat, fronts, tallies), so a lance that
-- joins late, aborts or is mined moves none of it. A joiner aims at the group's
-- centre and ends on the group's cut tick; the group detonates on that tick.
-- Four lances into one sphere cost what one sphere costs, and add their power.
-- =============================================================================

--- Overpower for a whole group: the summed power's own band, times a bonus for
--- having been fired together.
local function group_omega(power, lances)
  local cv = B.convergence
  local w = C.overpower(power or 0)
  local n = math.min(lances or 1, cv.max_lances)
  if n > 1 then w = w * (1 + cv.gain_per_lance * (n - 1)) end
  return w
end
beam.group_omega = group_omega

--- The live strike a lance aimed at `aim` would join: the nearest one with
--- enough burn left to be worth joining, or nil.
local function strike_near(surface, aim)
  local cv = B.convergence
  if not (cv and cv.enabled and storage.strikes) then return nil end
  local best, best_d
  for id, g in pairs(storage.strikes) do
    if g.surface == surface.index and g.lances < cv.max_lances
       and g.cut_at - game.tick >= cv.join_min_ticks then
      local dx, dy = g.to.x - aim.x, g.to.y - aim.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d <= cv.radius and (not best_d or d < best_d) then best, best_d = id, d end
    end
  end
  return best
end

--- Open a group.
local function strike_open(surface, aim, power, un)
  storage.strikes = storage.strikes or {}
  local id = (storage.strike_next or 0) + 1
  storage.strike_next = id
  local sp = B.sphere
  storage.strikes[id] = {
    to = {x = aim.x, y = aim.y}, surface = surface.index,
    -- power is the yield DELIVERED (lances summed); order is the dial, and the
    -- dial alone sets the crater. CRITICAL: every radius reads order, never power.
    power = power, order = power, lances = 1, live = 1, opener = un,
    at = game.tick, cut_at = game.tick + C.beam.sustain_ticks,
    omega_group = group_omega(power, 1),
    theta_ball = 0, taunts = 0, burned = 0, struck = 0,
    streaks = implode.layout_streaks(sp.streaks),
    fire = sp.fire.enabled and front.new{
      x = aim.x, y = aim.y,
      r_max = C.sphere_full_radius(power) * sp.fire.radius_fraction,
      dir = 1, bucket = sp.fire.bucket_tiles,
      movers = C.blast.movers.enabled,
    } or nil,
  }
  return id
end

--- Add a joining lance to a group. Its power is added to the delivered total;
--- the crater only widens if the joiner's own dial is bigger than the group's.
--- A front's r_max is read fresh on every advance, so raising it mid-flight lets
--- the walk carry on.
local function strike_absorb(g, power)
  g.power  = math.min(g.power + power, C.charge.group_cap)
  g.order  = math.max(g.order or power, power)
  g.lances = g.lances + 1
  g.live   = g.live + 1
  g.omega_group = group_omega(g.power, g.lances)
  local full = C.sphere_full_radius(g.order)
  if g.fire then
    g.fire.r_max = math.max(g.fire.r_max, full * B.sphere.fire.radius_fraction)
  end
end

--- A lance is going out. Returns the group to the call that closes it: the last
--- lance out, or, with `ripe`, any lance once the group's cut tick has come, so
--- a lost record cannot hold the detonation back.
local function strike_leave(L, ripe)
  local g = L.strike and storage.strikes and storage.strikes[L.strike]
  if not g then return nil end
  g.live = g.live - 1
  if g.live > 0 and not (ripe and game.tick >= g.cut_at) then return nil end
  storage.strikes[L.strike] = nil
  return g
end

--- The group a live lance belongs to, or nil.
local function strike_of(L)
  return L.strike and storage.strikes and storage.strikes[L.strike] or nil
end

-- =============================================================================
-- Ignition
-- =============================================================================

--- Fire the lance. Called from turret.discharge at C.sound.discharge_at.
--
-- @param rec   turret record
-- @param aim   MapPosition  where the beam terminates. Already carries the
--              short-fall correction for an under-charged shot -- an order the
--              grid could not fill produces a beam that visibly STOPS in open
--              ground before the target, which is a far more legible failure
--              than a shell quietly landing short was.
-- @param power number  yield as a fraction of a standard shot
-- @return boolean whether the lance was created
function beam.fire(rec, aim, power)
  local e = rec.entity
  if not (e and e.valid) then return false end

  local surface = e.surface
  -- A joiner lands on its group's centre and burns only what is left of the
  -- group's sustain.
  local near = strike_near(surface, aim)
  local g = near and storage.strikes[near]
  if g then aim = g.to end
  local burn = g and (g.cut_at - game.tick) or C.beam.sustain_ticks

  local from    = beam.muzzle_draw(e.position, aim, power)
  -- What the sprite starts from is up the tower and stood off by the channel's
  -- own width; what the weapon cuts is along the ground from the muzzle itself.
  -- See beam.muzzle_draw and beam.muzzle_ground.
  local ground  = beam.muzzle_ground(e.position, aim)

  -- Which built beam this shot gets: the width step nearest the energy the
  -- STRIKE carries, not this one gun's. A lance's own power stops at 100%
  -- (the dial's ceiling), so thickness reads the battery. rec.alpha_lances is
  -- stamped by alpha.release on every member of a synchronised volley, so all
  -- of them pick the same rung -- without it the first to tick would see a
  -- group of one and fire thin while the last fired fat.
  local g_power = power * (rec.alpha_lances or 1)
  if g then g_power = math.max(g_power, g.power + power) end
  local variant = C.beam_step_for(math.min(g_power, C.charge.group_cap))
  -- Generous on purpose: max_length destroys the beam if source and target drift
  -- further apart than it.
  local max_len = C.reach() * B.max_length_factor

  -- COLD AT IGNITION: the channel has had no time to heat, so the first
  -- frames are the coolest built step and beam.sustain climbs from there.
  local hstep = heat.step_for(heat.kelvin(0))

  profile.start("lance/fire: create")
  local chain = lance.open(surface, e.force, from, aim, variant, hstep, burn, max_len)
  profile.stop("lance/fire: create")
  -- Nothing to sustain and nothing to cut. Say so rather than leaving a record
  -- claiming a beam that does not exist.
  if not chain then return false end

  -- Committed only once the beam exists, so a failed create leaves no group.
  local strike = near
  if g then
    strike_absorb(g, power)
  else
    strike = strike_open(surface, aim, power, rec.unit_number)
    g = storage.strikes[strike]
  end

  rec.lance = {
    chain      = chain,
    from       = {x = from.x, y = from.y},
    ground     = {x = ground.x, y = ground.y},
    to         = {x = aim.x, y = aim.y},
    lit_at     = game.tick,
    cut_at     = g.cut_at,
    power      = power,
    -- This lance's own overpower band (C.overpower): heat, thickness, scorch
    -- lane and bloom follow what this installation put into this channel. The
    -- sphere's band is the group's.
    omega      = C.overpower(power),
    strike     = strike,
    opened     = strike ~= near,
    variant    = variant,
    surface    = surface.index,
    next_hit   = game.tick,
    contact_i  = 0,
    max_len    = max_len,
    beam_r     = 0,
    -- Normalised channel temperature, integrated every tick (C.heat), and the
    -- temperature step currently built.
    theta      = 0,
    hstep      = hstep,
    killed     = 0,
  }
  -- A fresh shot starts a fresh tally, or the numbers accumulate across every
  -- shot the installation has ever fired and mean nothing.
  rec.last_shot = nil

  if B.muzzle_flash then
    -- `target` IS MANDATORY HERE: base's artillery-cannon-muzzle-flash sets
    -- rotate = true, making it an ORIENTED explosion that needs a target to
    -- face or create_entity hard-crashes ("Oriented explosion (or beam) needs
    -- a target to be created") -- unlike every other explosion in this mod.
    -- Pointing it at the aim point is also correct, not just legal: the flash
    -- is the muzzle blast, lying along the barrel toward the ground it burns.
    surface.create_entity{
      name = N.base.muzzle_flash,
      position = from,
      target = aim,
      source = from,
    }
  end

  -- time_to_live does the cleanup, so there is no render object to track, no
  -- storage key to migrate, and nothing left glowing if the turret is mined
  -- mid-shot. The one bit of bookkeeping this file deliberately does not do.
  local L = B.muzzle_light
  if L then
    rendering.draw_light{
      sprite    = "utility/light_medium",
      surface   = surface,
      target    = from,
      color     = L.color,
      intensity = L.intensity,
      scale     = L.scale,
      time_to_live = burn,
    }
  end

  return true
end

-- =============================================================================
-- Sustain
-- =============================================================================

--- Is this one of ours, or on the firing force with the interlock on? Own
--- pylons/masts are always spared (a bank can sit squarely under the beam at
--- 5.5 tiles out). A CHARACTER IS NEVER SPARED: the interlock protects
--- buildings, not players standing in the line of fire. The interlock (C.beam.path.spares_friendly)
--- checks force NAME, not is_enemy, which is documented always-false for the
--- neutral force and would spare trees/rocks that should burn. Shared by the
--- beam, fire wave and arcs -- the collapse and wave are the detonation, which
--- the designator overlay warns about instead of sparing.
local function spared(v, e, fname)
  if v == e then return true end
  local n = v.name
  if n == N.pylon or n == N.substation then
    return true
  end
  if v.type == "character" then return false end
  return B.path.spares_friendly and fname ~= nil and v.force.name == fname
end

--- Where the DRAWN lance ends, on the ground, for a ball of this radius.
--
-- retarget_lance stops the beam at the ball's near face, so
-- everything that follows the beam -- what it vaporizes, and its line on the map
-- -- has to stop there too. This is the ground-level twin of lance_endpoint: the
-- same clamp, measured from L.ground rather than the lifted muzzle, because
-- nothing stands three and a half tiles up the tower.
local function ground_end(L, radius)
  local a = L.ground or L.from
  local dx, dy = L.to.x - a.x, L.to.y - a.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then return {x = L.to.x, y = L.to.y} end
  local want = d
  local rt = B.retarget
  if rt and rt.enabled then
    want = d - (radius or 0) - rt.surface_gap
    local floor = d * rt.min_length_fraction
    if want < floor then want = floor end
    if want > d then want = d end
  end
  local k = want / d
  return {x = a.x + dx * k, y = a.y + dy * k}
end

-- =============================================================================
-- The lane: EVERYTHING UNDER THE DRAWN BEAM IS GONE (C.beam.path)
--
-- The SWEEP searches a lane once, when it opens or widens, spread over
-- sweep_ticks. The WATCH then reads each chunk's military-target list under a
-- strike's lanes every `interval` ticks: every mover is a military target, and
-- a list costs the targets on it, not the ground.
-- HAZARD: an entity search costs every entity in its area whatever its filter;
-- never search a swept lane again to find what walked into it.
-- =============================================================================

local KILLABLE = {}
for _, t in ipairs(B.path.types) do KILLABLE[t] = true end

local CHUNK = 32
local RUN = 256            -- longest sweep box along its row, in tiles
local OFF, SPAN = 32768, 65536

-- One watch-mask bit per lane of a strike; lanes past the last share it.
local BIT = {}
for k = 1, 50 do BIT[k] = 2 ^ (k - 1) end

local function bit_of(k)
  return BIT[k] or BIT[#BIT]
end

local function has(mask, k)
  return math.floor(mask / bit_of(k)) % 2 == 1
end

--- Half-width of a lance's lane in tiles: the halo at its built width, plus the
--- scorch margin of the strike's overpower band.
local function lane_half(L, g)
  return C.beam_half_width((g and g.omega_group) or L.omega) * C.beam_size(L.variant or 1)
end

--- One lance's lane this tick, from its ground muzzle to the drawn tip. nil when
--- the lance has nothing left to cut with.
local function lane_of(rec, L, g)
  local e = rec.entity
  if not (e and e.valid) then return nil end
  local a = L.ground or L.from
  local b = ground_end(L, (g and g.sphere_r) or L.sphere_r or 0)
  local abx, aby = b.x - a.x, b.y - a.y
  local len2 = abx * abx + aby * aby
  if len2 < 1e-12 then return nil end
  local half = lane_half(L, g)
  local force = e.force
  return {
    ax = a.x, ay = a.y, bx = b.x, by = b.y, abx = abx, aby = aby, len2 = len2,
    half = half, half2 = half * half, e = e, force = force, fname = force.name, L = L,
  }
end

--- Whether (x, y) lies under the lane.
-- MUST test 0 <= t <= 1: without it a nest behind the gun is under the infinite line.
local function under(ln, x, y)
  local t = ((x - ln.ax) * ln.abx + (y - ln.ay) * ln.aby) / ln.len2
  if t < 0 or t > 1 then return false end
  local dx, dy = x - (ln.ax + ln.abx * t), y - (ln.ay + ln.aby * t)
  return dx * dx + dy * dy <= ln.half2
end

--- die(), not damage(): no health pool or resistance saves it, and the kill is credited.
--- Trees and rocks are destroyed instead, leaving no stump or debris (scripts/flora.lua).
local function vaporize(v, ln)
  local p = B.path
  if p.vaporize then
    if flora.owns(v) then
      v.destroy{raise_destroy = true}
    else
      v.die(ln.force, ln.e)
    end
    ln.L.killed = (ln.L.killed or 0) + 1
  elseif p.damage_per_application > 0 then
    v.damage(p.damage_per_application * (ln.L.power or 1), ln.force,
             p.damage_type, ln.e, ln.e)
  end
end

--- Calls emit(j, lo, hi, v0, v1) for each band j (h tiles, on multiples of h) that
--- the lane's rectangle, grown by `pad`, crosses: lo..hi is its extent along the
--- band, v0..v1 the part of the band it fills. `swap` lays the bands as columns.
local function raster(ln, h, pad, swap, emit)
  local ax, ay, bx, by = ln.ax, ln.ay, ln.bx, ln.by
  if swap then ax, ay, bx, by = ay, ax, by, bx end
  local len = math.sqrt(ln.len2)
  local ux, uy = (bx - ax) / len, (by - ay) / len
  local w = ln.half + pad
  local nx, ny = -uy * w, ux * w
  ax, ay = ax - ux * pad, ay - uy * pad
  bx, by = bx + ux * pad, by + uy * pad
  local px = {ax + nx, bx + nx, bx - nx, ax - nx}
  local py = {ay + ny, by + ny, by - ny, ay - ny}
  local vmin = math.min(py[1], py[2], py[3], py[4])
  local vmax = math.max(py[1], py[2], py[3], py[4])
  for j = math.floor(vmin / h), math.floor(vmax / h) do
    local v0, v1 = math.max(j * h, vmin), math.min((j + 1) * h, vmax)
    local lo, hi = math.huge, -math.huge
    for k = 1, 4 do
      local m = k % 4 + 1
      local x1, y1, x2, y2 = px[k], py[k], px[m], py[m]
      if y1 > y2 then x1, y1, x2, y2 = x2, y2, x1, y1 end
      if y2 >= v0 and y1 <= v1 then
        local xa, xb = x1, x2
        if y2 - y1 > 1e-9 then
          local s = (x2 - x1) / (y2 - y1)
          xa = x1 + (math.max(y1, v0) - y1) * s
          xb = x1 + (math.min(y2, v1) - y1) * s
        end
        if xa < lo then lo = xa end
        if xb < lo then lo = xb end
        if xa > hi then hi = xa end
        if xb > hi then hi = xb end
      end
    end
    if lo <= hi then emit(j, lo, hi, v0, v1) end
  end
end

--- A lane's sweep as search boxes {x0, y0, x1, y1, area, reach}, muzzle outward.
--- Rows run along the axis the lane is nearer, so a straight lane is a few long
--- boxes and a diagonal one searches at most a row's slant past its edges.
local function sweep_plan(ln)
  local h = B.path.row
  local swap = math.abs(ln.aby) > math.abs(ln.abx)
  local boxes, total = {}, 0
  raster(ln, h, 1, swap, function(_, lo, hi, v0, v1)
    local n = math.max(1, math.ceil((hi - lo) / RUN))
    for s = 0, n - 1 do
      local u0, u1 = lo + (hi - lo) * s / n, lo + (hi - lo) * (s + 1) / n
      local x0, y0, x1, y1 = u0, v0, u1, v1
      if swap then x0, y0, x1, y1 = v0, u0, v1, u1 end
      local area = (x1 - x0) * (y1 - y0)
      local reach = ((x0 + x1) / 2 - ln.ax) * ln.abx + ((y0 + y1) / 2 - ln.ay) * ln.aby
      boxes[#boxes + 1] = {x0, y0, x1, y1, area, reach}
      total = total + area
    end
  end)
  table.sort(boxes, function(p, q) return p[6] < q[6] end)
  return {boxes = boxes, left = total}
end

--- One tick of a lance's sweep: this tick's share of its boxes by area, so the
--- search spreads evenly over C.beam.path.sweep_ticks. Opens one on a new or
--- widened lane.
local function sweep_step(rec, L, g, surface)
  if not L.sweep and L.swept and lane_half(L, g) <= L.swept + 1e-6 then return end
  local ln = lane_of(rec, L, g)
  if not ln then return end

  profile.start("lance/path search (scour, full)")
  local S = L.sweep
  if not S then
    S = sweep_plan(ln)
    S.i, S.half = 1, ln.half
    S.due = game.tick + math.max(1, B.path.sweep_ticks) - 1
    L.sweep = S
  end
  local boxes, types = S.boxes, B.path.types
  local last = game.tick >= S.due
  local budget = S.left / math.max(1, S.due - game.tick + 1)
  local spent, searched = 0, 0
  while S.i <= #boxes and (last or spent < budget) do
    local bx = boxes[S.i]
    S.i = S.i + 1
    for _, v in ipairs(surface.find_entities_filtered{
      area = {{bx[1], bx[2]}, {bx[3], bx[4]}}, type = types,
    }) do
      if v.valid then
        local at = v.position
        if under(ln, at.x, at.y) and v.health and not spared(v, ln.e, ln.fname) then
          vaporize(v, ln)
        end
      end
    end
    spent = spent + bx[5]
    searched = searched + 1
  end
  S.left = S.left - spent
  if S.i > #boxes then
    L.swept = S.half
    L.sweep = nil
  end
  profile.stop("lance/path search (scour, full)")
  profile.count("scour/sweep searches", searched)
  profile.count("scour/sweep tiles searched", math.floor(spent))
end

--- The generated chunks under a strike's lanes, with a mask of the lanes over each.
local function watch_plan(lanes, surface)
  local index, cx, cy, mask = {}, {}, {}, {}
  local pos = {0, 0}
  for k, ln in ipairs(lanes) do
    local b = bit_of(k)
    raster(ln, CHUNK, 1, false, function(j, lo, hi)
      for c = math.floor(lo / CHUNK), math.floor(hi / CHUNK) do
        local key = (c + OFF) * SPAN + (j + OFF)
        local i = index[key]
        if i == nil then
          pos[1], pos[2] = c, j
          i = false
          if surface.is_chunk_generated(pos) then
            i = #cx + 1
            cx[i], cy[i], mask[i] = c, j, 0
          end
          index[key] = i
        end
        if i and not has(mask[i], k) then mask[i] = mask[i] + b end
      end
    end)
  end
  return cx, cy, mask
end

--- Open a watch cycle over a strike's live lanes: characters first (never spared,
--- and a spared force's lists are not read), then the chunk plan.
local function watch_start(host, sid, rec, surface)
  local g = sid and host or nil
  local lanes, uns = {}, {}
  if sid then
    for un, r in pairs(storage.turrets) do
      local L = r.lance
      if L and L.strike == sid and not L.wind_at then
        local ln = lane_of(r, L, g)
        if ln then
          lanes[#lanes + 1] = ln
          uns[#uns + 1] = un
        end
      end
    end
  else
    local ln = lane_of(rec, rec.lance, nil)
    if ln then lanes[1], uns[1] = ln, rec.unit_number end
  end
  if #lanes == 0 then return nil end

  local forces = {}
  for _, f in pairs(game.forces) do
    local skip = B.path.spares_friendly
    for _, ln in ipairs(lanes) do
      if ln.fname ~= f.name then skip = false end
    end
    if not skip then forces[#forces + 1] = f.name end
  end

  for _, p in pairs(game.players) do
    local c = p.character
    if c and c.valid and c.surface_index == surface.index then
      local at = c.position
      for _, ln in ipairs(lanes) do
        if under(ln, at.x, at.y) then
          vaporize(c, ln)
          break
        end
      end
    end
  end

  local cx, cy, mask = watch_plan(lanes, surface)
  return {
    uns = uns, forces = forces, cx = cx, cy = cy, mask = mask,
    i = 1, due = game.tick + math.max(1, B.path.interval) - 1,
  }
end

--- One tick of a strike's watch: this tick's share of its chunks, so every chunk
--- under a lane is read once per C.beam.path.interval.
local function watch_step(host, sid, rec, surface)
  local W = host.watch
  if not W or W.i > #W.cx then
    if game.tick < (host.next_watch or 0) then return end
    host.next_watch = game.tick + math.max(1, B.path.interval)
    W = watch_start(host, sid, rec, surface)
    host.watch = W
    if not W then return end
  end

  local g = sid and host or nil
  local lanes = {}
  for k, un in ipairs(W.uns) do
    local r = storage.turrets[un]
    local L = r and r.lance
    lanes[k] = (L and not L.wind_at and (not sid or L.strike == sid)
                and lane_of(r, L, g)) or false
  end

  local n = #W.cx
  local last = math.min(n, W.i - 1 + math.ceil((n - W.i + 1) / math.max(1, W.due - game.tick + 1)))
  local pos = {0, 0}
  local reads, checked = 0, 0
  for i = W.i, last do
    pos[1], pos[2] = W.cx[i], W.cy[i]
    local mask = W.mask[i]
    for _, fname in ipairs(W.forces) do
      reads = reads + 1
      for _, v in ipairs(surface.get_entities_with_force(pos, fname)) do
        if v.valid then
          checked = checked + 1
          local at = v.position
          for k = 1, #lanes do
            local ln = lanes[k]
            if ln and has(mask, k) and under(ln, at.x, at.y)
               and not spared(v, ln.e, ln.fname) then
              if KILLABLE[v.type] and v.health then vaporize(v, ln) end
              break
            end
          end
        end
      end
    end
  end
  W.i = last + 1
  profile.count("scour/chunk lists read", reads)
  profile.count("scour/military targets checked", checked)
end

-- =============================================================================
-- The charging sphere. Its state lives on the strike group `g`, not on a lance.
-- =============================================================================

--- The radius the sphere is headed for, in tiles: the group's clock against the
--- dialled yield. The size formula is C.sphere_full_radius because implode.begin
--- reads it too.
local function sphere_target(g)
  local sp = B.sphere
  local t = (game.tick - g.at) / math.max(1, g.cut_at - g.at)
  t = math.max(0, math.min(1, t))
  local full = C.sphere_full_radius(g.order)
  return sp.min_radius + (full - sp.min_radius) * (t ^ sp.growth_exponent)
end

--- Move the published radius toward the target. A joining lance raises the
--- target at once; the ball swells to it at sp.swell_rate of its full radius a
--- tick, which never binds on the ordinary growth curve.
local function sphere_grow(g)
  local sp = B.sphere
  local r = g.sphere_r or sp.min_radius
  local want = sphere_target(g)
  local step = C.sphere_full_radius(g.order) * sp.swell_rate
  if want > r + step then want = r + step end
  if want < r then want = r end
  g.sphere_r = want
  return want
end

--- Draw it. Redrawn every tick with a two tick life, so there is no render
--- object to store, invalidate or leave glowing after a cut, mine or abort.
local function draw_sphere(g, surface, radius)
  local tone = {kelvin = heat.kelvin(g.theta_ball, g.omega_group),
                glow = math.min(1, g.theta_ball or 0)}
  -- Shared with the collapse (implode.draw_orb), so nothing steps on the frame
  -- the beam cuts. Body and rim go through mapdraw; the shading is world-only.
  implode.draw_orb(g.to.x, g.to.y, surface, radius, 0, tone)
end

--- THE LANCE, ON THE MAP. Whether an entity appears on the chart is a
--- prototype decision with no runtime lever, so the map gets a line drawn for
--- it instead: chart_only, from L.ground (not the tower-lifted L.from -- a
--- map has no height), to ground_end -- the same retreating point the
--- vaporize line uses, so the chart line doesn't run through the middle of
--- the ball once the world beam has been eaten back.
local function draw_lance_chart(L, surface, radius)
  local cb = C.chart_view.beam
  if not (C.chart_view.enabled and cb.enabled) then return end
  if not (L.ground and L.to) then return end

  mapdraw.line({
    color = cb.color,
    width = cb.width,
    from  = L.ground,
    to    = ground_end(L, radius),
    surface = surface,
    time_to_live = 2,
  }, {chart_only = true, alpha_mult = 1.0, width_mult = 1.0})
end

--- STAGE ONE: THE FIRE WAVE (C.beam.sphere.fire). A front at
--- `radius_fraction` of the ball's current radius, burning outward through
--- the hottest plasma -- priced on the annulus scripts/front.lua finds chunk
--- by chunk just ahead of it, never the whole disc behind it. No visuals (it
--- is inside an opaque ball); heard instead, via N.sound.sear.
local function fire_wave(rec, g, surface, radius)
  local fc = B.sphere.fire
  local f = g.fire
  if not (fc and fc.enabled and f) then return end

  local e = rec.entity
  local live = e and e.valid
  local force = live and e.force or C.blast.rings.default_force
  local fname = live and e.force.name or nil
  local src = live and e or nil
  local amount = C.blast.dose.lethal_dose * fc.dose

  local hits = front.advance(f, surface, radius * fc.radius_fraction, {
    types  = fc.types,
    lead   = fc.lead,
    accept = function(v) return not spared(v, e, fname) end,
    movers = C.blast.movers.enabled and C.blast.movers or nil,
    -- NOT nil. This front rides a fraction of a ball that grows to the whole
    -- blast, so an unbounded one builds ground with the dial, inside the
    -- sustain. See C.beam.sphere.fire.generate_to.
    generate_to = fc.generate_to,
  }, function(v)
    slay.hit(v, amount, force, fc.damage_type, src, src)
  end, fc.budget)
  slay.flush()

  if hits > 0 then
    g.burned = (g.burned or 0) + hits
    if game.tick >= (g.next_sear or 0) then
      g.next_sear = game.tick + fc.sound_interval
      audio.broadcast(surface, g.to, N.sound.sear, {volume = fc.sound_volume})
    end
  end
end


-- =============================================================================
-- What the growth phase spends its budget on -- 0.16.3
--
-- THE FILTER, and it is the lesson 0.16.2 paid 20 FPS for: the ball fill is
-- OPAQUE. Anything drawn inside the current radius is paid for and never seen.
-- Only four surfaces exist during the sustain -- the rim, above the ball, outside
-- the ball, and the footprint once the ball retreats -- and everything here uses
-- one of them. Nothing below scales with how much is standing there, which was
-- the other half of what went wrong: a sphere over empty grass now costs what a
-- sphere over a forest costs.
-- =============================================================================

--- Material stripped off the ground outside the ball and dragged after it.
--
-- Surface 3. Identical code to the collapse version (scripts/implode.lua owns it)
-- with its own numbers, because growth and collapse are two phases of one
-- continuous piece of material being pulled in -- and a second implementation is
-- the streaks changing appearance on the frame the beam cuts.
local function sphere_streaks(g, surface, radius)
  implode.draw_streaks_at(g.to.x, g.to.y, g.streaks, surface, radius,
                          B.sphere.streaks)
end

-- defines.* mapped HERE and not in config.lua. config.lua is required by the
-- settings, data AND control stages, and `defines` exists in none of the first
-- two -- naming one there is a nil index at startup, a long way from the line
-- that caused it.
local TAUNT_DISTRACTION = {
  none        = defines.distraction.none,
  by_damage   = defines.distraction.by_damage,
  by_enemy    = defines.distraction.by_enemy,
  by_anything = defines.distraction.by_anything,
}

--- Order what is near the ball (but outside it) to walk into it -- the one
--- thing in the growth phase that is gameplay rather than a picture, off by
--- default. set_command is pathfinding per unit, so this runs on its own slow
--- interval with a hard per-application and per-shot budget and each unit
--- commanded exactly once (deduped by unit_number). Worms/spawners can't
--- move and players/vehicles aren't commandable -- biters and spitters only.
--- SHARP EDGE: distraction "none" makes the unit ignore being shot at, so an
--- ABORTED shot after this fires hands a nest an unmolested walk to the aim
--- point -- a real consequence of the feature, not a bug in it.
local function sphere_taunt(g, surface, radius)
  local t = B.sphere.taunt
  if not (t and t.enabled) then return end
  if game.tick < (g.next_taunt or 0) then return end
  g.next_taunt = game.tick + t.interval
  if (g.taunts or 0) >= t.max_total then return end

  g.taunted = g.taunted or {}
  local dest = {x = g.to.x, y = g.to.y}
  local dist = TAUNT_DISTRACTION[t.distraction] or defines.distraction.none
  local spent = 0

  for _, u in pairs(surface.find_entities_filtered{
    position = g.to, radius = radius * t.reach, type = "unit",
  }) do
    if spent >= t.budget or (g.taunts or 0) >= t.max_total then break end
    if u.valid then
      local id = u.unit_number
      if id and not g.taunted[id] then
        -- `commandable` is nil for anything that cannot be ordered, which is the
        -- honest test -- checking `type` would be a guess about which types the
        -- engine considers commandable, and the spec answers it directly.
        local cmd = u.commandable
        if cmd then
          g.taunted[id] = true
          cmd.set_command{
            type = defines.command.go_to_location,
            destination = dest,
            radius = t.arrive_radius,
            distraction = dist,
          }
          g.taunts = (g.taunts or 0) + 1
          spent = spent + 1
        end
      end
    end
  end
end

--- Where the lance should END: the ball's near face, not its centre -- the
--- ball is opaque and physically the lance deposits energy into the plasma
--- surface, so the endpoint retreats toward the muzzle as the ball grows.
local function lance_endpoint(L, radius)
  local rt = B.retarget
  local dx, dy = L.to.x - L.from.x, L.to.y - L.from.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then return {x = L.to.x, y = L.to.y}, 0 end

  local want = d - radius - rt.surface_gap
  -- CLAMPED, and it is not a formality: at full yield the ball radius exceeds the
  -- firing range, so an unclamped endpoint retreats PAST the muzzle and the beam
  -- points backwards out of the gun.
  local floor = d * rt.min_length_fraction
  if want < floor then want = floor end

  local k = want / d
  return {x = L.from.x + dx * k, y = L.from.y + dy * k}, want
end

--- Escalating hits where the beam is landing, so the sustain builds toward the
--- detonation instead of holding a static line.
--
-- AT THE DRAWN BEAM'S END, NOT THE AIM POINT. The ball's fill is drawn
-- above sprites and entities (draw_circle without draw_on_ground) and is 88%
-- opaque; it passes the old 3-tile spread within a few ticks of ignition, so
-- nine of the ten explosions played underneath it. The splash now lands where
-- the lance actually meets the ball's near face -- lance_endpoint at the radius
-- the beam was last POINTED at (L.beam_r), so it follows the drawn sprite.
-- Scattered across the beam and pulled back toward the muzzle, never forward
-- into the fill.
local function contact(L)
  local c = B.contact
  local surface = game.get_surface(L.surface)
  if not (surface and surface.valid) then return end

  L.contact_i = (L.contact_i or 0) + 1
  local pick = c.sequence[math.min(L.contact_i, #c.sequence)]
  local name = CONTACT[pick]
  if not name then return end

  local tip = L.to
  local rt = B.retarget
  if rt and rt.enabled then tip = lance_endpoint(L, L.beam_r or 0) end

  local dx, dy = L.to.x - L.from.x, L.to.y - L.from.y
  local d = math.sqrt(dx * dx + dy * dy)
  local ux, uy = 0, 0
  if d > 1e-6 then ux, uy = dx / d, dy / d end
  local across = (math.random() * 2 - 1) * c.spread
  local back = math.random() * c.spread * (c.pull_back or 0)
  surface.create_entity{
    name = name,
    position = {
      x = tip.x - uy * across - ux * back,
      y = tip.y + ux * across - uy * back,
    },
  }
end

--- Point the lance at the ball's near face, so it is eaten into as the ball grows,
--- and bring its visible spans to the current heat step. The tint is baked into
--- the prototype, so a colour change is a span rebuild on scripts/lance.lua's
--- shared budget.
--- A span's `duration` is its whole life, set when it is created, so this has
--- to run to when the LIGHT goes out and not to the cut: measured to cut_at
--- every span expires on that tick and the shutdown has nothing left to fade.
local function span_life(L)
  local w = B.winddown
  return L.cut_at + ((w.enabled and w.ticks) or 0) - game.tick
end

local function retarget_lance(rec, L, radius, hstep)
  local e = rec.entity
  if not (e and e.valid) then return end
  local chain = L.chain or lance.adopt(L)
  if not chain then return end
  L.chain = chain

  local remaining = span_life(L)
  if remaining < 2 then return end

  local aim, len = lance_endpoint(L, radius)
  hstep = hstep or L.hstep
  local rt = B.retarget
  lance.step(chain, L.from, aim, hstep, remaining, rt and rt.enabled)
  L.hstep = hstep
  L.beam_r, L.beam_len = radius, len
end

--- One tick of a group's sphere: heat, radius, drawing and every stage that
--- rides it. Run once a tick by whichever of the group's lances ticks first, so
--- the ball outlives any one installation.
local function drive_ball(rec, g, surface)
  g.theta_ball = heat.advance(g.theta_ball, g.power, C.heat.tau_ball)
  local radius = sphere_grow(g)

  profile.start("sphere/draw")
  draw_sphere(g, surface, radius)
  profile.stop("sphere/draw")
  profile.start("sphere/infall streaks")
  sphere_streaks(g, surface, radius)
  profile.stop("sphere/infall streaks")
  profile.start("sphere/inner fire front")
  fire_wave(rec, g, surface, radius)
  profile.stop("sphere/inner fire front")
  -- Trees and rocks the ball swallows die on its rim, under the opaque fill, so
  -- the collapse uncovers bare ground. The radius is the blast's, so the wave
  -- keys the same front; this never generates ground.
  profile.start("sphere/tree clearing (flora)")
  local e = rec.entity
  flora.advance(surface, g.to.x, g.to.y,
    C.yield.radius((g.order or 1) * C.charge.cost_per_shot),
    radius, (e and e.valid) and e.force.name or nil, nil, true)
  profile.stop("sphere/tree clearing (flora)")
  profile.start("sphere/lightning")
  lightning.tick(g, surface, radius, e, spared, true)
  profile.stop("sphere/lightning")
  slay.flush()
  profile.start("sphere/taunt")
  sphere_taunt(g, surface, radius)
  profile.stop("sphere/taunt")
end

--- THE SHUTDOWN, 0 at the cut and 1 when the light goes out. nil while the
--- lance is still delivering. (No clamp01 here: that local is declared far
--- below, and a call from above its declaration reads a global.)
local function wind_u(L)
  if not L.wind_at then return nil end
  local u = (game.tick - L.wind_at) / math.max(1, B.winddown.ticks)
  if u < 0 then return 0 elseif u > 1 then return 1 end
  return u
end

--- The held radius, ringing down over the shutdown. `u` is wind_u.
-- Cosmetic: g.sphere_r is untouched, so the collapse starts from the real radius.
local function settle_radius(r, u)
  local s = B.winddown.settle
  if not (s and s.enabled) then return r end
  local a = s.amplitude * math.exp(-s.decay * u)
  return r * (1 + a * math.sin(2 * math.pi * s.cycles * u))
end

--- True while the lance has stopped delivering but is still lit and cooling.
--- turret.stand_down reads it: its belt-and-braces abort would otherwise put
--- the beam out on the tick the state changes, which is the tick the shutdown
--- starts, and take the detonation with it.
function beam.winding(rec)
  local L = rec.lance
  return (L and L.wind_at) and true or false
end

--- One tick of a live lance. Called from the per-tick loop in scripts/turret.lua;
--- it returns at once for every turret that is not firing.
function beam.sustain(rec)
  local L = rec.lance
  if not L then return end

  -- Self-terminating: the cut tick is the group's, fixed when it opened. Past
  -- it the lance stops delivering and beam.cut opens the shutdown instead of
  -- putting the light out; the second call, at the end of it, is what detonates.
  local wind = wind_u(L)
  if wind then
    if wind >= 1 then
      beam.cut(rec)
      return
    end
  elseif game.tick >= L.cut_at then
    beam.cut(rec)
    L = rec.lance
    if not (L and L.wind_at) then return end
    wind = 0
  end

  if wind then
    -- Cooling, not heating: the heat step walks back down the black-body ladder
    -- so the lance dims through ember rather than blinking out.
    local w = B.winddown
    local k = (1 - wind) ^ w.heat_exponent
    L.theta = (L.wind_theta or 0) * (w.heat_floor + (1 - w.heat_floor) * k)
  else
    L.theta = heat.advance(L.theta, L.power or 0, C.heat.tau_beam)
  end

  if not B.sphere.enabled and L.chain then
    lance.build(L.chain, span_life(L))
  end

  -- From the tick after ignition: a volley's lances all join their strike on
  -- the ignition tick, and each joiner widens every lane.
  if not wind and B.path.enabled and game.tick > (L.lit_at or 0) then
    local surface = game.get_surface(L.surface)
    if surface and surface.valid then
      local g = strike_of(L)
      sweep_step(rec, L, g, surface)
      -- The watch belongs to the strike: its lanes share ground near the ball.
      local host = g or L
      if host.watched ~= game.tick then
        host.watched = game.tick
        profile.start("lance/path search (scour)")
        watch_step(host, g and L.strike, rec, surface)
        profile.stop("lance/path search (scour)")
      end
    end
  end

  if not wind and B.contact.enabled and game.tick >= (L.next_hit or 0) then
    L.next_hit = game.tick + B.contact.interval
    profile.start("lance/contact")
    contact(L)
    profile.stop("lance/contact")
  end

  if B.sphere.enabled then
    local surface = game.get_surface(L.surface)
    if surface and surface.valid then
      local g = strike_of(L)
      if g and g.driven ~= game.tick then
        g.driven = game.tick
        -- Through the shutdown the ball holds the radius and heat it had at the
        -- cut: only the draw runs, and lightning already under way plays out.
        -- The other stages (fire front, flora, taunt) ended with the burn.
        if wind then
          draw_sphere(g, surface, settle_radius(g.sphere_r or 0, wind))
          lightning.tick(g, surface, g.sphere_r or 0, rec.entity, spared, false)
          slay.flush()
        else
          drive_ball(rec, g, surface)
        end
      end
      local radius = g and g.sphere_r or 0
      L.sphere_r = radius

      -- ESCALATION BELONGS TO THE BATTERY, NOT TO ONE GUN. A single
      -- installation's dial stops at 100%, so its own power can never reach the
      -- overpower band; what pushes a lance past the black-body locus, widens
      -- its scorch lane and lights the bloom is how many installations are
      -- firing into this strike. Read fresh every tick because a joiner raises
      -- it mid-burn, and the group owns it (g.omega_group), not the first lance.
      if g then L.omega = g.omega_group end

      -- The beam stops on the ball's near face.
      profile.start("lance/retarget + spans")
      retarget_lance(rec, L, radius, heat.step_for(heat.kelvin(L.theta, L.omega)))
      profile.stop("lance/retarget + spans")
      profile.start("lance/bloom")
      beam.bloom(L, surface, wind and (1 - wind) ^ B.winddown.glow_exponent or 1)
      profile.stop("lance/bloom")
      profile.start("lance/map line")
      draw_lance_chart(L, surface, radius)
      profile.stop("lance/map line")

      -- What this round has done so far, for /oppenheimer-status.
      rec.last_shot = {
        killed = L.killed or 0,
        burned = g and g.burned or 0, struck = g and g.struck or 0,
        radius = radius, power = L.power or 0,
        total = g and g.power or L.power or 0, lances = g and g.lances or 1,
      }
    end
  end
end

-- =============================================================================
-- Cut
-- =============================================================================

--- Destroy the beam entities and forget the record's handle on them.
-- @return table|nil the lance record as it was, for the caller to detonate from
local function extinguish(rec)
  local L = rec.lance
  rec.lance = nil
  if not L then return nil end
  lance.destroy(L.chain)
  if L.core and L.core.valid then L.core.destroy() end
  if L.halo and L.halo.valid then L.halo.destroy() end
  return L
end

--- END OF THE SHOT. The beam goes out and the ground goes up.
--
-- C.beam.detonate_at decides which of those two is the payoff:
--   "cut"     the beam bores for the sustain and the detonation is the energy
--             letting go -- the lance vanishing and the cloud starting on the
--             same frame.
--   "ignite"  the detonation happens at the strike and the beam sustains through
--             the fireball. Handled at ignition (turret.discharge), so all this
--             does then is put the light out.
function beam.cut(rec)
  local w = B.winddown
  local live = rec.lance
  if live and w and w.enabled and w.ticks > 0 and not live.wind_at then
    -- STOP DELIVERING, STAY LIT. Everything that reaches the ground has ended;
    -- the lance now cools over w.ticks under the head of the spin-down clip
    -- (which turret.stand_down starts on this same tick) and beam.sustain calls
    -- back here when it is dark. The detonation moves with it.
    live.wind_at = game.tick
    live.wind_theta = live.theta
    return
  end

  local L = extinguish(rec)
  if not L then return end
  -- The group comes back to the call that closes it. Every lance of a group
  -- shares one cut tick, so whichever runs first this tick detonates and the
  -- rest find the group gone. Called before the detonate_at guard so the
  -- bookkeeping happens on either setting.
  local g = strike_leave(L, true)
  if B.detonate_at ~= "cut" then return end
  if not g then return end

  local surface = game.get_surface(L.surface)
  if not (surface and surface.valid) then return end
  -- The record may have lost its entity by now (mined or destroyed mid-shot), so
  -- the force falls back to the sweep's default rather than a dead handle.
  local force = rec.entity and rec.entity.valid and rec.entity.force or nil
  -- The ball's temperature and radius at the cut travel with it: the collapse
  -- starts from that colour and that size.
  profile.start("lance/cut: detonate")
  impact.detonate(surface, g.to, g.order, force,
                  heat.kelvin(g.theta_ball, g.omega_group), g.sphere_r, g.power)
  profile.stop("lance/cut: detonate")
end

-- =============================================================================
-- The ionization channel, during the charge (C.heat.haze). PURELY VISUAL.
--
-- Every piece is N.sprite.ion_glow -- a radial falloff that is zero on every
-- edge -- stretched along the line of fire. A chain of those overlapping is a
-- soft tube: no hard side, no hard end, the same long thin shape the lance has.
-- (The first version was three draw_line calls hundreds of pixels wide: a line
-- is a flat quad, so it rendered as a hard-edged panel, and its sine wobble slid
-- the whole panel sideways.)
--
-- Colours are PREMULTIPLIED (Factorio's Color concept expects it) with alpha
-- cut to `occlude` of the brightness: rgb adds light, a small alpha barely
-- darkens what is behind -- a glow, not a veil.
--
-- Everything is redrawn with a short time_to_live, the sphere's idiom -- no
-- render object to store, invalidate, or migrate.
-- =============================================================================

local atan2 = math.atan2 or math.atan
local ION_TILES = 300 / 32   -- the glow sprite's side at scale 1, in tiles

local function clamp01(v)
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end

local function smoothstep(u)
  u = clamp01(u)
  return u * u * (3 - 2 * u)
end

local function premul(c, a, keep)
  a = clamp01(a)
  return {r = c.r * a, g = c.g * a, b = c.b * a, a = a * keep}
end

-- utility/light_medium's radius at scale 1, in tiles.
local LIGHT_TILES = C.beam.sphere.lightning.light_sprite_tiles / 2

--- A two-tick light at (x, y), skipped where no player can see it.
local function light(surface, x, y, color, intensity, scale)
  if not view.disc(surface.index, x, y, LIGHT_TILES * scale) then return end
  rendering.draw_light{
    sprite = "utility/light_medium", surface = surface, target = {x, y},
    color = color, intensity = intensity, scale = scale, time_to_live = 2,
  }
end

--- One soft elongated glow centred on (cx, cy), `length` tiles along bearing
--- (ux, uy), `width` tiles across. Not drawn where no player can see it.
local function glow(surface, cx, cy, ux, uy, length, width, color, ttl, layer)
  if length <= 0 or width <= 0 or color.r + color.g + color.b <= 0 then return end
  if not view.disc(surface.index, cx, cy, 0.5 * math.max(length, width)) then return end
  rendering.draw_sprite{
    sprite       = N.sprite.ion_glow,
    surface      = surface,
    target       = {cx, cy},
    orientation  = (atan2(uy, ux) / (2 * math.pi)) % 1,
    x_scale      = length / ION_TILES,
    y_scale      = width / ION_TILES,
    tint         = color,
    render_layer = layer,
    time_to_live = ttl,
  }
end

--- A soft tube from `from`, `reach` tiles along (ux, uy). `alpha_at(i)` gives
--- each segment's alpha, so a caller can make brightness crawl along it.
--- `frac` is reach as a fraction of the full line, so a partial leader uses
--- proportionally fewer segments at the same spacing.
local function tube(surface, from, ux, uy, reach, frac, width, color, alpha_at, keep, ttl, hz, bow)
  if reach < 0.5 then return end
  local n = math.max(2, math.ceil(hz.segments * clamp01(frac)))
  local seg = reach / n
  local px, py = -uy, ux
  for i = 1, n do
    local s = (i - 0.5) * seg
    local off = bow and bow(s / reach) or 0
    -- glow() CENTRES its sprite, so an overlapped segment reaches back past
    -- `from` by (overlap - 1)/2 of a segment: at overlap 2.6 the first quad
    -- covered 0.8 segments of ground BEHIND the muzzle, which on a
    -- retreat-clamped overpressure lance is the installation itself.
    glow(surface, from.x + ux * s + px * off, from.y + uy * s + py * off, ux, uy,
         math.min(seg * hz.overlap, 2 * s), width,
         premul(color, alpha_at(i), keep), ttl, hz.render_layer)
  end
end

--- Tiles across the lance core this shot will fire -- what the channel
--- constricts onto. The same width step beam.fire picks. Exported
--- (beam.core_thickness) so arcsweep.lua's own hyper-scaled charge channel
--- (arcsweep.lua's step(), "charging" phase) matches the main sequence's
--- width formula instead of a second, independently-drifting copy of it.
local function core_thickness(power)
  return blib.body_thickness(C.beam_scale(B.core.scale_mult))
         * C.beam_size(C.beam_step_for(power or 1))
end
beam.core_thickness = core_thickness

local function mix(a, b, u)
  return {r = a.r + (b.r - a.r) * u, g = a.g + (b.g - a.g) * u, b = a.b + (b.b - a.b) * u}
end

--- THE BLOOM (C.beam.bloom). What an overpowered channel looks like after the
--- black-body locus has run out at C.heat.t_max: the lance stops reading as a
--- coloured object and starts reading as a hole punched in the scene. Additive
--- white along the live beam, widening and brightening across the overpower
--- band; nothing at all below the knee.
--
-- A MODULE MEMBER, not a local, because beam.sustain is defined ABOVE the glow
-- and tube helpers this needs: a local called from above its own declaration
-- compiles to a global read and is nil the first time it runs.
--
-- Two-tick life and no handle, like everything else drawn during the sustain.
-- `fade` is 1 during the burn and rides to 0 across the shutdown.
function beam.bloom(L, surface, fade)
  local bl = B.bloom
  if not (bl and bl.enabled) then return end
  local u = C.overpower_u(L.omega or 1, bl.exponent) * (fade or 1)
  if u <= 0.001 then return end

  local aim, len = lance_endpoint(L, L.sphere_r or 0)
  if not (aim and len and len > 1) then return end
  local from = L.from
  local ux, uy = (aim.x - from.x) / len, (aim.y - from.y) / len

  local width = core_thickness(L.power) * (1 + (bl.width_max - 1) * u)
  local alpha = bl.alpha_max * u
  local n     = bl.segments
  local seg   = len / n
  for i = 1, n do
    local s = (i - 0.5) * seg
    -- Back edge on the source, never behind it. See tube().
    glow(surface, from.x + ux * s, from.y + uy * s, ux, uy, math.min(seg * bl.overlap, 2 * s),
         width, premul(bl.color, alpha, 0), 2, bl.render_layer)
  end

  if bl.muzzle_scale_max and bl.muzzle_scale_max > 1 then
    light(surface, from.x, from.y, bl.color, 0.55 + 0.45 * u,
          1 + (bl.muzzle_scale_max - 1) * u)
  end
end

--- The channel's actual draw, parameterized on explicit geometry rather than
--- read off `rec` -- shared by beam.haze below (the main sequence's own long
--- charge, reading rec.designated/rec.yield_target) and arcsweep.lua's own
--- charging phase (a much shorter window with no rec.designated of its own:
--- writing one would risk colliding with whatever the main sequence's state
--- machine assumes that field means). `progress` is 0..1 through whichever
--- charge window the caller is on; every phase inside (leader/constrict/
--- flicker/streamers) is progress-relative, so the SAME code reads correctly
--- whether progress 0->1 takes 16 s or 1.6 s.
function beam.haze_line(surface, from, ux, uy, len, core_w, progress)
  local hz = C.heat.haze
  if not (hz and hz.enabled) then return end
  if len < 1 then return end
  progress = clamp01(progress or 0)
  if progress <= 0 then return end
  local tick = game.tick

  -- LEADER: the channel's front advances in discrete steps; `sub` is how far
  -- through the current step, so the tip flares at each new step and dims.
  local lead = clamp01(progress / hz.leader_end)
  local k    = lead * hz.leader_steps
  local reach, sub
  if lead >= 1 then
    reach, sub = len, 1
  else
    reach, sub = (math.floor(k) + 1) / hz.leader_steps * len, k - math.floor(k)
  end

  -- CONSTRICTION: the last stretch of the charge pinches the channel down
  -- onto the lance's own width and heats it toward white.
  local pinch = smoothstep((progress - hz.constrict_from) / (1 - hz.constrict_from))
  local width = core_w * (hz.width_mult + (hz.constrict_mult - hz.width_mult) * pinch)
  local color = mix(hz.color, hz.hot_color, pinch)
  local base  = hz.alpha * progress ^ hz.fade_exponent * (1 + hz.constrict_gain * pinch)
  -- Flicker tightens as breakdown approaches.
  local period = hz.flicker_period * (1 - 0.6 * pinch)

  -- BOW: the struck column sags under its own buoyancy and drifts. Zero at both
  -- ends, peaking mid-span; nothing at all before the return stroke.
  local col = hz.column
  local bow
  if col and col.enabled and lead >= 1 then
    local amp = math.min(len * col.sag_fraction, col.sag_max)
                * (1 + col.wander * math.sin(tick / col.wander_period))
    if amp > 0.01 then
      bow = function(f) return amp * math.sin(math.pi * f) end
    end
  end

  tube(surface, from, ux, uy, reach, reach / len, width, color, function(i)
    local fl = 0.6 * math.sin(tick / period + i * 1.7)
             + 0.4 * math.sin(tick / (period * 0.43) - i * 2.9)
    return base * (1 + hz.flicker * fl)
  end, hz.occlude, 2, hz, bow)

  -- THE RETURN STROKE: the front runs target -> muzzle over `span` of the
  -- charge, so it reads as the moment the channel becomes conducting.
  local st = hz.stroke
  if st and st.enabled and progress >= hz.leader_end
     and progress < hz.leader_end + st.span then
    local u = (progress - hz.leader_end) / st.span
    local at = len * (1 - u)
    local n = math.max(6, math.ceil(hz.segments * st.head))
    local run = len * st.head
    for i = 1, n do
      local s = at + (i - 0.5) / n * run
      if s >= 0 and s <= len then
        local fade = (1 - (i - 0.5) / n) * (1 - u * u)
        glow(surface, from.x + ux * s, from.y + uy * s, ux, uy,
             run / n * hz.overlap, width * st.width_mult,
             premul(hz.hot_color, st.alpha * fade, hz.occlude), 2, hz.render_layer)
      end
    end
    if st.light then
      light(surface, from.x + ux * at, from.y + uy * at, hz.hot_color,
            st.light.intensity * (1 - u), st.light.scale)
    end
  end

  -- The struck channel lights the ground it crosses.
  if col and col.enabled and lead >= 1 and col.lights > 0 then
    for i = 1, col.lights do
      local s = (i - 0.5) / col.lights * len
      light(surface, from.x + ux * s, from.y + uy * s, color,
            col.light_intensity * progress, col.light_scale)
    end
  end

  -- DEAD FORKS off the advancing leader.
  local fk = hz.fork
  if fk and fk.enabled and lead < 1 and reach > 4
     and tick % fk.interval == 0 then
    local flen = reach * fk.length
    for _ = 1, fk.count do
      local root = reach * (1 - math.random() * fk.back)
      local ang = (math.random() * 2 - 1) * 0.8
      local fx, fy = ux * math.cos(ang) - uy * math.sin(ang),
                     ux * math.sin(ang) + uy * math.cos(ang)
      local pts = boltlib.path(from.x + ux * root, from.y + uy * root,
                               from.x + ux * root + fx * flen,
                               from.y + uy * root + fy * flen,
                               fk.segs, fk.spread)
      if pts then
        for j = 2, #pts do
          local p0, p1 = pts[j - 1], pts[j]
          local sx, sy = p1[1] - p0[1], p1[2] - p0[2]
          local sl = math.sqrt(sx * sx + sy * sy)
          if sl > 1e-3 then
            glow(surface, (p0[1] + p1[1]) / 2, (p0[2] + p1[2]) / 2, sx / sl, sy / sl,
                 sl * 1.3, core_w * fk.width,
                 premul(color, fk.alpha * (1 - (j - 1) / #pts), hz.occlude),
                 fk.interval + 1, hz.render_layer)
          end
        end
      end
    end
  end

  -- THE LEADER TIP, while it is still travelling.
  if lead < 1 then
    local ta = hz.tip_alpha * math.min(1, progress * 8) * (0.35 + 0.65 * (1 - sub) ^ 2)
    local d  = core_w * hz.tip_mult
    glow(surface, from.x + ux * reach, from.y + uy * reach, ux, uy, d * 1.4, d,
         premul(hz.hot_color, ta, hz.occlude), 2, hz.render_layer)
  end

  -- CORONA at the muzzle, and its light (a night charge lights the gun up).
  local ca = hz.corona_alpha * progress ^ 1.2 * (1 + 0.25 * math.sin(tick / 2.3))
  local cd = core_w * hz.corona_mult * (0.5 + 0.5 * progress)
  glow(surface, from.x, from.y, ux, uy, cd, cd, premul(color, ca, hz.occlude), 2, hz.render_layer)
  if hz.corona_light then
    light(surface, from.x, from.y, color, hz.corona_light.intensity * progress,
          hz.corona_light.scale * (0.5 + 0.5 * progress))
  end

  -- STREAMERS: thin filaments wandering inside the channel, each shape held
  -- for filament_interval ticks and re-rolled -- the crackle inside the glow.
  if progress >= hz.filament_from and reach > 2
     and tick % hz.filament_interval == 0 then
    local fa = hz.filament_alpha * smoothstep((progress - hz.filament_from) / 0.3)
    local fw = core_w * hz.filament_width
    local jitter = (width * hz.filament_spread) / reach
    local ttl = hz.filament_interval + 1
    for _ = 1, hz.filaments do
      local pts = boltlib.path(from.x, from.y, from.x + ux * reach, from.y + uy * reach,
                               hz.filament_segs, jitter)
      if pts then
        local a = fa * (0.5 + 0.5 * math.random())
        for j = 2, #pts do
          local p0, p1 = pts[j - 1], pts[j]
          local sx, sy = p1[1] - p0[1], p1[2] - p0[2]
          local sl = math.sqrt(sx * sx + sy * sy)
          if sl > 1e-3 then
            glow(surface, (p0[1] + p1[1]) / 2, (p0[2] + p1[2]) / 2, sx / sl, sy / sl,
                 sl * 1.35, fw, premul(mix(color, hz.hot_color, 0.5), a, hz.occlude), ttl, hz.render_layer)
          end
        end
      end
    end
  end
end

--- The channel during the MAIN SEQUENCE's own charge. `progress` is 0..1
--- through the charge window (turret.fire_tick, on the audio clock) --
--- thin wrapper around haze_line, reading rec.designated/rec.yield_target
--- for the geometry/width haze_line itself no longer knows about.
function beam.haze(rec, progress)
  local e, t = rec.entity, rec.designated
  if not (e and e.valid and t) then return end
  -- The same origin the lance will light at, so ignition is not a jump.
  local from = beam.muzzle_draw(e.position, t, rec.yield_target)
  local dx, dy = t.x - from.x, t.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  beam.haze_line(e.surface, from, dx / len, dy / len, len,
                 core_thickness(rec.yield_target), progress)

  -- THE CHANNEL ON THE MAP. The charge is the only part of the sequence with
  -- nothing on the chart, and at full reach it is entirely off-screen.
  local ch = C.heat.haze.chart
  if ch and ch.enabled and C.chart_view.enabled then
    local lead = math.min(1, progress / C.heat.haze.leader_end)
    local col = ch.color
    mapdraw.line({
      color = {r = col.r, g = col.g, b = col.b, a = col.a * progress},
      width = ch.width,
      from  = from,
      to    = {x = from.x + dx * lead, y = from.y + dy * lead},
      surface = e.surface,
      time_to_live = 2,
    }, {chart_only = true, alpha_mult = 1.0, width_mult = 1.0})
  end
end

--- The handoff, for `flash.ticks`/`afterglow.ticks` after ignition
--- (turret.fire_tick). Two layers under the live lance:
---   FLASH      the breakdown: a white channel at the lance's width, decaying
---              fast -- it carries the eye across the frame the beam appears.
---   AFTERGLOW  the constricted channel the charge ended on, fading as it
---              recombines and spreading as it diffuses.
--- Drawn along the lance actually built (rec.lance), which is where the beam
--- is, not rec.designated. Nothing if the lance never lit.
function beam.haze_handoff(rec)
  local hz = C.heat.haze
  if not (hz and hz.enabled) then return end
  local L = rec.lance
  local e = rec.entity
  if not (L and e and e.valid and rec.discharged_at) then return end
  local age = game.tick - rec.discharged_at
  local fl, ag = hz.flash, hz.afterglow
  if age > math.max(fl.ticks, ag.ticks) then return end

  local surface = e.surface
  local from = L.from
  local dx, dy = L.to.x - from.x, L.to.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  local core_w = core_thickness(L.power)

  if age <= ag.ticks then
    local a = hz.alpha * (1 + hz.constrict_gain) * math.exp(-age / ag.tau)
    local w = core_w * hz.constrict_mult * (1 + ag.spread * age / ag.ticks)
    tube(surface, from, ux, uy, len, 1, w, hz.hot_color, function() return a end,
         hz.occlude, 2, hz)
  end

  if age <= fl.ticks then
    local k = math.exp(-age / fl.tau)
    local a = fl.alpha * k
    tube(surface, from, ux, uy, len, 1, core_w * fl.width_mult, fl.color,
         function() return a end, hz.occlude, 2, hz)
    for i = 0, fl.lights - 1 do
      local s = len * (i + 0.5) / fl.lights
      light(surface, from.x + ux * s, from.y + uy * s, fl.color, k, fl.light_scale)
    end
  end
end

--- Put the beam out without detonating. For a shot that ends because the
--- installation did -- mined, destroyed, scrubbed, or a bank lost mid-sequence.
--- The energy is gone either way; it just does not arrive anywhere.
function beam.abort(rec)
  -- LEAVE THE GROUP TOO. An abort destroys the lance without going through
  -- beam.cut, and a strike whose live count is never decremented never releases:
  -- the remaining lances would wait for a beam that no longer exists. The group
  -- handed back here is dropped rather than detonated -- an abort is the shot
  -- being lost, not fired.
  local L = extinguish(rec)
  if L then strike_leave(L) end
end

return beam
