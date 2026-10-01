-- prototypes/entity/substation.lua ---------------------------------------------------
-- The masts: four substations unique to the installation, one outside each
-- capacitor cluster. Entity, item and recipe, together, because it is ONE thing
-- -- splitting three prototypes across two files for symmetry with the
-- three-tier bank family would be worse than keeping them in one place.
--
-- WHY THEY EXIST
-- Asked for as decoration -- "some substations unique to the turret, just for
-- visual effect" -- and that is genuinely the first reason. Sixteen capacitor
-- banks and a nine-tile gun read as equipment scattered on concrete until
-- something VERTICAL stands at the corners and ties the footprint together.
--
-- They were made real rather than decorative because the same four objects
-- solve a problem the installation already had. Sixteen banks is sixteen
-- entities that each have to be inside somebody's supply area, which meant
-- hand-placing a lattice of medium poles inside the pad, every time. One mast
-- per cluster covers its own four outright (supply_area_distance is a RADIUS --
-- confirmed from the shipped spec, "if this is 3.5, the pole will have a 7x7
-- supply area"), and the wire reach is derived to chain the four masts to each
-- other and no further. So the whole installation takes ONE power drop.
--
-- And they carry the status lights (C.lights, scripts/render.lua). A mast is the
-- natural place for a beacon: tallest thing on the pad, standing at the corner,
-- so the state of the gun is legible from OUTSIDE the installation rather than
-- only from standing in the middle of it.
--
-- THE ART is base's substation, borrowed by path and drawn at twice the scale it
-- was authored at. Which means the standing trap applies to every number below:
-- a `shift` is in TILES and does NOT follow `scale`, and neither do
-- connection_points. Both go through px(), for the same reason
-- prototypes/entity.lua's own SCALING header does -- authored offsets drift off
-- a scaled sprite, and the only thing that catches it is noticing the wires
-- leave from mid-air.
--------------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local util = require("util")

local s = C.substation

local RATIO = s.sprite_scale / s.base_sprite_scale
local function px(x, y) return util.by_pixel(x * RATIO, y * RATIO) end

-- Base substation's four wire connection points, in the pixel coordinates they
-- are authored in, copied verbatim from
-- __base__/prototypes/entity/entities.lua. Copying a working precedent rather
-- than authoring wire anchors blind is the standing rule for anything whose
-- correctness only shows up on screen.
local RAW_POINTS = {
  {shadow = {copper = {136,  8}, green = {124,  8}, red = {151,   9}},
   wire   = {copper = {  0, -86}, green = {-21, -82}, red = { 22, -81}}},
  {shadow = {copper = {133,  9}, green = {144, 21}, red = {110,  -3}},
   wire   = {copper = {  0, -85}, green = { 15, -70}, red = {-15, -92}}},
  {shadow = {copper = {133,  9}, green = {127, 26}, red = {127,  -8}},
   wire   = {copper = {  0, -85}, green = {  0, -66}, red = {  0, -97}}},
  {shadow = {copper = {133,  9}, green = {111, 20}, red = {144,  -3}},
   wire   = {copper = {  0, -86}, green = {-15, -71}, red = { 15, -92}}},
}

--- Scale one connection point out of the raw pixel table.
-- Generated rather than typed twice, so the eight vectors per point cannot be
-- scaled by hand with one of them missed.
local function connection_points()
  local out = {}
  for i, raw in ipairs(RAW_POINTS) do
    local point = {}
    for group, wires in pairs(raw) do
      local scaled = {}
      for wire, v in pairs(wires) do
        scaled[wire] = px(v[1], v[2])
      end
      point[group] = scaled
    end
    out[i] = point
  end
  return out
end

local half = s.tile_size / 2

data:extend({

  {
    type = "electric-pole",
    name = N.substation,
    icon = "__base__/graphics/icons/substation.png",
    flags = {"placeable-neutral", "player-creation"},
    minable = {mining_time = 0.3, result = N.substation},
    fast_replaceable_group = N.substation_group,
    max_health = s.max_health,
    corpse = "substation-remnants",
    dying_explosion = "substation-explosion",
    resistances = {
      {type = "fire", percent = 90},
    },
    collision_box = {{-half + 0.1, -half + 0.1}, {half - 0.1, half - 0.1}},
    selection_box = {{-half, -half}, {half, half}},
    -- The sprite is 270 px tall at twice base scale -- nearly seventeen tiles of
    -- drawn height on a three tile footprint. Without this the top of the mast
    -- is clipped by whatever is drawn north of it.
    drawing_box_vertical_extension = 4,

    -- DERIVED, both of them. The wire reach is exactly the distance to the
    -- neighbouring mast plus slack (C.substation_wire_distance), so the ring of
    -- four closes from one drop and these deliberately do NOT become a
    -- general-purpose long-haul pole that happens to be unlocked by an
    -- artillery technology.
    maximum_wire_distance = C.substation_wire_distance(),
    supply_area_distance = s.supply_area_distance,

    -- A mast is a legitimate target, exactly as a bank is: cut the power to a
    -- cluster and four banks stop filling.
    is_military_target = true,

    pictures = {
      layers = {
        {
          filename = "__base__/graphics/entity/substation/substation.png",
          priority = "high",
          width = 138,
          height = 270,
          direction_count = 4,
          shift = px(0, -31),
          scale = s.sprite_scale,
        },
        {
          filename = "__base__/graphics/entity/substation/substation-shadow.png",
          priority = "high",
          width = 370,
          height = 104,
          direction_count = 4,
          shift = px(62, 10),
          draw_as_shadow = true,
          scale = s.sprite_scale,
        },
      },
    },

    connection_points = connection_points(),

    radius_visualisation_picture = {
      filename = "__base__/graphics/entity/small-electric-pole/electric-pole-radius-visualization.png",
      width = 12,
      height = 12,
      priority = "extra-high-no-scale",
    },

    impact_category = "metal",
    -- Inlined rather than required out of base's own sounds table. A cross-mod
    -- require into base internals is the trap CLAUDE.md section 9 names: it may
    -- resolve against base's relative requires or re-execute the file in this
    -- context and drag its transitive requires along.
    open_sound = {filename = "__base__/sound/machine-open.ogg", volume = 0.5},
    close_sound = {filename = "__base__/sound/machine-close.ogg", volume = 0.5},
    working_sound = {
      sound = {
        filename = "__base__/sound/substation.ogg",
        volume = 0.5,
        audible_distance_modifier = 0.6,
      },
      max_sounds_per_prototype = 4,
      fade_in_ticks = 30,
      fade_out_ticks = 40,
      use_doppler_shift = false,
    },
  },

  {
    type = "item",
    name = N.substation,
    icon = "__base__/graphics/icons/substation.png",
    subgroup = "defensive-structure",
    -- Sorts immediately after the three bank tiers, which end at "-c".
    order = "b[turret]-d[artillery-turret]-e[oppenheimer-pylon]-d",
    place_result = N.substation,
    stack_size = s.stack_size,
    weight = 100 * 1000,
  },

  {
    type = "recipe",
    name = N.substation,
    enabled = false,
    energy_required = C.recipe.substation.energy_required,
    ingredients = C.recipe.substation.ingredients,
    results = {{type = "item", name = N.substation, amount = 1}},
  },

})
