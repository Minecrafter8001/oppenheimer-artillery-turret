-- scripts/lance.lua ----------------------------------------------------------------
-- The lance as a chain of beam spans that exist only where a player can see them.
-- Mid slot k covers [(k-1)S, kS] along the muzzle-to-tip line and the tip span covers
-- [nS, len]. A span is built when it comes within view (scripts/view.lua) and dropped
-- once it leaves; builds, heat-step rebuilds and drops draw on per-tick budgets shared
-- by every chain (C.beam.spans).
----------------------------------------------------------------------------------

local C       = require("config")
local N       = require("lib.names")
local blib    = require("lib.beam")
local profile = require("scripts.profile")
local view    = require("scripts.view")

local B  = C.beam
local SP = B.spans

local lance = {}

-- Whether LuaEntity.set_beam_source/set_beam_target work; nil = untried. A failure
-- is a fact about the engine build, identical on every client, so it is latched.
local POINT_OK = nil

-- SCRATCH: what is left of this tick's budgets, reset on the first call of a tick.
local BUDGET_TICK = -1
local LEFT = {create = 0, recolour = 0, cull = 0}

local function take(kind)
  local t = game.tick
  if BUDGET_TICK ~= t then
    BUDGET_TICK = t
    LEFT.create   = SP.create_per_tick
    LEFT.recolour = SP.recolour_per_tick
    LEFT.cull     = SP.cull_per_tick
  end
  if LEFT[kind] < 1 then return false end
  LEFT[kind] = LEFT[kind] - 1
  return true
end

local function pt(chain, d)
  return {x = chain.from.x + chain.ux * d, y = chain.from.y + chain.uy * d}
end

local function set_pair(core, halo, a, b)
  core.set_beam_source(a)
  core.set_beam_target(b)
  if halo and halo.valid then
    halo.set_beam_source(a)
    halo.set_beam_target(b)
  end
end

local function set_tip(core, halo, b)
  core.set_beam_target(b)
  if halo and halo.valid then halo.set_beam_target(b) end
end

local function kill(sp)
  if not sp then return end
  if sp.halo and sp.halo.valid then sp.halo.destroy() end
  if sp.core and sp.core.valid then sp.core.destroy() end
end

--- Move a span's endpoints (`a` nil moves the tip only). False once its core is gone.
local function point(sp, a, b)
  if not (sp.core and sp.core.valid) then return false end
  if POINT_OK == false then return true end
  local ok
  if a then
    ok = pcall(set_pair, sp.core, sp.halo, a, b)
  else
    ok = pcall(set_tip, sp.core, sp.halo, b)
  end
  if not ok then POINT_OK = false elseif POINT_OK == nil then POINT_OK = true end
  return true
end

--- Halo layer scale at this yield.
local function halo_scale(variant)
  return C.beam_scale(B.halo.scale_mult) * C.beam_size(variant)
end

--- Shortest tip span in tiles: room for the end cap's head, body and tail segments.
local function min_span(variant)
  return SP.min_span_segments * blib.segment_length(halo_scale(variant))
end

--- Mid slots on a line `len` tiles long: as many as leave the tip span at least min_span.
local function slots(chain, len)
  if not SP.enabled or len < chain.min_span + chain.S then return 0 end
  return math.floor((len - chain.min_span) / chain.S)
end

--- One span: a halo and a core over [a, b] tiles along the chain, at the chain's heat
--- step. Nil if the core failed.
local function make(chain, surface, kind, a, b, remaining)
  -- Only the `end` family is built when spans are off; a `-m` name would not exist.
  if not SP.enabled then kind = "end" end
  local p, q = pt(chain, a), pt(chain, b)
  local hstep = chain.hstep
  local function one(layer)
    return surface.create_entity{
      name            = N.lance(layer, chain.variant, hstep, kind),
      position        = p,
      source_position = p,
      target_position = q,
      duration        = remaining,
      max_length      = chain.max_len,
      force           = chain.force,
    }
  end
  -- Halo first, so the hot core composites on top of it.
  local halo = one("halo")
  local core = one("core")
  if not core then
    if halo and halo.valid then halo.destroy() end
    return nil
  end
  return {core = core, halo = halo, hstep = hstep, kind = kind}
end

--- The stretches of the chain's line, in tiles from its origin, within `r` of a
--- world-view player: a flat {t0, t1, ...}, true with culling off, nil for none.
local function seen(chain, r)
  if not C.perf.view.enabled then return true end
  local w = view.watchers()
  local out
  local fx, fy, ux, uy = chain.from.x, chain.from.y, chain.ux, chain.uy
  local r2 = r * r
  for i = 1, #w, 3 do
    if w[i] == chain.surface then
      local dx, dy = w[i + 1] - fx, w[i + 2] - fy
      local t = dx * ux + dy * uy
      local d2 = dx * dx + dy * dy - t * t
      if d2 < r2 then
        local h = math.sqrt(r2 - d2)
        out = out or {}
        out[#out + 1] = t - h
        out[#out + 1] = t + h
      end
    end
  end
  return out
end

local function meets(iv, a, b)
  if iv == true then return true end
  if not iv then return false end
  for i = 1, #iv, 2 do
    if iv[i] <= b and iv[i + 1] >= a then return true end
  end
  return false
end

--- Open a chain along from -> to. Spans are built by lance.build as they come into view.
-- @param force LuaForce
function lance.open(surface, force, from, to, variant, hstep, remaining, max_len)
  local dx, dy = to.x - from.x, to.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  local ux, uy = 1, 0
  if len > 1e-6 then ux, uy = dx / len, dy / len end

  local chain = {
    surface = surface.index, force = force.name, variant = variant,
    from = {x = from.x, y = from.y}, ux = ux, uy = uy, len = len,
    S = SP.length, min_span = min_span(variant), mids = {}, n = 0,
    max_len = max_len, hstep = hstep,
  }
  chain.n = slots(chain, len)
  chain.cap_a = chain.n * chain.S
  lance.build(chain, remaining)
  return chain
end

--- A lance record from a save that predates chains becomes a chain whose tip span is
--- the old beam pair.
function lance.adopt(L)
  local core = L.core
  if not (core and core.valid) then return nil end
  local from, to = L.from, L.to
  local dx, dy = to.x - from.x, to.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  local ux, uy = 1, 0
  if len > 1e-6 then ux, uy = dx / len, dy / len end
  return {
    surface = core.surface.index, force = core.force.name, variant = L.variant,
    from = {x = from.x, y = from.y}, ux = ux, uy = uy, len = L.beam_len or len,
    S = SP.length, min_span = min_span(L.variant), mids = {}, n = 0, cap_a = 0,
    cap = {core = core, halo = L.halo, hstep = L.hstep, kind = "end"},
    max_len = L.max_len, hstep = L.hstep,
  }
end

--- One tick of upkeep, each on the shared budget: build the nearest-the-muzzle span a
--- player can see that is missing, rebuild one visible span behind the heat step, and
--- drop one span nobody can see.
function lance.build(chain, remaining)
  if remaining < 2 then return end
  local surface = game.get_surface(chain.surface)
  if not (surface and surface.valid) then return end

  local scale = halo_scale(chain.variant)
  local r = C.perf.view.radius + blib.body_thickness(scale) / 2
  local near = seen(chain, r)
  local keep = seen(chain, r + SP.keep_margin)
  local reach = blib.end_length(scale) / 2

  local S, n, len, hstep = chain.S, chain.n, chain.len, chain.hstep
  local miss, stale, drop
  local live = 0
  for k = 1, n + 1 do
    local sp, a, b
    if k <= n then
      sp, a, b = chain.mids[k], (k - 1) * S, k * S
    else
      sp, a, b = chain.cap, n * S, len + reach
    end
    if sp and not (sp.core and sp.core.valid) then
      kill(sp)
      if k <= n then chain.mids[k] = nil else chain.cap = nil end
      sp = nil
    end
    if sp then
      live = live + 1
      if meets(near, a, b) then
        if not stale and sp.hstep ~= hstep then stale = k end
      elseif not drop and not meets(keep, a, b) then
        drop = k
      end
    elseif not miss and meets(near, a, b) then
      miss = k
    end
  end
  profile.count("spans/live", live)

  local function bounds(k)
    if k <= n then return (k - 1) * S, k * S end
    return n * S, len
  end

  if miss and (chain.retry_at or 0) <= game.tick and take("create") then
    profile.start("spans/create")
    local a, b = bounds(miss)
    local sp = make(chain, surface, miss <= n and "mid" or "end", a, b, remaining)
    profile.stop("spans/create")
    if sp then
      if miss <= n then chain.mids[miss] = sp else chain.cap = sp end
      profile.count("spans/created")
    else
      chain.retry_at = game.tick + 60
    end
  end

  if stale and take("recolour") then
    profile.start("spans/recolour")
    local sp = (stale <= n) and chain.mids[stale] or chain.cap
    local a, b = bounds(stale)
    local new = make(chain, surface, sp.kind, a, b, remaining)
    if new then
      kill(sp)
      sp.core, sp.halo, sp.hstep = new.core, new.halo, new.hstep
      profile.count("spans/replaced")
    end
    profile.stop("spans/recolour")
  end

  if drop and take("cull") then
    profile.start("spans/destroy")
    if drop <= n then
      kill(chain.mids[drop])
      chain.mids[drop] = nil
    else
      kill(chain.cap)
      chain.cap = nil
    end
    profile.stop("spans/destroy")
    profile.count("spans/culled")
  end
end

--- Follow the tip. `from` is fixed for the main lance and moves with the bearing
--- for the arc sweep; built mids are re-pointed only when the line itself moved.
function lance.aim(chain, from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return end
  local ux, uy = dx / len, dy / len

  local moved = math.abs(from.x - chain.from.x) > 1e-6 or math.abs(from.y - chain.from.y) > 1e-6
             or math.abs(ux - chain.ux) > 1e-6 or math.abs(uy - chain.uy) > 1e-6
  if moved then
    chain.from = {x = from.x, y = from.y}
    chain.ux, chain.uy = ux, uy
  end
  chain.len = len

  local n = slots(chain, len)
  for k = n + 1, chain.n do
    kill(chain.mids[k])
    chain.mids[k] = nil
  end
  chain.n = n

  local S = chain.S
  if moved then
    for k = 1, n do
      local sp = chain.mids[k]
      if sp and not point(sp, pt(chain, (k - 1) * S), pt(chain, k * S)) then
        kill(sp)
        chain.mids[k] = nil
      end
    end
  end
  local a = n * S
  local cap = chain.cap
  if cap then
    local tip = pt(chain, len)
    local ok
    if moved or chain.cap_a ~= a then
      ok = point(cap, pt(chain, a), tip)
    else
      ok = point(cap, nil, tip)
    end
    if not ok then
      kill(cap)
      chain.cap = nil
    end
  end
  chain.cap_a = a
end

--- One tick of a live chain.
-- @param follow boolean  move the tip to `aim`; false holds the length it was opened at
function lance.step(chain, from, aim, hstep, remaining, follow)
  if remaining < 2 then return end
  chain.hstep = hstep
  if follow then lance.aim(chain, from, aim) end
  lance.build(chain, remaining)
end

function lance.destroy(chain)
  if not chain then return end
  profile.start("spans/destroy")
  for _, sp in pairs(chain.mids) do kill(sp) end
  kill(chain.cap)
  chain.mids, chain.n, chain.cap = {}, 0, nil
  profile.stop("spans/destroy")
end

return lance
