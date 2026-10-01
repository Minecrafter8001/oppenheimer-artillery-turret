-- prototypes/vfx/carriers.lua ------------------------------------------------------
-- One invisible explosion per selectable yield, each carrying that yield's whole
-- staged detonation in its `created_effect`. Backlog #83 + #101.
--
-- WHY A CARRIER RATHER THAN THE SHELL'S OWN ACTION
-- A detonation is a data-stage trigger tree with no runtime handle. The shell,
-- however, is chosen by the player's ammo, not by the yield selector -- so the
-- shell cannot BE the yield. The chain is therefore:
--
--   turret fires -> shell -> artillery projectile -> impact raises a script
--   trigger -> scripts/impact.lua looks up the yield that was paid for and
--   creates the matching carrier here -> created_effect fires the detonation
--
-- The projectile keeps its own direct hit (see prototypes/projectile.lua), so a
-- shell that lands always does artillery damage even if the lookup misses.
-- Everything the capacitors paid for is in here.
--
-- THIS IS A BASE-GAME PATTERN, NOT AN INVENTION.
-- `nuke-effects-nauvis` (base/prototypes/entity/explosions.lua) is an explosion
-- with `animations = util.empty_sprite()` and a created_effect carrying the
-- nuke's set-tile scarring, spawned by the atomic bomb's action. Confirmed in
-- the local 2.0.77 install, and `created_effect` is declared on EntityPrototype
-- in the shipped prototype spec -- so it is available on every entity type,
-- explosions included.
--------------------------------------------------------------------------------------

local C     = require("config")
local N     = require("lib.names")
local waves = require("prototypes.vfx.waves")

local util = require("util")

local carriers = {}

for i, step in ipairs(C.charge.yield_targets) do
  local tag = N.yield_tag(step.fraction)
  local effects = waves.variants[tag]
  -- A carrier with no effects would be a shell that lands and does nothing --
  -- fail at load instead, where it is one line to read.
  assert(effects, "no detonation variant built for yield " .. tag .. "%")

  carriers[#carriers + 1] = {
    type = "explosion",
    name = N.detonation(step.fraction),
    flags = {"not-on-map"},
    hidden = true,
    subgroup = "explosions",
    order = string.format("z[oppenheimer]-y-%02d", i),
    height = 0,
    animations = util.empty_sprite(),
    created_effect = {
      type = "direct",
      action_delivery = {
        type = "instant",
        target_effects = effects,
      },
    },
  }
end

data:extend(carriers)
