local math = ...

local abs, floor, max, min =
  math.abs, math.floor, math.max, math.min
local Huge = math.huge
local pi = math.pi

local Epsilon = 2.2204460492503e-16
local TwoPi = 2 * pi

math.epsilon = Epsilon

function math.lerp(v0, v1, t)
  return (1 - t) * v0 + t * v1
end

function math.approach(current, target, step)
  if step < 0 then
    error('math.approach: step must be non-negative', 2)
  end
  local delta = target - current
  if abs(delta) <= step then
    return target
  end
  return current + (delta > 0 and step or -step)
end

function math.clamp(value, low, high)
  if low > high then
    low, high = high, low
  end
  return max(low, min(high, value))
end

local function remap(value, lowin, highin, lowout, highout)
  if highin == lowin then
    error('remap: lowin and highin must differ', 2)
  end
  return lowout + (value - lowin) * (highout - lowout) / (highin - lowin)
end
math.remap = remap

function math.remapclamped(value, inmin, inmax, outmin, outmax)
  if inmax == inmin then
    error('math.remapclamped: lowin and highin must differ', 2)
  end
  local result = remap(value, inmin, inmax, outmin, outmax)
  local lo = outmin < outmax and outmin or outmax
  local hi = outmin < outmax and outmax or outmin
  return max(lo, min(hi, result))
end

function math.round(value, digits)
  local mult = 10 ^ (digits or 0)
  return floor(value * mult + 0.5) / mult
end

function math.isclose(a, b, absolutetolerance, relativetolerance)
  absolutetolerance = absolutetolerance or Epsilon
  relativetolerance = relativetolerance or 1e-9
  return abs(a - b) <= max(relativetolerance * max(abs(a), abs(b)), absolutetolerance)
end

function math.nextpoweroftwo(value)
  if type(value) ~= 'number' or value ~= value or value < 1 or value == Huge then
    error('nextpoweroftwo: value must be a finite number >= 1', 2)
  end

  local power = 1
  while power < value do
    local nextpower = power * 2
    if nextpower == Huge then
      error('nextpoweroftwo: result would overflow', 2)
    end
    power = nextpower
  end
  return power
end

function math.normalizeangle(angle)
  local fullturns = angle / TwoPi + 0.5
  return (fullturns - floor(fullturns) - 0.5) * TwoPi
end

function math.eerp(a, b, t)
  return a * (b / a) ^ t
end

function math.oscillate(phase, inmin, inmax)
  local range = inmax - inmin
  local t = (phase - inmin) % (2 * range)
  if t > range then t = 2 * range - t end
  return inmin + t
end

local function clamp01(x)
  return x < 0 and 0 or (x > 1 and 1 or x)
end

function math.smoothstep(edge0, edge1, x)
  if edge0 == edge1 then
    error('smoothstep: edge0 and edge1 must differ', 2)
  end
  x = clamp01((x - edge0) / (edge1 - edge0))
  return x * x * (3 - 2 * x)
end

function math.smootherstep(edge0, edge1, x)
  if edge0 == edge1 then
    error('smootherstep: edge0 and edge1 must differ', 2)
  end
  x = clamp01((x - edge0) / (edge1 - edge0))
  return x * x * x * (x * (x * 6 - 15) + 10)
end

function math.snap(value, step)
  return floor(value / step + 0.5) * step
end
