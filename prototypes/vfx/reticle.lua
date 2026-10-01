-- prototypes/vfx/reticle.lua --------------------------------------------------------
-- sprites scripts/reticle.lua draws on the pad. Numbers from
-- C.reticle.scorch.sprite; the art is base's own.
--------------------------------------------------------------------------------------

local C = require("config")
local N = require("lib.names")

local s = C.reticle.scorch.sprite

local protos = {}
for i, name in ipairs(N.sprite.stage_scorch) do
  protos[#protos + 1] = {
    type     = "sprite",
    name     = name,
    filename = s.filename,
    width    = s.width,
    height   = s.height,
    x        = s.width * (i - 1),
    scale    = s.scale,
  }
end

data:extend(protos)
