-- prototypes/projectile.lua --------------------------------------------------
-- The shell in flight. An "artillery-projectile" arcs to a target position,
-- runs `action` on impact, then `final_action` for scorch marks / cleanup.
--
-- This is where the shell's DAMAGE lives. We scale it by the startup setting so
-- there's one number to tune.
------------------------------------------------------------------------------

-- Nothing here reads `settings` directly (ARCHITECTURE.md rule 1). Nothing here
-- reads damage numbers either, any more -- see the block below.
local N = require("lib.names")

data:extend({
  {
    type = "artillery-projectile",
    name = N.projectile,
    flags = {"not-on-map"},
    hidden = true,
    reveal_map = true,                 -- uncovers fog where it lands
    map_color = {1, 1, 0},
    picture = {
      filename = "__base__/graphics/entity/artillery-projectile/shell.png",
      draw_as_glow = true,
      width = 64,
      height = 64,
      scale = 0.5,
    },
    shadow = {
      filename = "__base__/graphics/entity/artillery-projectile/shell-shadow.png",
      width = 64,
      height = 64,
      scale = 0.5,
    },
    chart_picture = {
      filename = "__base__/graphics/entity/artillery-projectile/artillery-shoot-map-visualization.png",
      flags = {"icon"},
      width = 64,
      height = 64,
      priority = "high",
      scale = 0.25,
    },

    -- ============================================================
    -- DELIBERATELY INERT. THIS SHELL DOES NOTHING WHEN IT LANDS.
    -- ============================================================
    --
    -- There is no `action` and no `final_action`, and that is the point.
    --
    -- WHAT THIS PROTOTYPE IS FOR NOW. The installation fires a beam. The
    -- resonance cell in the chamber is a battery, not ordnance, and the crater
    -- is put on the ground by scripts/impact.lua at the end of a sequence a
    -- player authorised. Nothing in the mod's own firing path passes through
    -- here. The prototype survives only because the cannon's ammo declares an
    -- `artillery` action_delivery and that delivery has to name a projectile.
    --
    -- WHY IT IS GUTTED RATHER THAN DELETED. This is the choke point every
    -- accidental shot funnels through, and 0.8.0 proved accidental shots are
    -- reachable. The chain was:
    --
    --   any artillery flare on the surface  ->  the engine fires this gun
    --     -> this projectile lands
    --     -> its action raised N.fx.detonated
    --     -> scripts/impact.lua could not match it to a paid order
    --     -> impact.variant_for(nil) fell back to C.charge.yield_default = 1.00
    --     -> a FULL Oppenheimer detonation, unordered and uncharged.
    --
    -- A vanilla artillery targeting remote is enough to start that chain: base's
    -- own `artillery-flare` sets no `shot_category`, and the shipped 2.0.77 spec
    -- says a flare without one is an order every artillery piece on the surface
    -- will answer, whatever its ammo category. Our custom category never
    -- isolated us from it. That is how a sandbox base got deleted by its own
    -- artillery remote.
    --
    -- So the fix is not "make the flare harder to get". Two other locks landed
    -- in 0.8.1 -- an inert shot_category on our flare, disable_automatic_firing
    -- on the turret -- but both depend on reasoning about what commands the gun,
    -- and that reasoning has now been wrong twice. This one does not: a
    -- projectile with no action cannot detonate anything no matter who fired it,
    -- how, or why. The worst a stray shot can now cost is one resonance cell.
    --
    -- IF YOU EVER WANT SHELL DAMAGE BACK, it does not go here. Give the shell a
    -- second, differently-named projectile and let the LANCE keep this dud, so
    -- that "the gun fired without being asked" can never again mean "and it went
    -- off at full yield".

    height_from_ground = 280 / 64,
  },
})
