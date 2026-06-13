---@meta

---@class mathlib
math = math or {}

---Geometry helpers intentionally retain OpenMW-style camelCase names such as
---math.immutableVector3, math.color.commaString, and math.transform.rotateZ.
---See README.md "math geometry" for the supported surface.

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
---@param step number Non-negative step expected.
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

---Returns the smallest power of two greater than or equal to value.
---Value must be a finite number >= 1; fractional values are accepted. Raises
---an error for non-numbers, NaN, infinity, values below 1, or overflow.
---@param value number Finite number >= 1.
---@return integer result
function math.nextpoweroftwo(value) end

---Normalizes an angle into the range [-pi, pi).
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

---FFI-backed geometry cdata values. These annotations model the named public
---surface for completion and parameter hints; dynamic swizzles and arithmetic
---metamethods are documented but not exhaustively typed.

---@alias math.Vector2Like math.Vector2|math.ImmutableVector2
---@alias math.Vector3Like math.Vector3|math.ImmutableVector3
---@alias math.Vector4Like math.Vector4|math.ImmutableVector4
---@alias math.Transform math.TransformM|math.TransformQ

---Mutable 2D vector cdata with float components. Supports arithmetic
---metamethods, length operator, and property swizzles using x/y plus 0/1.
---@class math.Vector2
---@field x number
---@field y number
---@field length2 fun(self: math.Vector2): number
---@field length fun(self: math.Vector2): number
---@field normalize fun(self: math.Vector2): math.Vector2, number
---@field dot fun(self: math.Vector2, other: math.Vector2Like): number
---@field emul fun(self: math.Vector2, other: math.Vector2Like): math.Vector2
---@field ediv fun(self: math.Vector2, other: math.Vector2Like): math.Vector2
---@field rotate fun(self: math.Vector2, angle: number): math.Vector2
---@field is fun(value: any): boolean

---Immutable 2D vector cdata with read-only float components. Supports the same
---arithmetic, length, and swizzle surface as math.Vector2.
---@class math.ImmutableVector2
---@field x number
---@field y number
---@field length2 fun(self: math.ImmutableVector2): number
---@field length fun(self: math.ImmutableVector2): number
---@field normalize fun(self: math.ImmutableVector2): math.ImmutableVector2, number
---@field dot fun(self: math.ImmutableVector2, other: math.Vector2Like): number
---@field emul fun(self: math.ImmutableVector2, other: math.Vector2Like): math.ImmutableVector2
---@field ediv fun(self: math.ImmutableVector2, other: math.Vector2Like): math.ImmutableVector2
---@field rotate fun(self: math.ImmutableVector2, angle: number): math.ImmutableVector2
---@field is fun(value: any): boolean

---Mutable 3D vector cdata with float components. Supports arithmetic
---metamethods, cross product with `^`, length operator, and property swizzles
---using x/y/z plus 0/1.
---@class math.Vector3
---@field x number
---@field y number
---@field z number
---@field length2 fun(self: math.Vector3): number
---@field length fun(self: math.Vector3): number
---@field normalize fun(self: math.Vector3): math.Vector3, number
---@field dot fun(self: math.Vector3, other: math.Vector3Like): number
---@field cross fun(self: math.Vector3, other: math.Vector3Like): math.Vector3
---@field emul fun(self: math.Vector3, other: math.Vector3Like): math.Vector3
---@field ediv fun(self: math.Vector3, other: math.Vector3Like): math.Vector3
---@field is fun(value: any): boolean

---Immutable 3D vector cdata with read-only float components. Supports the same
---arithmetic, cross product, length, and swizzle surface as math.Vector3.
---@class math.ImmutableVector3
---@field x number
---@field y number
---@field z number
---@field length2 fun(self: math.ImmutableVector3): number
---@field length fun(self: math.ImmutableVector3): number
---@field normalize fun(self: math.ImmutableVector3): math.ImmutableVector3, number
---@field dot fun(self: math.ImmutableVector3, other: math.Vector3Like): number
---@field cross fun(self: math.ImmutableVector3, other: math.Vector3Like): math.ImmutableVector3
---@field emul fun(self: math.ImmutableVector3, other: math.Vector3Like): math.ImmutableVector3
---@field ediv fun(self: math.ImmutableVector3, other: math.Vector3Like): math.ImmutableVector3
---@field is fun(value: any): boolean

---Mutable 4D vector cdata with float components. Supports arithmetic
---metamethods, length operator, and property swizzles using x/y/z/w plus 0/1.
---@class math.Vector4
---@field x number
---@field y number
---@field z number
---@field w number
---@field length2 fun(self: math.Vector4): number
---@field length fun(self: math.Vector4): number
---@field normalize fun(self: math.Vector4): math.Vector4, number
---@field dot fun(self: math.Vector4, other: math.Vector4Like): number
---@field emul fun(self: math.Vector4, other: math.Vector4Like): math.Vector4
---@field ediv fun(self: math.Vector4, other: math.Vector4Like): math.Vector4
---@field is fun(value: any): boolean

---Immutable 4D vector cdata with read-only float components. Supports the same
---arithmetic, length, and swizzle surface as math.Vector4.
---@class math.ImmutableVector4
---@field x number
---@field y number
---@field z number
---@field w number
---@field length2 fun(self: math.ImmutableVector4): number
---@field length fun(self: math.ImmutableVector4): number
---@field normalize fun(self: math.ImmutableVector4): math.ImmutableVector4, number
---@field dot fun(self: math.ImmutableVector4, other: math.Vector4Like): number
---@field emul fun(self: math.ImmutableVector4, other: math.Vector4Like): math.ImmutableVector4
---@field ediv fun(self: math.ImmutableVector4, other: math.Vector4Like): math.ImmutableVector4
---@field is fun(value: any): boolean

---RGBA color cdata with read-only components. Normal constructor inputs are
---clamped to [0, 1]; NaNs remain visible until operations such as asHex().
---@class math.Color
---@field r number
---@field g number
---@field b number
---@field a number
---@field asRgba fun(self: math.Color): math.Vector4
---@field asRgb fun(self: math.Color): math.Vector3
---@field asHex fun(self: math.Color): string

---Matrix transform cdata. Multiplication/apply with vector3 returns a mutable
---math.Vector3; transform multiplication follows `A * B * v` applies B first.
---@class math.TransformM
---@field m00 number
---@field m01 number
---@field m02 number
---@field m10 number
---@field m11 number
---@field m12 number
---@field m20 number
---@field m21 number
---@field m22 number
---@field m30 number
---@field m31 number
---@field m32 number
---@field apply fun(self: math.TransformM, value: math.Vector3Like): math.Vector3
---@field inverse fun(self: math.TransformM): math.TransformM
---@field getYaw fun(self: math.TransformM): number
---@field getPitch fun(self: math.TransformM): number
---@field getAnglesXZ fun(self: math.TransformM): number, number
---@field getAnglesZYX fun(self: math.TransformM): number, number, number

---Quaternion rotation transform cdata.
---@class math.TransformQ
---@field qx number
---@field qy number
---@field qz number
---@field qw number
---@field apply fun(self: math.TransformQ, value: math.Vector3Like): math.Vector3
---@field inverse fun(self: math.TransformQ): math.TransformQ
---@field getYaw fun(self: math.TransformQ): number
---@field getPitch fun(self: math.TransformQ): number
---@field getAnglesXZ fun(self: math.TransformQ): number, number
---@field getAnglesZYX fun(self: math.TransformQ): number, number, number

---Box cdata. The center and halfSize vectors are immutable. The transform and
---vertices properties allocate new geometry values when accessed.
---@class math.Box
---@field center math.ImmutableVector3
---@field halfSize math.ImmutableVector3
---@field transform math.TransformM
---@field vertices math.ImmutableVector3[]

---Constructs a mutable 2D vector.
---@param x number
---@param y number
---@return math.Vector2 vector
function math.vector2(x, y) end

---Constructs a mutable 3D vector.
---@param x number
---@param y number
---@param z number
---@return math.Vector3 vector
function math.vector3(x, y, z) end

---Constructs a mutable 4D vector.
---@param x number
---@param y number
---@param z number
---@param w number
---@return math.Vector4 vector
function math.vector4(x, y, z, w) end

---Constructs an immutable 2D vector.
---@param x number
---@param y number
---@return math.ImmutableVector2 vector
function math.immutableVector2(x, y) end

---Constructs an immutable 3D vector.
---@param x number
---@param y number
---@param z number
---@return math.ImmutableVector3 vector
function math.immutableVector3(x, y, z) end

---Constructs an immutable 4D vector.
---@param x number
---@param y number
---@param z number
---@param w number
---@return math.ImmutableVector4 vector
function math.immutableVector4(x, y, z, w) end

---Constructs a box from center/halfSize vectors, or from a transform.
---@param center math.Vector3Like
---@param halfSize math.Vector3Like
---@return math.Box box
---@overload fun(transform: math.Transform): math.Box
function math.box(center, halfSize) end

---@class math.ColorLib
---@type math.ColorLib
math.color = math.color or {}

---Constructs an RGBA color from normalized components.
---@param r number
---@param g number
---@param b number
---@param a number
---@return math.Color color
function math.color.rgba(r, g, b, a) end

---Constructs an opaque RGB color from normalized components.
---@param r number
---@param g number
---@param b number
---@return math.Color color
function math.color.rgb(r, g, b) end

---Constructs an opaque color from a six-digit hexadecimal RGB string.
---@param hex string
---@return math.Color color
function math.color.hex(hex) end

---Constructs a color from comma-separated byte components: "r,g,b" or
---"r,g,b,a".
---@param str string
---@return math.Color color
function math.color.commaString(str) end

---@class math.TransformLib
---@field identity math.TransformQ Identity rotation transform.
---@type math.TransformLib
math.transform = math.transform or {}

---Constructs a translation transform from a vector or x/y/z components.
---@param x number
---@param y number
---@param z number
---@return math.TransformM transform
---@overload fun(offset: math.Vector3Like): math.TransformM
function math.transform.move(x, y, z) end

---Constructs a scale transform from a vector or x/y/z components.
---@param x number
---@param y number
---@param z number
---@return math.TransformM transform
---@overload fun(scale: math.Vector3Like): math.TransformM
function math.transform.scale(x, y, z) end

---Constructs a quaternion rotation transform from an angle and axis vector.
---@param angle number
---@param axis math.Vector3Like
---@return math.TransformQ transform
function math.transform.rotate(angle, axis) end

---Constructs a quaternion rotation transform around the X axis.
---@param angle number
---@return math.TransformQ transform
function math.transform.rotateX(angle) end

---Constructs a quaternion rotation transform around the Y axis.
---@param angle number
---@return math.TransformQ transform
function math.transform.rotateY(angle) end

---Constructs a quaternion rotation transform around the Z axis.
---@param angle number
---@return math.TransformQ transform
function math.transform.rotateZ(angle) end
