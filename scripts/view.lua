-- scripts/view.lua ---------------------------------------------------------------
-- WHO IS ACTUALLY LOOKING, AND AT WHAT.
--
-- THE PROBLEM THIS EXISTS FOR. A full-yield shot is 2000 tiles across. The
-- viewport at full zoom-out is about 500 x 280. So for most of a detonation the
-- overwhelming majority of what this mod draws is drawn where no human being
-- can see it -- and a render object costs the same whether or not it lands on
-- somebody's screen. The damage has to happen everywhere. The PICTURE does not.
--
-- scripts/slay.lua had the only watcher list in the mod (it asks "would the
-- player see this death, or can I just delete the unit"). Three more callers
-- now want the same question with different shapes, so the list moved here and
-- slay delegates: ONE rebuild per tick, one owner, per the project's own rule.
--
-- THE SHAPE OF THE QUESTION MATTERS, and this is the whole point of the module
-- rather than a single distance helper:
--
--   * a POINT (a spark, a bolt) is visible if a watcher is within view radius.
--   * a FILLED DISC (the charging sphere) is visible if a watcher is anywhere
--     within `view radius + R` of its centre -- the player may be standing
--     inside it.
--   * a RING (the shock wall, the fire wave) is visible only if the watcher's
--     own view band OVERLAPS the annulus. A player standing at ground zero
--     watching a 1500-tile front expand sees NOTHING of it: it is 1500 tiles
--     away in every direction. The naive centre-distance test says "yes,
--     visible" for exactly the case that is most expensive to draw and least
--     possible to see, which is why `ring` is not `disc`.
--
-- CULL ONLY WHAT REDRAWS. Everything culled here is a short-time_to_live object
-- that its owner redraws every tick or two, so the instant a player pans over,
-- the next redraw puts it on screen -- there is no state to repair and no way
-- to leak a permanently missing object. A PERSISTENT render object (one created
-- once and torn down explicitly later, like the designator preview) must never
-- be culled, because nothing would ever redraw it. mapdraw enforces that by
-- only culling calls that carry a time_to_live.
--
-- DETERMINISM. Exactly the assumption scripts/slay.lua has been shipping on
-- since it was written, restated here because this module is now where it
-- lives: `game.connected_players` and their `position` / `surface_index` /
-- `render_mode` are synced simulation state, so every client culls identically.
-- `position` is the CONTROLLER position, which in 2.0 follows remote view (the
-- body is `physical_position`) -- so a player watching the blast from orbit is
-- correctly counted as looking at it, not at their character.
--
-- The list is scratch, rebuilt on first use each tick and never stored.
--------------------------------------------------------------------------------

local C = require("config")

local view = {}

local TAU = math.pi * 2
local atan2 = math.atan2 or math.atan

-- SCRATCH: the watchers for WATCH_TICK, flat {surface_index, x, y, ...}.
-- World-view players only -- a player in chart mode is looking at the map, and
-- render_mode "chart" objects are what reaches them (see view.chart below).
local WATCH_TICK, WATCH = -1, {}
-- SCRATCH: surface_index -> true for any player in chart mode this tick.
local CHART_TICK, CHART = -1, {}

local function watchers()
  local tick = game.tick
  if WATCH_TICK == tick then return WATCH end
  WATCH_TICK = tick
  local w, n = WATCH, 0
  local chart = defines.render_mode.chart
  for _, pl in pairs(game.connected_players) do
    if pl.render_mode ~= chart then
      local p = pl.position
      w[n + 1], w[n + 2], w[n + 3] = pl.surface_index, p.x, p.y
      n = n + 3
    end
  end
  for i = #w, n + 1, -1 do w[i] = nil end
  return w
end

view.watchers = watchers

--- Is anyone in chart (map) mode on this surface at all?
--
-- No distance test on purpose: chart zoom is unbounded, so "where the map view
-- is centred" says nothing useful about what fits on it. This is the gate for
-- the render_mode "chart" half of every mapdraw call -- when nobody has the map
-- open, that half is pure allocation.
function view.chart(si)
  local tick = game.tick
  if CHART_TICK ~= tick then
    CHART_TICK = tick
    for k in pairs(CHART) do CHART[k] = nil end
    local chart = defines.render_mode.chart
    for _, pl in pairs(game.connected_players) do
      if pl.render_mode == chart then CHART[pl.surface_index] = true end
    end
  end
  return CHART[si] == true
end

--- The default draw-cull radius, in tiles: half the diagonal of the widest
--- viewport plus slack, from C.perf.view.
local function vr()
  return C.perf.view.radius
end

--- A POINT: is (x, y) on surface `si` within `r` tiles of a world-view player?
--- `r` is explicit because the two consumers judge differently -- slay asks
--- "close enough to see a death animation" (128), drawing asks "on screen".
function view.near(si, x, y, r)
  local w = watchers()
  local n = #w
  if n == 0 then return false end
  local r2 = r * r
  for i = 1, n, 3 do
    if w[i] == si then
      local dx, dy = w[i + 1] - x, w[i + 2] - y
      if dx * dx + dy * dy <= r2 then return true end
    end
  end
  return false
end

--- Is anything at all being watched on this surface? The cheapest possible
--- early-out for a caller about to do per-object geometry.
function view.any(si)
  local w = watchers()
  for i = 1, #w, 3 do
    if w[i] == si then return true end
  end
  return false
end

--- A FILLED DISC of `radius` at (cx, cy): visible if a watcher is inside it or
--- within view radius of its edge.
function view.disc(si, cx, cy, radius)
  if not C.perf.view.enabled then return true end
  return view.near(si, cx, cy, vr() + (radius or 0))
end

--- An ANNULUS [r_in, r_out] centred at (cx, cy): visible only where the
--- watcher's own view band overlaps the ring. See the header -- this is the
--- test that actually pays, because a wide front is invisible from its own
--- centre and `disc` would happily draw it anyway.
function view.ring(si, cx, cy, r_in, r_out)
  if not C.perf.view.enabled then return true end
  local w = watchers()
  local n = #w
  if n == 0 then return false end
  local r = vr()
  local lo, hi = r_in - r, r_out + r
  if lo < 0 then lo = 0 end
  local lo2, hi2 = lo * lo, hi * hi
  for i = 1, n, 3 do
    if w[i] == si then
      local dx, dy = w[i + 1] - cx, w[i + 2] - cy
      local d2 = dx * dx + dy * dy
      if d2 >= lo2 and d2 <= hi2 then return true end
    end
  end
  return false
end

--- The widest half-angle of the band [r_in, r_out] a watcher at distance d
--- can see, in radians. math.pi means the whole circle; nil means none of it.
--
-- A point at radius rho, bearing theta is within r of a watcher at distance d,
-- bearing phi, when cos(theta - phi) >= k, k = (rho^2 + d^2 - r^2)/(2*rho*d).
-- k is lowest (the arc widest) at rho = sqrt(d^2 - r^2), so probing both ends
-- of the band and that turning point gives the widest arc over the whole band,
-- which is the only safe direction to err in.
local function widest(d, r, r_in, r_out)
  if d <= 0 then return math.pi end
  local best
  local function probe(rho)
    if rho <= 0 then return end
    local k = (rho * rho + d * d - r * r) / (2 * rho * d)
    if not best or k < best then best = k end
  end
  probe(r_in)
  probe(r_out)
  local t2 = d * d - r * r
  if t2 > 0 then
    local rs = math.sqrt(t2)
    if rs > r_in and rs < r_out then probe(rs) end
  end
  if not best or best <= -1 then return math.pi end
  if best >= 1 then return nil end
  return math.acos(best)
end

--- WHICH PART of an annulus [r_in, r_out] at (cx, cy) anyone can see, as a flat
--- list {centre_angle, half_width, ...} in radians. `true` is every angle (or
--- culling off), nil is none.
--
-- `ring` answers yes/no for a whole circumference, which at blast radii means a
-- watcher standing beside the front buys every stamp on a ring they see a
-- fraction of. Callers that draw per angle test each one with `in_arcs`.
-- The caller must pad r_in/r_out by whatever displaces what it draws off the
-- nominal radius; the arc only ever widens with a wider band.
function view.arcs(si, cx, cy, r_in, r_out)
  if not C.perf.view.enabled then return true end
  local w = watchers()
  local n = #w
  if n == 0 then return nil end
  local r = vr()
  local out
  for i = 1, n, 3 do
    if w[i] == si then
      local dx, dy = w[i + 1] - cx, w[i + 2] - cy
      local h = widest(math.sqrt(dx * dx + dy * dy), r, r_in, r_out)
      if h then
        if h >= math.pi then return true end
        out = out or {}
        out[#out + 1] = atan2(dy, dx)
        out[#out + 1] = h
      end
    end
  end
  return out
end

--- Is bearing `a` inside anything view.arcs returned?
function view.in_arcs(arcs, a)
  if arcs == true then return true end
  if not arcs then return false end
  for i = 1, #arcs, 2 do
    local dd = a - arcs[i]
    dd = dd - TAU * math.floor((dd + math.pi) / TAU)
    local h = arcs[i + 1]
    if dd >= -h and dd <= h then return true end
  end
  return false
end

return view
