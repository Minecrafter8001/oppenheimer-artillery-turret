-- scripts/detonate: shock front mechanics (Sedov-Taylor), annulus-based damage;
-- the ground it leaves is scripts/crater.lua.

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
-- Requires config only, so no cycle -- see its header for why the
-- detonation's thunder is not just an ExplosionPrototype's `sound` field.
local audio  = require("scripts.audio")
-- The front is drawn on the map too -- the puffs are "not-on-map"
-- explosions and never can be. See scripts/mapdraw.lua.
local mapdraw = require("scripts.mapdraw")
-- What the front passes, found and paid. Shared with the collapse and
-- the fire wave.
local front  = require("scripts.front")
-- Trees and rocks: charred or vaporized, never damage()d. See its header.
local flora  = require("scripts.flora")
-- Lethal hits on creatures off screen skip the engine's death. See its header.
local slay   = require("scripts.slay")
-- Black-body colour and emission for the shock wall and the puffs stamped on
-- it -- one law, shared with the lance and the collapse (C.heat). Named
-- `heat` here; scripts/implode.lua calls the same module `heatlib` only
-- because `heat` is already a parameter name there.
local heat   = require("lib.heat")
local profile = require("scripts.profile")
local view   = require("scripts.view")
local groundfire = require("scripts.groundfire")
local crater = require("scripts.crater")

local detonate = {}

local CHUNK = 32
local DIAG  = 46

local TAU   = 2 * math.pi

local SKIP = {}
for _, t in ipairs(C.blast.rings.skip_types) do SKIP[t] = true end
local MOVERS = C.blast.movers.enabled and C.blast.movers or nil
local VAPOR = {unit = true, ["spider-unit"] = true, ["segmented-unit"] = true}
local EXCLUDE
local function exclude_types()
  if EXCLUDE then return EXCLUDE end
  local present = {}
  for _, p in pairs(prototypes.entity) do present[p.type] = true end
  local out, seen = {}, {}
  local function add(t)
    if present[t] and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  for _, t in ipairs(C.blast.rings.skip_types) do add(t) end
  if flora.enabled() then
    for _, t in ipairs(flora.types()) do add(t) end
  end
  EXCLUDE = out
  return EXCLUDE
end

-- =============================================================================
-- Starting a sweep
-- =============================================================================

--- Put a detonation's wave on the ground.
--
-- @param surface   LuaSurface
-- @param pos       table    ground zero
-- @param trigger_j number   trigger energy in JOULES -- what the grid actually
--                           paid. The yield and the radius come from C.yield.
-- @param force     ForceID|nil  who gets the kill credit, and whose map is charted
-- @param variant   number|nil   the built yield step (names the puff prototype,
--                               and sets the release clock -- see below)
-- @param kelvin    number|nil   the ball's temperature at the moment it let go
--                               (C.heat), carried from the lance through
--                               impact.detonate. THE WALL'S COLOUR STARTS
--                               HERE: the gas the wave is made of is the gas
--                               that was in the ball, so the sphere, the
--                               collapse and the shock front are one
--                               temperature thread rather than three
--                               independently-tuned palettes. nil falls back
--                               to C.blast.rings.wave.wall.kelvin_fallback.
-- @return number   the blast radius used, in tiles
-- @param delivered number|nil  the converged group's total yield fraction. The
--                               radius is the dial's; this is what is inside it.
function detonate.begin(surface, pos, trigger_j, force, variant, kelvin, delivered)
  if not (surface and surface.valid and pos) then return 0 end
  local rings = C.blast.rings
  if not rings.enabled then return 0 end

  local radius = C.yield.radius(trigger_j or 0)
  if radius <= 0 then return 0 end

  local ticks = rings.sweep_ticks_for_radius(radius)

  -- THE SWEEP STARTS WHEN THE EXPLOSION DOES, NOT WHEN THE CARRIER IS CREATED,
  -- ON THE VARIANT'S CLOCK -- not the shot's raw (continuous) power. Only the
  -- ball's radius is continuous; implode.begin's own ticks/total and
  -- prototypes/vfx/waves.lua's release-stage offsets are all baked against the
  -- VARIANT, because prototypes can't know anything else. The variant is the
  -- one clock the wave, the damage and the tile paint can all read without
  -- drifting from the explosion or from each other.
  local delay = C.blast.stages.flash or 0
  if C.blast.style == "implosion" then
    local clock = variant
    if not clock then
      clock = 1
      if C.charge.cost_per_shot > 0 and (trigger_j or 0) > 0 then
        clock = trigger_j / C.charge.cost_per_shot
      end
    end
    delay = delay + C.blast.implosion.total_ticks_for(clock)
  end

  -- Force by NAME: plain data in storage, and valid as a ForceID for die() and
  -- damage() and as a key into game.forces for the chart.
  local fname = rings.default_force
  if type(force) == "string" then
    fname = force
  elseif force and force.valid then
    fname = force.name
  end

  storage.sweeps = storage.sweeps or {}
  storage.sweeps[#storage.sweeps + 1] = {
    surface = surface.index,
    x = pos.x, y = pos.y,
    radius  = radius,
    -- In the FUTURE while the collapse plays; step() skips it until then.
    started = game.tick + delay,
    ticks   = ticks,
    force   = fname,
    variant = variant,
    -- Yield delivered into `radius`, which the dial set. Their ratio IS the
    -- overpressure the battery bought.
    yield   = delivered or variant or 1,
    kelvin  = kelvin,
    front   = front.new{
      x = pos.x, y = pos.y, r_max = radius, dir = 1, bucket = rings.bucket_tiles,
      movers = C.blast.movers.enabled,
    },
    painted   = 0,
    paint_r   = 0,
    cleared   = false,
    -- Whether the release fireball has been put down. Latched on the sweep's
    -- first tick -- see step(). Written here rather than left lazy because
    -- "has this already happened" is exactly the kind of field that must not
    -- read nil on a record that has in fact already done it.
    released  = false,
    -- Where the last layer of fire was stamped. nil until the first.
    stamp_r   = nil,
    layer_n   = 0,
    -- Same bookkeeping, kept separate for the ground-fire trail (draw_firewave)
    -- so its own much-tighter stamp cadence never shares a cursor with the
    -- plasma ring above.
    fw_stamp_r = nil,
    fw_layer_n = 0,
    -- The map: charted out to chart_r, refreshed behind the paint to refresh_r.
    chart_r   = 0,
    refresh_r = 0,
    -- Telemetry, published to storage.last_sweep when the sweep ends.
    damaged = 0, destroyed = 0, charted = 0, generated = 0,
  }
  local sweep = storage.sweeps[#storage.sweeps]
  sweep.crater = crater.begin(sweep)

  -- The crater's fire rides the paint: crater.step writes paint_r into it.
  if rings.paint.enabled then
    sweep.groundfire = groundfire.begin(surface, pos, radius, sweep.started, ticks, variant,
                                        C.yield.kg_for_fraction(sweep.yield) / 1000000)
  end

  -- THE SCAR. Anything past generate_ahead_radius is ground the sweep will not
  -- build, so the blast has to outlive the sweep: scripts/scar.lua replays this
  -- record onto chunks as they are generated, for as long as the save exists.
  -- Inside that radius the front builds and pays as it goes, so a shot that
  -- never leaves the theatre leaves no record at all.
  local sc = C.blast.scars
  if sc and sc.enabled and radius > (rings.generate_ahead_radius or 0) then
    storage.scars = storage.scars or {}
    local scars = storage.scars
    local scar_rec = {
      surface = surface.index,
      x = pos.x, y = pos.y,
      radius = radius,
      -- The annulus this record owns. Everything inside was built and paid by
      -- the front as it passed; replaying it would damage that ground twice.
      inner = rings.generate_ahead_radius or 0,
      variant = variant,
      force = fname,
      tick = game.tick,
      -- When the front stops. Past it the front owns nothing, so scar.lua pays
      -- every chunk. BEFORE it, ownership is by radius, not by time -- see acq.
      ready_tick = game.tick + delay + ticks + 1,
      -- How far out the front has ACQUIRED, published by step() every tick. A
      -- chunk whose nearest point is beyond this has not been searched yet, so
      -- the front will find whatever generation puts in it. A chunk at or inside
      -- it was searched -- as EMPTY, if it was ungenerated then -- and the front
      -- never returns, so scar.lua must pay it. 0 until the sweep starts, which
      -- is right: during the collapse the front owns everything.
      acq = 0,
    }
    scars[#scars + 1] = scar_rec
    -- The sweep holds the record it publishes acq into. Shared references
    -- survive a save (Auxiliary Docs, Storage: circular references are handled).
    sweep.scar = scar_rec
    -- Shared too: crater.replay reads the paint and clear radii as they grow.
    scar_rec.crater = sweep.crater
    -- Oldest first out. A record is a handful of numbers, so this is a guard
    -- against an unbounded table rather than a budget anyone should meet.
    while #scars > (sc.max_records or 256) do table.remove(scars, 1) end
  end

  return radius
end

-- =============================================================================
-- The payout
-- =============================================================================

--- One thing the front has just reached. Inside the fireball ring or on melting
--- ground (crater.lava_at), creatures vanish and everything else die()s; outside,
--- rings.dose_at's hit points go through slay.hit, resistances applied.
-- MUST die(), not destroy(), for non-creatures: on_entity_died keeps other mods' bookkeeping right.
-- Exported: scripts/scar.lua pays out old footprints through it.
function detonate.hit(sw, e, d)
  if flora.enabled() and flora.owns(e) then
    flora.treat(e, d, sw.radius, sw.force)
    return
  end
  local rings = C.blast.rings
  local u = d / sw.radius
  local cr = sw.crater
  local gone = u <= rings.fireball_u
  if not gone and cr and d <= (cr.lava_r or 0) then
    local p = e.position
    gone = crater.lava_at(cr, p.x, p.y)
  end
  if gone and VAPOR[e.type] then
    slay.vanish(e, sw.force)
    sw.destroyed = sw.destroyed + 1
    return
  end
  if gone then
    e.die(sw.force)
    sw.destroyed = sw.destroyed + 1
    return
  end
  -- dose_at RETURNS HIT POINTS now (blast + thermal, each at its own published
  -- threshold) -- no payload multiply. sw.variant is the yield fraction, and it
  -- moves the thermal reach: a 25% shot's burn radius is 0.578 of its own
  -- blast, a full one's is past its rim.
  local amount = rings.dose_at(u, sw.yield or sw.variant or 1, sw.radius)
  if amount > 0 then
    slay.hit(e, amount, sw.force, rings.damage_type)
    sw.damaged = sw.damaged + 1
  end
end

-- =============================================================================
-- The wall
-- =============================================================================

-- The heat ladder's normalisation for the Rayleigh-Taylor mode sum: the modes
-- are weighted 1/j, so this keeps peak modulation at rt_amplitude regardless of
-- how many modes the config names. Built once from config -- pure, stateless,
-- identical on every client, same as SKIP above.
local RT_NORM
local function rt_norm()
  if RT_NORM then return RT_NORM end
  local s = 0
  for j = 1, #C.blast.rings.wave.wall.rt_modes do s = s + 1 / j end
  RT_NORM = (s > 0) and s or 1
  return RT_NORM
end

--- PREMULTIPLIED, which is what every rendering.draw_* wants: the 2.0.77
--- Color concept says "the game usually expects colors to be in pre-multiplied
--- form (color channels are pre-multiplied by alpha)". 0.48.0 passed a straight
--- pale blue at alpha 0.03 and the engine drew a solid white panel.
local function pm(c, a)
  if a > 1 then a = 1 elseif a < 0 then a = 0 end
  return {r = c.r * a, g = c.g * a, b = c.b * a, a = a}
end

--- The Rayleigh-Taylor instability amplitude at front fraction u. Grows as the
--- front decelerates; zero when rt is off, which makes every caller a plain circle.
-- MUST be read by both the wall and its stamps, or the stamps sit on the true
-- circle while the wall swings off it.
local function rt_amp(u)
  local wl = C.blast.rings.wave.wall
  if not wl.rt_enabled then return 0 end
  return wl.rt_amplitude * (u or 0) ^ wl.rt_growth
end

local function rt_factor(sw, a, amp)
  if not (amp and amp > 0) then return 1 end
  local modes = C.blast.rings.wave.wall.rt_modes
  local phase = sw.wall_phase or 0
  local s = 0
  for j = 1, #modes do
    s = s + math.cos(modes[j] * a + phase * (j + 1)) / j
  end
  return 1 + amp * s / rt_norm()
end

-- Per-shot instability phase, rolled from RNG on first use.
local function wall_phase(sw)
  sw.wall_phase = sw.wall_phase or (math.random() * TAU)
  return sw.wall_phase
end

--- One ring of the wall, as a closed triangle strip.
--
-- rendering.draw_polygon takes a triangle STRIP, so alternating OUTER and
-- INNER vertices around the circle tiles the annulus with quads: vertices
-- (O0,I0,O1) make the first triangle, (I0,O1,I1) the second, and so on. The
-- loop runs one step past the last segment and wraps the angle back to zero,
-- so the final pair is exactly the first pair and the ring closes with no seam.
--
-- WHY A POLYGON AND NOT A CIRCLE STROKE. draw_circle's `width` is in screen
-- PIXELS, so a stroke tuned to look like a wall at 200 tiles is a hairline on a
-- 2000 tile ring at the zoom you would have to watch one from -- the thickness
-- would not be the shock's thickness, it would be the camera's. These vertices
-- are world positions, so the shell is R/18 tiles thick at every radius and
-- every zoom, which is the only way the Sedov geometry can actually be on
-- screen rather than merely in the config.
--
-- `amp` modulates every vertex radius by the same angular function, so the
-- inner and outer edges stay parallel and the ring reads as a lumpy shell
-- rather than a ring of random spikes. Segment count is derived from rt_modes.
local function annulus(sw, surface, r_in, r_out, color, amp, on_ground)
  -- CULLED BEFORE THE VERTEX LOOP, NOT JUST BEFORE THE DRAW. At the current
  -- 412 vertices per ring x 9 rings per tick, building the table IS the cost --
  -- and a ring is the shape that most deserves the test: a player standing at
  -- ground zero watching a 1500-tile front expand can see no part of it, while
  -- a centre-distance test would call it visible. scripts/view.lua does the
  -- annulus-vs-view-band overlap properly.
  if not view.ring(surface.index, sw.x, sw.y, r_in, r_out) then return end

  local wl = C.blast.rings.wave.wall
  local n = wl.segments_for()
  local iso = C.blast.iso_y
  local v, k = {}, 0

  for i = 0, n do
    local a = (i % n) * TAU / n
    local f = rt_factor(sw, a, amp)
    local ca, sa = math.cos(a), math.sin(a) * iso
    k = k + 1; v[k] = {sw.x + ca * r_out * f, sw.y + sa * r_out * f}
    k = k + 1; v[k] = {sw.x + ca * r_in  * f, sw.y + sa * r_in  * f}
  end

  rendering.draw_polygon{
    color = color, vertices = v, surface = surface,
    time_to_live = 2, draw_on_ground = on_ground or nil,
  }
end

--- THE SHOCK WALL. See C.blast.rings.wave.wall for the physics; this is the
--- drawing of it.
--
-- Four things, outside in, and every colour on this tick comes from ONE
-- temperature law read at each ring's own radius:
--   DUST      ahead of the shell, on the ground, opaque exactly where the gas
--             has cooled too far to glow (alpha runs inverse to the emission)
--   AFTERGLOW nested rings stepping inward, fainter each time -- and HOTTER,
--             because a Sedov interior is hot and underdense while the density
--             peaks at the shock
--   SHELL     the swept mass, R/18 thick
--   RIM       the outer sliver of it, brighter and whitened: the shock surface
--
-- Redrawn every tick with a two-tick life rather than persisted and mutated,
-- the same discipline scripts/implode.lua's ball uses -- nothing to invalidate
-- on abort, save/load or surface removal. LuaRenderObject.vertices IS writable
-- (2.0.77), so a persistent mesh is possible; it is not worth the lifetime
-- bookkeeping for an object that lives a few hundred ticks.
local function draw_wall(sw, surface, u, r)
  local w  = C.blast.rings.wave
  local wl = w.wall
  if not (wl and wl.enabled) then return end
  if r < 2 then return end

  -- THE SEDOV SHELL: all the swept mass in R/18. Clamped, and never more than
  -- most of the current radius -- early on the front has not travelled far
  -- enough to have a full-thickness shell behind it.
  local th = sw.radius * wl.thickness_fraction
  if th < wl.thickness_min then th = wl.thickness_min end
  if th > wl.thickness_max then th = wl.thickness_max end
  if th > r * 0.9 then th = r * 0.9 end

  -- Rayleigh-Taylor amplitude grows as the front decelerates.
  local amp = rt_amp(u)

  local k_front = w.wall_kelvin(sw.kelvin, u)
  local glow    = heat.glow(k_front)
  local front_c = heat.glow_rgb(k_front)

  -- THE DUST, NESTED AND TAPERED. One annulus of one flat alpha was up to 238
  -- tiles of uniform brown ending at a crisp polygon edge, with nothing
  -- stamped in it (the puff band only ever reaches `r`) -- a vector overlay by
  -- construction. These step outward across the same depth, each fainter, so
  -- the leading edge fades into the ground rather than stopping at a line.
  if wl.dust_enabled then
    local da = wl.dust_alpha_min + (wl.dust_alpha_max - wl.dust_alpha_min) * (1 - glow)
    local reach = th * wl.dust_fraction
    local n = math.max(1, math.floor(wl.dust_layers or 1))
    for i = 1, n do
      local d0 = r + reach * ((i - 1) / n)
      local d1 = r + reach * (i / n)
      -- Linear from full alpha at the innermost layer to dust_taper at the
      -- outermost. One layer collapses to the old behaviour exactly.
      local fade = (n > 1) and (1 - (1 - wl.dust_taper) * ((i - 1) / (n - 1))) or 1
      annulus(sw, surface, d0, d1, pm(wl.dust_color, da * fade), amp, true)
    end
  end

  local layers = wl.glow_layers or 0
  if layers > 0 then
    local depth = sw.radius * wl.glow_depth_fraction
    -- Outermost (brightest, just behind the shell) LAST, so it composites over
    -- the fainter ones rather than under them.
    for i = layers, 1, -1 do
      local r1 = r - th - depth * ((i - 1) / layers)
      local r0 = r - th - depth * (i / layers)
      if r0 > 1 then
        local kk = w.wall_kelvin(sw.kelvin, r0 / sw.radius) * wl.interior_gain
        local a  = wl.glow_alpha * (1 - (i - 1) / layers)
        annulus(sw, surface, r0, r1, pm(heat.glow_rgb(kk), a), amp, wl.glow_on_ground)
      end
    end
  end

  annulus(sw, surface, r - th, r, pm(front_c, wl.shell_alpha), amp, wl.shell_on_ground)

  -- THE RIM, mixed toward white AT THE CURRENT BRIGHTNESS rather than toward
  -- pure white: a rim that whitens as it cools would say the coldest part of
  -- the wave is the hottest-looking part of it.
  local rim = th * wl.rim_fraction
  if rim > 0.25 then
    local wht = wl.rim_whiten
    annulus(sw, surface, r - rim, r, pm({
      r = front_c.r + (glow - front_c.r) * wht,
      g = front_c.g + (glow - front_c.g) * wht,
      b = front_c.b + (glow - front_c.b) * wht,
    }, wl.rim_alpha), amp, wl.shell_on_ground)
  end

  -- THE LIGHT IT CASTS. A polygon is flat colour and spills nothing onto the
  -- ground; without this the wall is a shape drawn over the scene rather than
  -- something burning in it. Off past light_max_radius -- see the config note:
  -- at 2000 tiles these would be 400 tiles apart and the front is outside the
  -- viewport anyway.
  if wl.light_enabled and r <= wl.light_max_radius then
    local bb = heat.rgb(k_front)
    local hue = {r = bb.r, g = bb.g, b = bb.b, a = 1}
    local scale = th * wl.light_scale_per_thickness
    if scale < wl.light_scale_min then scale = wl.light_scale_min end
    if scale > wl.light_scale_max then scale = wl.light_scale_max end
    local n = math.floor((TAU * r) / wl.light_spacing)
    if n < wl.light_count_min then n = wl.light_count_min end
    if n > wl.light_count then n = wl.light_count end
    local iso = C.blast.iso_y
    for i = 0, n - 1 do
      local a = i * TAU / n + sw.wall_phase
      rendering.draw_light{
        sprite = wl.light_sprite, surface = surface,
        target = {sw.x + math.cos(a) * r, sw.y + math.sin(a) * r * iso},
        -- THE RAW BLACK-BODY HUE, not front_c: heat.glow_rgb has already
        -- scaled that one by the emission, and `intensity` below scales by it
        -- again -- squaring the falloff and leaving the rim of a big shot at
        -- 2% of full instead of 21%. Straight, not premultiplied, following
        -- draw_orb's own working light call (scripts/implode.lua): a hue at
        -- full alpha, with brightness carried entirely by `intensity`.
        color = hue,
        intensity = wl.light_intensity * glow,
        scale = scale, time_to_live = 2,
      }
    end
  end
end

-- =============================================================================
-- The ring of fire
-- =============================================================================

--- Stamp a ring of `puff` from r_from to r_to, banded and jittered per `w`.
--- Shared by draw_front (plasma ring) and draw_firewave (ground-fire trail).
--- Stamped by circumference, so neither ring thins with radius; called when the
--- front has moved, not on a clock. Each layer is rotated by a golden-ratio
--- fraction of its stamp step, so layers never line up into spokes.
--- The budget is spent ring by ring, LEADING EDGE FIRST: layers that no longer
--- fit are dropped, never thinned.
--
-- @param w          table   a ring config (C.blast.rings.wave or .firewave):
--                            band_enabled/band_max_layers/band_layer_spacing/
--                            band_min_layer_stamps/max_stamps/min_stamps/
--                            jitter_fraction/jitter_max
-- @param puff_for   function(sw, lr) -> prototype name for a layer at radius
--                            lr. A function, not a name, because the wave's
--                            puff is built per heat step and the wall cools
--                            across its own depth -- so the trailing layers of
--                            one stamp are hotter art than its leading edge.
-- @param puff_tiles number  this puff's drawn width in tiles, for the gap
-- @param spacing    number  tiles between stamps along the ring
-- @param rot0       number  rotation counter to continue from (sw.layer_n or
--                           sw.fw_layer_n -- caller stores the return back)
-- @param amp        number|nil  the tick's Rayleigh-Taylor amplitude (rt_amp),
--                            the one draw_wall uses; nil or 0 for a plain circle.
-- @return number    the rotation counter to store back
local function stamp_ring(sw, surface, r_from, r_to, w, puff_for, puff_tiles, spacing, rot0, amp)
  local depth = r_to - r_from
  if depth < 0 then depth = 0 end
  local gap = math.max(0.5, puff_tiles * w.band_layer_spacing)

  local layers = 1
  if w.band_enabled and depth > gap then
    layers = math.ceil(depth / gap)
    if layers > w.band_max_layers then layers = w.band_max_layers end
  end

  -- Jitter proportional to the radius it scatters around, capped: enough to
  -- break a machine-drawn edge, not enough to break the shape.
  local jit = r_to * w.jitter_fraction
  if jit > w.jitter_max then jit = w.jitter_max end

  -- THE BIGGEST ENTITY SOURCE IN THE MOD: up to w.max_stamps explosions per
  -- call (900 wave + 700 firewave), several calls in flight, each an
  -- engine-updated entity for as long as its animation plays. The bill lands on
  -- F4's "Entity update", never on this mod's script line.
  --
  -- CULLED BY ARC, NOT BY RING. A whole-circumference yes/no passes the moment
  -- one watcher's band overlaps the annulus, so a player beside the front pays
  -- for the ~90% of the circle they cannot see. Band padded by the RT swing
  -- (rt_factor is bounded by 1 +/- amp) and the jitter, so a displaced puff
  -- still counts as visible.
  --
  -- SAFE TO CULL: a stamp is a short-lived explosion that plays once and
  -- expires. arcsweep's fire wall is deliberately NOT culled -- it has to
  -- exist when someone walks up to the ground later.
  local pad = amp or 0
  local arcs = view.arcs(surface.index, sw.x, sw.y,
                         r_from * (1 - pad) - jit, r_to * (1 + pad) + jit)
  if not arcs then return rot0 or 0 end

  local iso = C.blast.iso_y

  local budget = w.max_stamps
  local rot = rot0 or 0
  for li = 0, layers - 1 do
    -- Outermost first, so what gets dropped is the trailing edge.
    local lr = r_to - (depth * li) / layers
    if lr >= 1 then
      local n = math.floor((2 * math.pi * lr) / spacing)
      if n < w.min_stamps then n = w.min_stamps end
      if n > budget then n = budget end
      -- Below this a layer is scattered puffs rather than a ring, so the
      -- remaining budget is better left unspent than smeared.
      if n < w.band_min_layer_stamps then break end
      budget = budget - n

      local step = (2 * math.pi) / n
      rot = rot + 1
      local offset = step * ((rot * 0.6180339887) % 1)
      local puff = puff_for(sw, lr)

      -- `budget` is charged the full circle above, not what survives the arc
      -- test: the visible density, the golden-ratio phase and the worst-case
      -- spend per call all stay exactly what they are without a watcher.
      for i = 0, n - 1 do
        local a = i * step + offset
        if view.in_arcs(arcs, a) then
          -- math.random is Factorio's deterministic RNG in the control stage.
          -- THE SAME RAYLEIGH-TAYLOR FACTOR THE WALL IS DRAWN WITH, so the
          -- texture lands ON the surface instead of on the true circle the
          -- surface has swung away from. Applied to the modulated radius, then
          -- jittered -- the lump is the shape, the jitter is the grit.
          local rr = lr * rt_factor(sw, a, amp) + (math.random() * 2 - 1) * jit
          surface.create_entity{
            name = puff,
            position = {sw.x + math.cos(a) * rr, sw.y + math.sin(a) * rr * iso},
          }
        end
      end

      if budget <= 0 then break end
    end
  end
  return rot
end

--- The plasma puffs. ONE PROTOTYPE PER YIELD STEP AND HEAT STEP
--- (N.ex_wave_for): an explosion's scale, lifetime and TINT are all baked at
--- load and create_entity sets none of them, so a front that cools as it
--- travels needs one puff per colour it passes through.
--
-- THESE ARE TEXTURE NOW, NOT THE WALL. Until this pass they were the entire
-- shock front, and a ring of billowing fireballs is a collage of fireballs --
-- nothing joins them. draw_wall above carries the continuous surface; these
-- break it up so it does not read as painted geometry.
local function wave_puff(sw, lr)
  local R = sw.radius
  local u = (R and R > 0) and (lr / R) or 1
  local k = C.blast.rings.wave.wall_kelvin(sw.kelvin, u)
  return N.ex_wave_for(sw.variant or 1, heat.step_for(k))
end

local function draw_front(sw, surface, r_from, r_to, amp)
  local w = C.blast.rings.wave
  if not w.enabled then return end
  if r_to < 1 then return end

  sw.layer_n = stamp_ring(sw, surface, r_from, r_to, w, wave_puff,
                           w.stamp_tiles(sw.variant or 1),
                           w.stamp_spacing(sw.variant or 1),
                           sw.layer_n, amp)
end

--- The ground-fire trail: the same ring, tighter and far shorter-lived.
--
-- PER HEAT STEP, exactly like wave_puff above and for the same reason. It used
-- to be one flat prototype at a hand-picked ember tint, which put a ~1900 K
-- fire ring on a wall the same tick's wall_kelvin was drawing at 15-48 kK --
-- one point on the map claiming two temperatures, and visibly so. Both stamp
-- layers and the surface under them now read the same law at the same radius.
local function firewave_puff(sw, lr)
  local R = sw.radius
  local u = (R and R > 0) and (lr / R) or 1
  local k = C.blast.rings.wave.wall_kelvin(sw.kelvin, u)
  return N.ex_firewave_for(sw.variant or 1, heat.step_for(k))
end

local function draw_firewave(sw, surface, r_from, r_to, amp)
  local fw = C.blast.rings.firewave
  if not fw.enabled then return end
  if r_to < 1 then return end

  sw.fw_layer_n = stamp_ring(sw, surface, r_from, r_to, fw, firewave_puff,
                              fw.stamp_tiles(sw.variant or 1),
                              fw.stamp_spacing(sw.variant or 1),
                              sw.fw_layer_n, amp)
end

--- The front on the MAP: one chart-mode ring at the front's true radius, every
--- tick, so it moves smoothly even between stamped layers. The puffs are
--- "not-on-map" and always will be; this is the wave as the chart sees it.
local function draw_front_chart(sw, surface, r)
  local ch = C.blast.rings.wave.chart
  if not (ch and ch.enabled) then return end
  if r < (ch.min_radius or 0) then return end
  -- THE MAP RING IS THE SAME TEMPERATURE AS THE WALL, so a player watching a
  -- full-yield shot from the chart -- the only place it fits on screen -- sees
  -- the same blue-white-to-ember progression as someone standing next to it,
  -- rather than a fixed orange ring that says nothing about the wave's age.
  -- Opaque: the chart is a flat diagram with no lighting to carry a faint
  -- colour, so the emission scales the HUE here, not the alpha.
  local c = heat.glow_rgb(C.blast.rings.wave.wall_kelvin(sw.kelvin, r / sw.radius))
  mapdraw.circle({
    color = {r = c.r, g = c.g, b = c.b, a = ch.color.a or 1},
    radius = r, width = ch.width, filled = false,
    target = {sw.x, sw.y}, surface = surface, time_to_live = 2,
  }, {chart_only = true, width_mult = 1.0, min_radius = ch.min_radius})
end

--- The dark base of the wall of fire. FILL is off by default -- a translucent
--- black disc over freshly painted volcanic rock is two dark layers stacked,
--- reading as a hole rather than a burn, now that the paint follows the front
--- rather than lagging it. RIM stays: it's what reads as a wall on the
--- ground rather than a decal.
local function draw_shadow(sw, surface, u)
  local sh = C.blast.rings.wave.shadow
  if not (sh and sh.enabled) then return end

  local r = u * sw.radius * sh.radius_mult
  if r < 2 then return end
  if r > sh.max_radius then r = sh.max_radius end

  local fade = 1.0
  if sh.fade_with_paint and sw.radius > 0 then
    local pr = (sw.paint_r or 0) / sw.radius
    fade = 1.0 - pr * pr
    if fade < 0 then fade = 0 elseif fade > 1 then fade = 1 end
  end
  if fade <= 0.01 then return end

  if sh.fill_enabled then
    local fc = sh.fill_color
    mapdraw.circle{
      color = {r = fc.r, g = fc.g, b = fc.b, a = fc.a * fade},
      radius = r, filled = true,
      target = {sw.x, sw.y}, surface = surface, time_to_live = 2,
      draw_on_ground = true,
    }
  end

  local rc = sh.rim_color
  mapdraw.circle{
    color = {r = rc.r, g = rc.g, b = rc.b, a = rc.a * fade},
    radius = r, filled = false, width = sh.rim_width,
    target = {sw.x, sw.y}, surface = surface, time_to_live = 2,
    draw_on_ground = true,
  }
end

-- =============================================================================
-- The fireball leaves nothing
-- =============================================================================

--- Sweep the bodies out of the fireball ring. Once per shot, after the payout
--- has crossed it -- every listener sees the death first, then the bodies go.
local function clear_bodies(sw, surface)
  local cp = C.blast.rings.corpses
  if not (cp and cp.enabled) or sw.cleared then return end
  sw.cleared = true

  local r = sw.radius * cp.radius_fraction
  if r > cp.max_radius then r = cp.max_radius end
  if r < 1 then return end

  for _, e in pairs(surface.find_entities_filtered{
    position = {sw.x, sw.y}, radius = r, type = cp.types,
  }) do
    if e.valid then e.destroy() end
  end
end

-- =============================================================================
-- The map
-- =============================================================================

--- The wave on the map (C.blast.rings.chart_ahead). AHEAD: generated chunks not
--- yet charted, out to lead_ticks of the front's current speed, each pass capped at
--- a few passes of travel. BEHIND: every generated chunk re-charted once the front,
--- the payout and the paint have all passed its farthest corner.
-- MUST re-chart behind: a chart does not follow set_tiles or deaths on its own.
local function chart_step(sw, surface, r, elapsed, paint_done)
  local ca = C.blast.rings.chart_ahead
  if not (ca and ca.enabled) then return end
  if (elapsed % ca.interval) ~= 0 then return end
  local force = game.forces[sw.force]
  if not force then return end

  local v = C.blast.rings.wave.front_curve * r / math.max(1, elapsed)
  local lead = v * ca.lead_ticks
  if lead < ca.lead_min then lead = ca.lead_min end
  local target = r + lead
  local cap = math.max(ca.lead_min, 3 * v * ca.interval)
  if target > sw.chart_r + cap then target = sw.chart_r + cap end
  if target > sw.radius then target = sw.radius end

  if target > sw.chart_r then
    if ca.generate then
      front.each_ring_run(sw.x, sw.y, sw.chart_r, target, function(j, i0, i1)
        for i = i0, i1 do
          if not surface.is_chunk_generated({i, j}) then
            surface.request_to_generate_chunks({i * CHUNK + 16, j * CHUNK + 16}, 0)
            sw.generated = sw.generated + 1
          end
        end
      end)
    end
    sw.charted = sw.charted + front.chart_runs(force, surface, sw.x, sw.y, sw.chart_r, target, true)
    sw.chart_r = target
  end

  if ca.refresh_behind then
    -- Behind the payout too: a chunk charted while its nests wait in the queue keeps them on the map.
    local pr = r - DIAG
    local paid = front.paid_radius(sw.front)
    if paid and paid - DIAG < pr then pr = paid - DIAG end
    if sw.paint_r - DIAG < pr and not paint_done then pr = sw.paint_r - DIAG end
    if paint_done and elapsed >= sw.ticks and front.done(sw.front) then
      pr = sw.radius + DIAG
    end
    if pr > sw.refresh_r then
      front.chart_runs(force, surface, sw.x, sw.y, sw.refresh_r, pr, false)
      sw.refresh_r = pr
    end
  end
end

--- Chart a chunk generated inside a running wave's charted reach, once its blast has
--- been replayed onto it: the wave's own passes skip ground that does not exist yet.
function detonate.reveal(surface, cpos)
  local sweeps = storage.sweeps
  if not sweeps then return end
  local si = surface.index
  local x0, y0 = cpos.x * CHUNK, cpos.y * CHUNK
  for _, sw in ipairs(sweeps) do
    local reach = sw.chart_r
    if sw.surface == si and reach and reach > 0 then
      local dx = math.max(x0 - sw.x, 0, sw.x - (x0 + CHUNK))
      local dy = math.max(y0 - sw.y, 0, sw.y - (y0 + CHUNK))
      local force = game.forces[sw.force]
      if force and dx * dx + dy * dy <= reach * reach then
        force.chart(surface, front.chunk_box(cpos.x, cpos.x, cpos.y))
        sw.charted = sw.charted + 1
      end
    end
  end
end

-- =============================================================================
-- The thunder
-- =============================================================================

--- how loud the boom lands, as a fraction of C.sound.boom_volume.
--
-- ENERGY-BASED, because duration cannot be: play_sound has no stop or seek in
-- the 2.0.77 runtime API (scripts/beam.lua's note on the sear/arc/fire sounds is
-- the same finding), so the 10.5 s clip always plays to the end regardless of
-- what the shot paid for. Volume is the lever that is actually available.
--
-- sw.variant is already the fraction of a standard shot this detonation was
-- BUILT at (impact.variant_for) -- the same number that names the carrier and
-- the wave puff, so the boom cannot disagree with the picture about how big the
-- shot was. floor + (1 - floor) * min(1, variant^exponent): a 1% shot still
-- reads as an impact, not a rounding error to silence.
local function boom_volume(sw)
  local snd = C.sound
  local v = (sw.variant or 1) ^ (snd.boom_volume_exponent or 1)
  if v > 1 then v = 1 end
  local floor = snd.boom_volume_floor or 0
  return floor + (1 - floor) * v
end

--- Broadcast rather than played in the world, so it reaches someone watching
--- from the map. PER LISTENER, on the tick sound actually reaches them:
--- sound travels at C.sound.boom_speed, light does not travel at all.
--
-- Deterministic despite iterating players: connected_players and positions are
-- synced state, so every client writes the same `heard` table.
local function thunder(sw, elapsed)
  if sw.heard == false then return end
  sw.heard = sw.heard or {}
  local snd = C.sound
  local pos = {x = sw.x, y = sw.y}
  local vol = boom_volume(sw)
  local pending = false
  for _, player in pairs(game.connected_players) do
    local pi = player.index
    if not sw.heard[pi] then
      local d = audio.hearing_distance(player, sw.surface, sw.x, sw.y)
      if not d or d > snd.boom_distance then
        sw.heard[pi] = true
      else
        local at = d / snd.boom_speed
        if at < snd.boom_delay_min then at = snd.boom_delay_min end
        if at > snd.boom_delay_max then at = snd.boom_delay_max end
        if elapsed >= at then
          sw.heard[pi] = true
          audio.to_player(player, sw.surface, pos, N.sound.boom,
                          {max_distance = snd.boom_distance, volume = vol})
        else
          pending = true
        end
      end
    end
  end
  if not pending then sw.heard = false end
end

-- =============================================================================
-- The tick
-- =============================================================================

--- Advance every running sweep by one tick.
local function step()
  local sweeps = storage.sweeps
  if not sweeps or #sweeps == 0 then return end
  profile.start("wave (total)")

  local rings = C.blast.rings
  local w     = rings.wave
  local ca    = rings.chart_ahead

  for si = #sweeps, 1, -1 do
    local sw      = sweeps[si]
    local elapsed = game.tick - sw.started
    -- repeat/until true is the `continue` idiom. NOT goto: tools/verify.py check
    -- 12 does not model Lua labels, and a false positive is still a broken check.
    repeat
    if elapsed < 0 then
      crater.ahead(sw, elapsed)
      break
    end

    -- A sweep without a front cannot be resumed.
    if not sw.front then
      crater.finish(sw)
      table.remove(sweeps, si)
      break
    end

    local surface = game.get_surface(sw.surface)
    if not (surface and surface.valid) then
      crater.finish(sw)
      table.remove(sweeps, si)
      break
    end

    -- THE RELEASE FIREBALL. The sweep's first tick IS the release tick -- the
    -- `started` offset above is the same C.blast.stages.flash + implosion
    -- clock prototypes/vfx/waves.lua bakes its flash stage against -- so this
    -- lands on the same tick as the flash's light and the camera shake,
    -- without the data stage having to know a temperature it cannot know.
    --
    -- LATCHED rather than tested on `elapsed == 0`: the tick this fires on is
    -- the one thing here that must happen exactly once, and a latch says so
    -- instead of depending on step() staying registered at on_nth_tick(1).
    --
    -- wall_kelvin at u = 0 clamps to the fireball ring and returns the release
    -- temperature itself -- and supplies kelvin_fallback when the sweep
    -- carries none (the console command, the vestigial shell path).
    if not sw.released then
      sw.released = true
      local rl = C.blast.release
      -- ⚠️ AND ONLY IF THIS REALLY IS THE FIRST TICK. A sweep saved before
      -- this version carries no `released` field, so on the first tick after
      -- the upgrade it would look brand new and pop a fireball in the middle
      -- of a wave already halfway to the rim. The latch still closes; the
      -- entity is what the window guards.
      if rl.enabled and elapsed <= 1 then
        local k = C.blast.rings.wave.wall_kelvin(sw.kelvin, 0)
        surface.create_entity{
          name = N.ex_release_for(sw.variant or 1, heat.step_for(k)),
          position = {sw.x, sw.y},
        }
      end
    end

    profile.start("wave/thunder")
    thunder(sw, elapsed)
    profile.stop("wave/thunder")

    -- THE FRONT. Sedov-Taylor, and ONE number for everything that follows.
    local u = (elapsed / sw.ticks) ^ w.front_curve
    if u > 1 then u = 1 end
    local r = u * sw.radius

    -- The payout: search just ahead, pay what has been passed.
    profile.start("wave/payout (search + damage)")
    front.advance(sw.front, surface, r, {types = exclude_types(), invert = true,
                                         skip = SKIP, lead = rings.acquire_lead,
                                         movers = MOVERS,
                                         generate_to = rings.generate_ahead_radius},
                  function(e, d) detonate.hit(sw, e, d) end,
                  rings.entity_budget_per_tick)
    slay.flush()
    -- Published AFTER the advance, so a chunk generated later this tick is judged
    -- against what the front really searched. See scar.lua's ownership rule.
    if sw.scar then sw.scar.acq = sw.front.acq end
    profile.stop("wave/payout (search + damage)")

    -- Trees and rocks: normally already done by the sphere, in which case this
    -- is one table lookup. A shot with no sphere is driven from here alone.
    -- The wave's own search has just generated the ground ahead of it, so the
    -- retry is immediate (0).
    profile.start("wave/flora")
    flora.advance(surface, sw.x, sw.y, sw.radius, r, sw.force, 0)
    if elapsed <= sw.ticks then
      flora.debris(surface, sw.x, sw.y, sw.radius, r, sw.force)
    end
    profile.stop("wave/flora")

    -- The ring of fire -- stamped on distance travelled, not on a clock.
    profile.start("wave/ring of fire + firewave")
    -- ONE instability amplitude for this tick, read by the wall and by BOTH
    -- stamp layers -- see rt_factor. The wall and its texture cannot be drawn
    -- at different shapes because they are no longer given the chance to be.
    --
    -- The phase is rolled HERE, not in draw_wall, for the same reason: the
    -- firewave ring is gated on its own `enabled` flag, so with the wall off it
    -- would read sw.wall_phase as nil and fall back to a phase of 0 -- every
    -- shot lumping at identical angles instead of its own.
    wall_phase(sw)
    local amp = rt_amp(u)

    if w.enabled then
      local gap = w.stamp_tiles(sw.variant or 1) * w.band_layer_spacing
      local last = sw.stamp_r
      if elapsed <= sw.ticks then
        -- THE WALL EVERY TICK, the puffs only when the front has moved. The
        -- wall is the continuous surface and has to track the front exactly or
        -- it lags visibly; the puffs are texture stamped onto it and would
        -- overdraw a slow front by tens of thousands of entities for nothing.
        draw_wall(sw, surface, u, r)
        if (not last and r >= 1) or (last and r - last >= gap) then
          draw_front(sw, surface, last or 0, r, amp)
          sw.stamp_r = r
        end
        draw_front_chart(sw, surface, r)
        draw_shadow(sw, surface, u)
      elseif not sw.final_stamp then
        -- The last layer, so the ring reaches the rim rather than stopping up to
        -- one gap short of it.
        sw.final_stamp = true
        if last and sw.radius - last > gap * 0.25 then
          draw_front(sw, surface, last, sw.radius, amp)
        end
        sw.stamp_r = sw.radius
      end
    end

    -- The ground-fire trail -- same distance-gated banding as the ring of
    -- fire above, its own (much tighter) cadence and its own state fields,
    -- so the two rings can never fight over sw.stamp_r/sw.layer_n.
    do
      local fw = C.blast.rings.firewave
      if fw.enabled then
        local fgap = fw.stamp_tiles(sw.variant or 1) * fw.band_layer_spacing
        local flast = sw.fw_stamp_r
        if elapsed <= sw.ticks then
          if (not flast and r >= 1) or (flast and r - flast >= fgap) then
            draw_firewave(sw, surface, flast or 0, r, amp)
            sw.fw_stamp_r = r
          end
        elseif not sw.fw_final_stamp then
          sw.fw_final_stamp = true
          if flast and sw.radius - flast > fgap * 0.25 then
            draw_firewave(sw, surface, flast, sw.radius, amp)
          end
          sw.fw_stamp_r = sw.radius
        end
      end
    end
    profile.stop("wave/ring of fire + firewave")

    -- THE FIREBALL LEAVES NOTHING, once the payout has crossed the fireball ring.
    if not sw.cleared
       and sw.front.next_i * sw.front.bw > rings.fireball_u * sw.radius then
      profile.start("wave/clear bodies")
      clear_bodies(sw, surface)
      profile.stop("wave/clear bodies")
    end

    profile.start("wave/crater (paint + clear + probes)")
    crater.step(sw, surface, r, elapsed)
    profile.stop("wave/crater (paint + clear + probes)")
    local paint_done = crater.painted(sw)
    profile.start("wave/chart")
    chart_step(sw, surface, r, elapsed, paint_done)
    profile.stop("wave/chart")

    -- Done when the payout, the front, the crater and the map have all arrived.
    -- A force that no longer exists has no map to refresh.
    local chart_done = not (ca and ca.enabled and ca.refresh_behind)
      or not game.forces[sw.force]
      or sw.refresh_r >= sw.radius
    if front.done(sw.front) and elapsed >= sw.ticks and crater.done(sw) and chart_done
       and flora.finished(sw.surface, sw.x, sw.y) then
      local f = sw.front
      storage.last_sweep = {
        tick      = game.tick,
        radius    = sw.radius,
        found     = f.found,
        binned    = f.binned,
        searches  = f.runs,
        damaged   = sw.damaged,
        destroyed = sw.destroyed,
        movers    = f.mpaid,
        painted   = sw.painted,
        charted   = sw.charted,
        generated = sw.generated,
      }
      crater.finish(sw)
      table.remove(sweeps, si)
    end
    until true
  end
  profile.stop("wave (total)")
end

events.on_nth_tick(1, step)

detonate.step = step

return detonate
