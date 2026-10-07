-- config.lua: tuning surface. Loaded by both settings and data stages, so side-effect free.

local N = require("lib.names")

local C = {}

C.turret = {
  tile_size          = 9,
  collision_inset    = 0.1,
  max_health         = 20000,
  sprite_scale       = 1.5,
  base_sprite_scale  = 0.5,
  vertical_extension = 12,
  attack_range    = 0.5,
  attack_cooldown = 60,
  tint = {r = 0.55, g = 0.50, b = 0.46, a = 1.0},
  head = {
    directions  = 64,
    line_length = 8,
    frame_speed = 1e-9,
    shadow      = true,
    glow        = true,
  },
  cannon_pivot_up    = 0.9722,
  tower_lift         = 0.7,
  rotation_speed     = 0.0004,
  slew_speed         = 0.0004,
  aim_tolerance      = 0.01,
  confirm_tolerance  = 8.0,

  -- How long a committed battery order waits for its slowest barrel before it
  -- fires whatever IS on target (scripts/alpha.lua). A full traverse is a few
  -- seconds; this is the backstop for a barrel that never arrives, not a
  -- deadline the ordinary case meets.
  alpha_hold_ticks   = 60 * 30,
  item_stack_size    = 5,
  inventory_size     = 1,
  ammo_stack_limit   = 150,
  charge_sound_volume = 0.75,
  exclusion_radius = 42,
  light = {intensity = 0.6, size = 18, color = {r = 1.0, g = 0.85, b = 0.6}},
  chart_scale = 1.2,

  resistances = {
    {type = "fire",      decrease = 15, percent = 50},
    {type = "physical",  decrease = 15, percent = 30},
    {type = "impact",    decrease = 50, percent = 50},
    {type = "explosion", decrease = 15, percent = 30},
    {type = "acid",      decrease = 3,  percent = 20},
  },
}

function C.selection_box()
  local h = C.turret.tile_size / 2
  return {{-h, -h}, {h, h}}
end

function C.collision_box()
  local h = C.turret.tile_size / 2 - C.turret.collision_inset
  return {{-h, -h}, {h, h}}
end

--- Sprite shift multiplier; shift does not scale automatically with scale.
function C.shift_ratio()
  return C.turret.sprite_scale / C.turret.base_sprite_scale
end

--- Projectile creation distance, scaled with barrel.
function C.muzzle_distance()
  return C.gun.projectile_creation_distance * C.shift_ratio()
end

function C.scale_muzzle(list)
  local r, out = C.shift_ratio(), {}
  for i, entry in ipairs(list) do
    out[i] = {entry[1], {entry[2][1] * r, entry[2][2] * r}}
  end
  return out
end

function C.cannon_base_shift()
  return {0.0, 0.0, C.turret.cannon_pivot_up * C.shift_ratio() + C.turret.tower_lift}
end

--- Pylon slots: {key, ox, oy, dir}. Cached after first call.
local slot_defs_cache
function C.pylon_slot_defs()
  if slot_defs_cache then return slot_defs_cache end

  local out = {}
  local step = C.pylon.slot_spacing or C.pylon.tile_size
  local n = C.pylon.per_side

  if C.pylon.layout == "corners" then
    local side_n = math.ceil(math.sqrt(n + 1))
    if side_n % 2 == 0 or side_n * side_n ~= n + 1 then
      error("oppenheimer: C.pylon.per_side (" .. n .. ") + 1 must be an odd "
            .. "perfect square -- corner cluster reserves centre cell for mast")
    end
    local mid = (side_n + 1) / 2
    local co = C.pylon.corner_offset
    local half = (side_n - 1) * step / 2
    for _, corner in ipairs({
      {key = "nw", cx = -co, cy = -co},
      {key = "ne", cx =  co, cy = -co},
      {key = "sw", cx = -co, cy =  co},
      {key = "se", cx =  co, cy =  co},
    }) do
      local inv = 1 / math.sqrt(2)
      local dx = (corner.cx < 0) and -inv or inv
      local dy = (corner.cy < 0) and -inv or inv
      local i = 0
      for row = 1, side_n do
        for col = 1, side_n do
          if row ~= mid or col ~= mid then
            i = i + 1
            out[#out + 1] = {
              key = corner.key .. "-" .. i,
              side = corner.key,
              ox = corner.cx - half + (col - 1) * step,
              oy = corner.cy - half + (row - 1) * step,
              dir = {dx, dy},
            }
          end
        end
      end
    end
  else
    local span = (n - 1) * step
    local d = C.pylon_offset()
    for _, side in ipairs({"north", "east", "south", "west"}) do
      local v = C.pylon.sides[side]
      local ax, ay = -v[2], v[1]
      for i = 1, n do
        local t = -span / 2 + (i - 1) * step
        out[#out + 1] = {
          key = side .. "-" .. i,
          side = side,
          ox = v[1] * d + ax * t,
          oy = v[2] * d + ay * t,
          dir = {v[1], v[2]},
        }
      end
    end
  end

  slot_defs_cache = out
  return out
end

--- Conduit ring radius; mean gun-to-bank distance.
function C.pylon_bus_radius()
  local defs = C.pylon_slot_defs()
  local total, n = 0, 0
  for _, def in ipairs(defs) do
    total = total + math.sqrt(def.ox * def.ox + def.oy * def.oy)
    n = n + 1
  end
  if n == 0 then return C.pylon_offset() end
  return total / n
end

--- Distance from the turret centre to the outermost bank edge, in tiles (axis-aligned). Foundation, margin and the auto-ghost pass derive from it.
function C.pylon_extent()
  local far = 0
  for _, def in ipairs(C.pylon_slot_defs()) do
    far = math.max(far, math.abs(def.ox), math.abs(def.oy))
  end
  return far + C.pylon.tile_size / 2
end

--- RADIAL reach from a turret centre to the furthest bank, plus tolerance.
-- Not C.pylon_extent(): that is an axis-aligned half-width and a search `radius` is a circle. The outermost bank is at axis 15.5 but radial 19.8, so an extent-sized search never finds the turret and one bank per cluster never links.
function C.pylon_link_radius()
  local far = 0
  for _, def in ipairs(C.pylon_slot_defs()) do
    local d = math.sqrt(def.ox * def.ox + def.oy * def.oy)
    if d > far then far = d end
  end
  return far + C.pylon.tile_size / 2 + C.pylon.link_tolerance
end

--- Substation distance from the turret: the mast stands in each cluster's reserved centre cell, so this is corner_offset.
function C.substation_offset()
  return C.pylon.corner_offset
end

--- Supply reach for a mast to cover its whole cluster. supply_area_distance is a radius but the area is a square, so this is a Chebyshev reach: half the cluster span plus a bank's half-width.
function C.substation_supply_distance()
  local side_n = math.ceil(math.sqrt(C.pylon.per_side + 1))
  local half_span = (side_n - 1) * C.pylon.slot_spacing / 2
  return half_span + C.pylon.tile_size / 2
end

local sub_slots_cache
function C.substation_slot_defs()
  if sub_slots_cache then return sub_slots_cache end
  local d = C.substation_offset()
  local inv = 1 / math.sqrt(2)
  local out = {}
  for _, c in ipairs({
    {key = "nw", sx = -1, sy = -1},
    {key = "ne", sx =  1, sy = -1},
    {key = "sw", sx = -1, sy =  1},
    {key = "se", sx =  1, sy =  1},
  }) do
    out[#out + 1] = {
      key = c.key, ox = c.sx * d, oy = c.sy * d,
      dir = {c.sx * inv, c.sy * inv},
    }
  end
  sub_slots_cache = out
  return out
end

--- Wire distance that reaches exactly the neighbouring substation: chains the ring of four from one drop and no further.
function C.substation_wire_distance()
  return 2 * C.substation_offset() + C.substation.wire_slack
end

--- Radial reach from a turret centre to a mast, plus tolerance (masts stand further out than banks).
function C.substation_link_radius()
  return C.substation_offset() * math.sqrt(2)
         + C.substation.tile_size / 2 + C.substation.link_tolerance
end

--- Half-width of the whole installation, banks and masts. The pad derives from this so masts do not stand on bare ground.
-- corners of their own foundation.
function C.installation_extent()
  local banks = C.pylon_extent()
  if not (C.substation and C.substation.enabled) then return banks end
  return math.max(banks, C.substation_offset() + C.substation.tile_size / 2)
end

-- Lamp ART rect in tiles, accounting for sprite scale and shift.
function C.pylon_art_rect(ox, oy)
  local a = C.pylon.art
  local s = C.pylon.sprite_scale / 32
  local hw, hh = a.width * s / 2, a.height * s / 2
  local cy = oy + a.shift_px[2] * (C.pylon.sprite_scale / 0.5) / 32
  local cx = ox + a.shift_px[1] * (C.pylon.sprite_scale / 0.5) / 32
  return {left = cx - hw, right = cx + hw, top = cy - hh, bottom = cy + hh}
end

-- 24 lamp slots: row groups by distance from centre.
local LAMP_DEFS = {
    {key = "north-1", side = "north", row = 9, ox = 0, oy = -9},
    {key = "south-1", side = "south", row = 9, ox = 0, oy = 9},
    {key = "east-1", side = "east", row = 9, ox = 9, oy = -1},
    {key = "west-1", side = "west", row = 10, ox = -10, oy = -1},
    {key = "south-2", side = "south", row = 10, ox = -5, oy = 9},
    {key = "north-2", side = "north", row = 10, ox = 5, oy = -9},
    {key = "south-3", side = "south", row = 10, ox = 5, oy = 9},
    {key = "east-2", side = "east", row = 10, ox = 9, oy = 5},
    {key = "west-2", side = "west", row = 11, ox = -10, oy = 5},
    {key = "north-3", side = "north", row = 11, ox = -6, oy = -9},
    {key = "east-3", side = "east", row = 11, ox = 9, oy = -6},
    {key = "west-3", side = "west", row = 12, ox = -10, oy = -6},
    {key = "west-4", side = "west", row = 16, ox = -16, oy = -1},
    {key = "north-4", side = "north", row = 16, ox = 0, oy = -16},
    {key = "south-4", side = "south", row = 16, ox = 0, oy = 16},
    {key = "east-4", side = "east", row = 16, ox = 16, oy = -1},
    {key = "west-5", side = "west", row = 17, ox = -16, oy = -6},
    {key = "west-6", side = "west", row = 17, ox = -16, oy = 5},
    {key = "north-5", side = "north", row = 17, ox = -6, oy = -16},
    {key = "south-5", side = "south", row = 17, ox = -5, oy = 16},
    {key = "north-6", side = "north", row = 17, ox = 5, oy = -16},
    {key = "south-6", side = "south", row = 17, ox = 5, oy = 16},
    {key = "east-5", side = "east", row = 17, ox = 16, oy = -6},
    {key = "east-6", side = "east", row = 17, ox = 16, oy = 5},
}

local lamp_slots_cache
function C.lamp_slot_defs()
  if lamp_slots_cache then return lamp_slots_cache end
  local out = {}
  if not (C.lamp and C.lamp.enabled) then
    lamp_slots_cache = out
    return out
  end
  for _, d in ipairs(LAMP_DEFS) do
    out[#out + 1] = {key = d.key, side = d.side, row = d.row, ox = d.ox, oy = d.oy}
  end

  local keep = C.lamp.art_half + C.lamp.clearance
  for _, l in ipairs(out) do
    for _, def in ipairs(C.pylon_slot_defs()) do
      local r = C.pylon_art_rect(def.ox, def.oy)
      if l.ox + keep > r.left and l.ox - keep < r.right
         and l.oy + keep > r.top and l.oy - keep < r.bottom then
        error("oppenheimer: lamp slot " .. l.key .. " at (" .. l.ox .. ", " .. l.oy
              .. ") is under the art of bank " .. def.key
              .. " -- move C.lamp.lane_gap or the lane, not the check")
      end
    end
  end

  lamp_slots_cache = out
  return out
end

--- Radial reach from the gun to the furthest lamp, plus slack: render.lights searches this far.
function C.lamp_reach()
  local far = 0
  for _, d in ipairs(C.lamp_slot_defs()) do
    far = math.max(far, math.sqrt(d.ox * d.ox + d.oy * d.oy))
  end
  return far + (C.lamp.link_tolerance or 1)
end

--- Outward direction of a slot by key (hash lookup; the asymmetric drain calls it every tick).
local slot_dir_cache
function C.pylon_slot_dir(key)
  if not slot_dir_cache then
    slot_dir_cache = {}
    for _, def in ipairs(C.pylon_slot_defs()) do
      slot_dir_cache[def.key] = def.dir
    end
  end
  return slot_dir_cache[key]
end

--- Distance from turret centre to a pylon centre.
function C.pylon_offset()
  return C.turret.tile_size / 2 + C.pylon.clearance
end

--- Recoil offsets are in tiles, so they scale with the barrel.
function C.scale_recoil(list)
  local r, out = C.shift_ratio(), {}
  for i, v in ipairs(list) do
    out[i] = {v[1] * r, v[2] * r, v[3] * r}
  end
  return out
end

-- Gun / shell
C.gun = {
  stack_size = 1,      -- a gun item is structurally stack-1; here so rule 1
                       -- has no exceptions to remember
  -- Native attack range: decorative, never fires, and not the designation reach (C.reach). Overwritten by the startup setting.
  range     = 1200.0,

  -- Designation reach in tiles, for every installation from the start (C.reach). MUST clear the widest crater's standoff (saturation.max_radius x blast_clearance); asserted at the bottom of this file.
  reach_max_tiles = 10000,

  -- Hardware dead zone. It cannot be the self-safety interlock: blast radius runs from 30 tiles at 1% to 2000 at 150%, so no single minimum fits.
  -- The real check is dynamic, in turret.designate, against the radius of the selected shot, and it refuses an order with a reason the overlay shows. Never gate on who may command the gun.
  min_range = 2 * 32,

  -- Required standoff as a multiple of the shot's blast radius (10% clear air past your own crater).
  blast_clearance = 1.10,
  cooldown  = 200,     -- ticks between shots. Lower = faster.
  -- Muzzle shake: short, so it stays distinct from the detonation shake.
  recoil_shake = {
    duration      = 20,
    strength      = 4,
    full_distance = 30,
    max_distance  = 200,
  },
  -- The beam's source_offset from vanilla laser-turret (base turrets.lua: {0, -1.31439}); C.muzzle_distance() scales it by shift_ratio().
  projectile_creation_distance = 1.31439,
}

C.shell = {
  physical          = 1000,
  explosion         = 1000,
  blast_radius      = 4.0,
  stack_size        = 1,
  weight            = 100 * 1000,   -- 100 kg
  starting_speed    = 1,            -- #45: rocket-assisted shells raise this
}

-- Pylons (accumulator-derived banks; the gun itself has no energy_source)
C.pylon = {
  -- Eight banks to operate, thirty-two for the top of the selector. `count` is the gate: below it the installation does nothing. `max_count` is the full build.
  -- The gate is the buffer, not the inflow: a bank holds at most max_shot x buffer_headroom / max_count (22.5 GJ at 32 banks), so the yield ceiling is linear in the bank count (8 banks = 25% of the dial, 16 = 50%, 24 = 75%, 32 = 100% at 80% fill).
  -- Ordering more than the banks can carry stalls the charge, and a stalled round lands short.
  count      = 8,
  max_count  = 32,
  per_side   = 8,   -- per CLUSTER under "corners": a 3x3 block minus its own
                     -- centre cell, which the cluster's mast stands in
  -- Gap between the turret EDGE and a bank CENTRE; the ring radius is the half-width (4.5) plus this (11.5 gives a ring of 16 and a 35x35 installation around the 9x9 gun). The foundation, pad margin and auto-ghost placement derive from it.
  clearance  = 11.5,

  -- Layout. 'corners' (shipped): four clusters of banks, one per corner, gun alone in the middle, leaving the four cardinal approaches clear where the beam goes. 'sides': four straight rows parallel to the edges (kept, unused).
  layout = "corners",

  -- 'corners': distance from the turret centre to a cluster centre on each axis. 14 with 3x3 clusters at slot_spacing 4 puts bank rows at 10, 14 and 18; the cluster's centre cell holds the mast.
  corner_offset = 14,

  -- Gap between bank centres (within a cluster for 'corners', along a row for 'sides').
  slot_spacing = 4,
  -- The four sides as outward unit vectors; slot positions are generated from these plus per_side (C.pylon_slot_defs).
  sides      = {
    north = { 0, -1},
    east  = { 1,  0},
    south = { 0,  1},
    west  = {-1,  0},
  },

  tile_size    = 3,      -- each pylon's own footprint
  sprite_scale = 1.0,    -- base accumulator art is authored at 0.5; 2x here
  -- The main art layer at its authored 0.5 (base accumulator.png). prototypes/entity/pylon.lua draws from it and C.pylon_art_rect clears the lamps against it.
  art = {width = 130, height = 189, shift_px = {0, -11}},

  -- The standard bank, sized to the shot: max_shot (C.power.max_shot) buffered across max_count banks with headroom.
  -- Derived (C.pylon_buffer) and overwritten at the bottom of this file; the string documents intent, and on any disagreement trust the derivation.
  buffer_capacity   = "78125kJ",
  -- input_flow_limit is derived (C.pylon_input) in the prototype: exactly a sixteenth of the installation's draw.


  -- Exclusive banks: 0 means the network can never draw energy back out of a pylon, so a brownout cannot borrow the gun's charge. scripts/pylon.lua writes LuaEntity.energy directly, which is not subject to either flow limit.
  output_flow_limit = "0W",
  max_health        = 800,

  -- How far a pylon may sit from its slot and still link (a roughly placed pylon should link).
  link_tolerance = 2.5,

  -- Placing the turret places bank ghosts.
  auto_ghost = true,

  -- How strongly the bank facing the target is favoured when draining: 0 = even, 1 = the far bank barely contributes.
  drain_bias = 0.55,
}

-- Masts: four substations. They give the pad a vertical silhouette, cover each cluster's banks from its centre, chain to each other so the installation takes one power drop, and carry the status lights (C.lights).
C.substation = {
  enabled = true,

  -- 3x3: the footprint follows the art (drawn at 1.0 against the vanilla 2x2 at 0.5).
  tile_size    = 3,
  sprite_scale = 1.0,
  base_sprite_scale = 0.5,   -- what the base substation art was authored at

  -- Reach from a mast to its own cluster: a RADIUS, but the area is a SQUARE (Chebyshev; 3.5 gives 7x7). Derived (C.substation_supply_distance) and overwritten at the bottom of this file.
  supply_area_distance = 5.5,

  -- Slack on top of exactly reaching the neighbouring mast (C.substation_wire_distance), so a mast nudged by the link tolerance still closes the ring.
  wire_slack = 1.5,

  max_health = 600,
  stack_size = 20,

  -- Placing the turret places mast ghosts alongside the bank ghosts.
  auto_ghost = true,

  -- How far a mast may sit from its slot and still count for the status lights.
  link_tolerance = 3.0,
}

-- Charge cycle
C.charge = {
  -- Energy pulled from the banks per shot. Derived from the standby draw, the charge window and overcharge_max, and overwritten at the bottom of this file; the value here documents intent only.
  cost_per_shot = 453 * 1000000,

  -- How completely the banks must meet the order for the shot to count as delivered; below it the round is announced as stalled and lands short.
  -- It also decides tier snapping (scripts/impact.lua): a shot that did not stall detonates at the selected yield, so a 99.8% shot cannot warn about nothing while detonating a tier down.
  stall_fraction = 0.95,

  -- Charge-scaled yield. The player picks a rate (C.power.rate_presets or free entry); the fraction falls out of rate x window. rec.yield_target is a derived cache written by turret.set_rate. yield_default derives from C.power.default_rate at the bottom of this file.
  yield_default = 0.10,

  -- Quantisation: a detonation is ~100 generated prototypes, so impact.variant_for rounds a shot DOWN to the step at or below what it paid for. The ladder is dense at the bottom because a fixed gap is a bigger relative jump on a small dial.
  -- THIS TABLE MUST COVER THE WHOLE DIAL. variant_for falls back to the smallest step below the lowest entry and does NOT clamp to the largest above the highest, so raising overcharge_max means extending it in the same edit.
  -- ~16 generated prototypes per step.
  yield_targets = {
    {fraction = 0.01}, {fraction = 0.02}, {fraction = 0.05}, {fraction = 0.10},
    {fraction = 0.25}, {fraction = 0.50}, {fraction = 0.75}, {fraction = 1.00},
  },

  -- The charge stops at the selected fraction (turret.power_tick) and one detonation is built per step (prototypes/vfx/waves.lua). The clock is locked to the audio, so yield trades power for joules, never for time.
  yield_scale = {
    -- Exponents on the yield fraction (1.0 = linear). The physical radius exponent is 1/3, but at 1/3 the whole selector spans 0.63x to 1.14x and the player cannot see what they paid for.
    damage = 1.0,
    radius = 1.0,
    -- Dart counts, scaled to keep density roughly constant.
    count  = 1.0,
    -- Nothing is built below this; a thinner fan stops reading as an explosion.
    floor  = 0.15,
  },

  -- Impact matching. The shell carries no yield: it raises a script trigger where it lands and scripts/impact.lua creates the carrier for the yield paid for. A landing matches the nearest pending strike within this many tiles; a shell that matches nothing detonates at 100%.
  impact_match_radius = 24,
  -- Ticks a pending strike is remembered.
  impact_ttl = 60 * 60,

  yield_tiers = {
    {threshold = 0.40, projectile = "conventional"},
    {threshold = 0.70, projectile = "heavy"},
    {threshold = 1.00, projectile = "atomic"},
    {threshold = 1.50, projectile = "overcharge"},   -- #73 overcharge band
  },
  -- The dial is 1%..100% and 100% is the whole weapon: 2000 tiles at the top. The grid is the real ceiling: an order beyond what the plant and battery deliver in the charge window stalls and detonates at what was paid for.
  -- Raising this means extending `yield_targets` above in the same edit.
  --
  -- ONE INSTALLATION'S CEILING, and the top a player can select from the start: a standard shot, 36 GW held for the charge window, a 2000-tile crater. Everything above it comes from more installations (N.tech.capacity), never from turning this up -- see group_cap.
  overcharge_max = 1.00,

  -- THE WEAPON'S CEILING, as a multiple of a standard shot: what a full battery firing together adds up to (C.beam.convergence.max_lances installations at 100% each). strike_absorb clamps a group's total to it, C.overpower_u measures the overpower band against it, and C.beam_steps() builds the lance widths up to it. Raising it means raising max_lances in the same edit, or the group can never reach it.
  group_cap = 10.00,

  -- Where the FINE width ladder ends. C.beam_steps() builds one lance prototype per C.beam.width_step up to here and then switches to C.beam.width_step_coarse, so the overpower band keeps thickening the lance without 257 prototypes per heat step. Also the top of the fine rate presets and of the chamber gauge.
  visual_cap = 1.00,

  -- Headroom so the top of the selector is reachable. cost_per_shot derives from the charge window at the standby draw divided by overcharge_max. Below 1 the gun is quietly weaker than advertised.
  charge_margin  = 1.00,

  -- No gate_mode: the lance places no flare, so there is nothing to hold back, and an ammo gate would fight turret.discharge. Lock at the effect, not the authority (see scripts/turret.lua, Gating).

  -- Taking a hit while charging loses progress.
  damage_charge_loss = 0.25,   -- fraction of current charge, per damage event

  -- THE RECOVERY, in ticks: the spin-down clip's own length, assigned below C.sound because that is where the number lives. The gun is ready on the tick it stops being audibly heard winding down, and the vent smokes for exactly it (scripts/installfx.lua).
  -- THE ONE KNOB on how often this gun may speak, and the one thing that makes it read as an installation rather than a weapon. A whole cycle is this plus the firing sequence.
  cooldown_ticks = 0,   -- derived

}

--- Levels of a bounded multi-level tech COMPLETED by `force`, 0 if unresolvable. LuaTechnology.level is the level on offer, so an unresearched '-1' tech reads 1; only the final level is marked `researched`.
function C.tech_levels_done(force, name, max_level)
  if not (force and force.valid) then return 0 end
  local tech = force.technologies[name]
  if not tech then return 0 end
  local done = tech.researched and tech.level or (tech.level - 1)
  if done < 0 then done = 0 end
  if done > max_level then done = max_level end
  return done
end

-- Cooldown duration, shortened by compression; must not end before spindown_ticks.
function C.charge.cooldown_for(force, compression)
  local t = C.charge.cooldown_ticks
  if t < C.sound.spindown_ticks then t = C.sound.spindown_ticks end
  return t
end

--- How many installations `force` may own: one, plus one per level of N.tech.capacity. nil or invalid reads as unresearched.
function C.capacity(force)
  return 1 + C.tech_levels_done(force, N.tech.capacity, C.tech.capacity_levels)
end

-- Yield model: trigger -> yield -> radius.
--   trigger  what the grid pays: rate x charge window (576 GJ at 100%)
--   yield    Y = M x E^a, a > 1 (a bigger trigger burns a larger fraction of the core)
--   radius   R = k x Y^(1/3), the cube-root blast law
-- With a = 8/3, R ~ E^(8/9): nearly linear, spanning 30-2000 tiles; at a = 1 the 150x field would buy only 5.3x radius. Only the product k x M^(1/3) matters, so both are derived below from reference_mt / reference_radius.
C.yield = {
  -- The world scale (3 m per tile) every physical derivation passes through. reference_radius pins the crater, so moving this moves reference_mt and not the crater.
  tile_metres      = 3.0,
  -- The hard ceiling on any blast radius, in tiles. Sits ON the saturation asymptote (C.yield.saturation.max_radius), so a full battery approaches it and nothing can exceed it.
  radius_cap_tiles = 3000,
  -- Derived at the bottom of this file from reference_radius x tile_metres against Brode's edge contour (a 2000-tile 1.45 psi contour at 3 m/tile is a 221 kt device). It feeds only C.yield.tonnes(), the fire-control readout: it cancels out of R = R_ref x (E/E_ref)^(a/3).
  reference_mt     = nil,
  reference_radius = 2000,   -- what 100% does to the ground, tiles -- top of the dial
  chain_exponent   = 8 / 3,  -- spread knob: R ~ E^(a/3). Does not move the 100% point.
  gj_per_tonne     = 4.184,

  -- RADIUS SATURATES; YIELD DOES NOT. Disc area goes as R^2 and every chunk a blast generates stays in the save forever, so radius is the one axis whose cost is quadratic AND permanent. Past the knee the curve rolls over to max_radius and the energy above it becomes C.overpower, which every other system scales on instead.
  -- Below the knee this is exactly the old power law, so 1% is still a 30-tile crater and 100% still a 2000-tile one.
  saturation = {
    knee_fraction = 1.00,
    max_radius    = 3000,   -- tiles, approached and never reached
    -- Derived at the bottom: the exponential's length scale, chosen so the join at the knee is C1 (value and slope both continuous) and the dial has no visible kink as it is scrubbed.
    tau           = nil,
    knee_radius   = nil,
  },

  -- Derived at the bottom of this file (M, k).
  chain_multiplier = nil,
  blast_k          = nil,
}

-- Detonation (fed to lib/blast.lua)
C.blast = {
  -- iso_y is 1.0: there is no isometric projection in Factorio. The ground plane is orthographic and square, and the crater, damage binning and charging sphere already draw true circles; a squash makes the shock front an ellipse inside a circular crater. Kept as a knob because sprite geometry cannot be checked statically.
  iso_y = 1.0,

  -- Decorative fans (damage moved to scripts/detonate.lua). `count` is the number of invisible darts thrown and the UPS bill (~1270 in total, a quarter of vanilla's nuke); `radius` is how far they scatter. Names match lib/names.lua.
  -- The radii describe the visible fireball, not the blast: at full zoom-out the damage front is far off screen, so a sprite ring at the real radius would be a single dart every few hundred tiles.
  fans = {
    core     = {count =  150, radius =  42, speed = 0.6 * 0.8},
    main     = {count =  200, radius = 105, speed = 0.5 * 0.7},
    cluster  = {count =  140, radius =  78, speed = 0.5 * 0.7},
    smoke    = {count =   60, radius =  78, speed = 0.5 * 0.65},
    inner    = {count =  140, radius =  48, speed = 0.5 * 0.65},
    fireball = {count =  100, radius =  26, speed = 0.5 * 0.65},
    -- Fans vanilla lacks: a slow outer dust ring, a fast tight overpressure ring, and a wave that travels back inward a second later.
    dust     = {count =  320, radius = 150, speed = 0.5 * 0.30},
    over     = {count =   90, radius =  45, speed = 0.5 * 1.10},
    reflect  = {count =   70, radius =  70, speed = 0.5 * 0.50},
  },
  -- Map-view bloom (vanilla artillery uses 8/32).
  chart_scale = 48 / 32,

  speed_deviation = 0.075,
  wave_max_distance = 19,
  wave_max_distance_deviation = 2,

  -- Ground-zero damage.
  damage = {
    -- Ground zero: one big falloff circle so the centre is unsurvivable wherever the darts land. Falloff runs across the circle's own radius. Absolute numbers, not multipliers, so two multipliers cannot stack.
    ground_zero        = 64000,
    ground_zero_radius =   130,
    wave               = 28000,
    wave_radius        =   100,
    centre_falloff     = 0.35,   -- damage multiplier at the rim

    -- The darts carry the damage: explosion entities are purely visual. Vanilla's atomic-bomb-wave is radius 3, 400 explosion, falloff 1.0 -> 0.1 over 35 tiles; radii here are ~3x vanilla's at similar counts, so per-dart damage is raised to compensate.
    dart_radius      = 3,
    falloff_near     = 0,
    -- Gentler slope and a higher floor than 220/0.25, which read as trickle damage after worm resistances.
    falloff_far      = 300,
    falloff_far_mult = 0.60,

    -- Dart density falls as the square of the radius, so per-dart damage rises with reach or the fans become decoration. Raising damage rather than dart count is deliberate: counts are entity spawns (UPS), amounts are free.
    dart_core        = 6000,
    dart_main        = 4800,
    dart_cluster     = 3600,
    dart_over        = 2800,
    dart_reflect     = 2000,
    -- The dust ring is the visible black wave, so it has to kill as it passes.
    dart_dust        = 4000,
  },

  -- Effect rings. Damage is not made of sprites: one find_entities_filtered at detonation, one pass binning the result into `buckets` distance bands, then one band paid out per tick as the front passes.
  -- Dart density falls as the square of the radius, so holding coverage at 1800 tiles would take over a million projectiles; the dart model cannot work at this scale.
  -- The fans above are purely visual. Damage radius and sprite radius are independent and neither derives from the other.
  -- Damage does not scale with yield, only the radii do: the 5 psi radius grows with yield but 5 psi is still 5 psi, so a 1% shot is as unsurvivable at its centre as a full one.
  -- The payload is one number in hit points and every stage is a share of it. Damage is absolute, not a fraction of the victim's health, so the weapon scales with enemy health: soft things die everywhere, armoured ones only where pressure is high enough (the payload technology pushes that line out). Yield buys radius, never dose.
  dose = {
    -- Two mechanisms, each calibrated at its own published lethality threshold: blast at 5 psi (the ~50% lethality contour) and thermal at its 3rd-degree-burn radius. Neither anchor moves with the enemy health pool.
    -- An absolute dose anchored to an observed health pool fails every time: 60000, sized on a 9000 HP worm, left the outer 89% of the blast area harmless against 18000 HP spawners.
    -- lethal_hp is the one number to restate when the enemy mod changes: what the weapon must kill at the edge of its own effect.
    lethal_hp      = 18000,   -- toughest thing the rim must kill
    lethal_resist  = 0.30,    -- its explosion resistance, as a fraction
    -- Blast alone delivers a lethal dose at this contour, psi.
    blast_lethal_psi = 5,
    -- Derived at the bottom of this file. Declared here because beam.lua and implode.lua read them and verify.py check 14 resolves C.* reads against this table's literal key tree.
    lethal_dose    = nil,     -- lethal_hp through lethal_resist
    blast_p_ref    = nil,     -- pressure at blast_lethal_psi, dose_at's divisor

    -- Thermal radiation: why the outer half of the blast kills anything. 1.45 psi (windows break) cannot pay for lethality at the rim; thermal can, and at these yields it reaches further (fluence goes as W^(1/2), blast as W^(1/3)). Q = f_th x W x tau / (4 pi R^2); the burn radius is where Q falls to threshold_j_m2, and inside it the dose rises as 1/R^2.
    -- Thermal reach as a fraction of the shot's radius goes as f^(4/9): 0.138 R at 1%, 0.578 R at 25%, 1.070 R at full. A small shot is concussive; a full one burns its whole disc. It is a second term in dose_at(), not a second sweep.
    thermal = {
      enabled        = true,
      yield_fraction = 0.25,      -- of yield emitted as thermal, SURFACE burst
                                  -- (an airburst is ~0.35; the ground eats the rest)
      transmittance  = 0.75,      -- clear-day atmospheric, at these ranges
      threshold_j_m2 = 3.35e5,    -- 8 cal/cm^2, 3rd-degree burn / ignition
      -- DERIVED at the bottom: burn radius at full dial, as a fraction of the
      -- blast radius, and the exponent that scales it down the dial.
      u_ref          = nil,
      u_exponent     = 4 / 9,
    },

    -- Derived at the bottom of this file: the dose at the fireball ring's edge, which every pre-wave stage takes a share of.
    payload = nil,
  },

  -- Movers are found by a trailing band, not a one-time search. front.lua searches each chunk once, which is exact for buildings but leaks walkers that step into a searched chunk or spawn in one. Every front keeps these types out of its one-time search and re-searches a thin band behind itself (sweep_movers in scripts/front.lua).
  movers = {
    enabled = true,
    -- Every one inherits EntityWithOwnerPrototype, so every one has the
    -- unit_number the band dedupes on (2.0.77 spec).
    types = {"unit", "spider-unit", "segmented-unit", "character", "car", "spider-vehicle"},
    set = {},             -- DERIVED from types at the bottom of this file
    -- Re-search after this much front travel, or this many ticks, whichever
    -- first. Band depth ~ chunk diagonal + travel, so each chunk is searched
    -- about (46 + 32) / step_tiles times as the front passes.
    step_tiles = 8,
    max_interval = 30,
    -- Fastest thing the band must not lose, tiles/tick. Vanilla's fastest
    -- biter (behemoth) is 0.3; widening this only deepens the band.
    speed = 0.5,
  },

  -- Scars. Past generate_ahead_radius the sweep does not build ground, so charting toward an old crater later would generate it fresh and the crater would heal. Every shot leaves a record, and scripts/scar.lua pays it out on on_chunk_generated at the distance the chunk actually sits, through rings.dose_at. on_chunk_generated fires once per chunk, so a biter that walks in afterwards correctly survives.
  scars = {
    enabled = true,
    -- Oldest dropped past this; a guard against an unbounded table.
    max_records = 256,
    -- Entities paid per newly generated chunk; the chunk is generated once, so the cap is deliberately generous.
    budget_per_chunk = 400,
  },

  rings = {
    -- Switch for the sweep model. False restores the dart detonation. scripts/detonate.lua and the fans must never both be armed or entities in the overlap are damaged twice; the derived block at the bottom zeroes the dart and ground-zero damage whenever this is true.
    enabled = true,

    -- Entity types the query never returns, excluded ENGINE-SIDE (`invert`, filtered to types that exist at runtime) so ore patches, which outnumber everything built, never cross into Lua.
    skip_types = {
      "resource", "corpse", "particle", "explosion", "projectile",
      "smoke", "smoke-with-trigger", "stream", "sticker", "highlight-box",
      "flying-text", "item-request-proxy", "rocket-silo-rocket-shadow",
      "arrow", "speech-bubble", "entity-ghost", "tile-ghost",
      "fire", "beam", "cliff", "artillery-flare", "deconstructible-tile-proxy",
    },

    -- Known and deliberately not fixed: destroying spawners drives enemy_evolution (one full-dial shot measured to 0.83), which raises enemy health and shrinks the next shot's lethal radius.
    -- Kill credit when the caller does not say: 'player', never neutral, which breaks evolution accounting and kill statistics.
    default_force = "player",

    -- `destroy` skips damage and removes the entity: 30000 explosion damage still leaves a spidertron standing.
    -- The rings are overpressure contours from Brode's (1955) fit for peak free-air overpressure against scaled distance Z (m/kg^1/3):
    --     p = 0.975/Z + 1.455/Z^2 + 5.85/Z^3 - 0.019   bar   (0.1 < p < 10 bar)
    --     p = 6.7/Z^3 + 1                               bar   (p > 10 bar)
    -- The edge of the blast is 0.1 bar (1.45 psi), where the fit stops being valid. Each ring is the radius where pressure crosses a classic threshold, as a fraction of the blast R:
    --     fireball  >= 20 psi   0     .. 0.214 R   obliterated: die(), no roll
    --     heavy    20 -> 10 psi 0.214 .. 0.301 R   dose 100% -> 50% of payload
    --     severe   10 ->  5 psi 0.301 .. 0.445 R   dose  50% -> 25%
    --     blast     5 -> 1.45   0.445 .. 1.000 R   dose  25% -> 7.3%
    -- The dose is continuous inside a ring; the lines are what the designator overlay draws.
    -- Derived at the bottom of this file into rings.bands, rings.fireball_u and law.z_edge / law.p_ref.
    law = {
      edge_bar = 0.10,
      rings = {
        {name = "fireball", psi = 20, destroy = true},
        {name = "heavy",    psi = 10},
        {name = "severe",   psi = 5},
        {name = "blast"},                 -- to the edge
      },
    },
    bands = {},        -- BUILT at the bottom of this file from `law`

    -- One damage type for every band: a fire ring does nothing to worms that resist fire.
    damage_type = "explosion",


    -- Average front speed in tiles per tick (sweep_ticks = R / this). The front follows Sedov-Taylor (wave.front_curve): fast out of the fireball, crawling at the rim. This scales the whole curve without bending it (R ~ t^(2/5)).
    -- Slow on purpose: every radius-squared bill (paint, chart, generation) is spread across the sweep. New ground acquired and paid per tick:
    --   10000 tiles, 1.2 : peak 75757, rim 30159 tiles/tick, 139 s sweep
    --   10000 tiles, 0.8 : peak 50504, rim 20106 tiles/tick, 208 s sweep
    --   2000 tiles,  0.8 : peak 10101, rim  4021 tiles/tick,  42 s sweep
    -- The front is already subsonic at 1.2 (sound is 1.89 tiles/tick at 3 m/tile).
    front_speed = 0.8,

    -- Floor on the sweep length in ticks: a front crossing the whole blast in a fraction of a second reads as a flash of concentric rings, and the sweep must outlast a stamp's own lifetime. Binds below about 340 tiles (~17% yield).
    min_sweep_ticks = 90,

    -- Distance buckets are a width in tiles: a 42 tile bucket paid on arrival kills things ahead of the visible fire. See scripts/front.lua.
    bucket_tiles = 4,
    -- Tiles of lead the entity search keeps ahead of the front (front.lua adds
    -- twice the per-tick travel and a chunk diagonal on top).
    acquire_lead = 32,

    -- UPS safety valve: max entities damaged per tick; a bigger band spills into following ticks. At 10000 tiles the front crosses ~20000 tiles of ground per tick at the rim, so on a dense death world a lower cap falls behind and drains after the front stops (front.done gates the teardown, so nothing is lost).
    -- UNMEASURED: /oppenheimer-status reports found/binned/damaged; `damaged` well under `binned` long after the front stops means raise it.
    entity_budget_per_tick = 1400,

    -- Designator overlay: what the shot will destroy, drawn before it is fired. A readout, not a lock; every gate that reasoned about whether the gun may fire has failed. One circle per band at that band's real radius.
    preview = {
      -- Per band, inside-out. Indices match `bands` above.
      colours = {
        {r = 1.00, g = 0.95, b = 0.90, a = 0.55},   -- vaporize
        {r = 1.00, g = 0.55, b = 0.15, a = 0.45},   -- severe
        {r = 1.00, g = 0.85, b = 0.30, a = 0.35},   -- blast
        {r = 0.70, g = 0.75, b = 0.85, a = 0.25},   -- thermal
      },
      -- Ring colour when the blast covers something of your own: a warning, not a refusal.
      danger  = {r = 1.00, g = 0.15, b = 0.10, a = 0.70},
      width   = 3,
      -- Ring widths do not scale with the circle, so the outer bands are drawn thicker to stay visible at zoom.
      width_outer = 6,

      -- Coverage readout: samples `coverage_samples` points around the outer band (is_chunk_generated). Below `coverage_warn_threshold` generated, the band switches to `unconfirmed`.
      coverage_samples        = 24,
      coverage_warn_threshold = 0.85,
      unconfirmed = {r = 0.75, g = 0.20, b = 0.85, a = 0.55},
    },

    -- The shock front, drawn by the sweep itself from the exact radius reached this tick, so picture and damage share one number. A true circle (iso_y is 1.0) with a little jitter.
    wave = {
      enabled = true,

      -- 'plasma' (base's big-explosion, emissive; default), 'smoke' (tinted nuke-shockwave), or 'both' (twice the sprite cost per stamp).
      art = "plasma",

      -- Sprite width in tiles at explosion scale 1; drives stamp density. Copied from anims.lua (config.lua cannot require a data-stage file); keep in sync.
      sprite_tiles = 197 / 32,

      -- Map-view copy of the front: VFX prototypes are not-on-map, so this is one purpose-drawn render object at the front's true radius. Not drawn below min_radius or in world view.
      chart = {
        enabled = true,
        color = {r = 1.00, g = 0.45, b = 0.12, a = 0.95},   -- opaque: reads on a flat map
        width = 5,          -- pixels, authored for the map (no width_mult)
        min_radius = 60,
      },

      -- Tiles between stamps along the front (stamp count = circumference /
      -- this, until max_stamps binds).
      spacing = 7,

      -- Overrides `spacing` when set: a fraction of the puff's own width, so density stays constant across the yield range.
      spacing_fraction = 0.4,

      -- Floor so a small blast still reads as a ring.
      min_stamps = 24,

      -- UPS budget for the whole band, split across its layers: the number to turn down if a full-yield shot stutters. The front stamps a layer whenever it has advanced band_layer_spacing of a puff's width (draw_front in scripts/detonate.lua).
      max_stamps    = 900,

      -- The band: each draw stamps several concentric rings spanning where the front was to where it is, so a fast early front draws a thick wall and a crawling late one a thin ring. max_stamps is split across the layers, not multiplied.
      band_enabled = true,

      -- Hard ceiling on layers in one band (the frame-rate stop for the first ticks of a full-yield shot).
      band_max_layers = 9,

      -- Gap between layers as a fraction of a puff's drawn width; below 1.0 they overlap.
      band_layer_spacing = 0.7,

      -- Floor per layer of a deep band, below which it's just scattered puffs.
      band_min_layer_stamps = 20,

      -- The wall: the front is a body of gas drawn as world-space geometry, not a ring of sprites. rendering.draw_polygon takes a triangle STRIP, so alternating outer and inner vertices give an exact annulus with thickness in tiles (a draw_circle width is screen pixels and becomes a hairline at zoom). Nested annuli at different colours and alphas make the gradient; the puff stamps stay on top as texture.
      -- Sprite stamps alone read as a dotted arc: base's big-explosion sheet is a burst (frames 5-9 at 0.93-1.00 of peak luminance, frames 15-40 at 0.13, of a 47-frame clip), so no stamp count fixes its duty cycle (anims.lua frame_sequence), and nothing connects the stamps.
      -- Physics:
      --   temperature: the gas is the ball's kelvin at release (impact.detonate), cooling as it expands (Sedov: T ~ R^-3; see cool_exponent)
      --   thickness: a Sedov shell compresses six-fold, so d = R/18 (thickness_fraction)
      --   instability: a decelerating dense shell is Rayleigh-Taylor unstable, so vertex radii carry cosine modes growing with u, with the same per-shot phase as implosion's rt_* lumps
      --   interior: hotter than the front, so the afterglow is drawn whiter and the leading edge oranger
      --   dust: a precursor whose alpha runs inverse to the glow, so the rim of a big shot reads as a dark rolling wave
      -- Cost: about a thousand small tables per tick per sweep, redrawn each tick with a two-tick life (as scripts/implode.lua's ball) so nothing persists to invalidate.
      wall = {
        enabled = true,

        -- Vertices around the ring; a closed strip costs 2(segments + 1) tables per annulus.
        -- Bound by rt_modes: a ring sampled at `segments` angles carries at most segments/2 modes before aliasing into a lower-frequency shape, and needs about four samples per cycle to stop looking faceted. segments_for() enforces top mode x rt_samples_per_mode, floored. Raising rt_modes without raising this gives an alias, not finer lumps ({5, 9, 14} at 72 segments drew a five-lobed blob).
        segments_min       = 96,
        segments_max       = 384,
        rt_samples_per_mode = 5.0,

        -- The Sedov shell, R/18. Floored so a small blast has a wall rather than a line, capped so a full-yield one stays a front rather than a filled disc.
        thickness_fraction = 1 / 18,
        thickness_min = 2.5,
        thickness_max = 140,

        -- Cooling law: k(u) = k_release x (u_fireball / u) ^ cool_exponent, floored at t_floor.
        -- Sedov says 3, which is too fast: a full shot's gas would fall under the Draper point (~800 K) by a third of the radius. At 2.0 a 100% shot runs ~48000 K at the fireball edge to ~2200 K at the rim, and a 1% shot ~15000 K to ~700 K (floored), across the whole radius at every yield. Deliberately tempered, like yield_scale's radius exponent.
        cool_exponent = 2.0,

        -- Ember red, above the Draper point so a small shot's rim is dull red rather than black.
        t_floor = 1200,

        -- Used when a detonation reaches the sweep with no temperature (console command, old save); roughly a half-dial release.
        kelvin_fallback = 24000,

        -- The afterglow: nested annuli stepping inward from the shell, each fainter. Colour comes from each annulus's own radius through the same law, so the inside is whiter for free.
        glow_layers = 4,
        glow_depth_fraction = 0.22,   -- how far in the afterglow reaches, x R
        glow_alpha = 0.15,            -- of the outermost layer; fades inward
        -- Sedov's interior is hotter than its shock front; applied to the afterglow temperature.
        interior_gain = 1.35,

        -- The shell
        shell_alpha = 0.50,

        -- Draw order: draw_polygon takes no render_layer, so the only lever is draw_on_ground (on: below sprites and entities; off: above them). Both are on so the fire-ring stamps texture the wall instead of being buried under it.
        glow_on_ground  = true,
        shell_on_ground = true,

        -- The rim: the outer sliver of the shell, brighter and whitened (the shock surface, where gas is densest).
        rim_fraction = 0.22,   -- of the shell's thickness
        rim_alpha    = 0.80,
        rim_whiten   = 0.45,

        -- The dust precursor, ahead of the shell and drawn ON THE GROUND so things stand in it. Alpha runs inverse to the glow. `dust_layers` annuli step outward across the same depth, each fainter by dust_taper, so the leading edge fades into the ground instead of ending at a crisp polygon edge. Two extra polygons per tick.
        dust_enabled   = true,
        dust_fraction  = 1.7,   -- of the shell's thickness, outward
        dust_layers    = 3,
        dust_taper     = 0.45,  -- alpha of the outermost layer vs the innermost
        dust_color     = {r = 0.09, g = 0.06, b = 0.04},
        dust_alpha_min = 0.10,
        dust_alpha_max = 0.42,

        -- Rayleigh-Taylor: r(theta) x (1 + amp x sum(cos(m theta + phase) / i) / norm), amp = rt_amplitude x u ^ rt_growth. Several modes so the lumps do not read as a flower; per-shot phase from Factorio's RNG, stored lazily on the sweep record (no schema bump).
        -- Mode numbers are set by the shell thickness, not the radius. Fingers a few shell thicknesses long give m = 2 pi R / (q x R/18) = 36 pi / q, so q = 2 gives 57 and q = 4 gives 28. The fundamental is 41 (q = 2.76) with harmonics 23 and 13 at 1/2 and 1/3 weight. th/R is constant, so one set of integers serves the whole dial.
        -- Low modes such as {5, 9, 14} are wrong: at full yield mode 5 is a 3243-tile finger 284 deep, an 11:1 bulge that makes the circle the wrong shape.
        -- 41 rather than 57 because segments_for scales vertex count off the top mode and each vertex is a table built nine times a tick (dust x3 + glow x4 + shell + rim); it keeps the mesh near 205 segments instead of 314.
        -- rt_amplitude 0.055 equals one thickness_fraction: fingers one shell thick. The three modes rarely peak together, so RMS deviation is ~0.45 of it (~2.5% of R).
        rt_enabled   = true,
        rt_modes     = {41, 23, 13},
        rt_amplitude = 0.055,
        rt_growth    = 1.6,

        -- The light it casts. A polygon is not additive and cannot spill light, so a ring of lights along the front makes it read as burning. Off past max_radius: at 2000 tiles even 32 lights are 400 tiles apart, and the front is off screen anyway.
        light_enabled    = true,
        light_max_radius = 520,
        -- Spaced in tiles, then capped, so lit density is the same at a 33-tile ring and a 520-tile one (a flat 32 lights is a blowout at one end and a scatter at the other).
        light_spacing    = 24,
        light_count      = 32,
        light_count_min  = 4,
        light_sprite     = "utility/light_medium",
        light_scale_per_thickness = 1.6,
        light_scale_min  = 2.0,
        light_scale_max  = 14.0,
        -- Lights overlap and Factorio adds light, so this is a per-lamp share. First knob if a near shot blows out.
        light_intensity  = 0.50,
      },

      -- Shadow: superseded by `wall.dust_*`, which does the same job with real thickness and a temperature-tracked colour. Kept behind its flag.
      shadow = {
        enabled = false,

        fill_color = {r = 0.02, g = 0.01, b = 0.01, a = 0.30},
        -- Off: the tile paint follows the front, so a fill would double up with it.
        fill_enabled = false,

        rim_color  = {r = 0.03, g = 0.01, b = 0.00, a = 0.55},
        rim_width  = 14,          -- pixels (screen space, holds weight at any zoom)
        radius_mult = 1.03,       -- just outside the front, like a wall's shadow leaning away
        fade_with_paint = false,  -- the paint follows the front now; no fade needed
        max_radius = 3000,        -- fill-rate stop past any real viewport
      },

      -- Radial jitter so the front does not read as a drawn circle; small, so the wave stays coherent.
      jitter_fraction = 0.006,
      jitter_max      = 5,

      -- Puff size as a multiple of the sprite's scale, driven by k.rad and clamped: too small gaps into a bead necklace, too big (~8x+) reads as fog. See prototypes/vfx/explosions.lua.
      stamp_scale_min = 0.5,
      stamp_scale_max = 8.0,

      -- Not the puff's colour: the black-body law in `wall` decides that per heat step through heat.glow_rgb, so texture and surface cannot disagree. This is a plain white multiplier; `a` is how loudly the puff layer reads against the wall.
      tint = {r = 1.00, g = 1.00, b = 1.00, a = 0.55},
      stamp_scale_in  = 0.75,   -- grows as it plays, so the puff expands with the front
      stamp_scale_out = 1.35,

      -- Stamp lifetime derives from the cadence: it must outlive the gap until the next layer lands behind it or the ring blinks. life = stamp_overlap x (layer gap in tiles) / (front speed at the rim); see C.blast.rings.wave.stamp_life.
      stamp_overlap  = 1.8,
      stamp_life_min = 20,
      stamp_life_max = 150,

      -- Front decay: u = (elapsed/ticks)^curve. 0.4 is the Sedov-Taylor exponent for a surface burst (a hemisphere in 3D air), applied to damage and visual alike. Do not use 0.5: that is the cylindrical solution (a line charge). It would flatten the area swept per tick (75757 -> 37699 tiles/tick at 10000 tiles), but the load is front-heavy by nature and front_speed is the performance knob that preserves the shape.
      front_curve = 0.4,
    },

    -- The fire wave: a second ring stamped by the same mechanism as `wave` (stamp_ring in scripts/detonate.lua) but carrying N.ex_firewave, the N.scorch_flame art alive for only lifetime_ticks. It reads as a wave of fire crossing the ground. The short lifetime makes the density affordable: concurrent count is stamps per call x lifetime_ticks / gap ticks, so cost never scales with the blast's area.
    firewave = {
      enabled = true,

      -- Ticks the decal's animation plays, which is its whole lifetime (an explosion lives exactly as long as its animation plays).
      lifetime_ticks = 15,

      -- Puff geometry, yield-scaled (stamp_tiles() / stamp_spacing() at the bottom of this file mirror the wave's pair). A fixed 2.6-tile flame is a pixel at a 2000-tile radius. It grows on the same k.rad curve as the plasma puff, clamped harder (4x, not 8x).
      -- The ring is not closed at full yield: 11000 tiles of circumference cannot be closed by sprites at 60 UPS, which is why the polygon wall exists. The fire ring is texture on that wall.
      scale_initial      = 0.9,
      scale_end          = 1.3,
      sprite_tiles       = (84 / 32) * 1.3,
      stamp_scale_min    = 1.0,
      stamp_scale_max    = 4.0,

      -- Tiles between stamps: a fraction of the puff's own width so density holds across the yield range; `spacing` is the fallback. Tighter than the plasma ring so it reads as a running trail.
      spacing          = 2,
      spacing_fraction = 0.3,
      min_stamps       = 16,

      -- UPS budget per call. Can exceed wave's 900 because at a 15-tick lifetime even a full burst is gone in a quarter second.
      max_stamps = 700,

      band_enabled          = true,
      band_max_layers       = 6,
      band_layer_spacing    = 0.6,
      band_min_layer_stamps = 10,

      -- Same role as wave.jitter_*.
      jitter_fraction = 0.01,
      jitter_max      = 2,

      -- Not the flame's colour: it reads from heat.glow_rgb at its own radius, like the wall and the plasma puff. A tint multiplies, and base's fire-flame-01 averages (139, 83, 37) over its opaque pixels, capping blue at 27% of anything asked for, so the art is the mod's own greyscale bake (tools/make_fire_art.py). This is a plain white multiplier; `a` is how loudly the flame layer reads against the wall.
      tint = {r = 1.00, g = 1.00, b = 1.00, a = 0.85},
    },

    -- Trees and rocks (scripts/flora.lua) are never damage()d or die()d by the blast: one dose kills a base tree and throws ~250 particles, which through a forest was 160 ms/tick of F4 'Particle update'. Inside the fireball ring they are destroyed; outside it trees are charred (leafless, gray) and rocks destroyed if the dose would kill them. Driven by the sphere's rim first, then the wave.
    flora = {
      enabled = true,

      -- LEAVE NOTHING STANDING. The flora front destroys every tree, rock and
      -- scrub it reaches, to the full blast radius, instead of charring trees
      -- outside the fireball ring and dosing rocks. Two reasons it is the
      -- default: a charred tree is still an entity every later phase searches,
      -- bins and re-treats, and char() is a stage-index write that does nothing
      -- visible on a modded tree whose prototype ships no dying stages. false
      -- restores the charred-and-standing treatment.
      vaporize_all = true,

      -- Tiles of travel between searches; the treatment trails its driver by up to this much.
      min_step = 12,
      -- Widest annulus one pass may take: halved while a pass returns more than `budget` entities, doubled under half of it, so a dense forest slows the front instead of spiking a tick.
      max_step = 96,
      budget = 4000,
      -- A front not fed for this long is dropped. Must outlast the gap between the sphere's last feed and the wave's first.
      stale_ticks = 60 * 60,
      -- Never generates ground. A pass stops short of the nearest ungenerated chunk INSIDE generate_ahead_radius and waits for the wave, whose own search builds just ahead of itself, re-checking every sphere_retry_ticks. Holes beyond that radius are skipped, not waited on: nothing will build them this shot and scripts/scar.lua pays them on generation.
      sphere_retry_ticks = 30,

      -- Real debris: a fixed trickle of trees killed with their own death effects at the shock front, outside the fireball. per_tick is the particle knob, shared by every sweep (~51 particles a tree).
      debris = {
        enabled = true,
        per_tick = 4,
        probes = 8,           -- position searches per tick, per sweep
        probe_radius = 3,
        -- Base leaf/branch particles are only_when_visible, so this share of probes goes to the stretch of front within aim_tiles of a player.
        aim_fraction = 0.75,
        aim_tiles = 60,
      },
    },

    -- The fireball leaves nothing: a separate sweep (die() first so kills and corpses are credited, then remove corpse/item-entity within the vaporize radius). set_tiles runs with remove_colliding_entities = false (see the paint block), so the crater tile cannot clear bodies itself.
    corpses = {
      enabled = true,

      -- DERIVED from the ring law (the fireball ring's edge, 0.214 R) and
      -- overwritten at the bottom of this file.
      radius_fraction = 0.214,

      -- `corpse` is the body; `item-entity` is everything the dead dropped.
      -- Drop "item-entity" if loot inside the crater should survive.
      types = {"corpse", "item-entity"},

      -- Insurance against a query nobody intended.
      max_radius = 600,
    },

    -- Ground fire: the painted crater drawn as its own temperature (C.heat.ground), sampled every `interval` ticks inside the painted radius and stamped as short flames at the heat step each point has cooled to (scripts/groundfire.lua). Flames land only where a player can see, so the cost is set by coverage and max_per_pass, never by the crater's area. `firewave` is the wave; this is the ground it leaves.
    groundfire = {
      enabled = true,

      interval = 4,       -- ticks between passes
      -- Ticks one flame burns, which is its animation's whole length. Frames play at base fire's own rate (frame_rate per tick), in `variations` windows from different points of the loop so flames laid together do not flicker in step.
      life       = 120,
      frame_rate = 0.5,
      variations = 4,
      fade_in    = 60,
      fade_out   = 120,

      -- Share of the glowing ground the live flames cover, each counted as its drawn width squared.
      coverage = 1.0,
      -- Flames one pass may lay across every watcher: the UPS knob. Live flames are at most max_per_pass x life / interval.
      max_per_pass = 60,

      -- Flame size: scale x k.rad clamped to [scale_min, scale_max] (as the fire wave); the variations span 1 -/+ size_spread of it.
      sprite_tiles = 84 / 32,
      scale        = 0.85,
      scale_min    = 1.0,
      scale_max    = 4.0,
      size_spread  = 0.25,

      -- Tiles per cooling patch (C.heat.ground.patch_spread).
      patch_tiles = 4,

      -- Not the colour: heat.glow_rgb per heat step against the ground's own peak (groundfire.kelvin(0)), so a flame dims as it reddens. A white multiplier; `a` is how loudly the flames read.
      tint = {r = 1.00, g = 1.00, b = 1.00, a = 0.60},
      -- Sorted with whatever stands in the crater, as a `fire` is.
      render_layer = "object",

      -- One light at ground zero, sized to the glowing radius and coloured by the centre's temperature. light_medium is 300 px: about 4.7 tiles of radius at scale 1.
      light = {
        enabled     = true,
        sprite      = "utility/light_medium",
        intensity   = 0.6,
        scale_per_r = 0.2,
        scale_min   = 2.0,
        scale_max   = 14.0,
      },
    },

    -- The map (scripts/detonate.lua chart_step): the fireball ring is charted at designation, which generates it; during the wave, generated chunks ahead of the front are charted, and every generated chunk is re-charted once the front, the payout and the paint have passed it. Ground that does not exist is never charted by the wave: force.chart generates what it charts, and a chart request waiting on the generator delays every chart request after it.
    chart_ahead = {
      enabled = true,
      epicenter_at_designate = true,
      -- Extra tiles around the fireball ring when charting at designation.
      epicenter_margin = 32,
      -- How far ahead of the front to chart, in ticks of its CURRENT speed.
      lead_ticks = 240,
      lead_min   = 96,
      -- Ticks between chart passes. The engine processes chart requests
      -- asynchronously, so batching costs nothing in smoothness.
      interval   = 10,
      -- Request generation of the ground ahead; it is charted as it lands. MUST stay off while scripts/front.lua force-flushes: the flush drains the WHOLE queue, so every chunk requested here is generated synchronously (measured on an unprepared death world at full dial: 83% of the mod's script update).
      generate   = false,
      -- Re-chart behind the wave, so the crater and the dead show on the map: a chart does not follow set_tiles or deaths on its own.
      refresh_behind = true,
    },

    -- Ground built ahead of the damage, which finds its victims with find_entities_filtered (nothing in an ungenerated chunk): a capped square queued at designation, CONFIRM and the strike (scripts/impact.lua settle_terrain), flushed only with force_at_strike.
    pregen = {
      enabled = true,
      -- request_to_generate_chunks takes a radius in CHUNKS: ceil(blast_tiles / 32) reaches the rim; one more covers the circle poking into the next chunk.
      margin_chunks = 1,
      -- Hard cap on the generated square, load-bearing: a full-dial shot would otherwise request a 64-chunk radius (16641 chunks) and the async queue grinds UPS to ~5 FPS through the firing sequence. Only the near-epicentre disc must exist before the fronts move; past generate_ahead_radius nothing is built at all and scripts/scar.lua pays it on generation. 12 chunks = 384 tiles, one chunk of slack over that radius -- keep the two in step.
      max_chunks = 12,
      -- OFF. On, the strike drained the whole queue synchronously and cost a single tick of ~1.5 s (max_chunks 16 is ~1089 chunks) -- the freeze players describe as the game hanging when they fire. The request still goes out at CONFIRM, so the charge window generates it asynchronously; whatever is left when the fronts move is drained by front.lua's own flush, bounded by generate_ahead_radius.
      force_at_strike = false,
    },

    -- The crater floor, laid behind the front as it passes (scripts/crater.lua). With Space Age each tile is graded by the ground law's peak temperature (`ladder`), the fireball's glaze cools through `glaze` on C.heat.ground's clock, and the crater itself is dug at ground zero; without it one tile reaches ring_base.
    paint = {
      enabled = true,

      -- Tiles one tick may write; past it the paint trails the front. The front lays ~3.8 x R tiles a tick across the crater, so this binds above a ~1000-tile blast.
      tiles_per_tick = 4000,
      -- Tiles the paint edge leads the front: lead_fraction of one plasma puff, capped at lead_max.
      lead_fraction = 0,
      lead_max      = 0,

      max_total_tiles = 25000000,

      -- Ticks between passes over one half of the crater; the halves are offset by half of it, so at 2 one half is written each tick.
      interval = 2,

      -- Crater edge: 'severe' (5 psi) is where the ground law falls to ~800 K, the Draper point. ring_base is the edge without Space Age. Both derived into radius_fraction(_base) at the bottom of this file.
      ring = "severe",
      radius_fraction = 0.445,
      ring_base = "heavy",
      radius_fraction_base = 0.301,

      -- The cold floor, inside out: each tile covers ground whose peak temperature (C.blast.rings.groundfire.kelvin) reached `kelvin` K; the last reaches the ring. Used only when every tile exists.
      ladder = {
        {tile = N.tiles.volcanic_cracks,       kelvin = 1200},
        {tile = N.tiles.volcanic_smooth_stone, kelvin = 1000},
        {tile = N.tiles.volcanic_folds,        kelvin = 0},
      },
      -- The glaze under the fireball ring, hottest first, each tile held until the C.heat.ground.cooling event named by `ends`: crust (the surface falls below t_melt), solid (the whole layer has frozen), dark (the surface falls below the Draper point). It then cools into the floor or the crater beneath it.
      glaze = {
        {tile = N.tiles.lava,                 ends = "crust"},
        {tile = N.tiles.volcanic_cracks_hot,  ends = "solid"},
        {tile = N.tiles.volcanic_cracks_warm, ends = "dark"},
      },
      -- The crater the burst digs at ground zero (Glasstone and Dolan, The Effects of Nuclear Weapons, 6.09 and 6.71): apparent radius radius_m at 1 kt in dry soil, every dimension scaling as yield ^ exponent, the lip's crest at `lip` times the radius.
      crater = {
        enabled  = true,
        radius_m = 18.3,
        exponent = 0.3,
        lip      = 1.25,
        floor    = N.tiles.nuclear_ground,
        rim      = N.tiles.volcanic_jagged_ground,
      },

      -- Every class edge is r x (1 + amplitude x sum(cos(m theta + phase (j + 1)) / j) / norm), one per-shot phase for all edges.
      lobes = {amplitude = 0.06, modes = {7, 13, 29}},
      -- Tiles each class edge is dithered by, per tile.
      dither_tiles = 1.5,

      -- Liquid is left alone: the flash boils off centimetres and the glaze quenches on it. Only boil_off water under the fireball ring is shallow enough to boil dry, and takes the glaze.
      skip_fluid_tiles = true,
      boil_off = {N.base.water_shallow, N.base.water_mud},
      -- Tiles holding this tile's fluid count as molten, so ground fire burns on them.
      molten_tile = N.base.lava,

      -- Chunks probed for liquid per tick, and how far ahead of now, in ticks of front travel.
      probe_per_tick = 8,
      probe_ahead_ticks = 60,

      -- The cooling pass: painted glaze rewritten as each event's contour falls inward.
      cool = {
        enabled = true,
        -- Tiles one tick may rewrite across every crater; past it the floor trails the temperature.
        tiles_per_tick = 1500,
        -- Rows of 8-tile cells are interleaved, each revisited every `slices` ticks.
        slices = 8,
        -- Tiles a contour must fall before its band is rewritten.
        min_tiles = 1,
        -- Map re-charts of the glaze per cooling event as its rewrite falls to ground zero.
        chart_steps = 4,
      },

      -- Left standing on the glaze once the front and the paint have passed it: creatures vanish, nests and worms die, bodies and loot are removed.
      melt_types = {"unit", "spider-unit", "segmented-unit", "unit-spawner", "turret", "corpse", "item-entity"},

      correct_tiles = false,
      -- NEVER TRUE: a painted tile would delete what stands on it with no damage event.
      remove_colliding_entities = false,
      -- Lava removes what it covers; ground tiles collide with no decorative, so `clear` sweeps those.
      remove_colliding_decoratives = true,
    },

    -- Decoratives and cliffs, cleared in 8-tile cells behind the front (scripts/crater.lua): every decorative inside the crater, non-decals to C.blast.scar.decorative_fraction of R, cliffs to cliff_fraction.
    clear = {
      enabled = true,
      lag_tiles = 4,   -- a cell clears once the front is this far past its nearest point
    },

    -- Hard ceiling on the query radius: insurance against a mistuned yield model asking to fault in most of the map.
    max_query_radius = 10000,

    -- How far the sweep forces the ground to exist, in tiles. Inside it, chunks the front reaches are generated on demand (the theatre the player watches). Outside it nothing is generated: the sweep damages chunks that exist and records the rest (scripts/scar.lua) for payout when they generate. An ungenerated chunk holds no entities, so nothing is missed; what is avoided is the blocking force_generate_chunk_requests and the permanent save file behind it.
    -- ⚠️ MUST STAY AT OR ABOVE C.perf.view.radius (360): it is the radius a watcher can see, so everything inside it has to be real ground. Above that it buys nothing but generation. A value at or over the shot radius disables the deferral entirely -- detonate.lua records a scar only `if radius > this` -- which is how a 1176 tile shot came to build its whole disc at 58.6 ms/tick of blocking generation. Measurements taken over already-generated ground (0.004-0.037 ms/tick) say nothing about this number; only a shot into wilderness does.
    generate_ahead_radius = 360,
  },

  -- Slay (scripts/slay.lua): every lethal blast hit on a creature outside every player's view is a quiet removal (kill statistics credited by hand, no body, no death effects) instead of die()'s particle and on_entity_died chain. Inside a view the hit goes through damage() so what anyone watches dies with its full animation. Spawners and worms always die normally (evolution stays the engine's own).
  slay = {
    enabled = true,
    -- Tiles from a player's view centre (which follows remote view) that count as watched; ~half the diagonal of a 1080p screen at the furthest normal zoom-out. A player on the zoomed-out map watches nothing.
    watch_radius = 128,
  },

  -- Detonation style: 'implosion' (energy drags into a point, holds, releases) or 'atomic' (flash, fans, mushroom column, fallout field). Both are built; this picks which one the carriers wrap. Delays are in ticks; 0 fires immediately, anything else generates a delayed-active-trigger prototype (lib/blast.lua).
  style = "implosion",

  -- Multiplies every radius in the detonation (folded into k.rad in prototypes/vfx/waves.lua, which every fan radius, damage circle, falloff, scar radius and camera distance scales by).
  radius_scale = 1.08,
  -- Whether the dart fans draw at all. A dart stamps smoke along its whole flight, and the visible explosion is the flash, the implosion gather and the shock front; true restores the dart detonation.
  fans_enabled = false,

  -- k.rad = blast_radius / this, so every VFX value stays at the scale it was tuned at (150 = the dust fan's radius).
  visual_divisor = 150,

  -- The implosion is control-stage: it needs runtime numbers a trigger tree cannot know (the real circumference, the radius the sphere reached). scripts/implode.lua owns it; the data stage keeps only the stamp art, core art and release delay.
  -- Schedule (both halves of the detonation read the same function): shell converges ticks_for(fraction), + settle_ticks, + beat_ticks = total_ticks_for(fraction), when release and damage happen.
  implosion = {
    -- Shell

    -- Shells stamped across the collapse; each lives stamp_life() across a 48-210 tick collapse, so several are on screen at once and read as one continuous inward flow.
    rings = 16,

    -- Convergence exponent: a converging shock is self-similar (Guderley), radius ~ (t_collapse - t)^alpha with alpha ~= 0.688 for a sphere, so dr/dt diverges as it closes. Toward 1.0 is a linear collapse; below ~0.4 the last two shells land on the same tick.
    converge_exponent = 0.688,

    -- Where the last shell lands, as a fraction of the starting radius; not zero, so it is still a small ring falling onto the core.
    radius_end_fraction = 0.02,

    -- Ring density: circumference over spacing, like the shock front.

    -- Spacing between stamps as a fraction of the puff's own width, so density self-tunes across the yield range (0.55 overlaps neighbours by 45%).
    stamp_spacing_fraction = 0.55,

    -- Frame-rate ceiling on one shell, and a floor so a tiny blast still gets a ring. Sixteen shells of 400 across a 150 tick collapse is ~2800 entities, under twenty a tick; the cap insures against a mistuned spacing.
    max_stamps = 400,
    min_stamps = 12,

    -- Stamp size, per yield step.

    -- scale_initial > scale_end makes each stamp point inward on its own: every puff shrinks while it plays.
    stamp_scale_initial = 1.4,
    stamp_scale_end     = 0.25,

    -- k.rad clamped, as C.blast.rings.wave.stamp_scale_min/max: past ~8 a puff reads as fog, below 0.5 as a pixel.
    stamp_mult_min = 0.5,
    stamp_mult_max = 8.0,

    -- Asset fact: the width of one plasma frame in tiles at explosion scale 1. Copied from anims.plasma_hot() because config.lua cannot require a data-stage file; change it with the art.
    stamp_sprite_tiles = 197 / 32,

    -- The clock, per yield: a larger shell converges slower, and at full yield the viewport shows a fifth of the event. Scaled on the radius with an exponent well under 1, so the clock spans 3.9x while the radius spans 86x:
    --     1%   ->  48 ticks (floor) + 15 beat =  63   1.05 s
    --     25%  ->  98 ticks         + 15      = 113   1.88 s
    --     100% -> 150 ticks         + 15      = 165   2.75 s
    --     150% -> 169 ticks         + 15      = 184   3.07 s
    base_ticks        = 150,   -- at reference_radius
    duration_exponent = 0.35,
    min_ticks         = 48,
    max_ticks         = 210,

    -- The beat: the pause between the collapse finishing and the release, kept short so the boom is not heard a second after the implosion.
    -- stamp_life() clamps down to beat_ticks first, so a beat below stamp_life_min lets the last shell's fade outlive the flash.
    beat_ticks = 15,

    -- Zero: the last shells land at 2% of radius on top of the core, under the flash.
    settle_ticks = 0,

    -- Stamp lifetime, capped at beat_ticks so the gather finishes before the flash. A bound, not a taste value: raising it past beat_ticks reopens the shell/flash overlap.
    stamp_life_fraction = 0.35,
    stamp_life_min      = 15,

    -- Rayleigh-Taylor: a converging shell is unstable, so it is drawn lumpy: r * (1 + amp * sin(m*theta + phase)), amplitude growing as it closes. Phase is rolled per shot from Factorio's deterministic RNG. Not possible in the data stage, where an `area` trigger cannot be given a shape.
    rt_enabled   = true,
    rt_modes     = 6,      -- lobes around the shell; 5-7 reads as instability,
                           -- 3 reads as a triangle and 12 reads as noise
    rt_amplitude = 0.11,   -- peak radial modulation, as a fraction of r
    rt_growth    = 2.0,    -- amp = rt_amplitude * t^rt_growth: smooth start,
                           -- breaks up only as it converges

    -- The ball: continuity with the sphere. The gather keeps drawing the same circle at the collapsing radius, starting at the radius the sphere reached; colours come from C.beam.sphere (fill_color/shell_color), so the ball cannot jump colour on the frame the beam cuts.
    ball = {
      enabled = true,

      -- Gets hotter as it shrinks: the rim interpolates from the sphere's rim colour toward this at full compression.
      heat_color = {r = 1.00, g = 0.93, b = 0.80, a = 1.00},
      fill_heat  = 0.35,

      -- Rim thickens as it closes (a constant screen-space width on a shrinking circle would read as thinning).
      shell_width_end = 26,

      -- Rim halo: a single hard stroke around a filled disc looks like render.preview's overlay rings. `halo_steps` extra strokes are drawn just outside the edge, each wider and fainter (`halo_fade` compounds), so the boundary bleeds outward.
      halo_steps  = 3,
      halo_spread = 0.03,   -- fraction of r added to radius, per step outward
      halo_fade   = 0.5,    -- alpha multiplier per step (compounds: .5, .25, .125)

      -- Ground shadow (draw_on_ground) so the ball reads as sitting on the ground.
      shadow_enabled     = true,
      shadow_radius_mult = 1.22,
      shadow_color       = {r = 0, g = 0, b = 0, a = 0.34},
      -- Pushed away from the light (shade.light) as a fraction of the ball's radius.
      shadow_offset      = {0.14, 0.09},

      -- Shading that makes the disc a sphere (implode.draw_orb): `layers` discs, each smaller (down to `inner` of the radius) and moved toward `light` (a unit vector, upper-left) by up to `offset`. Colour runs `color` -> `hot`; each is drawn at `alpha` over the one below, so the overlap is the gradient. 16 layers with a linear ease avoid the banding 6 layers at alpha 0.15 showed, at about the same total alpha. More layers cost a circle each per tick (world only).
      shade = {
        enabled = true,
        layers  = 16,
        ease    = 1,
        inner   = 0.20,
        offset  = 0.36,
        light   = {-0.60, -0.80},
        alpha   = 0.06,
        color   = {r = 0.06, g = 0.10, b = 0.38, a = 1},
        hot     = {r = 0.60, g = 0.82, b = 1.00, a = 1},
      },

      -- The ball casts light: one draw_light (same two-tick redraw) so it spills onto the ground and nearby things instead of reading as a painted circle. `scale` is capped since light_medium's falloff stops helping past a point.
      light = {
        enabled     = true,
        sprite      = "utility/light_medium",
        color       = {r = 0.55, g = 0.75, b = 1.00, a = 1},
        intensity   = 0.9,
        scale_per_r = 0.045,
        scale_min   = 1.0,
        scale_max   = 9.0,
      },
    },

    -- The collapse is a converging shock: everything the shell passes over takes one physical hit sized by the shock's strength at that radius (Guderley: pressure ~ r^-0.907 at alpha = 0.688).
    -- dose(r) = payload x dose x (r/r0)^(-shock_exponent), capped at cap_mult x the rim dose, floored at floor_fraction x r0. shock_exponent is derived from converge_exponent at the bottom of this file. Found chunk by chunk just ahead of the shell (scripts/front.lua); no full-disc query.
    shock = {
      enabled = true,
      dose = 0.093,           -- x C.blast.dose.lethal_dose, at the rim
      cap_mult = 12,
      floor_fraction = 0.05,
      damage_type = "physical",
      -- Trees and rocks are left to the wave: pulling every tree in a 2000-tile disc into Lua costs a lot for nothing visible.
      types = {"unit", "unit-spawner", "turret", "spider-unit", "segmented-unit",
               "car", "spider-vehicle", "character"},
      bucket_tiles = 4,
      lead = 32,
      -- The shell moves ~13 tiles/tick at full yield, so an 8-tile mover band would re-search ~67 tiles of shell every tick; coarser is free since the collapse is inside the opaque ball. See C.blast.movers.
      mover_step_tiles = 48,
      budget = 800,   -- entities/tick; over a dense nest, payout spills into
                       -- following ticks, still inside the beat

      -- How far out this front will build ground, in tiles; 0 = never build, search and pay whatever exists (opts.generate_to in front.advance; nil there means build everywhere).
      -- Must not be nil: beam.sphere.radius_fraction is 1.00, so r0 is the full blast radius and an unbounded front builds the entire disc (~3600 chunks at 1080 tiles) inside the ~4 s collapse. Measured: collapse/shock 53.5 ms/tick, 97.8% of it force_generate_chunk_requests.
      -- Declining costs no damage: an ungenerated chunk holds no entities (scripts/scar.lua) and the wave crosses the same ground later with its own bounded generation plus a scar record. Only the shock's sub-lethal share is given up (dose crosses lethal only inside ~0.073 r0, which rings.pregen has already built).
      -- Raise it only if things are found standing inside the ball on unexplored ground and the wave is not reaching them either.
      generate_to = 0,
    },

    -- Infall streaks: material dragged in rather than thrown out. Off: at any sane zoom they render as white blobs with a line through them. The code stays behind the flag (one drawing for both phases) but nothing calls it.
    streaks = {
      enabled = false,
      count   = 56,   -- render objects/tick for the whole collapse -- the
                       -- first knob to turn down if the collapse stutters

      -- Start above 1x the shell's radius: material pulled in from outside the ball.
      reach_min = 1.05,
      reach_max = 1.85,

      -- Length as a fraction of current radius, so a streak stretches as it falls (tidal elongation).
      length_fraction = 0.16,
      length_min      = 3,

      width = 5,   -- pixels, screen space
      color = {r = 0.55, g = 0.75, b = 1.00, a = 0.55},

      -- The leading tip (implode.draw_streaks_at), hotter than the streak colour.
      head_color       = {r = 0.85, g = 0.92, b = 1.00, a = 0.95},
      head_radius_frac = 0.35,   -- fraction of the streak's own length
      head_radius_min  = 0.6,    -- tiles
    },

    -- Core, per yield step.

    -- The point everything falls into, created once and stretched to last through the release (retimed against total_ticks_for, covering the held beat).
    core_scale_initial = 0.6,
    core_scale_end     = 3.2,

    -- Tighter clamp than the stamp's: the core is a point and must stay readable across an 86:1 radius range.
    core_mult_min = 0.25,
    core_mult_max = 6.0,

    -- Not the puff's colour: lib/heat.lua decides that per heat step through rgb (undimmed, as the ball's own rim), from the ball's temperature heating by collapse_gain as it converges, so shell and ball cannot disagree about how hot the same gas is. These are plain white multipliers; `a` is how loudly each layer reads additively. The core is stamped at full compression (t = 1) and the shell at its own t, so the gradient still points at the centre -- as a temperature now, not a typed red.
    core_tint = {r = 1.00, g = 1.00, b = 1.00, a = 1.00},
    tint      = {r = 1.00, g = 1.00, b = 1.00, a = 0.80},

    -- Casts light on a curve opposite the flash's (the core climbs and peaks at the release), with the same viewport-size caps (a Factorio light is a screen-space fill).
    -- Unverified: the spec does not document how initial/peak/final interpolate, so an increasing ramp is inferred from the flash's decreasing one. Failure is mild: full brightness instead of a climb. Open item in IN-GAME-CHECKLIST.md.
    core_light = {
      enabled        = true,
      intensity      = 0.85,
      intensity_floor = 0.30,   -- a 1% shot still lights its own crater
      size           = 46,      -- multiplied by the core's clamped k.rad
      max_size       = 500,
      factor_initial = 0.12,
      factor_final   = 1.00,
      peak_start     = 0.95,
      peak_end       = 1.00,
    },
  },

  stages = {
    flash        = 0,     -- light and camera, instantly
    overpressure = 8,
    fireball     = 16,
    shockwave    = 26,
    mushroom     = 34,    -- the cap starts climbing after the wave leaves
    dust         = 55,
    smoulder     = 110,
    -- The fallout cloud rides in the black wave; it must land after the dust fan has spread.
    fallout      = 170,
    -- Near the broadcast's own near-field floor (C.sound.boom_delay_min) so N.ex_boom (prototypes/vfx/explosions.lua) and the broadcast land together. Cannot reference that constant (defined later in this file); keep near it by hand.
    boom         = 10,
  },

  -- Terrain scarring. `duration` is not optional on CameraEffectTriggerEffectItem.
  scar = {
    tile_radius        = 75,
    decorative_radius  = 90,
    cliff_radius       = 60,

    -- Ground-zero decal, clamped harder than the puffs: a decal is one stretched texture that blurs when scaled hard. The script tile paint carries the crater at scale; this is the dark heart of it.
    decal_enabled  = true,
    decal_mult_min = 0.6,    -- a 1% shot: ~5.5 tiles in a 30 tile crater
    decal_mult_max = 7.0,    -- ~63 tiles, at every yield from about 45% up

    -- Ticks before the engine removes it: an hour, because the tile paint under it is permanent.
    decal_lifetime = 60 * 60 * 60,

    -- SetTileTriggerEffectItem.apply_projection: the spec gives only its name, type and default (false); what it does is unverified. Left at the default.
    apply_projection   = false,
  },

  -- Camera shake.
  camera = {
    strength             = 12,
    duration             = 90,
    ease_in_duration     = 5,
    ease_out_duration    = 30,
    full_strength_max_distance = 400,
    max_distance         = 2000,
    -- A second shake timed to the wave's arrival, so a distant player feels it after seeing the flash.
    arrival_delay        = 45,
    arrival_strength     = 5,
    arrival_duration     = 45,

    -- Pre-shake: the ground moves before the light arrives, so the flash lands as confirmation. Eased in over its whole duration so it ramps into the flash; scheduled at (shift - pre_shake_ticks) relative to the release, so it stays glued to the flash at every yield. Zero disables it.
    pre_shake_ticks      = 26,
    pre_shake_strength   = 3,
  },

  -- Flash first, thunder later: audible_distance_modifier carries a sound across the map (vanilla's nuke is about 3).
  sound = {
    near_distance_modifier = 3,
    far_distance_modifier  = 8,     -- audible from the far side of the map
  },

  -- ExplosionPrototype takes a full LightDefinition plus intensity and size curves, so the flash blows out and falls away on its own.
  flash = {
    -- This entity is a light and a camera shake, not artwork: its sprite is scaled to nothing (as `sustain_sprite` below) and C.blast.release, created from the control stage, carries the fireball. The old anims.big() art was untinted vanilla explosion art, outside lib/heat.lua, at the centre of a non-vanilla weapon.
    sprite    = 0.05,

    -- The flash's own length, load-bearing: an explosion's light lasts exactly as long as its animation and every light-curve field is a fraction of that length (peak_end is 0.15 of the clip). anims.big() was 47 frames at animation_speed 0.5 = 94 ticks; with the sprite held to a dot this number carries it, or the flash would be two ticks long.
    ticks     = 94,

    intensity = 1.0,
    size      = 120,

    -- Ceilings on light size (frame rate): multiplied by k.rad (up to 12), and a light is a screen-space fill, so one bigger than the ~500x280 tile viewport at full zoom-out costs full price for pixels nobody sees.
    max_light_size         = 600,
    max_sustain_light_size = 900,
    peak_end  = 0.15,    -- fraction of the animation spent at full brightness

    -- Floor on flash intensity at small yields, so a 5% shot still reads as a detonation.
    intensity_floor = 0.35,

    -- The sustained white: a light's life equals its animation (~1.6 s), too short for a detonation, so this second entity exists only for its light: a one-frame animation held for sustain_ticks with the sprite scaled to nothing.
    sustain_ticks     = 60 * 8,   -- how long the white lasts
    sustain_size      = 260,      -- light radius, tiles
    sustain_intensity = 1.0,
    sustain_peak_end  = 0.55,     -- fraction spent at FULL white before decay
    sustain_sprite    = 0.05,     -- sprite scale: this entity is a light, not art
  },

  -- The release fireball: what is at the centre when the collapse lets go (C.blast.flash above is the light and shake). The control stage creates it because the gas leaves at `kelvin x (1 + C.heat.collapse_gain)` and kelvin is what the sphere reached while charging, a function of the rate dial and hold time, not of yield, so no data-stage trigger tree can pick the colour. scripts/detonate.lua creates it on the sweep's first tick, which is the release tick.
  -- If C.blast.rings.enabled is off there is no sweep and therefore no fireball: a light with no art. That branch is already degraded (no wave, damage front or paint).
  -- The art is anims.plasma(), the mod's greyscale bake of big-explosion, frame-sequenced to hold its fireball frames: the same sheet the shock front is stamped from.
  release = {
    enabled = true,

    -- Scale against k.rad, derived so the fireball fills the fireball ring at every yield: the sheet is 197 px = 6.16 tiles at scale 1, k.rad = R / visual_divisor = R / 150, and the ring edge is C.blast.rings.fireball_u = 0.214 R, so drawn width = 6.16 x (scale x R/150) x scale_out against a target of 0.428 R. At scale 9.0 and scale_out 1.25 that is 0.462 R, within 8% of the ring at every yield because both sides are linear in R.
    -- max_scale is a sanity ceiling (the curve tops out near 120): a sprite is one blit and this entity carries no light.
    scale     = 9.0,
    max_scale = 200,

    -- Grows as it plays: an expanding fireball reads as pressure, one at full size as a placed sprite.
    scale_in  = 0.55,
    scale_out = 1.25,

    -- Ticks. Longer than the flash's ~94: this is the event, and anims.plasma spends half its sequence on bright frames.
    ticks = 150,

    -- Fireball-frame pairs anims.plasma holds; higher than the puff's 8, since one big fireball can sit in its bright frames where a ring of 900 would look frozen.
    hold = 14,

    -- White multiplier on the black-body colour (as C.blast.rings.wave.tint); opaque, as the brightest object in the event.
    tint = {r = 1.00, g = 1.00, b = 1.00, a = 1.00},
  },

  -- The mod's own flame (N.scorch_flame), laid by the arc sweep's wall of fire: base's `fire-flame` spreads up to a hundred times per seed. Same construction as `fallout`: spread_delay pushed past anything it can live to see.
  scorch = {
    -- Ticks one flame burns; the arc sweep's wall stays lethal this long (C.arc_sweep.wall.burn_ticks).
    lifetime = 12 * 60,

    damage_per_tick = 0.15,
    damage_type     = "fire",

    scale = 0.85,
    tint  = {r = 1.00, g = 0.72, b = 0.38, a = 0.85},

    fade_in_duration  = 20,
    fade_out_duration = 90,

    -- Off: one light per flame is a screen-space fill each, and a wall is many flames. The sprite still carries draw_as_glow, so only the light cast on the ground is lost.
    light_enabled = false,
    light = {intensity = 0.22, size = 6, color = {r = 1.0, g = 0.55, b = 0.2}},

    -- Every smoke spawn is a real entity, multiplied by the flame count; kept low.
    smoke_frequency = 0.05,
  },

  -- The crater stays lethal: a `fire` entity configured not to spread.
  fallout = {
    -- A `fire` entity damages roughly the tile it stands on, so scattered embers cover almost nothing. The embers are decoration; the damage lives in the cloud below, which covers area.
    damage_per_tick = 0.2,       -- ember DoT, essentially cosmetic
    damage_cloud    = 6,         -- per APPLICATION in the cloud, poison
    lifetime        = 55 * 60,   -- ticks; shared by embers and cloud
    count           = 8,         -- animated entities -- keep this low
    radius          = 45,        -- how far embers scatter

    -- The toxic cloud (vanilla's poison-cloud is radius 11 / 8 poison / cooldown 30): far wider and gentler per application, over a huge area for most of a minute. One entity per cloud.
    cloud_radius    = 42,        -- damage radius of ONE cloud
    cloud_count     = 5,         -- clouds seeded across the blast
    cloud_spread    = 55,        -- radius they are scattered over
    cloud_scale     = 6.0,
    action_cooldown = 30,        -- ticks between damage applications
  },

  -- The mushroom cloud. ExplosionPrototype supports it natively (scale_initial/scale_end/scale_increment_per_tick/height; apiq proto ExplosionPrototype): base ships 100 frames of rising mushroom art (nuke-explosion-1..4) and these fields swell it as it climbs. `height` is a screen offset, so 'up' is -Y.
  mushroom = {
    scale                    = 3.4,   -- overall size vs vanilla's nuke
    height                   = 3.0,   -- lifts the cap off the ground
    scale_initial            = 0.6,
    scale_end                = 3.0,
    scale_increment_per_tick = 0.012,
    scale_in_duration        = 40,
    scale_out_duration       = 180,
    -- The stem below it and the cap that shears downwind.
    stem_duration            = 60 * 32,
    stem_count               = 90,
    -- These two drive the smoke, the cloud you look at; it must fade with the column, not outlast it. The hovering fire is the cap EXPLOSION stretching its own animation (scale_animation_speed in prototypes/vfx): the cloud wants to be long and the fire short.
    cap_duration             = 60 * 30,
    cap_count                = 140,
  },
}

-- Control stage: targeting
C.targeting = {
  -- Manual only: no auto-acquire, sweep or AI, and no setting turns one on. Every shot was designated by a player with the remote. The scoring below is retained only to snap a remote-designated strike to something.
  enabled = false,

  enemy_forces = {"enemy"},

  -- What is worth hitting: a spawner outranks the worm beside it.
  score_spawner    = 1000,
  score_worm       = 400,
  score_other      = 100,
  -- Proximity is a tiebreak only.
  distance_penalty = 0.5,

  -- Overkill prevention: a pending strike claims this much ground (about the blast radius); nothing else targets inside it.
  overkill_radius = 30,
  -- Coarse grid for strike lookups.
  grid_size       = 32,
  -- How long a claim lasts; must exceed the shell's flight time.
  strike_ttl      = 60 * 20,
  expire_interval = 60 * 5,

  -- Search-and-destroy: the gun walks outward ring by ring.
  sweep_enabled = true,
}

-- Rendering: persistent objects are created once and recoloured on the turret's bucket tick; redrawing per tick is the expensive way to the same picture.
-- The scar radii derive from the blast's visual extent (C.blast.fans.dust.radius) so the scarring and the cloud cannot drift apart.
C.blast.scar.decorative_radius = math.floor(C.blast.fans.dust.radius)
C.blast.scar.tile_radius       = math.floor(C.blast.fans.dust.radius * 0.55)
C.blast.scar.cliff_radius      = math.floor(C.blast.fans.dust.radius * 0.45)

-- Ceilings in tiles on the scarring reach. The decorative and cliff pair also bound scripts/crater.lua's clear.
C.blast.scar.max_tile_radius       = 1000
C.blast.scar.max_decorative_radius = 1170
C.blast.scar.max_cliff_radius      = 1000

-- Fraction of the blast radius each reaches, before the ceilings above.
C.blast.scar.tile_fraction       = 0.35
C.blast.scar.decorative_fraction = 1.00
C.blast.scar.cliff_fraction      = 0.85

-- The shockwave stage's set-tile disc, cliff and decorative clearing, all on one tick engine-side. Off: scripts/crater.lua lays the same behind the front.
C.blast.scar.instant = false

-- The crater surface: Space Age's Vulcanus terrain (cracked black volcanic rock). Optional: lib/blast.lua checks data.raw and falls back to nuclear-ground without Space Age, because a set-tile naming a missing tile is a hard load error. Alternatives in the same set: volcanic-folds-flat, volcanic-cracks, volcanic-ash-dark.
C.blast.scar.tile_name = N.tiles.volcanic_folds

C.render = {
  -- The power run: a conduit ring on the concrete plus one short spur per pylon.
  bus_width       = 5.0,
  spur_width      = 4.0,
  mast_spur_width = 7.0,    -- heavier: a mast spur carries a whole cluster

  -- The ground glow, as a ring (a filled disc reads as a white pad).
  glow_width      = 3.0,
  glow_max_alpha  = 0.55,
}

-- Status lighting: state reported by light, which reads peripherally, rather than a readout that must be looked at.
--   DARK                    black                off, nothing designated
--   STANDBY                 blue, solid
--   AIM, rotating           yellow, flashing
--   AIM, ready              amber, solid         aligned AND terrain confirmed (rec.aim_aligned, rec.terrain_ready)
--   FIRE, charging          red, ramping         brightness IS the charge %
--   FIRE, lance lit         red, flashing hard   brightest the installation gets
--   COOLDOWN                orange, flashing     venting: busy, not dangerous
--   BOOT                    blue, ramping        cold start to standby level
-- The N.ground_lamp entities at every bank slot are the status light: render.lights() paints .color onto them, found by position.
C.lights = {
  enabled = true,

  -- Ticks between repaints: six is 10 Hz, fast enough to read a flash as a flash. The 30-tick bucket aliases a 2 Hz flash into a stutter.
  update_interval = 6,

  -- Per-bank charge glow: a script-drawn animation (base's accumulator-charge.png), since electric-energy-interface has no chargable_graphics. Reports this bank's fill (energy / electric_buffer_size), not the installation state.
  bank_charge = {
    enabled = true,
    -- Frames per tick: half of base's 1, since sixteen at 1 is a strobe.
    speed = 0.5,
    -- Alpha at a full bank; drawn as glow, so it stacks with the status light.
    max_alpha = 0.85,
    -- Below this fraction the object is hidden rather than drawn near-invisible (sixteen idle banks per installation).
    floor = 0.02,

    -- Flicker: plain math.random (deterministic in the control stage) jitters alpha by up to this fraction, scaled by the bank's fill so an empty bank sits dark. Not a smart light; layered on the precise fill reading.
    flicker_amount = 0.12,
  },
  -- Palette: pure hues at full value; every behaviour scales them.
  colour = {
    dark     = {r = 0.00, g = 0.00, b = 0.00},
    boot     = {r = 0.25, g = 0.55, b = 1.00},
    standby  = {r = 0.20, g = 0.48, b = 1.00},
    aim      = {r = 1.00, g = 0.82, b = 0.05},
    amber    = {r = 1.00, g = 0.55, b = 0.02},   -- AIM, ready
    charging = {r = 1.00, g = 0.11, b = 0.05},
    firing   = {r = 1.00, g = 0.20, b = 0.10},
    venting  = {r = 1.00, g = 0.55, b = 0.05},
  },

  -- Standby: solid. standby_breath and standby_period are dead knobs kept as a one-line revert (behaviour() in render.lua).
  standby_solid  = true,
  standby_level  = 0.32,
  standby_breath = 0.09,
  standby_period = 240,       -- ticks for one full breath, four seconds

  -- BOOT: ramps from nothing to standby across the cold start.
  boot_overshoot = 1.35,      -- how far past standby it peaks before settling

  -- Aim, still rotating: yellow square-wave flash.
  aim_low    = 0.30,
  aim_high   = 0.95,
  aim_period = 24,            -- ticks for one on-plus-off cycle

  -- Aim, ready: aligned and terrain-confirmed (rec.aim_aligned, rec.terrain_ready from render.preview's coverage check); solid amber.
  aim_ready_level = 0.60,

  -- Charging: linear from floor to full, so brightness is the progress bar; a shallow flicker grows with the charge.
  charge_floor   = 0.14,
  charge_ceiling = 1.00,
  charge_flicker        = 0.10,
  charge_flicker_period = 11,

  -- FIRING: held at flash_high for the whole beam sustain, not flashed.
  flash_high   = 1.30,        -- over 1.0 on purpose: the brightest the
                              -- installation ever gets

  -- Cooldown: flashing orange, slower and softer than the firing flash (firing snaps, venting pulses).
  vent_flash_period = 34,
  vent_low          = 0.22,
  vent_high         = 0.80,


  -- Brownout beat: on the strike every lamp, bank glow and the conduit ring drop to `level` for `ticks`, then slam back. Repainted on the exact edge ticks (render.brownout_step), not the 6-tick relight cadence.
  brownout = {
    enabled = true,
    ticks   = 14,
    level   = 0.04,
  },
}

-- Barrel FX: everything drawn on the barrel, as opposed to C.lights (banks and masts) and C.lamp (the ground). Geometry from scripts/beam.lua (beam.tip_distance, beam.barrel_point); render.lua owns the persistent glow object.
C.barrelfx = {
  -- Standby glow: its own rhythm, not C.lights.behaviour(), so it reads as the barrel looking alive.
  glow = {
    enabled = true,
    -- Fraction of the muzzle distance (beam.tip_distance()) back from the tip, so retuning with /oppenheimer-muzzle carries it along.
    forward_fraction = 0.55,
    color = {r = 0.35, g = 0.65, b = 1.00},
    scale = 9,
    period      = 340,   -- ticks for one slow drift, not lockstep with anything
    level_low   = 0.30,
    level_high  = 0.70,
  },
}

-- Installation FX (scripts/installfx.lua): short-lived render objects or trivial smoke, none stored; each is keyed on a timestamp the turret record already carries.
C.installfx = {
  -- Capacitor arcs: lightning pinging bank to bank while the gun charges past `threshold` (the charge fraction the ring and chase bulbs read). Mostly within a cluster; `cross_chance` jump to the nearest bank of a neighbouring cluster, never diagonally across the gun. Pings speed up and multiply with the charge.
  arcs = {
    enabled   = true,
    threshold = 0.10,
    interval_slow = 12,    -- ticks between pings at the threshold
    interval_fast = 3,     -- ...and at a full charge
    count_min = 1,         -- bolts per ping at the threshold
    count_max = 3,         -- ...and at a full charge
    cross_chance = 0.22,
    -- Bolt attachment: this far up from the entity centre, in tiles (the terminals on top of the accumulator art; the art top is ~3.6 up).
    terminal_lift   = 2.5,
    terminal_jitter = 0.45,
    segments       = 5,
    cross_segments = 9,
    jitter         = 0.16,
    ttl            = 4,
    -- Two strokes on one path: a wide violet-blue body and a thin white core. Not red: an arc channel runs 20000-30000 K and its light is nitrogen emission plus a near-white continuum (blue-white with a violet fringe); red is what a colder flame looks like.
    width      = 6,
    color      = {r = 0.55, g = 0.62, b = 1.00, a = 0.55},
    core_width = 2,
    core_color = {r = 0.92, g = 0.96, b = 1.00, a = 0.95},
    spark_light_scale     = 1.4,
    spark_light_intensity = 0.8,
  },

  -- Waste heat: the banks glow while they take charge. Resistive loss is I^2 R, so `drive` below is (charge fraction x rate fraction) squared: a 1% shot leaves the banks cold and a full-dial one has them glowing before the lance lights. The colour is the black body's through lib/heat.lua, as the lance and the sphere, several thousand kelvin lower down the same curve. Nothing is stored; each light lives `interval` ticks and is redrawn while the charge lasts.
  heat = {
    enabled = true,
    interval = 12,        -- ticks between repaints
    threshold = 0.02,     -- below this `drive`, nothing glows at all
    t_min = 1000,         -- K at threshold: dull red, and lib/heat.lua's own
                          -- floor (below ~800 K, the Draper point, nothing
                          -- glows and heat.rgb clamps anyway)
    t_max = 1700,         -- K at a full-dial shot's last seconds: orange-yellow
    light_scale     = 3.2,
    light_intensity = 0.85,
    -- Coolant boiling off the bus bars, pacing the same `drive`; reuses the barrel's vent smoke.
    steam_interval = 26,
    steam_chance   = 0.55,   -- per bank, per emission
    steam_rise     = 2.2,
    steam_jitter   = 0.9,
  },

  -- Barrel venting: steam out of the muzzle after a real shot, heavy at the cut and thinning across the vent state's own duration, so the smoke is the timer. See vent_ticks_for below; `ticks` is only the fallback if the cooldown is unreadable.
  vent = {
    enabled = true,
    ticks = 900,
    interval_start = 2,    -- ticks between puffs at the cut
    interval_end   = 14,   -- ...and at the end
    burst = 2,             -- puffs per emission at the cut, tapering to 1
    jitter = 0.35,         -- tiles of sideways scatter
    rise   = 1.4,          -- tiles of upward scatter (trivial smoke cannot move)
  },

  -- Ignition shock: on the strike a ring of dust races from the stage to the pad's rim, decelerating. A puff stamp every `stamp_spacing` tiles of travel, `puff_spacing` tiles apart around the ring (counted from the circumference so it never thins into beads), plus one front line on the ground.
  dust = {
    enabled = true,
    ticks = 34,
    stamp_spacing = 2.5,
    puff_spacing  = 2.2,
    front_width = 3,
    front_color = {r = 0.85, g = 0.78, b = 0.66, a = 0.55},
  },
}

--- Exactly the COOLDOWN state's duration, research included (the time scripts/turret.lua holds the gun in VENTING), so a vent that is still smoking is a gun that cannot fire.
function C.installfx.vent_ticks_for(force)
  return C.charge.cooldown_for(force)
end

-- Ground lamps: vanilla-style small lamps in pairs flanking the four beam lanes (C.lamp_slot_defs). They are the status light (render.lights paints them) but carry no schema or adoption tracking: found by position each repaint (lib/names.lua).
C.lamp = {
  enabled = true,

  -- Vanilla size: the turret's own 3x put an oversized fixture on a normal bank and clipped it.
  sprite_scale      = 0.5,
  base_sprite_scale = 0.5,
  tile_size   = 1,     -- for the marked-pad footprint; the collision box is
                       -- well under one tile even at 1.5x scale

  stack_size  = 50,
  max_health  = 100,   -- vanilla small-lamp's own figure; no reason to differ

  -- Placing the turret ghosts the lamp brackets with the banks and masts.
  auto_ghost     = true,
  link_tolerance = 1.5,

  -- Slots: see C.lamp_slot_defs() (static). art_half is the fixture's largest half-extent at sprite_scale 0.5 (lamp-light.png is 90 px: 90 * 0.5 / 32 / 2 = 0.70 tiles); clearance is the least bare floor accepted between fixture art and any bank's art.
  art_half  = 0.70,
  clearance = 0.25,
}

-- Resonance cells: the chamber as a gauge. The cell is the charge, condensed: the gun makes one per percent of a standard shot out of what is in the banks, and it exists only as long as the charge does.
--     0 cells    at rest (banks held at zero; the gun cannot be pre-loaded)
--    100 cells   a standard shot's worth of charge in the banks
--    150 cells   the top of the overcharge band
-- They rise with the charge ramp, fall when a hit knocks charge out of the banks, and drain with the discharge, so the chamber repeats the fire-control bar and is readable from the map. The item is `hidden`, has no recipe and is on no technology.
C.cells = {
  -- Cells per 100% of a standard shot: a percentage with the sign filed off, so '137' in the chamber needs no legend.
  per_shot = 100,

  -- Round DOWN: a chamber reading 100 must hold a full standard shot. The count lags the bar by up to one cell (1% of a shot).
}

C.logistics = {
  -- Off, and there is nothing to turn back on: the chamber fills from the grid through the banks (turret.sync_cells), and the cell is hidden and uncraftable, so reload() would search every STANDBY step for an item no logistic network holds. Kept because it is the right machinery for any future consumed item.
  auto_reload = false,
  -- Cap per pass, so one turret cannot drain a network in a tick.
  per_pass    = 5,
  -- Dead with auto_reload.
  keep_loaded = 6,
}

-- Foundation: the concrete pad the installation stands on
C.foundation = {
  enabled = true,

  -- The floor is static data, not a formula: lib/foundation_plan.lua, baked from an exported blueprint by tools/bp_to_plan.py (see its header). The real pad is hand-authored (an irregular hazard shape per bank cluster, an asymmetric lamp layout) and does not reduce to a rim/field/lane/ring rule. Regenerate the plan the same way if the pad is redesigned; C.lamp_slot_defs() is baked from the same blueprint.
  -- Every tile is a mineable base tile: the coloured refined concretes are hidden with no mining result and would outlive the gun.

  -- Margin beyond the outermost hardware before the plan's edge, in tiles. Not freely tunable: 0.5 makes C.foundation_reach() reproduce lib/foundation_plan.lua's `reach` (20) exactly (the furthest bank's art stops at 19.5). Changing corner_offset/slot_spacing/tile_size without re-baking the plan (tools/bp_to_plan.py, then clip_plan.py) desyncs the two. C.turret.exclusion_radius must stay above this reach or two installations at the closest legal spacing pour over each other.
  margin  = 0.5,

  -- 11x11 under a 9x9 gun. C.foundation.stage_radius (below) feeds the strike flash and dust ring (scripts/installfx.lua, scripts/reticle.lua) independently of the floor tiles.
  stage_half  = 5,

  -- Building is a sequence: placing the gun lays an outline, then the ghosts arrive in order (masts, banks clockwise cluster by cluster, runway lamps row by row outward), then the floor pours outward from the centre. Saved in storage.groundworks, so a save mid-pour finishes the job. Existing pads are re-laid instantly on a configuration change (control.lua).
  survey = {
    enabled = true,
    outline_ticks = 15,   -- the outline alone, before the first ghost
    mast_step     = 8,    -- ticks between masts
    bank_step     = 3,    -- ticks between banks (36 of them)
    lamp_step     = 8,    -- ticks between lamp rows (a row is all 8 at once)
    cluster_gap   = 6,    -- extra pause between clusters
    outline_color = {r = 1.00, g = 0.62, b = 0.10, a = 0.55},
    outline_width = 2,
  },
  pour = {
    enabled  = true,
    delay    = 0,     -- ticks after the last survey ghost
    ticks    = 210,   -- centre to corner; the front is linear in radius
    interval = 3,     -- one set_tiles call per this many ticks
  },
}

--- Half-width of the square pad, in tiles. The pad spans -reach..reach tile
--- offsets around the turret's own tile.
function C.foundation_reach()
  return math.ceil(C.installation_extent() + C.foundation.margin)
end

-- Placement preview: the whole pad drawn around the cursor while the turret is held. The engine stretches the sprite over a square of side 2 x distance; the pad is (2 x reach + 1) tiles centred on the gun, hence reach + 0.5. Sprite generated by tools/preview_sprite.py.
C.preview = {
  enabled = true,
  -- (2 * foundation_reach + 1) tiles at 32 px = 41 tiles. Re-run tools/preview_sprite.py whenever this changes: an image that does not cover exactly the pad lands skewed.
  sprite_px = 1312,
}
function C.preview_distance()
  return C.foundation_reach() + 0.5
end

-- The stage's inscribed circle: where the strike flash's light and the dust ring start.
C.foundation.stage_radius = C.foundation.stage_half + 0.5

--- The firing ring's radius: the conduit ring's mean-bank distance rounded to a tile. One owner: the conduit ring, survey outline, commissioning arc, chase lights and hazard ring read it.
function C.firing_ring_radius()
  return math.floor(C.pylon_bus_radius() + 0.5)
end

-- Reticle moments (scripts/reticle.lua), script-drawn only; the floor is C.foundation.
C.reticle = {
  enabled = true,

  -- Commissioning: fires once when the last bank and mast are linked (all C.pylon.max_count banks and every mast slot), not at C.pylon.count where the gun merely boots. Masts light clockwise from the upper-left, then the conduit ring draws itself around the loop.
  commission = {
    enabled = true,
    mast_step   = 12,     -- ticks between masts lighting
    arc_ticks   = 90,     -- one lap
    fade_ticks  = 40,     -- the masts' lights settling back out afterwards
    arc_half_width = 0.35,
    arc_color   = {r = 0.55, g = 0.80, b = 1.00, a = 0.90},
    mast_color  = {r = 0.45, g = 0.72, b = 1.00},
    mast_light_scale = 8,
    mast_light_intensity = 0.9,
    mast_disc_radius = 2.2,
    mast_disc_alpha  = 0.45,
    -- Unverified: which orientation draw_arc's angle 0 points at and whether a positive angle runs clockwise. It only affects when each spur appears; if spurs pop a quarter-turn early or late change zero, if mirrored flip clockwise.
    arc_zero_orientation = 0.25,   -- east
    arc_clockwise = true,
  },

  -- Aim: a dim dashed line from the gun's edge to the rim along the barrel's bearing; brightens for the convergence.
  aim_line = {
    enabled = true,
    color     = {r = 0.85, g = 0.08, b = 0.05, a = 0.45},
    hot_color = {r = 1.00, g = 0.25, b = 0.12, a = 0.90},
    width     = 2,
    dash_length = 0.6,
    gap_length  = 0.35,
    clearance = 0.5,       -- tiles past the gun's own edge
  },

  -- Charge: a storage ring. Bunches circulate the firing ring while the installation fills and are extracted into the barrel on the strike.
  --   * Speed saturates: beta = sqrt(1 - 1/gamma^2) is already 0.95 c past a couple of rest masses, so the bunches accelerate hard, then stop getting faster while charge keeps climbing.
  --   * Bunches tighten (pack_sharpness climbs with gamma) as an RF cavity compresses them.
  --   * Colour is synchrotron light: blue-white, whitening as gamma rises.
  --   * Extraction is a kicker: each bunch leaves at the extraction point (where the aim line crosses) and travels out along the beam line at the speed it already had.
  chase = {
    enabled = true,
    count  = 24,
    packs  = 3,
    -- cos^n; climbs with gamma: a cold beam is a smear, a full one three hard bunches.
    pack_sharpness     = 3,
    pack_sharpness_max = 14,
    bulb_radius = 0.32,
    -- Synchrotron: cold blue-white at injection, whiter at full energy.
    color     = {r = 0.45, g = 0.72, b = 1.00},
    hot_color = {r = 0.88, g = 0.95, b = 1.00},
    alpha_floor = 0.18,        -- a bulb between bunches, as a fraction of one
    alpha_min   = 0.35,        -- whole-ring brightness at zero charge
    alpha_max   = 1.00,        -- ...and at full
    -- Orbital rate at beta -> 1, turns per tick (one lap per 48 ticks), held just below where a 24-bulb ring reads as turning backwards (half a bulb spacing per tick).
    speed_max = 1 / 48,
    -- Lorentz factor at full charge: 12 gives beta 0.997 at the top and 0.89 by a fifth of the way in; the saturation is what is shown.
    gamma_max = 12,
    light_scale = 4,
    light_intensity = 0.7,
  },

  -- Extraction on the last lap before the strike: the kicker fires where the aim line crosses the ring and each bunch runs out along the line into the barrel.
  converge = {
    -- One full lap at speed_max plus the flight down the line: the schedule's budget (derived from the ring's geometry in scripts/reticle.lua).
    ring_ticks = 48,
    line_ticks = 14,
    fade = 0.75,   -- fraction of the run-in over which a bunch fades out
  },

  -- THE STRIKE: the stage flashes white.
  strike = {
    enabled = true,
    ticks = 40,
    alpha = 0.85,
    light_scale = 24,
    light_intensity = 1.0,
  },

  -- The stage keeps a history: one scorch per shot, oldest dropped past `max`. base's scorchmark corpses expire after ten minutes and are wiped by tile placement, so this is a script sprite of the same art.
  scorch = {
    enabled = true,
    max    = 6,
    alpha  = 0.22,
    tint   = {r = 0.20, g = 0.16, b = 0.13},
    jitter = 0.6,                          -- tiles of random offset
    render_layer = "ground-patch-higher2", -- base corpses' own final layer
    -- base's medium-scorchmark-tintable sheet: two 510x352 variations side by side, drawn at 0.5 (remnants.lua).
    sprite = {
      filename = "__base__/graphics/entity/scorchmark/medium-scorchmark-tintable.png",
      width  = 510,
      height = 352,
      scale  = 0.5,
    },
  },
}

-- Power and sound. Power values are in watts and converted per step by turret.lua; a step is C.control.update_buckets ticks apart, so treating a per-second figure as per-step is a silent 30x error. Factorio loads Ogg Vorbis only: an .mp3 silently does not play.
-- Chart view: a full-yield shot is 2000 tiles across, far past the ~500-tile viewport at full zoom-out, so the sphere, collapse and wave need a chart-mode copy. ScriptRenderMode is 'game' or 'chart', never both, so scripts/mapdraw.lua draws each twice from one call site, re-tinted (a 30%-alpha black disc is a shadow in the lit world and nothing on the chart).
C.chart_view = {
  enabled = true,

  -- Alpha runs hotter than the world copy (the chart has no lighting to fight; clamped to 1 in mapdraw).
  alpha_mult = 1.6,

  -- Pixel widths run thinner: a world-tuned stroke is the same pixel count over ~100x more ground, so a 2000-tile ring's rim would become a fat band.
  width_mult = 0.45,

  -- Below this radius, no chart copy -- at map zoom it's a sub-pixel dot.
  min_radius = 12,

  -- The same floor for lines: one arc bolt is 4-5 segments and each allocated a chart object at every interval for the whole sustain, when the entire bolt is a dot at map zoom. Measured end to end over the whole line, so the lance's own map line (thousands of tiles) never trips it.
  min_length = 24,

  -- The lance on the map: the beam is `beam` entities (lib/beam.lua) and charting an entity has no runtime lever, so the map gets a purpose-drawn line: one draw_line per tick, chart mode only, from the muzzle's GROUND projection (the real muzzle is lifted up the tower, C.beam.muzzle_lift_mult, which is wrong on a map with no height) to the impact point.
  beam = {
    enabled = true,
    color = {r = 1.00, g = 0.15, b = 0.10, a = 0.95},   -- the world beam's red, opaque for the map
    width = 3,   -- pixels, tuned for the map directly (not run through width_mult)
  },
}

C.sound = {
  -- The installation's interface voices (sound/ui-*.ogg, tools/make_ui_sounds.py). Every chat line the mod prints goes through audio.notify with the engine's own console ping switched off, so a burst of messages is one soft voice at most every min_gap ticks per kind instead of a ping per line.
  ui = {
    volume        = 0.7,    -- notify voices, against the file's own level
    button_volume = 0.8,    -- style click sounds
    min_gap       = 12,     -- ticks between two voices of one kind for one force
    -- Ticks a force-wide line is deduplicated for (turret.say). Every installation
    -- announces its own state changes and a battery reaches them one gun at a
    -- time across a bucket cycle (C.control.update_buckets), so this is comfortably
    -- longer than one: the first line of a burst is heard and the repeats are not.
    battery_gap   = 90,
    -- Message key (oppenheimer.<key>) -> voice: notice | ok | alert | arm | silent. Anything unlisted is `notice`. A toggle's own click already sounds, so its confirmation line is silent; a refusal is `alert`.
    say = {
      online = "ok", restored = "ok", vented = "ok",
      release = "arm", ["alpha-fired"] = "arm",
      dark = "alert", stalled = "alert", ["alpha-partial"] = "alert",
      ["no-turret"] = "alert", ["no-turret-detail"] = "alert", ["still-slewing"] = "alert",
      ["fire-refused"] = "alert", ["out-of-range"] = "alert", ["need-banks"] = "alert",
      ["all-busy"] = "alert", ["target-inside-blast"] = "alert", ["target-too-close"] = "alert",
      ["arc-sweep-refused"] = "alert", ["capacity-full"] = "alert",
      ["blueprint-missing-pylons"] = "alert",
      booting = "silent", ["rate-set"] = "silent",
      ["alpha-lapsed"] = "silent",
      ["hud-on"] = "silent", ["hud-off"] = "silent", ["hud-empty"] = "silent",
    },
  },

  -- How this weapon is heard: world sounds (`surface.play_sound`) mix against the camera and attenuate on zoom-out or drop in map view, which is wrong for a blast watched from the map. scripts/audio.lua plays broadcast sounds globally (LuaPlayer.play_sound with no `position`) with the falloff curve below, computed from real distance. audible_distance_modifier is dead for anything routed through audio.broadcast; keep_positional restores the old path.
  broadcast = {
    enabled = true,

    full_distance = 400,    -- tiles, full volume inside this

    -- Zero volume here: above the largest possible crater (C.yield.saturation.max_radius), so a full-yield shot is audible anywhere inside its own blast.
    max_distance = 4000,

    -- Falloff shape: above 1 holds loud and drops late; below 1 drops immediately and trails.
    curve = 1.8,

    volume = 1.0,   -- master gain on everything broadcast

    -- Also play the located sound. Off: with both on, a nearby player hears a positioned copy and a global one.
    keep_positional = false,

    -- Volume mixer. The firing sounds are `category = "weapon"` and the 2.0.77 spec says a SoundType decides mixing as well as which slider governs it -- zoom level effects among them -- so a weapon-category sound is still zoom-mixed when played with no position. 'game-effect' takes the whole broadcast out of that mix, at the cost of moving it off the player's weapon/explosion sliders. nil restores per-sound categories.
    override_sound_type = "game-effect",
  },

  -- THE JOIN RULE FOR EVERY CHAINED CLIP HERE. Two play_sound calls cannot be aligned to the sample: there is no sub-tick scheduling and no seek. So neighbours share NO audio -- each is a butt cut, the outgoing fades out over `join` ticks, the incoming fades in over its own first `join`, and the Lua starts it `join` ticks early. Equal power, because the two streams are different moments of the same drone and sum in power. Overlapping the SAME audio instead reconstructs the source exactly at zero relative delay and comb-filters at every other delay, which is a level cliff: measured -3.1 dB at 2 ms of slip against -0.8 dB for this scheme at a full tick.
  -- Each join therefore COSTS `join` ticks of timeline. That is why discharge_at is derived below and not typed.
  join_ticks = 4,

  -- Arc sweep: sound/ArcSweep.ogg is a single mix (source copy assets-src/.../ArcSweep-user-mix.ogg) of charge, fire and discharge, played once, whole, at confirm. 327 ticks, audible to tick 318 (tools/oggdur.py). oggdur cannot find transients inside a flat Vorbis profile, so where charge ends and fire begins is set by ear: 1.6 s of charge, ~3.65 s of fire, then the discharge tail fading under its own envelope.
  -- arc_sweep_charge_ticks is what the barrel does during the first 1.6 s: it rotates from where it was aimed to the sweep's starting bearing, landing as the fire portion begins. arc_sweep_strike_ticks is where the hyper-rotation and vaporization happen. Nothing plays or holds for the tail. The strike figure was trimmed by ear against the mix; re-measure by ear if the clip is replaced.
  arc_sweep_audible_ticks = 318,
  arc_sweep_charge_ticks  = 96,    -- 1.6 s: barrel rotates to start bearing
  arc_sweep_strike_ticks  = 189,   -- 3.15 s: hyper-rotation + vaporize + wall

  -- Where the lance lights in assets-src CompleteSequence.ogg, and so how long the spin-up is. The mixer's own edit point, not a figure found by analysis: the beam element starts on 15.400 s and swells from there, so there is no transient to detect and nothing to snap to. A cut that misses it shows up as the lance lighting before or after its own sound.
  charge_source_ticks = 924,

  -- A broadcast sound has its volume baked in at trigger time (scripts/audio.lua header) and cannot be stopped or seeked, so one call at CONFIRM would play the climax at a distance computed 16 s or more earlier and let an abort play out a strike that never fired. Splitting lets the strike's distance be recomputed when it happens and bounds an abort's leftover to the charge portion.
  charge_volume   = 1.0,
  charge_distance = 3,
  -- Its own knob: the strike is the payoff, worth erring loud on independent of the spin-up mix.
  strike_volume   = 1.0,
  strike_distance = 3,

  -- The spin-up is cut into `charge_parts` equal pieces (tools/split_sequence.py), each gated behind its own 'is this turret still in FIRE' check (turret.lua fire_tick), so an abort lets only the piece already playing run out. Joined by the rule at the top of this block; must match the splitter.
  -- MUST divide charge_source_ticks exactly, and match both
  -- tools/split_sequence.py's PARTS and the length of lib/names.lua's
  -- N.sound.charge. Granularity of a shortened charge is one segment: the gun
  -- plays the LAST k pieces so the whine always ends on the bang, so the more
  -- pieces there are the more closely the audio follows a fast grid -- paid for
  -- in one join per piece (join_ticks out of the timeline each).
  charge_parts         = 12,
  charge_segment_ticks = 77,    -- charge_source_ticks / charge_parts, integer

  -- THE BURN, ONE UNCUT PIECE (tools/split_sequence.py), 15.400 s to 26.500 s of the mix. Nothing can interrupt it -- scrub() refuses once rec.discharged is set -- so there is no abort to bound and no reason to chain it out of smaller ones. It runs at level to its own last sample and hands straight to the detonation, so its audible end IS its length. Every shot burns this long whatever the yield: the tape is the clock.
  strike_ticks = 666,

  -- THE SPIN-DOWN, 26.500 s to the end of the mix (tools/split_sequence.py): the spin-up run backwards, played once at the cut when the lance stops outputting. C.charge.cooldown_ticks is floored on it, so the gun is never ready while this is still audible.
  -- NAMING, and it matters in this file: the changelog calls this the DISCHARGE sound, the code does not. `discharge()` is where the gun FIRES and `C.sound.discharge_at` is the ignition tick -- 15 seconds before this plays.
  spindown_ticks    = 898,
  spindown_audible  = 857,
  spindown_volume   = 1.0,
  spindown_distance = 3,

  -- The fire wave's voice. Volume only; frequency is its own sound_interval.
  sear_volume = 0.8,
  -- The lightning's thunder prototypes; each strike's own level volume applies on top (C.beam.sphere.lightning.volume).
  thunder_volume = 0.6,

  -- Standby hum: a working_sound on the turret prototype (not a scripted play_sound), so the engine loops, positions and fades it. Merged with the charge whine as a second `main_sounds` entry (a prototype has one working_sound key); see prototypes/entity.lua. ambient_sounds re-triggers with an audible ~0.5 s gap instead of looping.
  hum_volume      = 0.65,
  hum_distance    = 1.4,

  -- Dead: working_sound/MainSound has no radius field, reach is audible_distance_modifier alone.
  hum_radius      = 40,

  -- Dead: a barrel report over BeamFire.ogg's own strike muddied the frame that has to land clean.
  fire_volume     = 1.0,
  fire_distance   = 6,

  -- The detonation's boom, broadcast: N.ex_boom carries its own near-field `sound`; this carries it to someone watching from the map, where a world sound is silent. Cannot exceed 1.0 (play_sound's volume_modifier is engine-clamped); the file is the lever.
  boom_volume     = 1.0,
  -- Energy-based volume: a played sound cannot be trimmed, so a 1% pop and a 100% crater play the same clip; thunder() in scripts/detonate.lua scales loudness instead: floor + (1-floor) * min(1, variant_fraction^exponent), so a 1% shot still lands at boom_volume_floor.
  boom_volume_floor    = 0.35,
  boom_volume_exponent = 0.5,   -- < 1: even a modest shot climbs toward full fast
  -- Thunder arrives per listener at real distance / boom_speed ticks after the flash. 5.7 tiles/tick = 343 m/s, with a tile as a metre.
  boom_speed      = 343 / 60,
  boom_delay_min  = 8,      -- floor: even ground zero isn't literally instant
  boom_delay_max  = 240,    -- ceiling: past this the sound has no event left to belong to
  boom_distance   = 4500,   -- its own reach, beyond the broadcast default
}

--- Ticks a played segment ADVANCES the sequence: its own length less the join its successor eats into. Not its file length.
function C.sound.charge_advance()
  return C.sound.charge_segment_ticks - C.sound.join_ticks
end

--- The tick (since turret.release(), i.e. rec.state_since) at which the `seg`-th PLAYED slot starts, one join early so its fade-in covers its predecessor's fade-out. The audio side is tools/split_sequence.py; the two must agree.
-- Independent of how many segments this shot plays: every segment is the same length whatever slot it sits in, so slot j always starts j-1 advances in. Compression moves WHICH file plays in each slot (charge_sound_index), never when.
function C.sound.charge_trigger_tick(seg)
  return C.sound.charge_advance() * (seg - 1)
end

--- THE COMPRESSED CHARGE WINDOW, in ticks, for a shot playing `segs` segments. Exact: the last slot's own length is not shortened by a join it has no successor for.
function C.sound.charge_window_ticks(segs)
  local parts = C.sound.charge_parts
  local k = math.max(1, math.min(parts, segs or parts))
  return C.sound.charge_advance() * k + C.sound.join_ticks
end

--- Which of CHARGE_SOUNDS the `j`-th played slot holds when only `segs` are played: the LAST `segs` of them, so a compressed charge starts already spun up and still ends on the same climax under the strike.
function C.sound.charge_sound_index(j, segs)
  local parts = C.sound.charge_parts
  local k = math.max(1, math.min(parts, segs or parts))
  return parts - k + j
end

--- THE IGNITION TICK, since turret.release(). Derived, not typed: every join eats its own length out of the timeline, so a typed figure and the audio drift apart (see charge_source_ticks). Must be set before C.charge_window() is first called below.
C.sound.discharge_at = C.sound.charge_window_ticks(C.sound.charge_parts)

--- Total length of a firing sequence: the compressed charge window plus the burn. Only the spin-up varies -- it is what a strong grid has been waiting through; the burn is one uncut piece and the same length at every yield.
function C.sound.sequence_ticks_for(segs)
  return C.sound.charge_window_ticks(segs) + C.sound.strike_ticks
end

-- The lance: created by script between two points for a number of ticks; no flare, no projectile flight, no scatter.
--   t = 0s       CONFIRM: banks stop draining, fill toward the ordered yield
--   t = 14.3s    IGNITION: two beam entities created muzzle-to-aim-point, held
--   t = 14.3s-end SUSTAIN: path scours; impact point takes escalating hits
--   at the end  CUT: beams destroyed, staged detonation fires at the landing
-- Two beam entities because desired_segment_length belongs to a graphics set, not a layer, so a wide soft halo and a thin hot core cannot share one prototype (lib/beam.lua).
C.beam = {
  -- Geometry. scale_mult is a multiple of the base game's laser beam (art at 0.5, one tile per segment); lib/beam.lua derives the segment length from it so the sprite cannot tile wrong. Sprite geometry cannot be checked statically, so every change is an in-game checklist item. Colour is not set here: both layers take the black-body colour of the lance's temperature (C.heat, lib/heat.lua), additive blend.
  core = {
    scale_mult   = 48.0,    -- scale 24.0: a 48-tile segment, ~8.9 tiles thick
    -- BeamPrototype::width is SIMULATION GEOMETRY, NOT ART: it sits with action / damage_interval / random_target_offset / target_offset, and graphics_set alone decides what is drawn (layer scale plus desired_segment_length). It is undocumented in the 2.0.77 spec, and scaling it with the sprite gave a 2000-tile lance a swept box of 100000+ tiles, every tick, on an entity carrying no action at all. 1.0 puts it at base laser-beam's own 0.5. The mod's damage width is C.beam_half_width(), off scale_mult, and is untouched by this.
    width_mult   = 1.0,
    ground_mult  = 13.5,    -- the pool of light on the ground. Deliberately far
                            -- below the halo: this art is a 256 px disc and at
                            -- halo scale it is a puddle dragging under the beam.
    blend        = "additive",
  },
  halo = {
    scale_mult   = 108.0,   -- scale 54.0: a 108-tile segment, ~20 tiles thick
    width_mult   = 1.0,     -- see core.width_mult
    ground_mult  = nil,     -- none. See core.ground_mult.
    blend        = "additive-soft",
  },

  -- The beam is built once per selectable yield, since a prototype's scale is data-stage: a 25% shot must not fire a full-width lance with a quarter-size crater. Fraction of full size at zero yield, rising to 1.0 at the top of the selector; a small shot is thinner, not invisible.
  scale_floor = 0.45,

  -- Beam width follows the energy delivered, in steps this fine, decoupled from C.charge.yield_targets (the detonation's 8 coarse steps). The lance is built every width_step (plus the 1% floor) and a shot picks the nearest to what the banks delivered, so an order the grid could not fill fires a thinner lance.
  width_step = 0.05,
  -- Above visual_cap the lance keeps thickening across the battery's band (C.charge.group_cap), in steps this coarse: one prototype per FINE step up to 1000% would be 200 widths x the heat ladder x two layers. At 1.00 the ladder is 30 steps, 600 beam prototypes.
  width_step_coarse = 1.00,

  -- Lance thickness at the top of the dial, as a multiple of the 100% lance (C.beam_size). The halo is ~20 tiles thick at 100%, so this is a ~52 tile channel at the ceiling. C.beam_half_width derives the vaporize lane from the same number, so what burns is still what looks like it burns.
  overpower_scale_max      = 2.6,
  overpower_scale_exponent = 0.6,

  -- THE BLOOM: what an overpowered channel looks like once the black-body locus has run out (C.heat.t_max). Additive white drawn along the live lance every tick with a two-tick life, so there is no render object to own, migrate or leak. Scales without bound on the overpower band because it costs a fixed handful of sprites, not prototypes.
  bloom = {
    enabled = true,
    -- Width and alpha at the top of the dial; 1.0 at the knee means an unovercharged shot draws nothing at all.
    width_max = 2.2,      -- x core thickness
    alpha_max = 0.85,
    exponent  = 0.7,
    segments  = 14,
    overlap   = 2.6,
    color     = {r = 1.00, g = 0.97, b = 0.92},
    -- The muzzle flare, same curve, drawn as one light at the beam source.
    muzzle_scale_max = 4.0,
    render_layer = "higher-object-above",
  },

  -- WHERE THE DRAWN CHANNEL STARTS, in tiles past the muzzle. ART ONLY -- the damage origin is beam.muzzle_ground and never moves, so what the lance scours is unchanged. An overpressure channel is C.beam_half_width() x C.beam_size() across (~52 tiles at the top of the dial against ~20 at the knee) and its near end is drawn over the installation, banks and all; the standoff grows with the channel's own half-width and is zero at and below C.charge.visual_cap, so a standard shot still leaves the barrel exactly where it was tuned to (muzzle_forward_mult).
  draw_standoff = {
    -- Tiles of standoff per tile of half-width the shot carries ABOVE the knee. At 1.0 the top of the dial stands off ~16 tiles, which is about the bank ring (C.pylon.corner_offset).
    per_tile_over_knee = 1.0,
    max = 48,
  },

  -- The beam stops at the ball, not through it: the ball is opaque, so the endpoint retreats toward the muzzle as the ball grows, ending on its near face.
  -- The endpoint moves every tick with LuaEntity.set_beam_source/set_beam_target (2.0.77, LuaEntity|MapPosition; methods, not attributes). The entity is rebuilt only when its heat step changes, because the tint is baked into the prototype.
  retarget = {
    enabled = true,

    -- Fallback cadence only, used if set_beam_target fails (scripts/beam.lua POINT_OK latch): rebuild once the endpoint has moved this fraction of the ball's FINAL radius. Final, not current: gating on the current radius makes steps geometric, dozens of rebuilds while the ball is tiny and almost none at the end, which read as teleporting.
    step_fraction = 0.035,
    -- Floor in tiles, so a 30 tile blast still gets a handful of steps.
    step_min = 2.0,

    -- Extra tiles short of the rim: landing exactly on the circle puts the beam's end-sprite half inside the fill.
    surface_gap = 1.5,

    -- Never shorten past this fraction of the muzzle-to-target run: at full yield the ball's radius exceeds the firing range and an unclamped endpoint would invert the beam.
    min_length_fraction = 0.06,
  },

  -- The charging sphere. While the lance burns, a sphere builds at the impact point, growing for the whole sustain and destroying everything inside it continuously; when the beam cuts, it lets go. Drawn at the radius it kills at, so what you see is what dies.
  sphere = {
    enabled = true,

    -- Radius in tiles at the end of the sustain at 100% yield: dead as an input (see radius_fraction), kept as a record.
    max_radius = 70,
    min_radius = 2,   -- radius at ignition, so it starts as a point

    -- Fraction of the shot's real blast radius: at 1.0 the sphere grows to exactly the radius the rings reach. The cap sits above the dial's ceiling as a guard against a mistuned yield model.
    radius_fraction = 1.00,
    -- Clears C.yield.saturation.max_radius, so this stays the guard it was meant to be and never becomes the real ceiling.
    radius_cap      = 3200,

    -- The fire wave, in the inner tenth of the ball: one fire dose per victim as the front reaches them. Coupled to the ball's growth. No visuals (anything drawn inside an opaque ball is paid for and never seen); heard instead (N.sound.sear). Inside the fireball ring, so it changes when things die, not whether. Same friendly-fire interlock as the lance (C.beam.path.spares_friendly).
    fire = {
      enabled = true,
      radius_fraction = 0.10,
      -- x C.blast.dose.lethal_dose, not payload: payload is the dose at the fireball ring's edge, which thermal makes ~29x a lethal dose, so a share of it would silently buff this stage 12x.
      dose = 0.583,           -- x lethal_dose (was 0.25 x a 60000 payload)
      damage_type = "fire",
      types = {"unit", "unit-spawner", "turret", "spider-unit", "segmented-unit",
               "car", "spider-vehicle", "character"},
      bucket_tiles = 2,
      lead = 24,
      budget = 400,           -- entities per tick
      -- How far out this front will build ground, in tiles; 0 = never build, search and pay whatever exists (opts.generate_to in front.advance; nil there means build everywhere).
      -- Must not be nil: the front rides radius_fraction of a ball that grows to the whole blast, so what it builds scales with the dial -- ~123 chunks at 2000 tiles and ~3070 at the 10000-tile cap, the bulk of it past rings.generate_ahead_radius (360) and so ground nothing else in the shot would have built at all.
      -- Declining costs no damage: an ungenerated chunk holds no entities, this whole footprint lies inside the fireball ring (rings.fireball_u) where the wave destroys outright, and scripts/scar.lua pays a chunk generated later at that dose. It also keeps a blocking flush out of the sustain, which is the one phase with a sound clock bolted to it.
      generate_to = 0,
      sound_interval = 24,
      sound_volume = 0.9,
    },

    -- What the growth phase spends its budget on: the ball's fill is opaque, so anything drawn inside the current radius is never seen. Only four surfaces exist during the sustain: the rim (crossing new ground), above the ball (smoke, tall sprites), outside it, and the footprint (revealed when it retreats).
    -- 1. Infall, outside the rim. Off with the collapse's set (C.blast.implosion.streaks): both share one implementation, so they switch together or the streaks appear on the frame the beam cuts.
    streaks = {
      enabled = false,
      -- Fewer than the collapse's 56: growth is longer than the collapse, so the same count would read busier.
      count   = 34,

      -- Multiples of the current radius, above 1 so they are outside the ball.
      reach_min = 1.06,
      reach_max = 2.10,

      -- Length as a fraction of current radius (tidal elongation, as the collapse's).
      length_fraction = 0.14,
      length_min      = 3,

      width = 4,
      color = {r = 0.55, g = 0.75, b = 1.00, a = 0.42},   -- cooler/dimmer than the collapse's

      -- The leading tip (implode.draw_streaks_at), cooler and dimmer than the collapse's.
      head_color       = {r = 0.82, g = 0.90, b = 1.00, a = 0.85},
      head_radius_frac = 0.30,
      head_radius_min  = 0.5,
    },

    -- 2. Footprint paint: none. The ground changes with the wave only.

    -- 3. Lightning off the rim (scripts/lightning.lua). Strikes come at random bearings after exponential gaps. Each rolls a level, min_level..max_level, weighted ratio^(level - min_level), and the level sets its reach, branching, chain, dose and thunder (sound/ThunderLevel<NN>.ogg, tools/make_thunder.py).
    lightning = {
      enabled = true,
      min_level = 2,
      max_level = 10,
      min_radius = 6,            -- tiles; a smaller ball throws nothing
      root_inset = 1.0,          -- tiles inside the rim where a channel leaves the ball

      -- Strikes per second: rate_base, plus one per rim_tiles_per_rate tiles of circumference, capped at rate_max.
      rate_base = 1.875,
      rim_tiles_per_rate = 1000,
      rate_max = 4.5,
      gap_min = 20,              -- ticks between two flashes, so two cracks never land together
      -- After a strike the next waits hold_fraction of its thunder's loud window, capped at hold_max ticks.
      hold_fraction = 0.08,
      hold_max = 100,
      -- Share of strikes placed on rim a player can see (view.arcs); the rest land anywhere on it.
      watched_share = 0.75,

      -- The level roll's ratio climbs from calm to wild with sustain progress (weight wild_sustain) and the overpower band (weight wild_overpower).
      ratio_calm = 0.72,
      ratio_wild = 1.08,
      wild_sustain = 0.6,
      wild_overpower = 0.6,
      overpower_exponent = 0.7,
      dose_overpower_max = 2.0,

      -- Per-level ranges: lo at min_level, hi at max_level, eased by exp (above 1 keeps the low levels low). C.lightning_level evaluates them.
      reach        = {lo = 12,   hi = 110,  exp = 1.2},   -- tiles past the rim a strike lands
      seek         = {lo = 5,    hi = 18,   exp = 1.0},   -- tiles around the landing point searched for a target
      targets      = {lo = 1,    hi = 16,   exp = 1.3},   -- victims in the chain, the first included
      jump         = {lo = 6,    hi = 22,   exp = 1.0},   -- tiles per chain hop
      fork_chance  = {lo = 0,    hi = 0.45, exp = 1.0},   -- chance a hop splits in two
      forks        = {lo = 1,    hi = 9,    exp = 1.0},   -- dead branches off the main channel
      strokes      = {lo = 1,    hi = 5,    exp = 1.0},   -- return strokes down the same channel
      stroke_ticks = {lo = 16,   hi = 40,   exp = 1.0},   -- how long the main channel burns
      scale        = {lo = 0.45, hi = 1.3,  exp = 1.0},   -- main channel sprite scale; the tesla art is authored at 0.5
      branch_scale = {lo = 0.35, hi = 0.8,  exp = 1.0},   -- hops and dead branches
      impact_scale = {lo = 0.35, hi = 1.2,  exp = 1.0},
      streamer_scale = {lo = 0.35, hi = 0.75, exp = 1.0}, -- ground streamers at the strike and at every hop
      light_size   = {lo = 12,   hi = 72,   exp = 1.2},   -- tiles across, the flash at the strike
      dose         = {lo = 0.3,  hi = 3.0,  exp = 1.5},   -- x C.blast.dose.lethal_dose, first victim
      volume       = {lo = 0.75, hi = 1.0,  exp = 1.0},
      hear         = {lo = 350,  hi = 1500, exp = 1.0},   -- tiles, the thunder falls silent here
      hear_full    = {lo = 60,   hi = 300,  exp = 1.0},   -- tiles, full volume inside this

      -- A smaller ball throws shorter strikes: reach x clamp(sqrt(radius / reach_ref_radius), reach_floor, 1).
      reach_ref_radius = 150,
      reach_floor = 0.4,
      slant = 0.55,              -- radians a strike may lean off the radial
      reach_min_share = 0.4,     -- a strike lands between this share of its reach and all of it
      -- Landing points tried per strike, as multiples of the planned distance past the rim (capped at the reach); the first with a target wins.
      probes = {1.0, 0.55, 1.35},
      probe_limit = 12,          -- entities per search
      hop_falloff = 0.85,        -- share of the dose each hop carries on
      jump_delay = 3,            -- ticks between hops
      hop_ticks = 18,            -- how long a hop's arc burns
      fork_life = 0.6,           -- a dead branch burns this share of stroke_ticks
      restroke_gap_min = 3,      -- ticks between return strokes
      restroke_gap_max = 7,
      restroke_ticks = 5,
      leader_min = 8,            -- ticks of leader before the flash, at least
      segment_tiles = 7,         -- main channel segment length
      segments_min = 3,
      segments_max = 10,
      jitter = 0.45,             -- vertex offset, x segment length
      bow = 0.12,                -- whole-channel bend, x channel length
      fork_reach = {min = 0.25, max = 0.55},   -- dead branch length, x channel length
      fork_angle = {min = 0.35, max = 0.95},   -- radians off the channel
      fork_segments_max = 3,
      damage_type = "electric",
      -- Everything a bolt can land on; spared() in scripts/beam.lua still protects the firing force's buildings.
      types = {"unit", "spider-unit", "segmented-unit", "character", "car", "spider-vehicle", "unit-spawner", "turret"},

      -- Thunder. At most max_voices loud windows play at once; a strike past that sounds at masked_volume unless it outranks every level already rolling. Thunder started in the last duck_ticks of the sustain falls toward duck_floor at the cut, under the detonation.
      max_voices = 3,
      masked_volume = 0.4,
      duck_ticks = 180,
      duck_floor = 0.55,
      -- tools/make_thunder.py output, per level: lead = ticks from the file's start to its crack, loud = end of its loud window, ticks = length. The Lua starts a thunder `lead` ticks before its flash.
      thunder = {
        [2] = {lead = 25, loud = 285, ticks = 760},
        [3] = {lead = 36, loud = 76, ticks = 221},
        [4] = {lead = 51, loud = 670, ticks = 821},
        [5] = {lead = 3, loud = 118, ticks = 909},
        [6] = {lead = 42, loud = 133, ticks = 669},
        [7] = {lead = 8, loud = 193, ticks = 275},
        [8] = {lead = 6, loud = 286, ticks = 667},
        [9] = {lead = 5, loud = 136, ticks = 209},
        [10] = {lead = 7, loud = 1315, ticks = 1475},
      },

      -- The leader: a dim channel crawling out toward the landing point until the flash, met over its last streamer_share by a streamer rising from the ground.
      leader_color = {r = 0.55, g = 0.62, b = 1.00, a = 0.55},
      leader_width = 2,
      leader_light = {intensity = 0.5, tiles = 8},
      streamer_share = 0.3,
      streamer_reach = 0.5,      -- of the channel's last segment
      restroke_light = 0.75,     -- a return stroke's flash, x the first stroke's
      flash_tiles = 4,           -- radius of the drawn impact flash at impact_scale 1
      -- Without Space Age the channel is drawn: a wide halo under a hot core.
      halo_color = {r = 0.45, g = 0.55, b = 1.00, a = 0.35},
      core_color = {r = 0.90, g = 0.95, b = 1.00, a = 1.00},
      halo_width = 10,
      core_width = 3,
      light_color = {r = 0.55, g = 0.65, b = 1.00},
      ground_tint = {r = 0.20, g = 0.28, b = 0.60},   -- the channel's light on the ground
      light_sprite_tiles = 9.375,   -- utility/light_medium across at scale 1, in tiles
      -- The impact's light over its 36-tick life: full at once, dark by peak_end of it, shrinking to size_final.
      impact_light = {intensity = 1.0, peak_end = 0.15, size_final = 0.5},

      -- Screen shake from from_level up; ranges run min_level..max_level.
      camera = {
        from_level = 7,
        duration = 18,             -- ticks
        ease_in = 2,
        full_distance = 20,        -- tiles at full strength
        strength     = {lo = 0.3, hi = 1.1, exp = 1.0},
        max_distance = {lo = 60,  hi = 180, exp = 1.0},
      },

      -- Space Age only: a cloud-to-ground bolt from from_level up, its strike landing on the flash. Ranges run from_level..max_level.
      sky = {
        enabled = true,
        from_level = 8,
        time_to_damage = 8,        -- ticks from execute_lightning to its strike
        effect_duration = {lo = 36,    hi = 56,   exp = 1.0},
        bolt_half_width = {lo = 0.04,  hi = 0.07, exp = 1.0},
        light_size      = {lo = 50,    hi = 90,   exp = 1.0},
        height          = {lo = 25,    hi = 34,   exp = 1.0},   -- tiles above the strike the bolt falls from
        variance = {30, 6},        -- tiles the bolt's top wanders, x and y
        damage = 0,
        energy = "1000MJ",
        light_intensity = 5,
        light_color = {r = 0.10, g = 0.15, b = 1.00},
        cloud_tint = {r = 0.5, g = 0.5, b = 0.5, a = 0.5},
        -- LightningGraphicsSet figures, Space Age's own storm lightning.
        look = {
          relative_cloud_fork_length = 0.30,
          cloud_fork_orientation_variance = 0.2,
          cloud_detail_level = 4,
          bolt_detail_level = 5,
          bolt_midpoint_variance = 0.05,
          max_bolt_offset = 0.25,
          max_fork_probability = 1,
          fork_intensity_multiplier = 0.5,
          min_ground_streamer_distance = 2,
          max_ground_streamer_distance = 4,
          ground_streamer_variance = 4,
          shader_configuration = {
            {color = {0.0, 0.6, 1, 0.8}, distortion = 0.20, thickness = 0.20, power = 0.25},
            {color = {0.0, 0.6, 1, 1.0}, distortion = 0.40, thickness = 1.00, power = 0.25},
            {color = {0.2, 0.6, 1, 1.0}, distortion = 0.55, thickness = 1.00, power = 0.25},
            {color = {0.7, 0.6, 1, 0.6}, distortion = 0.70, thickness = 0.75, power = 0.25},
            {color = {0.4, 0.2, 1, 0.3}, distortion = 1.00, thickness = 0.50, power = 0.10},
            {color = {0.0, 0.2, 1, 0.0}, distortion = 20.00, thickness = 0.50, power = 0.01},
          },
        },
      },
    },

    -- 4. The taunt: gameplay, not decoration. Units inside and just outside the ball are ordered to walk into it, turning the sustain into a trap. Off by default: it changes balance, not just picture. Budgeted hard against the pathfinder (a fixed command count per application, each unit commanded once via unit_number). Worms, spawners, players and vehicles cannot be commanded.
    taunt = {
      enabled = false,

      interval = 30,
      budget   = 40,       -- commands/application -- the knob if the pathfinder stutters
      max_total = 600,     -- per shot, so a long sustain can't creep past intent

      -- Search radius as a multiple of the ball's current radius, above 1 because units inside are dying anyway.
      reach = 1.45,

      -- Not zero: a thousand units pathing to one tile jams the pathfinder.
      arrive_radius = 8,

      -- A string, not defines.*: config.lua loads in the settings and data stages, where `defines` does not exist (scripts/beam.lua maps it). 'none' makes it a taunt: units ignore being shot at on the way in.
      distraction = "none",
    },

    -- Radius travel from min to max across the sustain; above 1 it starts slow and accelerates, as if driven by the beam.
    growth_exponent = 1.6,
    -- Fastest the ball may swell toward a raised target, as a fraction of its full radius per tick. A lance joining mid-burn raises the target at once; this turns the jump into a swell. Must exceed growth_exponent / sustain_ticks (0.0026) or it throttles ordinary growth.
    swell_rate = 0.01,

    -- Shell and fill, redrawn every tick with a two-tick life: no render object to persist, migrate or leak. A ball of ionized energy: nearly black interior (optically thick matter reads as a surface), high alpha, and a thin searing blue-white rim. Blue-white rather than red because that is how an electrical discharge reads (as C.beam.sphere.lightning); the lance beam itself (C.beam.core/halo) stays red as the installation's charge/fire lighting.
    shell_color = {r = 0.58, g = 0.78, b = 1.00, a = 1.00},   -- searing rim
    fill_color  = {r = 0.02, g = 0.03, b = 0.10, a = 0.88},   -- ~#05081A, opaque
    shell_width = 10,
  },

  -- max_length passed to create_entity: the beam destroys itself if source and target end up further apart. A multiple of gun range so a full-range shot cannot trip it.
  max_length_factor = 3.0,

  -- The lance is a chain of short beam entities (scripts/lance.lua): a beam the length of a shot costs hundreds of milliseconds to create or destroy, and its tint is baked into the prototype, so a heat step is a rebuild. A span exists only within C.perf.view.radius (plus its own art) of a world-view player. Changing `enabled` needs a game restart (it decides which prototypes are built); false is one beam per lance.
  spans = {
    enabled = true,
    -- Tiles per interior span, at every yield.
    length  = 256,
    -- The tip span is at least this many halo segments long, room for the end cap's head, body and tail.
    min_span_segments = 2.2,
    -- Per tick, shared by every lance, at most one of each per lance: spans built as they come into view (muzzle outward), visible spans rebuilt at a new heat step, spans dropped out of view.
    create_per_tick   = 4,
    recolour_per_tick = 3,
    cull_per_tick     = 2,
    -- Tiles past the build distance before a span is dropped, so a player at the edge does not rebuild it every few ticks.
    keep_margin = 128,
  },

  -- Where the beam starts, in tiles beyond the muzzle, along the FIRING BEARING rather than the barrel's actual orientation, so a stuck barrel (storage.no_orientation) is a cosmetic fault, not a weapon that cannot fire. Only the clearance past C.muzzle_distance(). Tuned live with /oppenheimer-muzzle against this turret's scaled geometry (laser-turret's 1.31439-tile source_offset at ~3x shift_ratio plus tower_lift).
  muzzle_forward_mult = 0.6,
  muzzle_lift_mult    = 1.1,
  muzzle_clear = 0,

  -- 'cut' detonates at the end of the sustain (beam vanishes, mushroom cloud starts the same frame); 'ignite' detonates at the strike with the beam sustaining through the fireball.
  detonate_at = "cut",

  -- CONVERGENCE. A lance igniting within `radius` of a live strike joins it: its power is added to the strike's total, it aims at the strike's centre and it ends on the strike's cut tick, so every beam goes out and the sphere collapses together. One sphere, one set of fronts, one detonation, however many installations fired; a second sphere would multiply every per-tick cost in the sustain.
  -- The group's radius still saturates (C.yield.saturation), so four converging full-yield lances dig one 3000-tile crater at four times the pressure, not a 6000-tile one.
  convergence = {
    enabled = true,
    -- Tiles between aim points that count as the same strike.
    radius = 96,
    -- A strike with less burn than this left cannot be joined; the lance opens its own instead.
    join_min_ticks = 60,
    -- Bonus overpower for firing together, on top of the summed power: 1 + gain x (lances - 1).
    gain_per_lance = 0.6,
    -- Installations that may share one strike, and so the battery's real size. Must be at least C.charge.group_cap / the dial's own ceiling (1.00) or the group can never reach that cap.
    max_lances     = 10,
  },

  -- What the beam does to what it crosses: a shell arrives at a point, a beam is a line, and everything on it is in the weapon.
  path = {
    enabled = true,

    -- Safety interlock: true ignores anything on a force the installation is not at war with, except characters: a player in the beam is vaporized whatever their force. False fires across your own factory as it does at the nest.
    spares_friendly = true,

    -- Tiles either side of the centre line that count as under the beam, derived from the halo (C.beam_half_width).
    half_width_mult = 1.0,

    -- THE SCORCH MARGIN: extra lane width on the overpower band, on top of what the thicker lance already buys through C.beam_size. Search cost is length x width, linear, so this is the one kill area in the mod that may grow with power. A full-dial lance ploughs a ~130 tile furrow from muzzle to target.
    overpower_lane_max      = 1.5,
    overpower_lane_exponent = 0.8,

    -- Ticks between two reads of the same ground by the watch (scripts/beam.lua): a behemoth biter (0.3 tiles/tick) gets at most 1.8 tiles into a lane before it dies.
    interval = 6,

    -- Ticks a new or widened lane's clearing search is spread over, muzzle outward.
    sweep_ticks = 30,

    -- Height in tiles of the rows a lane's clearing search is cut into, one search per row. Lower trims the ground searched past a diagonal lane's edges; higher makes fewer searches.
    row = 8,

    -- Anything under the beam dies: die(), not damage(), so no health pool or resistance saves it. False falls back to damage_per_application.
    vaporize = true,

    damage_per_application = 3000,   -- only when vaporize is false, scaled by yield fraction
    damage_type = "laser",

    -- Trees and rocks (a lane carved through a forest is the point), Space Age pentapods and demolishers, and military buildings (spared on your own force by the interlock).
    types = {"unit", "unit-spawner", "turret", "spider-unit", "segmented-unit",
             "tree", "simple-entity", "car", "spider-vehicle", "character",
             "wall", "gate", "ammo-turret", "electric-turret", "fluid-turret"},
  },

  -- The far end during the sustain: escalating hits where the beam lands, so it builds toward the detonation.
  contact = {
    enabled  = true,
    interval = 24,          -- ten over the sustain
    sequence = {"shockwave", "fireball", "cluster"},   -- cycled, so the impact visibly escalates
    spread   = 3.0,         -- tiles ACROSS the beam, so it isn't one flickering sprite
    -- How far back toward the muzzle a hit may land, as a multiple of spread (scripts/beam.lua contact); forward would be under the ball's fill.
    pull_back = 0.6,
  },

  -- THE SHUTDOWN. At the cut the lance stops delivering -- no scour, no contact, no stages, the ball stops growing -- but it stays lit and cools for this long before it goes out and the ball implodes. The spin-down clip starts at the same tick, so this is the fade that clip is already playing: `ticks` is clamped to its audible length at the bottom of this file.
  -- It delays the detonation by its own length; the sequence itself is not lengthened.
  winddown = {
    enabled = true,
    ticks   = 240,

    -- Temperature at the end, as a fraction of what the lance was burning at. The heat step walks down with it, so the colour cools through the black-body ladder to ember instead of the beam blinking out.
    heat_floor = 0.0,

    -- Shape of the cool-down over the window: k = (1 - u)^heat_exponent. ABOVE 1 drops fast and early then lingers near dark (1.6 reached a third of the burn temperature by u = 0.5), BELOW 1 holds the colour and falls off at the end. Under 1 across this window so the beam is still visibly easing when the collapse takes over, rather than dark for its last third.
    heat_exponent = 0.8,

    -- The bloom and the muzzle light are additive white with no temperature of their own, so they take an explicit fade over the same window.
    glow_exponent = 1.0,

    -- THE STABILIZATION. The ball holds the radius it reached while the beam eases out, and a radius that is simply constant for four seconds renders as a frozen frame. The drive has stopped, so the boundary rings and damps to still: drawn at r x (1 + amplitude x e^(-decay u) x sin(2 pi cycles u)). Cosmetic only -- g.sphere_r is untouched, so the collapse still starts from the real radius.
    settle = {
      enabled   = true,
      amplitude = 0.012,   -- fraction of the held radius, at the cut
      cycles    = 3,       -- ring-downs across the window
      decay     = 4.0,     -- e-folds across it: still by about u = 0.6
    },
  },

  -- Muzzle
  muzzle_flash = true,   -- base artillery's own muzzle flash, referenced by name

  -- Light at the barrel for the whole sustain. `scale` is rendering.draw_light's scale (a multiplier on 'utility/light_medium'), not LightDefinition.size (C.turret.light): a different unit.
  muzzle_light = {intensity = 0.9, scale = 6,
                  color = {r = 1.00, g = 0.30, b = 0.20}},
}

-- The arc sweep: an additional capability, not a mode of C.beam and not routed through the charge/discharge/FIRE sequence (scripts/arcsweep.lua header). Off by default per installation (rec.arc_sweep_mode, toggled in the HUD in scripts/gui.lua); on, every press on that installation is sweep idiom. Drag marks a span (an AIM, previewed on the map; re-drag to re-aim); pressing near the span's centre CONFIRMS. A short charge-up plays, then the barrel hyper-rotates in one sweep across the span holding the same lance, vaporizing and scattering fire. No sphere, staged detonation or crater.
C.arc_sweep = {
  enabled = true,

  -- Below this drag diagonal (tiles) a press is too small to mark a span and is refused.
  min_drag = 15.0,

  -- How long a recorded mouse-down stays usable as where the drag started (scripts/remote.lua, N.drag_input); must outlast a slow drag across the map.
  drag_memory_ticks = 600,

  -- Multiplier on the vaporize half-width the main beam's lane derives (C.beam_half_width() * C.beam_size(variant); arcsweep.lua refresh()): 1.0 is exactly what the main beam would hit at the same dial setting.
  width_mult = 1.0,

  -- OVERPOWER (C.overpower). A sweep bills an ANNULUS, R x width, never R^2, which is what makes it the right place for a terawatt to go: the same energy that would buy 11x the disc area buys 3x the lane and 2.2x the arc for a linear price. The rotation stays audio-locked, so a wider span simply rotates faster.
  overpower = {
    -- The drawn span, extended outward from its own midpoint. The player marks
    -- where they want the line; the surplus overshoots both ends of it.
    span_max  = 2.2,
    fires_max = 2.5,    -- wall density along it
    exponent  = 0.7,
    -- NO WIDTH KNOB HERE. The lane comes through C.beam_half_width(omega) and
    -- C.beam_size like the main beam's, so one derivation decides how wide a
    -- lance burns and the sweep cannot drift from the shot at the same dial.
    -- NO PASS COUNT EITHER: the sweep vaporizes outright, so a second pass over
    -- the same ground has nothing left to kill. Span is what buys more.
  },

  -- The rotation is audio-locked, not rate-driven (the gun's clock belongs to the sound file): the whole hyper-rotation takes exactly sustain_ticks, derived at the bottom of this file from sound/ArcSweep.ogg's measured length, so barrel and sound start and finish together. A typical 90-180 degree drag works out to roughly 3-8x C.turret.slew_speed.

  -- The charge-up is the first 1.6 s of sound/ArcSweep.ogg itself (see C.sound.arc_sweep_charge_ticks). The clip plays once, at confirm. This flag only gates the mechanical charge phase in arcsweep.lua step(): the barrel rotating from its bearing to the sweep's starting bearing over arc_sweep_charge_ticks instead of snapping. ArcSweepCharge.ogg and its sound prototype stay on disk unreferenced.
  charge = {
    enabled = true,
  },

  -- How often, in ticks, the sweep pays for the ground it has crossed: the vaporized wedge between the last paid bearing and the current one, plus the stretch of wall that bearing traced. The wedge is the swept triangle, so billing every 6 ticks kills what billing every tick would, for a sixth of the searches. The lance itself is re-pointed every tick (set_beam_target via beam.point in scripts/beam.lua), so raising this coarsens the damage grain only. The name is historical (it once governed beam rebuilds).
  retarget_interval = 6,

  -- Not paid from the capacitor banks: standby's power_tick drains the banks to ~0 every tick and this capability only fires from STANDBY, so a charge gate would never pass. A plain per-turret cooldown prevents spamming without fighting the main power model.
  cooldown_ticks = 180,   -- 3 seconds

  -- Vaporized outright (die(), not damage()), with the main beam's path.vaporize interlock: a force this installation is not at war with is spared unless it is a character.
  spares_friendly = true,
  types = {"unit", "unit-spawner", "turret", "spider-unit", "segmented-unit",
           "tree", "simple-entity", "car", "spider-vehicle", "character",
           "wall", "gate", "ammo-turret", "electric-turret", "fluid-turret"},

  -- The wall of fire: laid only on the span the player drew, never along the beam's path from the muzzle, which crosses the installation itself. The beam ends on that span (arcsweep.lua refresh); as its end point travels along it, the stretch crossed catches fire and turns lethal: anything within spread + kill_pad dies, including anything that walks in afterwards, until the fire burns out. N.scorch_flame is the mod's own non-spreading fire (base's fire-flame spreads 100x).
  wall = {
    enabled = true,
    -- Density along the span. A 100-tile drag is ~250 flames.
    fires_per_tile = 2.5,
    -- Ceiling for one wall, however long the drag -- density thins past it.
    max_fires = 1500,
    -- Perpendicular jitter off the span, tiles: the wall's thickness is 2x.
    spread = 2.5,
    -- Kill half-width = spread + kill_pad: a little wider than the flames, so nothing slips through a gap.
    kill_pad = 0.5,
    -- How often a standing wall re-checks for anything inside it.
    kill_interval = 10,
    -- burn_ticks is DERIVED below (the scorch flame's own lifetime).
  },

  -- Marked-span preview: drawn from the moment a drag marks a span until it is confirmed or re-aimed, in world and chart (scripts/mapdraw.lua). A different colour from the beam's red so a marked span is never mistaken for a live sweep.
  aim_color = {r = 0.35, g = 0.85, b = 1.00, a = 0.85},
  aim_draw_width = 4,
}

-- Heat: the colour of the lance and the sphere from the energy put into them. A hot body's temperature climbs while more energy goes in than it radiates, and a black body radiates as T^4 (Stefan-Boltzmann). With theta = T / t_ref (t_ref: where a 100% shot settles) and p = power / 100%:
--     d(theta)/dt = (p - theta^4) / tau        (lib/heat.lua advance)
-- so the settled temperature goes as p^(1/4) and tau is the body's heat capacity. A 100% lance crosses red, orange and white in its first second and burns blue-white; a 1-5% shot never passes red-orange. Colour follows temperature through the black-body curve (lib/heat.lua rgb), so the top end is white with a blue cast: no black body is pure blue.
-- A beam's tint is data-stage, so the lance is built at `steps` temperatures and rebuilt as the heat crosses into the next, spaced evenly in mired (1e6 / K), where a colour-temperature change looks equally big anywhere.
C.heat = {
  t_ref = 30000,   -- K a 100% shot settles at: a lightning channel's peak
  t_min = 1000,    -- K floor: below ~800 K (the Draper point) nothing glows
  -- Top of the built ladder, and the top of heat.rgb's black-body fit. An overpowered channel keeps heating past t_ref and there is real colour left between the two, so the ladder runs to here and the rungs above t_ref are the overpower ones.
  t_max = 40000,
  steps = 10,
  overpower_steps = 3,

  -- Temperature multiplier at the top of the dial (C.overpower_gain). The locus runs out before the energy does: past t_max the extra shows up as C.beam.bloom, not as a new hue.
  overpower_t_max      = 40000 / 30000,
  overpower_t_exponent = 0.5,

  -- Brightness of a temperature, as opposed to its colour (heat.rgb is the real black-body locus, untuned): lib/heat.lua `glow` = clamp((T / glow_ref) ^ glow_exponent, glow_floor, 1).
  -- The physical exponent is 4 and it is unusable: the shock wall spans ~48000 K to ~2200 K, 22000:1 at the fourth power, so the outer nine tenths of the blast, most of what anyone watches, would render black. The eye is roughly logarithmic and this composites additively over a lit scene, so the curve is flattened and floored. 0.7 keeps a full shot's wall at 1.00 / 0.56 / 0.21 across fireball edge / half radius / rim.
  glow_ref      = 20000,
  glow_exponent = 0.7,
  glow_floor    = 0.15,

  tau_beam = 60,     -- ticks: the thin plasma channel heats fast
  tau_ball = 150,    -- ticks: the sphere carries far more mass, lags the lance
  tau_sweep = 60,    -- the arc sweep's lance, same channel as the main one

  -- An incandescent core over-exposes toward white; the halo carries the hue.
  core_whiten = 0.45,
  core_alpha  = 1.00,
  core_light_alpha = 1.00,
  halo_alpha  = 0.55,
  halo_light_alpha = 0.45,

  -- The sphere: its rim is the black-body colour; the dark fill glows toward it
  -- as it heats (up to fill_glow of the way), and the shading layers follow.
  ball_fill_glow = 0.55,
  ball_shade_mix = 0.70,
  -- The collapse compresses the same energy into a shrinking ball, so it keeps
  -- heating: temperature at full compression = the ball's temperature at the
  -- cut x (1 + collapse_gain).
  collapse_gain = 0.60,

  -- The crater floor as a body (scripts/groundfire.lua, scripts/crater.lua). The front heats the ground to a peak by the shock wall's own law (C.blast.rings.groundfire.kelvin: t_melt x dose, capped at t_boil). Outside the fireball ring that heat is a skin about skin_mm deep, which conduction drains into the cold rock below within seconds. Under the fireball, molten ejecta falls back as a glaze held at t_boil while the fireball stands on it (heat.glaze_start), then cooled as `cooling` says: a slab of rock radiating off its top and conducting into the ground beneath, freezing through its latent heat.
  ground = {
    -- K at the fused-rock contour (melt_ring): Trinity's sand melted into glass at about 1470 C, the least it saw (Wikipedia "Trinitite", citing the CDC LAHDRA report).
    t_melt = 1743,
    -- The law ring at t_melt; derived into melt_u (fraction of R) at the bottom of this file.
    melt_ring = "heavy",
    melt_u = 0.301,
    -- K ceiling: silica boils at 3220 K (Wikipedia "Silicon dioxide"; other sources give as low as ~2500 K). Energy past it boils the surface off rather than heating it.
    t_boil = 3220,
    -- K of the ground before the blast.
    ambient = 300,
    -- K below which rock stops glowing: the Draper point.
    draper = 798,
    -- m^2/s, the rock's thermal diffusivity: k / (rho c) for basalt, 2 / (2700 x 1000).
    diffusivity = 7.4e-7,
    -- mm the flash heats outside the fireball ring: sqrt(pi x diffusivity x t) for a pulse of about a second.
    skin_mm = 1,
    -- The glaze: glaze_mm thick at the fireball ring's edge for a glaze_kt device (Trinity's was 1-2 cm at about 22 kt; Wikipedia "Trinitite"), scaled as yield ^ glaze_exponent: the melt goes as the yield and the fireball's footprint as yield ^ 0.8 (Glasstone and Dolan 2.127: radius as W ^ 0.4).
    glaze_mm = 15,
    glaze_kt = 22,
    glaze_exponent = 0.2,
    -- Fraction the glaze thickens toward ground zero, where the most ejecta falls back.
    bowl = 0.5,
    -- Glaze thickness varies +/- this fraction from patch to patch, so the glow dies out unevenly instead of in rings.
    patch_spread = 0.2,
    -- tools/make_cooling.py: seconds after the fireball lifts at which a glaze h_mm thick cools its SURFACE through each kelvin, and when the whole layer has frozen (solid). Basalt, 2700 kg/m^3, 1000 J/(kg K), 2 W/(m K), 400 kJ/kg latent, emissivity 0.9, still air. Re-run it if t_melt, t_boil or ambient move.
    cooling = {
      h_mm   = {0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128},
      kelvin = {3000, 2500, 2000, 1743, 1500, 1250, 1000, 900, 798},
      t = {
        {0.007517, 0.02276, 0.04984, 0.08606, 0.1692, 0.2589, 0.4691, 0.635, 0.9154},
        {0.01469, 0.07157, 0.1637, 0.274, 0.5702, 0.8696, 1.57, 2.119, 3.041},
        {0.01855, 0.1948, 0.4909, 0.81, 1.789, 2.718, 4.881, 6.563, 9.36},
        {0.02143, 0.4012, 1.334, 2.225, 5.254, 7.932, 14.16, 18.94, 26.8},
        {0.04286, 0.4813, 3.146, 5.616, 14.53, 21.91, 38.83, 51.66, 72.4},
        {0.05357, 0.4812, 5.367, 12.82, 29.38, 59.06, 103.7, 137.1, 190.2},
        {0.05357, 0.4812, 5.596, 20.66, 59.44, 141.3, 269.8, 354.6, 487.2},
        {0.05357, 0.4812, 5.596, 21.33, 92.2, 269.2, 683.1, 895.9, 1221},
        {0.05357, 0.4812, 5.596, 21.33, 95.46, 432.5, 1370, 2172, 3008},
        {0.05357, 0.4812, 5.596, 21.33, 95.46, 457, 2356, 3943, 6555},
      },
      solid  = {0.1357, 0.4563, 1.447, 4.406, 13.48, 43.6, 148.2, 521.5, 1884, 6946},
    },
  },

  -- The ionisation channel during the charge: purely visual, the air along the line of fire breaking down before the lance arrives. Four phases on the charge's own 0..1 progress (the audio clock):
  --   LEADER     0..leader_end: a faint channel steps out from a muzzle corona, a bright tip at each step
  --   GLOW       the channel builds; brightness crawls along it (travelling sine flicker per segment) with thin re-rolling streamer filaments
  --   CONSTRICT  constrict_from..1: the channel pinches from width_mult to constrict_mult x the lance core, brightening and whitening
  --   HANDOFF    at ignition a flash fills the lance's width and decays over flash.tau while the channel fades and diffuses outward under the live beam
  -- Pale violet-blue (excited nitrogen, not a black body). Widths are multiples of the lance core's thickness at this shot's yield. Drawn with N.sprite.ion_glow; colours go out premultiplied and `occlude` is the fraction of alpha kept (0 = pure additive, 1 = ordinary over-blend). In-game tuning item.
  haze = {
    enabled       = true,
    color         = {r = 0.55, g = 0.60, b = 1.00},
    hot_color     = {r = 0.88, g = 0.90, b = 1.00},
    alpha         = 0.30,
    occlude       = 0.10,
    fade_exponent = 1.5,    -- channel alpha x progress^this
    segments      = 18,     -- soft sprites along the full channel
    overlap       = 2.5,    -- each sprite's length / segment spacing
    width_mult    = 1.6,    -- channel width x core thickness, before constriction
    render_layer  = "higher-object-above",

    -- PRE-IONIZATION, the charge's whole job: a stepped leader walks a conducting
    -- channel out to the target, the return stroke lights it, and the column then
    -- burns until the lance follows it down. Phases are fractions of the charge
    -- window, which is fixed, so the sequence lands identically on every shot.
    leader_end    = 0.35,
    leader_steps  = 12,
    tip_alpha     = 0.55,
    tip_mult      = 0.9,    -- tip glow diameter x core thickness

    -- Dead forks off the advancing leader. Most of a real leader's branches die;
    -- that is the whole visual signature.
    fork = {
      enabled   = true,
      interval  = 4,      -- ticks between rolls
      count     = 3,
      segs      = 5,
      length    = 0.16,   -- x the distance the leader has covered
      spread    = 0.30,   -- sideways wander x the fork's own length
      width     = 0.5,    -- x core thickness
      alpha     = 0.45,
      back      = 0.25,   -- how far behind the tip they may root, x reach
    },

    -- THE RETURN STROKE: on contact a bright front runs target -> muzzle. Sits
    -- in the charge window immediately after leader_end.
    stroke = {
      enabled    = true,
      span       = 0.018,  -- fraction of the charge window it occupies
      head       = 0.10,   -- lit fraction of the channel around the front
      width_mult = 2.6,    -- x the channel's width at its brightest
      alpha      = 0.95,
      light      = {intensity = 1.1, scale = 6.0},
    },

    -- The struck column: a buoyant plasma channel does not hang straight.
    column = {
      enabled       = true,
      sag_fraction  = 0.004,  -- x channel length, peaking mid-span
      sag_max       = 24,     -- tiles
      wander        = 0.45,   -- x the sag, as a slow lateral drift
      wander_period = 47,     -- ticks per radian
      lights        = 8,      -- draw_light points spaced along the run
      light_intensity = 0.45,
      light_scale     = 3.5,
    },

    -- The channel on the map. A 3000-tile charge is off-screen in the world.
    chart = {
      enabled = true,
      color   = {r = 0.55, g = 0.62, b = 1.00, a = 0.55},
      width   = 2.5,
    },

    corona_alpha  = 0.45,
    corona_mult   = 1.4,
    corona_light  = {intensity = 0.8, scale = 3.0},

    flicker        = 0.35,  -- +/- fraction of alpha
    flicker_period = 5,     -- ticks per radian of the slow component

    filament_from     = 0.20,
    filaments         = 3,
    filament_segs     = 14,
    filament_interval = 3,    -- ticks each streamer shape holds
    filament_spread   = 0.45, -- sideways wander x channel width
    filament_width    = 0.12, -- x core thickness
    filament_alpha    = 0.35,

    constrict_from  = 0.80,
    constrict_mult  = 0.55,
    constrict_gain  = 1.2,    -- extra alpha fraction at full constriction

    flash = {
      alpha      = 0.9,
      width_mult = 1.1,
      color      = {r = 0.95, g = 0.95, b = 1.00},
      tau        = 6,     -- ticks, e-folding decay
      ticks      = 30,
      lights     = 6,     -- draw_light points along the channel
      light_scale = 4.0,
    },
    afterglow = {
      tau    = 18,        -- ticks
      ticks  = 75,
      spread = 1.5,       -- width grows by this fraction over `ticks`
    },
  },
}

-- Preparation stage (scripts/prepare.lua): the first CONFIRM generates the whole blast disc as a circle walked out from the epicentre, deliberately slowly: a trickle the background generator absorbs, never the one-tick flood that once ground UPS to ~5 FPS. At 3 chunks/tick a full-dial disc (~12,000 chunks) takes a few minutes if nothing exists yet; explored ground verifies in seconds. Not a lock: the second CONFIRM fires regardless and says how far preparation got.
-- Fire-control panel (scripts/gui.lua): a row is three short lines: state and toggles, the dial with FIRE/ABORT, then the charge telemetry with a live power graph. The graph is columns of `sprite` elements whose height is written per refresh; a GUI has no chart widget and a sprite cannot be tinted at runtime, so the four levels are four tinted sprite prototypes (prototypes/style.lua). Samples come from turret.power_sample, one per refresh, so `samples x refresh_ticks` is the window shown.
C.hud = {
  -- The panel's refresh in ticks; also the graph's sample interval (one bar per refresh).
  refresh_ticks = 15,

  graph = {
    samples   = 60,    -- 60 x 15 ticks = 15 s of history
    bar_px    = 3,
    height_px = 22,
    -- A bar this far below the scale (the rate ordered, or standby when idle) is a grid not keeping up and reads amber/red rather than blue.
    warm_at   = 0.66,
    cold_at   = 0.90,
  },
}

C.prepare = {
  -- Base rate of new chunk generation requests per tick; the real number is C.prepare.rate() (the runtime-global setting N.setting.prep_rate) and this is only the fallback for a control stage that cannot see `settings`.
  requests_per_tick = 8,    -- new chunk generation requests per tick, at most
  -- Never more requested-but-unbuilt than this, scaled off the rate (C.prepare.pending()): the generator runs in the background and a queue that is too short starves it.
  pending_per_request = 8,
  max_pending       = 24,   -- floor; see pending()
  verify_per_tick   = 128,  -- generated chunks the progress cursor may pass per tick
  scan_per_tick     = 512,  -- ring cells examined per cursor move (skips outside the circle)
  margin_tiles      = 32,   -- beyond the blast radius
}

--- Chunk requests per tick, from the player's map setting. Read per call because a runtime-global setting can change in a running save. `settings.global` does not exist in the data stage; this is only called from the control stage, so the nil guard is the honest answer rather than a load-order bet.
function C.prepare.rate()
  local s = settings and settings.global and settings.global[N.setting.prep_rate]
  local v = s and s.value or C.prepare.requests_per_tick
  if v < 1 then v = 1 end
  return v
end

--- How many requested-but-unbuilt chunks to keep outstanding: the depth of the generator's asynchronous queue, not a safety limit (too short and it idles between requests).
function C.prepare.pending()
  local p = C.prepare.rate() * C.prepare.pending_per_request
  if p < C.prepare.max_pending then p = C.prepare.max_pending end
  return p
end

C.power = {
  -- Two knobs: standby_draw (what the installation takes, flat, forever) and max_shot (the biggest single shot). The tap runs at four times what the biggest shot needs, so filling is not the constraint; the ramp in turret.power_tick is, and the grid sees the same flat 250 MW idle or charging.
  -- The rate is the weapon: the player types a charge rate and shot = rate x the charge window follows, with no separate yield selector. Enforced through electric_buffer_size (writable on ElectricEnergyInterface, unlike input_flow_limit): at rest it is one tick of standby_draw, emptied every tick; while charging it is the ramp ceiling, rising at the ordered rate and never drained; dark or venting it is zero.

  -- 250 MW continuous (rotation, optics, coolant): what a lit gun costs before it is asked to do anything, split sixteen ways at a full build.
  standby_draw = 250 * 1000000,    -- W


  -- What 100% means: the player's whole grid, deliberately. 36 GJ/s across C.charge_window() is the reference trigger, which the chain reaction (C.yield) turns into the reference yield. Firing at 100% is a decision about the base. Rescales the whole weapon in one number.
  reference_rate = 36 * 1000000000,   -- W

  -- Panel bounds, derived below as fractions of reference_rate (a fraction is what the panel shows). Ceiling = reference_rate x C.charge.overcharge_max. Floor = 1% = a 5.8 GJ trigger = a 30-tile crater.
  min_fraction     = 0.01,
  min_rate         = 360 * 1000000,        -- W, OVERWRITTEN below

  -- Fresh-build default: modest, so a new installation does not brown out the base before the player has learned the dial.
  default_fraction = 0.10,
  default_rate     = 3600 * 1000000,       -- W, OVERWRITTEN below

  -- The drop-down's rungs, as fractions of reference_rate (not typed watts, which go stale when the reference moves). Roughly one per doubling; the panel labels each by its power, so these are the values a player reads. 1.00 is the FULL rung. The 2% and 35% rungs are the ones that are not a yield step (C.charge.yield_targets) or a whole quarter of FULL.
  -- The ceiling (C.charge.overcharge_max) is appended below as the MAX rung; a typed rung at or above it is dropped.
  rate_preset_fractions = {0.01, 0.02, 0.05, 0.10, 0.25, 0.35, 0.50, 0.75, 1.00,
                           1.50, 2.00, 3.00, 4.00, 5.00},
  rate_presets          = {},              -- BUILT below

  -- max_shot is derived at the bottom: max_rate x the window, what the banks must be able to hold.

  -- Headroom on the bucket: total buffer = max_shot x this, split across max_count banks. Not 1.0: a bank holding exactly its share of a full-yield charge is one the charge asymptotes into, parking the gauge short of the top tier. Also clamps what pylon.set_buffer accepts per bank, so bank count still decides the ceiling.
  buffer_headroom = 1.25,

  -- input_flow_limit sits above the highest ramp increment, or the fixed flow limit becomes the real meter instead of the buffer. It is per bank, so ordering more than the banks can pull stalls the shot rather than being refused.
  flow_headroom = 1.05,

  -- Draw is metered explicitly (turret.power_tick stops emptying the banks to charge) rather than modelled as ElectricEnergySource.drain, which continuously empties the entity's own buffer and cannot be switched off.

  -- How far below expected intake an installation may run before DARK, measured over a bucket step (banks are held at zero at rest, so one unlucky tick would black out a healthy gun).
  brownout_fraction = 0.6,
  boot_ticks   = 60 * 12,          -- how long a cold start takes


  -- Recovery needs a higher bar than the one that triggered DARK (paid < brownout_fraction -> DARK, paid >= restart_fraction -> STANDBY); the gap is the hysteresis.
  restart_fraction = 0.90,

  -- Charge is muzzle energy: a partially spooled shot lands short along the firing bearing, at this fraction of the designated distance at zero charge, rising to 1.0 at full. 1.00 means the round always lands where aimed; an under-delivered shot is punished by detonating at the yield actually paid for.
  reach_floor  = 1.00,
}

--- Joules the grid must deliver per joule that stays banked, at an instantaneous
--- draw of `drawn_w` against an order of `ordered_w`. 1.0 at or below the order.
-- Applied per tick against a MEASURED draw, never a predicted one, so a charge
-- whose intake varies is taxed on what each tick actually cost.

-- A STAIRCASE, NOT A SLAM. Each step opens the banks wider than the last and measures what arrives; the first step the grid cannot meet IS the ceiling and the survey closes there. So it never asks for more than the grid has already proved it can give plus one increment, which is what stops an instrument from browning out the base it is measuring.
C.survey = {
  enabled = true,

  -- Ticks per step: long enough for the electric network to settle on the new ceiling, short enough that the one unmet step is a fifth of a second of overdraw.
  step_ticks   = 12,
  settle_ticks = 2,      -- not counted, so a step is not billed against the previous ceiling

  -- The staircase, as a multiple of the previous step. Starts at standby_draw and stops at max_rate.
  step_mult = 1.7,
  max_steps = 16,

  -- A step counts as MET at this fraction of what it asked for. Below it, the survey closes on the last met step.
  accept_fraction = 0.92,

  -- A step is closed early, unmet, once this many ticks have been counted and the grid is delivering under this fraction of the ask: the rest of the step would only be overdraw.
  reject_after    = 3,
  reject_fraction = 0.5,

  -- Ticks a result stays good; re-run when the order changes or this expires, so a grid that grew since is noticed.
  ttl = 60 * 60 * 2,

  -- One clack per step, the load bank switching in.
  sound_volume = 0.55,
}

C.control = {
  -- Turrets are bucketed by unit_number % update_buckets, each bucket on its own on_nth_tick, so a turret's per-step charge is multiplied by this rather than applied per tick.
  update_buckets = 30,

  -- Redraw interval for the /oppenheimer-muzzle tuning marker.
  muzzle_marker_interval = 12,

  -- Safety net for blueprint pastes that land pylons before their turret; slow on purpose, and if it does real work every run something upstream is broken.
  resweep_interval = 60 * 30,
}

-- Research
-- N.tech.artillery sits past base artillery and costs a little more than the atomic bomb in either mode; prototypes/technology.lua picks the tier by mods["space-age"].
C.tech = {
  vanilla = {
    prerequisites = {"artillery", "atomic-bomb"},
    count = 6000,
    time  = 60,
    ingredients = {
      {"automation-science-pack", 1},
      {"logistic-science-pack",   1},
      {"chemical-science-pack",   1},
      {"military-science-pack",   1},
      {"production-science-pack", 1},
      {"utility-science-pack",    1},
    },
  },
  space_age = {
    prerequisites = {"artillery", "electromagnetic-science-pack"},
    count = 4000,
    time  = 60,
    ingredients = {
      {"automation-science-pack",      1},
      {"logistic-science-pack",        1},
      {"chemical-science-pack",        1},
      {"military-science-pack",        1},
      {"utility-science-pack",         1},
      {"space-science-pack",           1},
      {"metallurgic-science-pack",     1},
      {"electromagnetic-science-pack", 1},
    },
  },
  -- N.tech.capacity: one more installation per level, same packs as the tier above. capacity_levels is derived at the bottom of this file from C.beam.convergence.max_lances.
  capacity_count_formula = "L*2000",
  capacity_time = 60,
  capacity_levels = nil,
}

-- Recipes
C.remote = {
  stack_size = 1,      -- structurally stack-1 (only-in-cursor capsule)
}

C.recipe = {
  -- #57 DONE: reads like an infrastructure project, not a turret.
  turret = {
    energy_required = 120,
    ingredients = {
      {type = "item", name = "steel-plate",       amount = 400},
      {type = "item", name = "concrete",          amount = 400},
      {type = "item", name = "iron-gear-wheel",   amount = 250},
      {type = "item", name = "processing-unit",   amount = 100},
      {type = "item", name = "electric-engine-unit", amount = 60},
    },
  },
  shell = {
    energy_required = 15,
    ingredients = {
      {type = "item", name = "explosive-cannon-shell", amount = 4},
      {type = "item", name = "radar",                  amount = 1},
      {type = "item", name = "explosives",             amount = 8},
    },
  },
  -- The standard bank.
  pylon = {
    energy_required = 20,
    ingredients = {
      {type = "item", name = "steel-plate",      amount = 40},
      {type = "item", name = "concrete",         amount = 40},
      {type = "item", name = "battery",          amount = 40},
      {type = "item", name = "advanced-circuit", amount = 20},
    },
  },

  -- The mast, priced against a vanilla substation times the ground it covers: it carries a cluster and chains to its neighbours.
  substation = {
    energy_required = 25,
    ingredients = {
      {type = "item", name = "steel-plate",      amount = 30},
      {type = "item", name = "concrete",         amount = 50},
      {type = "item", name = "copper-cable",     amount = 40},
      {type = "item", name = "advanced-circuit", amount = 10},
    },
  },

  -- Purely decorative, deliberately cheap.
  lamp = {
    energy_required = 2,
    ingredients = {
      {type = "item", name = "iron-plate", amount = 5},
      {type = "item", name = "iron-stick", amount = 1},
    },
  },

  -- Replaces the entries above under Space Age: the gun needs Vulcanus, the banks Fulgora. MUST stay data-stage only; these items exist only with Space Age.
  space_age = {
    turret = {
      energy_required = 120,
      ingredients = {
        {type = "item", name = "tungsten-plate",       amount = 200},
        {type = "item", name = "refined-concrete",     amount = 400},
        {type = "item", name = "iron-gear-wheel",      amount = 250},
        {type = "item", name = "processing-unit",      amount = 100},
        {type = "item", name = "electric-engine-unit", amount = 60},
      },
    },
    pylon = {
      energy_required = 20,
      ingredients = {
        {type = "item", name = "steel-plate",      amount = 40},
        {type = "item", name = "concrete",         amount = 40},
        {type = "item", name = "battery",          amount = 30},
        {type = "item", name = "supercapacitor",   amount = 5},
        {type = "item", name = "advanced-circuit", amount = 20},
      },
    },
  },
}

--- The recipe table for `key`, the Space Age tier when that mod is loaded. Data stage only.
function C.recipe_for(key)
  local sa = mods["space-age"] and C.recipe.space_age[key]
  return sa or C.recipe[key]
end

-- Derived power geometry. The installation draws standby_draw flat, forever: at rest every joule is burned as standby; charging, the mod stops draining up to the ramp ceiling so joules accumulate instead (the grid sees the same flat draw); discharge dumps the stored charge into the round.
-- These cannot be typed independently: a pylon's input_flow_limit must be a sixteenth of the draw; its buffer a sixteenth of the biggest shot plus headroom, or the top of the selector is unreachable; and max_shot must fit inside standby_draw x the charge window or every full-yield shot stalls.

--- Energy strings for the data stage. "40000000W" is a legal Energy.
function C.watts(w) return string.format("%dW", math.floor(w + 0.5)) end

--- The same, for a quantity of energy: '78125000J'. Energy is one type and the suffix says which reading is meant, so a buffer written with C.watts is a silent unit error: legal, loadable, and off by a factor of sixty.
function C.joules(j) return string.format("%dJ", math.floor(j + 0.5)) end

--- A rate as a short human string: '500 MW' below a gigawatt, then '36 GW' or '1.8 GW'. GW is the unit Factorio's own power screens speak. Here rather than in a panel because the survey prints rates too, and two files formatting the same quantity differently is how a display convention drifts.
function C.fmt_rate(w)
  if w >= 1000000000 then
    local gw = w / 1000000000
    local whole = math.floor(gw + 0.5)
    if gw >= 100 or math.abs(gw - whole) < 0.05 then
      return string.format("%d GW", whole)
    end
    return string.format("%.1f GW", gw)
  end
  return string.format("%d MW", math.floor(w / 1000000 + 0.5))
end

-- The charge window in seconds. Every rate-to-energy conversion goes through this, so the window and the audio cannot drift apart.
function C.charge_window() return C.sound.discharge_at / 60 end

-- The yield model, solved. What 100% releases (reference_mt) and how wide its crater is (reference_radius) pin the curve: Y(E) = M x E^a with M chosen so Y(100%) = reference_mt, and R(Y) = k x Y^(1/3) with k chosen so R matches reference_radius. Everything is in gigajoules (E^(8/3) in joules is ~1e31), where the numbers stay human-sized (E = 576 for a standard shot).
-- Brode first: the yield derives from the blast's edge contour, so the pressure law must be solvable before the yield model is built. Only the two functions and z_edge live here; the bands are solved further down, where the ring table is.
do
  local rings = C.blast.rings

  --- Brode (1955) peak free-air overpressure, in bar, at scaled distance z
  --- (m/kg^(1/3)). Two branches, switching at 10 bar.
  function rings.overpressure_bar(z)
    if z <= 0 then z = 1e-6 end
    local z3 = z * z * z
    local near = 6.7 / z3 + 1
    if near > 10 then return near end
    return 0.975 / z + 1.455 / (z * z) + 5.85 / z3 - 0.019
  end

  --- Scaled distance at which the pressure has fallen to `bar`. Bisection: the
  --- curve is monotone over the range, and this runs a handful of times at load.
  function rings.z_for(bar)
    local lo, hi = 0.3, 60
    for _ = 1, 80 do
      local mid = (lo + hi) / 2
      if rings.overpressure_bar(mid) > bar then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
  end

  rings.law.z_edge = rings.z_for(rings.law.edge_bar)
end

-- The yield derives from the crater: reference_radius is pinned by what the engine can afford to sweep, tile_metres gives that radius in real units, and Brode says what yield puts its edge contour there: W^(1/3) = R_metres / z_edge, in kg of TNT. This is why the panel cannot disagree with the ground.
C.yield.reference_mt =
  ((C.yield.reference_radius * C.yield.tile_metres / C.blast.rings.law.z_edge) ^ 3)
  / 1000000000   -- kg TNT -> megatons

C.yield.reference_gj = C.yield.reference_mt * 1000000 * C.yield.gj_per_tonne

--- Trigger energy of a standard (100%) shot, in GJ: reference_rate x C.charge_window(), so it moves with the charge audio's length.
function C.yield.reference_trigger_gj()
  return C.power.reference_rate * C.charge_window() / 1000000000
end

C.yield.chain_multiplier =
  C.yield.reference_gj
  / (C.yield.reference_trigger_gj() ^ C.yield.chain_exponent)

C.yield.blast_k =
  C.yield.reference_radius / (C.yield.reference_gj ^ (1 / 3))

-- The saturation join. knee_radius is the power law evaluated at the knee; tau is picked so the exponential leaves that point at the SAME slope, which is what stops the designator overlay kinking as the dial is scrubbed across it.
--   R'(knee-) = R_ref * (a/3) * knee^(a/3 - 1)
--   R'(knee+) = (max_radius - knee_radius) / tau
do
  local y, s = C.yield, C.yield.saturation
  local p = y.chain_exponent / 3
  s.knee_radius = y.reference_radius * (s.knee_fraction ^ p)
  local slope = y.reference_radius * p * (s.knee_fraction ^ (p - 1))
  s.tau = (s.max_radius - s.knee_radius) / slope
end

--- How far past the radius knee a dial fraction sits, floored at 1. THE OVERPOWER BAND: the energy that has stopped buying crater and is spent on the lance instead (heat, width, lightning, lane, sweep). Every system that escalates with power reads this, never the raw fraction.
function C.overpower(f)
  local w = (f or 0) / C.yield.saturation.knee_fraction
  if w < 1 then return 1 end
  return w
end

--- The overpower band as a plain 0..1: 0 at the knee, 1 at the top of the dial, shaped by `exponent` (below 1 front-loads it, so the first overcharge step is felt). Callers wanting an added count or an alpha take this straight; callers wanting a multiplier take C.overpower_gain.
-- Clamped at 1, which is what bounds every overpower cost in the mod: convergence can push an effective omega past the dial's own ceiling and nothing downstream may grow with it without limit.
function C.overpower_u(omega, exponent)
  local top = C.overpower(C.charge.group_cap)
  if top <= 1 then return 0 end
  local u = ((omega or 1) - 1) / (top - 1)
  if u < 0 then u = 0 elseif u > 1 then u = 1 end
  return u ^ (exponent or 1)
end

--- A bounded multiplier from an overpower factor: 1.0 at the knee rising to `max_mult` at the top of the dial.
function C.overpower_gain(omega, max_mult, exponent)
  if (max_mult or 1) <= 1 then return 1 end
  return 1 + (max_mult - 1) * C.overpower_u(omega, exponent)
end

assert(C.gun.reach_max_tiles > C.yield.saturation.max_radius * C.gun.blast_clearance,
       "C.gun.reach_max_tiles must clear the widest crater's standoff")

-- One level of N.tech.capacity per installation past the first, up to the battery a strike group can hold.
C.tech.capacity_levels = C.beam.convergence.max_lances - 1

-- The rate ceiling and the biggest shot, derived so the top of the rate field and of the tier table are the same number.
C.power.max_rate = C.power.reference_rate * C.charge.overcharge_max
C.power.max_shot = C.power.max_rate * C.charge_window()

-- Fractions are typed (C.power), watts derived here, so moving reference_rate moves all of them.
C.power.min_rate     = C.power.reference_rate * C.power.min_fraction
C.power.default_rate = C.power.reference_rate * C.power.default_fraction

-- The ceiling closes the ladder as the MAX rung. rate_index compares preset watts to the current rate with `==`, so each rung's watts are computed once, here.
do
  local fr  = C.power.rate_preset_fractions
  local top = C.charge.overcharge_max
  while #fr > 0 and fr[#fr] >= top - 1e-9 do fr[#fr] = nil end
  fr[#fr + 1] = top
end

for i, f in ipairs(C.power.rate_preset_fractions) do
  C.power.rate_presets[i] = C.power.reference_rate * f
end


--- Yield in GJ, from a trigger energy in JOULES. The chain reaction.
function C.yield.of(trigger_j)
  local gj = trigger_j / 1000000000
  if gj <= 0 then return 0 end
  return C.yield.chain_multiplier * (gj ^ C.yield.chain_exponent)
end

--- Blast radius in TILES from a trigger energy in JOULES. Delegates, so the sweep, the dose model and the panel cannot describe different blasts.
function C.yield.radius(trigger_j)
  return C.yield.radius_for_fraction((trigger_j or 0) / C.charge.cost_per_shot)
end

--- Yield in kg of TNT at a dial fraction, against the reference shot rather than a trigger energy (what every downstream physical derivation wants).
function C.yield.kg_for_fraction(f)
  return C.yield.reference_mt * 1000000000 * ((f or 1) ^ C.yield.chain_exponent)
end

--- THE ONE RADIUS CURVE. Every radius in this mod comes through here: the power law below C.yield.saturation.knee_fraction, rolling over to max_radius above it. Above the knee the radius is effectively pinned and the yield is not, so the surplus shows up as pressure (rings.dose_at computes a true scaled distance) and as C.overpower everywhere else.
function C.yield.radius_for_fraction(f)
  local y, s = C.yield, C.yield.saturation
  f = f or 1
  if f <= 0 then return 0 end

  local r
  if f <= s.knee_fraction then
    r = y.reference_radius * (f ^ (y.chain_exponent / 3))
  else
    r = s.max_radius - (s.max_radius - s.knee_radius)
                       * math.exp(-(f - s.knee_fraction) / s.tau)
  end

  local cap = y.radius_cap_tiles
  if cap > C.blast.rings.max_query_radius then cap = C.blast.rings.max_query_radius end
  if r > cap then r = cap end
  return r
end

--- The 3rd-degree-burn radius in tiles at a dial fraction. Absolute, so it is correct on both sides of the radius cap: fluence goes as W^(1/2) and blast as W^(1/3), so it outruns the blast at the top of the dial and is buried inside the fireball at the bottom.
function C.blast.dose.burn_radius_tiles(f)
  local th = C.blast.dose.thermal
  if not (th and th.enabled) then return 0 end
  local w_j = C.yield.kg_for_fraction(f) * 4184000   -- kg TNT -> J
  return math.sqrt(th.yield_fraction * w_j * th.transmittance
                   / (4 * math.pi * th.threshold_j_m2))
         / C.yield.tile_metres
end

--- Yield as tonnes of TNT equivalent, for the fire-control readouts.
function C.yield.tonnes(trigger_j)
  return C.yield.of(trigger_j) / C.yield.gj_per_tonne
end

-- One damage system at a time: the ring sweep and the dart fans overlap inside the fans' radius, so arming both would silently double-damage the first ~150 tiles. Zeroed here (not branched in prototypes/vfx/waves.lua) so blast.wave_projectile can omit the damage trigger entirely; one boolean decides which is armed.
if C.blast.rings.enabled then
  local dmg = C.blast.damage
  -- Not a loop over every 'dart_' key: dart_radius shares the prefix and is geometry, not damage.
  dmg.ground_zero  = 0
  dmg.wave         = 0
  dmg.dart_core    = 0
  dmg.dart_main    = 0
  dmg.dart_cluster = 0
  dmg.dart_over    = 0
  dmg.dart_reflect = 0
  dmg.dart_dust    = 0
end

--- Clamp a rate a player typed into what the gun will accept. One place, because the field, the drop-down, the console command and any migration must agree on what is legal.
function C.clamp_rate(w)
  if type(w) ~= "number" or w ~= w then return C.power.default_rate end
  if w < C.power.min_rate then return C.power.min_rate end
  if w > C.power.max_rate then return C.power.max_rate end
  return w
end

--- Per-pylon input limit in watts: the ceiling on how fast one bank takes power.
-- CRITICAL: must stay above the highest ramp increment or the flow limit, not the buffer, becomes the meter.
function C.pylon_input()
  return C.power.max_rate / C.pylon.max_count * C.power.flow_headroom
end

--- Per-pylon buffer: a full build holds the biggest shot, plus headroom.
function C.pylon_buffer()
  return C.power.max_shot * C.power.buffer_headroom / C.pylon.max_count
end

--- One tick's worth of the standby draw, per bank: the idle load. The buffer is set to it and emptied every tick, so the engine can never deliver more however high the flow limit is.
function C.standby_allowance()
  return C.power.standby_draw / 60 / C.pylon.max_count
end

-- Overwrite the documented string with the derived value.
C.pylon.buffer_capacity   = C.joules(C.pylon_buffer())

-- Likewise the mast's supply-area reach (depends on C.pylon.per_side/slot_spacing/tile_size, set by now).
C.substation.supply_area_distance = C.substation_supply_distance()

-- A standard shot is the reference rate held for the charge window: what the tier table, detonation scaling, resonance cells and fire-control readout measure fractions against. The window never changes: a small shot is cheap, never quick.
C.charge.cost_per_shot =
  C.power.reference_rate * C.charge_window() * C.charge.charge_margin

-- The default rate as a fraction, so the panel's opening reading and the gun's opening behaviour are the same number.
C.charge.yield_default =
  C.power.default_rate * C.charge_window() / C.charge.cost_per_shot


-- The chamber gauge's ceiling: one slot must display the largest reading the gauge can produce, or the top of the selector charges to a number the chamber cannot show. visual_cap, not overcharge_max: the gauge saturates with the rest of the art (against overcharge_max it would be a ~35x stack).
C.turret.ammo_stack_limit =
  math.ceil(C.cells.per_shot * C.charge.visual_cap)

-- Derived beam geometry. The lance burns for exactly the mix's burn portion, at every yield: the tape is the clock and the tape does not vary. The ball's growth curve reads the group's own at/cut_at, so this scales the growth rather than changing where it ends up.
C.beam.sustain_ticks = C.sound.strike_ticks

-- THE VENT IS THE SPIN-DOWN. Typed, the two drift apart the first time the mix is re-cut and the gun comes ready under a clip still playing. cooldown_for floors on the same number, so the floor can never bind.
C.charge.cooldown_ticks = C.sound.spindown_ticks

-- The beam's fade-out overlays the head of the spin-down clip, so it cannot outlast it.
if C.beam.winddown.ticks > C.sound.spindown_audible then
  C.beam.winddown.ticks = C.sound.spindown_audible
end

-- The arc sweep's rotation duration is locked to its own clip (arcsweep.lua confirm()).
C.arc_sweep.sustain_ticks = C.sound.arc_sweep_strike_ticks
-- and its mechanical charge phase to the same clip's charge portion.
C.arc_sweep.charge_ticks = C.sound.arc_sweep_charge_ticks
-- The wall stays lethal exactly as long as its flames burn.
C.arc_sweep.wall.burn_ticks = C.blast.scorch.lifetime

-- The implosion clock, per yield: shared so the release and damage sweep cannot disagree by a tick.
--   prototypes/vfx/waves.lua       offsets every release stage by total_ticks_for
--   scripts/detonate.lua           delays the damage sweep by total_ticks_for
--   prototypes/vfx/explosions.lua  retimes the core animation to ticks_for
--   scripts/implode.lua            runs the collapse across ticks_for

--- How long the shell takes to converge, in ticks, for one yield fraction. Scaled on the radius (the distance actually crossed) with an exponent well under 1: the radius spans 86x across the dial and the clock 3.9x.
function C.blast.implosion.ticks_for(fraction)
  local imp = C.blast.implosion
  local r   = C.yield.radius(math.max(fraction or 1, 0.0001) * C.charge.cost_per_shot)
  local t   = imp.base_ticks * ((r / C.yield.reference_radius) ^ imp.duration_exponent)
  if t < imp.min_ticks then t = imp.min_ticks end
  if t > imp.max_ticks then t = imp.max_ticks end
  return math.floor(t + 0.5)
end

--- Collapse + settle + beat: the offset the RELEASE is delayed by.
function C.blast.implosion.total_ticks_for(fraction)
  local imp = C.blast.implosion
  return imp.ticks_for(fraction) + imp.settle_ticks + imp.beat_ticks
end

--- k.rad clamped for one gather stamp. Read by prototypes/vfx/explosions.lua to size the puff and by scripts/implode.lua to space it; they must be the same number or the ring is gapped or overlaps itself.
function C.blast.implosion.stamp_mult(fraction)
  local imp = C.blast.implosion
  local m   = C.yield_factors(fraction).rad
  if m < imp.stamp_mult_min then m = imp.stamp_mult_min end
  if m > imp.stamp_mult_max then m = imp.stamp_mult_max end
  return m
end

--- The same for the core, on its own tighter clamp. See core_mult_min/max.
function C.blast.implosion.core_mult(fraction)
  local imp = C.blast.implosion
  local m   = C.yield_factors(fraction).rad
  if m < imp.core_mult_min then m = imp.core_mult_min end
  if m > imp.core_mult_max then m = imp.core_mult_max end
  return m
end

--- How long the damage sweep runs at one yield, in ticks. Shared with the data stage, which retimes the shock-front puff to a fraction of the sweep; a second copy would let puff and front disagree about how long the wave lasts.
function C.blast.rings.sweep_ticks_for_radius(r)
  local rings = C.blast.rings
  local t = (r or 0) / rings.front_speed
  if t < rings.min_sweep_ticks then t = rings.min_sweep_ticks end
  return t
end

function C.blast.rings.sweep_ticks(fraction)
  local r = C.yield.radius(math.max(fraction or 1, 0.0001) * C.charge.cost_per_shot)
  return C.blast.rings.sweep_ticks_for_radius(r)
end

--- How long one shock-front stamp is on screen at one yield step: long enough to overlap the next layer, which the front stamps every band_layer_spacing of a puff's width (scripts/detonate.lua) and slowest at the rim (Sedov: rim speed is n R_max / T). A stamp that dies before the next layer lands is a blinking ring.
function C.blast.rings.wave.stamp_life(fraction)
  local w = C.blast.rings.wave
  local r = C.yield.radius(math.max(fraction or 1, 0.0001) * C.charge.cost_per_shot)
  local T = C.blast.rings.sweep_ticks_for_radius(r)
  local v_end = w.front_curve * r / math.max(1, T)
  local gap = w.stamp_tiles(fraction) * w.band_layer_spacing
  local t = w.stamp_overlap * gap / math.max(v_end, 0.01)
  if t < w.stamp_life_min then t = w.stamp_life_min end
  if t > w.stamp_life_max then t = w.stamp_life_max end
  return math.floor(t + 0.5)
end

--- One gather stamp's drawn width in tiles at one yield step: what the shock front's ring density derives from. Lives here so the clamp and the multiply are applied together. Same shape as C.blast.implosion.stamp_tiles.
function C.blast.rings.wave.stamp_tiles(fraction)
  local w = C.blast.rings.wave
  local m = C.yield_factors(fraction or 1).rad
  if m < w.stamp_scale_min then m = w.stamp_scale_min end
  if m > w.stamp_scale_max then m = w.stamp_scale_max end
  return w.sprite_tiles * m * w.stamp_scale_in
end

--- Tiles between stamps along the front at one yield step: a fraction of the puff's own width (spacing_fraction), falling back to the fixed `spacing` if that is nil.
function C.blast.rings.wave.stamp_spacing(fraction)
  local w = C.blast.rings.wave
  if not w.spacing_fraction then return w.spacing end
  return math.max(0.5, w.stamp_tiles(fraction) * w.spacing_fraction)
end

--- Vertices in one annulus of the wall. Derived from rt_modes: sampling a ring at N angles cannot carry an instability mode above N/2 without aliasing, and needs several samples per cycle (rt_samples_per_mode) to stop looking faceted. See the segments_min note in the wall block. Pure arithmetic, read once per draw_wall.
function C.blast.rings.wave.wall.segments_for()
  local wl = C.blast.rings.wave.wall
  local top = 0
  for _, m in ipairs(wl.rt_modes) do
    if m > top then top = m end
  end
  local n = math.ceil(top * wl.rt_samples_per_mode)
  if n < wl.segments_min then n = wl.segments_min end
  if n > wl.segments_max then n = wl.segments_max end
  return n
end

--- One fire-ring flame's drawn width in tiles at one yield step (as C.blast.rings.wave.stamp_tiles).
function C.blast.rings.firewave.stamp_tiles(fraction)
  local fw = C.blast.rings.firewave
  local m = C.yield_factors(fraction or 1).rad
  if m < fw.stamp_scale_min then m = fw.stamp_scale_min end
  if m > fw.stamp_scale_max then m = fw.stamp_scale_max end
  return fw.sprite_tiles * m
end

--- Tiles between flames along the front at one yield step; falls back to `spacing` if spacing_fraction is nil.
function C.blast.rings.firewave.stamp_spacing(fraction)
  local fw = C.blast.rings.firewave
  if not fw.spacing_fraction then return fw.spacing end
  return math.max(0.5, fw.stamp_tiles(fraction) * fw.spacing_fraction)
end

--- The release fireball's baked sprite scale at one yield step: the flash's k.rad curve at 3x the multiplier and a looser ceiling, since that ceiling existed to stop a light filling the screen and this entity carries no light.
function C.blast.release.scale_for(fraction)
  local rl = C.blast.release
  local s = rl.scale * C.yield_factors(fraction or 1).rad
  if s > rl.max_scale then s = rl.max_scale end
  return s
end

--- The shock wall's temperature at normalised radius u, in kelvin: the ball's kelvin at release (k_release, from scripts/beam.lua via impact.detonate) cooling on the tempered Sedov law (see C.blast.rings.wave.wall). Inside the fireball ring u is clamped, so everything there is at the release temperature and u = 0 cannot divide by zero. Pure arithmetic, usable from both stages.
function C.blast.rings.wave.wall_kelvin(k_release, u)
  local wl = C.blast.rings.wave.wall
  local u0 = C.blast.rings.fireball_u
  local k0 = k_release or wl.kelvin_fallback
  if not (u and u > u0) then u = u0 end
  local k = k0 * (u0 / u) ^ wl.cool_exponent
  if k < wl.t_floor then k = wl.t_floor end
  return k
end

--- The energy the front left in the ground at normalised radius u, relative to the fused-rock contour (1 there, rising inward): wall_kelvin's own ratio between the two radii, so the ground is dosed by the gas law that crossed it. Pure arithmetic, usable from both stages.
function C.blast.rings.groundfire.dose(u)
  local wk = C.blast.rings.wave.wall_kelvin
  return wk(nil, u) / wk(nil, C.heat.ground.melt_u)
end

--- The ground's peak temperature at normalised radius u, in kelvin (C.heat.ground).
function C.blast.rings.groundfire.kelvin(u)
  local g = C.heat.ground
  local k = g.t_melt * C.blast.rings.groundfire.dose(u)
  if k > g.t_boil then k = g.t_boil end
  return k
end

--- One ground flame's prototype scale at one yield step.
function C.blast.rings.groundfire.scale_for(fraction)
  local gf = C.blast.rings.groundfire
  local m = C.yield_factors(fraction or 1).rad
  if m < gf.scale_min then m = gf.scale_min end
  if m > gf.scale_max then m = gf.scale_max end
  return gf.scale * m
end

--- How long one gather stamp is on screen at one yield step. Capped at beat_ticks as a correctness bound: the last shell is stamped at `ticks_for` and the release fires `beat_ticks` later, so a life at or under the beat guarantees the collapse finishes drawing before the flash.
function C.blast.implosion.stamp_life(fraction)
  local imp = C.blast.implosion
  local t = imp.ticks_for(fraction) * imp.stamp_life_fraction
  if t > imp.beat_ticks then t = imp.beat_ticks end
  if t < imp.stamp_life_min then t = imp.stamp_life_min end
  return math.floor(t + 0.5)
end

--- k.rad clamped for the ground-zero scorch decal, on a tighter clamp than the puff's: a puff is one of many overlapping sprites, but the decal is a single stretched texture that blurs when scaled hard. See C.blast.scar.decal_mult_min/max.
function C.blast.scar.decal_mult(fraction)
  local sc = C.blast.scar
  local m  = C.yield_factors(fraction).rad
  if m < sc.decal_mult_min then m = sc.decal_mult_min end
  if m > sc.decal_mult_max then m = sc.decal_mult_max end
  return m
end

--- One gather stamp's drawn width in tiles at one yield step; ring density derives from it.
function C.blast.implosion.stamp_tiles(fraction)
  local imp = C.blast.implosion
  return imp.stamp_sprite_tiles * imp.stamp_scale_initial * imp.stamp_mult(fraction)
end

-- The ring law, solved (see C.blast.rings.law).
do
  local rings = C.blast.rings
  local law   = rings.law
  local PSI   = 0.0689476   -- bar per psi
  local z_for = rings.z_for   -- defined with overpressure_bar, above the yield model

  rings.bands = {}
  for i, ring in ipairs(law.rings) do
    local to = ring.psi and (z_for(ring.psi * PSI) / law.z_edge) or 1.0
    rings.bands[i] = {name = ring.name, to = to, destroy = ring.destroy}
  end
  rings.fireball_u = rings.bands[1].to
  law.p_ref = rings.overpressure_bar(rings.fireball_u * law.z_edge)
  rings.corpses.radius_fraction = rings.fireball_u
  for _, band in ipairs(rings.bands) do
    if band.name == rings.paint.ring then rings.paint.radius_fraction = band.to end
    if band.name == rings.paint.ring_base then rings.paint.radius_fraction_base = band.to end
    if band.name == C.heat.ground.melt_ring then C.heat.ground.melt_u = band.to end
  end
end

-- The dose, solved (see C.blast.dose): two mechanisms, two published anchors.
do
  local rings = C.blast.rings
  local d     = C.blast.dose
  local PSI   = 0.0689476

  -- One lethal dose for the reference target, through its own resistance.
  d.lethal_dose = d.lethal_hp / (1 - d.lethal_resist)

  -- Blast normalisation: the pressure at the contour where blast alone is lethal; dose_at divides by it, so blast contributes exactly one lethal dose there.
  d.blast_p_ref = rings.overpressure_bar(rings.z_for(d.blast_lethal_psi * PSI))

  -- Thermal reach at full dial as a fraction of the blast radius: Q = f_th x W x tau / (4 pi R^2), so R_burn = sqrt(f_th W tau / 4 pi Q_th). Above 1.0 the whole disc is inside the burn radius, which is why the rim kills at full yield and not at 25%. Informational: dose_at calls burn_radius_tiles directly, since a fraction of the reference radius means nothing once the sweep radius is capped; the panel and docs quote this.
  local th = d.thermal
  if th and th.enabled then
    th.u_ref = d.burn_radius_tiles(1) / C.yield.reference_radius
  end

end

for _, t in ipairs(C.blast.movers.types) do C.blast.movers.set[t] = true end

--- The wave's dose at normalised distance u (0..1 of the blast radius), in hit points: blast plus thermal, each at its own published lethality threshold (see C.blast.dose). Inside the fireball nobody asks (that ring is die()). Absolute HP, not a fraction of payload.
--- `fraction` is the yield DELIVERED (a converged group sums its lances); `r_tiles` is the radius that yield is confined to, which the dial alone sets. Pass both and the surplus shows up as pressure: Z shrinks, Brode does the rest. Omitting r_tiles recovers the unconfined shot.
function C.blast.rings.dose_at(u, fraction, r_tiles)
  local rings = C.blast.rings
  local d     = C.blast.dose
  if not (u and u > 0) then u = 1e-6 end

  local f = fraction or 1
  r_tiles = r_tiles or C.yield.radius_for_fraction(f)

  -- The true scaled distance, Z = metres / W^(1/3), not u x z_edge. Below the radius cap they are identical (the radius carries f^(a/3) and the cube root of the yield carries the same, so they cancel and damage does not scale with yield, only the radii). At the cap the radius stops growing and the yield does not, so Z shrinks and pressure everywhere rises: the overcharge regime.
  local z = u * r_tiles * C.yield.tile_metres / (C.yield.kg_for_fraction(f) ^ (1 / 3))

  local hp = d.lethal_dose * rings.overpressure_bar(z) / d.blast_p_ref

  -- Thermal: inverse-square fluence inside the burn radius and nothing outside it. Absolute for the same reason as Z: past the cap the burn radius keeps growing while the sweep does not.
  local th = d.thermal
  if th and th.enabled then
    local ut = d.burn_radius_tiles(f) / r_tiles
    if u <= ut then hp = hp + d.lethal_dose * (ut / u) ^ 2 end
  end
  return hp
end

-- The dose at the fireball ring's edge, which every pre-wave stage takes a share of (implode.lua's collapse shock).
-- Must come after dose_at, not with the other derived dose constants: a function reference resolves at call time, so deriving it earlier calls nil (valid syntax, hard crash on first load; verify.py check 12).
C.blast.dose.payload = C.blast.rings.dose_at(C.blast.rings.fireball_u, 1)

--- The collapse shock's pressure exponent from the convergence law: p ~ D^2 ~ r^(2(alpha-1)/alpha), as the positive magnitude (0.907).
C.blast.implosion.shock_exponent =
  2 * (1 - C.blast.implosion.converge_exponent) / C.blast.implosion.converge_exponent

--- Where the charging sphere ends up, in tiles, for a shot of this power. Shared by scripts/beam.lua (the ball) and the gather (which starts at exactly this radius), so the ball cannot change size on the frame the beam cuts. `power` is continuous, not quantised to a yield step; only the sprites are.
function C.sphere_full_radius(power)
  local sp   = C.beam.sphere
  local full = C.yield.radius((power or 1) * C.charge.cost_per_shot) * sp.radius_fraction
  if full > sp.radius_cap then full = sp.radius_cap end
  if full < sp.min_radius then full = sp.min_radius end
  return full
end

--- A {lo, hi, exp} range at `s`, 0..1.
function C.range_at(r, s)
  if s < 0 then s = 0 elseif s > 1 then s = 1 end
  return r.lo + (r.hi - r.lo) * (s ^ (r.exp or 1))
end

-- The lightning ranges that are whole numbers of things or ticks.
local LIGHTNING_COUNTS = {targets = true, forks = true, strokes = true, stroke_ticks = true}

--- One lightning level's figures: every {lo, hi} range in C.beam.sphere.lightning evaluated at `level`, counts rounded. Pure, so both stages build from it.
function C.lightning_level(level)
  local lt = C.beam.sphere.lightning
  local s = (level - lt.min_level) / (lt.max_level - lt.min_level)
  local out = {level = level, s = s}
  for k, r in pairs(lt) do
    if type(r) == "table" and r.lo and r.hi then
      local v = C.range_at(r, s)
      if LIGHTNING_COUNTS[k] then v = math.floor(v + 0.5) end
      out[k] = v
    end
  end
  return out
end

--- The three multipliers one yield step applies to the whole detonation, shared by every file that scales to yield so none ends on a different curve (at exponents of 1.0 all three are the fraction). `floor` stops a very small shot rendering as nothing.
function C.yield_factors(fraction)
  local ys = C.charge.yield_scale
  local f  = math.max(fraction, ys.floor)
  return {
    dmg = f ^ ys.damage,
    -- rad is the real blast radius divided by visual_divisor: what every fan radius, damage circle, falloff distance, scar radius, camera distance and light size scales by. Computed from the raw fraction, not the floored `f`, or a tiny shot would render at the size of a bigger one.
    rad = C.blast.rings.enabled
      and (C.yield.radius(math.max(fraction, 0.0001) * C.charge.cost_per_shot)
           / C.blast.visual_divisor)
      or  ((f ^ ys.radius) * C.blast.radius_scale),
    cnt = f ^ ys.count,
    -- The clamped fraction itself, for anything wanting 0..1.5 rather than a scaled radius (the flash intensity is a brightness, and must not pick up radius_scale).
    unit = f,
  }
end

--- How far the lance reaches, in tiles; every caller (designator, select ring, beam length) asks here.
function C.reach()
  return C.gun.reach_max_tiles
end

--- Half the lance's visual thickness, in tiles. The halo art at scale_mult 14 measures about 2.6 tiles thick, which is the ratio below. Everything asking 'is this under the beam' goes through here, so damage width and sprite width are one number.
-- `omega` (C.overpower) adds the scorch margin on top: the lane a full-dial lance burns is wider than the sprite, which is the one kill area in this mod allowed to grow with power because its search cost is length x width.
function C.beam_half_width(omega)
  local w = C.beam.halo.scale_mult * (2.6 / 14) * 0.5 * C.beam.path.half_width_mult
  if omega and omega > 1 then
    w = w * C.overpower_gain(omega, C.beam.path.overpower_lane_max,
                             C.beam.path.overpower_lane_exponent)
  end
  return w
end

--- Tiles past the muzzle the DRAWN channel starts (C.beam.draw_standoff), so an overpressure lance's near end clears the installation. Zero at and below C.charge.visual_cap.
function C.beam_draw_standoff(power)
  local ds = C.beam.draw_standoff
  if not (ds and (ds.per_tile_over_knee or 0) > 0) then return 0 end
  local over = C.beam_half_width() * (C.beam_size(C.beam_step_for(power or 1)) - 1)
  if over <= 0 then return 0 end
  return math.min(over * ds.per_tile_over_knee, ds.max)
end

--- Absolute scale for a beam layer: a multiple of the base game's laser beam (authored at 0.5).
function C.beam_scale(mult) return 0.5 * mult end

--- Every fraction a lance prototype is built at: the 1% floor, each width_step up to visual_cap, then width_step_coarse rungs across the overpower band. Counted, not accumulated (float drift would break the name lookup).
function C.beam_steps()
  local out = {C.power.min_fraction}
  local n = math.floor(C.charge.visual_cap / C.beam.width_step + 1e-9)
  for i = 1, n do
    local f = i * C.beam.width_step
    if f > C.power.min_fraction + 1e-9 then out[#out + 1] = f end
  end

  -- The overpower widths. Coarse on purpose: this is a prototype-count bill, paid against the whole heat ladder and both layers.
  local coarse = C.beam.width_step_coarse
  -- The GROUP's ceiling, not the dial's: a lance's width reads the strike it
  -- belongs to (scripts/beam.lua, fire), and a solo dial stops at 100%.
  local top    = C.charge.group_cap
  if coarse and coarse > 0 then
    -- Counted, like the fine rungs above: a repeated `f = f + coarse` drifts, and
    -- a drifted value here is a prototype name the control stage cannot look up.
    local n2 = math.floor((top - C.charge.visual_cap) / coarse + 1e-9)
    for i = 1, n2 do
      out[#out + 1] = C.charge.visual_cap + i * coarse
    end
    -- The ceiling itself, so the top of the dial always has a lance built for it.
    if out[#out] < top - 1e-9 then out[#out + 1] = top end
  end
  return out
end

--- The built lance step nearest to a delivered charge fraction.
function C.beam_step_for(power)
  local best, best_d = nil, nil
  for _, f in ipairs(C.beam_steps()) do
    local d = math.abs(f - (power or 1))
    if not best_d or d < best_d then best, best_d = f, d end
  end
  return best
end

--- How big a beam is at a given yield, as a multiple of the 100% lance: scale_floor at nothing, 1.0 at visual_cap, then on up the overpower band to C.beam.overpower_scale_max. Continuous at the join, because C.overpower_gain is 1.0 at the knee and visual_cap and the knee are the same point.
function C.beam_size(fraction)
  local top = C.charge.visual_cap
  local f   = math.max(0, fraction or 0)
  if f <= top then
    return C.beam.scale_floor + (1 - C.beam.scale_floor) * (f / top)
  end
  return C.overpower_gain(C.overpower(f), C.beam.overpower_scale_max,
                          C.beam.overpower_scale_exponent)
end

-- Startup settings: none are folded in. C.gun.range is a literal; a startup setting that no longer exists is dropped on load, not an error.

-- Performance: engine-side and measurement
C.perf = {
  -- Data stage (data-final-fixes.lua): sets only_when_visible on every create-particle effect used by base biter, spitter, spawner and worm blood/guts (on death and on every hit), which are otherwise created whether or not anyone is near. Particles within 200 tiles of a connected player (the engine's rule) look as before; the rest are never made. Touches base prototypes for every enemy death, not just this weapon; false restores vanilla.
  enemy_particles_only_when_visible = true,

  -- /oppenheimer-profile (scripts/profile.lua).
  profile = {
    default_seconds = 60,
    -- Averaging window: one report line per timer every window_ticks.
    window_ticks = 180,
    file = "oppenheimer-profile.txt",   -- under script-output/
  },

  -- Don't draw what nobody can see (scripts/view.lua). A full-yield shot is 2000 tiles across and the viewport at full zoom-out is about 500 x 280, and a render object costs the same whether or not it lands on a screen. Only short-time_to_live objects are culled (redrawn every tick or two, so panning back repairs itself); persistent objects such as the designator preview are never touched. No damage, tile or entity changes, only whether a picture is built.
  view = {
    enabled = true,
    -- Tiles from a watcher's view position: half the widest viewport's diagonal (~287) plus slack, so an object is drawn before it slides into frame. Raise if anything pops in at the screen edge.
    radius = 360,
  },
}

return C
