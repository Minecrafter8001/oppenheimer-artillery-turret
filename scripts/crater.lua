-- scripts/crater.lua: the ground a blast leaves. The floor is graded by the
-- peak temperature the ground law gives each radius; under the fireball a glaze
-- of molten fallback crusts, freezes and goes dark on C.heat.ground's clock, over
-- the crater the burst dug at ground zero. What stood on the glaze is vaporized,
-- decoratives and cliffs are cleared behind the front, and all of it is laid on
-- chunks generated inside the blast later.

local C       = require("config")
local N       = require("lib.names")
local heat    = require("lib.heat")
local events  = require("scripts.events")
local front   = require("scripts.front")
local profile = require("scripts.profile")
local slay    = require("scripts.slay")

local crater = {}

local CHUNK = 32
local AREA  = CHUNK * CHUNK
local DIAG  = 46
local CELL  = 8
local CELL_DIAG = 12
local TAU   = 2 * math.pi
local sqrt, floor, ceil, sin, cos = math.sqrt, math.floor, math.ceil, math.sin, math.cos
local atan2 = math.atan2 or math.atan

local POW2 = {}
for i = 0, CHUNK - 1 do POW2[i] = 2 ^ i end

local VANISH = {unit = true, ["spider-unit"] = true, ["segmented-unit"] = true}
-- The glaze's events: C.heat.ground.cooling's "solid", or the surface temperature named.
local EVENTS = {crust = "t_melt", dark = "draper", solid = true}

local function chunk_key(ci, cj) return (cj + 32768) * 65536 + (ci + 32768) end
local function key_ci(key) return key % 65536 - 32768 end
local function key_cj(key) return floor(key / 65536) - 32768 end

-- Scratch derived from prototypes and config on first use: identical on every client, never state.
local FLUIDS, MOLTEN, NON_DECALS, LOBE_NORM, BOIL
local LADDERS = {}

-- Each crater's bands for the current tick.
local NOW_TICK, NOW = -1, {}

-- Per-tile tables handed to set_tiles, reused: set_tiles copies them before returning.
local POOL = {}

local function on_nauvis(surface)
  local planet = surface.planet
  return (planet and planet.name == "nauvis") or (not planet and surface.name == "nauvis")
end

local function surface_tile(surface, name)
  return on_nauvis(surface) and N.nauvis_tiles[name] or name
end

local function near_chunk(x, y, ci, cj)
  local lx, ly = ci * CHUNK, cj * CHUNK
  local dx, dy = 0, 0
  if x < lx then dx = lx - x elseif x > lx + CHUNK then dx = x - (lx + CHUNK) end
  if y < ly then dy = ly - y elseif y > ly + CHUNK then dy = y - (ly + CHUNK) end
  return sqrt(dx * dx + dy * dy)
end

--- Every liquid tile name.
local function fluid_names()
  if FLUIDS then return FLUIDS end
  FLUIDS = {}
  for name, tp in pairs(prototypes.tile) do
    local mask = tp.collision_mask
    if tp.fluid or (mask and mask.layers and mask.layers.water_tile) then
      FLUIDS[#FLUIDS + 1] = name
    end
  end
  return FLUIDS
end

--- Tiles carrying molten_tile's fluid, as a set.
local function molten()
  if MOLTEN then return MOLTEN end
  MOLTEN = {}
  local m = C.blast.rings.paint.molten_tile
  local mf = m and prototypes.tile[m] and prototypes.tile[m].fluid
  if mf then
    local mfn = type(mf) == "string" and mf or mf.name
    for name, tp in pairs(prototypes.tile) do
      local f = tp.fluid
      if f and (type(f) == "string" and f or f.name) == mfn then MOLTEN[name] = true end
    end
  end
  return MOLTEN
end

--- Whether a tile holds the molten fluid (lava).
function crater.molten(name)
  return name == N.tiles.lava or name == N.nauvis_tiles[N.tiles.lava]
         or molten()[name] == true
end

--- Whether a liquid tile is shallow enough for the fireball to boil dry.
local function boils(name)
  if not BOIL then
    BOIL = {}
    for _, t in ipairs(C.blast.rings.paint.boil_off or {}) do BOIL[t] = true end
  end
  return BOIL[name] == true
end

local function non_decals()
  if NON_DECALS then return NON_DECALS end
  NON_DECALS = {}
  for name, p in pairs(prototypes.decorative) do
    if not p.decal then NON_DECALS[#NON_DECALS + 1] = name end
  end
  return NON_DECALS
end

--- Largest u in [0, u_lim] whose peak ground temperature is at least k.
local function edge_u(k, u_lim)
  local law = C.blast.rings.groundfire.kelvin
  if law(0) < k then return 0 end
  if law(u_lim) >= k then return u_lim end
  local lo, hi = 0, u_lim
  for _ = 1, 40 do
    local mid = (lo + hi) * 0.5
    if law(mid) >= k then lo = mid else hi = mid end
  end
  return lo
end

--- "graded" when every ladder and glaze tile exists, else "flat".
local function ladder_key()
  local pc = C.blast.rings.paint
  if not (pc.ladder and #pc.ladder > 0) then return "flat" end
  for _, step in ipairs(pc.ladder) do
    if not prototypes.tile[step.tile] then return "flat" end
  end
  for _, st in ipairs(pc.glaze or {}) do
    if not prototypes.tile[st.tile] then return "flat" end
  end
  return "graded"
end

--- A ladder: the cold floor inside out with its outer edges (fraction of R), the glaze's tiles hottest first with the event that ends each (`ev`), and the crater's floor and rim tiles when they exist.
local function ladder(key)
  local lad = LADDERS[key]
  if lad then return lad end
  local pc = C.blast.rings.paint
  local steps, u_lim = pc.ladder, pc.radius_fraction
  local glaze = {}
  if key == "graded" then
    for i, st in ipairs(pc.glaze or {}) do
      assert(EVENTS[st.ends], "C.blast.rings.paint.glaze: unknown event " .. tostring(st.ends))
      if prototypes.tile[st.tile] then
        glaze[#glaze + 1] = st
      end
    end
  else
    local t = C.blast.scar.tile_name
    if not (t and prototypes.tile[t]) then t = N.tiles.nuclear_ground end
    steps, u_lim = {{tile = t, kelvin = 0}}, pc.radius_fraction_base
  end
  lad = {u = u_lim, cold = {}, glaze = glaze, ev = {}}
  local prev = 0
  for i, step in ipairs(steps) do
    local u = (i == #steps) and u_lim or edge_u(step.kelvin, u_lim)
    if u < prev then u = prev end
    prev = u
    lad.cold[i] = {tile = step.tile, u = u}
  end
  for i, st in ipairs(glaze) do lad.ev[i] = st.ends end
  local cc = pc.crater
  if key == "graded" and cc and cc.enabled and prototypes.tile[cc.floor] and prototypes.tile[cc.rim] then
    lad.floor, lad.rim = cc.floor, cc.rim
  end
  LADDERS[key] = lad
  return lad
end

--- The kelvin (or "solid") heat.glaze_seconds takes for a glaze event.
local function event_kelvin(ev)
  local key = EVENTS[ev]
  if key == true then return ev end
  return C.heat.ground[key]
end

--- The tile at normalised radius m, with glaze contours `c` (nil once cold).
local function tile_at(cr, lad, c, m)
  if c and m <= C.blast.rings.fireball_u then
    for i, st in ipairs(lad.glaze) do
      if (c[i] or 0) > 0 and m <= c[i] then return st.tile end
    end
  end
  if cr.u_bowl then
    if m <= cr.u_bowl then return lad.floor end
    if m <= cr.u_lip then return lad.rim end
  end
  for _, b in ipairs(lad.cold) do
    if m <= b.u then return b.tile end
  end
  return lad.cold[#lad.cold].tile
end

--- The floor's bands inside out, with glaze contours `c` (nil once cold): {tile, u (outer edge, fraction of R), glaze (inside the fireball ring)}.
local function bands(cr, lad, c)
  local u0 = C.blast.rings.fireball_u
  local glazed = #lad.glaze > 0
  local cuts = {lad.u}
  local function cut(u)
    if u and u > 0 and u < lad.u then cuts[#cuts + 1] = u end
  end
  for _, b in ipairs(lad.cold) do cut(b.u) end
  if glazed then
    cut(u0)
    if c then
      for i = 1, #lad.ev do cut(c[i]) end
    end
  end
  cut(cr.u_bowl)
  cut(cr.u_lip)
  table.sort(cuts)
  local out, lo = {}, 0
  for _, hi in ipairs(cuts) do
    if hi > lo then
      local tile = tile_at(cr, lad, c, (lo + hi) * 0.5)
      local g = glazed and hi <= u0
      local last = out[#out]
      if last and last.tile == tile and last.glaze == g then
        last.u = hi
      else
        out[#out + 1] = {tile = tile, u = hi, glaze = g}
      end
      lo = hi
    end
  end
  return out
end

--- Radial factor of every class edge at angle a: one shape per shot, so bands keep their width.
local function lobe(cr, a)
  local lb = C.blast.rings.paint.lobes
  local amp = lb and lb.amplitude or 0
  if amp <= 0 then return 1 end
  local modes = lb.modes
  if not LOBE_NORM then
    LOBE_NORM = 0
    for j = 1, #modes do LOBE_NORM = LOBE_NORM + 1 / j end
    if LOBE_NORM <= 0 then LOBE_NORM = 1 end
  end
  local s, ph = 0, cr.phase
  for j = 1, #modes do s = s + cos(modes[j] * a + ph * (j + 1)) / j end
  return 1 + amp * s / LOBE_NORM
end

--- The lobe factor squared of 8-tile cell (i, j); every edge inside the cell scales by it.
local function cell_f2(cr, i, j)
  local f = lobe(cr, atan2((j + 0.5) * CELL - cr.y, (i + 0.5) * CELL - cr.x))
  return f * f
end

--- Each glaze event's contour this tick, fraction of R: the glaze inside it has not reached the event. Never grows back.
local function contours(cr, lad)
  local c = cr.c
  if cr.ct ~= game.tick then
    cr.ct = game.tick
    local u0 = C.blast.rings.fireball_u
    local b = C.heat.ground.bowl
    local s = (game.tick - cr.born - cr.hold) / 60
    for i, ev in ipairs(lad.ev) do
      local cur = c[i] or 0
      if cur > 0 then
        -- Glaze thicker than h has not reached the event; heat.glaze_at inverted.
        local h = heat.glaze_mm_at(event_kelvin(ev), s)
        local u = u0
        if h > cr.glaze then
          u = (b > 0) and u0 * (1 - (h / cr.glaze - 1) / b) or 0
          if u < 0 then u = 0 end
        end
        if u < cur then c[i] = u end
      end
    end
  end
  return c
end

--- The bands the floor shows this tick: cold for a crater without a glaze clock.
local function now_bands(cr, lad)
  if NOW_TICK ~= game.tick then NOW_TICK, NOW = game.tick, {} end
  local b = NOW[cr]
  if not b then
    if cr.born and cr.c and cr.glaze then
      b = bands(cr, lad, contours(cr, lad))
    else
      b = bands(cr, lad, nil)
    end
    NOW[cr] = b
  end
  return b
end

--- Front radius `t` ticks into a sweep (the Sedov law detonate.step draws).
local function front_at(sw, t)
  if t <= 0 then return 0 end
  local u = (t / sw.ticks) ^ C.blast.rings.wave.front_curve
  if u > 1 then u = 1 end
  return u * sw.radius
end

local function generated(surface, gen, ci, cj, key)
  if gen and gen[key] then return true end
  if surface.is_chunk_generated({ci, cj}) then
    if gen then gen[key] = true end
    return true
  end
  return false
end

--- One chunk's original liquid into maps[key]: false, the tile name filling all of it, or {[tile name] = {[local y] = column bitmask}}.
local function probe(surface, maps, ci, cj, key)
  local bx, by = ci * CHUNK, cj * CHUNK
  local area = {{bx, by}, {bx + CHUNK, by + CHUNK}}
  local fluids = fluid_names()
  local v = false
  local nl = surface.count_tiles_filtered{area = area, name = fluids}
  if nl > 0 then
    local first = (nl == AREA) and surface.get_tile(bx, by).name
    if first and surface.count_tiles_filtered{area = area, name = first} == AREA then
      v = first
    else
      v = {}
      for _, t in ipairs(surface.find_tiles_filtered{area = area, name = fluids}) do
        local p = t.position
        local ox, ry = p.x - bx, p.y - by
        if ox >= 0 and ox < CHUNK and ry >= 0 and ry < CHUNK then
          local name = t.name
          local rows = v[name]
          if not rows then rows = {}; v[name] = rows end
          rows[ry] = (rows[ry] or 0) + POW2[ox]
        end
      end
    end
  end
  maps[key] = v
  return v
end

--- The liquid tile at column ox, row ry of a probed chunk before the blast, or nil.
local function liquid_name(map, ox, ry)
  if not map then return nil end
  local tm = type(map)
  if tm == "string" then return map end
  if tm ~= "table" then return true end
  local p = POW2[ox]
  for name, rows in pairs(map) do
    local m = rows[ry]
    if m and floor(m / p) % 2 == 1 then return name end
  end
  return nil
end

--- Whether a band may write over the tile at column ox, row ry of a probed chunk: ground always, liquid only where the fireball boils it dry.
local function writable(map, ox, ry, band)
  local orig = liquid_name(map, ox, ry)
  return not orig or (band.glaze and boils(orig))
end

--- Paint every tile whose centre lies in r0 < d <= r1 with bands `cls`, inside rows y_lo..y_hi and columns x_lo..x_hi when given. Chunks not yet generated are left for crater.replay. Returns tiles written.
local function paint_band(surface, cr, maps, cls, r0, r1, y_lo, y_hi, x_lo, x_hi)
  local pc  = C.blast.rings.paint
  local K   = #cls
  local cx, cy, R = cr.x, cr.y, cr.radius
  local r0sq, r1sq = r0 > 0 and r0 * r0 or -1, r1 * r1
  local base2, edge2 = {}, {}
  for k = 1, K do
    local e = cls[k].u * R
    base2[k] = e * e
  end
  -- A tile's dither moves its d^2 by up to dk x d.
  local dk = 2 * (pc.dither_tiles or 0)
  local kd = dk * r1
  local liquid_check = pc.skip_fluid_tiles and #fluid_names() > 0
  local gen = cr.gen
  local tiles, n = {}, 0

  local ya, yb = floor(cy - r1), ceil(cy + r1)
  if y_lo and ya < y_lo then ya = y_lo end
  if y_hi and yb > y_hi then yb = y_hi end
  for y = ya, yb do
    local yc = y + 0.5 - cy
    local dy2 = yc * yc
    if dy2 < r1sq then
      local outer = sqrt(r1sq - dy2)
      local cj = floor(y / CHUNK)
      local ry = y - cj * CHUNK
      local gj = floor(y / CELL)
      local yh = y * 78.233 + cr.salt
      local s1a, s1b, s2a, s2b
      if r0sq > dy2 then
        local inner = sqrt(r0sq - dy2)
        s1a, s1b = floor(cx - outer - 0.5), ceil(cx - inner - 0.5)
        s2a, s2b = floor(cx + inner - 0.5), ceil(cx + outer - 0.5)
      else
        s1a, s1b = floor(cx - outer - 0.5), ceil(cx + outer - 0.5)
      end
      for s = 1, 2 do
        local xa, xb
        if s == 1 then
          xa, xb = s1a, s1b
        elseif s2a then
          xa, xb = s2a, s2b
        else
          break
        end
        if x_lo and xa < x_lo then xa = x_lo end
        if x_hi and xb > x_hi then xb = x_hi end
        local x = xa
        while x <= xb do
          local ci = floor(x / CHUNK)
          local xe = ci * CHUNK + CHUNK - 1
          if xe > xb then xe = xb end
          local key = chunk_key(ci, cj)
          if generated(surface, gen, ci, cj, key) then
            local map, fetched = nil, false
            local k, seg = 1, nil
            for xx = x, xe do
              local xc = xx + 0.5 - cx
              local d2 = xc * xc + dy2
              if d2 > r0sq and d2 <= r1sq then
                -- MUST probe before the first write into a chunk: the probe is the only record of its liquid.
                if liquid_check and not fetched then
                  fetched = true
                  map = maps[key]
                  if map == nil then
                    map = probe(surface, maps, ci, cj, key)
                    profile.count("wave/paint: chunk fluid probes", 1)
                  end
                end
                local sg = floor(xx / CELL)
                if sg ~= seg then
                  seg = sg
                  local f2 = cell_f2(cr, sg, gj)
                  for i = 1, K do edge2[i] = base2[i] * f2 end
                end
                while k > 1 and d2 <= edge2[k - 1] do k = k - 1 end
                while k <= K and d2 > edge2[k] do k = k + 1 end
                local c = k
                if kd > 0 and ((k <= K and edge2[k] - d2 < kd) or (k > 1 and d2 - edge2[k - 1] < kd)) then
                  local v = sin(xx * 12.9898 + yh) * 43758.5453
                  local de2 = d2 + dk * sqrt(d2) * (2 * (v - floor(v)) - 1)
                  while c > 1 and de2 <= edge2[c - 1] do c = c - 1 end
                  while c <= K and de2 > edge2[c] do c = c + 1 end
                end
                if c <= K then
                  local cl = cls[c]
                  if writable(map, xx - ci * CHUNK, ry, cl) then
                    n = n + 1
                    local t = POOL[n]
                    if t then
                      t.name = surface_tile(surface, cl.tile)
                      local pp = t.position
                      pp[1], pp[2] = xx, y
                    else
                      t = {name = surface_tile(surface, cl.tile), position = {xx, y}}
                      POOL[n] = t
                    end
                    tiles[n] = t
                  end
                end
              end
            end
          end
          x = xe + 1
        end
      end
    end
  end

  if n == 0 then return 0 end
  -- MUST keep remove_colliding_entities false: a tile write that deletes a building leaves no damage event and no corpse.
  profile.start("wave/paint: set_tiles")
  surface.set_tiles(tiles, pc.correct_tiles, pc.remove_colliding_entities,
                    pc.remove_colliding_decoratives, false)
  profile.stop("wave/paint: set_tiles")
  profile.count("wave/paint: tiles written", n)
  return n
end

--- Probe liquid ahead of the paint: chunks whose nearest point lies within `limit`, at most probe_per_tick a tick.
local function prefetch(surface, cr, limit)
  local pc = C.blast.rings.paint
  if not (pc.skip_fluid_tiles and cr.wet and cr.pq) then return end
  if limit > cr.lmax then limit = cr.lmax end
  local budget = pc.probe_per_tick or 0
  local done = 0
  while done < budget do
    if cr.pqh > cr.pqt then
      if cr.pr >= limit then break end
      local ra = cr.pr
      local rb = ra + CHUNK
      if rb > limit then rb = limit end
      front.each_ring_run(cr.x, cr.y, ra, rb, function(j, i0, i1)
        for i = i0, i1 do
          cr.pqt = cr.pqt + 1
          cr.pq[cr.pqt] = chunk_key(i, j)
        end
      end)
      cr.pr = rb
    else
      local key = cr.pq[cr.pqh]
      cr.pq[cr.pqh] = nil
      cr.pqh = cr.pqh + 1
      if cr.wet[key] == nil then
        local ci, cj = key_ci(key), key_cj(key)
        if generated(surface, cr.gen, ci, cj, key) then
          probe(surface, cr.wet, ci, cj, key)
          done = done + 1
        end
      end
    end
  end
  if done > 0 then profile.count("crater/probes ahead", done) end
end

--- Clear one area: every decorative when `near` is inside the crater, non-decals beyond it, and cliffs within cliff_r.
local function clear_area(surface, cr, area, near)
  if near < cr.lmax then
    surface.destroy_decoratives{area = area}
  else
    local nd = non_decals()
    if #nd > 0 then surface.destroy_decoratives{area = area, name = nd} end
  end
  if near >= cr.cliff_r then return 0 end
  local r2 = cr.cliff_r * cr.cliff_r
  local gone = 0
  -- Re-found each pass: cliff correction can replace a neighbour with a new entity.
  for _ = 1, 4 do
    local hit = 0
    for _, c in pairs(surface.find_entities_filtered{area = area, type = "cliff"}) do
      if c.valid then
        local p = c.position
        local dx, dy = p.x - cr.x, p.y - cr.y
        if dx * dx + dy * dy <= r2 then
          c.destroy{do_cliff_correction = true}
          hit = hit + 1
        end
      end
    end
    gone = gone + hit
    if hit == 0 then break end
  end
  return gone
end

--- Decoratives and cliffs in cells whose nearest point lies in (ra, rb].
local function clear_ring(surface, cr, ra, rb)
  local calls, cliffs = 0, 0
  front.each_ring_run(cr.x, cr.y, ra, rb, function(j, i0, i1)
    local area = {{i0 * CELL, j * CELL}, {(i1 + 1) * CELL, (j + 1) * CELL}}
    cliffs = cliffs + clear_area(surface, cr, area, ra)
    calls = calls + 1
  end, CELL)
  profile.count("crater/clear calls", calls)
  if cliffs > 0 then profile.count("crater/cliffs destroyed", cliffs) end
end

--- Whether (x, y) lies under the glaze, so whatever stood there is vaporized.
function crater.lava_at(cr, x, y)
  if not (cr and cr.lava_r and cr.lava_r > 0) then return false end
  local pc  = C.blast.rings.paint
  local R   = cr.radius
  local dt  = pc.dither_tiles or 0
  local amp = (pc.lobes and pc.lobes.amplitude) or 0
  local u0  = C.blast.rings.fireball_u
  local tx, ty = floor(x), floor(y)
  local xc, yc = tx + 0.5 - cr.x, ty + 0.5 - cr.y
  local d2 = xc * xc + yc * yc
  local lim = u0 * R * (1 + amp) + dt
  if d2 > lim * lim then return false end
  local e = u0 * R
  local e2 = e * e * cell_f2(cr, floor(tx / CELL), floor(ty / CELL))
  local v = sin(tx * 12.9898 + (ty * 78.233 + cr.salt)) * 43758.5453
  return d2 + 2 * dt * sqrt(d2) * (2 * (v - floor(v)) - 1) <= e2
end

--- Vaporize what stands on the glaze in `area`: creatures vanish, nests and worms die, bodies and loot go. Returns things removed.
local function melt(surface, cr, area, force)
  local gone, died = 0, false
  for _, e in ipairs(surface.find_entities_filtered{area = area, type = C.blast.rings.paint.melt_types}) do
    if e.valid then
      local p = e.position
      if crater.lava_at(cr, p.x, p.y) then
        local t = e.type
        if t == "corpse" or t == "item-entity" then
          e.destroy()
        elseif VANISH[t] then
          slay.vanish(e, force)
        else
          e.die(force)
          died = true
        end
        gone = gone + 1
      end
    end
  end
  if died then
    for _, e in ipairs(surface.find_entities_filtered{area = area, type = "corpse"}) do
      if e.valid then
        local p = e.position
        if crater.lava_at(cr, p.x, p.y) then e.destroy() end
      end
    end
  end
  return gone
end

--- Rewrite the painted tiles of slice `ph` whose glaze passed an event as its contour fell from hi to lo (fractions of R), to the bands `cur`. Returns tiles written.
local function cool_band(surface, cr, cur, lo, hi, ph)
  local pc  = C.blast.rings.paint
  local S   = pc.cool.slices
  local cx, cy, R = cr.x, cr.y, cr.radius
  local amp = (pc.lobes and pc.lobes.amplitude) or 0
  local dt  = pc.dither_tiles or 0
  local dk  = 2 * dt
  local K = #cur
  local cb2, ce2 = {}, {}
  for k = 1, K do local e = cur[k].u * R; cb2[k] = e * e end
  local l0, h0 = lo * R, hi * R
  local lo2, hi2 = l0 * l0, h0 * h0
  local wet, gen = cr.wet, cr.gen
  local tiles, n = {}, 0

  front.each_ring_run(cx, cy, l0 * (1 - amp) - dt - CELL_DIAG, h0 * (1 + amp) + dt, function(j, i0, i1)
    if j % S ~= ph then return end
    local y0 = j * CELL
    local cj = floor(y0 / CHUNK)
    local pr = (y0 < cr.ys) and cr.up or cr.dn
    local dyn, dyf = 0, math.max(math.abs(y0 - cy), math.abs(y0 + CELL - cy))
    if cy < y0 then dyn = y0 - cy elseif cy > y0 + CELL then dyn = cy - (y0 + CELL) end
    for gi = i0, i1 do
      local x0 = gi * CELL
      local f2 = cell_f2(cr, gi, j)
      local f = sqrt(f2)
      local a0, a1 = l0 * f - dt, h0 * f + dt
      if a1 > pr then a1 = pr end
      local a0sq = (a0 > 0) and a0 * a0 or -1
      local a1sq = a1 * a1
      local dxn, dxf = 0, math.max(math.abs(x0 - cx), math.abs(x0 + CELL - cx))
      if cx < x0 then dxn = x0 - cx elseif cx > x0 + CELL then dxn = cx - (x0 + CELL) end
      if a1 > a0 and a1 > 0 and dxn * dxn + dyn * dyn <= a1sq and dxf * dxf + dyf * dyf > a0sq then
        local ci = floor(x0 / CHUNK)
        local key = chunk_key(ci, cj)
        if generated(surface, gen, ci, cj, key) then
          local map = wet and wet[key]
          for k = 1, K do ce2[k] = cb2[k] * f2 end
          local blo, bhi = lo2 * f2, hi2 * f2
          for y = y0, y0 + CELL - 1 do
            local yc = y + 0.5 - cy
            local dy2 = yc * yc
            if dy2 < a1sq then
              local wo = sqrt(a1sq - dy2)
              local wi = (a0sq > dy2) and sqrt(a0sq - dy2) or -1
              local yh = y * 78.233 + cr.salt
              local ry = y - cj * CHUNK
              for xx = x0, x0 + CELL - 1 do
                local xc = xx + 0.5 - cx
                local ax = (xc < 0) and -xc or xc
                if ax <= wo and ax > wi then
                  local d2 = xc * xc + dy2
                  local v = sin(xx * 12.9898 + yh) * 43758.5453
                  local de2 = d2 + dk * sqrt(d2) * (2 * (v - floor(v)) - 1)
                  if (lo <= 0 or de2 > blo) and de2 <= bhi then
                    local k = 1
                    while k <= K and de2 > ce2[k] do k = k + 1 end
                    if k <= K and writable(map, xx - ci * CHUNK, ry, cur[k])
                       and N.tile_sources[surface.get_tile(xx, y).name] then
                      local name = surface_tile(surface, cur[k].tile)
                      n = n + 1
                      local t = POOL[n]
                      if t then
                        t.name = name
                        local pp = t.position
                        pp[1], pp[2] = xx, y
                      else
                        t = {name = name, position = {xx, y}}
                        POOL[n] = t
                      end
                      tiles[n] = t
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end, CELL)

  if n == 0 then return 0 end
  profile.start("crater/cool: set_tiles")
  surface.set_tiles(tiles, pc.correct_tiles, pc.remove_colliding_entities,
                    pc.remove_colliding_decoratives, false)
  profile.stop("crater/cool: set_tiles")
  profile.count("crater/cool: tiles written", n)
  return n
end

--- One tick of a crater's cooling: slice `ph` of every glaze event whose contour has fallen, in order, within `budget` tiles. Returns tiles written.
local function cool(surface, cr, ph, budget)
  local cc  = C.blast.rings.paint.cool
  local lad = ladder(cr.key)
  local c   = contours(cr, lad)
  local R   = cr.radius
  -- Tiles per unit of u^2 in one slice.
  local slice = math.pi * R * R / cc.slices
  local cur, written = nil, 0
  for i = 1, #lad.ev do
    local cu = cr.cu[i]
    if #cu ~= cc.slices then
      local top = 0
      for _, u in ipairs(cu) do if u > top then top = u end end
      cu = {}
      for p = 1, cc.slices do cu[p] = top end
      cr.cu[i] = cu
    end
    local hi, lo = cu[ph + 1], c[i]
    if hi > lo and ((hi - lo) * R >= cc.min_tiles or lo <= 0) then
      local left = budget - written
      if left <= 0 then break end
      local m2 = hi * hi - left / slice
      if m2 > lo * lo then lo = sqrt(m2) end
      cur = cur or now_bands(cr, lad)
      written = written + cool_band(surface, cr, cur, lo, hi, ph)
      cu[ph + 1] = lo
    end
  end
  return written
end

--- Whether a crater has painted everything and every glaze event has reached ground zero in every slice.
local function cooled(cr, lad)
  if cr.up < cr.lmax or cr.dn < cr.lmax then return false end
  for i = 1, #lad.ev do
    for _, u in ipairs(cr.cu[i]) do
      if u > 0 then return false end
    end
  end
  return true
end

--- A sweep's crater record (storage): ladder, lobe phase, per-half paint radii, clear and melt radii, the dug crater, liquid maps, and the glaze's clock. `static` paints it cold.
function crater.begin(sw, static)
  local pc  = C.blast.rings.paint
  local sc  = C.blast.scar
  local cl  = C.blast.rings.clear
  local key = ladder_key()
  local lad = ladder(key)
  local R   = sw.radius
  local amp = (pc.lobes and pc.lobes.amplitude) or 0
  local dt  = pc.dither_tiles or 0
  local u0  = C.blast.rings.fireball_u
  local kt  = C.yield.kg_for_fraction(sw.yield or sw.variant or 1) / 1000000
  local lmax = lad.u * R * (1 + amp) + dt + 1
  local clim = math.min(R * sc.decorative_fraction, sc.max_decorative_radius)
  local cr = {
    key = key,
    surface = sw.surface,
    force = sw.force,
    x = sw.x, y = sw.y, radius = R,
    phase = math.random() * TAU,
    salt  = math.random() * 1000,
    -- Chunk row splitting the two halves the paint alternates between.
    ys = floor(sw.y / CHUNK + 0.5) * CHUNK,
    up = 0, dn = 0,
    lmax = lmax,
    clear_r = (cl and cl.enabled) and 0 or clim,
    clim = clim,
    cliff_r = math.min(R * sc.cliff_fraction, sc.max_cliff_radius),
    -- Outermost reach of the glaze, and how far the melt has swept it.
    lava_r = (#lad.glaze > 0) and (u0 * R * (1 + amp) + dt + 1) or 0,
    vap_r = 0,
    wet = {}, gen = {},
    pr = 0, pq = {}, pqh = 1, pqt = 0,
  }
  if lad.floor then
    local cc = pc.crater
    -- The dug crater's apparent radius, fraction of R.
    local ra = cc.radius_m * kt ^ cc.exponent / (C.yield.tile_metres * R)
    if ra * R >= 1 then cr.u_bowl, cr.u_lip = ra, ra * cc.lip end
  end
  if not pc.enabled then cr.up, cr.dn = lmax, lmax end
  local co = pc.cool
  if pc.enabled and co and co.enabled and #lad.ev > 0 and not static then
    cr.born  = sw.started
    cr.hold  = heat.glaze_start(sw.ticks)
    cr.glaze = heat.glaze_mm(kt)
    -- Each event's contour now, and how far each slice has been rewritten; fractions of R.
    cr.c, cr.cu = {}, {}
    for i = 1, #lad.ev do
      cr.c[i] = u0
      local s = {}
      for p = 1, co.slices do s[p] = u0 end
      cr.cu[i] = s
    end
    cr.cooling = true
    local list = storage.craters
    list[#list + 1] = cr
  end
  return cr
end

--- During the collapse: probe liquid for ground the front will reach within probe_ahead_ticks.
function crater.ahead(sw, elapsed)
  local cr = sw.crater
  if not (cr and cr.wet) then return end
  local surface = game.get_surface(sw.surface)
  if not (surface and surface.valid) then return end
  profile.start("crater/prefetch")
  prefetch(surface, cr, front_at(sw, elapsed + (C.blast.rings.paint.probe_ahead_ticks or 0)))
  profile.stop("crater/prefetch")
end

--- Whether the paint has reached the crater's edge in both halves.
function crater.painted(sw)
  local cr = sw.crater
  if not cr then return true end
  return (cr.up >= cr.lmax and cr.dn >= cr.lmax)
      or sw.painted >= C.blast.rings.paint.max_total_tiles
end

--- Whether paint, clearing and melt are all finished.
function crater.done(sw)
  local cr = sw.crater
  if not cr then return true end
  return crater.painted(sw) and cr.clear_r >= cr.clim and (cr.vap_r or 0) >= (cr.lava_r or 0)
end

--- One tick of a sweep's ground: probe ahead, clear behind the front, paint one half, and vaporize what stands on the glaze where the paint and the payout have both passed.
function crater.step(sw, surface, r, elapsed)
  local cr = sw.crater
  if not cr then
    cr = crater.begin(sw, true)
    cr.up, cr.dn = sw.paint_r or 0, sw.paint_r or 0
    sw.crater = cr
  end
  cr.wet = cr.wet or {}
  local pc = C.blast.rings.paint

  if cr.wet and cr.pq then
    local lim = front_at(sw, elapsed + (pc.probe_ahead_ticks or 0))
    local pmin = math.min(cr.up, cr.dn)
    if lim < pmin then lim = pmin end
    profile.start("crater/prefetch")
    prefetch(surface, cr, lim)
    profile.stop("crater/prefetch")
  end

  local cl = C.blast.rings.clear
  if cr.clear_r < cr.clim then
    local target = (elapsed >= sw.ticks) and cr.clim or (r - cl.lag_tiles)
    if target > cr.clim then target = cr.clim end
    if target > cr.clear_r then
      profile.start("crater/clear")
      clear_ring(surface, cr, cr.clear_r, target)
      profile.stop("crater/clear")
      cr.clear_r = target
    end
  end

  profile.start("wave/paint")
  if pc.enabled and not crater.painted(sw) then
    local lim = cr.lmax
    local target = lim
    if elapsed < sw.ticks then
      local lead = C.blast.rings.wave.stamp_tiles(sw.variant or 1) * pc.lead_fraction
      if lead > pc.lead_max then lead = pc.lead_max end
      target = r + lead
      if target > lim then target = lim end
    end
    local cls = now_bands(cr, ladder(cr.key))
    local iv  = pc.interval
    local off = floor(iv / 2)
    for h = 1, 2 do
      if (elapsed + (h - 1) * off) % iv == 0 then
        local r0 = (h == 1) and cr.up or cr.dn
        if target > r0 then
          -- Half an annulus holding tiles_per_tick tiles.
          local r1 = sqrt(r0 * r0 + 2 * pc.tiles_per_tick / math.pi)
          if r1 > target then r1 = target end
          local n
          if h == 1 then
            n = paint_band(surface, cr, cr.wet, cls, r0, r1, nil, cr.ys - 1)
            cr.up = r1
          else
            n = paint_band(surface, cr, cr.wet, cls, r0, r1, cr.ys, nil)
            cr.dn = r1
          end
          sw.painted = sw.painted + n
        end
      end
    end
  end
  profile.stop("wave/paint")

  if (cr.vap_r or 0) < (cr.lava_r or 0) then
    local target = math.min(front.paid_radius(sw.front) or 0, cr.up, cr.dn) - DIAG
    if elapsed >= sw.ticks and front.done(sw.front) and crater.painted(sw) then target = cr.lava_r end
    if target > cr.lava_r then target = cr.lava_r end
    if target > cr.vap_r then
      profile.start("crater/melt")
      local gone = 0
      front.each_ring_run(cr.x, cr.y, cr.vap_r, target, function(j, i0, i1)
        gone = gone + melt(surface, cr, {{i0 * CHUNK, j * CHUNK}, {(i1 + 1) * CHUNK, (j + 1) * CHUNK}}, sw.force)
      end)
      if gone > 0 then
        slay.flush()
        profile.count("crater/melted", gone)
      end
      profile.stop("crater/melt")
      cr.vap_r = target
    end
  end

  sw.paint_r = math.min(cr.up, cr.dn)
  if sw.groundfire then sw.groundfire.paint_r = sw.paint_r end
end

--- The sweep is over: keep what crater.replay and cooling read, including unfinished glaze.
function crater.finish(sw)
  local cr = sw.crater
  if not cr then return end
  cr.up, cr.dn = cr.lmax, cr.lmax
  cr.clear_r = cr.clim
  cr.vap_r = cr.lava_r
  cr.pq, cr.pqh, cr.pqt, cr.pr = nil, nil, nil, nil
  if not cr.cooling then cr.wet, cr.gen = nil, nil end
end

--- A chunk generated inside a recorded blast: tiles the paint has passed as they stand now, decoratives and cliffs the front has passed, and what stands on the glaze.
function crater.replay(surface, area, s)
  local cr = s.crater
  if not cr then return end
  local lt = area.left_top
  local x0, y0 = floor(lt.x), floor(lt.y)
  local near = near_chunk(cr.x, cr.y, floor(x0 / CHUNK), floor(y0 / CHUNK))
  local rh = (y0 < cr.ys) and cr.up or cr.dn
  local box = {{x0, y0}, {x0 + CHUNK, y0 + CHUNK}}
  if near < rh and C.blast.rings.paint.enabled then
    local maps = (cr.cooling and cr.wet) or {}
    paint_band(surface, cr, maps, now_bands(cr, ladder(cr.key)), 0, rh,
               y0, y0 + CHUNK - 1, x0, x0 + CHUNK - 1)
  end
  if near < cr.clear_r then
    clear_area(surface, cr, box, near)
  end
  if near < (cr.vap_r or 0) and melt(surface, cr, box, s.force) > 0 then
    slay.flush()
  end
end

--- Re-chart the glaze each time an event's rewrite has fallen 1/chart_steps of the fireball ring, and when it reaches ground zero.
local function chart_cooling(surface, cr, lad)
  local u0 = C.blast.rings.fireball_u
  local step = u0 / C.blast.rings.paint.cool.chart_steps
  local mu = cr.mu
  if not mu then mu = {}; cr.mu = mu end
  local lo, hi
  for i = 1, #lad.ev do
    local top = 0
    for _, u in ipairs(cr.cu[i]) do if u > top then top = u end end
    local last = mu[i] or u0
    if last - top >= step or (top <= 0 and last > 0) then
      mu[i] = top
      if not lo or top < lo then lo = top end
      if not hi or last > hi then hi = last end
    end
  end
  if not lo then return end
  local force = game.forces[cr.force or C.blast.rings.default_force]
  if not force then return end
  local pc  = C.blast.rings.paint
  local amp = (pc.lobes and pc.lobes.amplitude) or 0
  local dt  = pc.dither_tiles or 0
  local R   = cr.radius
  front.chart_runs(force, surface, cr.x, cr.y,
                   lo * R * (1 - amp) - dt - DIAG, hi * R * (1 + amp) + dt, false)
end

--- Every cooling crater, one slice a tick, under one shared tile budget.
local function cool_step()
  local list = storage.craters
  if not list or #list == 0 then return end
  local cc = C.blast.rings.paint.cool
  if not (cc and cc.enabled) then return end
  profile.start("crater/cool")
  local ph = game.tick % cc.slices
  local budget = cc.tiles_per_tick
  for i = #list, 1, -1 do
    local cr = list[i]
    local surface = game.get_surface(cr.surface)
    local lad = ladder(cr.key)
    if not (cr.cooling and cr.glaze and surface and surface.valid and #cr.cu == #lad.ev)
       or cooled(cr, lad) then
      cr.cooling = nil
      cr.wet, cr.gen = nil, nil
      table.remove(list, i)
    elseif game.tick >= cr.born then
      budget = budget - cool(surface, cr, ph, budget)
      chart_cooling(surface, cr, lad)
    end
  end
  profile.stop("crater/cool")
end

events.on_nth_tick(1, cool_step)

return crater
