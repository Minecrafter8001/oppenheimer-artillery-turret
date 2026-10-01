-- scripts/blueprint.lua -------------------------------------------------------------
-- Keeping the five-entity assembly intact through blueprints, ghosts and
-- undo/redo. Backlog #70.
--
-- This is the part that always breaks in multi-entity mods, and it breaks
-- quietly: the blueprint captures fine, pastes fine, and then the player has
-- four accumulators that never link to the gun because the linking code only
-- ever ran on manual placement.
--
-- THE THREE WAYS THE ASSEMBLY GETS BUILT
--   1. by hand            on_built_entity        -- handled in turret/pylon
--   2. by construction    on_robot_built_entity  -- same handlers
--   3. from a ghost       script_raised_revive   -- same handlers
--
-- All three already route through the same code, so the linking works. What
-- does NOT work without this file is ORDER: a blueprint paste places entities
-- in whatever order the engine chooses, so the pylons frequently land before
-- the turret they belong to. pylon.link() finds no turret record and gives up,
-- and the pylon is orphaned forever.
--
-- Two defences:
--   * turret.on_built calls pylon.adopt_existing(), which sweeps for pylons
--     already standing in its slots (handles pylons-before-turret)
--   * this file re-sweeps on a slow timer, catching anything both paths missed
--     -- another mod's script_raised_built, /editor placement, an undo that
--     restored one half of the pair
--
-- The re-sweep is deliberately cheap and slow. It is a safety net, not the
-- mechanism; if it is doing real work every time it runs, something upstream
-- is broken and should be fixed there.
--------------------------------------------------------------------------------------

local C      = require("config")
local N      = require("lib.names")
local audio = require("scripts.audio")
local events = require("scripts.events")
local schema = require("scripts.schema")
local pylon  = require("scripts.pylon")

local blueprint = {}

-- =============================================================================
-- Orphan recovery
-- =============================================================================

--- Re-link anything that came out of a paste in the wrong order.
function blueprint.resweep()
  local checked = 0
  for _, rec in pairs(storage.turrets) do
    if schema.valid(rec) then
      local n = 0
      for _ in pairs(rec.pylons or {}) do n = n + 1 end
      local m = 0
      for _ in pairs(rec.masts or {}) do m = m + 1 end
      -- Only bother with incomplete installations. A complete one has nothing
      -- to recover and scanning it is wasted work.
      --
      -- MASTS COUNT TOWARD "COMPLETE". Testing the banks alone would mean a gun
      -- with all sixteen banks and no linked substations is never swept -- and a
      -- mast pasted before its turret is orphaned by exactly the same
      -- wrong-order mechanism this file exists for.
      if n < C.pylon.max_count or m < #C.substation_slot_defs() then
        pylon.adopt_existing(rec)
        checked = checked + 1
      end
    end
  end
  return checked
end

-- =============================================================================
-- Blueprint capture
--
-- The turret and the pylons are ordinary entities with ordinary items, so the
-- engine blueprints them without help. What it cannot know is that they belong
-- together -- but because the pylon positions are DERIVED from the turret's
-- position (C.pylon_offset), a blueprint that captured all five will paste all
-- five at the right relative offsets, and adopt_existing() reconnects them.
--
-- That is why the geometry lives in config as an offset rather than being
-- stored per turret: derived geometry survives a blueprint, stored geometry
-- does not.
-- =============================================================================

--- A player just picked up a blueprint. If it contains one of our turrets but
--- not its pylons, say so -- silently pasting a gun that cannot fire is a
--- worse outcome than a one-line warning.
function blueprint.on_setup(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local stack = event.stack or (player.cursor_stack and player.cursor_stack.valid_for_read
                                and player.cursor_stack)
  if not (stack and stack.valid_for_read and stack.is_blueprint) then return end
  if not stack.is_blueprint_setup() then return end

  local ents = stack.get_blueprint_entities()
  if not ents then return end

  -- Masts count as installation hardware here for the same reason they do in
  -- resweep: a blueprint that caught the gun and its banks but clipped the
  -- corners pastes an installation with no power connection at all, which looks
  -- exactly like a bug and is the thing this warning exists to prevent.
  local turrets, pylons = 0, 0
  for _, e in pairs(ents) do
    if e.name == N.turret then
      turrets = turrets + 1
    elseif pylon.NAMES[e.name] or pylon.MAST_NAMES[e.name] then
      pylons = pylons + 1
    end
  end

  local want = C.pylon.max_count + #C.substation_slot_defs()
  if turrets > 0 and pylons < turrets * want then
    audio.notify(player, {"oppenheimer.blueprint-missing-pylons",
                 tostring(turrets), tostring(pylons),
                 tostring(turrets * want)})
  end
end

-- =============================================================================
-- Events
-- =============================================================================

events.on(defines.events.on_player_setup_blueprint, blueprint.on_setup)

-- The safety net. Slow on purpose -- see the header.
events.on_nth_tick(C.control.resweep_interval, function()
  blueprint.resweep()
end)

return blueprint
