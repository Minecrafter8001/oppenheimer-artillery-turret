-- prototypes/technology.lua ------------------------------------------------------
-- N.tech.artillery unlocks the installation; N.tech.capacity (bounded,
-- C.tech.capacity_levels) allows one more installation per level, read back in Lua
-- (C.capacity) and enforced where one is built (scripts/placement.lua).
-- HAZARD: renaming a technology orphans every save that researched it.
-- LOCALE TRAP: a tech named "...-<number>" is looked up WITHOUT that suffix;
-- lib/names.lua holds both forms.
------------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local ICON      = "__base__/graphics/technology/laser-turret.png"
local ICON_SIZE = 256

local tier = mods["space-age"] and C.tech.space_age or C.tech.vanilla

data:extend({

  {
    type = "technology",
    name = N.tech.artillery,
    icon = ICON,
    icon_size = ICON_SIZE,
    prerequisites = tier.prerequisites,
    effects = {
      {type = "unlock-recipe", recipe = N.turret},
      {type = "unlock-recipe", recipe = N.pylon},
      {type = "unlock-recipe", recipe = N.substation},
      {type = "unlock-recipe", recipe = N.ground_lamp},
    },
    unit = {
      count = tier.count,
      time = tier.time,
      ingredients = tier.ingredients,
    },
  },

  {
    type = "technology",
    name = N.tech.capacity,
    icon = ICON,
    icon_size = ICON_SIZE,
    localised_description = {"technology-description." .. N.tech.capacity_locale,
      tostring(1 + C.tech.capacity_levels),
      tostring(math.floor((1 + C.tech.capacity_levels) * C.charge.overcharge_max * 100 + 0.5))},
    prerequisites = {N.tech.artillery},
    effects = {
      {type = "nothing", effect_description = {"modifier-description." .. N.tech.capacity_locale}},
    },
    unit = {
      count_formula = C.tech.capacity_count_formula,
      time = C.tech.capacity_time,
      ingredients = tier.ingredients,
    },
    max_level = C.tech.capacity_levels,
  },

})
