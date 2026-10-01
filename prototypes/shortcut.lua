-- prototypes/shortcut.lua --------------------------------------------------------
-- #107: the show/hide button for the status HUD, in the shortcut bar next to the
-- targeting remote.
--
-- action = "lua" is what makes clicking it raise on_lua_shortcut in the control
-- stage; `toggleable` is what makes the button hold its pressed state instead of
-- springing back. Both are required for a toggle -- without `toggleable` the
-- button works but never looks switched on.
----------------------------------------------------------------------------------

local N = require("lib.names")

data:extend({

  -- ============================================================================
  -- THE DESIGNATOR SPAWNER. Without this the weapon cannot be fired at all.
  -- ============================================================================
  --
  -- The designator capsule is flagged "only-in-cursor", which means it cannot
  -- exist in an inventory, cannot be crafted into one and cannot be pulled from
  -- a chest. The only legal way to hold one is for something to put it directly
  -- into the cursor, and `action = "spawn-item"` is that something. Vanilla
  -- gives its own artillery remote out exactly this way -- a shortcut-bar button
  -- and a keybind, both spawn-item -- which is why base defines no recipe for it
  -- either and why looking for one is a dead end.
  --
  -- 0.8.0 shipped the capsule with neither. The prototype was in data.raw, the
  -- locale string was written, the item was named in the mod description, and
  -- there was no way to get one. Since designation is the ONLY way this gun ever
  -- acquires a target -- there is no auto-targeting and no setting that enables
  -- one -- the entire weapon was unfireable, which is what "the lance designator
  -- doesn't exist in game" turned out to mean.
  --
  -- Two spawners, not one, and deliberately: a shortcut bar can be collapsed or
  -- the button hidden, and a keybind can collide with another mod's. Either one
  -- alone is a single point of failure for the whole weapon.
  {
    type = "custom-input",
    name = N.designator_input,
    -- ALT+O for Oppenheimer. Checked against base's custom-inputs: base binds
    -- ALT with B D U F L E C R G A Y T, and not O. A collision with another MOD
    -- is still possible; Factorio resolves that by leaving one unbound and
    -- saying so in the controls menu, not by failing to load.
    key_sequence = "ALT + O",
    consuming = "game-only",
    item_to_spawn = N.remote,
    action = "spawn-item",
  },

  -- ============================================================================
  -- WHERE A DRAG STARTED (arc sweep). See lib/names.lua's note on N.drag_input.
  -- ============================================================================
  --
  -- linked_game_control means the game's own select controls raise these, at
  -- the moment the button goes down, with the cursor position on the event --
  -- the one piece on_player_selected_area throws away when it normalises the
  -- rectangle. key_sequence is mandatory even for a linked input; "" is the
  -- documented "unassigned", and a linked input is never bound by hand anyway.
  -- consuming defaults to "none", so the selection still happens.
  {
    type = "custom-input",
    name = N.drag_input,
    key_sequence = "",
    linked_game_control = "select-for-blueprint",
  },
  {
    type = "custom-input",
    name = N.drag_input_alt,
    key_sequence = "",
    linked_game_control = "select-for-cancel-deconstruct",
  },

  {
    type = "shortcut",
    name = N.designator_shortcut,
    action = "spawn-item",
    item_to_spawn = N.remote,
    associated_control_input = N.designator_input,
    -- Gated on the same research that unlocks the turret: a designator before
    -- there is anything to designate for is just clutter in the shortcut bar.
    technology_to_unlock = N.tech.artillery,
    order = "b[blueprints]-n[oppenheimer-designator]",
    -- Same tint as the item (prototypes/item.lua). Untinted, this button is
    -- pixel-identical to vanilla's artillery targeting remote sitting next to it,
    -- and pressing the wrong one drops a vanilla flare.
    icon = "__base__/graphics/icons/artillery-targeting-remote.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/artillery-targeting-remote.png",
    small_icon_size = 64,
    icons = {{icon = "__base__/graphics/icons/artillery-targeting-remote.png",
              icon_size = 64, tint = {r = 1.0, g = 0.55, b = 0.15}}},
  },

  {
    type = "shortcut",
    name = N.gui.hud_toggle,
    action = "lua",
    toggleable = true,
    order = "b[blueprints]-o[oppenheimer]",
    icon = "__base__/graphics/icons/artillery-targeting-remote.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/artillery-targeting-remote.png",
    small_icon_size = 64,
  },
})
