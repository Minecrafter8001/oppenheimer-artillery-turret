-- prototypes/item.lua --------------------------------------------------------
-- Three item-ish prototypes:
--   ammo    "oppenheimer-artillery-shell"   -- what you load into the turret
--   item    "oppenheimer-artillery-turret"  -- the thing in your inventory you place
--   capsule "oppenheimer-artillery-remote"  -- click a spot on the map to call a strike
------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

-- Shared by the designator item and its shortcut so the two can never drift
-- apart in the shortcut bar.
local ICON_REMOTE = "__base__/graphics/icons/artillery-targeting-remote.png"
local ICON_TINT   = {r = 1.0, g = 0.55, b = 0.15}

local kg = 1000  -- weight helper; base game defines this globally, we do it locally

data:extend({

  ----------------------------------------------------------------------------
  -- AMMO: the shell. target_type = "position" means it strikes a map location
  -- (chosen by the turret's auto-targeting, or by the remote), not a unit.
  ----------------------------------------------------------------------------
  {
    type = "ammo",
    name = N.shell,
    -- was artillery-shell.png -- there is no shell (see `hidden` below,
    -- and the electric-turret chassis has no ammo inventory at all since
    -- 0.23.0). This item never actually renders anywhere `hidden` reaches, but
    -- an ammo-category icon reads closer to "condensed lasing charge" than an
    -- artillery round if it ever does.
    icon = "__base__/graphics/icons/ammo-category/laser.png",
    ammo_category = N.shell,
    ammo_type = {
      target_type = "position",
      action = {
        type = "direct",
        action_delivery = {
          type = "artillery",
          projectile = N.projectile,                        -- prototypes/projectile.lua
          starting_speed = C.shell.starting_speed,
          direction_deviation = 0,
          range_deviation = 0,
          -- Fired from the gun: the muzzle flash, and #85, a short tight
          -- camera shake so you FEEL the shot leave. Distinct from the
          -- detonation shake (#96), which fires when it lands -- together they
          -- bracket the shell's whole flight.
          source_effects = {
            {
              type = "create-explosion",
              entity_name = N.base.muzzle_flash,             -- base entity, by name
            },
            {
              type = "camera-effect",
              duration = C.gun.recoil_shake.duration,
              ease_in_duration = 2,
              ease_out_duration = C.gun.recoil_shake.duration,
              strength = C.gun.recoil_shake.strength,
              full_strength_max_distance = C.gun.recoil_shake.full_distance,
              max_distance = C.gun.recoil_shake.max_distance,
            },
          },
        },
      },
    },
    subgroup = "ammo",
    order = "d[explosive-cannon-shell]-d[artillery]-b[oppenheimer]",
    stack_size = C.shell.stack_size,
    weight = C.shell.weight,

    -- HIDDEN, AND IT HAS TO BE.
    --
    -- The cell is no longer a thing a player makes and carries. It is charge,
    -- condensed: turret.sync_cells creates and destroys them to track what is in
    -- the capacitor banks, one per percent of a standard shot. There is no
    -- recipe and no technology that unlocks one -- see prototypes/recipe.lua and
    -- prototypes/technology.lua, where both were removed rather than left
    -- disabled.
    --
    -- `hidden` is what keeps it out of the places a phantom item is a nuisance
    -- rather than a mystery: logistic requests, filters, constant combinators,
    -- the crafting menu. Without it a player can request a hundred cells into a
    -- chest and wait forever for something no recipe produces.
    --
    -- Confirmed against the shipped 2.0.77 spec: ItemPrototype.hidden, boolean,
    -- optional, default false, and hidden_in_factoriopedia defaults to the value
    -- of hidden -- so this one field also takes it out of Factoriopedia, which is
    -- correct. The gun's own cells are not a thing to look up; the gun is.
    hidden = true,
  },

  ----------------------------------------------------------------------------
  -- ITEM: the placeable turret. place_result ties it to the entity.
  ----------------------------------------------------------------------------
  {
    type = "item",
    name = N.turret,
    -- was artillery-turret.png -- matches the entity's own chassis
    -- (electric-turret, laser-turret's graphics),
    -- same reasoning as prototypes/technology.lua's ICON.
    icon = "__base__/graphics/icons/laser-turret.png",
    subgroup = "turret",
    order = "b[turret]-d[artillery-turret]-c[oppenheimer]",
    place_result = N.turret,
    stack_size = C.turret.item_stack_size,
    weight = 200 * kg,
  },

  ----------------------------------------------------------------------------
  -- THE DESIGNATOR. A SELECTION TOOL, NOT AN ARTILLERY-REMOTE CAPSULE.
  ----------------------------------------------------------------------------
  --
  -- READ THIS BEFORE CHANGING THE TYPE BACK. It was a capsule with
  -- capsule_action = {type = "artillery-remote"} for seven versions, and that
  -- one field put the ENGINE in the middle of this mod's firing path with two
  -- behaviours neither of which is wanted:
  --
  --   1. IT VETOES THE CLICK. Before the mod sees anything, the engine looks for
  --      an artillery turret in range holding ammo whose category matches the
  --      flare's shot_category. If it finds none it prints the core string
  --      no-artillery-with-ammo-in-range -- "No artillery with ammo in range." --
  --      and does not raise on_player_used_capsule at all. The mod is never told
  --      the player clicked. Pointing the flare at an inert ammo category to stop
  --      it commanding the gun therefore silently disabled the entire designator,
  --      and the message the player saw came from the engine, which is why it
  --      matched no string in this mod's locale.
  --
  --   2. IT DROPS A FLARE. Not the mod -- the engine, on every use. A flare is a
  --      firing order, so the first press fired a live shell.
  --
  -- Both are properties of the capsule ACTION, and neither can be configured
  -- away: a shot_category that permits firing re-arms (2), and one that forbids
  -- it triggers (1). There is no third setting. The type has to go.
  --
  -- A selection-tool has neither behaviour. mode = {"nothing"} selects nothing,
  -- vetoes nothing and places nothing; it just raises on_player_selected_area
  -- with the rectangle the player dragged, whose centre is the designated point.
  -- The engine is now entirely out of the firing path -- which is the thing this
  -- mod has been trying and failing to achieve.
  --
  -- The name is unchanged on purpose: renaming would orphan it, and the item is
  -- "only-in-cursor" so no save can be holding a stack of the old capsule.
  {
    type = "selection-tool",
    name = N.remote,
    -- TINTED, and deliberately. The untinted icon is byte-for-byte vanilla's
    -- artillery targeting remote, so the two sat side by side in the shortcut bar
    -- looking identical -- and reaching for the wrong one produces a vanilla
    -- flare, a vanilla firing order and a bug report about this mod.
    icons = {{icon = ICON_REMOTE, icon_size = 64, tint = ICON_TINT}},
    flags = {"only-in-cursor", "not-stackable", "spawnable"},
    auto_recycle = false,
    subgroup = "spawnables",
    order = "b[turret]-d[artillery-turret]-d[oppenheimer-remote]",
    stack_size = C.remote.stack_size,

    -- Drag or click: either way the mod takes the centre of the rectangle.
    select = {
      border_color = ICON_TINT,
      cursor_box_type = "not-allowed",
      mode = {"nothing"},
    },
    alt_select = {
      border_color = ICON_TINT,
      cursor_box_type = "not-allowed",
      mode = {"nothing"},
    },
  },
})
