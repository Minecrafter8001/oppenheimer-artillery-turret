-- scripts/render.lua ----------------------------------------------------------------
-- Everything drawn on top of the world. Backlog #28, #67, #78, #79, #80.
--
--   #28  range rings when the turret is selected
--   #67  power cabling turret <-> pylons, brightening with charge
--   #78  arcs from each pylon to the barrel -- REMOVED, see render.build()
--   #79  ground glow that tracks charge, so the area brightens before a shot
--   #80  a charge readout on the turret
--
-- 2.0 RENDERING NOTES (confirmed via `apiq class LuaRendering` / LuaRenderObject)
--   * rendering.draw_* returns a LuaRenderObject, not a numeric id. It has
--     .valid, .destroy(), .color, .target.
--   * "If an entity target of an object is destroyed or changes surface, then
--     the object is also destroyed." So objects anchored to the turret clean
--     themselves up when it dies -- but a stored reference still has to be
--     checked with .valid before use, because it may already be gone.
--
-- PERSISTENCE
-- Render objects are stored in storage.render[unit_number]. They survive
-- save/load as LuaObjects. Nothing here is recreated in on_load -- doing so
-- would both write storage (an error) and desync, since one client's renders
-- are not another's.
--
-- UPS
-- Persistent objects (ring, spurs, glow) are created ONCE when the pylons
-- link, and only their `color` is written afterwards, on the turret's bucket
-- tick -- once every C.control.update_buckets ticks, not every tick. Redrawing
-- them per tick would be the expensive way to get the same picture.
--------------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
local schema = require("scripts.schema")
local pylon  = require("scripts.pylon")
-- Geometry only (beam.tip_distance, beam.barrel_point) -- for the
-- standby muzzle glow's position. beam.lua does not require this file, so
-- render -> beam is a leaf, not a cycle.
local beam   = require("scripts.beam")
-- Config-only dependency (see its own header), so requiring it here
-- creates no cycle. Lets the designator overlay draw its chart twin the same
-- way the sphere, the wave and the collapse already do -- see render.preview.
local mapdraw = require("scripts.mapdraw")

local render = {}

local r = C.render

-- THE VFX GENERATION STAMP. Render objects are saved; the code that made them
-- is not. So when the design changes, every object the PREVIOUS design
-- created is still in the save and still drawn, with no key the new code
-- looks at -- build() returns early on a matching style+signature, so a bag
-- missing a newly-added object would simply never grow it. BUMP THIS whenever
-- the set of objects render.build() creates changes, so a mismatched
-- generation is torn down wholesale (rendering.clear) instead of built on top
-- of. Current: 10 -- 0.27.0 moves the conduit ring onto the concrete firing
-- ring (C.firing_ring_radius), so a save's ring at the old radius must go.
local STYLE = 10

-- =============================================================================
-- Helpers
-- =============================================================================

local function set(unit_number)
  storage.render[unit_number] = storage.render[unit_number] or {}
  return storage.render[unit_number]
end

--- Destroy one keyed render object if it still exists.
-- The bag also carries two plain scalars (style, sig), so this has to check that
-- what it found is an object before calling .valid on it.
local function drop(bag, key)
  local o = bag[key]
  if type(o) == "table" or type(o) == "userdata" then
    if o.valid then o.destroy() end
  end
  bag[key] = nil
end

--- Destroy everything for a turret.
function render.clear(unit_number)
  -- The designator rings live in their own bag with their own lifetime -- they
  -- come and go with the AIM state, where everything in storage.render persists
  -- with the installation -- but they die with the turret like anything else.
  -- Without this line an installation mined mid-designation leaves four circles
  -- on the ground with nothing left alive that knows how to destroy them, which
  -- is exactly the "old lines from the capacitor are still drawing" bug that
  -- schema migration 4 exists to clean up.
  render.preview_clear(unit_number)

  local bag = storage.render[unit_number]
  if not bag then return end
  for k in pairs(bag) do drop(bag, k) end
  storage.render[unit_number] = nil
end

--- Where the standby muzzle glow sits right now. See C.barrelfx.glow -- a
--- fraction of beam.tip_distance() back from the tip, ON the barrel's current
--- bearing, computed the same way the beam origin and the charge emitters are.
-- nil if the orientation cannot be read (beam.barrel_point's own contract);
-- callers must check.
local function muzzle_glow_point(e)
  local g = C.barrelfx and C.barrelfx.glow
  if not (g and g.enabled) then return nil end
  return beam.barrel_point(e, beam.tip_distance() * g.forward_fraction, 0)
end

--- 0..1+ -- how charged this turret is. Can exceed 1 in the overcharge band.
function render.charge_fraction(rec)
  local cost = C.charge.cost_per_shot
  if cost <= 0 then return 1 end
  return pylon.available(rec) / cost
end

--- Keep the script-drawn rotating head in sync with the barrel's real
--- orientation. Called from turret.slew every tick IT runs (only while
--- aiming); outside that the head holds its last frame, as the entity does.
--
-- BY FRAME, NEVER BY .orientation. The head is a 64-frame strip of
-- pre-drawn facings (prototypes/entity.lua, header bug 2); writing the render
-- object's orientation spins one facing's bitmap instead of choosing another.
local HEAD_KEYS = {"head_shadow", "head", "head_glow"}

local function head_frame(orientation)
  local n = C.turret.head.directions
  return math.floor(orientation * n + 0.5) % n
end

function render.sync_head(rec, orientation)
  local bag = storage.render[rec.unit_number]
  if not bag then return end
  local frame = head_frame(orientation)
  for _, key in ipairs(HEAD_KEYS) do
    local o = bag[key]
    if o and type(o) ~= "number" and type(o) ~= "string" and o.valid then
      o.animation_offset = frame
    end
  end
end

-- =============================================================================
-- #67 / #78 / #79: the persistent installation VFX
-- =============================================================================

--- Which pylons this bag was drawn for. Two installations with the same four
--- sides filled are not the same picture if the entities behind them changed --
--- a bank that died and was rebuilt one tile over needs a new spur, and the old
--- one has to go rather than being left pointing at nothing.
local function signature(rec)
  local sides = {}
  for side, un in pairs(rec.pylons or {}) do sides[#sides + 1] = side .. "=" .. un end
  -- The masts count too, and they have to. A mast built after the bag was drawn
  -- would otherwise never get a light: build() returns early on a matching
  -- signature, and a signature that ignores masts matches forever.
  for un in pairs(rec.masts or {}) do sides[#sides + 1] = "m=" .. un end
  table.sort(sides)
  return table.concat(sides, ",")
end

--- 0..1 -- charge as a fraction of WHAT WAS ORDERED, not of a standard shot.
--
-- Against a standard shot a 25% order would read as a gun stuck at a quarter,
-- when it is a gun that finished early because that is what was asked of it.
-- The ring, the HUD progress bar and the charging lights all share this
-- denominator deliberately, so the three can never tell the player different
-- stories about the same shot.
function render.charge_unit(rec)
  local f = render.charge_fraction(rec)
  if f < 0 then f = 0 end
  local goal = rec.yield_target or C.charge.yield_default
  return math.min(f / math.max(goal, 0.01), 1), f >= goal
end

--- Build the ring, spurs and glow once, when all four pylons are present.
function render.build(rec)
  if not schema.valid(rec) then return end
  local e = rec.entity
  local bag = set(rec.unit_number)

  -- Already built, for THIS design and THIS set of pylons? Then leave it alone.
  local sig = signature(rec)
  if bag.bus and bag.bus.valid and bag.style == STYLE and bag.sig == sig then
    return
  end

  -- Anything else means the bag is stale: a different VFX generation, a pylon
  -- swapped underneath us, or an object that went invalid. Tear the whole thing
  -- down before rebuilding. Overwriting keys one at a time is what orphans an
  -- object -- the reference is gone but the object is still on screen, and
  -- nothing can ever destroy it again.
  render.clear(rec.unit_number)
  bag = set(rec.unit_number)
  bag.style = STYLE
  bag.sig = sig

  -- ON the concrete firing ring, so the charge readout is drawn on
  -- construction rather than floating between the banks.
  local bus_r = C.firing_ring_radius()
  local c = e.position

  -- #79: the glow, as a RING on the pad. The filled version was a white disc
  -- pasted under the turret.
  bag.glow = rendering.draw_circle{
    color = {r = 0, g = 0, b = 0, a = 0},
    radius = bus_r + 0.9,
    width = r.glow_width,
    filled = false,
    target = e,
    surface = e.surface,
    draw_on_ground = true,
  }

  -- #67: the conduit ring. One closed loop on the concrete that all four banks
  -- feed, instead of four lines drawn through the middle of the gun.
  bag.bus = rendering.draw_circle{
    color = {r = 0, g = 0, b = 0, a = 0},
    radius = bus_r,
    width = r.bus_width,
    filled = false,
    target = e,
    surface = e.surface,
    draw_on_ground = true,
  }

  -- THE SCRIPT-DRAWN ROTATING HEAD (prototypes/entity.lua's header): barrel,
  -- shadow, glow -- three objects sharing one frame, re-framed every slew tick
  -- by render.sync_head (build() only reruns on a pylon/style change). Seeded
  -- from the entity's own orientation (pcall: class-gated reads can throw on
  -- this chassis) so the STYLE-9 rebuild every old save runs does not snap
  -- the head to north while the real bearing is elsewhere.
  local hd = C.turret.head
  local ok, seed = pcall(function() return e.orientation end)
  if not (ok and type(seed) == "number") then seed = 0 end
  local function head_part(key, anim, layer)
    bag[key] = rendering.draw_animation{
      animation = anim,
      surface = e.surface,
      target = e,
      render_layer = layer,
      animation_speed = hd.frame_speed,
      animation_offset = head_frame(seed),
    }
  end
  if hd.shadow then head_part("head_shadow", N.anim.turret_head_shadow, "lower-object") end
  head_part("head", N.anim.turret_head, "object")
  if hd.glow then head_part("head_glow", N.anim.turret_head_glow, "higher-object-under") end

  for side, un in pairs(rec.pylons or {}) do
    local link = storage.pylons[un]
    local p = link and link.entity
    if p and p.valid then
      local dx, dy = p.position.x - c.x, p.position.y - c.y
      local len = math.sqrt(dx * dx + dy * dy)
      if len > 0.001 then
        local ux, uy = dx / len, dy / len

        -- A SHORT spur: bank to the nearest point on the ring. Nothing crosses
        -- the turret sprite any more.
        bag["spur_" .. side] = rendering.draw_line{
          color = {r = 0, g = 0, b = 0, a = 0},
          width = r.spur_width,
          from = {x = c.x + ux * bus_r, y = c.y + uy * bus_r},
          to = p,
          surface = e.surface,
          draw_on_ground = true,
        }

        -- Nothing is drawn across the gun: the ring and spurs carry the readout.
      end
    end
  end

  -- The masts get a spur too, drawn from the ring straight out past their
  -- cluster. Without it the four tallest objects on the pad are the only things
  -- standing on it that the conduit does not touch, and an installation reads as
  -- a gun with substations parked near it rather than as one machine.
  --
  -- Heavier than a bank spur on purpose: this is the run that carries the whole
  -- cluster, and the line weights should say which cable matters.
  for un, m in pairs(rec.masts or {}) do
    if m and m.valid then
      local dx, dy = m.position.x - c.x, m.position.y - c.y
      local len = math.sqrt(dx * dx + dy * dy)
      if len > 0.001 then
        local ux, uy = dx / len, dy / len
        bag["spur_m_" .. un] = rendering.draw_line{
          color = {r = 0, g = 0, b = 0, a = 0},
          width = r.mast_spur_width,
          from = {x = c.x + ux * bus_r, y = c.y + uy * bus_r},
          to = m,
          surface = e.surface,
          draw_on_ground = true,
        }
      end
    end
  end

  -- --- the per-bank charge glow ---------------------------------------------
  --
  -- One per bank, created ONCE and only ever repainted. Anchored to its bank,
  -- so "if an entity target of an object is destroyed the object is also
  -- destroyed" does the cleanup for a bank that gets eaten -- no per-tick
  -- create/destroy churn and nothing left glowing over a crater.
  --
  -- Reports a DIFFERENT quantity from the installation's state (which
  -- render.lights() paints onto the real N.ground_lamp entities instead):
  -- THIS bank's own fill. `visible = false` at birth since every bank is
  -- empty at rest -- the first repaint turns on whichever have something in
  -- them.
  if C.lights and C.lights.enabled and C.lights.bank_charge
     and C.lights.bank_charge.enabled then
    local function glow(key, target)
      bag[key] = rendering.draw_animation{
        animation = N.anim.bank_charge,
        surface   = e.surface,
        target    = target,
        tint      = {r = 1, g = 1, b = 1, a = 0},
        visible   = false,
        animation_speed = C.lights.bank_charge.speed,
      }
    end

    for _, un in pairs(rec.pylons or {}) do
      local link = storage.pylons[un]
      local p = link and link.entity
      if p and p.valid then glow("charge_p_" .. un, p) end
    end
  end

  -- THE STANDBY MUZZLE GLOW (this session). Its own object, its own rhythm --
  -- see C.barrelfx.glow and render.lights() below. Position is repainted every
  -- relight tick rather than fixed here: the barrel can end up pointing
  -- anywhere after a shot, and build() only reruns when the pylon/mast set
  -- changes, not when the gun rotates.
  local bfx = C.barrelfx and C.barrelfx.glow
  if bfx and bfx.enabled then
    local gp = muzzle_glow_point(e)
    if gp then
      bag.muzzle_glow = rendering.draw_light{
        sprite    = "utility/light_medium",
        surface   = e.surface,
        target    = gp,
        color     = bfx.color,
        intensity = 0,
        scale     = bfx.scale,
      }
    end
  end

  -- #106: there is no text drawn in the world any more. Status lives in the
  -- fire-control HUD (scripts/gui.lua). Words pasted over a sprite read as
  -- debug output, not as a control system -- the installation says what it is
  -- doing through the ring, the spurs, the lights and the panel.
end

-- =============================================================================
-- The status lights
--
-- The installation reports its own state in colour, so it can be read
-- peripherally instead of by opening something. See C.lights for the scheme and
-- why each state got the colour it did.
-- =============================================================================

--- Blend two colours. `t` = 0 gives `a`, 1 gives `b`.
-- UNUSED -- its only caller was the cooldown crossfade, which is
-- now a flash. Kept rather than deleted because a hue interpolator is the first
-- thing any new light behaviour reaches for, and re-deriving one is more work
-- than reading past it.
local function mix(a, b, t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return {
    r = a.r + (b.r - a.r) * t,
    g = a.g + (b.g - a.g) * t,
    b = a.b + (b.b - a.b) * t,
  }
end

--- What colour the installation is, and how bright, right now.
--
-- Returns colour, level. Level is an intensity MULTIPLIER -- the per-object
-- base_intensity scales it, so a mast is brighter than a bank in every state
-- without either of them carrying its own copy of the behaviour.
--
-- The state strings compared here are turret.BOOT/STANDBY/... verbatim. They are
-- NOT required from scripts/turret.lua, and cannot be: turret.lua requires this
-- file (it calls render.clear when an installation goes incomplete), so a
-- require back the other way is a cycle. Keeping the strings in C.lights.colour
-- under the same keys is what stops them drifting -- add a state, add a colour,
-- and a missing one falls through to dark rather than erroring.
local function behaviour(rec, tick)
  local L = C.lights
  local st = rec.state
  local since = tick - (rec.state_since or tick)

  if st == "dark" or st == "idle" or st == nil then
    return L.colour.dark, 0
  end

  if st == "boot" then
    -- Arriving. Ramps past the resting level and settles back onto it, so a cold
    -- start reads as something powering up rather than a lamp switching on.
    local t = math.min(1, since / math.max(1, C.power.boot_ticks))
    local peak = L.standby_level * L.boot_overshoot
    return L.colour.boot, peak * t
  end

  if st == "standby" then
    if L.standby_solid then return L.colour.standby, L.standby_level end
    local phase = (tick % L.standby_period) / L.standby_period
    local breath = math.sin(phase * 2 * math.pi) * L.standby_breath
    return L.colour.standby, L.standby_level + breath
  end

  if st == "aim" then
    -- READY: aligned (rec.aim_aligned, written by turret.slew) AND the ground
    -- under the shot confirmed generated (rec.terrain_ready, render.preview's
    -- coverage check) -- solid amber, its own hue, distinct from the firing
    -- red below it.
    if rec.aim_aligned and rec.terrain_ready then
      return L.colour.amber, L.aim_ready_level
    end
    -- STILL PREPARING: rotating, or the ground not yet confirmed. Yellow,
    -- flashing on a square wave -- "something is happening, wait".
    local on = (tick % L.aim_period) < (L.aim_period / 2)
    return L.colour.aim, on and L.aim_high or L.aim_low
  end

  if st == "fire" then
    if rec.discharged then
      -- THE LANCE IS LIT: held steady at flash_high, not flashed -- reads as
      -- the charge ramp's own peak rather than a strobe over the beam sustain.
      return L.colour.firing, L.flash_high
    end
    -- SPOOLING. Brightness IS the charge: floor to ceiling, linear in how far
    -- through the ORDER the banks are, with a shallow flicker that grows with
    -- it so a bank at a gigajoule doesn't sit there looking calm.
    local unit = render.charge_unit(rec)
    local level = L.charge_floor + (L.charge_ceiling - L.charge_floor) * unit
    local phase = (tick % L.charge_flicker_period) / L.charge_flicker_period
    level = level + math.sin(phase * 2 * math.pi) * L.charge_flicker * unit
    return L.colour.charging, level
  end

  if st == "cooldown" then
    -- VENTING: flashing orange, the same square wave as the firing flash so
    -- it unmistakably reads as a state (a smooth crossfade back to standby
    -- reads as the lamp settling, not as a third state) -- but at roughly
    -- half the rate and well under 1.0, so firing SNAPS bright and venting
    -- PULSES calmer, never confused with each other.
    local on = (tick % L.vent_flash_period) < (L.vent_flash_period / 2)
    return L.colour.venting, on and L.vent_high or L.vent_low
  end

  return L.colour.standby, L.standby_level
end

--- the brownout multiplier right now -- C.lights.brownout.level for
--- its first `ticks` after the strike, 1 otherwise. Keyed on rec.discharged_at,
--- so it needs no state of its own and a save mid-dip simply finishes it.
local function brownout_mult(rec, tick)
  local b = C.lights.brownout
  if not (b and b.enabled and rec.lance and rec.discharged_at) then return 1 end
  local t = tick - rec.discharged_at
  if t >= 0 and t < b.ticks then return b.level end
  return 1
end

--- Repaint the lights and the conduit on the dip's two edges. Called every
--- tick from scripts/turret.lua AFTER fire_tick, so the strike tick itself
--- (t = 0) goes dark rather than the one after it.
function render.brownout_step(rec)
  local b = C.lights and C.lights.brownout
  if not (b and b.enabled and rec.lance and rec.discharged_at) then return end
  local t = game.tick - rec.discharged_at
  if t == 0 or t == b.ticks then
    render.lights(rec)
    render.update(rec)
  end
end

--- Repaint every light on one installation. Called on a fixed interval from the
--- per-tick loop in scripts/turret.lua, NOT on the bucket.
--
-- The bucket is 30 ticks. An 18-tick flash sampled every 30 ticks aliases into a
-- stutter, and a 17-second ramp sampled at 2 Hz steps visibly. Six ticks is
-- 10 Hz, which is smooth for both and is still twenty attribute writes per
-- installation per tenth of a second -- nothing, next to the entity searches the
-- bucket already does.
function render.lights(rec)
  if not (C.lights and C.lights.enabled) then return end
  local bag = storage.render[rec.unit_number]
  if not bag then return end

  local colour, level = behaviour(rec, game.tick)
  if level < 0 then level = 0 end
  local dip = brownout_mult(rec, game.tick)
  level = level * dip

  -- THE REAL GROUND LAMPS ARE THE STATUS LIGHT: `level` is baked straight into
  -- the RGB sent to each N.ground_lamp entity's own .color (LuaEntity.color
  -- names "lamp" as a valid target). Hue and baked-in brightness are the
  -- whole signal -- no runtime-writable radius or intensity multiplier exists
  -- on a lamp, so the fixture stays the size prototypes/entity/lamp.lua bakes
  -- in. FOUND BY POSITION, NOT TRACKED: these are deliberately absent from
  -- schema/storage (lib/names.lua's note on N.ground_lamp).
  if C.lamp and C.lamp.enabled then
    local e = rec.entity
    if e and e.valid then
      local lr = colour.r * level
      local lg = colour.g * level
      local lb = colour.b * level
      if lr > 1 then lr = 1 elseif lr < 0 then lr = 0 end
      if lg > 1 then lg = 1 elseif lg < 0 then lg = 0 end
      if lb > 1 then lb = 1 elseif lb < 0 then lb = 0 end
      local lamps = e.surface.find_entities_filtered{
        name = N.ground_lamp, position = e.position, radius = C.lamp_reach(),
      }
      for _, l in pairs(lamps) do
        if l.valid then l.color = {r = lr, g = lg, b = lb, a = 1} end
      end
    end
  end

  -- THE STANDBY MUZZLE GLOW (this session). Its own rhythm, deliberately NOT
  -- C.lights.behaviour() above -- see C.barrelfx.glow's header. Only relevant
  -- in STANDBY; every other state leaves it at rest rather than fighting the
  -- status lights for attention.
  local bfx = C.barrelfx and C.barrelfx.glow
  if bfx and bfx.enabled then
    local o = bag.muzzle_glow
    if o and type(o) ~= "number" and type(o) ~= "string" and o.valid then
      local e = rec.entity
      if e and e.valid and rec.state == "standby" then
        local gp = muzzle_glow_point(e)
        if gp then o.target = gp end
        local phase = (game.tick % bfx.period) / bfx.period
        local w = 0.5 - 0.5 * math.cos(phase * 2 * math.pi)
        o.color = bfx.color
        o.intensity = bfx.level_low + (bfx.level_high - bfx.level_low) * w
      else
        o.intensity = 0
      end
    end
  end

  -- THE PER-BANK CHARGE GLOW: alpha from each bank's OWN fill, hue from the
  -- state (the lamps' behaviour table). A bank with no glow object is skipped.
  local bc = C.lights.bank_charge
  if bc and bc.enabled then
    for _, un in pairs(rec.pylons or {}) do
      local o = bag["charge_p_" .. un]
      if o and type(o) ~= "number" and type(o) ~= "string" and o.valid then
        local link = storage.pylons[un]
        local p = link and link.entity
        local fill = 0
        if p and p.valid then
          -- THE PROTOTYPE BUFFER, NOT electric_buffer_size: the live buffer
          -- is the ramp ceiling turret.power_tick rewrites every tick, so
          -- energy/electric_buffer_size is pinned near 1.0 for the whole
          -- charge. The bank's own tier maximum is the fixed denominator the
          -- fill is actually a fraction of.
          local size = pylon.max_buffer_of(p) or 0
          if size > 0 then fill = p.energy / size end
          if fill > 1 then fill = 1 elseif fill < 0 then fill = 0 end
        end
        if fill < bc.floor then
          o.visible = false
        else
          o.visible = true
          -- THE FLICKER (this session): asked for explicitly as NOT a smart
          -- light -- no state edges, plain math.random noise scaled by the
          -- bank's own fill, so an empty bank stays dark instead of jittering
          -- for no reason. See C.lights.bank_charge.flicker_amount.
          local jit = (math.random() * 2 - 1) * (bc.flicker_amount or 0) * fill
          local a = fill + jit
          if a < 0 then a = 0 elseif a > 1 then a = 1 end
          o.color = {r = colour.r, g = colour.g, b = colour.b,
                     a = a * bc.max_alpha * dip}
        end
      end
    end
  end
end

-- =============================================================================
-- The "incomplete installation" notice.
--
-- Kept OUTSIDE the render bag on purpose: the bag is destroyed whenever the
-- installation is not ready, which is exactly when this needs to be on screen.
-- =============================================================================

-- #106: an incomplete installation is now REPORTED, not labelled in the world.
-- The count is recorded on the record and the HUD renders it, so the same
-- information arrives as UI instead of as text floating over a sprite.
function render.incomplete(rec, have)
  rec.short_banks = have
end

function render.incomplete_clear(unit_number)
  local rec = storage.turrets and storage.turrets[unit_number]
  if rec then rec.short_banks = nil end
end

--- Repaint everything for the current charge. Called on the bucket tick.
function render.update(rec)
  local bag = storage.render[rec.unit_number]
  if not bag then return end

  -- THE RING IS PROGRESS TOWARD THE ORDER, not toward a standard shot -- see
  -- render.charge_unit. `over` is "fully charged to what was ordered": the glow
  -- goes white there, at 25% as readily as at 150%. What differs is how long it
  -- took to get there.
  local unit, over = render.charge_unit(rec)
  -- the brownout dips the conduit with the lights.
  local dip = brownout_mult(rec, game.tick)

  if bag.glow and bag.glow.valid then
    bag.glow.color = over
      and {r = 0.95, g = 0.95, b = 1.0, a = r.glow_max_alpha * dip}
      or  {r = 0.45, g = 0.70, b = 1.0, a = r.glow_max_alpha * unit * 0.8 * dip}
  end

  -- The ring IS the charge readout. A loop that fills with light is legible
  -- across the base; a number floating over the barrel is not.
  if bag.bus and bag.bus.valid then
    bag.bus.color = {
      r = 0.20 + 0.65 * unit,
      g = 0.28 + 0.45 * unit,
      b = 0.42 + 0.40 * unit,
      a = (0.45 + 0.45 * unit) * dip,
    }
  end

  for side in pairs(rec.pylons or {}) do
    local spur = bag["spur_" .. side]
    if spur and spur.valid then
      spur.color = {r = 0.25, g = 0.30, b = 0.40, a = (0.35 + 0.35 * unit) * dip}
    end
  end

  -- The mast runs brighten harder than the bank spurs, on the same charge. They
  -- are the trunk; a trunk that lit at the same rate as a branch would be doing
  -- nothing that the branch was not already saying.
  for un in pairs(rec.masts or {}) do
    local spur = bag["spur_m_" .. un]
    if spur and spur.valid then
      spur.color = {r = 0.30, g = 0.38, b = 0.52, a = (0.45 + 0.45 * unit) * dip}
    end
  end
end

-- =============================================================================
-- THE DESIGNATOR OVERLAY
--
-- Four rings on the ground at the aim point, at the real radii of the four damage
-- bands of the CONVERGED shot, redrawn whenever the aim point, the dial or the
-- number of lances on it changes. It is the answer to "how do I not delete my
-- own base with a megaton", and it answers it by showing rather than by
-- forbidding -- see the note on C.blast.rings.preview.
--
-- REBUILT ON A SIGNATURE, NOT EVERY TICK. Eight render objects per group per
-- tick would be absurd for a picture that only changes when the player moves
-- the aim point or turns the dial, so the inputs are hashed into one string and
-- the whole thing is rebuilt only when that string moves. The common case -- a
-- battery sitting in AIM while the player thinks -- costs one string compare.
-- =============================================================================

--- Tear down a turret's preview rings.
function render.preview_clear(unit_number)
  storage.preview = storage.preview or {}
  local bag = storage.preview[unit_number]
  if not bag then return end
  for _, o in pairs(bag.objs or {}) do
    if o and o.valid then o.destroy() end
  end
  storage.preview[unit_number] = nil
end

--- Keep a render object if mapdraw.circle actually returned one. World and
--- chart copies both come through here, so a call that draws only one (chart
--- disabled, or radius under the map's floor) does not leave a hole in `objs`
--- for preview_clear to trip on.
local function keep(objs, o)
  if o then objs[#objs + 1] = o end
end

--- Sampled fraction of a circle's circumference that sits on generated ground.
--- Not an exhaustive scan -- the full disc is thousands of chunks at full
--- yield -- just `n` points checked with is_chunk_generated: the same
--- question scripts/front.lua answers for real before trusting a query (see
--- its acquire()), but the cheap, approximate version for a picture rather
--- than for damage.
local function coverage(surface, cx, cy, r, n)
  if n <= 0 or r <= 0 then return 1 end
  local hit = 0
  for i = 0, n - 1 do
    local a = (2 * math.pi * i) / n
    local ccx = math.floor((cx + math.cos(a) * r) / 32)
    local ccy = math.floor((cy + math.sin(a) * r) / 32)
    if surface.is_chunk_generated({ccx, ccy}) then hit = hit + 1 end
  end
  return hit / n
end

--- Draw (or refresh) the blast preview for an installation that is aiming.
-- Silently clears and returns when it should not be showing, so the caller can
-- run it unconditionally every tick and let this decide.
--
-- `aiming` IS PASSED IN RATHER THAN TESTED HERE: turret.lua requires this
-- file, so reading turret.AIM back would be a require cycle, and comparing
-- against a bare "aim" string would silently break if the constant were ever
-- renamed. The caller has the constant in scope; let it do the comparison.
--
-- DRAWN THROUGH mapdraw, so it appears on the chart too -- a player aiming a
-- long-range strike is usually standing at the gun, not the target, so the
-- map is the one place a 2000-tile ring is ever actually going to be seen.
function render.preview(rec, aiming)
  storage.preview = storage.preview or {}
  local un = rec.unit_number

  local e = rec.entity
  if not (aiming and e and e.valid and rec.designated) then
    render.preview_clear(un)
    return
  end

  local rings = C.blast.rings
  if not (rings.enabled and rings.preview) then
    -- No coverage signal to gate on -- the status light (render.lua's own
    -- behaviour()) should not be stuck "not ready" forever because a config
    -- turned this readout off.
    rec.terrain_ready = true
    return
  end
  local p = rings.preview
  local d = rec.designated

  -- CRITICAL: the crater is the converged group's, not this gun's, and exactly
  -- one member of the group draws it.
  local frac, lances, crew, order = schema.group(rec, d, rec.state)
  if crew[1] ~= rec then
    render.preview_clear(un)
    return
  end
  local radius = C.yield.radius_for_fraction(order)

  -- The tick bucket re-samples coverage every ~3s even when nothing else about
  -- the order changes: generation keeps running in the background the whole
  -- time the player is in AIM, and the readout should catch up to that
  -- instead of freezing on whatever it read when the aim point was picked.
  local bucket = math.floor(game.tick / 180)
  local sig = string.format("%d:%d:%d:%d:%d",
                            math.floor(d.x), math.floor(d.y),
                            math.floor(order * 1000), lances, bucket)

  local bag = storage.preview[un]
  if bag and bag.sig == sig then return end
  render.preview_clear(un)

  -- IS ANYTHING OF OURS INSIDE IT. `limit = 1` makes this an existence test the
  -- engine can abandon on the first hit rather than a census, which is what keeps
  -- it affordable at a 2000 tile radius -- and it only runs when the signature
  -- moved, never on the idle tick.
  local mine = e.surface.count_entities_filtered{
    position = d, radius = radius, force = e.force, limit = 1,
  } > 0

  -- ONLY THE OUTER BAND is coverage-checked. It is the one most likely to reach
  -- past what C.blast.rings.pregen already guarantees (capped at 512 tiles) --
  -- the inner bands are covered by that disc in nearly every real shot, and
  -- sampling all four for one signature change buys nothing the outer band does
  -- not already say. A READOUT, not a lock -- same rule as `danger` above and
  -- the dynamic standoff in turret.designate.
  local covered = coverage(e.surface, d.x, d.y, radius, p.coverage_samples or 0)
  local warn = covered < (p.coverage_warn_threshold or 0)
  -- The status light's map-generation gate, read by behaviour().
  -- MUST reach every member: they share one crater and only this one sampled it.
  for _, member in ipairs(crew) do member.terrain_ready = not warn end

  local objs = {}
  for i, band in ipairs(rings.bands) do
    local outer = (i >= #rings.bands - 1)
    local colour
    if mine then
      colour = p.danger
    elseif outer and warn and p.unconfirmed then
      colour = p.unconfirmed
    else
      colour = p.colours[i] or p.danger
    end
    local world, chart = mapdraw.circle{
      color   = colour,
      radius  = band.to * radius,
      width   = outer and p.width_outer or p.width,
      filled  = false,
      target  = d,
      surface = e.surface,
      -- Everyone on the firing force, not just the player who designated: a
      -- megaton landing near somebody else's half of the base is their business
      -- too, and they cannot ask for a preview they do not know exists.
      -- Forwarded to the chart copy too (mapdraw.lua, 0.21.0) -- otherwise this
      -- would leak a shot's full kill radius to every other force on the chart
      -- before it was ever fired.
      forces  = {e.force},
    }
    keep(objs, world)
    keep(objs, chart)
  end

  storage.preview[un] = {sig = sig, objs = objs, radius = radius, danger = mine}
end

-- =============================================================================
-- #28 / #80: selection-only overlays
-- =============================================================================

--- Range rings and a charge readout, drawn only while a player has the turret
--- selected. Disproportionately useful when placing a line of them.
function render.select(player, entity)
  local key = player.index
  storage.selection = storage.selection or {}
  render.deselect(player)

  if not (entity and entity.valid and entity.name == N.turret) then return end

  local rec = storage.turrets[entity.unit_number]
  local objs = {}

  -- #28: auto-target range (native attack, permanently neutered -- see
  -- prototypes/entity.lua -- kept as a decorative inner ring only), and the
  -- REAL designation reach, the same number the remote checks.
  local auto = C.gun.range
  local manual = C.reach()
  objs[#objs + 1] = rendering.draw_circle{
    color = {r = 0.9, g = 0.5, b = 0.1, a = 0.5},
    radius = auto, width = 3, filled = false,
    target = entity, surface = entity.surface, players = {player.index},
  }
  objs[#objs + 1] = rendering.draw_circle{
    color = {r = 0.4, g = 0.6, b = 1.0, a = 0.35},
    radius = manual, width = 2, filled = false,
    target = entity, surface = entity.surface, players = {player.index},
  }
  -- The minimum-range dead zone -- artillery's real weakness, and worth seeing.
  objs[#objs + 1] = rendering.draw_circle{
    color = {r = 1.0, g = 0.2, b = 0.2, a = 0.4},
    radius = C.gun.min_range, width = 2, filled = false,
    target = entity, surface = entity.surface, players = {player.index},
  }
  -- #61: the exclusion radius, so the player can see where the next one may go.
  if C.turret.exclusion_radius > 0 then
    objs[#objs + 1] = rendering.draw_circle{
      color = {r = 0.6, g = 0.6, b = 0.6, a = 0.25},
      radius = C.turret.exclusion_radius, width = 1, filled = false,
      target = entity, surface = entity.surface, players = {player.index},
    }
  end

  -- The charge readout is no longer drawn here. It is a persistent object under
  -- the installation (render.build), so it is legible without selecting the gun
  -- and it is not pinned over the barrel.

  storage.selection[key] = objs
end

function render.deselect(player)
  storage.selection = storage.selection or {}
  local objs = storage.selection[player.index]
  if not objs then return end
  for _, o in pairs(objs) do
    if o and o.valid then o.destroy() end
  end
  storage.selection[player.index] = nil
end

-- =============================================================================
-- Events
-- =============================================================================

events.on(defines.events.on_selected_entity_changed, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  render.select(player, player.selected)
end)

events.on(defines.events.on_player_left_game, function(event)
  local player = game.get_player(event.player_index)
  if player then render.deselect(player) end
end)

return render
