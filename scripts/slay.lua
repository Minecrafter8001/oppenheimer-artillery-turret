-- scripts/slay.lua: blast hits on creatures. A lethal hit nobody watches is a
-- hand-credited kill and a silent removal with no body; anything else is damage().
-- CALLERS MUST slay.flush() BEFORE THEIR TICK ENDS: kill counts are scratch, and a
-- save between ticks would drop them on one machine and not another.

local C       = require("config")
local profile = require("scripts.profile")
local view    = require("scripts.view")

local slay = {}

local SLAYABLE = {unit = true, ["spider-unit"] = true, ["segmented-unit"] = true}

-- Resistances by prototype name, cached; false = none.
local RES = {}

-- SCRATCH: [surface_index][killer][victim force][prototype name] = count
local KILLS = {}
local PENDING = false

--- Is (x, y) on surface `si` within watch_radius of anyone's view?
function slay.watched(si, x, y)
  return view.near(si, x, y, C.blast.slay.watch_radius)
end

--- Damage left after the engine's resistance formula: flat decrease, then percent.
local function after_resistance(name, amount, dtype)
  local res = RES[name]
  if res == nil then
    local p = prototypes.entity[name]
    res = (p and p.resistances) or false
    RES[name] = res
  end
  local r = res and res[dtype]
  if not r then return amount end
  local flat = r.decrease or 0
  local a
  if flat < amount then a = amount - flat else a = 1 / (2 + flat - amount) end
  return a * (1 - (r.percent or 0))
end

local function force_name(force)
  if type(force) == "string" then return force end
  return (force and force.valid and force.name) or C.blast.rings.default_force
end

--- Credit a kill by hand and remove the victim with no death and no body.
function slay.vanish(v, force)
  local si = v.surface_index
  local by_s = KILLS[si]
  if not by_s then by_s = {}; KILLS[si] = by_s end
  local kname = force_name(force)
  local by_k = by_s[kname]
  if not by_k then by_k = {}; by_s[kname] = by_k end
  local vname = v.force.name
  local names = by_k[vname]
  if not names then names = {}; by_k[vname] = names end
  local pname = v.name
  names[pname] = (names[pname] or 0) + 1
  PENDING = true
  v.destroy{raise_destroy = true}
end

--- One blast hit. Same arguments as LuaEntity.damage.
-- @return boolean true when slay destroyed the victim instead of damaging it
function slay.hit(v, amount, force, dtype, source, cause)
  local sc = C.blast.slay
  if sc.enabled and SLAYABLE[v.type] then
    local hp = v.health
    if hp and after_resistance(v.name, amount, dtype or "impact") >= hp then
      local p = v.position
      if slay.watched(v.surface_index, p.x, p.y) then
        profile.count("slay/lethal, watched (real death)")
      else
        profile.count("slay/lethal, unwatched (slain)")
        slay.vanish(v, force)
        return true
      end
    end
  end
  v.damage(amount, force, dtype, source, cause)
  return false
end

--- Push this tick's hand-credited kills into the engine's kill statistics.
function slay.flush()
  if not PENDING then return end
  PENDING = false
  for si, by_s in pairs(KILLS) do
    local surface = game.get_surface(si)
    for killer, victims in pairs(by_s) do
      local kf = game.forces[killer]
      for victim, names in pairs(victims) do
        local vf = game.forces[victim]
        local ks = surface and kf and kf.get_kill_count_statistics(surface)
        local vs = surface and vf and vf.get_kill_count_statistics(surface)
        for name, n in pairs(names) do
          if ks then ks.on_flow(name, n) end
          if vs then vs.on_flow(name, -n) end
        end
      end
    end
    KILLS[si] = nil
  end
end

return slay
