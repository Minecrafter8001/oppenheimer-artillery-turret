-- lib/bolt.lua: the points of one jagged bolt, for the capacitor arcs (scripts/installfx.lua) and the ionization haze (scripts/beam.lua). Draws nothing.
-- Control stage only: math.random is Factorio's deterministic RNG there, so a bolt cannot desync.

local bolt = {}

--- Points from (x0, y0) to (x1, y1), `segs` segments, each interior vertex
--- pushed sideways by up to `jitter` x the bolt's own length -- so a long bolt
--- is as jagged in proportion as a short one. The last point lands exactly on
--- the tip: a bolt ending on a jitter offset reads as cut off, not as a strike.
-- @return array of {x, y}, or nil for a zero-length bolt
function bolt.path(x0, y0, x1, y1, segs, jitter)
  local dx, dy = x1 - x0, y1 - y0
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return nil end
  local px, py = -dy / len, dx / len
  local jit = len * jitter
  local pts = {{x0, y0}}
  for i = 1, segs do
    local t = i / segs
    local off = 0
    if i < segs then off = (math.random() * 2 - 1) * jit end
    pts[#pts + 1] = {x0 + dx * t + px * off, y0 + dy * t + py * off}
  end
  return pts
end

return bolt
