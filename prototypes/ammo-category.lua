-- prototypes/ammo-category.lua ----------------------------------------------
-- An ammo category is the link between a gun and the ammo it accepts. The mod
-- defines its own so its shell only ever feeds its own gun.
--
-- To make our shell interchangeable with vanilla artillery shells instead,
-- delete this file, drop the require from data.lua, and change every
-- `ammo_category = "oppenheimer-artillery-shell"` in this mod to `"artillery-shell"`.
--
-- Note: this ammo-category and the ammo item in prototypes/item.lua share the
-- name "oppenheimer-artillery-shell". That is legal -- they are different
-- prototype types -- and it mirrors how base game names its `artillery-shell`.
----------------------------------------------------------------------------

local N = require("lib.names")

data:extend({
  {
    type = "ammo-category",
    name = N.shell,
    -- Reuses the vanilla artillery-shell category icon (Factoriopedia only).
    icon = "__base__/graphics/icons/ammo-category/artillery-shell.png",
    subgroup = "ammo-category",
  },

  -- --------------------------------------------------------------------------
  -- THE DEAD CATEGORY. Nothing is in it and nothing ever will be.
  --
  -- It exists to be named by the flare's `shot_category`, and that one line is
  -- what stops this mod's own targeting remote from being a firing order.
  --
  -- The mechanism, from the shipped 2.0.77 prototype spec
  -- (ArtilleryFlarePrototype::shot_category):
  --
  --   "Only artillery turrets/wagons whose ammo's ammo_category matches this
  --    category will shoot at this flare. Defaults to ALL ammo categories being
  --    able to shoot at this flare."
  --
  -- So a flare with no category is a general order to every artillery piece on
  -- the surface, and a flare pointed at a category no gun can load is an order
  -- nothing can answer.
  --
  -- WHY THIS STILL MATTERS TODAY, even though the current designator
  -- (prototypes/item.lua, a "selection-tool") places nothing and no flare is
  -- ever created by this mod any more (scripts/turret.lua: "NO FLARE. NOT
  -- HERE, NOT LATER, NOT EVER"; scripts/targeting.lua's targeting.flare is a
  -- disarmed stub for the same reason). N.flare itself is still declared
  -- (prototypes/entity.lua), kept vestigial alongside N.shell/N.projectile for
  -- a pre-0.8.0 save with a round already in the air -- and its
  -- `shot_category` still has to point somewhere nothing can answer. This is
  -- also the reason a future automatic-targeting revival must keep pointing
  -- any flare it creates at THIS category, never at N.shell: N.shell is the
  -- ammo item's own category, and a live artillery-remote-style capsule aimed
  -- at it was a real order to fire on the spot with no charge, no
  -- confirmation and no lance -- the 0.8.0 bug this mod spent two versions
  -- eliminating (see item.lua's own header on why the capsule type had to go).
  {
    type = "ammo-category",
    name = N.inert_category,
    -- No `hidden`: AmmoCategory has no such field in the shipped 2.0.77 spec, so
    -- this category is visible in Factoriopedia's category list. Cosmetic, and
    -- an invented field would be worse than a stray line in an encyclopedia.
    icon = "__base__/graphics/icons/ammo-category/artillery-shell.png",
    subgroup = "ammo-category",
  },
})
