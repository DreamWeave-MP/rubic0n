local math, loadffi = ...
local sqrt, cos, sin = math.sqrt, math.cos, math.sin
local string_byte = string.byte
local vector2_ctor, vector3_ctor, vector4_ctor
local immutable_vector2_ctor, immutable_vector3_ctor, immutable_vector4_ctor
local box_ctor

local function badarg(n, name)
  error('bad argument #'..n..' to '..name..' (number expected)', 3)
end

local function check_constructor(name, n, ...)
  if select('#', ...) ~= n then
    error(name..' constructor requires exactly '..n..' numeric arguments', 3)
  end
  for i = 1, n do
    if type(select(i, ...)) ~= 'number' then badarg(i, name) end
  end
end

local function build_geometry(ffi)
  if type(ffi) ~= 'table' or type(ffi.typeof) ~= 'function' or
     type(ffi.metatype) ~= 'function' or type(ffi.istype) ~= 'function' then
    error('math geometry requires a valid ffi module', 3)
  end

  local vector2_type = ffi.typeof('struct { float x, y; }')
  local vector3_type = ffi.typeof('struct { float x, y, z; }')
  local vector4_type = ffi.typeof('struct { float x, y, z, w; }')
  local immutable_vector2_type = ffi.typeof('struct { const float x, y; }')
  local immutable_vector3_type = ffi.typeof('struct { const float x, y, z; }')
  local immutable_vector4_type = ffi.typeof('struct { const float x, y, z, w; }')
  local box_type = ffi.typeof('struct { const $ center; const $ halfSize; const float qx, qy, qz, qw; }', immutable_vector3_type, immutable_vector3_type)
  local vector2, vector3, vector4
  local immutable_vector2, immutable_vector3, immutable_vector4
  local box
  local function is_mvec2(v) return ffi.istype(vector2_type, v) end
  local function is_mvec3(v) return ffi.istype(vector3_type, v) end
  local function is_mvec4(v) return ffi.istype(vector4_type, v) end
  local function is_ivec2(v) return ffi.istype(immutable_vector2_type, v) end
  local function is_ivec3(v) return ffi.istype(immutable_vector3_type, v) end
  local function is_ivec4(v) return ffi.istype(immutable_vector4_type, v) end
  local function is_box(v) return ffi.istype(box_type, v) end
  local function err_type(name, op)
    error(name..' expected for '..op, 3)
  end
  local function err_scalar(name, op)
    error(name..' can only be '..op..' by scalar', 3)
  end
  local nil_index = { __index = function() return nil end }

  local function swizzle2_component(v, c)
    if c == 120 then return v.x end
    if c == 121 then return v.y end
    if c == 48 then return 0 end
    if c == 49 then return 1 end
  end

  local function swizzle3_component(v, c)
    if c == 120 then return v.x end
    if c == 121 then return v.y end
    if c == 122 then return v.z end
    if c == 48 then return 0 end
    if c == 49 then return 1 end
  end

  local function swizzle4_component(v, c)
    if c == 120 then return v.x end
    if c == 121 then return v.y end
    if c == 122 then return v.z end
    if c == 119 then return v.w end
    if c == 48 then return 0 end
    if c == 49 then return 1 end
  end

  local function make_swizzle(component, immutable)
    return function(v, key)
      if type(key) ~= 'string' then return nil end
      local n = #key
      if n < 1 or n > 4 then return nil end
      local a = component(v, string_byte(key, 1))
      if a == nil then return nil end
      if n == 1 then return a end
      local b = component(v, string_byte(key, 2))
      if b == nil then return nil end
      if n == 2 then
        if immutable then return immutable_vector2(a, b) end
        return vector2(a, b)
      end
      local c = component(v, string_byte(key, 3))
      if c == nil then return nil end
      if n == 3 then
        if immutable then return immutable_vector3(a, b, c) end
        return vector3(a, b, c)
      end
      local d = component(v, string_byte(key, 4))
      if d == nil then return nil end
      if immutable then return immutable_vector4(a, b, c, d) end
      return vector4(a, b, c, d)
    end
  end

  local function vec2_mt(immutable, is_self, is_other)
    local Methods = setmetatable({}, nil_index)
    local MT = {}
    if immutable then
      MT.__add = function(a, b)
        if not is_self(a) then err_type('vector2', 'addition') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x+b.x, a.y+b.y) end
        err_type('vector2', 'addition')
      end
      MT.__sub = function(a, b)
        if not is_self(a) then err_type('vector2', 'subtraction') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x-b.x, a.y-b.y) end
        err_type('vector2', 'subtraction')
      end
      MT.__unm = function(v) return immutable_vector2(-v.x, -v.y) end
      MT.__eq = function(a, b)
        return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y
      end
      MT.__mul = function(a, b)
        if type(a) == 'number' then
          if not is_self(b) then err_type('vector2', 'multiplication') end
          return immutable_vector2(a*b.x, a*b.y)
        end
        if not is_self(a) then err_type('vector2', 'multiplication') end
        if type(b) == 'number' then return immutable_vector2(a.x*b, a.y*b) end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
        err_type('vector2', 'multiplication')
      end
      MT.__div = function(a, scalar)
        if not is_self(a) then err_type('vector2', 'division') end
        if type(scalar) ~= 'number' then err_scalar('vector2', 'divided') end
        return immutable_vector2(a.x/scalar, a.y/scalar)
      end
      MT.__tostring = function(v) return ('(%.38g, %.38g)'):format(v.x, v.y) end
      MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y) end
      Methods.length2 = function(v)
        if not is_self(v) then err_type('vector2', 'length2') end
        return v.x*v.x + v.y*v.y
      end
      Methods.length = function(v)
        if not is_self(v) then err_type('vector2', 'length') end
        return sqrt(v.x*v.x + v.y*v.y)
      end
      Methods.normalize = function(v)
        if not is_self(v) then err_type('vector2', 'normalize') end
        local len = sqrt(v.x*v.x + v.y*v.y)
        if len > 0 then return immutable_vector2(v.x/len, v.y/len), len end
        return immutable_vector2(0, 0), len
      end
      Methods.dot = function(a, b)
        if not is_self(a) then err_type('vector2', 'dot') end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
        err_type('vector2', 'dot')
      end
      Methods.emul = function(a, b)
        if not is_self(a) then err_type('vector2', 'element multiplication') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x*b.x, a.y*b.y) end
        err_type('vector2', 'element multiplication')
      end
      Methods.ediv = function(a, b)
        if not is_self(a) then err_type('vector2', 'element division') end
        if is_self(b) or is_other(b) then return immutable_vector2(a.x/b.x, a.y/b.y) end
        err_type('vector2', 'element division')
      end
      Methods.rotate = function(v, angle)
        if not is_self(v) then err_type('vector2', 'rotate') end
        if type(angle) ~= 'number' then badarg(2, 'rotate') end
        local c, s = cos(angle), sin(angle)
        return immutable_vector2(v.x*c - v.y*s, v.x*s + v.y*c)
      end
      Methods.is = function(v) return is_self(v) or is_other(v) end
      Methods.swizzle = make_swizzle(swizzle2_component, true)
      MT.__index = Methods
      return MT
    end
    MT.__add = function(a, b)
      if not is_self(a) then err_type('vector2', 'addition') end
      if is_self(b) or is_other(b) then return vector2(a.x+b.x, a.y+b.y) end
      err_type('vector2', 'addition')
    end
    MT.__sub = function(a, b)
      if not is_self(a) then err_type('vector2', 'subtraction') end
      if is_self(b) or is_other(b) then return vector2(a.x-b.x, a.y-b.y) end
      err_type('vector2', 'subtraction')
    end
    MT.__unm = function(v) return vector2(-v.x, -v.y) end
    MT.__eq = function(a, b)
      return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y
    end
    MT.__mul = function(a, b)
      if type(a) == 'number' then
        if not is_self(b) then err_type('vector2', 'multiplication') end
        return vector2(a*b.x, a*b.y)
      end
      if not is_self(a) then err_type('vector2', 'multiplication') end
      if type(b) == 'number' then return vector2(a.x*b, a.y*b) end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
      err_type('vector2', 'multiplication')
    end
    MT.__div = function(a, scalar)
      if not is_self(a) then err_type('vector2', 'division') end
      if type(scalar) ~= 'number' then err_scalar('vector2', 'divided') end
      return vector2(a.x/scalar, a.y/scalar)
    end
    MT.__tostring = function(v) return ('(%.38g, %.38g)'):format(v.x, v.y) end
    MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y) end
    Methods.length2 = function(v)
      if not is_self(v) then err_type('vector2', 'length2') end
      return v.x*v.x + v.y*v.y
    end
    Methods.length = function(v)
      if not is_self(v) then err_type('vector2', 'length') end
      return sqrt(v.x*v.x + v.y*v.y)
    end
    Methods.normalize = function(v)
      if not is_self(v) then err_type('vector2', 'normalize') end
      local len = sqrt(v.x*v.x + v.y*v.y)
      if len > 0 then return vector2(v.x/len, v.y/len), len end
      return vector2(0, 0), len
    end
    Methods.dot = function(a, b)
      if not is_self(a) then err_type('vector2', 'dot') end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y end
      err_type('vector2', 'dot')
    end
    Methods.emul = function(a, b)
      if not is_self(a) then err_type('vector2', 'element multiplication') end
      if is_self(b) or is_other(b) then return vector2(a.x*b.x, a.y*b.y) end
      err_type('vector2', 'element multiplication')
    end
    Methods.ediv = function(a, b)
      if not is_self(a) then err_type('vector2', 'element division') end
      if is_self(b) or is_other(b) then return vector2(a.x/b.x, a.y/b.y) end
      err_type('vector2', 'element division')
    end
    Methods.rotate = function(v, angle)
      if not is_self(v) then err_type('vector2', 'rotate') end
      if type(angle) ~= 'number' then badarg(2, 'rotate') end
      local c, s = cos(angle), sin(angle)
      return vector2(v.x*c - v.y*s, v.x*s + v.y*c)
    end
    Methods.is = function(v) return is_self(v) or is_other(v) end
    Methods.swizzle = make_swizzle(swizzle2_component, false)
    MT.__index = Methods
    return MT
  end

  local function vec3_mt(immutable, is_self, is_other)
    local Methods = setmetatable({}, nil_index)
    local MT = {}
    if immutable then
      MT.__add = function(a, b)
        if not is_self(a) then err_type('vector3', 'addition') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x+b.x, a.y+b.y, a.z+b.z) end
        err_type('vector3', 'addition')
      end
      MT.__sub = function(a, b)
        if not is_self(a) then err_type('vector3', 'subtraction') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x-b.x, a.y-b.y, a.z-b.z) end
        err_type('vector3', 'subtraction')
      end
      MT.__unm = function(v) return immutable_vector3(-v.x, -v.y, -v.z) end
      MT.__eq = function(a, b)
        return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z
      end
      MT.__mul = function(a, b)
        if type(a) == 'number' then
          if not is_self(b) then err_type('vector3', 'multiplication') end
          return immutable_vector3(a*b.x, a*b.y, a*b.z)
        end
        if not is_self(a) then err_type('vector3', 'multiplication') end
        if type(b) == 'number' then return immutable_vector3(a.x*b, a.y*b, a.z*b) end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
        err_type('vector3', 'multiplication')
      end
      MT.__div = function(a, scalar)
        if not is_self(a) then err_type('vector3', 'division') end
        if type(scalar) ~= 'number' then err_scalar('vector3', 'divided') end
        return immutable_vector3(a.x/scalar, a.y/scalar, a.z/scalar)
      end
      MT.__pow = function(a, b)
        if not is_self(a) then err_type('vector3', 'cross') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
        err_type('vector3', 'cross')
      end
      MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g)'):format(v.x, v.y, v.z) end
      MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
      Methods.length2 = function(v)
        if not is_self(v) then err_type('vector3', 'length2') end
        return v.x*v.x + v.y*v.y + v.z*v.z
      end
      Methods.length = function(v)
        if not is_self(v) then err_type('vector3', 'length') end
        return sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
      end
      Methods.normalize = function(v)
        if not is_self(v) then err_type('vector3', 'normalize') end
        local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
        if len > 0 then return immutable_vector3(v.x/len, v.y/len, v.z/len), len end
        return immutable_vector3(0, 0, 0), len
      end
      Methods.dot = function(a, b)
        if not is_self(a) then err_type('vector3', 'dot') end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
        err_type('vector3', 'dot')
      end
      Methods.cross = function(a, b)
        if not is_self(a) then err_type('vector3', 'cross') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
        err_type('vector3', 'cross')
      end
      Methods.emul = function(a, b)
        if not is_self(a) then err_type('vector3', 'element multiplication') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x*b.x, a.y*b.y, a.z*b.z) end
        err_type('vector3', 'element multiplication')
      end
      Methods.ediv = function(a, b)
        if not is_self(a) then err_type('vector3', 'element division') end
        if is_self(b) or is_other(b) then return immutable_vector3(a.x/b.x, a.y/b.y, a.z/b.z) end
        err_type('vector3', 'element division')
      end
      Methods.is = function(v) return is_self(v) or is_other(v) end
      Methods.swizzle = make_swizzle(swizzle3_component, true)
      MT.__index = Methods
      return MT
    end
    MT.__add = function(a, b)
      if not is_self(a) then err_type('vector3', 'addition') end
      if is_self(b) or is_other(b) then return vector3(a.x+b.x, a.y+b.y, a.z+b.z) end
      err_type('vector3', 'addition')
    end
    MT.__sub = function(a, b)
      if not is_self(a) then err_type('vector3', 'subtraction') end
      if is_self(b) or is_other(b) then return vector3(a.x-b.x, a.y-b.y, a.z-b.z) end
      err_type('vector3', 'subtraction')
    end
    MT.__unm = function(v) return vector3(-v.x, -v.y, -v.z) end
    MT.__eq = function(a, b)
      return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z
    end
    MT.__mul = function(a, b)
      if type(a) == 'number' then
        if not is_self(b) then err_type('vector3', 'multiplication') end
        return vector3(a*b.x, a*b.y, a*b.z)
      end
      if not is_self(a) then err_type('vector3', 'multiplication') end
      if type(b) == 'number' then return vector3(a.x*b, a.y*b, a.z*b) end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
      err_type('vector3', 'multiplication')
    end
    MT.__div = function(a, scalar)
      if not is_self(a) then err_type('vector3', 'division') end
      if type(scalar) ~= 'number' then err_scalar('vector3', 'divided') end
      return vector3(a.x/scalar, a.y/scalar, a.z/scalar)
    end
    MT.__pow = function(a, b)
      if not is_self(a) then err_type('vector3', 'cross') end
      if is_self(b) or is_other(b) then return vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
      err_type('vector3', 'cross')
    end
    MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g)'):format(v.x, v.y, v.z) end
    MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
    Methods.length2 = function(v)
      if not is_self(v) then err_type('vector3', 'length2') end
      return v.x*v.x + v.y*v.y + v.z*v.z
    end
    Methods.length = function(v)
      if not is_self(v) then err_type('vector3', 'length') end
      return sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
    end
    Methods.normalize = function(v)
      if not is_self(v) then err_type('vector3', 'normalize') end
      local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
      if len > 0 then return vector3(v.x/len, v.y/len, v.z/len), len end
      return vector3(0, 0, 0), len
    end
    Methods.dot = function(a, b)
      if not is_self(a) then err_type('vector3', 'dot') end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
      err_type('vector3', 'dot')
    end
    Methods.cross = function(a, b)
      if not is_self(a) then err_type('vector3', 'cross') end
      if is_self(b) or is_other(b) then return vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x) end
      err_type('vector3', 'cross')
    end
    Methods.emul = function(a, b)
      if not is_self(a) then err_type('vector3', 'element multiplication') end
      if is_self(b) or is_other(b) then return vector3(a.x*b.x, a.y*b.y, a.z*b.z) end
      err_type('vector3', 'element multiplication')
    end
    Methods.ediv = function(a, b)
      if not is_self(a) then err_type('vector3', 'element division') end
      if is_self(b) or is_other(b) then return vector3(a.x/b.x, a.y/b.y, a.z/b.z) end
      err_type('vector3', 'element division')
    end
    Methods.is = function(v) return is_self(v) or is_other(v) end
    Methods.swizzle = make_swizzle(swizzle3_component, false)
    MT.__index = Methods
    return MT
  end

  local function vec4_mt(immutable, is_self, is_other)
    local Methods = setmetatable({}, nil_index)
    local MT = {}
    if immutable then
      MT.__add = function(a, b)
        if not is_self(a) then err_type('vector4', 'addition') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x+b.x, a.y+b.y, a.z+b.z, a.w+b.w) end
        err_type('vector4', 'addition')
      end
      MT.__sub = function(a, b)
        if not is_self(a) then err_type('vector4', 'subtraction') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x-b.x, a.y-b.y, a.z-b.z, a.w-b.w) end
        err_type('vector4', 'subtraction')
      end
      MT.__unm = function(v) return immutable_vector4(-v.x, -v.y, -v.z, -v.w) end
      MT.__eq = function(a, b)
        return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
      end
      MT.__mul = function(a, b)
        if type(a) == 'number' then
          if not is_self(b) then err_type('vector4', 'multiplication') end
          return immutable_vector4(a*b.x, a*b.y, a*b.z, a*b.w)
        end
        if not is_self(a) then err_type('vector4', 'multiplication') end
        if type(b) == 'number' then return immutable_vector4(a.x*b, a.y*b, a.z*b, a.w*b) end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
        err_type('vector4', 'multiplication')
      end
      MT.__div = function(a, scalar)
        if not is_self(a) then err_type('vector4', 'division') end
        if type(scalar) ~= 'number' then err_scalar('vector4', 'divided') end
        return immutable_vector4(a.x/scalar, a.y/scalar, a.z/scalar, a.w/scalar)
      end
      MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g, %.38g)'):format(v.x, v.y, v.z, v.w) end
      MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w) end
      Methods.length2 = function(v)
        if not is_self(v) then err_type('vector4', 'length2') end
        return v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w
      end
      Methods.length = function(v)
        if not is_self(v) then err_type('vector4', 'length') end
        return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
      end
      Methods.normalize = function(v)
        if not is_self(v) then err_type('vector4', 'normalize') end
        local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
        if len > 0 then return immutable_vector4(v.x/len, v.y/len, v.z/len, v.w/len), len end
        return immutable_vector4(0, 0, 0, 0), len
      end
      Methods.dot = function(a, b)
        if not is_self(a) then err_type('vector4', 'dot') end
        if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
        err_type('vector4', 'dot')
      end
      Methods.emul = function(a, b)
        if not is_self(a) then err_type('vector4', 'element multiplication') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x*b.x, a.y*b.y, a.z*b.z, a.w*b.w) end
        err_type('vector4', 'element multiplication')
      end
      Methods.ediv = function(a, b)
        if not is_self(a) then err_type('vector4', 'element division') end
        if is_self(b) or is_other(b) then return immutable_vector4(a.x/b.x, a.y/b.y, a.z/b.z, a.w/b.w) end
        err_type('vector4', 'element division')
      end
      Methods.is = function(v) return is_self(v) or is_other(v) end
      Methods.swizzle = make_swizzle(swizzle4_component, true)
      MT.__index = Methods
      return MT
    end
    MT.__add = function(a, b)
      if not is_self(a) then err_type('vector4', 'addition') end
      if is_self(b) or is_other(b) then return vector4(a.x+b.x, a.y+b.y, a.z+b.z, a.w+b.w) end
      err_type('vector4', 'addition')
    end
    MT.__sub = function(a, b)
      if not is_self(a) then err_type('vector4', 'subtraction') end
      if is_self(b) or is_other(b) then return vector4(a.x-b.x, a.y-b.y, a.z-b.z, a.w-b.w) end
      err_type('vector4', 'subtraction')
    end
    MT.__unm = function(v) return vector4(-v.x, -v.y, -v.z, -v.w) end
    MT.__eq = function(a, b)
      return (is_self(a) or is_other(a)) and (is_self(b) or is_other(b)) and a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w
    end
    MT.__mul = function(a, b)
      if type(a) == 'number' then
        if not is_self(b) then err_type('vector4', 'multiplication') end
        return vector4(a*b.x, a*b.y, a*b.z, a*b.w)
      end
      if not is_self(a) then err_type('vector4', 'multiplication') end
      if type(b) == 'number' then return vector4(a.x*b, a.y*b, a.z*b, a.w*b) end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
      err_type('vector4', 'multiplication')
    end
    MT.__div = function(a, scalar)
      if not is_self(a) then err_type('vector4', 'division') end
      if type(scalar) ~= 'number' then err_scalar('vector4', 'divided') end
      return vector4(a.x/scalar, a.y/scalar, a.z/scalar, a.w/scalar)
    end
    MT.__tostring = function(v) return ('(%.38g, %.38g, %.38g, %.38g)'):format(v.x, v.y, v.z, v.w) end
    MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w) end
    Methods.length2 = function(v)
      if not is_self(v) then err_type('vector4', 'length2') end
      return v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w
    end
    Methods.length = function(v)
      if not is_self(v) then err_type('vector4', 'length') end
      return sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
    end
    Methods.normalize = function(v)
      if not is_self(v) then err_type('vector4', 'normalize') end
      local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z + v.w*v.w)
      if len > 0 then return vector4(v.x/len, v.y/len, v.z/len, v.w/len), len end
      return vector4(0, 0, 0, 0), len
    end
    Methods.dot = function(a, b)
      if not is_self(a) then err_type('vector4', 'dot') end
      if is_self(b) or is_other(b) then return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end
      err_type('vector4', 'dot')
    end
    Methods.emul = function(a, b)
      if not is_self(a) then err_type('vector4', 'element multiplication') end
      if is_self(b) or is_other(b) then return vector4(a.x*b.x, a.y*b.y, a.z*b.z, a.w*b.w) end
      err_type('vector4', 'element multiplication')
    end
    Methods.ediv = function(a, b)
      if not is_self(a) then err_type('vector4', 'element division') end
      if is_self(b) or is_other(b) then return vector4(a.x/b.x, a.y/b.y, a.z/b.z, a.w/b.w) end
      err_type('vector4', 'element division')
    end
    Methods.is = function(v) return is_self(v) or is_other(v) end
    Methods.swizzle = make_swizzle(swizzle4_component, false)
    MT.__index = Methods
    return MT
  end

  local function box_vertex(b, x, y, z)
    local qx, qy, qz, qw = b.qx, b.qy, b.qz, b.qw
    local tx = 2 * (qy*z - qz*y)
    local ty = 2 * (qz*x - qx*z)
    local tz = 2 * (qx*y - qy*x)
    return immutable_vector3(
      b.center.x + x + qw*tx + qy*tz - qz*ty,
      b.center.y + y + qw*ty + qz*tx - qx*tz,
      b.center.z + z + qw*tz + qx*ty - qy*tx)
  end

  local function box_mt()
    local MT = {}
    MT.__index = function(b, key)
      if key == 'vertices' then
        local hx, hy, hz = b.halfSize.x, b.halfSize.y, b.halfSize.z
        return {
          box_vertex(b, -hx, -hy, -hz),
          box_vertex(b,  hx, -hy, -hz),
          box_vertex(b,  hx,  hy, -hz),
          box_vertex(b, -hx,  hy, -hz),
          box_vertex(b, -hx, -hy,  hz),
          box_vertex(b,  hx, -hy,  hz),
          box_vertex(b,  hx,  hy,  hz),
          box_vertex(b, -hx,  hy,  hz),
        }
      end
      return nil
    end
    MT.__eq = function(a, b)
      return is_box(a) and is_box(b) and
        a.center.x == b.center.x and a.center.y == b.center.y and a.center.z == b.center.z and
        a.halfSize.x == b.halfSize.x and a.halfSize.y == b.halfSize.y and a.halfSize.z == b.halfSize.z and
        a.qx == b.qx and a.qy == b.qy and a.qz == b.qz and a.qw == b.qw
    end
    MT.__tostring = function(b)
      return ('Box{ center(%.38g, %.38g, %.38g) halfSize(%.38g, %.38g, %.38g) }'):
        format(b.center.x, b.center.y, b.center.z, b.halfSize.x, b.halfSize.y, b.halfSize.z)
    end
    return MT
  end

  local function box_constructor(center, halfSize)
    if not (is_mvec3(center) or is_ivec3(center)) then
      error('box constructor requires center to be a vector3', 3)
    end
    if not (is_mvec3(halfSize) or is_ivec3(halfSize)) then
      error('box constructor requires halfSize to be a vector3', 3)
    end
    return box(immutable_vector3(center.x, center.y, center.z), immutable_vector3(halfSize.x, halfSize.y, halfSize.z), 0, 0, 0, 1)
  end

  vector2 = ffi.metatype(vector2_type, vec2_mt(false, is_mvec2, is_ivec2))
  immutable_vector2 = ffi.metatype(immutable_vector2_type, vec2_mt(true, is_ivec2, is_mvec2))
  vector3 = ffi.metatype(vector3_type, vec3_mt(false, is_mvec3, is_ivec3))
  immutable_vector3 = ffi.metatype(immutable_vector3_type, vec3_mt(true, is_ivec3, is_mvec3))
  vector4 = ffi.metatype(vector4_type, vec4_mt(false, is_mvec4, is_ivec4))
  immutable_vector4 = ffi.metatype(immutable_vector4_type, vec4_mt(true, is_ivec4, is_mvec4))
  box = ffi.metatype(box_type, box_mt())
  return { vector2, vector3, vector4, immutable_vector2, immutable_vector3, immutable_vector4, box_constructor }
end

local function ensure_geometry()
  local vector2 = vector2_ctor
  if not vector2 then
    local ffi, cached = loadffi()
    local ctors = cached or build_geometry(ffi)
    vector2_ctor, vector3_ctor, vector4_ctor = ctors[1], ctors[2], ctors[3]
    immutable_vector2_ctor, immutable_vector3_ctor, immutable_vector4_ctor = ctors[4], ctors[5], ctors[6]
    box_ctor = ctors[7]
    if not cached then loadffi(ctors) end
  end
end

math.vector2 = function(...)
  check_constructor('vector2', 2, ...)
  local x, y = ...
  ensure_geometry()
  return vector2_ctor(x, y)
end

math.vector3 = function(...)
  check_constructor('vector3', 3, ...)
  local x, y, z = ...
  ensure_geometry()
  return vector3_ctor(x, y, z)
end

math.vector4 = function(...)
  check_constructor('vector4', 4, ...)
  local x, y, z, w = ...
  ensure_geometry()
  return vector4_ctor(x, y, z, w)
end

math.immutableVector2 = function(...)
  check_constructor('immutableVector2', 2, ...)
  local x, y = ...
  ensure_geometry()
  return immutable_vector2_ctor(x, y)
end

math.immutableVector3 = function(...)
  check_constructor('immutableVector3', 3, ...)
  local x, y, z = ...
  ensure_geometry()
  return immutable_vector3_ctor(x, y, z)
end

math.immutableVector4 = function(...)
  check_constructor('immutableVector4', 4, ...)
  local x, y, z, w = ...
  ensure_geometry()
  return immutable_vector4_ctor(x, y, z, w)
end

math.box = function(...)
  local n = select('#', ...)
  if n == 1 then
    error('box transform constructor is not supported', 2)
  end
  if n ~= 2 then
    error('box constructor requires center and halfSize vector3 arguments', 2)
  end
  local center, halfSize = ...
  ensure_geometry()
  return box_ctor(center, halfSize)
end
