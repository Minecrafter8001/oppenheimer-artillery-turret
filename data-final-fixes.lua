-- data-final-fixes: mark enemy particles only-when-visible.

local C = require("config")
local N = require("lib.names")

local grass_tiles = {}
for owned, nauvis in pairs(N.nauvis_tiles) do
  if not N.hot_tiles[owned] and data.raw.tile[nauvis] then
    grass_tiles[#grass_tiles + 1] = nauvis
  end
end
table.sort(grass_tiles)

if mods["zen-garden"] or mods["early-agriculture"] then
  for _, item in pairs(data.raw.item or {}) do
    local placement = item.place_as_tile
    local result = placement and placement.result
    if placement and result and (result == "artificial-grass" or result == "artificial-grass-2"
                   or result == "artificial-grass-3") and placement.tile_condition then
      local accepted = {}
      for _, name in ipairs(placement.tile_condition) do accepted[name] = true end
      for _, name in ipairs(grass_tiles) do
        if not accepted[name] then
          placement.tile_condition[#placement.tile_condition + 1] = name
        end
      end
    end
  end
end

local variants = {}
for name, source in pairs(N.tile_sources) do
  if data.raw.tile[name] then
    variants[source] = variants[source] or {}
    variants[source][#variants[source] + 1] = name
  end
end
for _, names in pairs(variants) do table.sort(names) end

local function extend_targets(targets)
  if not targets then return end
  local seen = {}
  for _, name in ipairs(targets) do seen[name] = true end
  local count = #targets
  for index = 1, count do
    for _, name in ipairs(variants[targets[index]] or {}) do
      if not seen[name] then
        targets[#targets + 1] = name
        seen[name] = true
      end
    end
  end
end

for _, tile in pairs(data.raw.tile) do
  extend_targets(tile.allowed_neighbors)
  for _, transition in ipairs(tile.transitions or {}) do
    extend_targets(transition.to_tiles)
  end
end

if C.perf and C.perf.enemy_particles_only_when_visible then
  local ENEMY_TYPES = {"unit", "unit-spawner", "turret", "spider-unit", "segmented-unit"}

  local seen = {}
  local explosion

  local function mark(t)
    if type(t) ~= "table" or seen[t] then return end
    seen[t] = true
    if t.type == "create-particle" then
      t.only_when_visible = true
    elseif t.type == "create-entity" and type(t.entity_name) == "string"
           and data.raw.explosion and data.raw.explosion[t.entity_name] then
      t.only_when_visible = true
      explosion(t.entity_name)
    end
    for _, v in pairs(t) do
      if type(v) == "table" then mark(v) end
    end
  end

  -- ExplosionDefinition: a name, {name = ...}, or an array of either.
  function explosion(def)
    if type(def) == "string" then
      local ex = data.raw.explosion and data.raw.explosion[def]
      if ex then mark(ex.created_effect) end
    elseif type(def) == "table" then
      if def.name then
        explosion(def.name)
      else
        for _, d in ipairs(def) do explosion(d) end
      end
    end
  end

  for _, ty in ipairs(ENEMY_TYPES) do
    for _, p in pairs(data.raw[ty] or {}) do
      if ty ~= "turret" or p.autoplace then
        mark(p.dying_trigger_effect)
        mark(p.damaged_trigger_effect)
        explosion(p.dying_explosion)
      end
    end
  end
end
