-- scripts/remote.lua -------------------------------------------------------------
-- #103: designation. The ONLY way this gun ever acquires a target.
--
-- There is no auto-acquire anywhere in this mod and no setting that enables one.
-- Every shot begins here, with a player pointing the remote at a piece of ground.
--
-- TWO PRESSES, ONE REMOTE. The first designates and turns the barrel; the second,
-- once the barrel has arrived, confirms and starts the sequence. See remote.on_used.
--
-- HOW THE DESIGNATION IS CAUGHT
-- The designator is a SELECTION TOOL (prototypes/item.lua -- read its header
-- before changing the type back), so using it raises on_player_selected_area
-- with the rectangle the player dragged. The mod takes the centre of that
-- rectangle as the designated point.
--
-- NOTHING IS PLACED ON THE MAP BY DESIGNATION. Not a flare, not anything. The
-- barrel is turned by turret.slew and the beam is created by scripts/beam.lua.
----------------------------------------------------------------------------------

local C        = require("config")
local N        = require("lib.names")
local audio = require("scripts.audio")
local events   = require("scripts.events")
local turret   = require("scripts.turret")
-- The additional, separate hyper-rotate-and-vaporize capability (idea C).
-- One-way: this file dispatches to it, it never dispatches back here.
local arcsweep = require("scripts.arcsweep")
local alpha    = require("scripts.alpha")

local remote = {}

--- Every turret of this force on this surface, nearest to the designated point
--- first. Nearest-first so a battery behaves the way a player expects: the gun
--- closest to the target takes the shot.
local function by_distance(surface, force, position)
  local out = {}
  for _, rec in pairs(storage.turrets or {}) do
    local e = rec.entity
    if e and e.valid and e.surface == surface and e.force == force then
      local dx = position.x - e.position.x
      local dy = position.y - e.position.y
      out[#out + 1] = {rec = rec, d2 = dx * dx + dy * dy}
    end
  end
  table.sort(out, function(a, b) return a.d2 < b.d2 end)
  return out
end

--- ONE PRESS, THE WHOLE BATTERY. Every installation this force owns is linked,
--- so the designator never picks one gun: the first press turns everything that
--- can take the order, the second commits them and scripts/alpha.lua fires them
--- on one tick. Returns false when there is nothing the battery can do with the
--- press, so the caller still produces the real refusal (busy, banks short,
--- inside the blast) rather than a generic one.
local function alpha_press(player, position)
  local reach = C.reach()
  local reach2 = reach * reach
  local tol = C.turret.confirm_tolerance
  local tol2 = tol * tol

  local members, on_order, free = 0, {}, {}
  for _, c in ipairs(by_distance(player.surface, player.force, position)) do
    -- Sorted, so once one is out of reach they all are.
    if c.d2 > reach2 then break end
    local rec = c.rec
    -- A gun in sweep mode reads every press in the sweep idiom and has no
    -- main-sequence charge cycle, so it is not part of a strike.
    if not rec.arc_sweep_mode then
      members = members + 1
      local d = rec.designated
      local same = false
      if d then
        local dx, dy = position.x - d.x, position.y - d.y
        same = (dx * dx + dy * dy) <= tol2
      end
      if rec.state == turret.AIM and same then
        on_order[#on_order + 1] = rec
      elseif rec.state == turret.STANDBY or rec.state == turret.AIM then
        free[#free + 1] = rec
      end
    end
  end

  if members == 0 then return false end

  -- ANYTHING STILL AIMABLE MAKES THIS THE DESIGNATION PRESS, including a gun
  -- already aiming somewhere else: a battery half-pointed at the old target is
  -- re-ordered, never left behind.
  if #free > 0 then
    local aimed = #on_order
    for _, rec in ipairs(free) do
      if turret.designate(rec, position, true) then aimed = aimed + 1 end
    end
    if aimed == 0 then return false end
    audio.notify(player, {"oppenheimer.alpha-designated",
                 tostring(aimed), tostring(members)})
    return true
  end

  if #on_order > 0 then
    return alpha.commit(player, on_order, position)
  end
  return false
end

--- WHERE THE DRAG STARTED, if this player's last press is recent enough to
--- belong to the selection being handled. The select controls raise their
--- linked custom-input (N.drag_input) on the press; the selection itself
--- arrives on release, so the two are one gesture separated by however long
--- the player held the button -- generous window, and a stale entry can only
--- ever cost the old behaviour.
local function drag_start(player_index)
  local d = storage.drag and storage.drag[player_index]
  if not d then return nil end
  if game.tick - d.tick > C.arc_sweep.drag_memory_ticks then return nil end
  return d
end

--- Remember the press. Cheap enough to record unconditionally -- it is one
--- table write per left click, and checking the cursor first would miss the
--- press that puts the designator to work on the very tick it arrives.
function remote.on_drag_start(event)
  local p = event.cursor_position
  if not p then return end
  -- schema.ensure owns this key (rule 5), but a click can land before
  -- on_configuration_changed on a save that predates it, and a nil index here
  -- would crash on an ordinary left click -- the one event in this mod that
  -- fires for every player whether or not they own an installation.
  storage.drag = storage.drag or {}
  storage.drag[event.player_index] = {x = p.x, y = p.y, tick = event.tick}
end

--- The centre of a selection rectangle. A plain click gives a rectangle of
--- almost zero size, so this is the click point.
local function area_centre(area)
  if not (area and area.left_top and area.right_bottom) then return nil end
  return {
    x = (area.left_top.x + area.right_bottom.x) / 2,
    y = (area.left_top.y + area.right_bottom.y) / 2,
  }
end

--- Idea C, the arc sweep: reads the SAME drag the designator already
--- produces, rather than collapsing it to a point. Below C.arc_sweep.min_drag
--- (the rectangle's own diagonal) this returns nil -- too small to mark a
--- span. Above it, the two corners become the two ends of the swept arc --
--- as BEARINGS from whichever turret answers (arcsweep.aim), not as ground
--- distances, so no centre point is needed here.
--
-- DIRECTION COMES FROM THE PRESS, NOT THE RECTANGLE. `area` is normalised by
-- the engine -- left_top is always the lesser corner on both axes -- so the
-- rectangle alone cannot tell a right-to-left drag from a left-to-right one,
-- and it cannot tell the two DIAGONALS apart either (bottom-left to top-right
-- arrives as top-left to bottom-right). Both were wrong before: the sweep ran
-- one way whatever the player drew. drag_start gives the corner the player
-- actually pressed on; `a` is whichever corner is nearest it and `b` is the
-- one diagonally opposite, which recovers the gesture exactly for all four
-- directions. With no recorded press (a keyboard selection, a stale entry) it
-- falls back to the old left_top -> right_bottom reading.
-- @return {a = MapPosition, b = MapPosition}|nil
local function sweep_from_area(area, from)
  local sw = C.arc_sweep
  if not (sw and sw.enabled) then return nil end
  if not (area and area.left_top and area.right_bottom) then return nil end

  local x0, y0 = area.left_top.x, area.left_top.y
  local x1, y1 = area.right_bottom.x, area.right_bottom.y
  local dx, dy = x1 - x0, y1 - y0
  local len = math.sqrt(dx * dx + dy * dy)
  if len < sw.min_drag then return nil end

  if from then
    -- Nearest corner of the four, by squared distance.
    local ax, ay = x0, y0
    local best = nil
    for _, c in ipairs({{x0, y0}, {x1, y0}, {x0, y1}, {x1, y1}}) do
      local ddx, ddy = c[1] - from.x, c[2] - from.y
      local d2 = ddx * ddx + ddy * ddy
      if not best or d2 < best then best, ax, ay = d2, c[1], c[2] end
    end
    -- The opposite corner on both axes: the release end of the same drag.
    local bx = (ax == x0) and x1 or x0
    local by = (ay == y0) and y1 or y0
    return {a = {x = ax, y = ay}, b = {x = bx, y = by}}
  end

  return {a = {x = x0, y = y0}, b = {x = x1, y = y1}}
end

function remote.on_used(event)
  -- on_player_selected_area carries `item` as the prototype NAME (a string), not
  -- an item stack -- unlike on_player_used_capsule, which carried a prototype.
  -- Comparing event.item.name here would index a string and throw.
  if event.item ~= N.remote then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local position = area_centre(event.area)
  if not position then return end

  -- IDEA C, THE ARC SWEEP: read from event.area BEFORE it is replaced below.
  -- nil for a press too small to mark a span -- see sweep_from_area.
  local sweep_pts = sweep_from_area(event.area, drag_start(event.player_index))

  event = {player_index = event.player_index, position = position}

  -- THE BATTERY FIRST, always: the installations are permanently linked, so a
  -- press is an order to all of them. The nearest-first sweep below is only the
  -- fallback that produces the real refusal when the battery can do nothing
  -- with this press.
  if alpha_press(player, position) then return end

  local list = by_distance(player.surface, player.force, event.position)
  if #list == 0 then
    -- SELF-HEAL BEFORE REFUSING. "No Oppenheimer installation on this surface"
    -- is the single most misleading message this mod can print: the player is
    -- usually standing next to one. It means the mod has no RECORD, not that
    -- there is no turret -- and a missing record is recoverable by looking at
    -- the map, which is what this does. Retry once with what it found, and only
    -- then refuse. See turret.adopt_orphans.
    if turret.adopt_orphans() > 0 then
      list = by_distance(player.surface, player.force, event.position)
    end
  end
  if #list == 0 then
    -- WHY THIS COUNTS BEFORE IT REFUSES: "no installation on this surface" is
    -- a statement about the mod's RECORDS, and two different faults look
    -- identical from a player's side -- a lost record (adopt_orphans should
    -- have caught it, something's wrong in this mod) vs. no Oppenheimer
    -- turret here at all (the thing being pointed at is a vanilla turret that
    -- looks similar, since this mod's own sprite borrows base's laser-turret
    -- art). One number settles it, so print the number.
    local ours = player.surface.count_entities_filtered{
      name = N.turret, force = player.force,
    }
    -- Counts BOTH vanilla types this mod's turret has ever visually
    -- resembled (its pre-0.23.0 artillery-turret look and its current one).
    local vanilla = player.surface.count_entities_filtered{
      type = "artillery-turret", force = player.force,
    } + player.surface.count_entities_filtered{
      type = "electric-turret", force = player.force,
    }
    audio.notify(player, {"oppenheimer.no-turret"})
    audio.notify(player, {"oppenheimer.no-turret-detail",
                 tostring(ours), tostring(vanilla - ours)})
    return
  end

  local reach = C.reach()
  local reach2 = reach * reach

  -- ONE REMOTE, TWO PRESSES: the first designates (the barrel starts its long
  -- swing, banks untouched), the second confirms and rolls the tape, once the
  -- barrel has arrived. No flare is placed by either -- see turret.designate().
  --
  -- Both presses go through the same item because that is how the weapon reads
  -- from the player's hand: point, then commit. It also takes the fire-control
  -- window off the critical path entirely -- CONFIRM was a button in a GUI that
  -- had to open, find its record and enable itself before the gun could ever
  -- fire, and every one of those was a way for the shot to silently not happen.
  local blocked, too_far, too_close = nil, false, false
  -- refused because the target sits inside the blast the CURRENT rate
  -- would produce. Holds the largest standoff any candidate asked for, so the
  -- message quotes a distance that satisfies every gun that refused.
  local inside_blast = nil
  local slewing_off = nil
  -- Carried out of the loop so the refusal can name the ONE cause a player can
  -- actually do something about. See the print block at the bottom.
  local banks_short = nil
  -- Idea C: set alongside `blocked` whenever the refusal came from the
  -- sweep-mode branch, so the print block can route to arc-sweep-refused
  -- (which explains "cooldown"/"blind"/etc. on their own terms) instead of
  -- the generic all-busy message, regardless of which of arcsweep's several
  -- reason strings this particular refusal was.
  local arc_sweep_blocked = false

  for _, c in ipairs(list) do
    if c.d2 > reach2 then
      -- The list is sorted, so once one is out of reach they all are.
      too_far = true
      break
    end

    -- IDEA C, THE ARC SWEEP: an installation with sweep mode ON reads EVERY
    -- press in the sweep idiom -- never point designation, so a drag here
    -- can never be mistaken for the start of a main-sequence order, and a
    -- press meant to confirm/re-aim a sweep can never be misread as one
    -- either. rec.state is still STANDBY throughout a sweep and its own
    -- charge-up, by design (it is not a state of this machine), so this
    -- branch is what actually keeps the two from ever fighting over the
    -- same e.orientation write.
    if c.rec.arc_sweep_mode then
      if c.rec.arc_sweep then
        -- Mid-sweep (or mid-charge-up): busy.
        blocked = blocked or "arc-sweep"
        arc_sweep_blocked = true
      elseif sweep_pts then
        -- A qualifying drag, whether or not one is already pending: mark
        -- (or REPLACE) the span. Firing is the HUD's CONFIRM, never a press.
        local ok, why = arcsweep.aim(c.rec, sweep_pts.a, sweep_pts.b, position)
        if ok then return end
        blocked = blocked or why
        arc_sweep_blocked = true
      elseif arcsweep.pending(c.rec) then
        -- A span is already marked: a plain press does not fire it.
        blocked = blocked or "arc-sweep-use-confirm"
        arc_sweep_blocked = true
      else
        -- Too small a press with nothing pending to confirm -- explain
        -- rather than silently doing nothing.
        blocked = blocked or "arc-sweep-need-drag"
        arc_sweep_blocked = true
      end
    else
      -- SECOND PRESS: this installation is already aiming. Confirm it -- but only
      -- if the player pressed at the target they already designated. Pressing
      -- somewhere else is a new order, not a confirmation, and firing a gigajoule
      -- at the previous spot because the second click landed elsewhere would be
      -- the worst possible reading of "press again".
      local d = c.rec.designated
      local same = false
      if d then
        local ddx, ddy = event.position.x - d.x, event.position.y - d.y
        same = (ddx * ddx + ddy * ddy)
               <= (C.turret.confirm_tolerance * C.turret.confirm_tolerance)
      end

      if c.rec.state == turret.AIM and same then
        -- NO SINGLE-GUN RELEASE HERE. alpha_press above already offered this
        -- press to the whole battery and handles TEST mode with it; reaching
        -- this line means it could not take the press, and firing the nearest
        -- installation alone is not the fallback for that -- it is one gun
        -- going downrange on a second press while the other nine stand by.
        local aligned, off = turret.aimed(c.rec)
        if not aligned then
          slewing_off = off
        else
          blocked = blocked or tostring(c.rec.state)
        end

      -- FIRST PRESS: designate.
      else
        local ok, why, need = turret.designate(c.rec, event.position)
        -- No second line on success: turret.designate already announces
        -- TARGET DESIGNATED to the whole force, and a private "designation
        -- accepted" underneath it was the same fact twice.
        if ok then return end
        -- "too-close" is not a busy installation, it is the gun's dead zone, and it
        -- needs its own message: a player who gets "every installation is busy" for
        -- a target 20 tiles away goes looking for a state bug that is not there.
        if why == "too-close" then
          too_close = true
        elseif why == "inside-blast" then
          -- A DIFFERENT REFUSAL FROM THE DEAD ZONE, and it must not be folded into
          -- it. "too-close" is hardware and never moves. This one is a consequence
          -- of the DIAL: the same target is legal at 1% and suicide at 150%, so the
          -- fix is usually "turn it down", not "walk further away" -- and a player
          -- told the wrong one of those goes hunting for a bug.
          if not inside_blast or (need or 0) > inside_blast then
            inside_blast = need or 0
          end
        else
          -- AN UNFINISHED INSTALLATION IS NOT A BUSY ONE: designate() refuses
          -- anything that isn't STANDBY/AIM and hands back the raw state, so a
          -- gun with incomplete banks would otherwise read as "busy (idle)" --
          -- true, useless, and indistinguishable from a mod bug. This is also
          -- the single most likely refusal, since an incomplete installation
          -- parks in IDLE permanently until rebuilt.
          if c.rec.short_banks then
            banks_short = banks_short or c.rec.short_banks
          end
          blocked = blocked or why
        end
      end
    end
  end

  if slewing_off then
    -- Not an error. The gun is still coming round, and this is the one piece of
    -- information that makes waiting make sense rather than feel like a dud.
    audio.notify(player, {"oppenheimer.still-slewing",
                 tostring(math.floor(slewing_off * 360 + 0.5))})
  elseif inside_blast and not blocked then
    audio.notify(player, {"oppenheimer.target-inside-blast", tostring(inside_blast)})
  elseif too_close and not blocked then
    audio.notify(player, {"oppenheimer.target-too-close", tostring(math.floor(C.gun.min_range))})
  elseif too_far and not blocked then
    audio.notify(player, {"oppenheimer.out-of-range", tostring(math.floor(reach))})
  elseif banks_short then
    -- Checked before all-busy, because it is the actionable one.
    audio.notify(player, {"oppenheimer.need-banks",
                 tostring(banks_short), tostring(C.pylon.count)})
  elseif arc_sweep_blocked then
    audio.notify(player, {"oppenheimer.arc-sweep-refused", tostring(blocked)})
  else
    -- "?" meant blocked came back nil and the player was told nothing at all.
    -- Any state is more use than that.
    audio.notify(player, {"oppenheimer.all-busy", tostring(blocked or "unknown state")})
  end
end

-- Both, so a left-drag and a shift/alt-drag do the same thing rather than one of
-- them silently doing nothing.
events.on(defines.events.on_player_selected_area,     remote.on_used)
events.on(defines.events.on_player_alt_selected_area, remote.on_used)
-- The press that BEGINS a selection, for its cursor position alone. Registered
-- by prototype name, the way every custom-input is.
events.on(N.drag_input,     remote.on_drag_start)
events.on(N.drag_input_alt, remote.on_drag_start)

return remote
