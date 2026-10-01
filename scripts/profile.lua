-- scripts/profile.lua -----------------------------------------------------------
-- /oppenheimer-profile: WHERE THE MOD'S F4 LINE GOES.
--
-- F4 puts all of this mod's script time on one line. This splits it: named
-- LuaProfiler timers (helpers.create_profiler, 2.0.77 spec) around each piece
-- of per-tick work, averaged over a window and reported as ms per tick, to the
-- requesting player's chat and to script-output/<C.perf.profile.file>.
--
--   profile.start("wave/paint") ... profile.stop("wave/paint")
--   profile.count("slay/offscreen", n)
--
-- OFF IS ONE TABLE READ: start/stop/count return on `storage.profile == nil`.
--
-- LIMITS. A LuaProfiler's value cannot be read as a number -- only printed via a
-- LocalisedString -- so the report can average (divide) but never sort, compare
-- or find a per-tick maximum. A one-tick spike is diluted across its window.
-- Timers nest: a parent key includes its children.
--
-- DETERMINISM. The on/off state and the report schedule are in storage, written
-- only by the command and the report tick, identically on every client. The
-- timers and counters are scratch (a LuaProfiler cannot be serialized); they
-- are only ever printed, and write_file writes on the requesting player's
-- machine alone -- nothing here feeds back into the simulation.
--------------------------------------------------------------------------------

local C = require("config")

local profile = {}

-- SCRATCH. key -> {p = LuaProfiler|nil, n = calls or counted units, counter = bool}
local T = {}
local ORDER = {}

local function slot(key, counter)
  local t = T[key]
  if not t then
    t = {n = 0, counter = counter}
    if not counter then t.p = helpers.create_profiler(true) end
    T[key] = t
    ORDER[#ORDER + 1] = key
  end
  return t
end

function profile.start(key)
  if not storage.profile then return end
  local t = slot(key, false)
  t.p.restart()
  t.n = t.n + 1
end

function profile.stop(key)
  if not storage.profile then return end
  local t = T[key]
  if t and t.p then t.p.stop() end
end

function profile.count(key, n)
  if not storage.profile then return end
  local t = slot(key, true)
  t.n = t.n + (n or 1)
end

local function clear()
  for k in pairs(T) do T[k] = nil end
  for i = #ORDER, 1, -1 do ORDER[i] = nil end
end

--- Begin a run for `player_index`, for `seconds`.
function profile.begin(player_index, seconds, window)
  clear()
  storage.profile = {
    player = player_index,
    started = game.tick,
    window_start = game.tick,
    stop_at = game.tick + math.floor(seconds * 60),
    window = window,
    windows = 0,
  }
end

--- What the mod is doing right now, for the report header.
local function phase_line()
  local lances, preps = 0, 0
  for _, rec in pairs(storage.turrets or {}) do
    if rec.lance then lances = lances + 1 end
    if rec.prep and not rec.prep.done then preps = preps + 1 end
  end
  return string.format(
    "lances lit %d, collapses %d, waves %d, preparing %d, flora fronts %d",
    lances, #(storage.implosions or {}), #(storage.sweeps or {}), preps,
    table_size(storage.flora or {}))
end

local function report(final)
  local pr = storage.profile
  local player = game.get_player(pr.player)
  local ticks = game.tick - pr.window_start
  if ticks <= 0 then return end
  local file = C.perf.profile.file
  local first = pr.windows == 0

  -- Emitted line by line, BEFORE the timer is reset: a LuaProfiler inside a
  -- LocalisedString is read when the string is handed over.
  local function emit(line)
    if player and player.valid then
      if player.connected then
        player.print(line, {skip = defines.print_skip.never, game_state = false,
                            sound = defines.print_sound.never})
      end
      helpers.write_file(file, {"", line, "\n"}, not first, pr.player)
      first = false
    end
  end

  emit(string.format("[oppenheimer-profile] tick %d-%d (%d ticks) %s -- %s",
    pr.window_start, game.tick, ticks, final and "FINAL" or ("window " .. (pr.windows + 1)),
    phase_line()))
  for _, key in ipairs(ORDER) do
    local t = T[key]
    if t.n > 0 then
      if t.counter then
        emit(string.format("  %s  %d total, %.1f/tick", key, t.n, t.n / ticks))
      else
        t.p.stop()
        t.p.divide(ticks)
        emit({"", "  ", key, string.format("  (%.2f calls/tick) per tick: ", t.n / ticks), t.p})
        t.p.reset()
        t.p.stop()
      end
      t.n = 0
    end
  end

  pr.windows = pr.windows + 1
  pr.window_start = game.tick
end

--- End the run, with a final report of the partial window.
function profile.finish()
  if not storage.profile then return end
  report(true)
  storage.profile = nil
  clear()
end

--- Per tick, registered LAST in control.lua so it follows every timed handler.
function profile.tick()
  local pr = storage.profile
  if not pr then return end
  if game.tick >= pr.stop_at then
    profile.finish()
  elseif game.tick - pr.window_start >= pr.window then
    report(false)
  end
end

return profile
