-- lib/heat: temperature -> RGB and heating state evolution. Usable from both stages.

local C = require("config")

local heat = {}
local H = C.heat

local function clamp01(v)
  if v < 0 then return 0 elseif v > 1 then return 1 end
  return v
end

--- Black-body colour of a temperature, 0..1 per channel, full brightness.
--- Tanner Helland's curve fit to the CIE 1964 black-body locus, 1000-40000 K.
function heat.rgb(kelvin)
  local t = math.max(1000, math.min(40000, kelvin)) / 100
  local r, g, b
  if t <= 66 then
    r = 255
    g = 99.4708025861 * math.log(t) - 161.1195681661
  else
    r = 329.698727446 * (t - 60) ^ -0.1332047592
    g = 288.1221695283 * (t - 60) ^ -0.0755148492
  end
  if t >= 66 then
    b = 255
  elseif t <= 19 then
    b = 0
  else
    b = 138.5177312231 * math.log(t - 10) - 305.0447927307
  end
  return {r = clamp01(r / 255), g = clamp01(g / 255), b = clamp01(b / 255)}
end

--- One tick of heating: theta' = theta + (p - theta^4) / tau. See C.heat.
function heat.advance(theta, p, tau)
  theta = theta or 0
  local th = theta + ((p or 0) - theta ^ 4) / math.max(1, tau)
  if th < 0 then th = 0 end
  return th
end

--- Temperature in kelvin for a normalised theta, hotter by the overpower band when one is given (C.heat.overpower_t_*). Clamped to t_max, which is both the top of the built ladder and the top of heat.rgb's fit: past it the surplus is C.beam.bloom's, not a new hue.
function heat.kelvin(theta, omega)
  local k = (theta or 0) * H.t_ref
  if omega and omega > 1 then
    k = k * C.overpower_gain(omega, H.overpower_t_max, H.overpower_t_exponent)
  end
  if k > H.t_max then k = H.t_max end
  return math.max(H.t_min, k)
end

--- Built temperature ladder, cached. Evenly spaced in mired (perceptually uniform).
local STEPS
function heat.steps()
  if STEPS then return STEPS end
  local out = {}
  local m0, m1 = 1e6 / H.t_min, 1e6 / H.t_ref
  local n = math.max(2, H.steps)
  for i = 0, n - 1 do
    out[#out + 1] = 1e6 / (m0 + (m1 - m0) * i / (n - 1))
  end
  local extra = H.overpower_steps or 0
  if extra > 0 and (H.t_max or 0) > H.t_ref then
    local m2 = 1e6 / H.t_max
    for i = 1, extra do
      out[#out + 1] = 1e6 / (m1 + (m2 - m1) * i / extra)
    end
  end
  STEPS = out
  return out
end

--- The built step nearest a temperature (in mired, the perceptual scale).
function heat.step_for(kelvin)
  local m = 1e6 / math.max(1, kelvin)
  local best, best_d = 1, nil
  for i, k in ipairs(heat.steps()) do
    local d = math.abs(1e6 / k - m)
    if not best_d or d < best_d then best, best_d = i, d end
  end
  return best
end

--- A built step for a temperature, picked between the two around it with odds by mired distance, so a smooth field does not band. `r` is uniform on [0, 1).
function heat.step_dither(kelvin, r)
  local steps = heat.steps()
  local m = 1e6 / math.max(1, kelvin)
  for i = 1, #steps - 1 do
    local lo, hi = 1e6 / steps[i], 1e6 / steps[i + 1]
    if m >= hi then
      if m >= lo then return i end
      return (r < (lo - m) / (lo - hi)) and (i + 1) or i
    end
  end
  return #steps
end

--- The first built step at or above a temperature: the highest step_dither can return for anything at or below it.
function heat.step_ceiling(kelvin)
  local steps = heat.steps()
  for i, k in ipairs(steps) do
    if k >= kelvin then return i end
  end
  return #steps
end

--- Temperature after `ticks` of cooling with no input: heat.advance's law solved exactly, T^-3 rising by `rate` per tick.
function heat.cooled(kelvin, ticks, rate)
  if not ticks or ticks <= 0 then return kelvin end
  return (kelvin ^ -3 + rate * ticks) ^ (-1 / 3)
end

local LN = math.log

--- Glaze thickness in mm at the fireball ring's edge for a device of `kt` kilotonnes.
function heat.glaze_mm(kt)
  local g = H.ground
  return g.glaze_mm * (math.max(kt or 0, 1e-9) / g.glaze_kt) ^ g.glaze_exponent
end

--- Glaze thickness in mm at normalised radius u inside the fireball ring, `edge` mm at its rim.
function heat.glaze_at(edge, u)
  return edge * (1 + H.ground.bowl * (1 - u / C.blast.rings.fireball_u))
end

--- Ticks into a sweep at which the glaze starts cooling: the release fireball lifting, or the front leaving the fireball ring when that is later.
function heat.glaze_start(ticks)
  local rl = C.blast.release
  local t = ticks * C.blast.rings.fireball_u ^ (1 / C.blast.rings.wave.front_curve)
  local hold = rl.enabled and rl.ticks or 0
  if hold > t then t = hold end
  return t
end

--- The cooling row at or below thickness h_mm and the log fraction toward the next; past either end the nearest pair, extrapolated.
local function bracket(h_mm)
  local hs = H.ground.cooling.h_mm
  local i = 1
  while i < #hs - 1 and h_mm > hs[i + 1] do i = i + 1 end
  return i, LN(h_mm / hs[i]) / LN(hs[i + 1] / hs[i])
end

--- Seconds for one cooling row to bring its surface down to `kelvin`, or to freeze through for "solid".
local function row_seconds(c, i, kelvin)
  if kelvin == "solid" then return c.solid[i] end
  local g = H.ground
  local row, lv = c.t[i], c.kelvin
  if kelvin >= g.t_boil then return 0 end
  if kelvin >= lv[1] then return row[1] * (g.t_boil - kelvin) / (g.t_boil - lv[1]) end
  for j = 1, #lv - 1 do
    if kelvin >= lv[j + 1] then
      return row[j] * (row[j + 1] / row[j]) ^ ((lv[j] - kelvin) / (lv[j] - lv[j + 1]))
    end
  end
  -- Past the table the surface cools by conduction alone: (T - ambient) as t ^ -1/2.
  local r = (lv[#lv] - g.ambient) / math.max(1, kelvin - g.ambient)
  return row[#lv] * r * r
end

--- Seconds after the fireball lifts for a glaze h_mm thick to bring its surface down to `kelvin`, or to freeze through for "solid".
function heat.glaze_seconds(h_mm, kelvin)
  local c = H.ground.cooling
  local i, f = bracket(h_mm)
  local a, b = row_seconds(c, i, kelvin), row_seconds(c, i + 1, kelvin)
  if a <= 0 or b <= 0 then return 0 end
  return a * (b / a) ^ f
end

--- The glaze thickness in mm that reaches `kelvin` (or freezes, for "solid") exactly `s` seconds after the fireball lifts; thicker glaze has not yet. math.huge once every thickness has.
function heat.glaze_mm_at(kelvin, s)
  if s <= 0 then return 0 end
  local c = H.ground.cooling
  local hs = c.h_mm
  local n = #hs
  local e1 = row_seconds(c, 1, kelvin)
  if s <= e1 then
    local e2 = row_seconds(c, 2, kelvin)
    if e1 <= 0 or e2 <= e1 then return hs[1] end
    return hs[1] * (s / e1) ^ (LN(hs[2] / hs[1]) / LN(e2 / e1))
  end
  local i, ei = n, row_seconds(c, n, kelvin)
  while i > 1 and ei > s do
    i = i - 1
    ei = row_seconds(c, i, kelvin)
  end
  if i == n then
    local ep = row_seconds(c, n - 1, kelvin)
    if ei <= ep then return math.huge end
    return hs[n] * (s / ei) ^ (LN(hs[n] / hs[n - 1]) / LN(ei / ep))
  end
  local ej = row_seconds(c, i + 1, kelvin)
  if ej <= ei then return hs[i + 1] end
  return hs[i] * (hs[i + 1] / hs[i]) ^ (LN(s / ei) / LN(ej / ei))
end

--- Kelvin at the surface of a glaze h_mm thick, `s` seconds after the fireball lifts.
function heat.glaze_kelvin(h_mm, s)
  local g = H.ground
  if s <= 0 then return g.t_boil end
  local c = g.cooling
  local lv = c.kelvin
  local i, f = bracket(h_mm)
  local ra, rb = c.t[i], c.t[i + 1]
  local t0, k0 = 0, g.t_boil
  for j = 1, #lv do
    local tj = ra[j] * (rb[j] / ra[j]) ^ f
    if s < tj and tj > t0 then
      if t0 <= 0 then return k0 + (lv[j] - k0) * s / tj end
      return k0 + (lv[j] - k0) * LN(s / t0) / LN(tj / t0)
    end
    t0, k0 = tj, lv[j]
  end
  return g.ambient + (k0 - g.ambient) * math.sqrt(t0 / s)
end

--- Kelvin of the flash-heated skin at normalised radius u outside the fireball ring, `s` seconds after the front crossed it: its heat conducting down into the cold rock.
local function skin_kelvin(u, s)
  local g = H.ground
  local peak = C.blast.rings.groundfire.kelvin(u)
  if s <= 0 then return peak end
  local h = g.skin_mm / 1000
  return g.ambient + (peak - g.ambient) * h / (h + math.sqrt(math.pi * g.diffusivity * s))
end

--- Seconds for the hottest skin to fall to `kelvin`.
function heat.skin_seconds(kelvin)
  local g = H.ground
  local x = g.skin_mm / 1000 * ((g.t_boil - g.ambient) / math.max(1, kelvin - g.ambient) - 1)
  return x * x / (math.pi * g.diffusivity)
end

--- Kelvin of a blast's ground at normalised radius u, `now` ticks into its sweep, on a patch holding `cap` times the usual glaze. `g` carries ticks (the sweep), hold (heat.glaze_start) and glaze (heat.glaze_mm).
function heat.ground_kelvin(g, u, now, cap)
  if u <= C.blast.rings.fireball_u then
    return heat.glaze_kelvin(heat.glaze_at(g.glaze, u) * (cap or 1), (now - g.hold) / 60)
  end
  return skin_kelvin(u, (now - g.ticks * u ^ (1 / C.blast.rings.wave.front_curve)) / 60)
end

local function mix(a, b, u)
  return {r = a.r + (b.r - a.r) * u, g = a.g + (b.g - a.g) * u, b = a.b + (b.b - a.b) * u}
end
heat.mix = mix

--- How brightly a black body glows at this temperature, 0..1, against `ref` (default C.heat.glow_ref). Tempered from T^4.
function heat.glow(kelvin, ref)
  local H = C.heat
  local g = (math.max(kelvin or 0, 1) / (ref or H.glow_ref)) ^ H.glow_exponent
  if g > 1 then g = 1 end
  if g < H.glow_floor then g = H.glow_floor end
  return g
end

--- Black-body colour scaled by its emission (heat.glow against `ref`).
function heat.glow_rgb(kelvin, mult, ref)
  local c = heat.rgb(kelvin)
  local g = heat.glow(kelvin, ref)
  local m = mult or {r = 1, g = 1, b = 1}
  return {r = c.r * g * (m.r or 1), g = c.g * g * (m.g or 1), b = c.b * g * (m.b or 1)}
end

--- Tints for one lance layer at one temperature.
-- @param layer "core"|"halo"
-- @return tint, light_tint
function heat.lance_tints(layer, kelvin)
  local c = heat.rgb(kelvin)
  if layer == "core" then
    local w = mix(c, {r = 1, g = 1, b = 1}, H.core_whiten)
    return {r = w.r, g = w.g, b = w.b, a = H.core_alpha},
           {r = c.r, g = c.g, b = c.b, a = H.core_light_alpha}
  end
  return {r = c.r, g = c.g, b = c.b, a = H.halo_alpha},
         {r = c.r, g = c.g, b = c.b, a = H.halo_light_alpha}
end

return heat
