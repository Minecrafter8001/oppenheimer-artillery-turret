-- scripts/schema.lua ------------------------------------------------------------
-- The shape of `storage`, and how it migrates. ARCHITECTURE.md rule 5: nothing
-- else creates a top-level storage key.
--
-- `storage` is the only table Factorio serialises into the save and the only
-- state guaranteed identical across every player in multiplayer. Everything
-- persistent goes here; everything else is rebuilt from control.lua on load.
--
-- THE SHAPE
--   storage = {
--     version = 1,
--     turrets = {                          -- [unit_number] = record, HAS HOLES
--       [123] = {
--         unit_number = 123,
--         entity      = LuaEntity,
--         pylons      = { north = 456, east = 457, south = 458, west = 459 },
--         charge      = 0.0,               -- joules accumulated this cycle
--         state       = "idle",            -- see scripts/turret.lua
--         state_since = 0,                 -- game.tick
--       },
--     },
--     pylons  = {},                        -- [unit_number] = owning turret's number
--     buckets = {},                        -- [0..N-1] = { unit_number, ... }
--     render  = {},                        -- [unit_number] = { LuaRenderObject }
--     selection = {},                      -- [player_index] = { LuaRenderObject }
--     strike_cells = {},                   -- [surface]["cx:cy"] = { {x,y,expires} }
--     warn = {},                           -- [unit_number] = LuaRenderObject
--     gui_open = {},                       -- [player_index] = unit_number
--     hud_hidden = {},                     -- [player_index] = true
--   }
--
-- RULES THIS FILE EXISTS TO ENFORCE
--   * storage.turrets is keyed by unit_number and HAS HOLES. Always
--     table_size(), never #. `#t` on a table with holes returns a wrong count,
--     silently.
--   * A stored LuaEntity is a handle to a C++ object and can go invalid between
--     ticks (another mod deleted it, a biter ate it). Every read path goes
--     through schema.valid(), which drops dead records as it finds them.
--   * Migrations run from on_configuration_changed, NEVER on_load. Writing to
--     storage in on_load is an error, and doing anything else there desyncs
--     multiplayer and breaks replays.
--   * Functions cannot be stored in storage (hard error on save). Metatables
--     are stripped unless registered via script.register_metatable.
----------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local schema = {}

-- Migration steps below need modules that either require schema back (turret,
-- pylon, placement) or are simply not loaded yet when this file runs --
-- control.lua requires schema before them. `require` is illegal at runtime, and
-- schema.migrate() runs from on_configuration_changed, so the steps cannot pull
-- these in themselves. control.lua hands them over here at parse time.
local deps = {}
function schema.link(modules)
  for k, v in pairs(modules) do deps[k] = v end
end

-- Bump this and add a migrate step for ANY change to the shape above.
schema.VERSION = 29

-- Shared by steps 14 and 15: both move a substation while trying to keep its
-- copper wires. Whether teleport itself preserves wires is undocumented, so
-- both record connections first and restore them after, rather than trusting it.
local COPPER = defines.wire_connector_id.pole_copper
local function mast_wires_of(m)
  local conn = m.get_wire_connector(COPPER, false)
  local out = {}
  if conn then
    for _, w in pairs(conn.connections) do out[#out + 1] = w end
  end
  return out
end
local function mast_rewire(m, list)
  local conn = m.get_wire_connector(COPPER, true)
  if not conn then return end
  for _, w in ipairs(list) do
    pcall(function()
      if w.target.valid and not conn.is_connected_to(w.target, w.origin) then
        conn.connect_to(w.target, false, w.origin)
      end
    end)
  end
end

-- =============================================================================
-- Initialisation
-- =============================================================================

--- Make every key exist with the right shape. Idempotent, so it is safe from
--- both on_init (new save) and on_configuration_changed (mod added/updated).
function schema.ensure()
  storage.version = storage.version or schema.VERSION
  storage.turrets = storage.turrets or {}
  storage.pylons  = storage.pylons  or {}
  -- Live strike groups (scripts/beam.lua, STRIKE GROUPS): [id] = {to, surface,
  -- power, lances, live, opener, at, cut_at, omega_group, theta_ball,
  -- sphere_r, streaks, fire, taunts, burned, struck, ...}. Converging lances
  -- share one: the clock, the sphere and the detonation belong to the group.
  storage.strikes = storage.strikes or {}
  storage.strike_next = storage.strike_next or 0
  -- [mast unit_number] = owning turret's unit_number. Flat, unlike
  -- storage.pylons, because a mast has no slot to remember -- see
  -- scripts/pylon.lua.
  storage.masts   = storage.masts   or {}
  storage.buckets = storage.buckets or {}
  storage.render  = storage.render  or {}
  -- Per-player selection overlays (#28, #80). Keyed by player_index, not
  -- unit_number, because they belong to whoever is looking at the turret.
  storage.selection = storage.selection or {}
  -- #33: pending artillery strikes, so two turrets never volley one nest.
  -- [surface_index]["cellx:celly"] = { {x, y, expires}, ... }
  storage.strike_cells = storage.strike_cells or {}
  -- #83/#101: rounds in flight and the yield each was fired at. A flat array,
  -- not a grid -- there are single digits of these at any moment, and
  -- scripts/impact.lua scans it once per shell that lands.
  -- { {surface, x, y, power, expires}, ... }
  storage.shots = storage.shots or {}

  -- 0.14.0: detonations whose damage front is still travelling. A flat array,
  -- normally empty and never more than a handful long -- a sweep lives for the
  -- four seconds its front takes to cross the blast and is then removed.
  -- { {surface, x, y, radius, buckets, next_i, cursor, started, ticks, force}, ... }
  --
  -- It holds LuaEntity references, which is legal in storage and is why every
  -- read in scripts/detonate.lua checks .valid: a save reloaded mid-sweep, or an
  -- entity killed by the band ahead of it, leaves stale handles behind.
  storage.sweeps = storage.sweeps or {}

  -- BLAST FOOTPRINTS, replayed onto ground as it is generated
  -- (scripts/scar.lua). Unlike storage.sweeps these are PERMANENT: a sweep is
  -- a few seconds of one detonation, a scar is a fact about the map that has
  -- to outlive every save/load or the crater heals the moment anyone charts it.
  -- `crater` is shared with its sweep's record (scripts/crater.lua) and trimmed
  -- to radii, ladder key and lobe phase when the sweep ends.
  storage.scars = storage.scars or {}

  -- 0.15.0: implosions in progress -- the collapse that runs between the beam
  -- cutting and the release firing. One record per round in that window, which
  -- is 88 to 209 ticks depending on yield, then removed.
  -- { {surface, x, y, r0, ticks, total, variant, started, next_ring, phase,
  --    streaks = {{angle, reach}, ...}}, ... }
  --
  -- PLAIN DATA ONLY -- no LuaEntity handles and no LuaRenderObject ids, unlike
  -- storage.sweeps above. Everything it draws is a two-tick redraw, so a save
  -- reloaded mid-collapse has nothing stale to validate: the record simply
  -- resumes drawing, or is dropped when its surface is gone.
  storage.implosions = storage.implosions or {}

  -- Craters still glowing (scripts/groundfire.lua). Plain data; a record
  -- outlives its sweep, which writes paint_r into it while it paints.
  -- { {surface, x, y, radius, started, ticks, variant, hold, rate, salt,
  --    paint_r, glow_r, laid, ends}, ... }
  storage.groundfires = storage.groundfires or {}

  -- Craters whose floor is still cooling (scripts/crater.lua). Each is the same
  -- table as its sweep's `crater` and its scar's, dropped once every threshold
  -- has reached ground zero.
  storage.craters = storage.craters or {}

  -- 0.51.0: trees-and-rocks fronts (scripts/flora.lua), one per detonation
  -- point, keyed "surface:x:y". PLAIN DATA -- two radii and the shot's force,
  -- no entity handles. Dropped once stale_ticks unfed.
  -- { [key] = {x, y, radius, done, goal, cap, force, fed, found, passes} }
  storage.flora = storage.flora or {}

  -- 0.14.0: the designator overlay's render objects, keyed by turret. Separate
  -- from storage.render because the lifetimes are different -- these exist only
  -- while an installation is aiming, and are rebuilt whenever the aim point or
  -- the charge rate moves. { [unit_number] = {sig, objs, radius, danger} }
  storage.preview = storage.preview or {}

  -- 0.27.0: groundbreaking in progress (scripts/placement.lua) -- the survey
  -- ghosts and the pour, resumable across a save. Gone when the floor is down.
  -- { [unit_number] = {entity, cx, cy, started, ghost_i, tile_i} }
  storage.groundworks = storage.groundworks or {}

  -- 0.27.0: the reticle's script-drawn moments (scripts/reticle.lua), keyed by
  -- turret. Own lifetime, separate from storage.render: the aim line and chase
  -- bulbs come and go with AIM/FIRE, and the scorch history must survive the
  -- render bag being torn down when an installation goes incomplete.
  -- { [unit_number] = {aim, bulbs, glows, phase, conv, flash, commission, scorch} }
  storage.reticle = storage.reticle or {}

  for i = 0, C.control.update_buckets - 1 do
    storage.buckets[i] = storage.buckets[i] or {}
  end

  -- Carried over from 0.1.0, which counted turrets for the /oppenheimer-count
  -- demo command. Kept so the command keeps working across the refactor.
  storage.turrets_built = storage.turrets_built or 0

  -- Rule 5 says this file is the only place a top-level key is created. Three
  -- of these were being conjured with `storage.x = storage.x or {}` at their
  -- point of use instead, which is how a key ends up existing in some saves and
  -- not others -- and why nothing could enumerate the mod's own state.
  storage.warn       = storage.warn       or {}   -- [unit_number] = LuaRenderObject
  storage.gui_open   = storage.gui_open   or {}   -- [player_index] = unit_number
  storage.hud_hidden = storage.hud_hidden or {}   -- [player_index] = true
  -- [force_index] = a committed battery order waiting on its barrels
  -- (scripts/alpha.lua): {units = {unit_number,...}, x, y, tick}. Plain data;
  -- a member that stops being part of it is dropped on the next tick.
  storage.alpha_order = storage.alpha_order or {}
  -- WHERE THE LAST DRAG BEGAN, [player_index] = {x, y, tick}. Written by the
  -- linked select custom-inputs (scripts/remote.lua) and read by the very next
  -- on_player_selected_area, because that event's rectangle is normalised and
  -- an arc sweep drawn right-to-left would otherwise fire left-to-right. Plain
  -- data, stale entries harmless: each read checks the tick.
  storage.drag       = storage.drag       or {}
  -- Latched once if LuaEntity.orientation turns out not to read on an artillery
  -- turret, so the aim gate degrades to "always aligned" instead of pcall-ing
  -- per turret per tick forever.
  storage.no_orientation = storage.no_orientation or false

  -- MUZZLE TUNING. Where the lance leaves the gun is two multipliers that two
  -- attempts to derive have both missed, so they are adjustable in game
  -- (/oppenheimer-muzzle) and the settled pair is copied back into config.lua.
  -- nil means "use the config value" -- deliberately not defaulted to the config
  -- number here, or editing config.lua would stop having any effect on a save
  -- that had once been tuned.
  storage.muzzle_forward = storage.muzzle_forward or nil
  storage.muzzle_lift    = storage.muzzle_lift    or nil
  storage.muzzle_debug   = storage.muzzle_debug   or false
end

-- =============================================================================
-- Migration
-- =============================================================================

-- [from_version] = function() ... end   -- migrates from_version -> from_version+1
local steps = {
  -- 1 -> 2. Clears every render object this mod created (rendering.clear with
  -- mod_name touches no other mod's): objects whose bag key the code no longer
  -- reads keep drawing otherwise. Everything is rebuilt on the next bucket tick.
  [1] = function()
    rendering.clear(script.mod_name)
    storage.render = {}
    storage.preview = {}
    storage.selection = {}
    storage.warn = {}
  end,

  -- 2 -> 3. GIVE THE SHELLS BACK.
  --
  -- Under the old ammo gate every shell was pulled out of the chamber into
  -- rec.reserve, a bare integer. The gate is now disabled_by_script and never
  -- touches an inventory, so nothing will ever read those counters again -- and
  -- leaving them would silently destroy every shell they hold the next time a
  -- record is dropped. Put them back in the gun they came out of.
  --
  -- Deliberately NOT conditional on the current gate_mode: the counters exist in
  -- the save either way, and a user who flips back to "ammo" gets a chamber the
  -- gate will re-empty on its next tick. Nothing is lost by returning them.
  [2] = function()
    local logistics = deps.logistics
    local returned, spilled = 0, 0

    for _, rec in pairs(storage.turrets or {}) do
      local left = rec.reserve or 0
      rec.reserve = nil
      if left > 0 then
        local e = rec.entity
        if e and e.valid then
          local inv = e.get_inventory(defines.inventory.artillery_turret_ammo)
          local put = inv and inv.insert{name = N.shell, count = left} or 0
          returned = returned + put
          if put < left then
            -- More than the gun can hold: back to the network, or onto the pad
            -- beside the installation where it can actually be seen.
            spilled = spilled + (left - put)
            logistics.park(rec, left - put)
          end
        end
      end
      -- The old gate's bookkeeping, now meaningless.
      rec.ammo_seen = nil
    end

    if returned > 0 or spilled > 0 then
      game.print{"oppenheimer.reserve-returned", tostring(returned), tostring(spilled)}
    end
  end,

  -- 3 -> 4. UNSTICK THE FROZEN GUNS.
  --
  -- Under 0.6.0 a designation placed a flare and held the entity with
  -- disabled_by_script. Deactivating an entity stops all its operations, so the
  -- barrel could not turn, the alignment gate could never open, and any turret
  -- left in AIM is sitting in a state it can never leave -- CONFIRM will refuse
  -- it forever. Anything mid-sequence is in the same position.
  --
  -- So every turret goes back to STANDBY with a clean record. The player loses a
  -- designation they could not have fired anyway.
  [3] = function()
    local turret = deps.turret

    -- Re-probe. If this latched under the old code path, script aiming would be
    -- dead on arrival in a save that is otherwise fine.
    storage.no_orientation = false
    storage.shots = storage.shots or {}

    for _, rec in pairs(storage.turrets or {}) do
      if rec.state == turret.AIM or rec.state == turret.FIRE then
        rec.state = turret.STANDBY
        rec.state_since = game.tick
        rec.said = nil
      end
      rec.designated   = nil
      rec.spool        = 0
      rec.discharged   = nil
      rec.discharged_at = nil
      rec.chamber_mark = nil
      rec.stalled      = nil
      rec.slew_last    = nil
      rec.slew_stuck   = nil
      -- Re-applied rather than assumed: the gate is what the old state was
      -- fighting, and a turret coming out of this must be held, not loose.
      turret.set_gate_disable(rec, false)
      -- The engine's own target-hunting, off. Written once and latched.
      rec.auto_locked = nil
      turret.lock_auto(rec)
    end
  end,

  -- 4 -> 5. THE PIVOT. Let every barrel go, and put every gun back in STANDBY.
  --
  -- Two things in a 0.7.0 save are now unreachable states rather than merely
  -- stale ones:
  --
  -- THE HOLD. Every turret was carrying disabled_by_script -- that was the gate,
  -- applied on entering any state that was not the firing window. Nothing in
  -- 0.8.0 ever sets it, because there is nothing left to gate, so nothing would
  -- ever clear it either: a deactivated nine-tile gun with no visible cause and
  -- no way to explain it. turret.unhold catches turrets on their next bucket
  -- step, but only because it is latched per record -- doing it here means the
  -- upgrade is not silently waiting on a tick.
  --
  -- A GUN MID-SEQUENCE. A turret in FIRE has committed energy and a chamber mark
  -- and expects a shell to leave; there is no shell path any more, and no lance
  -- either, because a lance only exists as an entity created at ignition. It
  -- would sit in FIRE waiting for a discharge that already happened. AIM is
  -- recoverable but not worth recovering across a delivery change -- the yield
  -- and the aim point are two clicks.
  --
  -- The strike table goes too. Entries in it were shells in the air; the beam
  -- does not use it, and a stale order would be claimed by the next thing that
  -- raises the trigger and detonate at the wrong yield.
  [4] = function()
    local turret = deps.turret

    for _, rec in pairs(storage.turrets or {}) do
      rec.state       = turret.STANDBY
      rec.state_since = game.tick
      rec.said        = nil
      rec.designated  = nil
      rec.spool       = 0
      rec.discharged  = nil
      rec.discharged_at = nil
      rec.stalled     = nil
      rec.lance       = nil
      -- Dead fields from the shell. Cleared so an inspected save does not still
      -- describe a chamber the mod no longer watches.
      rec.chamber_mark = nil
      rec.ammo_seen    = nil
      -- THE HOLD COMES OFF. Latch first, then apply, so this and turret.unhold
      -- cannot both write it.
      rec.unheld = nil
      turret.unhold(rec)
      rec.auto_locked = nil
      turret.lock_auto(rec)
    end

    storage.shots = {}
    game.print{"oppenheimer.pivoted"}
  end,

  -- 5 -> 6. THE BANKS CHANGED TYPE, AND THE MASTS ARRIVED.
  --
  -- The capacitor banks went from `accumulator` to `electric-energy-interface`
  -- (see prototypes/entity/pylon.lua for why). A prototype that changes TYPE
  -- does not survive a save: the engine drops every entity of the old type
  -- before any migration runs, so there is nothing here to convert -- only stale
  -- bookkeeping to clear. This was chosen deliberately over keeping the old
  -- prototype registered and swapping entities in place.
  --
  -- What is left over in a 0.10.x save, all of it now pointing at nothing:
  --   * storage.pylons entries for entities the engine has already deleted
  --   * rec.pylons keyed to those unit numbers, so every installation reads as
  --     incomplete and parks in IDLE -- which is correct, it IS incomplete, but
  --     it has to be able to notice that the player rebuilt it
  --   * render objects from a VFX generation that had no status lights in it
  --
  -- The pad is re-laid at the same time because the installation got BIGGER:
  -- the foundation is now derived from C.installation_extent(), which reaches
  -- past the masts rather than stopping at the outermost bank.
  [5] = function()
    local turret    = deps.turret
    local pylon     = deps.pylon
    local placement = deps.placement

    -- Wholesale, not per-key: the light objects are a new set with new keys, so
    -- nothing in the new code has a handle on anything the old code drew. Same
    -- reasoning as the 1 -> 2 step, and the same one-line sweep.
    rendering.clear(script.mod_name)
    storage.render = {}
    storage.preview = {}
    storage.selection = {}
    storage.masts = storage.masts or {}

    for _, rec in pairs(storage.turrets or {}) do
      for _, pun in pairs(rec.pylons or {}) do
        storage.pylons[pun] = nil
      end
      rec.pylons = {}
      rec.masts  = {}
      -- A gun mid-sequence has committed energy to banks that no longer exist.
      rec.state       = turret.STANDBY
      rec.state_since = game.tick
      rec.said        = nil
      rec.designated  = nil
      rec.spool       = 0
      rec.discharged  = nil
      rec.discharged_at = nil
      rec.stalled     = nil
      rec.lance       = nil
      rec.paid        = nil

      local e = rec.entity
      if e and e.valid then
        -- Nothing of the old type is left to adopt, but a player who has already
        -- rebuilt before loading, or who is pasting from a blueprint, should not
        -- have to wait for a separate pass.
        pylon.adopt_existing(rec)
        placement.foundation(e)
        placement.ghost_pylons(e)
      end
    end

    game.print{"oppenheimer.banks-rebuilt"}
  end,

  -- 6 -> 7. THE CHAMBER BECOMES A GAUGE (0.12.0).
  --
  -- Cells are no longer ammunition. turret.sync_cells creates and destroys them
  -- to track what is in the capacitor banks, so a chamber holding cells that no
  -- charge accounts for is a chamber reading a number that is not true.
  --
  -- The first sync_cells tick would clear them anyway -- rec.cells is nil on an
  -- old record, so the fast path is skipped and the inventory is read for real.
  -- Doing it here instead means the correction happens at load, in one place,
  -- with a line saying why, rather than as an invisible side effect of a fast
  -- path that could later be optimised away.
  --
  -- THE CELLS ARE DESTROYED, NOT HANDED BACK, and that is a deliberate choice
  -- rather than an oversight. Handing them back gives the player a stack of an
  -- item that is now hidden, has no recipe, cannot be crafted, cannot be
  -- requested, and would be deleted again the moment it was put in a gun. The
  -- honest version of "your ammunition is obsolete" is to say so once and clear
  -- it; the dishonest version is a chest full of something that looks like it
  -- must still be good for something. Cells already crafted and sitting in
  -- player inventories or chests are out of reach of this and will simply stay
  -- there, inert.
  --
  -- The power rescale needs no migration of its own. standby_draw, the buffers
  -- and cost_per_shot are all prototype or config values read fresh each load,
  -- and the banks themselves are re-created by the prototype change -- an
  -- existing pylon picks up the new buffer_capacity without anything here.
  [6] = function()
    local cleared = 0
    for _, rec in pairs(storage.turrets or {}) do
      rec.cells = 0
      local e = rec.entity
      if e and e.valid then
        local inv = e.get_inventory(defines.inventory.artillery_turret_ammo)
        if inv then
          local had = inv.get_item_count(N.shell)
          if had > 0 then
            inv.remove{name = N.shell, count = had}
            cleared = cleared + had
          end
        end
      end
    end
    if cleared > 0 then
      game.print{"oppenheimer.cells-converted", tostring(cleared)}
    end
  end,

  -- 7 -> 8. THE RATE REPLACES THE YIELD SELECTOR (0.13.0).
  --
  -- A saved record carries rec.yield_target -- one of six fixed fractions of a
  -- shot that was 667 MJ. A standard shot is now 160 GJ and the input is a
  -- WATTAGE, so that fraction means something different and cannot simply be
  -- kept: a record left holding 1.50 would open the panel showing 15 GJ/s and a
  -- 240 GJ shot, which is not what anyone chose.
  --
  -- Every installation is therefore set to the default rate, deliberately the
  -- modest one (1 GJ/s), and told so. A gun that silently inherited the maximum
  -- draw across a version bump would brown out the base on its next shot with no
  -- line anywhere explaining why.
  --
  -- The banks also have to be released from whatever buffer the old model left
  -- them holding: 0.13.0 writes electric_buffer_size every tick, but a bank
  -- belonging to a turret in a state that does not run the meter would keep a
  -- stale size forever. set_buffer on the next tick fixes it; zeroing here means
  -- it is fixed before anything reads it.
  [7] = function()
    local turret = deps.turret
    for _, rec in pairs(storage.turrets or {}) do
      turret.set_rate(rec, C.power.default_rate)
      rec.paid  = nil
      rec.spool = 0
    end
    game.print{"oppenheimer.rate-reset",
               tostring(math.floor(C.power.default_rate / 1000000 + 0.5))}
  end,

  -- 8 -> 9. THE YIELD MODEL (0.14.0), and the thing that has to be re-derived is
  -- not the rate -- it is what the rate is a PERCENTAGE OF.
  --
  -- reference_rate moved 10 GJ/s -> 36 GJ/s, so cost_per_shot moved 160 GJ ->
  -- 576 GJ. rec.rate is watts and still means exactly what it meant: a load on
  -- the grid, unchanged. rec.yield_target is a DERIVED cache of that same
  -- quantity as a fraction of a standard shot, and every save at version 8 has
  -- one computed against the old denominator -- so an installation set to
  -- 10 GJ/s would go on reporting 100% while actually ordering 28%, and the tier
  -- table would pick a detonation three steps too big.
  --
  -- The wattage is deliberately PRESERVED rather than reset the way 7 did. The
  -- player chose a grid load and that choice is still meaningful and still legal;
  -- only its percentage moved. set_rate re-clamps (the old 100 MW floor is below
  -- the new 360 MW one) and rewrites the cache from the watts, which is the one
  -- direction that cannot lose information.
  [8] = function()
    local turret = deps.turret
    for _, rec in pairs(storage.turrets or {}) do
      turret.set_rate(rec, rec.rate or C.power.default_rate)
    end
    -- Sweeps and previews are new keys; ensure() creates them. Nothing to move.
    game.print{"oppenheimer.yield-rescaled",
               tostring(math.floor(C.power.reference_rate / 1000000000 + 0.5))}
  end,

  -- 9 -> 10. THE LANCE SHRANK AND THE STAGES CHANGED SHAPE (0.20.0).
  --
  -- Three things in a 0.19.x save cannot run under 0.20.0:
  --   * a sweep or a collapse in flight has the old record shape -- no front,
  --     buckets keyed by the old 48 bands -- and may name puff prototypes for
  --     yield steps above 100%, which no longer exist. They are dropped: a
  --     detonation mid-wave at the save simply ends.
  --   * a lance lit at an old top-of-dial yield names beam prototypes that no
  --     longer exist (the engine removed those entities with their prototypes),
  --     and its record has no fire front. The record is cleared and the gun
  --     stood down; the committed charge is lost, the same trade 4 -> 5 made.
  --   * an installation set above the new ceiling is clamped to 100%.
  [9] = function()
    local turret = deps.turret
    storage.sweeps = {}
    storage.implosions = {}
    local clamped = 0
    for _, rec in pairs(storage.turrets or {}) do
      local L = rec.lance
      if L then
        if L.core and L.core.valid then L.core.destroy() end
        if L.halo and L.halo.valid then L.halo.destroy() end
        rec.lance = nil
      end
      if rec.state == turret.FIRE then
        rec.state       = turret.STANDBY
        rec.state_since = game.tick
        rec.said        = nil
        rec.designated  = nil
        rec.spool       = 0
        rec.discharged  = nil
        rec.discharged_at = nil
        rec.stalled     = nil
        rec.paid        = nil
      end
      local before = rec.rate or C.power.default_rate
      if turret.set_rate(rec, before) < before then clamped = clamped + 1 end
    end
    game.print{"oppenheimer.rescaled-020", tostring(clamped)}
  end,

  -- 10 -> 11 (0.27.0). storage.groundworks and storage.reticle, both created
  -- empty by ensure(). Nothing to convert: existing pads are re-laid in the new
  -- floor plan by control.lua's configuration-change pass, and an existing
  -- complete installation simply commissions once on its next bucket step.
  [10] = function() end,

  -- 11 -> 12 (0.28.0). THE LAMPS MOVE. All twenty old slots sat under bank
  -- art (C.lamp_slot_defs' header). Real lamps are teleported onto the new
  -- bracket, ghosts cleared and re-placed; nothing the player built is
  -- deleted. Searched out to the old layout's own reach (the pad's corner),
  -- not the new one's. The pad's slot marks are re-laid by control.lua's
  -- configuration-change pass, which runs after this.
  [11] = function()
    local old_reach = C.installation_extent() + 4
    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if e and e.valid then deps.placement.relocate_lamps(e, old_reach) end
    end
  end,

  -- 12 -> 13 (0.29.0). TWO UNRELATED SHAPE CHANGES, ONE RELEASE.
  --
  -- (a) THE LAMPS MOVE AGAIN: the L-brackets become runway pairs along the
  -- beam lanes, 20 slots -> 24. Same mechanism as 11 -> 12; the four extra
  -- slots are ghosted. The pad itself is re-laid by control.lua's
  -- configuration-change pass.
  --
  -- (b) THE BUFFERED AND FUEL-CELL BANK TIERS ARE GONE. Only the standard
  -- capacitor bank remains. Same mechanism as 5 -> 6's own note: a prototype
  -- that no longer exists does not survive a save at all -- the engine drops
  -- every entity of that name before any migration runs. So there is nothing
  -- here to destroy, only stale bookkeeping left pointing at what the engine
  -- already deleted:
  --   * storage.pylons entries for the vanished entities
  --   * rec.pylons slot links keyed to those now-dead unit numbers, which
  --     would otherwise read as "occupied" forever and block a replacement
  --     bank from ever linking to that slot
  -- Any freed slot is re-ghosted with the one surviving tier, same as 5 -> 6
  -- did for the whole bank array.
  [12] = function()
    local placement = deps.placement

    local old_reach = C.installation_extent() + 4
    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if e and e.valid then placement.relocate_lamps(e, old_reach) end
    end

    local touched = 0
    for _, rec in pairs(storage.turrets or {}) do
      local dropped = false
      for side, pun in pairs(rec.pylons or {}) do
        local link = storage.pylons[pun]
        if not (link and link.entity and link.entity.valid) then
          rec.pylons[side] = nil
          storage.pylons[pun] = nil
          dropped = true
        end
      end
      local e = rec.entity
      if dropped and e and e.valid then
        placement.ghost_pylons(e)
        touched = touched + 1
      end
    end
    if touched > 0 then
      game.print{"oppenheimer.banks-tiers-removed", tostring(touched)}
    end
  end,

  -- 13 -> 14. NOTHING TO DO. Two builds of 0.29.0 stamped saves differently
  -- (13 and 14) while step 12 was being merged; this no-op puts both on the
  -- same road into 14 -> 15.
  [13] = function() end,

  -- 14 -> 15 (0.31.0). 36 BANKS IN 3x3 CLUSTERS.
  --
  -- The 16-bank slots are a subset of the 36 (rows 10 and 14 of 10/14/18), so
  -- every bank stays where it is and control.lua's re-adopt links it. The
  -- MASTS cannot stay: the old ones stand at (+-18, +-18), which is now each
  -- cluster's corner bank, and their slot moved out to (+-22, +-22). Each is
  -- TELEPORTED -- never deleted, the player built it -- if its new slot is
  -- clear, with its copper wires put back (whether teleport keeps a wire is
  -- not documented, so every connection is recorded first and restored), and
  -- adjacent masts are wired to each other so the ring still takes one drop.
  -- A mast that cannot move stays put and is reported. Then the lamps move
  -- (24 -> 32) and every empty slot is ghosted. The pad is re-laid by
  -- control.lua after this.
  [14] = function()
    local placement = deps.placement
    local OLD = 18   -- the 16-bank build's C.substation_offset()
    local moved, stuck = 0, 0
    local wires_of, rewire = mast_wires_of, mast_rewire

    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if e and e.valid then
        local c, surface = e.position, e.surface
        -- [slot key] = this installation's mast for that corner, wherever it
        -- ended up. Searched ONLY at this installation's own old and new
        -- slots: a radius search round the gun reaches a neighbour's masts at
        -- the old 48-tile spacing.
        local mine, sign = {}, {}
        for _, slot in ipairs(C.substation_slot_defs()) do
          local sx = slot.ox < 0 and -1 or 1
          local sy = slot.oy < 0 and -1 or 1
          sign[slot.key] = {sx, sy}
          local from = {x = c.x + sx * OLD, y = c.y + sy * OLD}
          local to   = {x = c.x + slot.ox, y = c.y + slot.oy}
          for _, m in pairs(surface.find_entities_filtered{
              position = from, radius = C.substation.link_tolerance, force = e.force}) do
            if m.valid and m.name == "entity-ghost" and m.ghost_name == N.substation then
              m.destroy()   -- an unbuilt mast: nothing to keep
            elseif m.valid and m.name == N.substation then
              local keep = wires_of(m)
              if surface.can_place_entity{name = m.name, position = to, force = m.force}
                 and m.teleport(to) then
                rewire(m, keep)
                moved = moved + 1
              else
                stuck = stuck + 1
              end
              mine[slot.key] = m
            end
          end
          if not mine[slot.key] then
            local here = surface.find_entities_filtered{
              name = N.substation, position = to,
              radius = C.substation.link_tolerance, force = e.force}
            if here[1] then mine[slot.key] = here[1] end
          end
        end

        -- The mast ring: each mast to the two that share a side with it.
        for ka, a in pairs(mine) do
          for kb, b in pairs(mine) do
            local sa, sb = sign[ka], sign[kb]
            if ka < kb and a.valid and b.valid
               and ((sa[1] == sb[1]) ~= (sa[2] == sb[2])) then
              rewire(a, {{target = b.get_wire_connector(COPPER, true)}})
            end
          end
        end

        placement.relocate_lamps(e, C.installation_extent() + 4)
        placement.ghost_pylons(e)
      end
    end
    if moved + stuck > 0 then
      game.print{"oppenheimer.scaled-36", tostring(moved), tostring(stuck)}
    end
  end,

  -- 15 -> 16 (0.37.0). 32 BANKS -- THE MAST MOVES INTO THE HOLE.
  --
  -- Each cluster's centre cell -- the 36-bank build's ninth bank, standing
  -- exactly on the diagonal at corner_offset -- is now reserved for that
  -- cluster's own mast (C.pylon_slot_defs's "corners" branch,
  -- C.substation_offset). Unlike 14 -> 15, where masts moved OUT onto open
  -- ground, this mast has to move IN, onto a tile a real bank stands on -- so
  -- the bank comes out first, for every cluster, before any teleport is tried.
  --
  -- THE BANK IS NEVER SILENTLY DELETED. Same standing rule as
  -- placement.reject() and every migration before this one that has had to
  -- take something back: destroyed with raise_destroy so pylon.on_removed
  -- does its own bookkeeping through the ordinary event path, and spilled on
  -- the ground beside the installation rather than vanished -- there is no
  -- single player to hand it to from on_configuration_changed the way a live
  -- build event has one.
  --
  -- NOT responsible for re-linking or re-laying the pad: control.lua's own
  -- on_configuration_changed handler unconditionally drops and re-adopts
  -- every installation's pylons and re-pours the foundation AFTER
  -- schema.migrate() returns, the same division of labour step 12 already
  -- relies on. This step only has to get the PHYSICAL entities into their new
  -- positions before that pass looks for them -- and relocate the lamps and
  -- re-ghost empty slots, which nothing else does.
  [15] = function()
    local placement = deps.placement
    local pylon     = deps.pylon
    local OLD_MAST  = 22   -- the 36-bank build's C.substation_offset()
    local co        = C.pylon.corner_offset
    local returned, moved, stuck = 0, 0, 0

    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if e and e.valid then
        local c, surface, force = e.position, e.surface, e.force

        for _, sign in ipairs({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) do
          local sx, sy = sign[1], sign[2]
          local centre = {x = c.x + sx * co, y = c.y + sy * co}
          local from   = {x = c.x + sx * OLD_MAST, y = c.y + sy * OLD_MAST}

          -- Vacate the centre cell: mine the bank standing there (spilled,
          -- not deleted), or clear a ghost -- nothing to keep either way.
          for _, b in pairs(surface.find_entities_filtered{
              position = centre, radius = C.pylon.link_tolerance, force = force}) do
            if b.valid and b.name == "entity-ghost" and pylon.NAMES[b.ghost_name] then
              b.destroy()
            elseif b.valid and pylon.NAMES[b.name] then
              local pos = b.position
              b.destroy{raise_destroy = true}
              surface.spill_item_stack{
                position = pos, stack = {name = N.pylon, count = 1},
                enable_looted = false, force = force, allow_belts = false,
              }
              returned = returned + 1
            end
          end

          -- Move that cluster's mast in, from its old outer slot.
          for _, m in pairs(surface.find_entities_filtered{
              position = from, radius = C.substation.link_tolerance, force = force}) do
            if m.valid and m.name == "entity-ghost" and m.ghost_name == N.substation then
              m.destroy()   -- an unbuilt mast: nothing to keep
            elseif m.valid and m.name == N.substation then
              local keep = mast_wires_of(m)
              if surface.can_place_entity{name = m.name, position = centre, force = m.force}
                 and m.teleport(centre) then
                mast_rewire(m, keep)
                moved = moved + 1
              else
                stuck = stuck + 1
              end
            end
          end
        end

        placement.relocate_lamps(e, C.installation_extent() + 4)
        placement.ghost_pylons(e)
      end
    end
    if returned + moved + stuck > 0 then
      game.print{"oppenheimer.scaled-32",
                 tostring(returned), tostring(moved), tostring(stuck)}
    end
  end,

  -- 16 -> 17 (0.38.0). THE FLOOR AND THE LAMPS ARE BAKED FROM A REAL BLUEPRINT.
  --
  -- Through 0.37.0 the pad (rim/field/lane/ring/socket) and the 24 runway
  -- lamps were both generated from config formulas. 0.38.0 replaces both with
  -- static data baked from the user's own exported pad (tools/bp_to_plan.py,
  -- lib/foundation_plan.lua) -- the real design is hand-authored and never
  -- reduced to a clean formula. Bank/mast positions are UNCHANGED (they
  -- already matched this same blueprint exactly, confirmed 0.37.0), so
  -- nothing here has to move hardware.
  --
  -- Same division of labour as 12 and 15: this step only relocates the
  -- lamps (relocate_lamps teleports real ones to the nearest new slot;
  -- ghosts are simply cleared and rebuilt at the new positions). The floor
  -- itself is NOT re-poured here -- control.lua's on_configuration_changed
  -- handler unconditionally calls placement.foundation() for every
  -- installation after schema.migrate() returns, same as every version
  -- before this one.
  [16] = function()
    local placement = deps.placement
    local old_reach = C.installation_extent() + 4
    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if e and e.valid then placement.relocate_lamps(e, old_reach) end
    end
  end,

  -- 0.35.0-0.39.0 wrote LuaEntity.power_usage on every linked bank, which is
  -- an engine-side burn out of the buffer (see scripts/pylon.lua). The value
  -- persists on the entity in the save, so stopping the writes is not enough:
  -- zero it on every bank on every surface, linked or not -- a bank orphaned
  -- by a mined turret kept whatever it was last given.
  [17] = function()
    for _, surface in pairs(game.surfaces) do
      for _, e in pairs(surface.find_entities_filtered{name = N.pylon}) do
        if e.power_usage ~= 0 then e.power_usage = 0 end
      end
    end
  end,

  -- 18 -> 19 (0.45.0). THE GROUND-FIRE TRAIL. storage.sweeps records gained
  -- fw_stamp_r/fw_layer_n (scripts/detonate.lua's draw_firewave). Same
  -- mechanism as 9 -> 10's own front.lua rework: a sweep record's SHAPE
  -- changed, and a sweep in flight at the moment of upgrade is a handful of
  -- seconds of one detonation, not state worth migrating field by field.
  -- Dropped outright; a detonation mid-wave at the save simply ends.
  [18] = function()
    storage.sweeps = {}
  end,

  -- 19 -> 20 (0.47.0). THE RELEASE FIREBALL AND THE SHARED INSTABILITY.
  -- storage.sweeps records gained `released` (has the centre fireball been
  -- put down -- scripts/detonate.lua latches it on the sweep's first tick).
  -- A record saved before this has no such field, so it reads nil: "not yet",
  -- on a wave that may be most of the way to the rim.
  --
  -- detonate.step guards that case on its own (`elapsed <= 1`) and would
  -- survive without this step. It is here anyway, on the same reasoning
  -- 18 -> 19 used: a sweep in flight is a few seconds of one detonation, not
  -- state worth reasoning about field by field, and two independent reasons
  -- for a fireball not to appear in the middle of an old wave is the right
  -- number for something that cannot be tested without a save from the
  -- previous version.
  [19] = function()
    storage.sweeps = {}
  end,

  -- 20 -> 21. SCARS: schema.ensure creates storage.scars. In-flight sweeps are
  -- dropped (their fronts lack a generation bound); craters made earlier stay
  -- unrecorded.
  [20] = function()
    storage.scars = {}
    storage.sweeps = {}
  end,

  -- 21 -> 22. Nothing to do (see 28 -> 29).
  [21] = function() end,

  -- 22 -> 23. THE OVERPOWER BAND: turret records gain charge_segs /
  -- cycle_compression / survey / surveying, lances gain strike / owner / omega /
  -- power_total, and schema.ensure creates storage.strikes. A sequence in flight
  -- is ended, not migrated: a lance with no strike never detonates.
  [22] = function()
    storage.strikes = {}
    storage.strike_next = 0
    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if rec.lance then
        local L = rec.lance
        if L.core and L.core.valid then L.core.destroy() end
        if L.halo and L.halo.valid then L.halo.destroy() end
        rec.lance = nil
      end
      rec.survey, rec.surveying = nil, nil
      rec.charge_segs, rec.cycle_compression = nil, nil
      rec.spool, rec.designated, rec.prep = 0, nil, nil
      rec.discharged, rec.discharged_at, rec.charge_seg = nil, nil, nil
      if rec.state == "fire" or rec.state == "aim" then
        rec.state = "cooldown"
        rec.state_since = game.tick
        rec.said = nil
      end
      if e and e.valid then rec.charge = 0 end
    end
  end,

  -- 23 -> 24. STRIKE GROUPS OWN THE SPHERE. A group in flight has a different
  -- shape and its lances point at it by id, so shots in flight are ended: the
  -- beams go out and nothing detonates. Guns that are not firing are untouched.
  [23] = function()
    storage.strikes = {}
    for _, rec in pairs(storage.turrets or {}) do
      local L = rec.lance
      if L then
        if L.core and L.core.valid then L.core.destroy() end
        if L.halo and L.halo.valid then L.halo.destroy() end
        rec.lance = nil
      end
    end
  end,

  -- 24 -> 25. THE BATTERY, AND THE SURVEY THAT IS GONE.
  --
  -- The designator lock and the per-installation grid survey were both removed:
  -- installations are permanently linked now, and the charge is shortened by
  -- OVERCLOCK rather than by a load test. storage.locks and the per-record
  -- survey fields are dead, and a leftover survey_off would silently do nothing
  -- while looking like a setting.
  [24] = function()
    storage.locks = nil
    for _, rec in pairs(storage.turrets or {}) do
      rec.survey, rec.surveying, rec.survey_off = nil, nil, nil
    end
  end,

  -- 25 -> 26. GROUND FIRE: schema.ensure creates storage.groundfires. A sweep
  -- in flight has no record and lays no fire; the rest of it runs on.
  [25] = function()
    storage.groundfires = {}
  end,

  -- 26 -> 27. COOLING CRATERS: schema.ensure creates storage.craters. Craters
  -- painted before it keep their floor as it is.
  [26] = function()
    storage.craters = {}
  end,

  -- 27 -> 28. THE GLAZE: cooling craters and ground fire run on the glaze's
  -- clock. Craters already cooling stop where they are, keeping their liquid maps
  -- only while a sweep still paints them; their fire goes out.
  [27] = function()
    local live = {}
    for _, sw in ipairs(storage.sweeps or {}) do
      if sw.crater then live[sw.crater] = true end
    end
    for _, cr in ipairs(storage.craters or {}) do
      cr.cooling = nil
      if not live[cr] then cr.wet, cr.gen = nil, nil end
    end
    storage.craters = {}
    storage.groundfires = {}
  end,

  -- 28 -> 29. Unwatched kills leave no body: drop storage.bodies.
  [28] = function()
    storage.bodies = nil
  end,
}

--- Run every migration step between the saved version and the current one.
--- Call ONLY from on_configuration_changed.
function schema.migrate()
  schema.ensure()
  local from = storage.version or schema.VERSION
  while from < schema.VERSION do
    local step = steps[from]
    if step then step() end
    from = from + 1
    storage.version = from
  end
end

-- =============================================================================
-- Record access
-- =============================================================================

--- Is this turret record still usable? Drops it if not.
-- @return boolean
function schema.valid(rec)
  if not rec then return false end
  -- Name, not just validity. A record whose entity is alive but is not our
  -- turret is corrupt, not usable -- and checking it HERE means a bad record
  -- already sitting in someone's save is dropped on its next bucket tick,
  -- through the existing forget path, with no migration needed.
  if rec.entity and rec.entity.valid and rec.entity.name == N.turret then
    return true
  end
  if rec.unit_number then schema.forget_turret(rec.unit_number) end
  return false
end

--- Create and register a turret record.
function schema.add_turret(entity)
  if not (entity and entity.valid) then return nil end
  -- The function that writes storage.turrets validates what it writes. A
  -- mis-dispatched build event once put a pylon in here, and the bad record
  -- outlived the crash that came immediately after it.
  if entity.name ~= N.turret then return nil end
  local un = entity.unit_number
  if not un then return nil end

  local rec = {
    unit_number = un,
    entity      = entity,
    pylons      = {},
    -- [mast unit_number] = LuaEntity. A set, not slots: nothing depends on which
    -- corner a mast stands in.
    masts       = {},
    charge      = 0.0,
    -- The chamber gauge's last written reading (0.12.0). Held here so
    -- turret.sync_cells can skip an inventory read on the overwhelming majority
    -- of ticks -- an installation at rest wants zero cells and already has zero.
    -- It is a CACHE, not the truth: the inventory is the truth, and every tick
    -- where the wanted count is non-zero re-reads it, so a player pulling cells
    -- out of a charging gun is corrected on the next tick rather than believed.
    cells       = 0,
    -- The charge rate this installation is set to, in watts (0.13.0). THE knob:
    -- shot = rate x the charge window, and the buffer meter turns it into a real
    -- draw. Written only through turret.set_rate, which also refreshes the
    -- derived yield_target beside it.
    rate        = C.power.default_rate,
    yield_target = C.charge.yield_default,
    state       = "idle",
    state_since = game.tick,
  }
  storage.turrets[un] = rec

  local bucket = un % C.control.update_buckets
  local list = storage.buckets[bucket]
  list[#list + 1] = un

  return rec
end

--- Drop a turret record and everything that points at it.
function schema.forget_turret(unit_number)
  local rec = storage.turrets[unit_number]
  if rec then
    for _, pylon_un in pairs(rec.pylons or {}) do
      storage.pylons[pylon_un] = nil
    end
    for mast_un in pairs(rec.masts or {}) do
      storage.masts[mast_un] = nil
    end
  end
  storage.turrets[unit_number] = nil

  local bucket = unit_number % C.control.update_buckets
  local list = storage.buckets[bucket]
  if list then
    for i = #list, 1, -1 do
      if list[i] == unit_number then table.remove(list, i) end
    end
  end

  storage.warn = storage.warn or {}
  local warn = storage.warn[unit_number]
  if warn and warn.valid then warn.destroy() end
  storage.warn[unit_number] = nil

  local ids = storage.render[unit_number]
  if ids then
    for _, id in pairs(ids) do
      -- TYPE-CHECKED, not paranoia: the render bag also carries two plain
      -- scalars (bag.style, bag.sig), and `id.valid` on a NUMBER is a hard
      -- error (no metatable) -- mining any installation with built VFX would
      -- throw here without this guard. scripts/render.lua's own drop() checks
      -- the same way.
      local t = type(id)
      if (t == "table" or t == "userdata") and id.valid then id.destroy() end
    end
    storage.render[unit_number] = nil
  end

  -- 0.27.0. Most reticle objects target positions, not the gun, so they do not
  -- die with it. Nested (bulb/glow lists, the commission record). RENDER
  -- OBJECTS ONLY, by object_name: the commission record also holds the MAST
  -- ENTITIES, and a bare `.destroy()` on anything with one would delete them.
  if storage.groundworks then storage.groundworks[unit_number] = nil end
  local rb = storage.reticle and storage.reticle[unit_number]
  if rb then
    local function kill(o)
      local t = type(o)
      if t ~= "table" and t ~= "userdata" then return end
      local ok, name = pcall(function() return o.object_name end)
      if ok and name == "LuaRenderObject" then
        if o.valid then o.destroy() end
      elseif ok and name == nil and t == "table" then
        for _, v in pairs(o) do kill(v) end
      end
    end
    kill(rb)
    storage.reticle[unit_number] = nil
  end
end

--- Turret records due for update on this tick's bucket.
-- @param bucket number 0 .. update_buckets-1
-- @return array of records, dead ones already dropped
function schema.bucket(bucket)
  local out = {}
  local list = storage.buckets[bucket]
  if not list then return out end
  for i = #list, 1, -1 do
    local un = list[i]
    local rec = storage.turrets[un]
    if schema.valid(rec) then
      out[#out + 1] = rec
    elseif list[i] == un then
      -- schema.valid(), when `rec` existed but was dead, already removed this
      -- exact entry via forget_turret() -- from THIS SAME LIST, since it is the
      -- one storage.buckets[bucket] gets to by the identical un % update_buckets
      -- arithmetic add_turret used. Removing it again at index i would delete
      -- whatever forget_turret's own table.remove shifted into that slot: a
      -- turret still standing, unschedule from every future bucket tick with
      -- nothing left to notice (its record survives in storage.turrets, so
      -- adopt_orphans never re-adds it). Only remove here when `un` is still
      -- sitting at `i` -- i.e. `rec` was nil to begin with and forget_turret was
      -- never called for it.
      table.remove(list, i)
    end
  end
  return out
end

--- Count of live turret records. table_size, never #, because of the holes.
function schema.turret_count()
  return table_size(storage.turrets)
end

-- The battery: the installations that fire as one weapon, and the converged
-- shot they add up to. Here because schema owns storage.turrets and requires
-- only config; render.lua and prepare.lua cannot require turret.lua.

--- Charge rate in watts, clamped to the dial.
-- CRITICAL: the only clamp. turret.rate delegates here.
function schema.rate(rec)
  return C.clamp_rate(rec.rate or C.power.default_rate)
end

--- One installation's dial fraction: 1.0 is a standard shot.
function schema.fraction(rec)
  return schema.rate(rec) * C.charge_window() / C.charge.cost_per_shot
end

-- Per-tick memo of the crew lists, by force and surface.
-- NEVER read across a tick boundary: it holds no state between ticks.
local crew_tick, crew_cache

--- Every live installation of this one's force on its surface, lowest
--- unit_number first.
function schema.crew(rec)
  local e = rec.entity
  if not (e and e.valid) then return {rec} end

  local tick = game.tick
  if crew_tick ~= tick then crew_tick, crew_cache = tick, {} end
  local key = e.force.index .. ":" .. e.surface.index
  local got = crew_cache[key]
  if got then return got end

  got = {}
  for _, r in pairs(storage.turrets or {}) do
    local re = r.entity
    if re and re.valid and re.force == e.force and re.surface == e.surface then
      got[#got + 1] = r
    end
  end
  if #got == 0 then got[1] = rec end
  table.sort(got, function(a, b) return a.unit_number < b.unit_number end)
  crew_cache[key] = got
  return got
end

--- The converged shot this installation is part of. `at` keeps only members
--- designated within C.turret.confirm_tolerance of it; `state` only members in
--- the same state as the caller's.
-- @return number  yield DELIVERED, clamped to C.charge.group_cap
-- @return number  lances counted, capped at C.beam.convergence.max_lances
-- @return table   those members, lowest unit_number first
-- @return number  the ORDER: the biggest dial in the group, which sets the crater
function schema.group(rec, at, state)
  local tol2 = C.turret.confirm_tolerance * C.turret.confirm_tolerance
  local recs, sum, order = {}, 0, 0
  for _, r in ipairs(schema.crew(rec)) do
    local take = (state == nil or r.state == state)
    if take and at then
      local d = r.designated
      take = d ~= nil
             and (at.x - d.x) * (at.x - d.x) + (at.y - d.y) * (at.y - d.y) <= tol2
    end
    if take and #recs < C.beam.convergence.max_lances then
      local f = schema.fraction(r)
      recs[#recs + 1] = r
      sum = sum + f
      if f > order then order = f end
    end
  end
  if #recs == 0 then
    recs[1] = rec
    sum = schema.fraction(rec)
    order = sum
  end
  return math.min(sum, C.charge.group_cap), #recs, recs, order
end

return schema
