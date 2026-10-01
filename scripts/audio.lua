-- scripts/audio.lua: Non-positional sound with custom distance falloff from config.
--
-- WHAT IS GIVEN UP, honestly: stereo panning and any sense of direction. A
-- global sound is in your head rather than over your shoulder. For a 21 second
-- charge sequence and a megaton detonation that is the right trade -- both are
-- the sound of the sky rather than the sound of a thing at a bearing -- and
-- C.sound.broadcast.keep_positional puts the located layer back for anyone who
-- disagrees.
--
-- DETERMINISM. Sound is client-side and affects nothing the simulation reads, so
-- iterating connected players and computing per-player volumes cannot desync --
-- but note that this is exactly the kind of loop that WOULD desync if it ever
-- wrote to storage or decided anything. It does neither. It reads positions and
-- calls play_sound.
----------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local audio = {}

--- Distance from a player to a point, taking the NEARER of body and camera.
--
-- 2.0 splits the two: `position` is where the controller is looking from (in
-- remote view, potentially the far side of the planet) and `physical_position`
-- is where the character actually stands. Neither alone is right. A player in
-- remote view watching the target expects to hear the target; a player standing
-- next to the gun with the camera elsewhere expects to hear the gun. Taking the
-- minimum gives both, and the failure mode of being too generous with a sound is
-- that someone hears something impressive.
--
-- `to` makes the event a LINE rather than a point, and it is not a nicety: the
-- firing sequence is emitted at the muzzle while the thing the player is
-- watching is the target, thousands of tiles away at full dial. Measured from
-- the muzzle alone the whole spin-up fell off the end of broadcast.max_distance
-- for anyone watching their own shot land, while the detonation -- which is
-- emitted at the target -- came through at full volume. A lance IS its whole
-- length; a listener at either end, or beside it, is at the event.
--
-- @return number|nil distance in tiles, or nil if the player is not on this
--         surface by either measure
function audio.hearing_distance(player, surface_index, x, y, to)
  local best

  -- Point to segment (x,y)->to, or to the point itself when there is no `to`.
  local function reach(pos)
    local dx, dy = pos.x - x, pos.y - y
    if to then
      local ex, ey = to.x - x, to.y - y
      local len2 = ex * ex + ey * ey
      if len2 > 1e-9 then
        local t = (dx * ex + dy * ey) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        dx, dy = dx - ex * t, dy - ey * t
      end
    end
    return math.sqrt(dx * dx + dy * dy)
  end

  local function consider(pos, idx)
    if not pos or idx ~= surface_index then return end
    local d = reach(pos)
    if not best or d < best then best = d end
  end

  consider(player.position, player.surface_index)
  -- physical_* is nil for a player who has no character at all (an editor or
  -- spectator controller), which is not an error -- it just means the camera is
  -- the only listener they have.
  consider(player.physical_position, player.physical_surface_index)

  return best
end

--- Volume for one listener, 0..1, from C.sound.broadcast's curve.
--
-- Flat inside `full_distance` -- close enough is close enough, and a falloff
-- that starts at zero distance makes the near field quieter than the engine's
-- own model did, which would fix the reported problem by introducing its mirror
-- image. Then it falls to zero at `max_distance` on `curve`: above 1 it holds
-- loud and drops late (a big diffuse boom), below 1 it drops immediately and
-- trails off (a sharp local crack).
local function volume_at(d, b)
  if d <= b.full_distance then return 1.0 end
  if d >= b.max_distance then return 0.0 end
  local t = (d - b.full_distance) / (b.max_distance - b.full_distance)
  local v = (1 - t) ^ b.curve
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end

--- Play `path` for ONE player at a computed volume. The per-listener half of
--- broadcast(), split out so a caller can schedule arrivals individually.
--
-- EXISTS FOR THUNDER. Sound travels and light does not, so a detonation does not
-- arrive at the same tick for everybody -- see C.sound.boom_speed. broadcast()
-- plays for everyone on one tick, which is right for a firing sequence that
-- starts where the player already is and wrong for a bang 2000 tiles away.
function audio.to_player(player, surface_index, pos, path, opts)
  if not (player and player.valid and pos and path) then return end
  local b = C.sound.broadcast
  opts = opts or {}

  local d = audio.hearing_distance(player, surface_index, pos.x, pos.y, opts.to)
  if not d then return end

  local reach = opts.max_distance or b.max_distance
  local full  = opts.full_distance or b.full_distance
  local v = volume_at(d, {
    full_distance = full,
    max_distance  = math.max(reach, full + 1),
    curve         = b.curve,
  }) * (opts.volume or 1.0) * b.volume
  if v <= 0.01 then return end

  player.play_sound{
    path = path,
    volume_modifier = math.min(1, v),
    override_sound_type = b.override_sound_type,
  }
end

--- Play `path` so it is heard for real distances rather than for camera ones.
--
-- @param surface LuaSurface
-- @param pos     table    where the event happened
-- @param path    string   SoundPath -- a `sound` prototype name works, which is
--                         why prototypes/sound.lua defines standalone ones
-- @param opts    table|nil {volume = 0..1, max_distance = tiles, full_distance =
--                          tiles, to = MapPosition} -- per-call overrides of
--                          C.sound.broadcast; `to` makes it a line, not a point
function audio.broadcast(surface, pos, path, opts)
  if not (surface and surface.valid and pos and path) then return end

  local b = C.sound.broadcast
  if not b.enabled then
    -- The switch restores exactly what every version before 0.16.0 did, in one
    -- word, rather than leaving two code paths that have to be kept in step.
    surface.play_sound{path = path, position = pos}
    return
  end

  opts = opts or {}
  local reach = opts.max_distance or b.max_distance
  local full  = opts.full_distance or b.full_distance
  local gain  = opts.volume or 1.0

  -- A local table, not a stored one: `b` is config and must not be written, and
  -- volume_at needs the per-call overrides folded in.
  local curveset = {
    full_distance = full,
    max_distance  = math.max(reach, full + 1),
    curve         = b.curve,
  }

  -- THE LOCATED LAYER, optional and off by default. It is the pre-0.16.0
  -- behaviour kept as a layer rather than as an alternative: with both on, a
  -- player standing next to the gun hears a positioned sound AND a global one,
  -- which is louder than either and is why this is not the default.
  if b.keep_positional then
    surface.play_sound{path = path, position = pos}
  end

  local si = surface.index
  for _, player in pairs(game.connected_players) do
    local d = audio.hearing_distance(player, si, pos.x, pos.y, opts.to)
    if d then
      local v = volume_at(d, curveset) * gain * b.volume
      if v > 0.01 then
        -- NO `position` KEY. That is the entire mechanism: with one, this is a
        -- world sound and the camera decides how loud it is; without one, it is
        -- played globally and only this function decides.
        player.play_sound{
          path = path,
          volume_modifier = math.min(1, v),
          -- Usually nil, so the sound keeps its own mixer and the player's
          -- explosion/weapon volume sliders still govern it -- which is what
          -- they are for. See the note in C.sound.broadcast: if zoom mixing
          -- turns out to reach global sounds too, this is the escape hatch.
          override_sound_type = b.override_sound_type,
        }
      end
    end
  end
end

-- =============================================================================
-- Chat lines and interface voices
--
-- Every LuaPlayer/LuaForce/LuaGameScript print plays the engine's console ping
-- unless told not to, so a run of button presses or a profile report is a ping
-- per line. The mod prints with the ping off and plays one of its own soft
-- voices (C.sound.ui) at most once per min_gap ticks per voice.
-- =============================================================================

local VOICE = {
  notice = N.sound.ui_notice,
  ok     = N.sound.ui_ok,
  alert  = N.sound.ui_alert,
  arm    = N.sound.ui_arm,
}

--- Print with no sound at all: for reports and command output.
-- @param target LuaPlayer|LuaForce|LuaGameScript
function audio.print(target, message, settings)
  settings = settings or {}
  settings.sound = defines.print_sound.never
  target.print(message, settings)
end

local function listeners(target)
  local kind = target.object_name
  if kind == "LuaForce" then return target.connected_players end
  if kind == "LuaPlayer" then return {target} end
  return game.connected_players
end

--- Print `message` and play its voice. The voice comes from the message's own key
--- (`{"oppenheimer.<key>", ...}`) through C.sound.ui.say, or from `key` when the
--- message is not a plain key.
-- @param target LuaPlayer|LuaForce|LuaGameScript
function audio.notify(target, message, key)
  audio.print(target, message)
  if not key and type(message) == "table" and type(message[1]) == "string" then
    key = message[1]:match("^oppenheimer%.(.+)$")
  end
  local kind = C.sound.ui.say[key] or "notice"
  local path = VOICE[kind]
  if not path then return end

  storage.ui_voice_at = storage.ui_voice_at or {}
  -- LuaGameScript carries no `index` and reading one raises.
  local name = target.object_name
  local gate = name .. ((name ~= "LuaGameScript" and target.index) or 0) .. kind
  local last = storage.ui_voice_at[gate]
  if last and game.tick - last < C.sound.ui.min_gap then return end
  storage.ui_voice_at[gate] = game.tick
  for _, player in pairs(listeners(target)) do
    if player.valid then player.play_sound{path = path} end
  end
end

return audio
