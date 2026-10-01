-- control.lua: runtime entry point. Modules must register before events.install().

local events = require("scripts.events")
local N      = require("lib.names")
local audio = require("scripts.audio")
local schema = require("scripts.schema")

require("scripts.pylon")
require("scripts.detonate")
require("scripts.groundfire")
local scar = require("scripts.scar")
require("scripts.implode")
require("scripts.impact")
require("scripts.beam")
require("scripts.turret")
require("scripts.placement")
require("scripts.render")
require("scripts.targeting")
require("scripts.blueprint")
require("scripts.gui")
require("scripts.remote")
require("scripts.arcsweep")
require("scripts.alpha")

local turret = require("scripts.turret")
local gui    = require("scripts.gui")
local C      = require("config")
local pylon     = require("scripts.pylon")
local placement = require("scripts.placement")

schema.link{
  turret    = turret,
  pylon     = pylon,
  placement = placement,
  logistics = require("scripts.logistics"),
}

--- Enable HUD toggle button on player join or init.
local function arm_shortcut(player)
  if not (player and player.valid) then return end
  player.set_shortcut_available(N.gui.hud_toggle, true)
  storage.hud_hidden = storage.hud_hidden or {}
  player.set_shortcut_toggled(N.gui.hud_toggle, not storage.hud_hidden[player.index])
end

local function arm_all()
  for _, player in pairs(game.players) do arm_shortcut(player) end
end

script.on_init(function()
  schema.ensure()
  arm_all()
  turret.adopt_orphans()
end)

-- Register through the dispatcher (scripts/events.lua), not script.on_event.
events.on(defines.events.on_player_created, function(event)
  arm_shortcut(game.get_player(event.player_index))
end)

events.on(defines.events.on_player_joined_game, function(event)
  arm_shortcut(game.get_player(event.player_index))
end)

script.on_configuration_changed(function()
  schema.migrate()
  arm_all()
  storage.no_orientation = nil
  local adopted = turret.adopt_orphans()
  if adopted > 0 then
    game.print{"oppenheimer.adopted", tostring(adopted)}
  end
  for _, rec in pairs(storage.turrets or {}) do
    local e = rec.entity
    if e and e.valid then
      for _, pun in pairs(rec.pylons or {}) do
        if storage.pylons then storage.pylons[pun] = nil end
      end
      rec.pylons = {}
      pylon.adopt_existing(rec)
      placement.foundation(e)
    end
  end
  for _, player in pairs(game.players) do
    gui.purge_legacy(player)
  end
end)

--- Status dump: what the mod believes about all installations.
commands.add_command(
  N.command.status,
  {"oppenheimer.status-command-help"},
  function(command)
    local player = command.player_index and game.get_player(command.player_index)
    local function out(msg)
      audio.print(player or game, msg)
    end

    local turrets = (storage and storage.turrets) or {}
    local n = 0
    for _ in pairs(turrets) do n = n + 1 end
    out(string.format("[Oppenheimer] %d installation(s) tracked", n))

    for un, rec in pairs(turrets) do
      local e = rec.entity
      local alive = e and e.valid
      local energy, chamber = 0, 0
      local banks = 0
      if alive then
        for _, pun in pairs(rec.pylons or {}) do
          local link = storage.pylons and storage.pylons[pun]
          local pe = link and link.entity
          if pe and pe.valid then
            banks = banks + 1
            energy = energy + pe.energy
          end
        end
        chamber = rec.cells or -1
      end
      local aim = "n/a"
      if storage.no_orientation then
        aim = "BLIND -- orientation unavailable, gates open"
      elseif alive and rec.designated then
        local ok, off = turret.aimed(rec)
        aim = ok and "ON TARGET"
          or (off and string.format("%.1f deg off", off * 360) or "slewing")
      end
      local force = alive and e.force or nil
      out(string.format(
        "  #%d state=%s banks=%d energy=%.0f MJ spool=%.0f MJ cells=%d yield=%d%% rec.rate=%.0f MW turret.rate=%.0f MW capacity=%d reach=%.0f designated=%s aim=%s lance=%s",
        un, tostring(rec.state), banks, energy / 1000000,
        (rec.spool or 0) / 1000000, chamber,
        math.floor((rec.yield_target or 1) * 100 + 0.5),
        (rec.rate or -1) / 1000000, turret.rate(rec) / 1000000,
        C.capacity(force), C.reach(),
        rec.designated and "yes" or "no", aim,
        rec.lance and "LIT" or "-"))

      local ls = rec.last_shot
      if ls then
        out(string.format(
          "     last shot: beam vaporized %d, fire wave burned %d, lightning struck %d, sphere %.0f tiles, power %.0f%%",
          ls.killed or 0, ls.burned or 0, ls.struck or 0, ls.radius or 0,
          (ls.power or 0) * 100))
      end
    end

    local sweeps = (storage and storage.sweeps) or {}
    local running = 0
    for _ in pairs(sweeps) do running = running + 1 end
    if running > 0 then
      out(string.format("  %d damage sweep(s) in flight", running))
    end

    local burning = (storage and storage.groundfires) or {}
    if #burning > 0 then
      local laid = 0
      for _, g in ipairs(burning) do laid = laid + (g.laid or 0) end
      out(string.format("  %d crater(s) still glowing, %d ground flames laid", #burning, laid))
    end

    local sv = storage and storage.last_sweep
    if sv then
      out(string.format(
        "  last sweep @tick %d: radius %.0f, searches %d, found %d, binned %d, damaged %d, vaporized %d (movers among them %d), painted %d tiles, charted %d chunks, generated %d",
        sv.tick or 0, sv.radius or 0, sv.searches or 0, sv.found or 0, sv.binned or 0,
        sv.damaged or 0, sv.destroyed or 0, sv.movers or 0, sv.painted or 0,
        sv.charted or 0, sv.generated or 0))
    end

    local scars = (storage and storage.scars) or {}
    if #scars > 0 then
      local s1 = scars[#scars]
      out(string.format(
        "  %d blast footprint(s) on record; newest @tick %d: radius %.0f, annulus beyond %.0f",
        #scars, s1.tick or 0, s1.radius or 0, s1.inner or 0))
    end
  end
)

--- Fire the nearest installation.
commands.add_command(
  N.command.fire,
  {"oppenheimer.fire-command-help"},
  function(command)
    local player = command.player_index and game.get_player(command.player_index)
    if not player then return end

    local best, best_d2
    for _, rec in pairs(storage.turrets or {}) do
      local e = rec.entity
      if e and e.valid and e.surface == player.surface and e.force == player.force then
        local dx = e.position.x - player.position.x
        local dy = e.position.y - player.position.y
        local d2 = dx * dx + dy * dy
        if not best_d2 or d2 < best_d2 then best, best_d2 = rec, d2 end
      end
    end

    if not best then
      audio.notify(player, {"oppenheimer.no-turret"})
      return
    end

    if best.state == turret.AIM then
      local ok, why, off = turret.release(best)
      if not ok and why == "slewing" then
        audio.notify(player, {"oppenheimer.still-slewing",
                     tostring(math.floor((off or 0) * 360 + 0.5))})
      end
    else
      audio.notify(player, {"oppenheimer.fire-refused", tostring(best.state)})
    end
  end
)

--- Calibrate beam origin: /oppenheimer-muzzle [forward lift] | reset
commands.add_command(
  N.command.muzzle,
  {"oppenheimer.muzzle-command-help"},
  function(command)
    local player = command.player_index and game.get_player(command.player_index)
    local function out(msg)
      audio.print(player or game, msg)
    end

    local arg = command.parameter

    if arg and arg:match("^%s*reset%s*$") then
      storage.muzzle_forward = nil
      storage.muzzle_lift = nil
      out{"oppenheimer.muzzle-reset",
          string.format("%.3f", C.beam.muzzle_forward_mult or 1),
          string.format("%.3f", C.beam.muzzle_lift_mult or 1)}
      return
    end

    if arg then
      local f, l = arg:match("^%s*([%-%d%.]+)%s+([%-%d%.]+)%s*$")
      local nf, nl = tonumber(f), tonumber(l)
      if nf and nl then
        storage.muzzle_forward = nf
        storage.muzzle_lift = nl
        storage.muzzle_debug = true
      elseif arg:match("%S") then
        out{"oppenheimer.muzzle-usage"}
        return
      end
    else
      storage.muzzle_debug = not storage.muzzle_debug
    end

    local fwd = storage.muzzle_forward or C.beam.muzzle_forward_mult or 1
    local lft = storage.muzzle_lift or C.beam.muzzle_lift_mult or 1
    out{"oppenheimer.muzzle-report",
        string.format("%.3f", fwd),
        string.format("%.3f", lft),
        string.format("%.2f", C.muzzle_distance() * fwd + C.beam.muzzle_clear),
        string.format("%.2f", C.cannon_base_shift()[3] * lft),
        storage.muzzle_debug and "ON" or "OFF"}
  end
)

commands.add_command(
  N.command.hud,
  {"oppenheimer.hud-command-help"},
  function(command)
    local player = command.player_index and game.get_player(command.player_index)
    if player then gui.toggle_hud(player) end
  end
)

commands.add_command(
  N.command.count,
  {"oppenheimer.count-command-help"},
  function(command)
    local total = (storage and storage.turrets_built) or 0
    local message = {"oppenheimer.count-message", total}
    local player = command.player_index and game.get_player(command.player_index)
    audio.print(player or game, message)
  end
)

local profile = require("scripts.profile")
commands.add_command(
  N.command.profile,
  {"oppenheimer.profile-command-help"},
  function(command)
    local player = command.player_index and game.get_player(command.player_index)
    if not player then return end
    local arg = command.parameter or ""
    local pc = C.perf.profile
    if arg:match("^%s*off%s*$") then
      if storage.profile then
        profile.finish()
      else
        audio.print(player, {"oppenheimer.profile-not-running"})
      end
      return
    end
    local secs, win = arg:match("^%s*(%d*%.?%d*)%s*(%d*)%s*$")
    if not secs then
      audio.print(player, {"oppenheimer.profile-usage"})
      return
    end
    secs = tonumber(secs) or pc.default_seconds
    win = tonumber(win) or pc.window_ticks
    if secs <= 0 or win < 1 then
      audio.print(player, {"oppenheimer.profile-usage"})
      return
    end
    if storage.profile then profile.finish() end
    profile.begin(player.index, secs, win)
    audio.print(player, {"oppenheimer.profile-started", tostring(secs), tostring(win), pc.file})
  end
)
events.on_nth_tick(1, profile.tick)
events.install()
