-- prototypes/recipe.lua ------------------------------------------------------
-- How the turret is crafted; `enabled = false` until the technology in
-- technology.lua unlocks it. Ingredients and results use the 2.0 long form
-- {type = "item"|"fluid", name = "...", amount = N}. A recipe named after its
-- item produces it and borrows its icon and localised name.
------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

data:extend({
  {
    type = "recipe",
    name = N.turret,
    enabled = false,
    energy_required = C.recipe_for("turret").energy_required,  -- seconds at crafting speed 1
    ingredients = C.recipe_for("turret").ingredients,
    results = {
      {type = "item", name = N.turret, amount = 1},
    },
  },
  -- No cell recipe: cells are condensed from the banks by turret.sync_cells,
  -- which deletes any cell the charge does not account for.
})
