-- scripts/front.lua ---------------------------------------------------------------
-- A RADIUS SWEEPING ACROSS THE GROUND, AND EVERYTHING IT PASSES: the fire wave
-- (outward), the collapsing shell (inward) and the shock front (outward), priced
-- on the annulus the front crosses.
--   ACQUIRE  each chunk searched exactly once, when the front comes within `lead`.
--   BIN      each thing found goes into a distance bucket a few tiles wide.
--   PAY      each tick, buckets the front has passed are paid out under a budget;
--            a victim that walked ahead of the front is re-binned first.
-- A thing is kept only if its POSITION lies in the searched chunk run, so none is
-- taken twice. MOVERS (opts.movers) are never in the one-time search: a trailing
-- band finds them (sweep_movers). Storage holds entity handles, never functions.
----------------------------------------------------------------------------------

local profile = require("scripts.profile")

local front = {}

local CHUNK = 32
-- A chunk's diagonal, rounded up. Added to every acquisition lead so a chunk is
-- always searched before the front reaches its FARTHEST corner, not just its
-- nearest one.
local DIAG = 46
-- Tiles a chart box stops short of its far chunk lines, so it never reaches a neighbour.
local EDGE = 1

--- Columns [lo, hi] of cell row with vertical gap dy whose nearest point lies
--- within radius r of x = cx. nil when the row is out of reach.
local function span(cx, dy, r, size)
  local o2 = r * r - dy * dy
  if o2 <= 0 then return nil end
  local w = math.sqrt(o2)
  return math.floor((cx - w) / size), math.floor((cx + w) / size)
end

--- Every chunk (or square cell of `size` tiles) whose nearest point to (cx, cy)
--- is within rb but not within ra, reported as contiguous runs:
--- fn(row, col_lo, col_hi).
--
-- ra < rb. Call it with the previous radius and the new one and it hands back
-- exactly the chunks that just came into reach -- outward (ra = old, rb = new) or
-- inward (ra = new, rb = old), the set difference is the same shape.
function front.each_ring_run(cx, cy, ra, rb, fn, size)
  if rb <= ra or rb <= 0 then return end
  if ra < 0 then ra = 0 end
  size = size or CHUNK
  local j0 = math.floor((cy - rb) / size)
  local j1 = math.floor((cy + rb) / size)
  for j = j0, j1 do
    local y0 = j * size
    local dy = 0
    if cy < y0 then dy = y0 - cy elseif cy > y0 + size then dy = cy - (y0 + size) end
    local lo1, hi1 = span(cx, dy, rb, size)
    if lo1 then
      local lo0, hi0 = span(cx, dy, ra, size)
      if not lo0 then
        fn(j, lo1, hi1)
      else
        if lo1 <= lo0 - 1 then fn(j, lo1, lo0 - 1) end
        if hi0 + 1 <= hi1 then fn(j, hi0 + 1, hi1) end
      end
    end
  end
end

--- The chart box for chunk columns i0..i1 of chunk row j.
function front.chunk_box(i0, i1, j)
  return {{i0 * CHUNK, j * CHUNK}, {(i1 + 1) * CHUNK - EDGE, (j + 1) * CHUNK - EDGE}}
end

--- Chart for `force` every GENERATED chunk whose nearest point is within rb but
--- not within ra, one force.chart per contiguous run; `fresh` skips chunks already
--- charted. Returns chunks charted.
-- MUST NOT chart an ungenerated chunk: force.chart generates it, and a request
-- waiting on the generator delays every chart request made after it.
function front.chart_runs(force, surface, cx, cy, ra, rb, fresh)
  local n = 0
  local cp = {0, 0}
  front.each_ring_run(cx, cy, ra, rb, function(j, i0, i1)
    cp[2] = j
    local run0
    for i = i0, i1 + 1 do
      local ok = false
      if i <= i1 then
        cp[1] = i
        ok = surface.is_chunk_generated(cp) and not (fresh and force.is_chunk_charted(surface, cp))
      end
      if ok then
        run0 = run0 or i
      elseif run0 then
        force.chart(surface, front.chunk_box(run0, i - 1, j))
        n = n + i - run0
        run0 = nil
      end
    end
  end)
  return n
end

--- A new front.
-- @param o table {x, y, r_max, dir = 1 (outward) | -1 (inward), bucket = tiles,
--                 movers = bool -- find movers by band (opts.movers must then
--                 be passed to every advance)}
function front.new(o)
  local dir = (o.dir == -1) and -1 or 1
  local bw  = o.bucket or 4
  return {
    -- Mover band state. nil on a front built without it, and on every front
    -- saved before 0.41.0 -- those keep searching movers once, as they began.
    mv = o.movers and true or nil,
    mq = o.movers and {} or nil,   -- reached movers awaiting payout
    -- Parallel to mq: the band radius BEFORE the pass that queued each entry, i.e.
    -- a radius inside which nothing of that pass's is closer. What paid_radius
    -- reads. nil-safe on a front saved without it (see paid_radius).
    mqr = o.movers and {} or nil,
    mqi = 1,
    mseen = o.movers and {} or nil, -- unit_number -> true once queued: one hit per front
    mpaid = 0,
    cx = o.x, cy = o.y,
    r_max = o.r_max,
    dir = dir,
    bw = bw,
    -- Radius the acquisition has reached. Outward it grows from 0; inward it
    -- shrinks from just past the start radius.
    acq = (dir > 0) and 0 or (o.r_max + 1),
    b = {},
    -- The bucket the payout is standing in. Outward it climbs from 0; inward it
    -- descends from the outermost bucket.
    next_i = (dir > 0) and 0 or math.floor(o.r_max / bw),
    cursor = 1,
    -- Telemetry: searches run, things returned, things kept, things paid.
    runs = 0, found = 0, binned = 0, paid = 0,
  }
end

--- Put one entity in the bucket for distance d. Never behind the payout cursor:
--- something acquired late, or found to have walked into ground the front has
--- already crossed, is paid on the next pass instead of never.
local function place(f, e, d)
  local idx = math.floor(d / f.bw)
  if f.dir > 0 then
    if idx < f.next_i then idx = f.next_i end
  else
    if idx > f.next_i then idx = f.next_i end
  end
  local list = f.b[idx]
  if not list then
    list = {}
    f.b[idx] = list
  end
  list[#list + 1] = e
end

--- Search the chunks that just came within reach of radius `a`.
local function acquire(f, surface, a, opts)
  local ra, rb
  if f.dir > 0 then
    if a <= f.acq then return end
    ra, rb = f.acq, a
  else
    if a >= f.acq then return end
    ra, rb = a, f.acq
  end
  f.acq = a

  local cx, cy, r_max = f.cx, f.cy, f.r_max
  local types, skip, accept = opts.types, opts.skip, opts.accept
  local mset = f.mv and opts.movers and opts.movers.set

  -- GENERATION MUST BE VERIFIED: find_entities_filtered returns {} for an
  -- ungenerated chunk. Pass 1 requests every missing chunk of the run and flushes
  -- ONCE (force_generate_chunk_requests drains the whole queue; once per chunk is a
  -- freeze); pass 2 searches. MUST NOT merge the passes: a row searched before its
  -- own chunk lands reads as empty.
  -- opts.generate_to bounds where the front builds ground; past it the search still
  -- pays what exists, and scripts/scar.lua pays the rest on generation. nil builds
  -- everywhere, which for a front spanning the blast is the whole disc: see
  -- C.blast.implosion.shock.generate_to before passing nil.
  local gen_to = opts.generate_to
  local gra, grb = ra, rb
  if gen_to then
    if grb > gen_to then grb = gen_to end
  end
  if grb > gra then
    profile.start("front/generate ahead (all fronts)")
    local queued = false
    front.each_ring_run(cx, cy, gra, grb, function(j, i0, i1)
      for i = i0, i1 do
        if not surface.is_chunk_generated({i, j}) then
          surface.request_to_generate_chunks({i * CHUNK + 16, j * CHUNK + 16}, 0)
          queued = true
        end
      end
    end)
    if queued then
      profile.count("front/forced generation flushes")
      surface.force_generate_chunk_requests()
    end
    profile.stop("front/generate ahead (all fronts)")
  end

  front.each_ring_run(cx, cy, ra, rb, function(j, i0, i1)
    local x0, x1 = i0 * CHUNK, (i1 + 1) * CHUNK
    local y0, y1 = j * CHUNK, (j + 1) * CHUNK
    local ents = surface.find_entities_filtered{
      area = {{x0, y0}, {x1, y1}},
      type = types,
      invert = types and opts.invert or nil,
    }
    f.runs = f.runs + 1
    f.found = f.found + #ents
    for k = 1, #ents do
      local e = ents[k]
      if e.valid and e.health and not (skip and skip[e.type])
         and not (mset and mset[e.type]) then
        local p = e.position
        -- Half-open: a position on a chunk line belongs to one side only.
        if p.x >= x0 and p.x < x1 and p.y >= y0 and p.y < y1 then
          if not accept or accept(e) then
            local dx, dy = p.x - cx, p.y - cy
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= r_max then
              place(f, e, d)
              f.binned = f.binned + 1
            end
          end
        end
      end
    end
  end)
end

--- THE MOVER BAND: re-search, for movers only, every chunk a mover the front
--- has not yet paid could be standing in -- and queue the ones it has reached.
--
-- THE ARGUMENT, outward (inward is the mirror): suppose every mover within the
-- front at the last band (radius r0, dt ticks ago) was queued. A mover still
-- unqueued and now within r was therefore outside r0 then, so it is now beyond
-- r0 - speed*dt, and its chunk's nearest point is within a chunk diagonal of
-- that. So the band is the chunks whose nearest point lies between
-- r0 - speed*dt - DIAG and r, and nothing that walked, strafed or was spawned
-- into the swept disc can be outside it. The first band starts from the centre
-- (outward) or from r_max (inward), which is the induction's base.
--
-- COST: a type-filtered search, so only movers cross into Lua -- the trees
-- and buildings in those chunks stay engine-side. It runs every step_tiles of
-- front travel or max_interval ticks, whichever comes first; the band's depth
-- is roughly DIAG + that travel, so each chunk is re-searched about
-- (DIAG + 32) / step_tiles times as the front goes by.
--
-- Something queued is never searched for again (mseen), so a mover that
-- survives its hit is not hit a second time by the same front.
local function sweep_movers(f, surface, r, opts)
  local mv   = opts.movers
  local dir  = f.dir
  local tick = game.tick
  local r_max = f.r_max
  local at_end = (dir > 0 and r >= r_max - 1e-6) or (dir < 0 and r <= 0)

  if f.mr then
    local dt = tick - f.mt
    if not (math.abs(r - f.mr) >= (opts.mover_step or mv.step_tiles)
            or dt >= mv.max_interval
            or (at_end and f.mr ~= r)) then
      if at_end then f.mdone = true end
      return
    end
  end

  local bw = f.bw
  local drift = f.mr and (mv.speed * (tick - f.mt)) or 0
  local ra, rb
  if dir > 0 then
    ra = f.mr and (f.mr - drift - DIAG - bw - 1) or 0
    rb = r + bw
  else
    ra = r - bw - DIAG - 1
    rb = (f.mr or r_max) + drift + bw
    if rb > r_max + bw then rb = r_max + bw end
  end
  -- The band radius before THIS pass: every mover this pass queues that was not
  -- already inside it stands beyond it. Recorded per queue entry for paid_radius.
  local prev = f.mr or (dir > 0 and 0 or r_max)
  f.mr, f.mt = r, tick

  local cx, cy = f.cx, f.cy
  local skip, accept = opts.skip, opts.accept
  local seen, q = f.mseen, f.mq
  local qr = f.mqr
  if not qr then qr = {}; f.mqr = qr end
  front.each_ring_run(cx, cy, ra, rb, function(j, i0, i1)
    local ents = surface.find_entities_filtered{
      area = {{i0 * CHUNK, j * CHUNK}, {(i1 + 1) * CHUNK, (j + 1) * CHUNK}},
      type = mv.types,
    }
    f.runs = f.runs + 1
    for k = 1, #ents do
      local e = ents[k]
      local id = e.valid and e.health and e.unit_number
      if id and not seen[id] and not (skip and skip[e.type]) then
        local p = e.position
        local dx, dy = p.x - cx, p.y - cy
        local d = math.sqrt(dx * dx + dy * dy)
        local reached
        if dir > 0 then reached = d <= r + bw else reached = d >= r - bw end
        if reached and d <= r_max and (not accept or accept(e)) then
          seen[id] = true
          q[#q + 1] = e
          qr[#q] = prev
          f.found = f.found + 1
          f.binned = f.binned + 1
        end
      end
    end
  end)

  if at_end then f.mdone = true end
end

--- Move the front to radius r: search what it is about to reach, pay what it has
--- passed.
--
-- @param opts   table  {types = {...}|nil, invert = bool|nil (types EXCLUDED,
--                       engine-side, instead of selected), skip = {[type]=true}|nil,
--                       accept = function(entity) -> bool |nil, lead = tiles,
--                       movers = C.blast.movers |nil -- required by a front
--                       built with movers = true}
-- @param pay    function(entity, distance) called once per thing the front passes;
--               the entity is valid when called and may be dead after it
-- @param budget number   most things paid this call
-- @return number things paid
function front.advance(f, surface, r, opts, pay, budget)
  if not (surface and surface.valid) then return 0 end
  local dir = f.dir

  -- THE LEAD: at least opts.lead, at least twice this tick's travel (the Sedov
  -- front and the Guderley shell both move fastest exactly where a fixed lead
  -- would be outrun), plus a chunk diagonal.
  local step = math.abs(r - (f.r_last or r))
  f.r_last = r
  local lead = opts.lead or 32
  if step * 2 > lead then lead = step * 2 end
  lead = lead + DIAG

  if dir > 0 then
    local a = r + lead
    if a > f.r_max + 1 then a = f.r_max + 1 end
    acquire(f, surface, a, opts)
  else
    local a = r - lead
    if a < 0 then a = 0 end
    acquire(f, surface, a, opts)
  end

  -- A front built for the band but advanced without it (config switched off
  -- under a save) falls back to the one-time search from here on.
  if f.mv and not opts.movers then f.mv = nil end

  local done = 0
  if f.mv then
    sweep_movers(f, surface, r, opts)
    -- Reached movers first: they were reached, and they are the ones that walk.
    local q = f.mq
    local i = f.mqi
    while i <= #q and done < budget do
      local e = q[i]
      i = i + 1
      if e.valid then
        local p = e.position
        local dx, dy = p.x - f.cx, p.y - f.cy
        pay(e, math.sqrt(dx * dx + dy * dy))
        done = done + 1
        f.mpaid = f.mpaid + 1
      end
    end
    if i > #q then
      f.mq = {}
      f.mqr = {}
      f.mqi = 1
    else
      f.mqi = i
    end
  end

  local bw = f.bw
  local reached = math.floor(r / bw)
  local slack = bw

  while done < budget do
    local idx = f.next_i
    if dir > 0 then
      if idx > reached then break end
    else
      if idx < reached or idx < 0 then break end
    end

    local list = f.b[idx]
    if list then
      local i = f.cursor
      local n = #list
      while i <= n and done < budget do
        local e = list[i]
        i = i + 1
        if e.valid then
          local p = e.position
          local dx, dy = p.x - f.cx, p.y - f.cy
          local d = math.sqrt(dx * dx + dy * dy)
          if dir > 0 and d > r + slack then
            -- Walked out ahead of the front. It is caught when the front is.
            if d <= f.r_max then place(f, e, d) end
          elseif dir < 0 and d < r - slack then
            -- Walked in ahead of the shell.
            place(f, e, d)
          else
            pay(e, d)
            done = done + 1
          end
        end
      end
      if i > n then
        f.b[idx] = nil
        f.cursor = 1
      else
        -- Budget ran out mid-bucket. Resume here next tick.
        f.cursor = i
        break
      end
    end
    f.next_i = idx + dir
  end

  f.paid = f.paid + done
  return done
end

--- The radius an OUTWARD front's payout has fully crossed: nothing at or inside
--- it is still waiting to be hit.
--
-- The front's own radius says where the wave IS; this says where its damage has
-- GOT TO, and under a per-tick budget they come apart -- the payout trails the
-- front by however much backlog a dense death world piles up, and movers are
-- paid before statics, so on a bad tick the buckets get nothing at all. A
-- consumer that snapshots the world (the map refresh) has to wait for THIS
-- radius or it records things that are already condemned as still standing.
--
-- Statics: every bucket below next_i is empty. Movers: nothing beyond the last
-- band pass has been queued at all, and the queue is paid in the order it was
-- filled, so nothing inside the band radius recorded for the head entry is still
-- queued. Whichever is furthest behind wins. A queue entry with no
-- recorded radius (a front saved before mqr existed) reads as 0 -- the honest
-- answer for one of unknown depth, and it drains in a few ticks.
-- @return number|nil  nil for an inward front, which no consumer asks about
function front.paid_radius(f)
  if f.dir < 0 then return nil end
  local r = f.next_i * f.bw
  if f.mv then
    -- Movers past the last band pass have not even been QUEUED yet (the band
    -- re-runs every step_tiles of travel or max_interval ticks).
    local searched = f.mr or 0
    if searched < r then r = searched end
    local q, i = f.mq, f.mqi
    if i <= #q then
      local qr = f.mqr and f.mqr[i] or 0
      if qr < r then r = qr end
    end
  end
  return r
end

--- Has the payout crossed the whole sweep?
function front.done(f)
  if f.mv and not (f.mdone and f.mqi > #f.mq) then return false end
  if f.dir > 0 then
    return f.next_i > math.floor(f.r_max / f.bw)
  end
  return f.next_i < 0
end

return front
