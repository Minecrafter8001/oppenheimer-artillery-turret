-- prototypes/vfx/ionization.lua ----------------------------------------------------
-- The one texture the charge's ionization channel is drawn with (scripts/beam.lua,
-- beam.haze). core's light-medium.png: a 300 px radial falloff that reaches zero
-- on every edge. Stretched along the line of fire (draw_sprite x_scale/y_scale)
-- it is a soft tube with no hard side and no hard end -- the flat, square-edged
-- panel a very wide rendering.draw_line makes is what this replaced.
--
-- premul_alpha = false: the file is ALREADY premultiplied (rgb == alpha in every
-- pixel). Letting the engine premultiply it again squares the falloff, and the
-- overlapping segments of the channel then bead visibly at their joints.
----------------------------------------------------------------------------------

local N = require("lib.names")

data:extend({
  {
    type         = "sprite",
    name         = N.sprite.ion_glow,
    filename     = "__core__/graphics/light-medium.png",
    width        = 300,
    height       = 300,
    priority     = "extra-high",
    premul_alpha = false,
  },
})
