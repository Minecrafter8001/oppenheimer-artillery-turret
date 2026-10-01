-- scripts/logistics.lua -------------------------------------------------------------
-- Auto-reload: keeps a turret's chamber topped up from the logistic network it
-- stands in.
--------------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local events = require("scripts.events")
local schema = require("scripts.schema")

local logistics = {}

-- =============================================================================
-- #22: auto-reload
-- =============================================================================

--- How many cells this turret is short of its target holding.
local function shortfall(rec)
  local want = C.logistics.keep_loaded
  local inv = rec.entity.get_inventory(defines.inventory.artillery_turret_ammo)
  if not inv then return 0 end
  return math.max(0, want - inv.get_item_count(N.shell))
end

--- Pull shells from a logistic network the turret is standing in.
-- Deliberately uses the network the turret is IN rather than a global search:
-- an outpost gun should be fed by the outpost's own network, and a gun outside
-- any network should stay hungry rather than teleporting shells across the map.
function logistics.reload(rec)
  if not C.logistics.auto_reload then return end
  if not schema.valid(rec) then return end

  local e = rec.entity
  local need = shortfall(rec)
  if need <= 0 then return end

  local network = e.surface.find_logistic_network_by_position(e.position, e.force)
  if not network then return end

  -- Take at most a partial load per pass, so one turret cannot drain a network
  -- in a single tick and starve everything else that wants shells.
  local take = math.min(need, C.logistics.per_pass)
  local removed = network.remove_item({name = N.shell, count = take})
  if removed and removed > 0 then
    local inv = e.get_inventory(defines.inventory.artillery_turret_ammo)
    local inserted = inv and inv.insert{name = N.shell, count = removed} or 0
    -- Anything the turret could not take goes back, or it is destroyed.
    if inserted < removed then
      network.insert({name = N.shell, count = removed - inserted})
    end
  end
end

--- Park shells outside the gun (used by the #76 fallback gate).
-- Puts them back into the local logistic network if there is one, and spills
-- them at the turret if there is not. Never destroys them -- a shell costs
-- 4 explosive cannon shells, a radar and 8 explosives.
function logistics.park(rec, count)
  local e = rec.entity
  if not (e and e.valid and count > 0) then return end
  local network = e.surface.find_logistic_network_by_position(e.position, e.force)
  if network then
    local left = count - (network.insert({name = N.shell, count = count}) or 0)
    if left <= 0 then return end
    count = left
  end
  -- Offset clear of the turret's own footprint. Spilling at e.position drops the
  -- stack UNDER a 9x9 sprite, where the player cannot see it -- which is how
  -- "handed safely back" reads, from the outside, as "deleted".
  local clear = C.turret.tile_size / 2 + 2
  e.surface.spill_item_stack{
    position = {x = e.position.x, y = e.position.y + clear},
    stack = {name = N.shell, count = count},
    enable_looted = false,
    force = e.force,
    allow_belts = false,
  }
end

-- =============================================================================
-- #25: circuit control
-- =============================================================================

--- Is this turret currently disabled by its own circuit condition?
-- The engine already applies the condition; this only reads it so the FSM can
-- avoid charging a gun the player has switched off.
--
-- KNOWN BROKEN, the electric-turret chassis swap, NOT FIXED YET.
-- `.disabled` is a LuaArtilleryTurretControlBehavior field; get_control_behavior
-- now returns a LuaTurretControlBehavior instead (confirmed via apiq -- a
-- different class, with read_ammo/set_priority_list/
-- ignore_unlisted_targets_condition, no `disabled` at all). So `cb.disabled`
-- reads nil, the comparison is always false, and this silently stops noticing
-- a circuit-disabled installation instead of erroring -- LOW severity, since
-- nothing safety-critical depends on it (the "never fires on its own" model
-- is entirely attack_parameters.range and scripts/beam.lua, not this), but a
-- real, live regression rather than a cosmetic one. Whatever the 2.0 turret
-- family's actual enable/disable-by-circuit surface is has not been found
-- yet -- needs its own look, not a guess bolted on here.
function logistics.circuit_disabled(rec)
  local e = rec.entity
  if not (e and e.valid) then return false end
  local cb = e.get_control_behavior()
  if not cb then return false end
  return cb.disabled == true
end

return logistics
