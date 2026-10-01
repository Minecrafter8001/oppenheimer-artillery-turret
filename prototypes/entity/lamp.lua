-- prototypes/entity/lamp.lua -----------------------------------------------------
-- The ground lamps flanking the four beam lanes: base's "small-lamp" cloned under
-- this mod's own name so placement can tell them from a player's lamps; a slot
-- under a bank fails the load (C.lamp_slot_defs). always_on: scripts/render.lua's
-- render.lights() colours them by state, finding them by position.
--------------------------------------------------------------------------------------

local C    = require("config")
local N    = require("lib.names")
local util = require("util")

local l = C.lamp

-- Build (and so clearance-check) the slots at load. Errors name the slot.
C.lamp_slot_defs()

local RATIO = l.sprite_scale / l.base_sprite_scale
local function px(x, y) return util.by_pixel(x * RATIO, y * RATIO) end

data:extend({

  {
    type = "lamp",
    name = N.ground_lamp,
    icon = "__base__/graphics/icons/small-lamp.png",
    flags = {"placeable-neutral", "player-creation"},
    fast_replaceable_group = "lamp",
    minable = {mining_time = 0.1, result = N.ground_lamp},
    max_health = l.max_health,
    corpse = "lamp-remnants",
    dying_explosion = "lamp-explosion",
    -- Scaled with RATIO like every other companion entity's boxes -- vanilla's
    -- own 0.15/0.5 halves, at this installation's sprite scale instead of 0.5.
    collision_box = {{-0.15 * RATIO, -0.15 * RATIO}, {0.15 * RATIO, 0.15 * RATIO}},
    selection_box = {{-0.5 * RATIO, -0.5 * RATIO}, {0.5 * RATIO, 0.5 * RATIO}},
    impact_category = "glass",
    open_sound = {filename = "__base__/sound/open-close/electric-small-open.ogg", volume = 0.7},
    close_sound = {filename = "__base__/sound/open-close/electric-small-close.ogg", volume = 0.7},

    energy_source = {
      type = "electric",
      usage_priority = "lamp",
    },
    energy_usage_per_tick = "5kW",
    darkness_for_all_lamps_on  = 0.5,
    darkness_for_all_lamps_off = 0.3,
    -- ALWAYS ON (this session). Vanilla's own darkness rule otherwise governs
    -- when a lamp lights at all -- correct for a decorative fixture, wrong for
    -- a status indicator that has to read the same at noon as at midnight.
    -- darkness_for_all_lamps_on/off above are harmless left in place: this
    -- flag is documented as overriding them outright.
    always_on = true,
    light              = {intensity = 0.9, size = 40, color = {1, 1, 0.75}},
    -- WAS vanilla's own {intensity = 0, size = 6, ...} -- correct for a lamp
    -- that occasionally shows a circuit signal colour, wrong for a fixture
    -- that is now ALWAYS in "coloured" mode (render.lights writes .color on
    -- every repaint, so this entity is for practical purposes never showing
    -- plain `light` again). Left at vanilla's size-6 dim default, this is what
    -- read as "so dim the actual running lights are overpowering them" --
    -- matched to `light` above instead: same size, same intensity, white base
    -- so .color's own RGB is the only thing deciding the hue.
    light_when_colored = {intensity = 0.9, size = 40, color = {1, 1, 1}},
    glow_size = 6,
    glow_color_intensity = 1,
    glow_render_mode = "multiplicative",

    picture_off = {
      layers = {
        {
          filename = "__base__/graphics/entity/small-lamp/lamp.png",
          priority = "high",
          width = 83, height = 70,
          shift = px(0.25, 3),
          scale = l.sprite_scale,
        },
        {
          filename = "__base__/graphics/entity/small-lamp/lamp-shadow.png",
          priority = "high",
          width = 76, height = 47,
          shift = px(4, 4.75),
          draw_as_shadow = true,
          scale = l.sprite_scale,
        },
      },
    },
    picture_on = {
      filename = "__base__/graphics/entity/small-lamp/lamp-light.png",
      priority = "high",
      width = 90, height = 78,
      shift = px(0, -7),
      scale = l.sprite_scale,
    },
  },

  {
    type = "item",
    name = N.ground_lamp,
    icon = "__base__/graphics/icons/small-lamp.png",
    subgroup = "defensive-structure",
    -- Sorts after the masts.
    order = "b[turret]-d[artillery-turret]-e[oppenheimer-pylon]-e",
    place_result = N.ground_lamp,
    stack_size = l.stack_size,
  },

  {
    type = "recipe",
    name = N.ground_lamp,
    enabled = false,
    energy_required = C.recipe.lamp.energy_required,
    ingredients = C.recipe.lamp.ingredients,
    results = {{type = "item", name = N.ground_lamp, amount = 1}},
  },

})
