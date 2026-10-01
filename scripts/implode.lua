-- scripts/implode.lua -------------------------------------------------------------
-- THE COLLAPSE: everything between the beam cutting and the release firing --
-- the charging sphere's circle shrinking on a convergence law, a shell of
-- stamped puffs converging with it, streaks falling in from outside, and the
-- core they all land on. Then a held beat, and prototypes/vfx/waves.lua takes
-- over.
--
-- WHY THIS IS CONTROL STAGE, NOT A DATA-STAGE TRIGGER TREE: a trigger tree
-- can't be told a number not known until the shot fires -- the puff density
-- and spacing have to come off the shell's actual circumference (an `area`
-- trigger only has repeat_count + a disc radius), the sprites have to scale
-- continuously with yield, and the shell is Rayleigh-Taylor unstable and
-- breaks up as it converges, which a trigger can't be given a shape to do at
-- all. The charging sphere is also drawn at the REAL continuous radius so the
-- collapse can start exactly where the sphere left off -- the discontinuity a
-- data-stage gather could never close.
--
-- THE DRAWING DISCIPLINE, shared with scripts/beam.lua's sphere: everything
-- is redrawn every tick with a two-tick life rather than a persisted
-- LuaRenderObject, so there is no lifetime to invalidate on abort/save-load/
-- surface-removal -- stop calling it and it is gone.
--
-- DETERMINISM: math.random is Factorio's own RNG in the control stage, so the
-- per-shot Rayleigh-Taylor phase and streak layout are identical on every
-- client. The ONE thing here that reads players is the draw cull
-- (scripts/view.lua) -- connected players' position/surface/render_mode are
-- synced state, so every client culls the same objects; see view.lua's own
-- determinism note. Zoom is never read: it is genuinely client-local.
----------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
-- Every circle below is drawn twice -- once in the world, once in
-- render_mode "chart" -- because a collapse 2000 tiles wide is only watchable
-- from the map. See scripts/mapdraw.lua.
local mapdraw = require("scripts.mapdraw")
-- The collapse's shock finds what it crosses through the same front the
-- wave and the fire wave use. Requires nothing but config-free arithmetic.
local front   = require("scripts.front")
-- Black-body colour for the collapse (C.heat). Named heatlib: `heat` is
-- already draw_orb's own parameter name.
local heatlib = require("lib.heat")
local slay    = require("scripts.slay")
local profile = require("scripts.profile")
local view    = require("scripts.view")

local implode = {}

local TAU = 2 * math.pi

-- =============================================================================
-- Geometry
-- =============================================================================

--- The shell's radius at collapse progress `t` (0 at the cut, 1 at full
--- compression), in tiles.
--
-- THE CONVERGENCE LAW. r ~ (1 - t)^alpha with alpha < 1, so dr/dt diverges as it
-- closes: slow, slow, then gone. See C.blast.implosion.converge_exponent for the
-- Guderley derivation and for the per-ring deltas that show what the old,
-- near-linear expression was doing instead.
local function radius_at(im, t)
  local imp  = C.blast.implosion
  local endf = imp.radius_end_fraction
  local u    = (1 - t) ^ imp.converge_exponent
  return im.r0 * (endf + (1 - endf) * u)
end

implode.radius_at = radius_at

--- Collapse temperature in kelvin at progress `t`: the ball's at the cut, times
--- C.heat.collapse_gain as it compresses.
-- The ball, the shell and the core all read this; a second copy is the same gas
-- drawn at two temperatures.
local function collapse_kelvin(kelvin, t)
  return (kelvin or C.blast.rings.wave.wall.kelvin_fallback)
         * (1 + C.heat.collapse_gain * t)
end

--- Linear interpolation between two colours. `u` is clamped by the caller.
local function mix(a, b, u)
  return {
    r = a.r + (b.r - a.r) * u,
    g = a.g + (b.g - a.g) * u,
    b = a.b + (b.b - a.b) * u,
    a = (a.a or 1) + ((b.a or 1) - (a.a or 1)) * u,
  }
end

-- =============================================================================
-- The ball
-- =============================================================================

--- Redraw the collapsing sphere.
--
-- THIS IS THE SAME CIRCLE scripts/beam.lua was drawing one tick ago, at the
-- radius it had reached, in its own colours -- read from C.beam.sphere rather
-- than duplicated here, because a second pair of colours is the ball changing
-- appearance on the frame the beam cuts, which is the discontinuity this whole
-- version exists to remove.
--
-- IT GETS HOTTER AS IT GETS SMALLER, which is the physical claim of an
-- implosion: the same energy in a smaller volume. The rim travels from the
-- sphere's own rim colour toward heat_color, the near-black fill lightens
-- part of the way after it, and the rim THICKENS -- a constant screen-space
-- width on a shrinking circle reads as the ball getting thinner, which is
-- backwards.
--- THE ORB: shadow, body, shading, rim. The ONE drawing of the ball, used by
--- the growing sphere (scripts/beam.lua, heat 0) and the collapse (below, heat
--- rising to 1) -- two copies would be the ball changing look on the cut frame.
--
-- A SPHERE, NOT A DISC. A flat fill plus an outline is a hoop. What
-- makes a round thing read as a ball is light falling across it, so the body
-- carries a stack of smaller, lighter discs, each shifted further toward the
-- light (C.blast.implosion.ball.shade.light, upper-left -- the side Factorio's
-- own shadows fall away from). Their overlap builds a gradient that is
-- brightest off-centre toward the light and leaves the far limb darkest, and
-- the ground shadow is pushed the other way to match. The searing rim is kept
-- whole on top: an incandescent surface glows at every edge.
--
-- The shading is WORLD ONLY. The map is a flat diagram at a hundredth of the
-- zoom, where a highlight is sub-pixel and each layer would be one more chart
-- object every tick for nothing.
--
-- STILL READ AS A TARGET, NOT A CORE (user, from a screenshot of the
-- charging sphere at 139 tiles/5%). Three fixes, same root cause -- too few
-- discrete steps to fake something continuous: shade.layers 6 -> 16 with a
-- linear (not quadratic) colour ease, so the banding drops below the eye's
-- contrast threshold instead of stacking into the last two layers; the rim
-- is now a halo (fading, widening strokes stepping outward) instead of one
-- hard stroke, because a single crisp ring is exactly the shape
-- render.preview's own danger bands use for "informational overlay", not
-- "edge of a hot object"; and the ball now casts real light (bl.light,
-- scaled off the current radius), since nothing before this leaked outside
-- its own silhouette no matter how hot the fill got.
-- @param heat number 0..1  how far toward C.blast.implosion.ball.heat_color
-- @param tone table|nil {kelvin, glow 0..1}: when given, the rim is the
--        black-body colour of that temperature (C.heat) instead of the fixed
--        shell/heat colours, and the fill glows toward it by glow.
function implode.draw_orb(x, y, surface, r, heat, tone)
  local imp = C.blast.implosion
  local bl  = imp.ball
  local sp  = C.beam.sphere
  local t   = heat or 0

  local rim, fill, shade_to
  if tone then
    local H = C.heat
    local bb = heatlib.rgb(tone.kelvin)
    rim = {r = bb.r, g = bb.g, b = bb.b, a = sp.shell_color.a or 1}
    local g = math.max(0, math.min(1, tone.glow or 0))
    fill = mix(sp.fill_color, rim, math.max(H.ball_fill_glow * g, bl.fill_heat * t))
    fill.a = sp.fill_color.a
    shade_to = {r = bb.r, g = bb.g, b = bb.b, a = 1}
  else
    rim  = mix(sp.shell_color, bl.heat_color, t)
    fill = mix(sp.fill_color, rim, bl.fill_heat * t)
  end

  -- Underneath first, and explicitly on the ground rather than by creation
  -- order: a dense ball occludes, and a circle drawn on grass with nothing under
  -- it reads as a decal rather than as an object standing on the map.
  if bl.shadow_enabled then
    local off = bl.shadow_offset or {0, 0}
    mapdraw.circle{
      color = bl.shadow_color, radius = r * bl.shadow_radius_mult, filled = true,
      target = {x + r * off[1], y + r * off[2]}, surface = surface,
      time_to_live = 2, draw_on_ground = true,
    }
  end

  mapdraw.circle{
    color = fill, radius = r, filled = true,
    target = {x, y}, surface = surface, time_to_live = 2,
  }

  -- The shading is the one layer of the orb that does NOT go through mapdraw
  -- (it is world-only -- a stack of offset discs reads as lighting in the world
  -- and as mud on a flat chart), so it needs its own cull rather than inheriting
  -- mapdraw's. Gated once for the whole stack, not per layer.
  local sh = bl.shade
  if sh and sh.enabled and sh.layers > 0
     and view.disc(surface.index, x, y, r) then
    local lit, hot
    if shade_to then
      local m = C.heat.ball_shade_mix
      lit = mix(sh.color, shade_to, m * math.min(1, tone.glow or 0))
      hot = mix(sh.hot, shade_to, m)
    else
      lit = mix(sh.color, bl.heat_color, t)
      hot = mix(sh.hot, bl.heat_color, t)
    end
    for k = 1, sh.layers do
      local u = k / sh.layers
      local c = mix(lit, hot, u ^ (sh.ease or 1))
      c.a = sh.alpha
      local shift = r * sh.offset * u
      rendering.draw_circle{
        color = c,
        radius = r * (1 - (1 - sh.inner) * u),
        filled = true,
        target = {x + sh.light[1] * shift, y + sh.light[2] * shift},
        surface = surface, time_to_live = 2,
      }
    end
  end

  local rim_width = sp.shell_width + (bl.shell_width_end - sp.shell_width) * t
  mapdraw.circle{
    color = rim, radius = r, filled = false, width = rim_width,
    target = {x, y}, surface = surface, time_to_live = 2,
  }

  -- THE HALO: fading, widening strokes stepping outward from the true edge,
  -- so the boundary bleeds into the fill/background instead of being one
  -- clean line -- see the 0.30.0 note above for why the single stroke had to
  -- go.
  local steps = bl.halo_steps or 0
  if steps > 0 then
    local a = rim.a or 1
    for k = 1, steps do
      a = a * (bl.halo_fade or 1)
      mapdraw.circle{
        color = {r = rim.r, g = rim.g, b = rim.b, a = a},
        radius = r * (1 + (bl.halo_spread or 0) * k),
        filled = false,
        width = rim_width * (1 + k * 0.4),
        target = {x, y}, surface = surface, time_to_live = 2,
      }
    end
  end

  -- THE BALL CASTS LIGHT. Everything above is confined to its own silhouette
  -- -- however hot the fill and rim get, nothing outside the edge shows it.
  -- One draw_light, same two-tick redraw as the rest of this drawing (no
  -- persisted object to manage). Scale is capped: past a point a bigger halo
  -- doesn't buy anything more on screen, and the ball is usually watched
  -- zoomed in far enough to read the fire-control panel anyway.
  local lt = bl.light
  if lt and lt.enabled then
    local scale = r * lt.scale_per_r
    if scale < lt.scale_min then scale = lt.scale_min end
    if scale > lt.scale_max then scale = lt.scale_max end
    rendering.draw_light{
      sprite = lt.sprite, surface = surface, target = {x, y},
      color = lt.color, intensity = lt.intensity, scale = scale,
      time_to_live = 2,
    }
  end
end

local function draw_ball(im, surface, r, t)
  if not C.blast.implosion.ball.enabled then return end
  -- A collapse with no recorded temperature (a save from before C.heat) keeps
  -- the old fixed palette rather than inventing one.
  local tone = im.kelvin
               and {kelvin = collapse_kelvin(im.kelvin, t), glow = 1}
               or nil
  implode.draw_orb(im.x, im.y, surface, r, t, tone)
end

-- =============================================================================
-- Infall streaks
-- =============================================================================

--- Material being dragged in from outside the shell.
--
-- Real implosion does not make dust -- dust is what comes OUT. What goes IN is
-- ground being stripped off outside the ball and falling after it, and no ring
-- of stamps can show that, because a stamp is PLACED and a streak MOVES.
--
-- Each streak sits at a fixed multiple of the shell radius, so it converges with
-- the shell rather than on a clock of its own, and its length is a fraction of
-- its current radius -- it stretches as it falls, which is what makes the motion
-- legible at a zoom where the whole event is forty pixels wide.
--
-- Lines, not projectiles: no prototype, no collision, no damage semantics to get
-- wrong, no entity churn, and the same two-tick redraw as the ball.
--- Lay out one shot's streaks. Called once, not per tick.
--
-- EXPORTED IN 0.16.3 because the growing sphere needs the same thing. A streak
-- that re-rolls its angle every frame is static noise rather than infall, so the
-- layout has to be stable for the life of the effect -- and the growth phase and
-- the collapse are one continuous piece of material being pulled in, so they had
-- better be drawn by one implementation. A second copy is the streaks changing
-- appearance on the frame the beam cuts, which is the discontinuity 0.15.0
-- exists to remove.
function implode.layout_streaks(st)
  if not (st and st.enabled and st.count > 0) then return nil end
  local out = {}
  for i = 1, st.count do
    out[i] = {
      angle = math.random() * TAU,
      reach = st.reach_min + math.random() * (st.reach_max - st.reach_min),
    }
  end
  return out
end

--- Draw a laid-out streak set around (x, y) at shell radius `r`.
--
-- Takes the config block rather than reading one, so the collapse and the growth
-- can carry different numbers through the same code. See C.beam.sphere.streaks
-- for why the growth's are different.
function implode.draw_streaks_at(x, y, streaks, surface, r, st)
  if not (st and st.enabled and streaks) then return end

  for i = 1, #streaks do
    local s   = streaks[i]
    local rr  = r * s.reach
    local len = math.max(st.length_min, rr * st.length_fraction)
    local cs, sn = math.cos(s.angle), math.sin(s.angle)
    local hx, hy = x + cs * rr, y + sn * rr
    rendering.draw_line{
      color = st.color,
      width = st.width,
      from  = {hx,                  hy},
      to    = {x + cs * (rr + len), y + sn * (rr + len)},
      surface = surface, time_to_live = 2,
    }

    -- THE LEADING TIP. A line the same colour top to bottom reads as
    -- a scratch mark, not falling debris. `hx,hy` is the end closest to the
    -- ball (the direction of travel) -- one small hot dot there says this is
    -- material about to hit, the same "gets hotter as it gets smaller" claim
    -- draw_orb already makes for the ball itself.
    if st.head_color then
      local hr = math.max(st.head_radius_min or 0, len * (st.head_radius_frac or 0))
      if hr > 0 then
        rendering.draw_circle{
          color = st.head_color, radius = hr, filled = true,
          target = {hx, hy}, surface = surface, time_to_live = 2,
        }
      end
    end
  end
end

local function draw_streaks(im, surface, r)
  implode.draw_streaks_at(im.x, im.y, im.streaks, surface, r,
                          C.blast.implosion.streaks)
end

-- =============================================================================
-- The shell
-- =============================================================================

--- Stamp one shell of the collapse.
--
-- DENSITY COMES OFF THE CIRCUMFERENCE, which is the whole reason this is not a
-- data-stage `area` trigger. Spacing is a fraction of the PUFF'S OWN WIDTH
-- rather than a tile count, so it self-tunes across an 86:1 range of radius: the
-- puff is scaled per yield step and a fixed tile spacing would be dense at one
-- end of the dial and a bead necklace at the other.
--
-- THE RAYLEIGH-TAYLOR MODULATION. A perfectly symmetric implosion is the hardest
-- engineering problem in the field and nobody has ever quite had one -- the
-- interface between a light driver and a dense core is unstable, perturbations
-- grow through the convergence, and the shell arrives lumpy. One angular
-- harmonic says that: the amplitude climbs as t^rt_growth, so the shell starts
-- smooth and only breaks up as it closes, and the phase is rolled once per shot
-- so no two rounds come apart the same way.
--
-- The phase is per SHOT and not per shell, deliberately: RT spikes are radial
-- and stand still while the shell falls past them. A per-shell phase would make
-- the lobes rotate, which reads as a spinning ring rather than an unstable one.
local function stamp_shell(im, surface, index)
  local imp = C.blast.implosion

  local t = (imp.rings > 1) and (index / (imp.rings - 1)) or 1
  local r = radius_at(im, t)
  if r < 1 then return end

  local spacing = math.max(0.5, imp.stamp_tiles(im.variant) * imp.stamp_spacing_fraction)
  local n = math.floor((TAU * r) / spacing)
  if n < imp.min_stamps then n = imp.min_stamps end
  if n > imp.max_stamps then n = imp.max_stamps end

  -- Colour is baked per prototype, so the rung is picked here. This shell is
  -- stamped on the tick the ball reaches this radius, so both read one `t`.
  local name = N.ex_gather_for(im.variant,
                               heatlib.step_for(collapse_kelvin(im.kelvin, t)))
  local amp  = imp.rt_enabled and (imp.rt_amplitude * (t ^ imp.rt_growth)) or 0

  -- CULLED BY ARC like the wave's stamp_ring, and for the same reason: up to
  -- imp.max_stamps engine-updated explosion entities per shell, most of them
  -- on the far side of a ring nobody is standing near. Short-lived explosions
  -- only, so nothing is missing afterwards. The RT modulation swings the ring
  -- by +/- amp, so the band is padded by it.
  local arcs = view.arcs(surface.index, im.x, im.y, r * (1 - amp), r * (1 + amp))
  if not arcs then return end

  local step = TAU / n

  for j = 0, n - 1 do
    local a  = j * step
    if view.in_arcs(arcs, a) then
      local rr = r * (1 + amp * math.sin(imp.rt_modes * a + im.phase))
      surface.create_entity{
        name = name,
        position = {im.x + math.cos(a) * rr, im.y + math.sin(a) * rr},
      }
    end
  end
end

-- =============================================================================
-- The shock
-- =============================================================================

--- THE COLLAPSE HITS LIKE A CONVERGING SHOCK: the shell is a Guderley
--- converging shock (C.blast.implosion.shock has the derivation), so each
--- thing it passes over takes ONE physical hit as the shell crosses it, and
--- the hit grows as the shell closes -- dose ~ r^-0.907, since the pressure
--- behind a strong shock goes as the square of its speed and this shock
--- accelerates inward: the rim is nudged, a tenth of the way in takes eight
--- times that, the centre is crushed. Found chunk by chunk just ahead of the
--- shell (scripts/front.lua), never a full-disc query per application. No
--- friendly interlock, deliberately -- this is the detonation, not the lance.
local function shock(im, surface, r)
  local sk = C.blast.implosion.shock
  local f = im.front
  if not (sk and sk.enabled and f) then return end
  if front.done(f) then return end

  local r0 = im.r0
  if not r0 or r0 <= 0 then return end
  local base    = C.blast.dose.lethal_dose * sk.dose
  local cap     = base * sk.cap_mult
  local floor_r = r0 * sk.floor_fraction
  local pexp    = C.blast.implosion.shock_exponent
  local force   = im.force or C.blast.rings.default_force

  front.advance(f, surface, r, {types = sk.types, lead = sk.lead,
                                movers = C.blast.movers.enabled and C.blast.movers or nil,
                                mover_step = sk.mover_step_tiles,
                                -- NOT nil. r0 is the full blast radius, so an
                                -- unbounded front builds the whole disc inside
                                -- the collapse's own few seconds -- 97.8% of
                                -- this mechanism's measured cost. See
                                -- C.blast.implosion.shock.generate_to.
                                generate_to = sk.generate_to},
                function(v, d)
    local rr = d
    if rr < floor_r then rr = floor_r end
    local amount = base * (rr / r0) ^ (-pexp)
    if amount > cap then amount = cap end
    slay.hit(v, amount, force, sk.damage_type)
  end, sk.budget)
  slay.flush()
end

-- =============================================================================
-- Starting one
-- =============================================================================

--- Begin a collapse at `pos`.
--
-- Called from scripts/impact.lua, from the same call that creates the carrier
-- and schedules the wave -- so there is still exactly one place in this mod that
-- puts a detonation on the ground.
--
-- @param power   number|nil fraction of a standard shot, CONTINUOUS. The ball
--                was drawn at the real radius, so the collapse starts at the
--                real radius; only the sprites are quantised, because only
--                prototypes have to be.
-- @param variant number the built yield step, for naming the puff and the core
--                and for the collapse clock -- the same clock waves.lua offsets
--                the release by and detonate.begin delays the wave by.
-- @param force   ForceID|nil who gets the kill credit for the shock
-- @param radius  number|nil  the radius the ball actually reached; nil derives
--                            it from `power`
function implode.begin(surface, pos, power, variant, force, kelvin, radius)
  if C.blast.style ~= "implosion" then return end
  if not (surface and surface.valid and pos) then return end

  local imp = C.blast.implosion
  local r0  = radius or C.sphere_full_radius(power)

  -- The point everything falls onto, created once and left to play until the
  -- release, at the temperature of full compression: the hot end of the
  -- gradient, which is what the shell heats toward.
  surface.create_entity{
    name = N.ex_gather_core_for(variant,
                                heatlib.step_for(collapse_kelvin(kelvin, 1))),
    position = pos,
  }

  -- Streaks are laid out once, here: a streak that picks a new angle each frame
  -- is static noise, not infall.
  local streaks = implode.layout_streaks(imp.streaks)

  -- Force by NAME -- plain data in storage.
  local fname = C.blast.rings.default_force
  if type(force) == "string" then
    fname = force
  elseif force and force.valid then
    fname = force.name
  end

  local sk = imp.shock
  storage.implosions = storage.implosions or {}
  storage.implosions[#storage.implosions + 1] = {
    surface   = surface.index,
    x = pos.x, y = pos.y,
    r0        = r0,
    ticks     = math.max(1, imp.ticks_for(variant)),
    total     = imp.total_ticks_for(variant),
    variant   = variant,
    started   = game.tick,
    next_ring = 0,
    phase     = math.random() * TAU,
    streaks   = streaks,
    force     = fname,
    kelvin    = kelvin,
    -- the shock's front, from the shell's starting radius inward.
    front     = (sk and sk.enabled) and front.new{
      x = pos.x, y = pos.y, r_max = r0, dir = -1, bucket = sk.bucket_tiles,
      movers = C.blast.movers.enabled,
    } or nil,
  }
end

-- =============================================================================
-- Running them
-- =============================================================================

--- Advance every collapse by one tick.
--
-- Reverse iteration, because table.remove shifts everything after the index --
-- the same shape as scripts/detonate.lua's sweep loop and scripts/impact.lua's
-- expiry, for the same reason.
local function step()
  local list = storage.implosions
  if not list or #list == 0 then return end
  profile.start("collapse (total)")

  for i = #list, 1, -1 do
    local im      = list[i]
    local elapsed = game.tick - im.started

    -- repeat/until true is the `continue` idiom. NOT goto: tools/verify.py check
    -- 12 walks the AST for globals and does not model Lua labels, so a label
    -- reads to it as an undeclared global. A false positive is still a broken
    -- check, and this idiom costs nothing.
    repeat
      if elapsed > im.total then
        table.remove(list, i)
        break
      end

      local surface = game.get_surface(im.surface)
      if not (surface and surface.valid) then
        table.remove(list, i)
        break
      end

      -- Clamped at 1, so the ball holds at full compression -- smallest,
      -- brightest, thickest-rimmed -- through the beat rather than continuing
      -- past it into a negative radius. The beat is the effect; something has to
      -- be sitting in it.
      local t = elapsed / im.ticks
      if t > 1 then t = 1 end
      local r = radius_at(im, t)

      profile.start("collapse/draw ball + streaks")
      draw_ball(im, surface, r, t)
      draw_streaks(im, surface, r)
      profile.stop("collapse/draw ball + streaks")

      -- AND IT STILL HURTS -- as a converging shock. Every tick, because
      -- the front is incremental: each thing is found just ahead of the shell and
      -- hit once, as the shell crosses it. Once the shell has closed (t = 1) the
      -- front is driven to radius zero, so what was left in the middle is crushed
      -- during the beat rather than spared by the last 2%.
      profile.start("collapse/shock (search + damage)")
      shock(im, surface, (t >= 1) and 0 or r)
      profile.stop("collapse/shock (search + damage)")

      -- Shells are due on their own schedule, spaced evenly across the collapse.
      -- A while loop rather than an if: on a short collapse at a low yield two
      -- shells can fall on the same tick, and skipping one would leave a gap in
      -- a sequence whose whole job is to be continuous.
      while im.next_ring < C.blast.implosion.rings do
        local ti = (C.blast.implosion.rings > 1)
                   and (im.next_ring / (C.blast.implosion.rings - 1)) or 1
        if elapsed < math.floor(ti * im.ticks + 0.5) then break end
        profile.start("collapse/shells")
        stamp_shell(im, surface, im.next_ring)
        profile.stop("collapse/shells")
        im.next_ring = im.next_ring + 1
      end
    until true
  end
  profile.stop("collapse (total)")
end

events.on_nth_tick(1, step)

implode.step = step

return implode
