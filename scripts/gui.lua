-- scripts/gui.lua ----------------------------------------------------------------
-- ONE panel. The status HUD *is* the fire control.
--
-- A per-turret fire-control frame doesn't work here: `player.gui.relative`
-- (the mechanism for "attach my UI to that entity window") needs a
-- defines.relative_gui_type anchor, and the enum has no artillery-turret
-- member (an artillery turret is not a TurretPrototype). A `player.gui.screen`
-- frame opened on on_gui_opened instead renders underneath the engine's own
-- ammo-inventory window for the same entity, which opens on the same event --
-- both centred, same size, the mod's window always losing.
--
-- So the controls live in one panel that answers to nobody's z-order but
-- ours. ONE installation is shown at a time -- status, chamber, charge bar,
-- yield, CONFIRM, ABORT -- because a battery of eight guns was eight stacked
-- copies of the same controls and a LOCK button to press before each shot. A
-- battery bar above the row says how many there are, picks which one the panel
-- shows and the designator commands, and arms the ALPHA STRIKE that fires the
-- lot at once (scripts/alpha.lua).
--
-- THE PANEL IS NOT ON THE CRITICAL PATH, and must never become it. The
-- primary fire control is the designator itself (scripts/remote.lua) and
-- /oppenheimer-fire behind that -- a GUI that has to open, find its record and
-- enable a button before the gun can fire is a single point of failure for a
-- weapon.
--
-- REBUILT ONLY WHEN THE SET OF INSTALLATIONS CHANGES: a button destroyed and
-- recreated under the cursor eats the click, so structure is built once per
-- signature change and captions/values/enabled states are written in place.
----------------------------------------------------------------------------------

local C        = require("config")
local N        = require("lib.names")
local audio = require("scripts.audio")
local events   = require("scripts.events")
local schema   = require("scripts.schema")
local turret   = require("scripts.turret")
-- Idea C: the arc sweep's own HUD toggle lives here (the row's own controls),
-- but the mode flag it writes belongs to that file, not this one. One-way:
-- arcsweep.lua never requires gui.lua.
local arcsweep = require("scripts.arcsweep")
local alpha    = require("scripts.alpha")
local prepare  = require("scripts.prepare")
local profile  = require("scripts.profile")

local gui = {}

-- The 0.8.0 fire-control frame. It is never built any more -- but GUI elements
-- live in the save file, so a save taken with that window open reloads with the
-- frame still on screen, orphaned, with no handler behind it and no way to shut
-- it. purge_legacy() is what takes it off the screen on upgrade.
local LEGACY_FIRE_FRAME = N.gui.fire_frame

-- =============================================================================
-- Open-window bookkeeping
-- =============================================================================

local function opened(player_index)
  storage.gui_open = storage.gui_open or {}
  return storage.gui_open[player_index]
end

--- Remove the dead 0.8.0 fire-control window from a player's screen.
-- Called from control.lua on_configuration_changed. Idempotent, and harmless on
-- a save that never had one.
function gui.purge_legacy(player)
  if not (player and player.valid) then return end
  local stale = player.gui.screen[LEGACY_FIRE_FRAME]
  if stale and stale.valid then stale.destroy() end
end

-- FORWARD DECLARATIONS, and they are load-bearing: Lua resolves a `local`
-- only from its declaration onward, so a caller ABOVE a same-file helper's
-- definition would otherwise compile to a GLOBAL lookup -- valid syntax,
-- clean parse, nil the first time it runs. tools/verify.py check 12 catches
-- this class of bug now; every name below was once the reason the panel
-- crashed the first time a player reached the state that exercised it.
local battery_recs
local crew_of, battery_hist, sweep_rec, battery_energy, window_tip
local progress_of
local fmt_rate, fmt_energy, fmt_yield, fmt_radius, fmt_rim_psi
local fmt_concentration, fmt_rim_kill
local rate_items, rate_index, milestone_of
local bank_ceiling, overdraw_of, cap_note
local release_caption, mode_state, mode_style

--- Whole seconds until `tick`, never negative.
local function seconds_until(tick)
  return tostring(math.floor(math.max(0, tick - game.tick) / 60 + 0.5))
end

--- The state field, as a localised string. ONE SHORT LINE: the fire-control
--- buttons sit beside it on the same row, and a status line that wraps pushes
--- every row's controls down with it.
local function status_of(rec)
  local st = rec.state
  if st == turret.AIM then
    -- The barrel's travel gates CONFIRM, so it is what the player reads while they wait.
    local aligned, off = turret.aimed(rec)
    if not aligned then
      return {"oppenheimer.fc-slewing", tostring(math.floor((off or 0) * 360 + 0.5))}
    end
    return {"oppenheimer.fc-aim"}
  elseif st == turret.FIRE then
    if rec.discharged then
      -- The lance's own cut tick: a lance that joined a strike late burns less.
      return {"oppenheimer.fc-lance", seconds_until(rec.lance and rec.lance.cut_at or 0)}
    end
    return {"oppenheimer.fc-spooling", tostring(math.floor(progress_of(rec) * 100 + 0.5))}
  elseif st == turret.STANDBY then
    return {"oppenheimer.fc-standby"}
  elseif st == turret.BOOT then
    return {"oppenheimer.fc-boot"}
  elseif st == turret.DARK then
    return {"oppenheimer.fc-dark"}
  elseif st == turret.COOLDOWN then
    -- THE VENT IS THE RELOAD TIMER, so it counts down. The same number
    -- scripts/installfx.lua now smokes for (C.installfx.vent_ticks_for), so
    -- the barrel and the panel agree on when the gun is ready.
    local e = rec.entity
    local force = e and e.valid and e.force or nil
    return {"oppenheimer.fc-cooldown",
            seconds_until(rec.state_since + C.charge.cooldown_for(force))}
  end
  return {"oppenheimer.fc-offline"}
end

--- The charge readout: percent of the order, then the energy behind it. THE
--- WHOLE BATTERY -- the row is one weapon however many installations stand in
--- it, so a figure for the representative alone understated the order and the
--- grid's bill by the size of the battery.
local function charge_of(rec)
  local goal, have = battery_energy(rec)
  local pct = math.floor(progress_of(rec) * 100 + 0.5)
  return {"oppenheimer.fc-charge", tostring(pct),
          fmt_energy(have), fmt_energy(goal)}
end

--- 0..1 for the progress bar. Declared above status_of; see the note there.
function progress_of(rec)
  -- After the strike the bar is the lance burning, 1 -> 0 across this lance's
  -- own burn; the banks are spent by then and would read zero.
  if rec.state == turret.FIRE and rec.discharged then
    local L = rec.lance
    if not L then return 0 end
    local left = L.cut_at - game.tick
    return math.max(0, math.min(1, left / math.max(1, L.cut_at - L.lit_at)))
  end
  if rec.state == turret.FIRE then
    -- The charge is the banks filling, not a counter the mod increments, so read
    -- the banks. rec.spool is only meaningful once the round has been released.
    local goal, have = battery_energy(rec)
    if goal <= 0 then return 0 end
    return math.min(1, have / goal)
  end
  return 0
end

-- =============================================================================
-- THE POWER GRAPH (#15)
--
-- What the grid is actually delivering into this installation, one bar per HUD
-- refresh, oldest on the left. turret.power_sample fills the history; this is
-- only presentation.
--
-- THE SCALE IS WHAT THE INSTALLATION IS ASKING FOR -- the dialled rate while it
-- charges, its standby draw otherwise -- so a full-height bar means "the grid is
-- keeping up" at every yield, and a sagging graph is the brownout the stall
-- warning shouts about, visible several seconds before it does.
-- =============================================================================

local G = C.hud.graph

--- The scale a bar is drawn against, in watts. Peaks in the window raise it,
--- so a spike is never clipped flat against the top.
local function battery_rate(rec)
  local want, firing = 0, 0
  local crew = crew_of(rec)
  for _, r in ipairs(crew) do
    if r.state == turret.FIRE and not r.discharged then
      want = want + turret.rate(r)
      firing = firing + 1
    end
  end
  if firing > 0 then return want end
  return C.power.standby_draw * #crew
end

local function graph_scale(rec, hist)
  local want = battery_rate(rec)
  if hist then
    for i = 1, #hist do
      if hist[i] > want then want = hist[i] end
    end
  end
  return math.max(1, want)
end

--- Which of the four tinted sprites a bar at this fraction of the scale gets.
local function graph_sprite(frac)
  if frac >= G.cold_at then return N.sprite_gui.graph_cold end
  if frac >= G.warm_at then return N.sprite_gui.graph_warm end
  if frac > 0.02       then return N.sprite_gui.graph_hot  end
  return N.sprite_gui.graph_dim
end

--- Write the history into a row's bars. Oldest on the left, so a graph that
--- is not full yet grows in from the right rather than jumping.
local function draw_graph(gr, rec)
  local hist = battery_hist(rec)
  local count = hist and #hist or 0
  local scale = graph_scale(rec, hist)
  local children = gr.children
  for i = 1, G.samples do
    local bar = children[i]
    if bar and bar.valid then
      local v = hist and hist[count - G.samples + i]
      local frac = v and math.min(1, v / scale) or 0
      local h = math.floor(frac * G.height_px + 0.5)
      if h < 1 then h = 1 end
      -- style.height is write-only (a read throws); minimal_height is what it sets.
      if bar.style.minimal_height ~= h then bar.style.height = h end
      local sp = v and graph_sprite(frac) or N.sprite_gui.graph_dim
      if bar.sprite ~= sp then bar.sprite = sp end
    end
  end
  gr.tooltip = {"oppenheimer.fc-graph-tip",
                tostring(math.floor(G.samples * C.hud.refresh_ticks / 60 + 0.5)),
                fmt_rate(scale)}
end

--- The instantaneous draw, and a warning colour on it when the grid is
--- falling short of the rate this installation ordered -- the same shortfall
--- the graph shows as a sagging line, in a number.
local function draw_of(rec)
  local hist = battery_hist(rec)
  local w = (hist and #hist > 0) and hist[#hist] or 0
  local text = fmt_rate(w)
  if rec.state == turret.FIRE and not rec.discharged
     and w < battery_rate(rec) * G.cold_at then
    text = "[color=255,190,60]" .. text .. "[/color]"
  end
  return {"oppenheimer.fc-draw", text}
end

--- What the overpower band is buying, once the dial is inside it. The radius has
--- stopped, so the row has to name what has not.
local function power_note(rec)
  -- The battery's yield against the crater the dial asked for. Their ratio is
  -- what the extra installations bought, and it is all pressure.
  local frac, _, _, order = schema.group(rec)
  if order <= 0 or frac <= order * 1.001 then return "" end
  local shot, order_j = frac * C.charge.cost_per_shot,
                        order * C.charge.cost_per_shot
  return {"oppenheimer.fc-overpower", string.format("%.1f", frac / order),
          fmt_rim_psi(shot, order_j), fmt_rim_kill(shot, order_j)}
end

--- The one conditional line under the telemetry, in priority order: what the
--- blast-zone preparation has to say while aiming, then a bank ceiling the
--- order is over, then the overpower band, then the research cap. "" when there is nothing, which leaves an empty label
--- rather than reflowing the row (see build_row).
-- @return LocalisedString caption, LocalisedString tooltip
-- MUST return the tooltip with its caption: five messages share one label.
local function note_of(rec, force)
  if rec.state == turret.AIM then
    local prep = prepare.caption(rec, true)
    if prep ~= "" then return prep, {"oppenheimer.fc-prep-tip"} end
  end
  local ov = overdraw_of(rec)
  if ov ~= "" then return ov, {"oppenheimer.fc-overdraw-tip"} end
  local pw = power_note(rec)
  if pw ~= "" then return pw, {"oppenheimer.fc-overpower-tip"} end
  return cap_note(force, #crew_of(rec)), {"oppenheimer.fc-cap-tip"}
end

-- =============================================================================
-- Focus
--
-- Clicking a turret no longer builds a window (see the header). It records
-- which installation the player is looking at, so the HUD can mark that row.
-- =============================================================================

function gui.on_opened(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local e = event.entity
  if not (e and e.valid and e.name == N.turret) then return end
  if not (storage.turrets and storage.turrets[e.unit_number]) then return end

  storage.gui_open = storage.gui_open or {}
  storage.gui_open[player.index] = e.unit_number

  -- Force a structural rebuild so the highlight moves this tick rather than
  -- whenever the installation set next happens to change.
  storage.hud_sig = storage.hud_sig or {}
  storage.hud_sig[player.index] = nil
  gui.refresh_hud(player)
end

function gui.on_closed(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  storage.gui_open = storage.gui_open or {}
  if storage.gui_open[player.index] then
    storage.gui_open[player.index] = nil
    storage.hud_sig = storage.hud_sig or {}
    storage.hud_sig[player.index] = nil
    gui.refresh_hud(player)
  end
end

-- =============================================================================
-- Interaction
-- =============================================================================

--- Yield select. A drop-down rather than the old six radiobuttons: the panel now
--- carries one control block PER INSTALLATION, and six radios times a battery of
--- six guns is a wall of forty rows nobody reads.
function gui.on_selection(event)
  local el = event.element
  if not (el and el.valid and el.type == "drop-down") then return end
  local un = el.tags and el.tags.oppenheimer_unit
  if not un then return end

  local rec = storage.turrets and storage.turrets[un]
  if not rec then return end

  -- The last row is Custom, which has no preset behind it. Selecting it is a
  -- no-op rather than an error: it is the row the drop-down DISPLAYS when the
  -- field has been used, so a player clicking it is asking for what they already
  -- have.
  local w = C.power.rate_presets[el.selected_index]
  if not w then return end

  -- Refused rather than silently applied once the tape is rolling. The ramp is
  -- already writing capacitor buffers against the current goal; moving the goal
  -- mid-charge would jump every bank's buffer in one tick and put a step in the
  -- middle of the power graph.
  if rec.state ~= turret.STANDBY and rec.state ~= turret.AIM then return end

  local set = turret.set_rate(rec, w)
  -- The battery shares one dial, because it shares one shot.
  for _, r in ipairs(battery_recs(rec)) do
    if r ~= rec then turret.set_rate(r, w) end
  end

  local player = game.get_player(event.player_index)
  if player then
    local order = set / C.power.reference_rate
    local shot = math.min(order * #battery_recs(rec), C.charge.group_cap)
                 * C.charge.cost_per_shot
    audio.notify(player, {"oppenheimer.rate-set", fmt_rate(set),
                 fmt_radius(order * C.charge.cost_per_shot), fmt_yield(shot)})
  end
end

--- TEST/LIVE. The whole battery, like every other control on this panel.
function gui.on_switch(event)
  local el = event.element
  if not (el and el.valid and el.name == N.gui.fire_mode) then return end
  local un = el.tags and el.tags.oppenheimer_unit
  local rec = un and storage.turrets and storage.turrets[un]
  if not rec then return end
  local mode = (el.switch_state == "left") and "test" or "live"
  for _, r in ipairs(battery_recs(rec)) do turret.set_fire_mode(r, mode) end
end

function gui.on_click(event)
  local el = event.element
  if not (el and el.valid) then return end
  if el.name ~= N.gui.fire_release and el.name ~= N.gui.fire_abort
     and el.name ~= N.gui.arc_sweep_toggle then
    return
  end

  -- Element names only have to be unique among SIBLINGS, and every row is its
  -- own container -- so all rows can share these two names and the unit number
  -- rides in the tags, exactly as it did when there was one window.
  local un = el.tags and el.tags.oppenheimer_unit
  local rec = un and storage.turrets and storage.turrets[un]
  if not rec then return end

  local player = game.get_player(event.player_index)
  -- EVERY CONTROL ON THIS PANEL COMMANDS THE WHOLE BATTERY. The installations
  -- are permanently linked and fire together, so `rec` is only the row's
  -- representative -- a control that reached it alone would put the rest out of
  -- step with what the panel says.
  local crew = battery_recs(rec)

  if el.name == N.gui.fire_release then
    local sw = sweep_rec(rec)
    if sw then
      local ok, why = arcsweep.confirm(sw)
      if not ok and player then audio.notify(player, {"oppenheimer.arc-sweep-refused", tostring(why)}) end
    elseif player then
      -- TEST mode prepares rather than fires, and does so per installation.
      if rec.fire_mode == "test" then
        for _, r in ipairs(crew) do turret.release(r) end
      else
        -- NO SINGLE-GUN FALLBACK. alpha.confirm has already offered the press
        -- to every installation aiming at the same point; releasing the
        -- representative on its own when it declines is not a fallback, it is
        -- one gun going downrange while the rest stand by.
        local ok, why = alpha.confirm(player, crew)
        if not ok then
          -- turret.aimed answers `false, nil` for a gun with no target at all,
          -- which would read as "barrel turning, 0 degrees to go".
          local aligned, off
          if rec.designated then aligned, off = turret.aimed(rec) end
          if rec.designated and not aligned then
            audio.notify(player, {"oppenheimer.still-slewing",
                         tostring(math.floor((off or 0) * 360 + 0.5))})
          else
            audio.notify(player, {"oppenheimer.fire-refused",
                         tostring(why or rec.state)})
          end
        end
      end
    end
  elseif el.name == N.gui.fire_abort then
    local e = rec.entity
    if e and e.valid then alpha.drop(e.force, e.surface) end
    for _, r in ipairs(crew) do
      if not arcsweep.cancel(r) then turret.scrub(r) end
    end
  else
    -- Idea C: the on/off toggle. set_mode also drops a pending (unconfirmed)
    -- aim, so switching off mid-aim cannot leave a stale marked span armed
    -- for the next time it is switched back on.
    local on = not rec.arc_sweep_mode
    for _, r in ipairs(crew) do arcsweep.set_mode(r, on) end
  end
end

-- =============================================================================
-- The status HUD. It exists only while something needs attention.
-- =============================================================================

local HUD = N.gui.hud_frame
-- GUI elements are saved, and refresh_hud only rebuilds a frame's rows when the
-- installation list changes -- so a save made under an older row layout keeps
-- drawing its old rows, captions and all, indefinitely (locale keys since
-- removed show as "Unknown key"). The frame carries this number in its tags;
-- a mismatch (or no tag) drops and rebuilds it. Bump it whenever build_row's
-- structure or the drop-down's rungs change. Independent of
-- on_configuration_changed on purpose: that never re-fires for a save already
-- at the current mod version.
local HUD_LAYOUT = 4

--- Every installation this player owns, in a stable order.
-- #107: ALL of them, not just the busy ones. A super weapon's status board is
-- supposed to be sitting there whether or not it is doing something -- that IS
-- the presence. The player hides it with the shortcut if they want it gone.
-- Viewed surface only: a battery is per surface (schema.crew).
local function notable(force, surface)
  local out = {}
  for un, rec in pairs(storage.turrets or {}) do
    local e = rec.entity
    if e and e.valid and e.force == force and e.surface == surface then
      out[#out + 1] = {un = un, rec = rec}
    end
  end
  -- Sorted by unit_number: a stable order, so rows do not shuffle underneath a
  -- player who is in the middle of reading them.
  table.sort(out, function(a, b) return a.un < b.un end)
  return out
end

--- Every installation linked to this one: the whole force's battery on this
--- surface. The panel's controls all act on this list, because the
--- installations are permanently linked -- one designation turns them all, one
--- CONFIRM fires them all (scripts/alpha.lua).
function battery_recs(rec)
  return schema.crew(rec)
end

--- The crew, memoised per tick in schema.
function crew_of(rec)
  return schema.crew(rec)
end

--- The battery's power history, summed sample for sample. Every installation
--- samples on the same refresh tick (the loop at the foot of this file), so the
--- histories are index-aligned from the NEWEST end; a gun built mid-charge has a
--- shorter one and aligning from the left would slide its samples into the
--- wrong bars.
function battery_hist(rec)
  local crew = crew_of(rec)
  if #crew < 2 then return rec.pg end
  local n = 0
  for _, r in ipairs(crew) do
    local h = r.pg
    if h and #h > n then n = #h end
  end
  local out = {}
  for i = 1, n do
    local v = 0
    for _, r in ipairs(crew) do
      local h = r.pg
      local j = h and (#h - n + i) or 0
      if j >= 1 then v = v + h[j] end
    end
    out[i] = v
  end
  return out
end

--- The crew member carrying a marked sweep span, if any.
-- MUST search the crew: the designator marks the installation NEAREST the drag
-- (scripts/remote.lua), rarely the one the panel speaks for.
function sweep_rec(rec)
  if not rec.arc_sweep_mode then return nil end
  if arcsweep.pending(rec) then return rec end
  for _, r in ipairs(crew_of(rec)) do
    if r.arc_sweep_mode and arcsweep.pending(r) then return r end
  end
  return nil
end

--- What the battery is charging toward, and what it holds, in joules. The
--- order is the members actually on the tape; with none on it, it is what
--- pressing FIRE would cost the grid.
function battery_energy(rec)
  local goal, have, firing = 0, 0, 0
  local crew = crew_of(rec)
  for _, r in ipairs(crew) do
    have = have + turret.available_energy(r)
    if r.state == turret.FIRE and not r.discharged then
      goal = goal + turret.spool_goal(r)
      firing = firing + 1
    end
  end
  if firing == 0 then goal = turret.spool_goal(rec) * #crew end
  return goal, have
end

--- THE INSTALLATION THE PANEL SPEAKS FOR. Lowest unit_number, so it is stable
--- across builds and losses and the panel does not hop between guns. It is a
--- representative, not the target: every control fans out over battery_recs,
--- and every number on the row is a battery sum.
local function lead(rows)
  return rows[1]
end

local function hud_caption(rec)
  if rec.short_banks then
    return {"oppenheimer.no-pylons-count",
            tostring(rec.short_banks), tostring(C.pylon.count)}
  end
  return status_of(rec)
end

-- =============================================================================
-- THE RATE CONTROLS
--
-- The player sets a charge RATE in watts and the shot is rate x the charge
-- window, so the dial asks what their power plant can carry. The drop-down
-- labels each rung by its power, with FULL and MAX as landmarks.
-- =============================================================================

--- A rate as a short human string. C.fmt_rate.
function fmt_rate(w)
  return C.fmt_rate(w)
end

--- An energy as a short human string.
function fmt_energy(j)
  if j >= 1000000000 then
    return string.format("%.1f GJ", j / 1000000000)
  end
  return string.format("%d MJ", math.floor(j / 1000000 + 0.5))
end

--- Yield as TNT equivalent from a TRIGGER energy in joules, run through the
--- chain reaction (C.yield.of): what the device releases, not what the banks
--- hand it. Scaled units because the dial spans six orders of magnitude.
function fmt_yield(trigger_j)
  local t = C.yield.tonnes(trigger_j)
  if t >= 1000000 then return string.format("%.1f Mt", t / 1000000) end
  if t >= 1000    then return string.format("%.1f kt", t / 1000)    end
  if t >= 10      then return string.format("%.0f t",  t)           end
  return string.format("%.1f t", t)
end

-- Real devices. A rung within MILESTONE_TOLERANCE of one takes its name; any
-- other is quoted as a multiple of the biggest device it exceeds, never as a
-- match. Yields are published figures, in tonnes of TNT equivalent.
local MILESTONES = {
  {t =       11, key = "moab"},        -- GBU-43/B MOAB, ~11 t
  {t =    15000, key = "hiroshima"},   -- Little Boy, ~15 kt
  {t =    21000, key = "nagasaki"},    -- Fat Man, ~21 kt
  {t =  1200000, key = "b83"},         -- B83, 1.2 Mt
  {t =  9000000, key = "b53"},         -- B53, 9 Mt
  {t = 15000000, key = "castle-bravo"},-- Castle Bravo, 15 Mt
  {t = 50000000, key = "tsar-bomba"},  -- Tsar Bomba, ~50 Mt
}

-- A name shows within this fraction of a device's yield: half the gap between
-- the two closest devices (15 kt and 21 kt), so no rung is inside two.
local MILESTONE_TOLERANCE = 0.12

--- The biggest shot the banks actually standing can HOLD, in joules. Capacity,
--- not intake: intake is sized off C.pylon_input, so a
--- part-built installation can take any rate the dial offers and then simply
--- run out of somewhere to put it -- which is the ceiling bank count really
--- imposes, and the one pylon.set_buffer clamps against.
function bank_ceiling(rec)
  return turret.linked_count(rec) * C.pylon_buffer()
end

--- A warning caption when the order is above what the banks can hold, "" if not.
function overdraw_of(rec)
  local cap = bank_ceiling(rec)
  if cap <= 0 then return "" end
  -- A hair of tolerance: a full build's capacity sits just above max_shot.
  if turret.spool_goal(rec) <= cap * 1.0001 then return "" end
  return {"oppenheimer.rate-overdraw", fmt_energy(cap),
          tostring(turret.linked_count(rec)), tostring(C.pylon.max_count)}
end

--- Installations on this surface, then the force's total against the researched
--- capacity, or "" once fully researched.
function cap_note(force, here)
  local cap = C.capacity(force)
  local top = 1 + C.tech.capacity_levels
  if cap >= top then return "" end
  return {"oppenheimer.capacity-note", tostring(here), tostring(alpha.count(force)),
          tostring(cap), tostring(top)}
end

--- The milestone this trigger energy is standing on, or nil for "between".
function milestone_of(trigger_j)
  local t = C.yield.tonnes(trigger_j)
  if t <= 0 then return nil end
  for _, m in ipairs(MILESTONES) do
    if math.abs(t - m.t) <= m.t * MILESTONE_TOLERANCE then
      return {"oppenheimer.milestone-" .. m.key}
    end
  end
  return nil
end

--- A landmark tag for a shot: the device it matches, else a multiple of the biggest device it exceeds, else "" below the smallest.
local function landmark_of(trigger_j)
  local m = milestone_of(trigger_j)
  if m then return m end
  local t = C.yield.tonnes(trigger_j)
  local base
  for _, d in ipairs(MILESTONES) do
    if d.t <= t then base = d end
  end
  if not base then return "" end
  local n = t / base.t
  return {"oppenheimer.milestone-multiple", string.format(n < 100 and "%.1f" or "%.0f", n),
          {"oppenheimer.milestone-name-" .. base.key}}
end

--- Trigger energy of the top of the dial when `n` installations converge.
local function top_shot(n)
  return math.min(C.charge.overcharge_max * n, C.charge.group_cap) * C.charge.cost_per_shot
end

--- The rate drop-down's tooltip: the fixed help, then the top of the dial for the battery standing, for what research allows now, and for the full battery.
local function rate_tip(force, lances)
  local top     = C.beam.convergence.max_lances
  local allowed = math.min(C.capacity(force), top)
  local function line(key, n)
    local shot = top_shot(n)
    return {"oppenheimer." .. key, tostring(n), fmt_yield(shot), landmark_of(shot)}
  end
  local tip = {"", window_tip("rate-help"), "\n", line("rate-bat-now", lances)}
  if allowed > lances then
    tip[#tip + 1] = "\n"
    tip[#tip + 1] = line("rate-bat-cap", allowed)
  end
  if top > math.max(allowed, lances) then
    tip[#tip + 1] = "\n"
    tip[#tip + 1] = line("rate-bat-top", top)
  end
  return tip
end

--- The crater this trigger energy digs, in tiles: C.yield.radius, the same
--- function the sweep and the designator rings use.
function fmt_radius(trigger_j)
  return tostring(math.floor(C.yield.radius(trigger_j) + 0.5))
end

--- Peak overpressure at the rim of the crater, in psi. `order_j` sets the
--- radius the yield is confined to; `trigger_j` is what was delivered into it.
function fmt_rim_psi(trigger_j, order_j)
  local frac = (trigger_j or 0) / C.charge.cost_per_shot
  if frac <= 0 then return "0" end
  local r   = C.yield.radius_for_fraction((order_j or trigger_j) / C.charge.cost_per_shot)
  local z   = r * C.yield.tile_metres / (C.yield.kg_for_fraction(frac) ^ (1 / 3))
  local psi = C.blast.rings.overpressure_bar(z) / 0.0689476
  if psi >= 10 then return string.format("%.0f", psi) end
  return string.format("%.1f", psi)
end

--- How much yield the battery puts into the crater one installation dialled,
--- as a compact tag, or "" for a lone gun. NOT the dose multiplier: that comes
--- out of Brode in dose_at and is far larger.
function fmt_concentration(trigger_j, order_j)
  if not (order_j and order_j > 0) then return "" end
  local w = (trigger_j or 0) / order_j
  if w <= 1.001 then return "" end
  return string.format("  ·  [color=255,170,60]×%.0f YIELD[/color]", w)
end

--- What a shot kills at the rim of its crater, in hit points through
--- resistance. Same two energies as fmt_rim_psi.
function fmt_rim_kill(trigger_j, order_j)
  local f = (trigger_j or 0) / C.charge.cost_per_shot
  if f <= 0 then return "0" end
  local r  = C.yield.radius_for_fraction((order_j or trigger_j) / C.charge.cost_per_shot)
  local hp = C.blast.rings.dose_at(1.0, f, r)
  if hp >= 1000 then return string.format("%.0fk", hp / 1000) end
  return string.format("%.0f", hp)
end

--- What the rate drop-down offers: one row per rung, then a Custom row.
--
-- A row reads power, crater, yield, then tags: OP above FULL, and a landmark
-- (FULL, MAX, or a real device near that yield). Custom is always last, so
-- the indices do not depend on what a save carries; picking it does nothing.
--
-- CRITICAL: the rate and the crater are per installation; the yield is the
-- converged group's. The dial buys area, the battery buys pressure inside it.
-- @param lances number how many converge, capped at C.beam.convergence.max_lances
function rate_items(lances)
  local items = {}
  local rungs = C.power.rate_presets
  local n = math.max(1, math.min(lances or 1, C.beam.convergence.max_lances))
  for i, w in ipairs(rungs) do
    local frac = w / C.power.reference_rate
    local order = frac * C.charge.cost_per_shot
    local shot = math.min(frac * n, C.charge.group_cap) * C.charge.cost_per_shot
    local mark
    if i == #rungs then
      local landmark = landmark_of(shot)
      mark = landmark == "" and {"oppenheimer.rate-max"}
             or {"", {"oppenheimer.rate-max"}, "  ·  ", landmark}
    elseif math.abs(frac - 1) < 1e-9 then
      mark = {"oppenheimer.rate-full"}
    else
      local landmark = landmark_of(shot)
      mark = landmark ~= "" and landmark or nil
    end
    items[#items + 1] = {"",
      {n > 1 and "oppenheimer.rate-option-each" or "oppenheimer.rate-option",
       fmt_rate(w), fmt_radius(order), fmt_yield(shot)},
      fmt_concentration(shot, order),
      mark and {"", "  ·  ", mark} or ""}
  end
  items[#items + 1] = {"oppenheimer.rate-custom"}
  return items
end

--- Which drop-down index a record's current rate corresponds to: its rung, or
--- the Custom row (last) for a rate that matches none, as in an older save.
function rate_index(rec)
  local current = turret.rate(rec)
  for i, w in ipairs(C.power.rate_presets) do
    -- Exact compare is safe: both sides come from C.power.rate_presets by way of
    -- C.clamp_rate, which does not do arithmetic on a value in range.
    if w == current then return i end
  end
  return #C.power.rate_presets + 1
end


--- Which side of the TEST/LIVE switch is up. Left is TEST, the safe one.
function mode_state(rec)
  return (rec.fire_mode == "test") and "left" or "right"
end

--- The switch's style.
-- CRITICAL: a switch_style colours whichever side is active, so green-on-TEST
-- and red-on-LIVE needs one style per side.
function mode_style(rec)
  return (rec.fire_mode == "test") and N.style.switch_test or N.style.switch_live
end

--- Is this installation in a state where CONFIRM means anything? State only:
--- MUST NOT test alignment, or the button greys out while the barrel slews;
--- turret.release refuses an unaligned shot and says why.
local function live_now(rec)
  if rec.state == turret.AIM then return true end
  local sw = sweep_rec(rec)
  return sw ~= nil and sw.state == turret.STANDBY
end

--- What CONFIRM does if pressed now, and the button says which: TEST prepares
--- the zone, LIVE fires on one press (release warns on an unprepared zone).
function release_caption(rec)
  if sweep_rec(rec) then
    return {"oppenheimer.fc-release-sweep"}
  end
  if rec.fire_mode == "test" then
    return {"oppenheimer.fc-release-prepare"}
  end
  return {"oppenheimer.fc-release"}
end

-- =============================================================================
-- Structure
--
-- Built once per signature change, then written to in place. See the header: a
-- control destroyed and recreated under the cursor eats the click, so the 4 Hz
-- refresh may not touch the tree.
-- =============================================================================

--- One installation's controls. Element names are unique among SIBLINGS only,
--- so every row reuses the same names and identity rides in the tags.
--
-- THREE LINES, in the order a gunner reads them:
--
--   1  state, then every toggle that decides what the buttons below MEAN
--      (TEST/LIVE, laser sweep, designator lock)
--   2  the dial, FIRE, ABORT -- the controls that do something irreversible,
--      on their own line, never mixed in with the toggles
--   3  telemetry: charge percent, the energy behind it, a bar, and the live
--      power graph
--
-- plus a fourth line that exists only when there is something to say (the
-- blast-zone survey, a bank ceiling, a research cap), written as an EMPTY
-- CAPTION rather than a hidden element -- an element that appears and
-- disappears reflows the row under the cursor four times a second, which is
-- the same class of problem as rebuilding a control mid-click.
--
-- Everything here uses the mod's own styles (prototypes/style.lua): silent,
-- 24 px tall, no 108 px minimum width. The stock controls are a click track
-- and a wall of padding on a panel that has a row per installation.
local function build_row(parent, entry, focused)
  local rec = entry.rec

  -- The focused row -- the turret whose window the player currently has open --
  -- is the one deeper frame on the panel. With a battery on screen, "which one
  -- am I looking at" has to be answerable without reading unit numbers.
  local row = parent.add{
    type = "frame", direction = "vertical",
    style = focused and "inside_deep_frame" or "inside_shallow_frame",
  }
  row.style.horizontally_stretchable = true
  row.style.padding = 4

  -- `vertical_spacing` is a Table/Flow/VerticalFlow/TabbedPane style
  -- property -- a Frame's own style rejects it outright ("Expected Table or
  -- Flow or VerticalFlow or TabbedPane style type but was Frame"), so the
  -- lines below live in an inner flow that carries the spacing, not on `row`.
  local body = row.add{type = "flow", name = "body", direction = "vertical"}
  body.style.horizontally_stretchable = true
  body.style.vertical_spacing = 2

  -- LINE 1: state, then the mode toggles.
  local hdr = body.add{type = "flow", name = "hdr", direction = "horizontal"}
  hdr.style.vertical_align = "center"
  hdr.style.horizontally_stretchable = true

  hdr.add{type = "label", name = "st", caption = hud_caption(rec)}
  local filler = hdr.add{type = "empty-widget"}
  filler.style.horizontally_stretchable = true

  -- TEST/LIVE is a switch, not a button: it selects what FIRE means.
  local md = hdr.add{type = "switch", name = N.gui.fire_mode,
          style = mode_style(rec),
          switch_state = mode_state(rec),
          left_label_caption  = {"oppenheimer.fc-mode-test"},
          left_label_tooltip  = {"oppenheimer.fc-mode-test-tip"},
          right_label_caption = {"oppenheimer.fc-mode-live"},
          right_label_tooltip = {"oppenheimer.fc-mode-live-tip"},
          tags = {oppenheimer_unit = entry.un}}
  md.enabled = rec.state == turret.STANDBY or rec.state == turret.AIM

  -- LASER SWEEP (it was "Arc Sweep" in the panel and nowhere else; the player
  -- has never seen the word "arc" in any other control).
  hdr.add{type = "button", name = N.gui.arc_sweep_toggle,
          style = rec.arc_sweep_mode and N.style.button_green or N.style.button_red,
          caption = {"oppenheimer.fc-sweep"},
          tooltip = {"oppenheimer.fc-sweep-tip"},
          enabled = rec.state == turret.STANDBY,
          tags = {oppenheimer_unit = entry.un}}


  -- LINE 2: the dial and the two controls that commit.
  local rec_e = rec.entity
  local force = rec_e and rec_e.valid and rec_e.force or nil
  local ctl = body.add{type = "flow", name = "ctl", direction = "horizontal"}
  ctl.style.vertical_align = "center"

  local lances = #crew_of(rec)
  local yd = ctl.add{
    type = "drop-down", name = "yd",
    style = N.style.dropdown,
    items = rate_items(lances),
    selected_index = rate_index(rec),
    tooltip = rate_tip(force, lances),
    tags = {oppenheimer_unit = entry.un, lances = lances, cap = C.capacity(force)},
  }
  yd.style.horizontally_stretchable = true
  yd.style.minimal_width = 300

  ctl.add{type = "button", name = N.gui.fire_release,
          style = N.style.button_fire,
          caption = release_caption(rec),
          tooltip = window_tip("fc-release-tip"),
          enabled = live_now(rec),
          tags = {oppenheimer_unit = entry.un}}

  ctl.add{type = "button", name = N.gui.fire_abort,
          style = N.style.button_red,
          caption = {"oppenheimer.fc-abort"},
          tooltip = {"oppenheimer.fc-abort-tip"},
          enabled = live_now(rec) or rec.state == turret.FIRE,
          tags = {oppenheimer_unit = entry.un}}

  -- LINE 3: telemetry. Charge percent and energy, a slim bar, and the graph.
  local tel = body.add{type = "flow", name = "tel", direction = "horizontal"}
  tel.style.vertical_align = "center"
  tel.style.horizontal_spacing = 6

  local ch = tel.add{type = "label", name = "ch", caption = charge_of(rec),
                     tooltip = {"oppenheimer.fc-charge-tip"}}
  ch.style.font = "default-semibold"
  ch.style.minimal_width = 150

  local pb = tel.add{type = "progressbar", name = "pb",
                     style = N.style.graph_bar, value = progress_of(rec)}
  pb.style.width = 120

  local dr = tel.add{type = "label", name = "dr", caption = draw_of(rec)}
  dr.style.font = "default-small"
  dr.style.font_color = {170, 170, 170}
  dr.style.minimal_width = 78

  -- THE GRAPH. One sprite element per sample, bottom-aligned, height written
  -- per refresh. Built once at full width so the row never changes shape as
  -- the history fills.
  local gr = tel.add{type = "flow", name = "gr", direction = "horizontal"}
  gr.style.horizontal_spacing = 0
  gr.style.vertical_align = "bottom"
  gr.style.height = G.height_px
  gr.tooltip = {"oppenheimer.fc-graph-tip",
                tostring(math.floor(G.samples * C.hud.refresh_ticks / 60 + 0.5)),
                fmt_rate(graph_scale(rec))}
  for i = 1, G.samples do
    local bar = gr.add{type = "sprite", name = "g" .. i,
                       sprite = N.sprite_gui.graph_dim}
    bar.style.stretch_image_to_widget_size = true
    bar.style.width = G.bar_px
    bar.style.height = 1
  end

  -- LINE 4, only when it has something to say.
  local note_caption, note_tip = note_of(rec, force)
  local note = body.add{type = "label", name = "note", caption = note_caption,
                        tooltip = note_tip}
  note.style.single_line = false
  note.style.maximal_width = 620
  note.style.font = "default-small"

  return row
end

--- Write current values into a row that already exists.
local function update_row(row, rec)
  if not (row and row.valid) then return end

  local body = row.body
  if not (body and body.valid) then return end

  local live = live_now(rec)

  local hdr = body.hdr
  if hdr and hdr.valid then
    local st = hdr.st
    if st and st.valid then st.caption = hud_caption(rec) end

    local fm = hdr[N.gui.fire_mode]
    if fm and fm.valid then
      -- A style write rebuilds the element's graphics, so only on a change.
      local want = mode_style(rec)
      if fm.style.name ~= want then fm.style = want end
      local side = mode_state(rec)
      if fm.switch_state ~= side then fm.switch_state = side end
      local can = rec.state == turret.STANDBY or rec.state == turret.AIM
      if fm.enabled ~= can then fm.enabled = can end
    end

    local sw = hdr[N.gui.arc_sweep_toggle]
    if sw and sw.valid then
      local want = rec.arc_sweep_mode and N.style.button_green or N.style.button_red
      if sw.style.name ~= want then sw.style = want end
      local standby = rec.state == turret.STANDBY
      if sw.enabled ~= standby then sw.enabled = standby end
    end

  end

  local ctl = body.ctl
  if ctl and ctl.valid then
    local rel = ctl[N.gui.fire_release]
    if rel and rel.valid then
      if rel.enabled ~= live then rel.enabled = live end
      rel.caption = release_caption(rec)
    end

    local abt = ctl[N.gui.fire_abort]
    local can_abort = live or (rec.state == turret.FIRE and not rec.discharged)
    if abt and abt.valid and abt.enabled ~= can_abort then abt.enabled = can_abort end

    -- The rate is what the sequence spends. Changing it once the charge is
    -- committed would move the finish line under a shot already running -- and
    -- worse, under a ramp that is already writing buffers against the old goal.
    local settable = (rec.state == turret.STANDBY or rec.state == turret.AIM)

    local yd = ctl.yd
    if yd and yd.valid then
      -- The lance count moves every figure on every rung, so the rows are rebuilt
      -- when it changes; the tooltip also follows research. Two number compares
      -- on every other refresh.
      local lances = #crew_of(rec)
      local rec_e  = rec.entity
      local force  = rec_e and rec_e.valid and rec_e.force or nil
      local cap    = C.capacity(force)
      local tags = yd.tags
      if tags.lances ~= lances or tags.cap ~= cap then
        if tags.lances ~= lances then yd.items = rate_items(lances) end
        yd.tooltip = rate_tip(force, lances)
        tags.lances, tags.cap = lances, cap
        yd.tags = tags
      end
      -- Written only when it actually differs, so a player mid-selection is not
      -- fighting a 4 Hz write for control of their own drop-down.
      local want = rate_index(rec)
      if yd.selected_index ~= want then yd.selected_index = want end
      if yd.enabled ~= settable then yd.enabled = settable end
    end
  end

  local tel = body.tel
  if tel and tel.valid then
    local ch = tel.ch
    if ch and ch.valid then ch.caption = charge_of(rec) end
    local pb = tel.pb
    if pb and pb.valid then pb.value = progress_of(rec) end
    local dr = tel.dr
    if dr and dr.valid then dr.caption = draw_of(rec) end
    local gr = tel.gr
    if gr and gr.valid then draw_graph(gr, rec) end
  end

  local note = body.note
  if note and note.valid then
    local rec_e = rec.entity
    local caption, tip = note_of(rec, rec_e and rec_e.valid and rec_e.force or nil)
    note.caption = caption
    note.tooltip = tip
  end
end

--- What the panel is currently built for, as one comparable string. Structure
-- is rebuilt when THIS changes and at no other time. Only the LEAD unit and the
-- battery's size are structural; which gun a player has open is not, now that
-- there is one row for the whole battery.
--- The tooltips that quote the firing sequence, filled from the sequence
--- itself. DERIVED, NEVER TYPED: the charge window is whatever the audio is
--- (C.sound.discharge_at), so a figure written into locale/*.cfg beside it goes
--- stale the first time the clip is re-cut -- which is exactly how the panel
--- came to promise a 14 second charge in four steps while the gun ran 14.7 in
--- twelve.
--
--- ONE PARAMETER LIST PER KEY, contiguous from __1__ and never repeating an
--- index -- the invariant base's own locale holds to everywhere. A shared list
--- forced these strings to skip slots and to name one slot twice, and both
--- rendered the placeholder raw at the player.
function window_tip(key)
  local secs = string.format("%.1f", C.charge_window())
  local slots
  if key == "fc-release-tip" then
    slots = {secs,
             tostring(C.sound.charge_parts),
             string.format("%.1f", C.sound.charge_window_ticks(1) / 60)}
  else
    slots = {secs, secs,
             fmt_rate(C.power.reference_rate),
             tostring(math.floor(C.yield.reference_radius + 0.5))}
  end
  local out = {"oppenheimer." .. key}
  for i = 1, #slots do out[i + 1] = slots[i] end
  return out
end

local function signature(rows)
  return tostring(rows[1] and rows[1].un or "-") .. "|" .. tostring(#rows)
end

--- How many installations are actually lined up on the designated point.
local function on_target(rows)
  local n = 0
  for _, row in ipairs(rows) do
    local r = row.rec
    if r.designated and (r.state == turret.AIM or r.state == turret.FIRE)
       and turret.aimed(r) then
      n = n + 1
    end
  end
  return n
end

function gui.refresh_hud(player)
  -- gui.screen, not gui.left: the left flow sits under the rest of the UI and
  -- is trivially missed, indistinguishable from a broken shortcut. A screen
  -- frame at a fixed position is either on screen or it is not.
  local root = player.gui.screen[HUD]

  storage.hud_hidden = storage.hud_hidden or {}
  storage.hud_sig    = storage.hud_sig or {}

  if root and root.valid and (root.tags or {}).layout ~= HUD_LAYOUT then
    root.destroy()
    root = nil
    storage.hud_sig[player.index] = nil
  end
  local rows = storage.hud_hidden[player.index] and {} or notable(player.force, player.surface)

  if #rows == 0 then
    if root and root.valid then root.destroy() end
    storage.hud_sig[player.index] = nil
    return
  end

  -- ONE ROW, whatever the battery's size. A second installation is not a second
  -- weapon -- they are permanently linked and fire together -- so a row each was
  -- the same controls stacked N deep. What the extra installations add to the
  -- panel is the multiplier on the battery line.
  local entry = lead(rows)
  local sig = signature(rows)

  if not (root and root.valid) then
    root = player.gui.screen.add{
      type = "frame", name = HUD, direction = "vertical",
      caption = {"oppenheimer.hud-title"},
      tags = {layout = HUD_LAYOUT},
    }
    root.location = {x = 12, y = 180}
    root.add{type = "label", name = N.gui.hud_bar}
    root.add{type = "flow", name = N.gui.hud_list, direction = "vertical"}
    storage.hud_sig[player.index] = nil
  end

  local bar = root[N.gui.hud_bar]
  if bar and bar.valid then
    bar.style.font = "default-semibold"
    -- Only shown once there is a battery: a single installation reads as
    -- itself, not as "1 of 1".
    --
    -- CRITICAL: xN is the ON-TARGET count, not the roster. Only lances that
    -- ignite at the same point join one strike.
    local owned = tostring(alpha.count(player.force))
    local cap = tostring(C.capacity(player.force))
    if #rows > 1 then
      local aimed = math.min(on_target(rows), C.beam.convergence.max_lances)
      local draw = fmt_rate(turret.rate(entry.rec) * #rows)
      bar.caption = (aimed > 1)
        and {"oppenheimer.hud-battery-many", tostring(#rows),
             tostring(aimed), draw, owned, cap}
        or {"oppenheimer.hud-battery-idle", tostring(#rows),
            tostring(on_target(rows)), draw, owned, cap}
    else
      bar.caption = {"oppenheimer.hud-battery-one", owned, cap}
    end
  end

  local list = root[N.gui.hud_list]
  if not (list and list.valid) then return end

  if storage.hud_sig[player.index] ~= sig then
    list.clear()
    build_row(list, entry, true)
    storage.hud_sig[player.index] = sig
  else
    update_row(list.children[1], entry.rec)
  end
end

-- =============================================================================
-- Live refresh
--
-- A spool is 20-30 seconds long and the whole point of the panel is watching it
-- fill. Only values move; the tree is left alone (see Structure, above).
-- =============================================================================

events.on_nth_tick(C.hud.refresh_ticks, function()
  profile.start("hud refresh + power sample")
  -- ONE SAMPLE PER INSTALLATION PER REFRESH, before any player is drawn: the
  -- graph is per installation, not per player, and closing the window must
  -- not put a hole in its history. Cheap and deterministic (it reads only
  -- what turret.power_tick already measured).
  for _, rec in pairs(storage.turrets or {}) do
    turret.power_sample(rec)
  end
  for _, player in pairs(game.connected_players) do
    gui.refresh_hud(player)
  end
  profile.stop("hud refresh + power sample")
end)

--- #107: the shortcut-bar toggle. `toggled` has to be pushed back onto the
--- button or it springs visually out of sync with what the HUD is doing.
function gui.on_shortcut(event)
  if event.prototype_name ~= N.gui.hud_toggle then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  gui.toggle_hud(player)
end

--- Flip the HUD for one player, and SAY what happened.
--
-- The panel defaults to visible, so the first press of the shortcut HIDES it --
-- which from the player's side is a button that does nothing except when it
-- makes something disappear. Printing the new state means a press always has a
-- visible result, even when the result is "hidden", and it separates "the
-- shortcut is not firing" from "the panel is somewhere I am not looking".
function gui.toggle_hud(player)
  storage.hud_hidden = storage.hud_hidden or {}
  local hidden = not storage.hud_hidden[player.index]
  storage.hud_hidden[player.index] = hidden or nil
  player.set_shortcut_toggled(N.gui.hud_toggle, not hidden)
  gui.refresh_hud(player)

  if hidden then
    audio.notify(player, {"oppenheimer.hud-off"})
  elseif not (player.gui.screen[HUD] and player.gui.screen[HUD].valid) then
    -- Shown, but there was nothing to show: no installation on this surface.
    audio.notify(player, {"oppenheimer.hud-empty"})
  else
    audio.notify(player, {"oppenheimer.hud-on"})
  end
end

events.on(defines.events.on_lua_shortcut,              gui.on_shortcut)
events.on(defines.events.on_gui_opened,                gui.on_opened)
events.on(defines.events.on_gui_closed,                gui.on_closed)
events.on(defines.events.on_gui_selection_state_changed, gui.on_selection)
events.on(defines.events.on_gui_switch_state_changed,  gui.on_switch)
events.on(defines.events.on_gui_click,                 gui.on_click)

return gui
