local function deepcopy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = deepcopy(child) end
  return result
end
table.deepcopy = deepcopy

local N = require("lib.names")
local C = require("config")
local function prototypes_for(space_age)
  data = {raw = {tile = {}, item = {}}}
  function data:extend(entries)
    for _, entry in ipairs(entries) do self.raw.tile[entry.name] = entry end
  end
  for _, source in pairs(N.tile_sources) do
    if space_age or source == N.base.nuclear_ground then
      data.raw.tile[source] = {
        type = "tile", name = source, subgroup = "vulcanus-tiles",
        fluid = source == N.base.lava and "lava" or nil,
        autoplace = {probability_expression = 1},
        collision_mask = {layers = {ground_tile = source ~= N.base.lava,
                                   lava_tile = source == N.base.lava}},
        transitions = {{to_tiles = {N.base.lava}}},
      }
    end
  end
  dofile("prototypes/tiles.lua")
end

prototypes_for(false)
assert(data.raw.tile[N.tiles.nuclear_ground])
assert(data.raw.tile[N.nauvis_tiles[N.tiles.nuclear_ground]])
assert(not data.raw.tile[N.tiles.lava])
prototypes_for(true)
local source_lava = data.raw.tile[N.base.lava]
assert(source_lava.fluid == "lava" and source_lava.autoplace)
for name, source in pairs(N.tile_sources) do
  local tile = assert(data.raw.tile[name])
  assert(not tile.fluid and not tile.autoplace and not tile.minable)
  assert(tile.collision_mask ~= data.raw.tile[source].collision_mask)
  assert(tile.allows_being_covered == not N.hot_tiles[name])
end

for _, style in ipairs({"zen", "early"}) do
  for _, result in ipairs({"artificial-grass", "artificial-grass-2", "artificial-grass-3"}) do
    data.raw.item[result] = {type = "item", name = result, stack_size = 100, place_as_tile = {
      result = result, condition_size = 1, tile_condition = {"grass-1"},
      invert = style == "early", condition = {layers = {ground_tile = true}},
    }}
  end
  mods = {[style == "zen" and "zen-garden" or "early-agriculture"] = "test"}
  local particle_setting = C.perf.enemy_particles_only_when_visible
  C.perf.enemy_particles_only_when_visible = false
  dofile("data-final-fixes.lua")
  dofile("data-final-fixes.lua")
  C.perf.enemy_particles_only_when_visible = particle_setting
  for _, item in pairs(data.raw.item) do
    local placement = assert(item.place_as_tile)
    local conditions = assert(placement.tile_condition)
    assert(placement.invert == (style == "early"))
    assert(placement.condition.layers.ground_tile)
    assert(#conditions == 6)
    for index = 2, #conditions do
      local name = conditions[index]
      assert(not N.hot_tiles[name])
      assert(data.raw.tile[name].subgroup == "nauvis-tiles")
    end
  end
end
assert(#data.raw.tile[N.tiles.volcanic_cracks].transitions[1].to_tiles == 3)

local callbacks = {}
package.loaded["scripts.events"] = {on_nth_tick = function(interval, callback)
  callbacks[#callbacks + 1] = callback
end}
package.loaded["scripts.profile"] = {start = function() end, stop = function() end,
                                     count = function() end}
package.loaded["scripts.slay"] = {flush = function() end}
package.loaded["scripts.front"] = {each_ring_run = function(cx, cy, low, high, callback)
  callback(0, 0, 0)
end}
prototypes = {tile = data.raw.tile, decorative = {}}
storage = {craters = {}}
game = {tick = 1000000}
local crater = require("scripts.crater")
assert(crater.molten(N.tiles.lava))
assert(crater.molten(N.nauvis_tiles[N.tiles.lava]))
assert(crater.molten(N.base.lava))
assert(not crater.molten(N.tiles.volcanic_cracks))

local function upvalue(callback, wanted)
  for index = 1, 100 do
    local name, value = debug.getupvalue(callback, index)
    if name == wanted then return value end
    if not name then break end
  end
  error("Missing upvalue " .. wanted)
end
local cooling_callback = callbacks[#callbacks]
local cool = upvalue(cooling_callback, "cool")
local cool_band = upvalue(cool, "cool_band")
local paint_band = upvalue(crater.replay, "paint_band")
local bands = upvalue(upvalue(crater.replay, "now_bands"), "bands")
local tile_at = upvalue(bands, "tile_at")
local lad = {glaze = {{tile = N.tiles.lava}}, cold = {{tile = N.tiles.nuclear_ground, u = 1}}}
assert(tile_at({}, lad, {0}, 0) == N.tiles.nuclear_ground)

for _, center in ipairs({0.5, 1, 1.25}) do
  for _, surface_name in ipairs({"nauvis", "vulcanus"}) do
    local current = N.tiles.lava
    local writes = {}
    local surface = {
      name = surface_name, planet = {name = surface_name},
      get_tile = function() return {name = current} end,
      is_chunk_generated = function() return true end,
      count_tiles_filtered = function() return 0 end,
      set_tiles = function(tiles)
        for _, tile in ipairs(tiles) do
          writes[tile.position[1] .. ":" .. tile.position[2]] = tile.name
        end
      end,
    }
    local record = {x = center, y = center, ys = 0, radius = 100,
                    salt = 17, phase = 0, up = 100, dn = 100, gen = {}, wet = {}}
    local cold = {{tile = N.tiles.nuclear_ground, u = 1}}
    local expected = surface_name == "nauvis" and N.nauvis_tiles[N.tiles.nuclear_ground]
                     or N.tiles.nuclear_ground
    for slice = 0, C.blast.rings.paint.cool.slices - 1 do
      cool_band(surface, record, cold, 0, 1, slice)
    end
    assert(writes["0:0"] == expected, "Center failed cooling")
    current, writes = "artificial-grass", {}
    for slice = 0, C.blast.rings.paint.cool.slices - 1 do
      cool_band(surface, record, cold, 0, 1, slice)
    end
    assert(not next(writes), "Cooling replaced grass")
    paint_band(surface, record, {}, cold, 0, 10, 0, 2, 0, 2)
    assert(writes["0:0"] == expected, "Paint missed center")
  end
end
local incomplete = {crater = {cooling = true, up = 0, dn = 0, lmax = 10,
                             clim = 10, lava_r = 10, wet = {}, gen = {}}}
crater.finish(incomplete)
assert(incomplete.crater.cooling and incomplete.crater.wet)
defines = {wire_connector_id = {pole_copper = 1}}
local schema = require("scripts.schema")
local steps = upvalue(schema.migrate, "steps")
assert(schema.VERSION == 29 and not steps[29])
assert(#callbacks == 1, "Unexpected terrain migration tick handler")
local heat = require("lib.heat")
local cooled = upvalue(cooling_callback, "cooled")
local ladder = upvalue(cool, "ladder")
for _, yield in ipairs({0.01, 0.25, 1, 10}) do
  storage.craters = {}
  game.tick = 0
  local record = crater.begin{
    radius = 20, x = 0.5, y = 0.5, surface = 1, force = "player",
    started = 0, ticks = 60, yield = yield,
  }
  local thickness = record.glaze * (1 + C.heat.ground.bowl)
  local seconds = math.max(heat.glaze_seconds(thickness, C.heat.ground.t_melt),
                          heat.glaze_seconds(thickness, "solid"),
                          heat.glaze_seconds(thickness, C.heat.ground.draper))
  game.tick = math.ceil(record.hold + seconds * 60) + 600
  record.up, record.dn = record.lmax, record.lmax
  local ground = {}
  local surface = {name = "nauvis", valid = true}
  surface.get_tile = function(x, y)
    return {name = ground[x .. ":" .. y] or N.nauvis_tiles[N.tiles.lava]}
  end
  surface.is_chunk_generated = function() return true end
  surface.set_tiles = function(tiles)
    for _, tile in ipairs(tiles) do
      ground[tile.position[1] .. ":" .. tile.position[2]] = tile.name
    end
  end
  for slice = 0, C.blast.rings.paint.cool.slices - 1 do
    cool(surface, record, slice, C.blast.rings.paint.cool.tiles_per_tick)
  end
  assert(cooled(record, ladder(record.key)), "Cooling clock did not complete")
  assert(ground["0:0"] and not N.hot_tiles[ground["0:0"]], "Center remained hot after deadline")
end
print("PASS: owned prototypes, base-only fallback, grass allowlists, molten detection,")
print("      integer/fractional centers, surface variants, coverings, incomplete cooling")
print("      no terrain migration or schema bump")
print("      complete physical cooling deadlines across four yields")