-- prototypes/style.lua ------------------------------------------------------------
-- THE PANEL'S OWN STYLES: compact, and with the mod's own click voices.
--
-- Every default GUI control plays the engine's gui-click / dropdown sounds, which
-- on a panel with a row per installation is a click track of chirps. These styles
-- replace them with the short, soft voices in sound/ui-*.ogg: a relay click for
-- the toggles, a heavier arming voice for the fire button, a light tick for the
-- dropdown. An empty Sound (`{}`) would be silence, the engine's own idiom.
--
-- The styles are also COMPACT: 24 px tall against the stock 28, no 108 px
-- minimum width, tighter padding. A battery of six installations has to fit on
-- a laptop screen beside everything else the player has open.
--
-- The dropdown is a DEEP COPY of core's, not a fresh style with `parent`: its
-- list box carries a hand-built scroll pane (maximal_height, shadows) that a
-- bare parent reference does not bring along, and rebuilding that by hand is a
-- second copy of core's own layout to keep in step. Copy, then silence.
--
-- THE GRAPH SPRITES are here for the same reason: the HUD's power graph is a
-- column of `sprite` elements stretched to height, a `sprite` element cannot be
-- tinted at runtime, and there is no chart widget -- so the tints are baked
-- into four sprite prototypes over core's white square.
----------------------------------------------------------------------------------

local C    = require("config")
local N    = require("lib.names")
local util = require("util")

local styles = data.raw["gui-style"].default
local ui = C.sound.ui

--- A style's click voice: one file from sound/, at the panel's button volume.
local function voice(file)
  return {{filename = "__oppenheimer-artillery-turret-forked__/sound/" .. file, volume = ui.button_volume}}
end

--- A compact button over one of core's, with the mod's own click.
local function panel_button(name, parent, click)
  styles[name] = {
    type = "button_style",
    parent = parent,
    minimal_width  = 0,
    minimal_height = 24,
    height         = 24,
    top_padding    = 0,
    bottom_padding = 0,
    left_padding   = 8,
    right_padding  = 8,
    font = "default-semibold",
    left_click_sound = voice(click),
  }
end

panel_button(N.style.button,       "button",       "ui-click.ogg")
panel_button(N.style.button_green, "green_button", "ui-click.ogg")
panel_button(N.style.button_red,   "red_button",   "ui-click.ogg")
-- The one control that fires the weapon reads differently from the toggles
-- around it: core's confirm green, wider, and with the heavier arming voice.
panel_button(N.style.button_fire,  "confirm_button", "ui-arm.ogg")
styles[N.style.button_fire].minimal_width = 96

--- Core's switch with the panel's voice, in the colour of its lit side.
-- CRITICAL: `active_label` is whichever side is up, so TEST-green and LIVE-red
-- take one style each and scripts/gui.lua swaps them on the state.
local function mode_switch(name, colour)
  local sw = util.table.deepcopy(styles.switch)
  sw.active_label = {type = "label_style", font = "default-bold", font_color = colour}
  sw.inactive_label = {type = "label_style", font = "default",
                       font_color = {100, 100, 100}, hovered_font_color = {190, 190, 190}}
  sw.button.left_click_sound = voice("ui-arm.ogg")
  styles[name] = sw
end

mode_switch(N.style.switch_test, {120, 255, 140})
mode_switch(N.style.switch_live, {255, 70, 60})

local dropdown = util.table.deepcopy(styles.dropdown)
dropdown.minimal_height = 24
dropdown.height = 24
dropdown.opened_sound = voice("ui-select.ogg")
dropdown.button_style = {type = "button_style", parent = "dropdown_button",
                         left_click_sound = voice("ui-select.ogg")}
-- The rows inside the open list. Core leaves item_style unset, so it is created here.
dropdown.list_box_style = dropdown.list_box_style or {type = "list_box_style"}
dropdown.list_box_style.item_style = {
  type = "button_style", parent = "list_box_item",
  left_click_sound = voice("ui-select.ogg"),
}
styles[N.style.dropdown] = dropdown

-- A slim progress bar: the charge readout is a line of telemetry, not a
-- headline, so the bar is the height of the text beside it.
styles[N.style.graph_bar] = {
  type = "progressbar_style",
  parent = "progressbar",
  bar_width = 6,
  color = {r = 0.35, g = 0.85, b = 1.00},
}

-- =============================================================================
-- The power graph's bars
-- =============================================================================

local function graph_sprite(name, tint)
  return {
    type = "sprite",
    name = name,
    filename = "__core__/graphics/white-square.png",
    priority = "extra-high-no-scale",
    width = 10,
    height = 10,
    tint = tint,
    flags = {"gui-icon"},
  }
end

data:extend({
  graph_sprite(N.sprite_gui.graph_hot,  {r = 1.00, g = 0.45, b = 0.25, a = 0.95}),
  graph_sprite(N.sprite_gui.graph_warm, {r = 1.00, g = 0.80, b = 0.30, a = 0.95}),
  graph_sprite(N.sprite_gui.graph_cold, {r = 0.35, g = 0.85, b = 1.00, a = 0.95}),
  graph_sprite(N.sprite_gui.graph_dim,  {r = 0.30, g = 0.36, b = 0.42, a = 0.75}),
})
