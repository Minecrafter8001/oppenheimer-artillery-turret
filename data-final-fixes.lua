-- data-final-fixes: mark enemy particles only-when-visible.

local C = require("config")

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
