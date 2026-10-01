-- prototypes/entity/pylon.lua -------------------------------------------------------
-- The capacitor banks. Backlog #63, #68, #72, #74.
--
-- WHY THIS ENTITY EXISTS AT ALL
-- The brief was "the turret requires power from four sides". The obvious
-- implementation -- an energy_source on the turret -- is impossible:
--
--     apiq proto ArtilleryTurretPrototype
--
-- lists every field ArtilleryTurretPrototype accepts, on itself and on both
-- parents (EntityWithOwnerPrototype, EntityWithHealthPrototype), and there is no
-- energy_source among them. Artillery turrets cannot consume power. That is not
-- a preference or a design opinion, it is the prototype.
--
-- So the power lives on companion entities, and the turret is gated in
-- control.lua on whether they are charged. Which turns out to be the better
-- design anyway:
--   * glowing banks around a huge gun is a far better silhouette than a wire
--     running to a box
--   * the charge-up time (#75) falls out for free -- fire rate IS how fast the
--     grid refills the banks (#64)
--   * killing one silences the gun (#66), so biters get real counterplay
--     against something otherwise untouchable
--
-- ============================================================================
-- WHY THESE ARE NO LONGER ACCUMULATORS
-- ============================================================================
-- They were `accumulator` from #63 until now, for three good reasons: the
-- buffer IS the stored charge, LuaEntity.energy is read/write on it, and the
-- charge animation and circuit signal came free. Two of those survive the
-- change. The other two were paying for a problem:
--
--   1. AN ACCUMULATOR IS NOT A CONSUMER, AND THE GRID KNOWS IT. The energy model
--      here is "hold the banks at zero, so the tap runs continuously, and that
--      IS the standby draw" (turret.power_tick). Under an accumulator, that tap
--      is accumulator transfer logic -- it takes SURPLUS. It never creates
--      demand: it does not make a steam engine burn more coal, it does not
--      compete with the factory, and on a grid with no headroom it silently
--      moves nothing at all. Reported exactly that way: "they still do not draw
--      from the grid while spooling charge."
--
--      This is the same wall 0.8.4 hit and 0.8.5 reverted from. The 0.8.5 note
--      was right about the mechanism and wrong about the conclusion: it said the
--      priority "is not a dial for how much a buffer draws", having tried
--      "secondary-input" ON AN ACCUMULATOR, where the accumulator transfer logic
--      still governs what actually moves. It is not a dial on an accumulator.
--      It is exactly the dial on anything else -- that is how a laser turret, a
--      buffered consumer with an identical energy source, draws real metered
--      power at "primary-input".
--
--   2. THE ACCUMULATOR STATISTIC. The electric network window sums the charge of
--      every accumulator on the network into one readout. Sixteen banks at 72 MJ
--      is 1.15 GJ, which drowns whatever real accumulators the player has and
--      makes their own readout useless. There is no prototype flag to opt out --
--      checked against the shipped 2.0.77 spec, AccumulatorPrototype has no such
--      field and neither does any ancestor. The only way out of the accumulator
--      statistic is to not be an accumulator. Reported as "remove the oppenheimer
--      capacitors from the power grid stat menu, it tracks their charge amount."
--
-- ElectricEnergyInterfacePrototype is the same energy source on a plain entity:
-- non-optional ElectricEnergySource with buffer_capacity, and LuaEntity.energy
-- read/write exactly as before -- so scripts/pylon.lua reads and writes joules
-- through an unchanged interface. It adds a script-writable power_usage and a
-- native `light`, and it subtracts the charge animation and the circuit
-- connector.
--
-- WHAT WAS LOST, HONESTLY
--   * chargable_graphics -- the built-in charge/discharge animation. Replaced,
--     and improved on, by the status lights (C.lights, scripts/render.lua),
--     which report the installation's STATE rather than one bank's fill level.
--   * #81, charge on the circuit network. Accumulators emit their charge as a
--     signal for free; an EEI has no circuit connector at all. Nothing in the
--     mod depended on it, but it was a real feature and it is gone until
--     something re-provides it.
--
--------------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local util = require("util")

local p = C.pylon

-- Same trap as the turret (prototypes/entity.lua): the base accumulator art is
-- authored at scale 0.5, and a shift does NOT scale with `scale`. Every shift
-- below goes through px() so the layers stay aligned when the bank is scaled up
-- to read as part of a 9x9 installation.
local SCALE = p.sprite_scale
local RATIO = p.sprite_scale / 0.5
local function px(x, y) return util.by_pixel(x * RATIO, y * RATIO) end

-- The base accumulator's sprite, borrowed by path so this mod ships no art.
local function pylon_picture(tint)
  return {
    layers = {
      {
        filename = "__base__/graphics/entity/accumulator/accumulator.png",
        priority = "high",
        width = p.art.width,
        height = p.art.height,
        shift = px(p.art.shift_px[1], p.art.shift_px[2]),
        scale = SCALE,
        tint = tint,
      },
      {
        filename = "__base__/graphics/entity/accumulator/accumulator-shadow.png",
        priority = "high",
        width = 234,
        height = 106,
        shift = px(29, 6),
        draw_as_shadow = true,
        scale = SCALE,
      },
    },
  }
end

--- Shared skeleton, so the three tiers cannot drift apart.
local function make_pylon(o)
  local half = p.tile_size / 2
  return {
    type = "electric-energy-interface",
    name = o.name,
    icon = "__base__/graphics/icons/accumulator.png",
    flags = {"placeable-neutral", "player-creation"},
    minable = {mining_time = 0.3, result = o.name},
    fast_replaceable_group = N.pylon_group,
    max_health = o.max_health or p.max_health,
    corpse = "accumulator-remnants",
    dying_explosion = "accumulator-explosion",
    collision_box = {{-half + 0.1, -half + 0.1}, {half - 0.1, half - 0.1}},
    selection_box = {{-half, -half}, {half, half}},
    drawing_box_vertical_extension = 1.5,

    energy_source = o.energy_source,

    -- ZERO, AND IT HAS TO BE ZERO.
    --
    -- energy_usage is an engine-side burn out of the entity's own buffer, every
    -- tick, that the script cannot see or switch off. The mod meters the grid
    -- itself: turret.power_tick empties the buffer and counts what it took
    -- (rec.paid), which is an EXACT measurement of what the network delivered
    -- since the last tick. An engine-side burn on top of that would be joules
    -- leaving by a second path that the meter is blind to, so the installation
    -- would draw more than it reports and charge slower than it should, with
    -- nothing anywhere saying why.
    --
    -- The load on the grid is therefore the buffer refill, at the priority
    -- below. LuaEntity.power_usage is the RUNTIME COPY OF THIS SAME BURN, not a
    -- readout -- writing it broke charging in 0.35.0-0.39.0. Leave it at 0.
    energy_usage = "0W",

    -- The vanilla electric-energy-interface opens a creative panel that lets a
    -- player type in any wattage they like. "none" is the default, and it is
    -- spelled out because inheriting a cheat GUI onto a gameplay entity is
    -- exactly the kind of thing that is discovered by a player, not by a check.
    gui_mode = "none",

    -- A bank is a legitimate target: killing one silences the gun (#66), so
    -- biters should actually go for them.
    is_military_target = true,

    picture = pylon_picture(o.tint),

    impact_category = "metal",
    open_sound = {filename = "__base__/sound/machine-open.ogg", volume = 0.5},
    close_sound = {filename = "__base__/sound/machine-close.ogg", volume = 0.5},
  }
end

-- THE PRIORITY, AND WHY IT IS THIS ONE.
--
-- Confirmed from the local 2.0.77 install rather than from memory, because the
-- shipped spec publishes no description for any ElectricUsagePriority value --
-- the only authority is what base does with them:
--
--   primary-input     laser-turret, the combinators        paid FIRST
--   secondary-input   assemblers, furnaces, labs, beacons  the ordinary machine
--   primary-output    generators
--   tertiary          accumulator, electric-energy-interface, equipment
--   lamp              small-lamp, paid last
--
-- secondary-input puts the installation on exactly the same footing as every
-- machine in the factory: it creates real demand, it competes on equal terms,
-- and when the grid cannot carry it the existing brownout detector takes the
-- gun DARK rather than the factory stopping. primary-input would give the gun
-- priority over the base -- a legitimate choice, and a different weapon; change
-- this one string if that is wanted.
local PRIORITY = "secondary-input"

-- THE CHARGE GLOW, AS A PROTOTYPE.
--
-- An accumulator plays this over its own sprite for free via
-- `chargable_graphics.charge_animation`. ElectricEnergyInterfacePrototype has no
-- such field -- checked against the shipped 2.0.77 spec, on the type and on every
-- ancestor -- so the animation has to be drawn by the control stage, and
-- rendering.draw_animation takes a PROTOTYPE NAME rather than a filename. Hence
-- a registered `animation` that nothing places and only scripts/render.lua ever
-- names.
--
-- Field for field from base's accumulator_charge() (entities.lua ~line 154):
-- 178x210, line_length 6, frame_count 24, draw_as_glow, shift by_pixel(1, -20)
-- at scale 0.5. Only the shift and the scale are ours, and both go through the
-- same px()/SCALE pair every other layer in this file uses -- a shift does NOT
-- follow `scale`, so art authored at 0.5 drifts off a bank drawn at 1.0.
--
-- Base's version layers the accumulator picture UNDER the glow; ours does not,
-- because the bank's own picture is already on the map underneath it. Layering
-- it again would double the sprite and wash out the tint.
data:extend({
  {
    type = "animation",
    name = N.anim.bank_charge,
    filename = "__base__/graphics/entity/accumulator/accumulator-charge.png",
    priority = "high",
    width = 178,
    height = 210,
    line_length = 6,
    frame_count = 24,
    draw_as_glow = true,
    shift = px(1, -20),
    scale = SCALE,
    animation_speed = C.lights.bank_charge.speed,
  },
})

data:extend({

  -- ===========================================================================
  -- #63: the standard bank. Draws straight from the grid.
  -- ===========================================================================
  make_pylon{
    name = N.pylon,
    tint = {r = 0.75, g = 0.85, b = 1.0, a = 1.0},
    energy_source = {
      type = "electric",
      buffer_capacity = p.buffer_capacity,
      input_flow_limit = C.watts(C.pylon_input()),
      -- Must exceed the per-shot drain or the shot stalls mid-discharge.
      output_flow_limit = p.output_flow_limit,
      usage_priority = PRIORITY,
    },
  },

})
