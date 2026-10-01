-- scripts/mapdraw.lua -------------------------------------------------------------
-- THE EVENT IS DRAWN ON THE MAP TOO.
--
-- THE PROBLEM, and this mod has been circling it. A full-yield
-- shot is 2000 tiles across and the viewport at full zoom-out is about 500 wide,
-- so the largest thing this weapon does CANNOT BE SEEN while it happens. That is
-- why C.beam.sphere.chart exists: the map uncovers the footprint as the ball
-- grows, so the player has somewhere to watch it from.
--
-- Except there was nothing to watch. Charting reveals the GROUND. The event
-- itself -- the sphere, the collapse, the wave -- is drawn with
-- rendering.draw_circle, which defaults to render_mode "game" and is therefore
-- invisible the moment the player opens the map. So 0.14.13 built the player a
-- window and then drew the show on the other wall.
--
-- The explosions cannot help: every VFX prototype in this mod carries the
-- "not-on-map" flag, which is correct -- a thousand shockwave puffs rendered as
-- map icons would be a solid block of colour -- and it is not conditional, so
-- there is no version of them that appears on the chart.
--
-- WHAT ACTUALLY WORKS. ScriptRenderMode in the 2.0.77 spec has exactly two
-- values, "game" and "chart", and every rendering.draw_* takes one. There is no
-- "both": a chart object is invisible in the world and a game object is
-- invisible on the map. So anything that should appear in both places has to be
-- drawn TWICE, which is what this module is for -- one call site, two objects,
-- and no chance of the map copy drifting from the world copy because they are
-- built from the same table.
--
-- THE MAP COPY IS NOT A COPY. It is deliberately re-tinted and re-weighted:
-- the world view is a lit scene where a 30%-alpha black disc reads as a shadow,
-- and the chart is a flat diagram where the same disc reads as nothing at all.
-- C.chart_view carries the two multipliers.
--
-- COST. One extra render object per drawn circle per tick, with the same two
-- tick TTL as everything else here -- and a chart object is not rendered at all
-- while the player is in world view. The floor (`min_radius`) exists because a
-- four tile ball is a sub-pixel dot at map zoom, so drawing it is paying for an
-- object nobody can resolve.
----------------------------------------------------------------------------------

-- TWO CULLS. The chart copy is drawn only while someone has the map open
-- (view.chart()), and a line shorter than min_length is skipped as sub-pixel.
-- The world copy is drawn only near a world-view player (scripts/view.lua).
-- ONLY SHORT-LIVED OBJECTS ARE CULLED: a call without time_to_live is persistent,
-- and culling it would delete it forever and hand its caller a nil handle.

local C    = require("config")
local view = require("scripts.view")

local mapdraw = {}

--- A MapPosition in either of the two forms the API accepts, as two numbers.
local function xy(t)
  if not t then return nil end
  if t.x then return t.x, t.y end
  return t[1], t[2]
end

--- The surface index of whatever a caller passed as `surface`.
local function sindex(s)
  if type(s) == "table" and s.index then return s.index end
  if type(s) == "number" then return s end
  return nil
end

--- Should the WORLD copy of this call be drawn at all? `pad` is the object's
--- own reach from its anchor (0 for a point, its radius for a disc).
local function world_seen(p, x, y, pad)
  if p.time_to_live == nil then return true end      -- persistent: never culled
  if not C.perf.view.enabled then return true end
  local si = sindex(p.surface)
  if not si or not x then return true end            -- unknown: draw, don't guess
  return view.disc(si, x, y, pad or 0)
end

--- ...and the CHART copy? Nobody on the map, nothing to draw for.
local function chart_seen(p)
  if p.time_to_live == nil then return true end
  if not C.perf.view.enabled then return true end
  local si = sindex(p.surface)
  if not si then return true end
  return view.chart(si)
end

--- Re-tint a colour for the chart, without touching the caller's table.
--
-- MUST NOT MUTATE. Every caller passes a colour straight out of config.lua --
-- C.beam.sphere.fill_color, C.blast.implosion.ball.shadow_color -- and scaling
-- one in place would permanently dim it for every future shot in the session,
-- compounding once per tick. That is the kind of bug that looks like a slow
-- graphical fade and is actually config rot.
local function chart_color(c, mult)
  local a = (c.a or 1) * mult
  if a > 1 then a = 1 elseif a < 0 then a = 0 end
  return {r = c.r, g = c.g, b = c.b, a = a}
end

--- Draw a circle in the world, on the map, or both.
--
-- @param p   table  a normal rendering.draw_circle parameter table -- `forces`
--                    and `players`, if given, restrict BOTH copies, not just
--                    the world one (0.21.0; see the return value note below)
-- @param opt table|nil
--        chart_only  -- skip the world copy (for things the world already shows
--                       as a real entity, like the beam)
--        alpha_mult  -- override C.chart_view.alpha_mult for this call
--        width_mult  -- override C.chart_view.width_mult. Pass 1.0 for anything
--                       whose width was tuned FOR the map: the global multiplier
--                       exists to thin strokes authored for the world, and
--                       applying it to a map-native number thins it twice.
--        min_radius  -- override the floor for this call
-- @return LuaRenderObject|nil world, LuaRenderObject|nil chart
--         every existing caller here draws with a short time_to_live and
--         never looks at the return, so adding it changes nothing for them. It
--         exists for a caller that needs a PERSISTENT pair -- created once, torn
--         down explicitly later (scripts/render.lua's designator preview) -- the
--         same reason rendering.draw_circle itself returns a handle.
function mapdraw.circle(p, opt)
  opt = opt or {}
  local r = p.radius or 0
  local cx, cy = xy(p.target)

  local world = nil
  if not opt.chart_only and world_seen(p, cx, cy, r) then
    world = rendering.draw_circle(p)
  end

  local m = C.chart_view
  if not m.enabled then return world end
  if not chart_seen(p) then return world end

  local floor = opt.min_radius or m.min_radius
  if r < floor then return world end

  local chart = rendering.draw_circle{
    color   = chart_color(p.color, opt.alpha_mult or m.alpha_mult),
    radius  = r,
    filled  = p.filled,
    -- Width is in PIXELS and the map is a different zoom, so a hairline in the
    -- world is a hairline on the map regardless of how many tiles across the
    -- circle is. It gets its own multiplier rather than the world's value.
    width   = p.width and (p.width * (opt.width_mult or m.width_mult)) or nil,
    target  = p.target,
    surface = p.surface,
    time_to_live = p.time_to_live,
    render_mode  = "chart",
    -- forwarded, where every prior caller left them nil (global). A
    -- caller that restricted the world copy to one force almost certainly wants
    -- the chart copy restricted the same way, not leaked to everyone.
    forces  = p.forces,
    players = p.players,
  }
  return world, chart
end

--- The same for a line.
function mapdraw.line(p, opt)
  opt = opt or {}
  local x0, y0 = xy(p.from)
  local x1, y1 = xy(p.to)

  -- A line's anchor is its midpoint and its reach is half its length, so one
  -- disc test covers the whole segment.
  local mx, my, half
  if x0 and x1 then
    local dx, dy = x1 - x0, y1 - y0
    mx, my = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    half = math.sqrt(dx * dx + dy * dy) * 0.5
  end

  if not opt.chart_only and world_seen(p, mx, my, half) then
    rendering.draw_line(p)
  end

  local m = C.chart_view
  if not m.enabled then return end
  if not chart_seen(p) then return end

  -- THE FLOOR CIRCLES HAVE HAD SINCE 0.14.13, FOR LINES. A bolt is four or five
  -- short segments; at chart zoom the whole bolt is a dot, so the map copy of
  -- each segment is an object drawn for a sub-pixel. Skip anything shorter than
  -- min_length end to end -- measured on the WHOLE line, via `half`, not per
  -- segment, so a long line is never dropped for being drawn in pieces.
  local floor = opt.min_length or m.min_length
  if floor and half and half * 2 < floor then return end

  rendering.draw_line{
    color = chart_color(p.color, opt.alpha_mult or m.alpha_mult),
    width = (p.width or 1) * (opt.width_mult or m.width_mult),
    from  = p.from,
    to    = p.to,
    surface = p.surface,
    time_to_live = p.time_to_live,
    render_mode  = "chart",
  }
end

return mapdraw
