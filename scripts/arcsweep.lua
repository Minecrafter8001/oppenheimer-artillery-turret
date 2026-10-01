-- scripts/arcsweep.lua ------------------------------------------------------------
-- THE ARC SWEEP: a drag marks a span; confirm spins the barrel across it on the
-- main lance's beam, vaporizing what it crosses and walling the span with fire.
-- Runs beside the main FIRE sequence, never through it, timed off
-- sound/ArcSweep.ogg (C.sound.arc_sweep_*).
-- NEVER write rec.state/designated/spool/charge/lance: the main sequence owns them.
-- MUST call render.sync_head after every orientation write: the barrel is script-drawn.
-- State: rec.arc_sweep_mode, rec.arc_sweep_aim {a, b, centre}, rec.arc_sweep
-- {phase = "charging"|"sweeping", ...}; rec.sweep and storage.sweeps are taken.
----------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
local schema = require("scripts.schema")
local turret = require("scripts.turret")
local beam   = require("scripts.beam")
local lance  = require("scripts.lance")
local render = require("scripts.render")
local mapdraw = require("scripts.mapdraw")
local audio  = require("scripts.audio")
local heat   = require("lib.heat")
local profile = require("scripts.profile")

local arcsweep = {}

local S = C.arc_sweep

-- =============================================================================
-- Geometry -- small and self-contained, the same shape as beam.lua's own
-- private distance_to_segment/spared. Not shared via lib/: this is a few
-- lines of pure math, not the repeated PROTOTYPE structure ARCHITECTURE.md
-- rule 3 is about, and beam.lua does not share its own copy either.
-- =============================================================================

--- Perpendicular distance from `p` to the segment a->b, and where along the
--- segment the foot of that perpendicular falls (0 at a, 1 at b).
local function distance_to_segment(p, a, b)
  local abx, aby = b.x - a.x, b.y - a.y
  local len2 = abx * abx + aby * aby
  if len2 < 1e-9 then
    local dx, dy = p.x - a.x, p.y - a.y
    return math.sqrt(dx * dx + dy * dy), 0
  end
  local t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
  local ct = math.min(1, math.max(0, t))
  local fx, fy = a.x + abx * ct, a.y + aby * ct
  local dx, dy = p.x - fx, p.y - fy
  return math.sqrt(dx * dx + dy * dy), t
end

--- Same interlock as the main beam's C.beam.path: own pylons/masts are always
--- spared, a character is NEVER spared regardless of force, and everything
--- else on a force this installation is not at war with is spared only if
--- S.spares_friendly says so.
local function spared(v, e, fname)
  if v == e then return true end
  local n = v.name
  if n == N.pylon or n == N.substation then return true end
  if v.type == "character" then return false end
  return S.spares_friendly and fname ~= nil and v.force.name == fname
end

--- Vaporize everything within `half` of the segment a->b (already scaled by
--- the caller to the SAME C.beam_half_width(omega) * C.beam_size(variant) the
--- main beam's own lane uses).
local function vaporize_line(rec, e, surface, a, b, half)
  local pad = half + 1
  local area = {
    {math.min(a.x, b.x) - pad, math.min(a.y, b.y) - pad},
    {math.max(a.x, b.x) + pad, math.max(a.y, b.y) + pad},
  }
  local force, fname = e.force, e.force.name
  for _, v in pairs(surface.find_entities_filtered{area = area, type = S.types}) do
    if v.valid and v.health and not spared(v, e, fname) then
      local d, t = distance_to_segment(v.position, a, b)
      if d <= half and t >= 0 and t <= 1 then
        v.die(force, e)
        if rec.arc_sweep then
          rec.arc_sweep.killed = (rec.arc_sweep.killed or 0) + 1
        end
      end
    end
  end
end

local function cross(ax, ay, bx, by) return ax * by - ay * bx end

--- Vaporize everything the beam SWEPT between two rebuilds: the triangle
--- muzzle -> previous end -> current end, plus `half` either side of both
--- edges. A rebuild only happens every retarget_interval ticks, and between
--- two of them the lance has rotated several degrees -- at a few hundred
--- tiles out that is a gap wider than the beam itself, which is exactly where
--- biters in plain line of sight were being left alive. The wedge is the
--- ground the lance actually crossed, so nothing in it can fall between two
--- frames.
local function vaporize_wedge(rec, e, surface, o, p1, p2, half)
  local pad = half + 1
  local area = {
    {math.min(o.x, p1.x, p2.x) - pad, math.min(o.y, p1.y, p2.y) - pad},
    {math.max(o.x, p1.x, p2.x) + pad, math.max(o.y, p1.y, p2.y) + pad},
  }
  local force, fname = e.force, e.force.name
  local d1 = cross(p1.x - o.x, p1.y - o.y, p2.x - o.x, p2.y - o.y)
  for _, v in pairs(surface.find_entities_filtered{area = area, type = S.types}) do
    if v.valid and v.health and not spared(v, e, fname) then
      local q = v.position
      local hit = false
      if math.abs(d1) > 1e-9 then
        -- Inside the triangle: same side of all three edges.
        local c1 = cross(p1.x - o.x, p1.y - o.y, q.x - o.x, q.y - o.y)
        local c2 = cross(p2.x - p1.x, p2.y - p1.y, q.x - p1.x, q.y - p1.y)
        local c3 = cross(o.x - p2.x, o.y - p2.y, q.x - p2.x, q.y - p2.y)
        if d1 > 0 then
          hit = c1 >= 0 and c2 >= 0 and c3 >= 0
        else
          hit = c1 <= 0 and c2 <= 0 and c3 <= 0
        end
      end
      if not hit then
        local da, ta = distance_to_segment(q, o, p1)
        local db, tb = distance_to_segment(q, o, p2)
        hit = (da <= half and ta >= 0 and ta <= 1) or (db <= half and tb >= 0 and tb <= 1)
      end
      if hit then
        v.die(force, e)
        if rec.arc_sweep then
          rec.arc_sweep.killed = (rec.arc_sweep.killed or 0) + 1
        end
      end
    end
  end
end

--- Where the ray origin + t*dir crosses the LINE through a->b. Returns the
--- distance t along the ray (nil if parallel or behind the muzzle) and s, the
--- fraction along a->b (0 at a, 1 at b; may fall slightly outside when the
--- muzzle's offset from the turret centre skews the bearings at the ends).
local function ray_hits_line(o, dirx, diry, a, b)
  local ex, ey = b.x - a.x, b.y - a.y
  local denom = dirx * ey - diry * ex
  if math.abs(denom) < 1e-9 then return nil end
  local qx, qy = a.x - o.x, a.y - o.y
  local t = (qx * ey - qy * ex) / denom
  local s = (qx * diry - qy * dirx) / denom
  if t <= 0 then return nil end
  return t, s
end

local function point_at(a, b, s)
  return {x = a.x + (b.x - a.x) * s, y = a.y + (b.y - a.y) * s}
end

--- Lay the WALL OF FIRE along the part of the marked span the beam's end
--- has just crossed (s0 -> s1 along a->b) -- density per TILE of span, not a
--- flat count per refresh, so the wall is equally thick whatever the drag
--- length (sw.fire_per_tile is settled once at CONFIRM against
--- S.wall.max_fires). Fractional fires carry to the next refresh instead of
--- rounding away. N.scorch_flame: the mod's own NON-SPREADING fire.
local function lay_wall(sw, surface, s0, s1)
  local W = S.wall
  local a, b = sw.a, sw.b
  local ex, ey = b.x - a.x, b.y - a.y
  local len = math.sqrt(ex * ex + ey * ey)
  if len < 1e-6 then return end
  local ux, uy = ex / len, ey / len
  local px, py = -uy, ux
  local lo, hi = math.min(s0, s1), math.max(s0, s1)
  local want = (hi - lo) * len * sw.fire_per_tile + (sw.fire_carry or 0)
  local n = math.floor(want)
  sw.fire_carry = want - n
  for _ = 1, n do
    local s = lo + (hi - lo) * math.random()
    local jitter = (math.random() * 2 - 1) * W.spread
    surface.create_entity{
      name = N.scorch_flame,
      position = {x = a.x + ex * s + px * jitter, y = a.y + ey * s + py * jitter},
    }
  end
end

--- The wall is LETHAL, not just drawn: anything inside its half-width along
--- the traced part of the span dies -- walking into it later included, for as
--- long as its fire burns (wall records outlive the sweep; see burn_walls).
local function wall_kill(rec, e, surface, wall)
  if wall.hi - wall.lo <= 0 then return end
  local from = point_at(wall.a, wall.b, wall.lo)
  local to   = point_at(wall.a, wall.b, wall.hi)
  vaporize_line(rec, e, surface, from, to, S.wall.spread + S.wall.kill_pad)
end

--- Destroy whatever the sweep currently has lit, if anything.
local function extinguish(sw)
  lance.destroy(sw.chain)
  sw.chain = nil
end

--- Where the current bearing puts the beam's end. PURE GEOMETRY, no side
--- effects, so it is free to run every tick.
---
--- THE BEAM ENDS ON THE MARKED SPAN, not at full reach: its target is where
--- the current bearing crosses the line the player drew (ray_hits_line) --
--- the same "target_position is a GROUND point" beam.fire uses. Only if the
--- bearing somehow misses that line (parallel, or behind the muzzle) does it
--- fall back to sw.range.
---
--- @return from MapPosition   the muzzle sprite origin, up the tower
--- @return ground MapPosition the muzzle on the ground, what the weapon cuts from
--- @return hit MapPosition    where the bearing lands
--- @return s number|nil       fraction along the marked span, nil on a miss
local function bearing_hit(sw, e, want)
  local a2 = want * 2 * math.pi
  -- Factorio orientation: 0 = north, clockwise, screen Y grows downward --
  -- same convention scripts/beam.lua's own barrel_vector uses.
  local dirx, diry = math.sin(a2), -math.cos(a2)
  -- beam.muzzle/beam.muzzle_ground only use direction from this point.
  local far = {x = e.position.x + dirx * 100, y = e.position.y + diry * 100}
  local from   = beam.muzzle(e.position, far)
  local ground = beam.muzzle_ground(e.position, far)

  local dist, s = nil, nil
  if sw.a and sw.b then dist, s = ray_hits_line(ground, dirx, diry, sw.a, sw.b) end
  if not dist or dist > sw.range then dist, s = sw.range, nil end
  return from, ground, {x = ground.x + dirx * dist, y = ground.y + diry * dist}, s
end

--- Put the lance on the current bearing: open the chain on the first tick, then
--- move its spans every tick (scripts/lance.lua). Its colour is its temperature
--- (C.heat), integrated every tick in step(); a new step replaces spans a few a
--- tick rather than the whole beam.
local function aim_beam(sw, e, surface, from, hit)
  local hstep = heat.step_for(heat.kelvin(sw.theta, sw.omega))
  local remaining = (sw.started + S.sustain_ticks) - game.tick
  if remaining < 2 then return end
  -- Six ticks of slack past the end, so a span built on the last tick still draws
  -- through the final frame.
  local duration = remaining + 6
  if not sw.chain then
    sw.chain = lance.open(surface, e.force, from, hit, sw.variant, hstep, duration, sw.max_len)
    return
  end
  lance.step(sw.chain, from, hit, hstep, duration, true)
end

--- Pay for the ground the beam swept since the last payout: vaporize the wedge
--- between the last paid bearing and this one, then lay the wall of fire along
--- the stretch of marked span the end point has crossed.
---
--- ON C.arc_sweep.retarget_interval, NOT PER TICK, and deliberately unchanged:
--- the wedge is the swept triangle, so paying it every 6 ticks kills exactly
--- what paying it every tick would, for a sixth of the searches. Between two
--- payouts the beam has still moved -- it just hasn't billed yet.
local function pay(rec, e, surface, ground, hit, s)
  local sw = rec.arc_sweep
  -- SAME derivation the main beam's lane uses: the halo's own scale, at this variant's
  -- size, times this file's own extra tuning knob.
  local half = C.beam_half_width(sw.omega) * C.beam_size(sw.variant) * S.width_mult
  if sw.prev_hit then
    vaporize_wedge(rec, e, surface, ground, sw.prev_hit, hit, half)
  else
    vaporize_line(rec, e, surface, ground, hit, half)
  end
  sw.prev_hit = hit

  if s and sw.wall then
    s = math.min(1, math.max(0, s))
    local w = sw.wall
    local last = sw.last_s or s
    if S.wall.enabled then lay_wall(sw, surface, last, s) end
    sw.last_s = s
    if w.lo == nil then w.lo, w.hi = math.min(last, s), math.max(last, s) end
    if s < w.lo then w.lo = s end
    if s > w.hi then w.hi = s end
    wall_kill(rec, e, surface, w)
  end
end

-- =============================================================================
-- Mode toggle -- scripts/gui.lua calls this
-- =============================================================================

--- Flip rec.arc_sweep_mode. Turning it off also drops a pending (unconfirmed)
--- aim -- a stale marked span from a previous session with the mode on should
--- not silently reappear armed the next time it is switched back on.
function arcsweep.set_mode(rec, on)
  rec.arc_sweep_mode = on or nil
  if not on then rec.arc_sweep_aim = nil end
end

-- =============================================================================
-- Aim -- a drag marks (or re-marks) a span. Does not touch the barrel.
-- =============================================================================

--- @param rec  turret record
--- @param a, b MapPosition  the two ends of the drag, read off the ground
--- @param centre MapPosition  the drag's own centre -- what a later press is
---        kept for the record; CONFIRM is the HUD button (arcsweep.pending)
--- @return boolean ok, string|nil why
function arcsweep.aim(rec, a, b, centre)
  if not (S and S.enabled) then return false, "disabled" end
  if rec.arc_sweep then return false, "busy" end
  if rec.state ~= turret.STANDBY then return false, rec.state end

  local e = rec.entity
  if not (e and e.valid) then return false, "invalid" end

  rec.arc_sweep_aim = {a = a, b = b, centre = centre}
  turret.say(rec, "arc-sweep-marked")
  return true
end

--- Is a marked span waiting for the HUD's CONFIRM? (scripts/gui.lua enables
--- the button on this.) A drag marks; CONFIRM fires -- there is no
--- press-on-the-map confirm, which proved hard to hit.
function arcsweep.pending(rec)
  return rec.arc_sweep_aim ~= nil and rec.arc_sweep == nil
end

--- ABORT on the HUD while a span is marked: drop it.
function arcsweep.cancel(rec)
  if not rec.arc_sweep_aim then return false end
  rec.arc_sweep_aim = nil
  turret.say(rec, "arc-sweep-cancelled")
  return true
end

--- Fires per tile of span: S.wall.fires_per_tile, thinned only if a very
--- long drag would push one wall past S.wall.max_fires in total.
local function fire_density(a, b, omega)
  local W = S.wall
  local dx, dy = b.x - a.x, b.y - a.y
  local len = math.max(1, math.sqrt(dx * dx + dy * dy))
  local per = W.fires_per_tile
               * C.overpower_gain(omega or 1, S.overpower.fires_max, S.overpower.exponent)
  return math.min(per, W.max_fires / len)
end

-- =============================================================================
-- Confirm -- commits the pending aim: settles the geometry, snaps the barrel
-- to the sweep's own starting bearing, and starts the charge-up.
-- =============================================================================

--- @return boolean ok, string|nil why (state name, or "busy"/"cooldown"/
---         "blind"/"invalid"/"disabled"/"no-aim")
function arcsweep.confirm(rec)
  local aim = rec.arc_sweep_aim
  if not aim then return false, "no-aim" end
  if not (S and S.enabled) then return false, "disabled" end
  if rec.arc_sweep then return false, "busy" end
  if rec.state ~= turret.STANDBY then return false, rec.state end
  if (rec.arc_sweep_ready_at or 0) > game.tick then return false, "cooldown" end

  local e = rec.entity
  if not (e and e.valid) then return false, "invalid" end

  local have = turret.read_orientation(e)
  if not have then return false, "blind" end

    -- The barrel runs aim.a -> aim.b, press to release (scripts/remote.lua): a
    -- sweep drawn right to left runs right to left. MUST NOT start from the end
    -- nearer the barrel, which reverses half of all drags. The width is the
    -- variant this installation's panel is dialled to now.
  local power = rec.yield_target or C.charge.yield_default
  local omega = C.overpower(power)

  -- THE OVERPOWER BAND EXTENDS THE SPAN, outward from its own midpoint, so the
  -- line the player drew stays where they drew it and the surplus overshoots
  -- both ends. A sweep bills an annulus, R x width, so this is linear in power
  -- where a bigger crater would have been quadratic.
  local sa, sb = aim.a, aim.b
  local ext = C.overpower_gain(omega, S.overpower.span_max, S.overpower.exponent)
  if ext > 1 then
    local mx, my = (sa.x + sb.x) / 2, (sa.y + sb.y) / 2
    sa = {x = mx + (sa.x - mx) * ext, y = my + (sa.y - my) * ext}
    sb = {x = mx + (sb.x - mx) * ext, y = my + (sb.y - my) * ext}
  end

  local start_o, end_o = turret.bearing_to(e, sa), turret.bearing_to(e, sb)
  local total = turret.shortest(start_o, end_o)

  rec.arc_sweep_aim = nil

  -- THE CHARGE PHASE ITSELF DOES THE ROTATION -- confirm() no longer snaps
  -- the barrel to start_o instantly. When charging is enabled the barrel
  -- travels from wherever it currently is (`have`) to start_o gradually,
  -- across the first S.charge_ticks (1.6 s -- ArcSweep.ogg's own measured
  -- charge portion, see C.sound), landing on it exactly as the sweep begins.
  -- Only the disabled fallback still snaps instantly, since there is then no
  -- charge window to travel across.
  local charging = S.charge and S.charge.enabled
  if not charging then
    turret.write_orientation(e, start_o)
    render.sync_head(rec, start_o)
  end

  rec.arc_sweep = {
    phase       = charging and "charging" or "sweeping",
    start_o     = start_o,
    charge_from = have,   -- where the barrel starts its rotate-into-position
    total       = total,
    started     = game.tick,
    next_tick   = game.tick,
    variant     = C.beam_step_for(power),
    power       = power,   -- same dial value beam.core_thickness wants, for
                            -- the charge phase's own ionization channel width
    omega       = omega,   -- the lane's own band, as the main beam's lane uses
    max_len     = C.reach() * C.beam.max_length_factor,
    range      = C.reach(),
    killed     = 0,
    theta      = 0,     -- the lance's temperature (C.heat), cold at the start
    -- The marked span itself: where the beam ENDS (refresh's ray_hits_line)
    -- and the only ground the wall of fire is laid on.
    a          = sa,
    b          = sb,
    wall       = {a = sa, b = sb},   -- lo/hi: the traced fraction
    fire_per_tile = fire_density(sa, sb, omega),
  }

  -- ArcSweep.ogg IS THE WHOLE SEQUENCE -- charge, fire and discharge already
  -- layered into the user's own mix -- so it plays exactly ONCE here,
  -- whichever phase confirm() starts in. There is no separate charge clip to
  -- trigger any more (see C.arc_sweep.charge's own comment).
  audio.broadcast(e.surface, e.position, N.sound.arc_sweep, {volume = 0.9})
  turret.say(rec, charging and "arc-sweep-charging" or "arc-sweep-fired")
  return true
end

-- =============================================================================
-- Per-tick step
-- =============================================================================

--- The sweep is over but its fire burns on: keep the traced wall lethal for
--- S.wall.burn_ticks (the fire's own lifetime, C.blast.scorch.lifetime --
--- derived below in config, so the kill zone and the visible flames go out
--- together). A list, so a second sweep fired while the first wall still
--- burns does not quietly disarm it.
local function leave_wall(rec, sw)
  local w = sw.wall
  if not (w and w.lo and w.hi > w.lo) then return end
  w.until_tick = game.tick + S.wall.burn_ticks
  w.next_kill  = game.tick + S.wall.kill_interval
  rec.arc_walls = rec.arc_walls or {}
  rec.arc_walls[#rec.arc_walls + 1] = w
end

--- Keep every standing wall lethal until its fire is out.
local function burn_walls(rec)
  local walls = rec.arc_walls
  local e = rec.entity
  for i = #walls, 1, -1 do
    local w = walls[i]
    if game.tick >= w.until_tick then
      table.remove(walls, i)
    elseif game.tick >= w.next_kill then
      w.next_kill = game.tick + S.wall.kill_interval
      wall_kill(rec, e, e.surface, w)
    end
  end
  if #walls == 0 then rec.arc_walls = nil end
end

--- One tick of a live sweep. Self-terminating on its own elapsed fraction of
--- C.arc_sweep.charge_ticks/sustain_ticks -- same idiom as beam.lua's
--- sphere_radius/L.cut_at -- no separate timer to keep in step.
local function step(rec)
  local sw = rec.arc_sweep
  if not sw then return end

  local e = rec.entity
  if not (e and e.valid) then extinguish(sw); rec.arc_sweep = nil; return end

  if sw.phase == "charging" then
    -- THE WIND-UP IS A SLEW, NOT A HOLD: the barrel travels from wherever it
    -- was aimed (sw.charge_from) to the sweep's own starting bearing
    -- (sw.start_o) across S.charge_ticks (ArcSweep.ogg's own measured 1.6 s
    -- charge portion), landing exactly as the clip's fire portion begins --
    -- turret.shortest gives the same <=180deg path the rest of this file's
    -- orientation math already uses, so this never spins the long way round.
    local span = math.max(1, S.charge_ticks)
    local ct = (game.tick - sw.started) / span
    local done = ct >= 1
    if ct < 0 then ct = 0 elseif ct > 1 then ct = 1 end
    local want = (sw.charge_from + turret.shortest(sw.charge_from, sw.start_o) * ct) % 1

    if not turret.write_orientation(e, want) then
      -- Same fallback the sweeping phase below already lives with: cannot
      -- aim, so give up rather than pretend the charge is still advancing.
      -- Nothing has fired yet, so there is nothing to extinguish and no wall
      -- to leave behind -- just drop the sweep.
      rec.arc_sweep = nil
      return
    end
    render.sync_head(rec, want)

    -- THE HYPER-SCALED IONIZATION CHANNEL -- the same visual the main
    -- lance's own charge builds (beam.haze_line), reused here at this
    -- sweep's own much faster pace: `ct` 0->1 plays every phase inside it
    -- (leader/constrict/flicker/streamers) in 1.6 s instead of the main
    -- sequence's own ~16 s, since every phase in there is progress-relative,
    -- not tick-absolute. Reach ends where the beam will actually first
    -- strike -- the same ray_hits_line cast against the marked span bearing_hit()
    -- uses -- clamped to sw.range so a miss (parallel bearing, or the span
    -- behind the muzzle) draws a channel of a sane length instead of none.
    local a2 = want * 2 * math.pi
    local dirx, diry = math.sin(a2), -math.cos(a2)
    local far = {x = e.position.x + dirx * 100, y = e.position.y + diry * 100}
    local from   = beam.muzzle(e.position, far)
    local ground = beam.muzzle_ground(e.position, far)
    local dist = nil
    if sw.a and sw.b then dist = ray_hits_line(ground, dirx, diry, sw.a, sw.b) end
    if not dist or dist > sw.range then dist = sw.range end
    beam.haze_line(e.surface, from, dirx, diry, dist, beam.core_thickness(sw.power), ct)

    if done then
      sw.phase = "sweeping"
      sw.started = game.tick
      sw.next_tick = game.tick
      turret.say(rec, "arc-sweep-fired")
    end
    return
  end

  -- phase == "sweeping"
  sw.theta = heat.advance(sw.theta, sw.variant or 0,
                          C.heat.tau_sweep)
  local span = math.max(1, S.sustain_ticks)
  local t = (game.tick - sw.started) / span
  local done = t >= 1
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local want = (sw.start_o + sw.total * t) % 1

  if not turret.write_orientation(e, want) then
    -- Same fallback the main slew already lives with: cannot aim, so stop
    -- spending a pcall on it every tick rather than pretend the sweep is
    -- still happening.
    extinguish(sw)
    leave_wall(rec, sw)
    rec.arc_sweep = nil
    return
  end
  render.sync_head(rec, want)

  -- THE BEAM FOLLOWS THE BARREL EVERY TICK; the damage bills on the interval.
  -- `done` forces one last payout so the wall reaches the span's far end
  -- instead of stopping up to one interval short of it.
  local from, ground, hit, s = bearing_hit(sw, e, want)
  local payout = done or game.tick >= (sw.next_tick or 0)
  aim_beam(sw, e, e.surface, from, hit)
  if payout then
    sw.next_tick = game.tick + S.retarget_interval
    pay(rec, e, e.surface, ground, hit, s)
  end

  if done then
    extinguish(sw)
    turret.say(rec, "arc-sweep-done", tostring(sw.killed or 0))
    leave_wall(rec, sw)
    rec.arc_sweep = nil
    rec.arc_sweep_ready_at = game.tick + S.cooldown_ticks
  end
end

--- Redraw the marked-span preview for a pending (unconfirmed) aim -- world
--- AND chart (mapdraw.line draws both in one call). Short-lived and redrawn
--- every tick, same "no object to persist, migrate, or leak; stop calling it
--- and it is gone" idiom this mod already uses for the sphere and its
--- streaks -- so a turret destroyed or a mode switched off mid-aim needs no
--- explicit cleanup: the loop below simply stops being called for it, and
--- the render object it last drew expires on its own within a couple ticks.
local function draw_aim_preview(rec, e)
  local aim = rec.arc_sweep_aim
  if not aim then return end
  mapdraw.line{
    color = S.aim_color, width = S.aim_draw_width,
    from = aim.a, to = aim.b, surface = e.surface, time_to_live = 3,
  }
end

-- Its own registration, not threaded through turret.lua's per-tick loop --
-- scripts/events.lua's on_nth_tick fans out multiple registrants for the same
-- interval (the whole reason that dispatcher exists), so this runs alongside
-- that loop rather than needing turret.lua to know this file exists at all.
-- Requiring turret.lua the other way (for turret.STANDBY / the orientation
-- exports) is a one-way dependency, not a cycle: turret.lua never requires
-- this file.
events.on_nth_tick(1, function()
  for _, rec in pairs(storage.turrets or {}) do
    if schema.valid(rec) then
      profile.start("arc sweep")
      if rec.arc_walls then burn_walls(rec) end
      if rec.arc_sweep then
        step(rec)
      elseif rec.arc_sweep_aim then
        draw_aim_preview(rec, rec.entity)
      end
      profile.stop("arc sweep")
    end
  end
end)

return arcsweep
