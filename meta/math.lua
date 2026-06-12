---@meta

---@class mathlib
math = math or {}

---Machine epsilon used by math.isclose by default.
---@type number
math.epsilon = math.epsilon

---Linearly interpolates between two numbers.
---@param v0 number
---@param v1 number
---@param t number
---@return number result
function math.lerp(v0, v1, t) end

---Moves current toward target by at most step, without overshooting.
---@param current number
---@param target number
---@param step number Positive step expected.
---@return number result
function math.approach(current, target, step) end

---Clamps value to the inclusive range low..high. Reversed bounds are accepted.
---@param value number
---@param low number
---@param high number
---@return number result
function math.clamp(value, low, high) end

---Remaps a value from one range to another.
---@param value number
---@param lowin number
---@param highin number Must differ from lowin.
---@param lowout number
---@param highout number
---@return number result
function math.remap(value, lowin, highin, lowout, highout) end

---Remaps a value from one range to another, then clamps to the output range.
---@param value number
---@param inmin number
---@param inmax number Must differ from inmin.
---@param outmin number
---@param outmax number
---@return number result
function math.remapclamped(value, inmin, inmax, outmin, outmax) end

---Rounds value to the nearest integer or decimal place.
---@param value number
---@param digits? integer Number of decimal digits. Defaults to 0.
---@return number result
function math.round(value, digits) end

---Returns whether two numbers are close under absolute/relative tolerances.
---@param a number
---@param b number
---@param absolutetolerance? number Defaults to math.epsilon.
---@param relativetolerance? number Defaults to 1e-9.
---@return boolean result
function math.isclose(a, b, absolutetolerance, relativetolerance) end

---Returns the next power of two greater than or equal to value.
---@param value number
---@return integer result
function math.nextpoweroftwo(value) end

---Normalizes an angle into the range [-pi, pi].
---@param angle number
---@return number normalized
function math.normalizeangle(angle) end

---Exponentially interpolates between two positive values.
---@param a number Positive value expected.
---@param b number Positive value expected.
---@param t number Interpolation factor.
---@return number result
function math.eerp(a, b, t) end

---Bounces a phase value back and forth between inmin and inmax.
---@param phase number
---@param inmin number
---@param inmax number Must differ from inmin.
---@return number result
function math.oscillate(phase, inmin, inmax) end

---Returns smooth cubic interpolation over edge0..edge1.
---@param edge0 number
---@param edge1 number Must differ from edge0.
---@param x number
---@return number result
function math.smoothstep(edge0, edge1, x) end

---Returns smoother quintic interpolation over edge0..edge1.
---@param edge0 number
---@param edge1 number Must differ from edge0.
---@param x number
---@return number result
function math.smootherstep(edge0, edge1, x) end

---Rounds value to the nearest multiple of step.
---@param value number
---@param step number Positive step expected.
---@return number result
function math.snap(value, step) end
