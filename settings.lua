-- settings: one runtime-global setting, prep_rate (chunks/tick for blast-zone generation).

local N = require("lib.names")

data:extend({
  {
    type = "int-setting",
    name = N.setting.prep_rate,
    setting_type = "runtime-global",
    default_value = 8,
    minimum_value = 1,
    maximum_value = 64,
    order = "a",
  },
})
