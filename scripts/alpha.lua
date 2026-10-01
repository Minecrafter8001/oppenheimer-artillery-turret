-- scripts/alpha.lua -------------------------------------------------------------
-- THE BATTERY. Every installation a force owns is linked, permanently: one
-- designation turns all of them, one confirmation fires all of them, and every
-- lance ignites on the SAME TICK. There is no per-installation order and no
-- switch to arm -- a second Oppenheimer is not a second weapon, it is more of
-- the same weapon.
--
-- WHAT SAME-TICK COSTS. Every member enters FIRE on one tick, which is free
-- (one loop, one tick), and every charge is the same length, so ignition -- the
-- end of the spin-up chain -- lands on one tick for all of them.
--
-- BARRELS are why this is a state machine and not a function. The traverse is
-- slower than the charge, so a battery pointed in four directions cannot be
-- released on the press that commits it: a committed order waits in
-- storage.alpha_order and alpha.tick() releases the whole group on the tick the
-- last barrel lands.
--
-- Once lit, convergence does the rest: every lance aims at one point, so they
-- join one strike group and share its clock, heat and detonation
-- (C.beam.convergence, scripts/beam.lua). The group's power is what carries the
-- shot past a single installation's 100% dial, up to C.charge.group_cap.
----------------------------------------------------------------------------------

local C      = require("config")
local audio  = require("scripts.audio")
local events = require("scripts.events")
local turret = require("scripts.turret")

local alpha = {}

--- Every installation of this force on this surface, nearest to `position`
--- first. The whole battery, because the battery is the weapon.
function alpha.battery(surface, force, position)
  local out = {}
  for _, rec in pairs(storage.turrets or {}) do
    local e = rec.entity
    if e and e.valid and e.surface == surface and e.force == force then
      local dx, dy = position.x - e.position.x, position.y - e.position.y
      out[#out + 1] = {rec = rec, d2 = dx * dx + dy * dy}
    end
  end
  table.sort(out, function(a, b) return a.d2 < b.d2 end)
  return out
end

--- How many installations this force owns, live. The HUD shows the group
--- multiplier only when this is more than one.
function alpha.count(force)
  local n = 0
  for _, rec in pairs(storage.turrets or {}) do
    local e = rec.entity
    if e and e.valid and e.force == force then n = n + 1 end
  end
  return n
end

-- One pending order per battery, and a battery is a force on one surface.
local function order_key(force, surface)
  return force.index .. ":" .. surface.index
end

function alpha.order(force, surface)
  return (storage.alpha_order or {})[order_key(force, surface)]
end

function alpha.drop(force, surface)
  if storage.alpha_order then storage.alpha_order[order_key(force, surface)] = nil end
end

--- The live records behind an order, and how many are on target. A member that
--- stopped being part of the order (destroyed, no longer AIM, re-aimed
--- elsewhere) leaves the list rather than blocking it.
function alpha.resolve(ord)
  local out, ready = {}, 0
  local tol = C.turret.confirm_tolerance
  local tol2 = tol * tol
  for _, un in ipairs(ord.units or {}) do
    local rec = (storage.turrets or {})[un]
    local e = rec and rec.entity
    local d = rec and rec.designated
    if e and e.valid and d and rec.state == turret.AIM then
      local dx, dy = ord.x - d.x, ord.y - d.y
      if dx * dx + dy * dy <= tol2 then
        out[#out + 1] = rec
        if turret.aimed(rec) then ready = ready + 1 end
      end
    end
  end
  return out, ready
end

--- Fire every record in `list` on THIS tick, on one chain length.
-- @return number fired    how many actually rolled a tape
-- @return number handled  how many did something with the press, TEST mode's
--   preparation included -- the caller needs the second number to know the
--   press landed, and the first to know whether to announce a volley.
function alpha.release(list)
  local fired, handled = 0, 0
  for _, rec in ipairs(list) do
    -- How wide every lance in this volley will be drawn: they all ignite on one
    -- tick, so without a shared count the first to tick sees a group of one and
    -- fires thin (scripts/beam.lua, fire). Cleared at stand_down.
    rec.alpha_lances = #list
    local ok, why = turret.release(rec)
    if not ok then rec.alpha_lances = nil end
    -- TEST MODE IS NOT A FIRING: release() builds and reports on the blast zone
    -- and nothing leaves the barrel, so the press is handled but the group must
    -- not announce a volley -- and must not fall through to a refusal either.
    if ok and rec.fire_mode ~= "test" then fired = fired + 1 end
    if ok or why == "test-mode" then handled = handled + 1 end
  end
  return fired, handled
end

--- Commit an order. Fires at once when every barrel is already on target,
--- otherwise records it and lets alpha.tick() fire the group when the last one
--- arrives -- so the player commits once instead of pressing until it takes.
function alpha.commit(player, recs, position)
  local units = {}
  for _, rec in ipairs(recs) do units[#units + 1] = rec.unit_number end

  local surface = recs[1].entity.surface
  local ord = {units = units, x = position.x, y = position.y, tick = game.tick,
               force = player.force.index}
  local live, ready = alpha.resolve(ord)
  if #live == 0 then return false end

  if ready == #live then
    alpha.drop(player.force, surface)
    local fired, handled = alpha.release(live)
    if fired > 0 then
      audio.notify(player.force, {"oppenheimer.alpha-fired", tostring(fired)})
    end
    return handled > 0
  end

  storage.alpha_order = storage.alpha_order or {}
  storage.alpha_order[order_key(player.force, surface)] = ord
  audio.notify(player, {"oppenheimer.alpha-committed",
               tostring(ready), tostring(#live)})
  return true
end

--- CONFIRM from the HUD: commit every installation of this force that is
--- aiming at the same point the lead one is. The panel is one row for one
--- linked weapon, so its FIRE button commits the battery, exactly as the
--- designator's second press does.
-- @return boolean, string  false plus a reason when nothing could be committed
function alpha.confirm(player, recs)
  local at
  for _, rec in ipairs(recs) do
    if not at and rec.state == turret.AIM and rec.designated then
      at = rec.designated
    end
  end
  if not at then return false, "no-target" end

  local tol = C.turret.confirm_tolerance
  local tol2 = tol * tol
  local on = {}
  for _, rec in ipairs(recs) do
    local d = rec.designated
    if rec.state == turret.AIM and d then
      local dx, dy = at.x - d.x, at.y - d.y
      if dx * dx + dy * dy <= tol2 then on[#on + 1] = rec end
    end
  end
  if #on == 0 then return false, "no-target" end
  return alpha.commit(player, on, at), nil
end

--- One tick of every committed order. Cheap when there are none, which is every
--- tick of an ordinary game.
function alpha.tick()
  local orders = storage.alpha_order
  if not orders or next(orders) == nil then return end

  for key, ord in pairs(orders) do
    -- Orders saved before 0.51.1 are keyed by force index and carry no ord.force.
    local force = game.forces[ord.force or key]
    local live, ready = alpha.resolve(ord)

    if #live == 0 then
      orders[key] = nil
      if force then audio.notify(force, {"oppenheimer.alpha-lapsed"}) end
    elseif ready == #live then
      orders[key] = nil
      local fired = alpha.release(live)
      if fired > 0 and force then
        audio.notify(force, {"oppenheimer.alpha-fired", tostring(fired)})
      end
    elseif game.tick - ord.tick > C.turret.alpha_hold_ticks then
      -- A barrel that never arrives must not hold the battery hostage: fire
      -- what IS on target rather than leaving the order pending forever.
      orders[key] = nil
      local on = {}
      for _, rec in ipairs(live) do
        if turret.aimed(rec) then on[#on + 1] = rec end
      end
      if #on > 0 then
        local fired = alpha.release(on)
        if fired > 0 and force then
          audio.notify(force, {"oppenheimer.alpha-partial",
                      tostring(fired), tostring(#live)})
        end
      elseif force then
        audio.notify(force, {"oppenheimer.alpha-lapsed"})
      end
    end
  end
end

events.on_nth_tick(1, alpha.tick)

return alpha
