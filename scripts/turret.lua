-- scripts/turret: per-turret charge state machine and firing sequence.

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
local schema = require("scripts.schema")
local pylon  = require("scripts.pylon")
local render = require("scripts.render")
local logistics = require("scripts.logistics")
local audio     = require("scripts.audio")
local impact    = require("scripts.impact")
local front     = require("scripts.front")
local beam      = require("scripts.beam")
local prepare   = require("scripts.prepare")
local reticle   = require("scripts.reticle")
local installfx = require("scripts.installfx")
local profile   = require("scripts.profile")

local turret = {}

-- The spin-up pieces, in source order. The gun plays the LAST k of them so the
-- whine always ends on the bang (C.sound.charge_sound_index).
local CHARGE_SOUNDS = N.sound.charge

turret.IDLE     = "idle"
turret.BOOT     = "boot"
turret.STANDBY  = "standby"
turret.AIM      = "aim"
turret.FIRE     = "fire"
turret.COOLDOWN = "cooldown"
turret.DARK     = "dark"

--- The old hold, kept because it is what RELEASES a stale one. A write is
--- silently ignored on a non-updatable entity, hence the guard.
local function set_gate_disable(rec, allowed)
  local e = rec.entity
  if not (e and e.valid) then return end
  if not e.is_updatable then return end
  local want = not allowed
  if e.disabled_by_script ~= want then
    e.disabled_by_script = want
  end
end

--- Turn the engine's own target-hunting off, once, per turret. Latched on the
--- record rather than written every step: one boolean, never set back.
--
-- PERMANENTLY INERT ON THE electric-turret CHASSIS, BY CONSTRUCTION, NOT
-- DELETED: e.type is always "electric-turret" now, so the guard below returns
-- before ever reaching artillery_auto_targeting (which doesn't exist on this
-- type, and this mod type-guards every class-gated read rather than trusting
-- one). The safety this bought is now attack_parameters.range's job instead
-- (prototypes/entity.lua). Left in place, not removed, for a save that still
-- has a pre-0.23.0 artillery-turret entity standing until the player rebuilds
-- it.
function turret.lock_auto(rec)
  if rec.auto_locked then return end
  local e = rec.entity
  if not (e and e.valid and e.type == "artillery-turret") then return end
  -- Reading this attribute on a non-artillery entity throws, hence the type
  -- check above the comparison rather than below it.
  if e.artillery_auto_targeting then e.artillery_auto_targeting = false end
  rec.auto_locked = true
end

turret.set_gate_disable = set_gate_disable

--- LET THE BARREL GO: clears a leftover disabled_by_script (a turret pasted from
--- an old blueprint, say); latched like lock_auto.
function turret.unhold(rec)
  if rec.unheld then return end
  set_gate_disable(rec, true)
  rec.unheld = true
end

local function goto_state(rec, state)
  if rec.state == state then return end
  -- LEAVING AIM ENDS THE SURVEY. It is an instrument for the hold, and a
  -- staircase frozen mid-climb would resume later against a stale phase clock
  -- and close on a rung it never actually measured.
  rec.state = state
  rec.state_since = game.tick
  -- New state, new things worth saying once.
  rec.said = nil
end

turret.goto_state = goto_state

-- =============================================================================
-- Charge
-- =============================================================================

--- Energy currently available across a turret's four pylons.
-- Delegates to scripts/pylon.lua, which reads LuaEntity.energy straight off the
-- banks. The buffer IS the state -- already saved, already synced, and visible
-- to the player as the status lights -- so there is no second copy in storage
-- that could disagree with it.
local function available_energy(rec)
  return pylon.available(rec)
end

turret.available_energy = available_energy

--- Are all four pylons present and alive?
--- How many banks are actually linked to this installation.
-- Extracted from pylons_ready because 0.13.0 needs the COUNT, not the verdict:
-- the buffer meter splits a rate across the banks that are standing, and the
-- brownout expectation is scaled by the same number.
local function linked_count(rec)
  local n = 0
  for _ in pairs(rec.pylons or {}) do n = n + 1 end
  return n
end

turret.linked_count = linked_count

local function pylons_ready(rec)
  return linked_count(rec) >= C.pylon.count
end

turret.pylons_ready = pylons_ready

-- RESONANCE CELLS ARE A GAUGE READING, not ammunition: sync_cells writes
-- rec.cells every tick from what the capacitor banks hold, and scripts/gui.lua
-- reads it back directly. shell_count/consume_cell are gone -- the
-- electric-turret chassis has no ammo inventory at all
-- (defines.inventory.artillery_turret_ammo doesn't exist on it; get_inventory
-- on a mismatched type returns nil rather than throwing, so either would have
-- quietly done nothing forever).

-- =============================================================================
-- Power draw
-- =============================================================================

-- Running costs are paid every tick, never on the (30-tick) bucket step -- a
-- bucket-sized draw taken in one instant refills at the flow limit and shows up
-- as a sawtooth on the power graph instead of a flat load; see the
-- factorio-modding skill's control-stage.md on chunked energy draws for the
-- general case this avoids.

-- =============================================================================
-- Announcements
-- =============================================================================

--- Say a line to the force, once per battery: a repeat of the same force + key +
--- arguments within C.sound.ui.battery_gap is dropped.
function turret.say(rec, key, ...)
  local e = rec.entity
  if not (e and e.valid) then return end
  local force = e.force

  local gate = force.index .. "|" .. key
  for i = 1, select("#", ...) do
    local a = select(i, ...)
    gate = gate .. "|" .. (type(a) == "string" and a or type(a))
  end

  local seen = storage.say_at
  if not seen then seen = {}; storage.say_at = seen end
  local last = seen[gate]
  if last and game.tick - last < C.sound.ui.battery_gap then return end
  -- Bounded on write: an entry is only useful for battery_gap ticks, and the
  -- key carries arguments (target coordinates among them), so without this the
  -- table would keep one row per distinct thing ever announced.
  if table_size(seen) > 64 then
    for k, v in pairs(seen) do
      if game.tick - v >= C.sound.ui.battery_gap then seen[k] = nil end
    end
  end
  seen[gate] = game.tick

  audio.notify(force, {"oppenheimer." .. key, ...})
end

-- Defined below with the rest of fire control, but called from the FSM above it.
local discharge

--- Play one of the installation's own sounds at the gun, through the
--- broadcast (scripts/audio.lua) rather than a plain world sound -- see that
--- file's header for why a world sound fails at the zoom/map view this weapon
--- is meant to be watched from.
--- Every piece of the firing sequence, heard along the whole line of fire.
--- The muzzle alone puts the spin-up thousands of tiles from a player watching
--- their own target, which is where the sequence is meant to be watched from.
local function play(rec, path)
  local e = rec.entity
  if not (e and e.valid) then return end
  audio.broadcast(e.surface, e.position, path, {to = rec.aim or rec.designated})
end

--- Say something at most once per state entry -- for conditions that persist
--- across steps, like a stalled spool, which would otherwise spam every tick.
local function say_once(rec, key, ...)
  if rec.said == key then return end
  rec.said = key
  turret.say(rec, key, ...)
end

--- One update step for one turret. Runs once every C.control.update_buckets
--- ticks, not every tick -- scale anything rate-based accordingly.
function turret.step(rec)
  if not schema.valid(rec) then return end
  -- Once per turret, ever -- including turrets that were already standing in a
  -- save from before the lock existed, which no on_built will ever fire for.
  turret.lock_auto(rec)
  -- And release any hold left over from when there was a gate. Same reasoning:
  -- a turret that predates this line will never see an on_built.
  turret.unhold(rec)
  -- schema.valid() has already established the entity is alive and is ours.
  local e = rec.entity

  local linked = 0
  for _ in pairs(rec.pylons or {}) do linked = linked + 1 end

  -- COMPLETE, not merely operational -- every bank and every mast.
  -- Losing any of them re-arms the ceremony for when it is finished again.
  local full = linked >= C.pylon.max_count
  if full and C.substation and C.substation.enabled then
    full = table_size(rec.masts or {}) >= #C.substation_slot_defs()
  end
  if not full then rec.commissioned = nil end

  if linked < C.pylon.count then
    -- Losing a bank mid-sequence has to ABORT the sequence -- UNLESS it has
    -- already discharged. Once beam.fire has created the lance the energy is
    -- already out of the banks (rec.spool was fixed at the discharge) and the
    -- beam is playing out on its own clock (beam.sustain, turret.fire_tick);
    -- nothing here can put it back. turret.scrub() already refuses to abort a
    -- discharged shot for exactly that reason ("ONCE THE LANCE IS LIT THE GUN
    -- IS COMMITTED") -- forcing the same abort here on a lost bank would
    -- silently swallow an already-paid-for detonation with no boom and no
    -- explanation, the moment a bank died in the last few seconds of the
    -- sustain. So: abort while still charging (AIM, or FIRE before the
    -- discharge); once discharged, let it finish -- fire_tick's own backstop
    -- calls beam.cut and turret.stand_down on the exact tick the sustain ends,
    -- and THIS branch catches the resulting COOLDOWN as incomplete on the very
    -- next bucket step, same as any other short installation.
    if rec.state == turret.FIRE and rec.discharged then
      render.incomplete(rec, linked)
    else
      if rec.state == turret.AIM or rec.state == turret.FIRE then
        turret.stand_down(rec)
      end
      goto_state(rec, turret.IDLE)
      -- An incomplete installation should not be glowing and arcing -- but it
      -- should say WHY, and that notice has to outlive the render bag.
      render.clear(rec.unit_number)
      render.incomplete(rec, linked)
      return
    end
  else
    render.incomplete_clear(rec.unit_number)
  end

  -- All four present: make sure the cabling/arcs/glow exist, then repaint them
  -- for the current charge. Both are cheap -- build() returns immediately if
  -- the objects already exist, and update() only writes .color.
  render.build(rec)
  render.update(rec)
  if full and not rec.commissioned then
    rec.commissioned = true
    reticle.commission(rec)
  end

  local st = rec.state

  -- --- cold start ----------------------------------------------------------
  -- The draw itself happens in turret.power_tick, every tick, so the grid sees a
  -- flat load. This branch only reads the verdict.
  if st == turret.BOOT then
    if game.tick - rec.state_since >= C.power.boot_ticks then
      goto_state(rec, turret.STANDBY)
      turret.say(rec, "online")
    end
    return
  end

  -- --- brownout and recovery, one measurement, two thresholds --------------
  --
  -- BOTH DIRECTIONS READ THE SAME NUMBER. rec.paid is what the grid actually
  -- delivered into the standby meter over the last bucket step, accumulating in
  -- every state except VENTING and FIRE -- DARK included, so a dark
  -- installation keeps trying to pay its standby draw and "did the grid come
  -- back" is answered by the same arithmetic that asked "did it fail". Two
  -- thresholds rather than one, or the state flaps tick to tick on a
  -- measurement sitting exactly on the line.
  if st ~= turret.COOLDOWN and st ~= turret.FIRE then
    -- The window is the ticks the meter actually ran. A window that starts
    -- mid-step (a state just changed) is carried into the next step, never
    -- judged short: a partial window reads as a brownout.
    local ticks = rec.paid_ticks or 0
    if ticks >= C.control.update_buckets then
      -- Scaled by how many banks are actually standing -- a fixed expectation of
      -- the full standby figure would declare every partial installation
      -- permanently browned out, which with tiering is most of them.
      local expect = C.standby_allowance() * linked * ticks
      local got    = rec.paid or 0
      rec.paid, rec.paid_ticks = 0, 0

      if st == turret.DARK then
        if expect <= 0 or got >= expect * C.power.restart_fraction then
          goto_state(rec, turret.STANDBY)
          turret.say(rec, "restored")
        end
        return
      end

      if expect > 0 and got < expect * C.power.brownout_fraction then
        rec.spool = 0
        rec.designated = nil
        goto_state(rec, turret.DARK)
        turret.say(rec, "dark")
        return
      end
    elseif st == turret.DARK then
      return
    end
  end

  -- --- brownout DURING the charge itself ------------------------------------
  --
  -- THE SAME MEASUREMENT, against the ramp's own per-tick share instead of
  -- standby_allowance: an order the banks physically cannot hold still stalls
  -- to a weak shot (discharge() already handles that -- see `delivered`), this
  -- only catches the grid supplying NOTHING while the ramp is asking for more.
  -- Skipped once the lance is lit -- ONCE THE LANCE IS LIT THE GUN IS
  -- COMMITTED, the same rule turret.scrub() enforces.
  if st == turret.FIRE and not rec.discharged then
    local ticks = rec.fire_paid_ticks or 0
    if ticks >= C.control.update_buckets then
      local expect = rec.fire_expect or 0
      local got    = rec.fire_paid or 0
      rec.fire_paid, rec.fire_expect, rec.fire_paid_ticks = 0, 0, 0
      if expect > 0 and got < expect * C.power.brownout_fraction then
        -- Through stand_down, same as a lost bank mid-sequence: closes the
        -- chamber, clears spool/designated/charge_seg, cancels the pending
        -- lance. Then DARK, not stand_down's own COOLDOWN -- nothing fired,
        -- so there is nothing to vent, only a grid to wait back out.
        turret.stand_down(rec)
        goto_state(rec, turret.DARK)
        turret.say(rec, "dark")
        return
      end
    end
  end

  -- NO GATE HERE, AND NOTHING REPLACES IT (see the Gating section above): the
  -- lance places no flare and lock_auto has stopped the gun hunting for its
  -- own targets, so a loaded chamber commands nothing.
  if st == turret.STANDBY then
    logistics.reload(rec)
    -- Nothing else happens here. No sweep, no acquire, no AI. The gun sits lit
    -- and expensive until a player points the remote at something.
    return

  elseif st == turret.AIM then
    -- Target designated, barrel swinging onto it, banks untouched. Holds
    -- indefinitely: nothing auto-fires and nothing times out. The next thing
    -- that happens is a human pressing CONFIRM.
    --
    return

  elseif st == turret.FIRE then
    -- THE FIRING SEQUENCE, hard-locked to the audio. Nothing here is
    -- power-dependent -- the energy argument was settled in SPOOL, and once
    -- the tape rolls the gun is committed. The discharge itself and the
    -- end-of-tape walk-out both happen in turret.fire_tick, on the TICK, not
    -- here -- this runs on a 30-tick bucket, and half a second of slop against
    -- a fixed-length audio file is audible. What follows is only a backstop:
    -- beam.cut is idempotent and stand_down is guarded by state, so arriving
    -- here late (a bucket step behind fire_tick's own exact-tick walk-out)
    -- costs nothing, and arriving never would strand the installation in FIRE
    -- forever.
    local elapsed = game.tick - rec.state_since
    if rec.discharged
       and elapsed >= C.sound.sequence_ticks_for(C.sound.charge_parts)
                      + C.beam.winddown.ticks + 60 then
      beam.cut(rec)
      turret.stand_down(rec)
    end
    return

  elseif st == turret.COOLDOWN then
    -- research-adjusted -- see config.lua's C.charge.cooldown_for
    -- header. e is already known valid: schema.valid(rec) at the top of
    -- this function established it.
    if game.tick - rec.state_since
       >= C.charge.cooldown_for(e.force) then
      rec.charge = 0
      rec.flare_tick = nil
      rec.aim = nil
      rec.ammo_seen = nil
      goto_state(rec, turret.STANDBY)
      turret.say(rec, "vented")
    end
    return

  else
    -- IDLE, or a state string from a save written before #102. Cold start it.
    goto_state(rec, turret.BOOT)
    turret.say(rec, "booting")
    return
  end
end

-- =============================================================================
-- #103: fire control. Every entry point here is driven by a PLAYER.
-- =============================================================================

--- End a firing sequence and vent. Closes the chamber (an unfired shell goes
--- back to the reserve, never to nowhere) and clears everything the sequence
--- was carrying, so the next designation starts from a clean record.
function turret.stand_down(rec)
  -- Belt and braces. Every ordinary path here has already cut the lance --
  -- beam.sustain self-terminates at the tick decided at ignition, and the state
  -- machine calls beam.cut before this. What is left is the paths that are not
  -- ordinary: a pylon lost mid-sequence, a record going stale. A beam that
  -- outlives its turret would keep drawing across the map with nothing left to
  -- stop it.
  -- NOT a lance still shutting down (C.beam.winddown): it is MEANT to outlive
  -- this call by its own window, and aborting it here would put the light out on
  -- the tick the spin-down starts and drop the detonation with it.
  if not beam.winding(rec) then beam.abort(rec) end
  -- A shot that actually discharged leaves the barrel smoking AND winding down.
  -- One condition for both: the vent smoke is the spin-down made visible, and
  -- C.charge.cooldown_for is floored on the clip so the smoke outlasts it.
  if rec.discharged then
    installfx.vent_start(rec)
    play(rec, N.sound.spindown)
  end
  rec.spool = 0
  rec.designated = nil
  rec.prep = nil
  rec.discharged = nil
  rec.discharged_at = nil
  rec.chamber_mark = nil        -- dead field; cleared so old saves shed it
  rec.stalled = nil
  rec.full_at = nil
  rec.alpha_lances = nil
  rec.charge_seg = nil -- so the next release() starts at 1
  goto_state(rec, turret.COOLDOWN)
end

--- The charge rate this installation is set to, in watts. THE knob.
--
-- Clamped on read as well as on write. A record can carry a rate from a save
-- written before the bounds moved, or one a console command reached in and set,
-- and a rate outside the bounds is a buffer write outside the bounds -- which is
-- the one place in this file where a bad number stops being a display problem
-- and becomes a gun that charges to something nobody asked for.
function turret.rate(rec)
  return schema.rate(rec)
end

--- Set the charge rate. ONE writer, because two numbers have to stay in step.
--
-- `rec.rate` is the truth -- watts, what the player typed, what the grid feels.
-- `rec.yield_target` is a DERIVED cache of the same quantity as a fraction of a
-- standard shot, kept because the tier table, the detonation scaling, the
-- resonance cell count and every readout in the fire-control panel were already
-- written against it. Deriving it here rather than at each of those call sites
-- is what made the rate a drop-in for the old six-step selector instead of a
-- rewrite of everything downstream of it.
-- @return number the rate actually stored, after clamping
function turret.set_rate(rec, watts)
  local w = C.clamp_rate(watts)
  rec.rate = w
  rec.yield_target = w * C.charge_window() / C.charge.cost_per_shot
  return w
end

--- Energy this shot is spooling toward: the rate, held for the charge window.
--
-- Derived from the rate rather than from yield_target, so that if the two ever
-- disagree the WATTS win -- they are what the player set and what the buffer
-- meter is enforcing, and a goal computed from a stale fraction would be a ramp
-- aimed somewhere the grid was never asked to reach.
function turret.spool_goal(rec)
  return turret.rate(rec) * C.charge_window()
end

--- Committed charge as a fraction of a STANDARD shot. Can exceed 1 at 150%.
function turret.spool_fraction(rec)
  return (rec.spool or 0) / C.charge.cost_per_shot
end

--- A player designated a target with the remote. Begin the sequence.
-- @param quiet boolean  skip the force-wide announcement; an alpha strike
--   designates a whole battery at once and says so once for the group.
function turret.designate(rec, position, quiet)
  -- STANDBY is a fresh designation; AIM is the player moving the aim point
  -- before they confirm, which must be allowed or a misclick locks the gun onto
  -- the wrong ground until it is scrubbed. Nothing else may designate: once the
  -- tape is rolling the target is settled.
  if rec.state ~= turret.STANDBY and rec.state ~= turret.AIM then
    return false, rec.state
  end

  -- THE DEAD ZONE, CHECKED BEFORE ANYTHING IS COMMITTED. The gun physically
  -- cannot engage inside min_range -- the prototype's own hardware limit, not a
  -- rule this file invented -- so a target inside it is refused before the
  -- barrel turns or a joule is spent.
  local e = rec.entity
  if not (e and e.valid) then return false, "invalid" end
  local dx, dy = position.x - e.position.x, position.y - e.position.y
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist < C.gun.min_range then return false, "too-close" end

  -- THE DYNAMIC STANDOFF, the real self-safety interlock: min_range above is
  -- fixed hardware, but the danger here is a property of the ORDER (a 30-tile
  -- blast at 1%, 2000 at 150%), so this is computed from the rate CURRENTLY SET
  -- through the same C.yield.radius the designator overlay draws -- the same
  -- fact enforced, not a second one invented, and it refuses one order rather
  -- than deciding whether the gun may work at all.
  local need = C.yield.radius(turret.rate(rec) * C.charge_window())
               * C.gun.blast_clearance
  if dist < need then
    return false, "inside-blast", math.floor(need)
  end

  rec.designated = {x = position.x, y = position.y}
  rec.spool = 0
  -- A new order needs its own preparation (scripts/prepare.lua).
  rec.prep = nil

  -- Chart the fireball ring now, which generates it during the aim; the wave charts the rest.
  local ca = C.blast.rings.chart_ahead
  if ca and ca.enabled and ca.epicenter_at_designate then
    local r = C.yield.radius(turret.rate(rec) * C.charge_window())
              * C.blast.rings.fireball_u + ca.epicenter_margin
    local force, surface = e.force, e.surface
    front.each_ring_run(position.x, position.y, 0, r, function(j, i0, i1)
      force.chart(surface, front.chunk_box(i0, i1, j))
    end)
  end

  -- Queue the pregen square now, so the whole aim hold builds it in the background.
  impact.settle_terrain(e.surface, rec.designated,
    C.yield.radius(turret.rate(rec) * C.charge_window()), false)
  -- A fresh order. The stall detector must not inherit the last one's readings,
  -- or a re-designation looks stuck the instant it starts.
  rec.slew_last  = nil
  rec.slew_stuck = nil
  -- And the status light must not inherit the LAST target's readiness --
  -- without this a re-designation could flash "ready" for one frame before
  -- turret.slew and render.preview have had a tick to re-check the new point.
  rec.aim_aligned   = nil
  rec.terrain_ready = nil

  -- NO FLARE. NOT HERE, NOT LATER, NOT EVER (see the Gating section above). The
  -- mod turns the barrel itself (turret.slew) and creates the beam itself
  -- (scripts/beam.lua), so nothing is ever put on the map for the gun to shoot
  -- at.

  -- Force the timestamp even when already in AIM (goto_state is a no-op on an
  -- unchanged state), so a re-designation resets the "said this already" latch
  -- and the barrel's travel is measured from the new order.
  rec.state = turret.AIM
  rec.state_since = game.tick
  rec.said = nil
  goto_state(rec, turret.AIM)
  -- Deliberately silent. The clip is the FIRING sequence, not ambience, and
  -- starting it here would put the discharge 17 s into the wrong phase.
  if not quiet then
    turret.say(rec, "designated",
               tostring(math.floor(position.x)), tostring(math.floor(position.y)))
  end
  return true
end

--- Release the shot. At full spool this is the shot the player asked for; at
--- partial spool it is a weaker one, landing on target (C.power.reach_floor).
--- The moment the lance actually strikes: C.sound.discharge_at into the
--- sequence, on the strike in the audio. Everything that makes a shot happen is here, not in
--- release() -- release only starts the tape.
function discharge(rec)
  local e = rec.entity
  local t = rec.designated
  if not (e and e.valid and t) then return end

  -- What the banks actually managed to store across the charge window IS the
  -- shot. Nothing was metered into a separate accumulator on the way -- the
  -- capacitors are the only place the energy ever was. Clamped to the order,
  -- because power_tick burns the surplus and a stray joule must not buy a bigger
  -- blast than was paid for.
  local goal   = turret.spool_goal(rec)
  local stored = available_energy(rec)
  rec.spool    = math.min(stored, goal)

  -- TWO DIFFERENT FRACTIONS, and conflating them is a real trap:
  --   delivered  how well the grid met THE ORDER. 25% asked for and 25% stored
  --              is a delivery of 1.0 -- a small shot, perfectly executed.
  --   power      the absolute yield against a standard shot -- what the
  --              detonation is scaled by, and what the player chose.
  local delivered = goal > 0 and (rec.spool / goal) or 0
  local power     = rec.spool / C.charge.cost_per_shot

  -- ZERO JOULES BANKED IS NOTHING TO FIRE: beam.fire has no power floor, and the
  -- brownout detector skips FIRE. Checked before `stalled` so an outage reports
  -- MISFIRE once.
  if rec.spool <= 0 then
    say_once(rec, "misfire")
    return
  end

  if delivered < C.charge.stall_fraction then
    -- The grid could not fill the banks inside the window. The round still
    -- leaves on schedule; it is simply weaker.
    say_once(rec, "stalled")
  end

  -- Short-fall along the bearing, scaled by C.power.reach_floor. At 1.0 (the
  -- shipped value) every round lands where it was aimed and an under-filled
  -- one is punished by yield alone.
  local reach = C.power.reach_floor
                + (1 - C.power.reach_floor) * math.min(delivered, 1)

  local land = {
    x = e.position.x + (t.x - e.position.x) * reach,
    y = e.position.y + (t.y - e.position.y) * reach,
  }

  -- yield_for reads rec.charge, so the committed energy has to be there before
  -- the tier is chosen -- otherwise every shot reports the tier of the LAST one.
  rec.charge = rec.spool or 0
  rec.yield  = turret.yield_for(rec)
  rec.power  = power
  rec.aim    = {x = land.x, y = land.y}

  -- Nothing is spent here: the cells are a reading of the banks, which
  -- power_tick drains across the sustain. Aborting is SCRUB, before the strike.

  -- Re-queue the pregen square at `land`; it blocks only with C.blast.rings.pregen.force_at_strike.
  impact.settle_terrain(e.surface, land,
    C.yield.radius(power * C.charge.cost_per_shot), true)

  -- FIRE THE LANCE -- the entire delivery. beam.fire either created the entity
  -- or it did not; `land` already carries any short-fall correction.
  if not beam.fire(rec, land, power) then
    say_once(rec, "misfire")
    return
  end
  reticle.strike(rec)

  -- THE STRIKE'S OWN HALF OF THE CLIP, TRIGGERED HERE, NOT AT CONFIRM.
  -- Only reachable once beam.fire has actually created the lance -- never on a
  -- misfire (both early returns above) and never on an abort (scrub() already
  -- refuses once rec.discharged is set, and this line is what sets the mood
  -- for it: nothing past this point in the function is skippable). Broadcasting
  -- fresh here, rather than trusting the CONFIRM-time play() call to still be
  -- audible 16 seconds later, is what makes the payoff correct for a player who
  -- designated from the map and has since walked back to the gun.
  -- THE BURN, WHOLE. One piece, one call, nothing for fire_tick to schedule
  -- after it: the burn is the same length at every yield, so there is no
  -- continuation to chain and nothing an abort could still be holding.
  play(rec, N.sound.strike)

  -- "ignite": the ground goes up at the strike and the beam sustains through the
  -- fireball. "cut" (the default) leaves it to beam.cut the sustain later.
  if C.beam.detonate_at == "ignite" and rec.lance and rec.lance.opened then
    -- e.force, so the sweep's kills are credited to whoever fired rather than
    -- to the default force. Evolution and every kill statistic read that.
    -- The opener only: a converged strike has one detonation.
    impact.detonate(e.surface, land, power, e.force)
  end

  -- No EXTRA barrel report layered here: the strike head already has its own
  -- bang on the frame it plays on, and base artillery's cannon over it muddied
  -- the one frame in the sequence that has to land clean. That rule is about
  -- not doubling the transient; cutting the clip and playing each piece at its
  -- own real event is a different thing from stacking two on one.
  turret.say(rec, "lance-away")
end

-- =============================================================================
-- AIMING
--
-- WHY THE MOD TURNS ITS OWN BARREL: an artillery turret only rotates toward a
-- target via an artillery flare, which is also what makes it FIRE -- there is
-- no engine-side "turn but do not shoot". So the mod drives rotation itself:
-- `LuaEntity.orientation` is read/write (confirmed via apiq), turned one step
-- per tick, with no flare ever on the map. Aiming and firing become two
-- separate acts. See the Gating section above for why disabled_by_script
-- can't substitute for this (it also freezes rotation).
-- =============================================================================

--- The orientation the barrel must reach to point at `t`.
-- Factorio orientation is a fraction of a full turn, 0 = north, increasing
-- clockwise -- the same convention as the pylon direction vectors. atan2(dx, -dy)
-- puts 0 at north and increases clockwise: east (dx>0) -> 0.25, south (dy>0) ->
-- 0.5, west -> 0.75. Lua 5.2 has math.atan2; 5.3 folded it into a two-argument
-- math.atan. Factorio is 5.2, but the fallback costs one `or`.
local function bearing_to(e, t)
  local dx, dy = t.x - e.position.x, t.y - e.position.y
  local atan2 = math.atan2 or math.atan
  local want = atan2(dx, -dy) / (2 * math.pi)
  if want < 0 then want = want + 1 end
  return want
end

turret.bearing_to = bearing_to

--- Signed shortest way round the circle from `have` to `want`, in turns.
-- Result is in (-0.5, 0.5]; negative means turn anticlockwise. Doing this with
-- a modulo rather than a chain of if-statements is the whole reason the barrel
-- takes the short way round a target behind it.
local function shortest(have, want)
  local delta = (want - have) % 1
  if delta > 0.5 then delta = delta - 1 end
  return delta
end

--- Read the barrel's orientation, or nil if the attribute is unavailable.
-- Wrapped in pcall and latched: this mod has been bitten once by a class-gated
-- read throwing instead of returning nil, so if orientation turns out to be
-- unreadable here, every gate below opens rather than locking the player out.
--
-- READS/WRITES `orientation` DIRECTLY -- NOT `relative_turret_orientation`.
-- confirmed via apiq against the shipped 2.0.77 spec rather than
-- assumed symmetric with the read: relative_turret_orientation is "nil ...
-- if this entity isn't a vehicle with a vehicle turret or artillery
-- turret/wagon" on READ, but "writing does nothing if the vehicle doesn't
-- have a turret" on WRITE -- a silently accepted no-op, not a throw, so the
-- old write_orientation's pcall reported success while the barrel never
-- moved. That was the right attribute pre-0.23.0 (this mod's chassis was
-- artillery-turret then); the chassis is permanently electric-turret now
-- (prototypes/entity.lua), and the spec is explicit for that case: "for
-- turrets this is the orientation of the weapon" -- `orientation`, full stop.
local function read_orientation(e)
  if storage.no_orientation then return nil end
  local ok, have = pcall(function() return e.orientation end)
  if ok and have then return have end
  storage.no_orientation = true
  return nil
end

--- Point the barrel.
-- @return boolean whether the write took
local function write_orientation(e, o)
  return (pcall(function() e.orientation = o end))
end

-- PUBLIC, ADDITIVE EXPORTS -- no behaviour here changed by these three lines.
-- scripts/arcsweep.lua (the additional, separate hyper-rotate-and-vaporize
-- capability) drives the SAME barrel and needs the SAME pcall-guarded
-- read/write and the SAME shortest-way-round arithmetic this file already
-- got right after two prior orientation bugs (0.26.1, 0.6.0) -- a second,
-- independently-drifting copy of either would be a worse risk than exporting
-- the one this file already tests every tick. Never called from anywhere in
-- the main sequence above; arcsweep never runs while rec.state is AIM/FIRE,
-- so there is no write-order question between the two callers.
turret.shortest          = shortest
turret.read_orientation  = read_orientation
turret.write_orientation = write_orientation

--- Is the barrel actually pointing at what was designated?
-- @return boolean aligned, number|nil how far off (fraction of a turn)
function turret.aimed(rec)
  local e = rec.entity
  local t = rec.designated
  if not (e and e.valid and t) then return false, nil end

  local have = read_orientation(e)
  if not have then return true, nil end

  local off = math.abs(shortest(have, bearing_to(e, t)))
  return off <= C.turret.aim_tolerance, off
end

--- TURN THE BARREL. One step, every tick, while a target is designated and
--- the shot has not been confirmed.
--
-- Runs on the per-tick loop rather than the bucket, because a bucket step is 30
-- ticks and a barrel that jumps 30 steps twice a second is a barrel that
-- teleports. This is a handful of arithmetic ops and one attribute write, and
-- only for turrets that are actually aiming.
--
-- THE STALL DETECTOR is the load-bearing part. Writing `orientation` on a
-- DISABLED entity is the one thing here the spec does not settle: it says the
-- attribute is writable, not that a deactivated entity honours the write. If it
-- silently does not, the observed orientation never moves, the alignment gate
-- never opens, and the gun is bricked in exactly the way it was already bricked
-- once. So: if the barrel has not moved after a second of being commanded to,
-- stop believing in orientation altogether and let every gate open. A gun that
-- snaps to its target late is a bug. A gun that cannot be fired is a brick.
--- The half of the firing sequence that must land on an exact tick, not a
--- bucket step: the sequence is hard-locked to the audio, so a bucket-late
--- discharge or walk-out is audibly behind the sound. Everything else about
--- FIRE stays in the bucket where it belongs.
function turret.fire_tick(rec)
  if rec.state ~= turret.FIRE then return end
  local elapsed = game.tick - rec.state_since

  -- THE REST OF THE SPIN-UP, IN GATED QUARTERS. rec.charge_seg counts
  -- how many of CHARGE_SOUNDS have played; turret.release already played the
  -- first. Each later one only plays if this line is even reached, which the
  -- guard at the top of this function already ties to rec.state == FIRE -- so
  -- turret.scrub()/stand_down() moving the state to COOLDOWN is the entire
  -- abort mechanism here, the same way it already gates beam.sustain and
  -- turret.slew. No separate "was this aborted" flag to keep in step.
  -- rec.charge_seg counts PLAYED SLOTS, 1..C.sound.charge_parts; the file in a
  -- slot is chosen by C.sound.charge_sound_index.
  local segs = C.sound.charge_parts
  if rec.charge_seg and rec.charge_seg < segs then
    local nxt = rec.charge_seg + 1
    if elapsed >= C.sound.charge_trigger_tick(nxt) then
      rec.charge_seg = nxt
      play(rec, CHARGE_SOUNDS[C.sound.charge_sound_index(nxt, segs)])
    end
  end

  local window = C.sound.charge_window_ticks(segs)

  -- THE IONISATION CHANNEL builds along the line of fire across the charge,
  -- then flashes and fades under the lit lance (purely visual -- see
  -- C.heat.haze). Clocked on the audio, like the rest.
  if not rec.discharged then
    profile.start("lance/haze")
    beam.haze(rec, elapsed / math.max(1, window))
    profile.stop("lance/haze")
  else
    beam.haze_handoff(rec)
  end

  if not rec.discharged and elapsed >= window then
    rec.discharged = true
    rec.discharged_at = game.tick
    discharge(rec)
    return
  end

  if rec.discharged
     and elapsed >= C.sound.sequence_ticks_for(segs) then
    beam.cut(rec)
    turret.stand_down(rec)
  end
end

function turret.slew(rec)
  -- AIM *AND* FIRE (until the lance lights): the traverse is deliberately
  -- slower than the charge window, so the barrel should still be coming round
  -- for most of the sequence between CONFIRM and the strike. Once the beam is
  -- lit the gun is committed and the barrel is left alone.
  if rec.state ~= turret.AIM
     and not (rec.state == turret.FIRE and not rec.lance) then
    return
  end

  local e, t = rec.entity, rec.designated
  if not (e and e.valid and t) then return end

  local have = read_orientation(e)
  if not have then
    -- BLIND. Same call turret.aimed already makes: every alignment gate opens
    -- rather than holding the status light on "still rotating" forever with
    -- nothing that could ever resolve it.
    rec.aim_aligned = true
    return
  end

  -- THE VISUAL, NOW SEPARATE FROM THE ENGINE'S OWN RENDERING (Gate 09
  -- fallback -- see prototypes/entity.lua's header). `have` is the entity's
  -- real current orientation regardless of which branch below runs, so this
  -- has to happen before both, not inside either.
  render.sync_head(rec, have)

  local want  = bearing_to(e, t)
  local delta = shortest(have, want)
  local step  = C.turret.slew_speed

  if math.abs(delta) <= step then
    -- Close enough that another full step would overshoot: land exactly on it.
    if delta ~= 0 then write_orientation(e, want) end
    rec.slew_stuck = nil
    rec.slew_last = nil
    rec.aim_aligned = true
    -- SAY SO. The player asked for designate -> rotate -> a message -> confirm,
    -- and without this the only way to learn the barrel had arrived was to press
    -- the designator again and see whether it was refused. Once per arrival:
    -- say_once latches on the key and designate() clears it.
    if rec.state == turret.AIM then say_once(rec, "locked") end
    return
  end

  -- STILL TURNING. Read by render.lua's status-light behaviour() -- see
  -- C.lights: yellow-flashing while this is false, flashing red once it and
  -- rec.terrain_ready (scripts/render.lua's render.preview) both hold.
  rec.aim_aligned = false

  -- Has the barrel actually moved since the last time this ran? Compares
  -- THIS tick's read against the PREVIOUS tick's read -- not against what
  -- was last WRITTEN. 0.26.1: the previous version compared against the
  -- write target instead, which meant a genuinely dead write (have frozen,
  -- so the target computed from it was also the same frozen value every
  -- tick) never satisfied this check and the 20-second give-up below could
  -- never fire -- exactly backwards for a stall detector, and exactly the
  -- silent-forever failure the write_orientation fix above was written to
  -- stop being possible.
  if rec.slew_last and math.abs(rec.slew_last - have) < 1e-9 then
    rec.slew_stuck = (rec.slew_stuck or 0) + 1
    -- This latch opens every alignment gate permanently, for every
    -- installation, so the threshold has to be well clear of any legitimate
    -- traverse stall
    -- while still short enough that a genuinely unaimable gun becomes usable.
    if rec.slew_stuck > 60 * 20 then
      storage.no_orientation = true
      say_once(rec, "aim-blind")
      return
    end
  else
    rec.slew_stuck = 0
  end

  local next_o = (have + (delta > 0 and step or -step)) % 1
  local ok = write_orientation(e, next_o)
  if not ok then
    storage.no_orientation = true
    return
  end
  rec.slew_last = have
end

--- Start the firing sequence. This does NOT fire -- it rolls the tape, and the
--- round leaves 17 seconds later (see discharge). Committing here is the last
--- decision the player gets to make.
function turret.release(rec)
  if rec.state ~= turret.AIM then return false, rec.state end
  if not rec.designated then return false, "no-target" end

  -- TEST MODE IS THE PREPARATION STAGE, and the only thing CONFIRM does in
  -- it. Builds the blast disc's ground and surveys what stands on it
  -- (scripts/prepare.lua); pressing again reports how far it has got. Any
  -- change to the order -- aim point or rate -- needs preparing again. Does
  -- not wait for the barrel: preparing is not firing.
  -- prepare.begin works on the group's holder and returns false for a member
  -- whose order is already being prepared, so a ten-gun press announces once.
  if rec.fire_mode == "test" then
    if not prepare.matches(rec) then
      if prepare.begin(rec) then turret.say(rec, "prepare-begun") end
      return true, "preparing"
    end
    turret.say(rec, "prepare-status", tostring(prepare.percent(rec)))
    return false, "test-mode"
  end

  -- The barrel has to be ON the flare before the tape rolls. Confirming while
  -- the gun is still swinging would start a 17 second charge that ends with the
  -- barrel pointing somewhere else -- which is one of the ways this gun spent a
  -- gigajoule and produced nothing.
  local aligned, off = turret.aimed(rec)
  if not aligned then
    return false, "slewing", off
  end

  -- The ORDER, not the charge: the banks are emptied at designation and don't
  -- start filling until the tape rolls, so what's worth announcing here is what
  -- was asked for; what was achieved is announced at the discharge.
    --
    -- NO DRY-GUN CHECK: every sequence starts dry by design; the brownout
    -- detector and stall warning judge the energy instead.
  -- NOT A LOCK, A WARNING, and only past prepare.needs_prep's radius: inside
  -- it the automatic pregen and the wave's own on-demand generation already
  -- cover the shot regardless, so ready_percent reads 100 without a press.
  -- Beyond it an unprepared zone still fires and still lands where it was
  -- aimed; what it cannot do is damage what is standing on ground the engine
  -- has not generated, because find_entities_filtered returns nothing there.
  -- Switch to TEST and CONFIRM to build it first.
  local ready = prepare.ready_percent(rec)
  if ready < 100 then
    turret.say(rec, "zone-unprepared", tostring(ready))
  end
  rec.discharged = nil
  -- Cleared here as well as in stand_down: a latch left over from an aborted
  -- shot is an EARLIER tick than this shot's state_since, which would measure a
  -- negative fill time and plan the next chain at its shortest.
  rec.full_at = nil

  goto_state(rec, turret.FIRE)

  -- Queue the pregen square so the charge window builds it (C.blast.rings.pregen).
  local e = rec.entity
  if e and e.valid then
    impact.settle_terrain(e.surface, rec.designated,
      C.yield.radius(turret.rate(rec) * C.charge_window()), false)
  end

  -- THE FIRST QUARTER OF THE SPIN-UP ONLY. turret.fire_tick plays
  -- the remaining three, each gated on this turret still being in FIRE --
  -- see config.lua's C.sound header. An abort (turret.scrub) leaves only
  -- whichever quarter is already sounding to play itself out, instead of
  -- the whole 16s clip 0.32.0 still had to accept.
  rec.charge_seg = 1
  play(rec, CHARGE_SOUNDS[C.sound.charge_sound_index(1, C.sound.charge_parts)])
  -- An alpha strike announces itself once for the group (scripts/alpha.lua),
  -- so its members do not each print a release line.
  if not rec.alpha_lances then
    turret.say(rec, "release", C.fmt_rate(turret.rate(rec)),
               string.format("%.0f",
                 C.sound.charge_window_ticks(C.sound.charge_parts) / 60))
  end
  return true
end

--- TEST / LIVE. Only settable before the tape rolls. TEST prepares and
--- surveys the blast zone and never fires; LIVE fires on CONFIRM.
function turret.set_fire_mode(rec, mode)
  if rec.state ~= turret.STANDBY and rec.state ~= turret.AIM then return false end
  rec.fire_mode = (mode == "test") and "test" or nil
  turret.say(rec, mode == "test" and "fire-mode-test" or "fire-mode-live")
  return true
end

--- Stand down without firing. The committed energy is GONE -- it was dumped
--- into the gun, and there is no path back into an accumulator.
function turret.scrub(rec)
  if rec.state ~= turret.AIM and rec.state ~= turret.FIRE then return false end
  -- ONCE THE LANCE IS LIT THE GUN IS COMMITTED. The energy is already leaving as
  -- light and it is already on the ground; there is no version of "stand down"
  -- that puts the sustain of beam back in the capacitors. Cutting it early would
  -- have to mean a partial detonation, which is a yield the player did not choose
  -- arriving by a route that is not the yield selector -- two mechanisms for one
  -- decision. ABORT is a decision about whether to fire, and that decision has
  -- seventeen seconds to be made in.
  if rec.discharged then return false, "committed" end
  -- Through stand_down, so an aborted sequence closes the chamber and clears
  -- `discharged` too. Clearing only spool and designated left a shell sitting in
  -- an open chamber after an abort during the last the sustain of a sequence.
  turret.stand_down(rec)
  turret.say(rec, "scrubbed")
  return true
end

-- =============================================================================
-- Events
-- =============================================================================

--- #83: which yield tier the current charge buys.
-- Returns the tier table from C.charge.yield_tiers, highest affordable first.
-- This is what makes charge-up mean something rather than being a delay you sit
-- through: hold fire and the same gun hits harder.
function turret.yield_for(rec)
  local cost = C.charge.cost_per_shot
  if cost <= 0 then return C.charge.yield_tiers[#C.charge.yield_tiers] end
  local frac = rec.charge / cost
  local best = C.charge.yield_tiers[1]
  for _, tier in ipairs(C.charge.yield_tiers) do
    if frac >= tier.threshold then best = tier end
  end
  return best
end

--- #73: charge may run past 100% into the overcharge band before it stops.
function turret.charge_cap()
  return C.charge.cost_per_shot * C.charge.overcharge_max
end

function turret.on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local rec = schema.add_turret(entity)
  -- Only count what actually became an installation. add_turret refuses
  -- anything that is not our turret or has no unit_number, and the counter was
  -- being bumped for those too.
  if rec then
    storage.turrets_built = (storage.turrets_built or 0) + 1
    turret.lock_auto(rec)
    turret.unhold(rec)
    -- Adopt any pylons already standing in its slots -- the player may have
    -- built the bank first, or pasted a blueprint that placed them in a
    -- different order.
    pylon.adopt_existing(rec)
  end
end

--- Find turrets standing in the world that the mod has no record of, and adopt
--- them.
--
-- WHY THIS HAS TO EXIST. storage.turrets is written in exactly one place:
-- on_built, from a build event. An installation with no record is invisible to
-- every system in this mod -- it does not charge, does not appear on the status
-- panel, and the designator refuses it with "No Oppenheimer installation on this
-- surface" while the player is looking straight at one. There is no error and
-- nothing in the log.
--
-- And a build event is easy to miss:
--   * surface.create_entity from the console or another mod raises none at all
--   * map-editor and scenario placement do not reliably raise one either
--   * any record lost to a crash, a bad migration or a half-finished schema
--     change is lost permanently, because nothing ever looks at the map again
--
-- That last one is the real argument. Every other repair path in this mod
-- assumes the record exists; this is the only one that starts from the world and
-- works back, so it is the only thing that can recover from the record being
-- wrong rather than stale.
--
-- Idempotent and cheap: a filtered find over surfaces the force has touched,
-- run on config change and as a self-heal when a designation finds nothing.
-- @return number how many were adopted
function turret.adopt_orphans()
  -- storage.turrets is indexed directly below. If schema.ensure() has not run in
  -- this save it is nil, and this self-heal becomes an index-nil crash inside the
  -- designator -- turning a clear refusal into a red box.
  schema.ensure()
  local found = 0
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered{name = N.turret}) do
      if e.valid and e.unit_number and not storage.turrets[e.unit_number] then
        local rec = schema.add_turret(e)
        if rec then
          found = found + 1
          -- The same wiring on_built does, minus the built counter -- these are
          -- not new installations, they are ones we lost track of.
          turret.lock_auto(rec)
          turret.unhold(rec)
          pylon.adopt_existing(rec)
        end
      end
    end
  end
  return found
end

function turret.on_removed(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local un = entity.unit_number
  if not un then return end

  -- PUT THE LANCE OUT FIRST. The record is about to be dropped, so nothing will
  -- ever call fire_tick for it again -- and a lance that never cuts never leaves
  -- its strike group (scripts/beam.lua), which would leave every OTHER
  -- installation firing into that point waiting on a beam that no longer exists.
  -- The shot itself is lost, which is what mining a gun mid-sequence always did.
  local rec = storage.turrets[un]
  if rec then
    -- Past the cut the ball is already made and waiting to let go, so mining the
    -- gun then ends the shutdown early rather than losing the shot.
    if beam.winding(rec) then beam.cut(rec) else beam.abort(rec) end
  end

  schema.forget_turret(un)
end

--- Taking a hit during FIRE loses progress: the banks AND rec.spool are drained,
--- or a gun under fire would still discharge what it had committed.
function turret.on_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.unit_number) then return end
  local rec = storage.turrets[entity.unit_number]
  if not (rec and rec.state == turret.FIRE) then return end
  -- Once the round has left the barrel there is no progress left to lose.
  if rec.discharged then return end

  local loss = C.charge.damage_charge_loss

  local lose = pylon.available(rec) * loss
  if lose > 0 then
    pylon.drain(rec, lose, nil)      -- evenly, not toward a bearing
  end

  rec.spool  = (rec.spool or 0) * (1 - loss)
  rec.charge = pylon.available(rec)
end

-- =============================================================================
-- Registration -- at require time, unconditional, identical on every load
-- =============================================================================

local build_filter  = {{filter = "name", name = N.turret}}
local damage_filter = {{filter = "name", name = N.turret}}

events.on(defines.events.on_built_entity,       turret.on_built, build_filter)
events.on(defines.events.on_robot_built_entity, turret.on_built, build_filter)
events.on(defines.events.script_raised_built,   turret.on_built, build_filter)
events.on(defines.events.script_raised_revive,  turret.on_built, build_filter)

events.on(defines.events.on_player_mined_entity, turret.on_removed, build_filter)
events.on(defines.events.on_robot_mined_entity,  turret.on_removed, build_filter)
events.on(defines.events.on_entity_died,         turret.on_removed, build_filter)
events.on(defines.events.script_raised_destroy,  turret.on_removed, build_filter)

events.on(defines.events.on_entity_damaged, turret.on_damaged, damage_filter)

--- THE CHAMBER GAUGE: cells condensed out of the capacitor banks, one per
--- percent of a standard shot (100 at cost_per_shot, 150 at the top of the
--- overcharge band, 0 at rest). Reads the banks, not rec.spool -- gui.lua's
--- progress_of follows the same rule, for the same reason: rec.spool is only
--- written at the discharge, so a gauge driven from it would sit at zero for
--- the whole charge. Floored rather than rounded, so a chamber reading 100
--- means a genuinely full shot, at the cost of trailing the bar by up to one
--- cell.
local function sync_cells(rec)
  local e = rec.entity
  if not (e and e.valid) then return end

  -- COOLDOWN and DARK are the two states where the banks are NOT the charge:
  -- power_tick lets them fill freely from the grid there instead of holding
  -- them at zero (a venting gun shouldn't be taxed; a dark one that kept
  -- drawing could never refill). The gauge reads charge available to the NEXT
  -- shot, and in neither state is there any -- zero is the honest answer, not
  -- a special case.
  local st = rec.state
  local cost = C.charge.cost_per_shot
  local want = 0
  if cost > 0 and st ~= turret.COOLDOWN and st ~= turret.DARK then
    want = math.floor(available_energy(rec) / cost * C.cells.per_shot)
    -- The slot's own ceiling. Derived in config from per_shot x overcharge_max,
    -- so this clamp should never bind -- power_tick stops the charge at the
    -- ordered goal, and the ordered goal cannot exceed overcharge_max. It is
    -- here because insert() silently returns a short count when it does bind,
    -- and a gauge that quietly saturates is worse than one that cannot.
    local cap = C.turret.ammo_stack_limit * C.turret.inventory_size
    if want > cap then want = cap end
    if want < 0 then want = 0 end
  end

  -- A PLAIN NUMBER, NOT AN INVENTORY. electric-turret has no ammo
  -- inventory to insert/remove real N.shell items into -- the alt-mode ammo
  -- badge that bought is gone with it (accepted knowingly; see
  -- prototypes/entity.lua's 0.23.0 header). What is left is exactly the
  -- number the fire-control panel already wanted: scripts/gui.lua's ammo_of
  -- reads rec.cells directly now, so this is the only writer and no second
  -- definition of "what is in the chamber" exists to drift from it.
  rec.cells = want
end

turret.sync_cells = sync_cells

--- Every running cost, applied EVERY TICK (not bucketed like turret.step --
--- see the comment above on why a tick-sized draw matters). Only a handful of
--- arithmetic ops and at most four `energy` writes; the decisions still live
--- in turret.step, on the bucket.
local function power_tick(rec)
  local st = rec.state

  -- THE BUFFER IS THE METER (see C.power, pylon.set_buffer): every branch
  -- below sets electric_buffer_size, which decides the installation's draw
  -- this tick since intake is min(input_flow_limit/60, buffer - energy) and
  -- the flow limit itself isn't writable.
  --   idle      buffer = one tick of standby_draw, emptied  ->  draws standby
  --   charging  buffer = the ramp ceiling, never emptied    ->  draws the rate
  --   dark      same as idle -- a dark gun keeps TRYING to pay its standby,
  --             which is how it finds out the grid came back (turret.step)
  --   venting   buffer = 0                                  ->  draws nothing

  -- THE FIRING SEQUENCE, FIRST 16 SECONDS: the ramp.
  if st == turret.FIRE then
    if rec.discharged then
      -- THE DISCHARGE. The stored charge leaves over this lance's own burn (a
      -- joiner's is shorter than the sustain), so the banks are empty on the
      -- tick it cuts; with no lance left, whatever remains goes at once.
      local L = rec.lance
      local tail = L and (L.cut_at - L.lit_at) or 1
      local per  = (rec.spool or 0) / math.max(1, tail)
      if per > 0 then pylon.drain(rec, per, pylon.bearing(rec)) end

      -- AND THEN PIN THE CEILING TO WHAT IS LEFT (pylon.freeze) -- otherwise
      -- the drain above just opens room in electric_buffer_size that the grid
      -- refills, doubling the cost of every shot. ORDER IS LOAD-BEARING: drain,
      -- THEN freeze. Freezing first pins the
      -- ceiling at the pre-drain level, which is the bug with an extra step.
      pylon.freeze(rec)
      return
    end

    -- THE CHARGE STOPS AT WHAT WAS ORDERED, METERED ACROSS THE WHOLE WINDOW.
    -- The banks fill because the mod stops emptying them, so "charge to 25%"
    -- means "stop emptying them until they hold a quarter of a shot" -- and the
    -- ceiling ramps LINEARLY from zero to that goal across the charge window
    -- (not raced to it and then held), so every yield fills for the full
    -- window and arrives exactly on the strike: the gun's clock belongs to the
    -- sound file, only the OUTPUT scales with what was ordered.
    --
    -- THE RAMP IS THE BUFFER ITSELF: the ceiling is written to
    -- electric_buffer_size, so the engine cannot deliver more than fits and the
    -- intake per tick IS the ramp increment (goal/discharge_at joules, exactly
    -- rate/60) -- nothing drained, nothing burned, the graph matches the panel.
    -- Clamped per bank to the prototype buffer inside pylon.set_buffer, which
    -- is the tiering gate: ordering 15 GJ/s on four banks stalls the shot
    -- rather than quietly working.
    -- The ramp spans the charge window, so the intake per tick IS the ordered
    -- rate and a bigger plant buys nothing. An order the grid cannot hold stalls.
    local goal    = turret.spool_goal(rec)
    local elapsed = game.tick - rec.state_since
    local ramp    = math.min(1, elapsed
                    / C.sound.charge_window_ticks(C.sound.charge_parts))
    local n = linked_count(rec)
    if n > 0 then
      pylon.set_buffer(rec, goal * ramp / n)
    end

    -- The tick the banks actually held the order. One bank loop per charging
    -- installation per tick, and only until it latches.
    if not rec.full_at and goal > 0 and available_energy(rec) >= goal then
      rec.full_at = game.tick
    end
    return
  end

  -- VENTING: buffer 0, so the installation draws nothing and holds nothing.
  if st == turret.COOLDOWN then
    pylon.set_buffer(rec, 0)
    rec.paid, rec.paid_ticks = nil, nil
    return
  end

  -- EVERY OTHER STATE, DARK INCLUDED: meter the standby draw. The buffer is
  -- one tick's allowance, emptied every tick, so the grid can never deliver
  -- more than standby_draw regardless of flow limit -- and rec.paid is an
  -- exact measurement of what it actually delivered, which is what the
  -- brownout/recovery tests in turret.step read. DARK keeps trying to pay its
  -- standby (bounded, not sitting on the grid at the full flow limit) rather
  -- than waiting on a stored level, which the buffer model can never reach at
  -- rest; coming back is simply the grid paying it again.
  local n = linked_count(rec)
  if n > 0 then
    pylon.set_buffer(rec, C.standby_allowance())
  end
  local had = available_energy(rec)
  if had > 0 then pylon.drain(rec, had, nil) end
  rec.paid = (rec.paid or 0) + had
  rec.paid_ticks = (rec.paid_ticks or 0) + 1
end

-- =============================================================================
-- THE POWER GRAPH'S METER (#15 -- the HUD's live feed)
--
-- WHAT IS BEING MEASURED, and why it is not rec.paid: `paid` only accumulates
-- in the states that meter standby (it is reset by the brownout test and is
-- not written at all while charging), so it can say nothing about the sixteen
-- seconds a player most wants to watch. What the graph wants is the same
-- number in every state -- joules the grid actually put into the banks this
-- tick -- and the banks themselves are the meter: whatever is in them at the
-- start of our tick that was not there when we finished the last one was
-- delivered by the engine's electric network in between.
--
-- Two extra pylon.available() walks a tick per installation (one before the
-- branch, one after), each a read of `energy` per bank. The branch itself
-- already made one of them.
-- =============================================================================

function turret.power_tick(rec)
  local before = pylon.available(rec, true)
  local got = before - (rec.pg_after or before)
  if got > 0 then rec.pg_acc = (rec.pg_acc or 0) + got end

  -- REAL-TIME CHARGE DELIVERY, for the brownout-during-FIRE check in
  -- turret.step: `got` above is already "joules the grid actually delivered
  -- this tick" -- charging only adds its own expectation (the ramp's own
  -- per-tick share), accumulated the same way rec.paid is for every other
  -- state. Cleared the moment charging stops or the lance lights, so a later
  -- charge or the post-discharge burn never inherits a stale count.
  if rec.state == turret.FIRE and not rec.discharged then
    local window  = C.sound.charge_window_ticks(C.sound.charge_parts)
    local elapsed = game.tick - rec.state_since
    local want = elapsed < window and (turret.spool_goal(rec) / window) or 0
    rec.fire_paid       = (rec.fire_paid or 0) + math.max(got, 0)
    rec.fire_expect     = (rec.fire_expect or 0) + want
    rec.fire_paid_ticks = (rec.fire_paid_ticks or 0) + 1
  else
    rec.fire_paid, rec.fire_expect, rec.fire_paid_ticks = nil, nil, nil
  end

  power_tick(rec)

  rec.pg_after = available_energy(rec)
end

--- Close one sample window and push it onto the record's history, in WATTS.
-- Called on the HUD's own refresh interval (scripts/gui.lua) rather than on a
-- clock of its own, so a bar is exactly one refresh wide.
function turret.power_sample(rec)
  local g = C.hud.graph
  local tick = game.tick
  local span = tick - (rec.pg_tick or tick)
  rec.pg_tick = tick
  if span <= 0 then return end

  local hist = rec.pg
  if not hist then hist = {}; rec.pg = hist end
  hist[#hist + 1] = (rec.pg_acc or 0) / span * 60
  rec.pg_acc = 0
  -- Trim from the front: the window is fixed and short (60 samples), so this
  -- is a handful of moves a second, not a reallocation of anything.
  while #hist > g.samples do table.remove(hist, 1) end
end

-- One bucket per tick: bucket index cycles with game.tick.
events.on_nth_tick(1, function(event)
  -- The status lights run on their own clock: fast enough that a flash reads as
  -- a flash and a charge ramp as a ramp, far slower than every tick. Computed
  -- once outside the loop rather than per turret -- it is the same answer for
  -- all of them.
  local relight = C.lights and C.lights.enabled
                  and (event.tick % C.lights.update_interval) == 0
  -- Off in every ordinary game: storage.muzzle_debug is false unless
  -- /oppenheimer-muzzle has been used, so this is one boolean read per tick.
  local remark = storage.muzzle_debug
                 and (event.tick % C.control.muzzle_marker_interval) == 0

  -- Running costs first, for every installation, every tick.
  profile.start("turret loop (total, incl. lance + sphere)")
  for _, rec in pairs(storage.turrets) do
    if schema.valid(rec) then
      profile.start("turret/power + gauge")
      turret.power_tick(rec)
      -- AFTER power_tick, never before: power_tick is what moves the joules this
      -- tick, and a gauge read before the movement is a gauge one tick stale --
      -- which on a ramp that runs for exactly 960 ticks is a cell of permanent
      -- lag for no reason. Costs one comparison per installation per tick in the
      -- common case; see the fast path in sync_cells.
      turret.sync_cells(rec)
      profile.stop("turret/power + gauge")
      profile.start("turret/overlays (preview, lights, reticle, fx)")
      -- The designator overlay. Costs one string compare on the overwhelmingly
      -- common tick where neither the aim point nor the dial has moved; see
      -- render.preview. The AIM test is done HERE because render.lua cannot
      -- require this file back without a cycle.
      render.preview(rec, rec.state == turret.AIM)
      if relight then render.lights(rec) end
      if remark then beam.marker(rec) end
      profile.stop("turret/overlays (preview, lights, reticle, fx)")
      -- On the TICK, not the bucket: the sequence is timed by an audio file.
      profile.start("turret/fire sequence (incl. haze)")
      turret.fire_tick(rec)
      profile.stop("turret/fire sequence (incl. haze)")
      profile.start("turret/overlays (preview, lights, reticle, fx)")
      -- After fire_tick, so the bulbs are gone on the very tick the strike
      -- flashes rather than one tick later.
      local charging = rec.state == turret.FIRE and not rec.discharged
      reticle.tick(rec, rec.state == turret.AIM, charging)
      -- also after fire_tick: the brownout and the dust both start ON
      -- the strike tick, which fire_tick is what marks.
      render.brownout_step(rec)
      installfx.tick(rec, charging)
      profile.stop("turret/overlays (preview, lights, reticle, fx)")
      -- The barrel, too. On the TICK, not the bucket: a bucket step is 30 ticks,
      -- and a gun that jumps thirty rotation steps twice a second is a gun that
      -- teleports. slew() returns immediately unless this turret is aiming.
      profile.start("turret/slew")
      turret.slew(rec)
      profile.stop("turret/slew")
      -- And the lance, for the same reason and on the same terms: it has to cut
      -- on the exact tick the audio ends, not on the next bucket step up to
      -- half a second later. Returns immediately unless this turret has a beam
      -- lit, which is all of them almost all of the time -- so it costs one
      -- table lookup per turret per tick, and no second per-tick handler.
      profile.start("lance + sphere (total)")
      beam.sustain(rec)
      profile.stop("lance + sphere (total)")
    end
  end
  profile.stop("turret loop (total, incl. lance + sphere)")

  -- Then the state machine, for this tick's bucket only.
  local bucket = event.tick % C.control.update_buckets
  local recs = schema.bucket(bucket)
  profile.start("turret/state machine")
  for i = 1, #recs do
    turret.step(recs[i])
  end
  profile.stop("turret/state machine")
end)

return turret
