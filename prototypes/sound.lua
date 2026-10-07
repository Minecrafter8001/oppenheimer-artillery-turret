-- prototypes/sound.lua -----------------------------------------------------------
-- The installation's voice: standalone `sound` prototypes the control stage plays
-- by NAME. Ogg Vorbis only. audible_distance_modifier carries a sound across the
-- map; the spec says 0..1, but base ships up to 6.25 and it loads.
----------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local s = C.sound

data:extend({
  -- THE SPIN-UP, IN C.sound.charge_parts PIECES. tools/split_sequence.py cuts
  -- the first C.sound.charge_source_ticks of assets-src CompleteSequence.ogg
  -- into equal pieces of C.sound.charge_segment_ticks and joins them by the
  -- rule in config.lua's C.sound header. scripts/turret.lua's fire_tick plays the LAST k of them,
  -- each gated on the turret still being in FIRE, so an abort only ever lets
  -- whichever piece is already playing run out.
  --
  -- The paths are written out one per line, not built with a loop: a missing
  -- sound path is a HARD load error and verify.py check 11 can only resolve a
  -- literal against the disk. Keep this list, N.sound.charge and
  -- tools/split_sequence.py's PARTS in step.
  {
    type = "sound",
    name = N.sound.charge[1],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge01.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[2],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge02.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[3],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge03.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[4],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge04.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[5],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge05.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[6],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge06.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[7],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge07.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[8],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge08.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[9],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge09.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[10],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge10.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[11],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge11.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },
  {
    type = "sound",
    name = N.sound.charge[12],
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamCharge12.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },

  -- THE BURN, ONE UNCUT PIECE (tools/split_sequence.py). Played once from
  -- turret.lua's discharge() at the exact tick the lance ignites -- never at
  -- CONFIRM, and never on a misfire or an abort, both of which return out of
  -- discharge() before beam.fire is attempted. It was three joined pieces while
  -- an overpressure lance could outburn the recording; the burn is now the same
  -- length at every yield, so there is nothing left for a join to buy. Own
  -- volume knob (s.strike_volume): this is the payoff, not a continuation of
  -- whatever the spin-up's mix settles on.
  {
    type = "sound",
    name = N.sound.strike,
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamStrike.ogg",
    volume = s.strike_volume,
    audible_distance_modifier = s.strike_distance,
    category = "weapon",
  },

  -- THE SPIN-DOWN, ONE UNCUT PIECE (tools/split_sequence.py). The spin-up run
  -- backwards, played once from turret.stand_down() at the cut, gated on the
  -- shot having actually discharged -- so an abort vents in silence, because
  -- nothing spun up far enough to wind down.
  {
    type = "sound",
    name = N.sound.spindown,
    filename = "__oppenheimer-artillery-turret-forked__/sound/BeamSpindown.ogg",
    volume = s.spindown_volume,
    audible_distance_modifier = s.spindown_distance,
    category = "weapon",
  },

  -- UNUSED, kept as a hook. Nothing calls play(rec, N.sound.fire): the burn
  -- carries its own ignition, and a cannon report layered over it muddied the
  -- one frame in the sequence that has to land clean.

  -- THE DETONATION'S BOOM, AS AN ADDRESSABLE PROTOTYPE.
  --
  -- The same file N.ex_boom plays, defined a second time as a standalone
  -- SoundPrototype -- because an ExplosionPrototype's embedded `sound` cannot be
  -- named by a SoundPath and therefore cannot be broadcast. The explosion keeps
  -- its own copy as the near-field layer; scripts/detonate.lua plays THIS one
  -- globally, which is what carries the bang to someone watching from the map.
  --
  -- WAS __base__/sound/fight/large-explosion-1.ogg -- a small stock effect
  -- built for an in-world explosion a few tiles across, playing over a
  -- detonation up to 2000 tiles wide. Reported as a mismatch, and it was: the
  -- clip is short enough that it finishes while the Sedov wave is still in its
  -- first few percent of travel, so twenty-plus seconds of a still-unfolding
  -- blast played out in silence. Replaced with sound/ImplosionBoom.ogg
  -- (10.500 s = 630 ticks, oggdur.py) -- do not round that number if this file
  -- changes again. A SEPARATE RECORDING: tools/split_sequence.py never touches
  -- it, and the mix's own tail is the lance spinning down, not this.
  -- scripts/detonate.lua's thunder() scales the volume by the shot's yield
  -- (C.sound.boom_volume_floor/_exponent) since the engine cannot truncate a
  -- playing sound (see scripts/beam.lua's note on play_sound having no
  -- stop/mute member) -- a small shot gets a quieter hit, not a shorter one.
  --
  -- audible_distance_modifier is set but does nothing while the broadcast is on:
  -- a non-positional sound has no distance for it to modify. It is here so that
  -- C.sound.broadcast.enabled = false falls back to a world sound that still
  -- carries, rather than to one audible from thirty tiles.
  {
    type = "sound",
    name = N.sound.boom,
    filename = "__oppenheimer-artillery-turret-forked__/sound/ImplosionBoom.ogg",
    volume = s.boom_volume,
    -- s.fire_distance (6) rather than C.blast.sound.far_distance_modifier (8),
    -- and the difference matters for a reason that is documented in this file's
    -- header: the 2.0.77 spec claims SoundPrototype.audible_distance_modifier
    -- "must be between 0 and 1", base itself ships 2.25 / 3 / 4 / 6.25, and the
    -- game loads those -- so the doc string is wrong and values above 1 are
    -- fine. What is NOT established is how far above. 6 is inside the range base
    -- proves, and this mod's own N.sound.fire has shipped at 6 on a real load.
    -- The 8 on N.ex_boom is a `Sound` inside an explosion, which the spec gives
    -- no upper bound at all -- a different field with a different rule.
    --
    -- It is dead weight while the broadcast is on anyway: a non-positional sound
    -- has no distance for this to modify. It only matters as the fallback.
    audible_distance_modifier = s.fire_distance,
    category = "explosion",
    aggregation = {max_count = 1, remove = true},
  },

  {
    type = "sound",
    name = N.sound.fire,
    volume = s.fire_volume,
    audible_distance_modifier = s.fire_distance,
    category = "weapon",
    variations = {
      {filename = "__base__/sound/fight/artillery-shoots-1.ogg"},
      {filename = "__base__/sound/fight/artillery-shoots-2.ogg"},
    },
  },

  -- THE FIRE WAVE'S DAMAGE. Played by scripts/beam.lua through the
  -- broadcast while the inner fire front is burning through something -- the
  -- stage has no visuals (it is inside an opaque ball), so this is how it is
  -- known to be working. Base's fire impact set, all five.
  {
    type = "sound",
    name = N.sound.sear,
    volume = s.sear_volume,
    audible_distance_modifier = s.fire_distance,
    category = "explosion",
    aggregation = {max_count = 2, remove = true},
    variations = {
      {filename = "__base__/sound/fight/fire-impact-1.ogg"},
      {filename = "__base__/sound/fight/fire-impact-2.ogg"},
      {filename = "__base__/sound/fight/fire-impact-3.ogg"},
      {filename = "__base__/sound/fight/fire-impact-4.ogg"},
      {filename = "__base__/sound/fight/fire-impact-5.ogg"},
    },
  },

  -- IDEA C, THE ARC SWEEP -- played once as the barrel begins hyper-
  -- rotating. The sweep's own rotation duration (C.arc_sweep.sustain_ticks)
  -- is locked to this clip's measured length, not the other way round --
  -- same rule the main firing sequence's own clock follows.
  {
    type = "sound",
    name = N.sound.arc_sweep,
    filename = "__oppenheimer-artillery-turret-forked__/sound/ArcSweep.ogg",
    volume = s.strike_volume,
    audible_distance_modifier = s.strike_distance,
    category = "weapon",
  },

  -- THE ARC SWEEP'S OWN CHARGE-UP -- played once at CONFIRM, before the
  -- rotation begins. C.arc_sweep.charge_ticks is locked to this clip too.
  {
    type = "sound",
    name = N.sound.arc_sweep_charge,
    filename = "__oppenheimer-artillery-turret-forked__/sound/ArcSweepCharge.ogg",
    volume = s.charge_volume,
    audible_distance_modifier = s.charge_distance,
    category = "weapon",
  },

  -- The interface voices. category "gui-effect" so the player's own interface
  -- volume slider governs them; played globally, never positioned.
  {type = "sound", name = N.sound.ui_click,  category = "gui-effect", volume = s.ui.button_volume,
   filename = "__oppenheimer-artillery-turret-forked__/sound/ui-click.ogg"},
  {type = "sound", name = N.sound.ui_select, category = "gui-effect", volume = s.ui.button_volume,
   filename = "__oppenheimer-artillery-turret-forked__/sound/ui-select.ogg"},
  {type = "sound", name = N.sound.ui_arm,    category = "gui-effect", volume = s.ui.volume,
   filename = "__oppenheimer-artillery-turret-forked__/sound/ui-arm.ogg"},
  {type = "sound", name = N.sound.ui_notice, category = "gui-effect", volume = s.ui.volume,
   filename = "__oppenheimer-artillery-turret-forked__/sound/ui-notice.ogg"},
  {type = "sound", name = N.sound.ui_ok,     category = "gui-effect", volume = s.ui.volume,
   filename = "__oppenheimer-artillery-turret-forked__/sound/ui-ok.ogg"},
  {type = "sound", name = N.sound.ui_alert,  category = "gui-effect", volume = s.ui.volume,
   filename = "__oppenheimer-artillery-turret-forked__/sound/ui-alert.ogg"},
})

-- The lightning's thunder, one per strike level (tools/make_thunder.py). Literal paths so verify.py check 11 can resolve each.
local THUNDER = {
  [2]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel02.ogg",
  [3]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel03.ogg",
  [4]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel04.ogg",
  [5]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel05.ogg",
  [6]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel06.ogg",
  [7]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel07.ogg",
  [8]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel08.ogg",
  [9]  = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel09.ogg",
  [10] = "__oppenheimer-artillery-turret-forked__/sound/ThunderLevel10.ogg",
}

local thunder = {}
for level, file in pairs(THUNDER) do
  local vol = s.thunder_volume
  if level >= 7 then
    vol = s.thunder_volume * 0.5
  end
  thunder[#thunder + 1] = {
    type = "sound",
    name = N.sound.thunder[level],
    filename = file,
    volume = vol,
    audible_distance_modifier = s.fire_distance,
    category = "explosion",
  }
end
data:extend(thunder)
