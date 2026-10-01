-- prototypes/entity/pylon-item.lua --------------------------------------------------
-- Item and recipe for the pylon. Backlog #63.
--
-- Split from pylon.lua so the entity file stays about the entity. Item, recipe
-- and entity share a name -- legal, because they are different prototype types,
-- and it is how base names its own accumulator.
--
-- A recipe with the same name as an item automatically produces that item and
-- borrows its icon and localised name, so there is no icon here.
--------------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local kg = 1000

local function pylon_item(name, order, tint, stack)
  return {
    type = "item",
    name = name,
    icon = "__base__/graphics/icons/accumulator.png",
    subgroup = "defensive-structure",
    order = "b[turret]-d[artillery-turret]-e[oppenheimer-pylon]-" .. order,
    place_result = name,
    stack_size = stack or 20,
    weight = 100 * kg,
    -- Tint carries the tier's colour through into the inventory icon so the
    -- three are distinguishable at a glance, matching the entity sprites.
    icon_tintable_mask = nil,
    pictures = {
      {
        filename = "__base__/graphics/icons/accumulator.png",
        size = 64,
        scale = 0.5,
        mipmap_count = 4,
        tint = tint,
      },
    },
  }
end

data:extend({

  pylon_item(N.pylon, "a", {r = 0.75, g = 0.85, b = 1.0, a = 1.0}),

  -- ===========================================================================
  -- Recipe. Unlocked by the same technology as the turret -- a gun you cannot
  -- power is not a gun.
  -- ===========================================================================
  {
    type = "recipe",
    name = N.pylon,
    enabled = false,
    energy_required = C.recipe_for("pylon").energy_required,
    ingredients = C.recipe_for("pylon").ingredients,
    results = {{type = "item", name = N.pylon, amount = 1}},
  },

})
