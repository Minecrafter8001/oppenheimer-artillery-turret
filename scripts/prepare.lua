-- scripts/prepare.lua --------------------------------------------------------------
-- THE PREPARATION STAGE: the first CONFIRM of the firing sequence.
--
-- Designate -> CONFIRM (prepare) -> CONFIRM (fire). The first CONFIRM builds the
-- ground the blast will land on and surveys what is standing on it; the second
-- starts the charge. Not a lock: the second CONFIRM fires whether or not the
-- preparation has finished, and says how far it got.
--
-- WHY: everything the detonation damages is found with find_entities_filtered,
-- which returns nothing for a chunk that has not been generated. The strike
-- only force-generates a capped disc (C.blast.rings.pregen), because an
-- uncapped full-dial request in ONE tick ground UPS to ~5 FPS. This does the
-- whole disc instead, before the shot: a few chunks requested per tick with a
-- bounded queue outstanding, so the engine's own background generator absorbs
-- it without a spike. Payload lands all in one go on ground that exists.
--
-- HOW FAST is the player's own map setting (N.setting.prep_rate, read through
-- C.prepare.rate/pending). It was a fixed 3/tick with 24 outstanding, which on
-- a full-dial disc is minutes of waiting -- and the right number depends on
-- the machine, not on the weapon. Changing it applies to a preparation
-- already running.
--
-- A CIRCLE, WALKED FROM THE EPICENTRE OUT: square rings of chunks around the
-- epicentre chunk, skipping any whose centre is outside the blast radius.
-- Generating a chunk does not chart it -- the map is still revealed only by the
-- wave as it travels -- and the circle keeps the work (and the world it
-- creates) to what the blast actually covers.
--
-- THE SURVEY: once the disc exists, count what is in it -- nests, worms and
-- enemies inside the fireball ring (certain death) and inside the whole blast
-- (damaged, and lethal to most), plus anything of the firing force's own
-- inside the blast. A snapshot: biters move.
--
-- ONE DISC FOR THE BATTERY: the radius is the converged group's (schema.group)
-- and only its holder, the lowest unit_number, walks it.
--
-- TEST / LIVE (rec.fire_mode). TEST *is* this stage: CONFIRM prepares and
-- surveys, and that installation never fires while it is in TEST. LIVE fires
-- on the first CONFIRM and warns if the zone is not prepared -- the two-stage
-- confirm in LIVE made TEST pointless (it did the same job with an extra
-- press), which is exactly how it was reported.
--
-- State: rec.prep, ad-hoc on the turret record (nil = not prepared). Requires
-- config/names/events/schema only, so scripts/turret.lua can require it.
----------------------------------------------------------------------------------

local C      = require("config")
local events = require("scripts.events")
local schema = require("scripts.schema")
local profile = require("scripts.profile")
local audio = require("scripts.audio")

local prepare = {}

local P = C.prepare
local CHUNK = 32
local HALF_DIAG = 22.7   -- a chunk's centre to its corner, tiles

--- The (di, dj) of cell `idx` (0-based) on square ring k around the centre.
--- Ring k has 8k cells (ring 0 has one).
local function ring_cell(k, idx)
  if k == 0 then return 0, 0 end
  local side = 2 * k
  if idx < side then return -k + idx, -k end
  idx = idx - side
  if idx < side then return k, -k + idx end
  idx = idx - side
  if idx < side then return k - idx, k end
  idx = idx - side
  return -k, k - idx
end

local function ring_size(k) return k == 0 and 1 or 8 * k end

--- The blast radius in tiles the dial asks for, and a signature of the order
--- (aim point, dial, lances) the preparation is only valid for.
local function order_of(rec)
  local d = rec.designated
  if not d then return nil end
  local _, lances, _, order = schema.group(rec, d, rec.state)
  local sig = string.format("%d:%d:%d:%d", math.floor(d.x), math.floor(d.y),
                            math.floor(order * 1000), lances)
  return C.yield.radius_for_fraction(order), sig
end

--- The outermost ring a preparation for `radius` needs to walk, same margin
--- prepare.begin adds to the dial's own radius.
local function kmax_for(radius)
  return math.ceil((radius + P.margin_tiles + HALF_DIAG) / CHUNK) + 1
end

--- Does an order of this radius actually depend on PREPARE ZONE? Inside
--- C.blast.rings.generate_ahead_radius nothing is ever missed regardless: the
--- automatic pregen at CONFIRM/strike (C.blast.rings.pregen) and the wave's
--- own on-demand generation (generate_to in scripts/detonate.lua's
--- front.advance call) both already force that ground into existence on
--- every shot, prepared or not. Only ground past that radius is left to
--- scripts/scar.lua's later payout if nothing generates it first.
function prepare.needs_prep(radius)
  return radius > (C.blast.rings.generate_ahead_radius or 0)
end

--- The group member that holds the battery's preparation: its lowest unit_number.
local function holder(rec)
  local d = rec.designated
  if not d then return rec end
  local _, _, recs = schema.group(rec, d, rec.state)
  return recs[1] or rec
end

local function in_circle(p, ci, cj)
  local x = ci * CHUNK + 16 - p.x
  local y = cj * CHUNK + 16 - p.y
  return (x * x + y * y) <= p.reach2
end

--- Does the battery's preparation COVER the order it is holding now? Same
--- epicentre, prepared at least as far out as the order currently needs --
--- not an exact match against the sig it was begun with, so turning the dial
--- down or the battery losing a lance after preparing does not throw away
--- ground that is still fully covered by the bigger circle already prepared.
--- (A bigger order after preparing correctly fails this -- more lances or a
--- higher dial needs a wider circle than the one that exists.)
function prepare.matches(rec)
  local p = holder(rec).prep
  local d = rec.designated
  if not (p and d) then return false end
  local radius = order_of(rec)
  return radius ~= nil
         and math.floor(p.x) == math.floor(d.x)
         and math.floor(p.y) == math.floor(d.y)
         and p.radius >= radius
end

--- Start (or restart) preparing the current order, on the group's holder.
--- @return boolean started  false when another member already has this order
function prepare.begin(rec)
  local d = rec.designated
  if not d then return false end
  rec = holder(rec)
  local e = rec.entity
  if not (e and e.valid and rec.designated) then return false end
  local radius, sig = order_of(rec)
  -- Covers, not just an exact sig match -- a dial turned down onto ground
  -- already prepared at a bigger radius should not throw that progress away.
  if rec.prep and prepare.matches(rec) then return false end

  local reach = radius + P.margin_tiles + HALF_DIAG
  local cx, cy = math.floor(d.x / CHUNK), math.floor(d.y / CHUNK)
  local kmax = kmax_for(radius)

  local p = {
    x = d.x, y = d.y, radius = radius, sig = sig,
    reach2 = reach * reach,
    cx = cx, cy = cy, kmax = kmax,
    rk = 0, ri = 0,   -- request cursor
    vk = 0, vi = 0,   -- verify cursor
    requested = 0, verified = 0, total = 0,
    started = game.tick,
  }
  -- Count once (a square scan of chunk centres, a few thousand at full dial).
  for dj = -kmax, kmax do
    for di = -kmax, kmax do
      if in_circle(p, cx + di, cy + dj) then p.total = p.total + 1 end
    end
  end
  rec.prep = p
  return true
end

--- Walk a cursor to the next cell INSIDE the circle. Returns ci, cj, or nil
--- when the walk is past the last ring. `budget` bounds cells examined.
local function next_cell(p, kf, if_, budget)
  while budget > 0 do
    local k, i = p[kf], p[if_]
    if k > p.kmax then return nil end
    if i >= ring_size(k) then
      p[kf], p[if_] = k + 1, 0
    else
      local di, dj = ring_cell(k, i)
      local ci, cj = p.cx + di, p.cy + dj
      if in_circle(p, ci, cj) then return ci, cj end
      p[if_] = i + 1
    end
    budget = budget - 1
  end
  return false
end

local function count(surface, p, r, filter)
  filter.position = {p.x, p.y}
  filter.radius = r
  return surface.count_entities_filtered(filter)
end

local CATEGORIES = {
  {key = "nests", types = {"unit-spawner"}},
  {key = "worms", types = {"turret"}},
  {key = "units", types = {"unit", "spider-unit", "segmented-unit"},
   parts = {"segment"}},
}

--- Every force this one is hostile to; "enemy" if it is at peace with all.
local function hostile_forces(force)
  local out = {}
  for _, f in pairs(game.forces) do
    if f ~= force and force.is_enemy(f) then out[#out + 1] = f.name end
  end
  if #out == 0 then out[1] = "enemy" end
  return out
end

-- MapGenSize reads back as a number, or a preset name in some saves.
local function gen_size(v)
  if type(v) == "number" then return v end
  return v == "none" and 0 or 1
end

local function enabled_setting(s)
  return s ~= nil and gen_size(s.size) > 0 and gen_size(s.frequency) > 0
end

--- The enemies this surface's map generator places: every autoplaced spawner,
--- every autoplaced worm, and every unit those spawners (or territories) field.
local function native_roster(surface)
  local mgs = surface.map_gen_settings or {}
  local ent = mgs.autoplace_settings and mgs.autoplace_settings.entity
  local listed = ent and ent.settings or {}
  local by_default = not ent or ent.treat_missing_as_default ~= false
  local controls = mgs.autoplace_controls or {}

  local function placed(proto)
    if listed[proto.name] then return enabled_setting(listed[proto.name]) end
    if not by_default then return false end
    local spec = proto.autoplace_specification
    return spec ~= nil and spec.control ~= nil and enabled_setting(controls[spec.control])
  end

  local roster = {nests = {}, worms = {}, units = {}}
  local seen = {}
  local function add(list, name)
    if name and not seen[name] and prototypes.entity[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end

  for name, proto in pairs(prototypes.get_entity_filtered{{filter = "type", type = "unit-spawner"}}) do
    if placed(proto) then
      add(roster.nests, name)
      for _, u in ipairs(proto.result_units or {}) do add(roster.units, u.unit) end
    end
  end
  for name, proto in pairs(prototypes.get_entity_filtered{{filter = "type", type = "turret"}}) do
    if placed(proto) then add(roster.worms, name) end
  end
  local territory = mgs.territory_settings
  for _, u in ipairs(territory and territory.units or {}) do
    add(roster.units, type(u) == "string" and u or u.name)
  end
  return roster
end

--- The segmented unit a segment belongs to, as key and name, or nil.
local function owner_of(part)
  local su = part.segmented_unit
  if su and su.valid then return su.unit_number, su.prototype.name end
  return nil
end

--- One category's hostiles in the blast, by name: natives in roster order, then
--- intruders by name. A native category with nothing standing keeps its first
--- icon at zero, so the line still says what this surface fields.
--- A segment stands for its whole unit: ignored when that unit is already
--- counted, otherwise the unit is counted once in its place.
local function tally(s, p, hostiles, cat, lethal2, native)
  local by, seen = {}, {}
  local function count_one(name, key, q)
    if key then
      if seen[key] then return end
      seen[key] = true
    end
    local t = by[name]
    if not t then t = {name = name, l = 0, b = 0}; by[name] = t end
    t.b = t.b + 1
    if q then
      local dx, dy = q.x - p.x, q.y - p.y
      if dx * dx + dy * dy <= lethal2 then t.l = t.l + 1 end
    end
  end

  local filter = {position = {p.x, p.y}, radius = p.radius, force = hostiles, type = cat.types}
  for _, v in pairs(s.find_entities_filtered(filter)) do
    if v.type == "segmented-unit" then
      local su = v.segmented_unit
      if su and su.valid then
        count_one(su.prototype.name, su.unit_number, v.position)
      else
        count_one(v.name, v.unit_number, v.position)
      end
    else
      count_one(v.name, v.unit_number, v.position)
    end
  end

  if cat.parts then
    filter.type = cat.parts
    for _, part in pairs(s.find_entities_filtered(filter)) do
      local key, name = owner_of(part)
      -- Its body stands outside the blast, so it is never inside the kill radius.
      if key and not seen[key] then count_one(name, key, nil) end
    end
  end

  local out, done = {}, {}
  for _, name in ipairs(native) do
    if by[name] then out[#out + 1] = by[name]; done[name] = true end
  end
  local extra = {}
  for name, t in pairs(by) do
    if not done[name] then extra[#extra + 1] = t end
  end
  table.sort(extra, function(a, b) return a.name < b.name end)
  for _, t in ipairs(extra) do out[#out + 1] = t end
  if #out == 0 and native[1] then out[1] = {name = native[1], l = 0, b = 0} end
  return out
end

--- What the shot will do, counted on the ground that now exists.
local function survey(rec, p)
  local e = rec.entity
  local s = e.surface
  local lethal = p.radius * C.blast.rings.fireball_u
  local hostiles = hostile_forces(e.force)
  local roster = native_roster(s)
  local sv = {lethal_r = lethal, own = count(s, p, p.radius, {force = e.force})}
  for _, cat in ipairs(CATEGORIES) do
    sv[cat.key] = tally(s, p, hostiles, cat, lethal * lethal, roster[cat.key])
  end
  p.survey = sv
end

--- One tick of one preparation.
local function step(rec)
  local p = rec.prep
  if not p or p.done then return end
  local e = rec.entity
  local surface = e.surface

  -- VERIFY: advance past every chunk that now exists.
  local checks = P.verify_per_tick
  while checks > 0 do
    local ci, cj = next_cell(p, "vk", "vi", P.scan_per_tick)
    if ci == nil then
      p.done = true
      p.done_tick = game.tick
      survey(rec, p)
      local e = rec.entity
      if e and e.valid then
        audio.notify(e.force, prepare.survey_line("prepare-done", p))
      end
      return
    end
    if ci == false then break end
    if not surface.is_chunk_generated({ci, cj}) then break end
    p.verified = p.verified + 1
    p.vi = p.vi + 1
    checks = checks - 1
  end

  -- REQUEST: never more than `pending` ahead of what exists. Both numbers come
  -- from the player's map setting (C.prepare.rate), read per tick so turning
  -- the dial up in a running save takes effect on the next tick of a
  -- preparation already under way.
  local asks = C.prepare.rate()
  local pending = C.prepare.pending()
  while asks > 0 and (p.requested - p.verified) < pending do
    -- The request cursor never trails the verify cursor.
    if p.rk < p.vk or (p.rk == p.vk and p.ri < p.vi) then
      p.rk, p.ri = p.vk, p.vi
      p.requested = math.max(p.requested, p.verified)
    end
    local ci, cj = next_cell(p, "rk", "ri", P.scan_per_tick)
    if not ci then break end
    if not surface.is_chunk_generated({ci, cj}) then
      -- Radius 0: that one chunk (2.0.77 spec).
      surface.request_to_generate_chunks({ci * CHUNK + 16, cj * CHUNK + 16}, 0)
      asks = asks - 1
    end
    p.requested = p.requested + 1
    p.ri = p.ri + 1
  end
end

-- Surveys saved before 0.51.1 hold one total per category and no names.
local LEGACY_ICONS = {nests = "biter-spawner", worms = "medium-worm-turret", units = "medium-biter"}

local function lists_of(sv)
  if sv.nests then return sv end
  local out = {}
  for _, cat in ipairs(CATEGORIES) do
    local k = cat.key
    out[k] = {{name = LEGACY_ICONS[k], l = sv["l_" .. k] or 0, b = sv["b_" .. k] or 0}}
  end
  return out
end

-- A plain string, not a LocalisedString: a long roster can outgrow the 20-parameter limit.
local function segment(lists, field)
  local cats = {}
  for _, cat in ipairs(CATEGORIES) do
    local parts = {}
    for _, t in ipairs(lists[cat.key]) do
      if prototypes.entity[t.name] then
        parts[#parts + 1] = "[entity=" .. t.name .. "]" .. t[field]
      end
    end
    if #parts > 0 then cats[#cats + 1] = table.concat(parts, " ") end
  end
  return table.concat(cats, "   ")
end

--- The finished survey as a LocalisedString, for the panel and for chat.
--- An empty zone takes the `<key>-clear` variant.
function prepare.survey_line(key, p)
  local sv = p.survey
  local lists = lists_of(sv)
  local blast = tostring(math.floor(p.radius + 0.5))
  local total = sv.own
  for _, cat in ipairs(CATEGORIES) do
    for _, t in ipairs(lists[cat.key]) do total = total + t.b end
  end
  if total == 0 then
    return {"oppenheimer." .. key .. "-clear", blast}
  end
  return {"oppenheimer." .. key,
          tostring(math.floor(sv.lethal_r + 0.5)), segment(lists, "l"),
          blast, segment(lists, "b"),
          tostring(sv.own)}
end

--- The HUD's preparation line for this installation, or "" when there is
--- nothing to say. `aiming` is passed in (turret.AIM), same no-cycle reason
--- as render.preview.
--
-- THE UNPREPARED LINE DEPENDS ON THE MODE, because it means two different
-- things: in TEST it is an instruction (press PREPARE ZONE), in LIVE it is a
-- warning (fire now and anything on ungenerated ground is missed). Saying
-- "CONFIRM to generate and survey it" in LIVE, where CONFIRM fires, was the
-- panel telling the player the opposite of what the button does.
function prepare.caption(rec, aiming)
  if not aiming then return "" end
  local p = holder(rec).prep
  if not p then
    if rec.fire_mode == "test" then return {"oppenheimer.fc-prep-test"} end
    -- LIVE's line is a warning, not an instruction -- nothing to warn about
    -- when this order's own radius does not depend on PREPARE ZONE at all.
    local radius = order_of(rec)
    if radius and not prepare.needs_prep(radius) then return "" end
    return {"oppenheimer.fc-prep-live"}
  end
  if not prepare.matches(rec) then return {"oppenheimer.fc-prep-stale"} end
  if not p.done then
    local pct = p.total > 0 and math.floor(p.verified / p.total * 100) or 100
    return {"oppenheimer.fc-prep-running", tostring(pct),
            tostring(p.verified), tostring(p.total)}
  end
  return prepare.survey_line("fc-prep-ready", p)
end

--- Percent generated, for the fire-time status message.
function prepare.percent(rec)
  local p = holder(rec).prep
  if not p then return 0 end
  if p.done or p.total <= 0 then return 100 end
  return math.floor(p.verified / p.total * 100)
end

--- Percent generated FOR THE ORDER THIS INSTALLATION IS HOLDING: zero unless
--- the preparation covers the current aim and radius (prepare.matches). What
--- the fire path and the HUD both ask -- a preparation for a different target
--- is not cover for this one, and reading the stale one's percent would
--- report ground that was built somewhere else.
--
-- READS 100 THE MOMENT THE NEEDED RINGS ARE DONE, not whenever the matching
-- prep's own (possibly bigger) circle finishes: next_cell walks centre-out,
-- so the verify cursor past the ring this order's radius needs means every
-- chunk inside it already came back generated, whatever is still pending
-- further out.
function prepare.ready_percent(rec)
  local radius = order_of(rec)
  -- Nothing to prepare: the automatic pregen and the wave's own on-demand
  -- generation already cover this order regardless of PREPARE ZONE.
  if radius and not prepare.needs_prep(radius) then return 100 end
  if not prepare.matches(rec) then return 0 end
  local p = holder(rec).prep
  if p.done then return 100 end
  if radius and p.vk > kmax_for(radius) then return 100 end
  return prepare.percent(rec)
end

events.on_nth_tick(1, function()
  for _, rec in pairs(storage.turrets or {}) do
    if rec.prep and not rec.prep.done and schema.valid(rec) then
      profile.start("prepare/generation cursor + survey")
      step(rec)
      profile.stop("prepare/generation cursor + survey")
    end
  end
end)

return prepare
