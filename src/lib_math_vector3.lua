local math, loadffi = ...
local sqrt = math.sqrt
local vector3_ctor

local function build_vector3(ffi)
  if type(ffi) ~= 'table' or type(ffi.typeof) ~= 'function' or
     type(ffi.metatype) ~= 'function' or type(ffi.istype) ~= 'function' then
    error('math.vector3 requires a valid ffi module', 3)
  end
  local vector3_type = ffi.typeof('struct { float x, y, z; }')
  local Vec3MT = {}
  local vector3
  local function is_vec3(v) return ffi.istype(vector3_type, v) end
  local function err_not_vec3(op, a, b)
    error(tostring(b)..' is not a vector type! Could not '..op..' it with '..tostring(a), 3)
  end
  local function err_number(op, v)
    error('vector3 can only be '..op..' by scalar, got '..type(v), 3)
  end
  Vec3MT.__add = function(a, b)
    if not is_vec3(a) then err_not_vec3('add', b, a) end
    if not is_vec3(b) then err_not_vec3('add', a, b) end
    local r = vector3(); r.x, r.y, r.z = a.x+b.x, a.y+b.y, a.z+b.z; return r
  end
  Vec3MT.__sub = function(a, b)
    if not is_vec3(a) then err_not_vec3('subtract', b, a) end
    if not is_vec3(b) then err_not_vec3('subtract', a, b) end
    local r = vector3(); r.x, r.y, r.z = a.x-b.x, a.y-b.y, a.z-b.z; return r
  end
  Vec3MT.__unm = function(v)
    local r = vector3(); r.x, r.y, r.z = -v.x, -v.y, -v.z; return r
  end
  Vec3MT.__eq = function(a, b)
    return is_vec3(a) and is_vec3(b) and a.x == b.x and a.y == b.y and a.z == b.z
  end
  Vec3MT.__mul = function(a, b)
    local ta, tb = type(a), type(b)
    if ta == 'number' then
      if not is_vec3(b) then err_not_vec3('multiply', a, b) end
      local r = vector3(); r.x, r.y, r.z = a*b.x, a*b.y, a*b.z; return r
    end
    if not is_vec3(a) then err_not_vec3('multiply', b, a) end
    if tb == 'number' then
      local r = vector3(); r.x, r.y, r.z = a.x*b, a.y*b, a.z*b; return r
    end
    if is_vec3(b) then return a.x*b.x + a.y*b.y + a.z*b.z end
    err_not_vec3('multiply', a, b)
  end
  Vec3MT.__div = function(a, scalar)
    if not is_vec3(a) then err_not_vec3('divide', scalar, a) end
    if type(scalar) ~= 'number' then err_number('divided', scalar) end
    local r = vector3(); r.x, r.y, r.z = a.x/scalar, a.y/scalar, a.z/scalar; return r
  end
  Vec3MT.__pow = function(a, b)
    if not is_vec3(a) then err_not_vec3('cross', b, a) end
    if not is_vec3(b) then err_not_vec3('cross', a, b) end
    local r = vector3()
    r.x = a.y*b.z - a.z*b.y; r.y = a.z*b.x - a.x*b.z; r.z = a.x*b.y - a.y*b.x
    return r
  end
  Vec3MT.__tostring = function(v) return ('vector3(%.2f, %.2f, %.2f)'):format(v.x, v.y, v.z) end
  Vec3MT.__len = function(v) return sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
  local Vec3Methods = {}
  Vec3Methods.length2 = function(v)
    if not is_vec3(v) then err_not_vec3('measure', nil, v) end
    return v.x*v.x + v.y*v.y + v.z*v.z
  end
  Vec3Methods.length = function(v)
    if not is_vec3(v) then err_not_vec3('measure', nil, v) end
    return sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
  end
  Vec3Methods.normalize = function(v)
    if not is_vec3(v) then err_not_vec3('normalize', nil, v) end
    local len = sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
    local r = vector3()
    if len > 0 then r.x, r.y, r.z = v.x/len, v.y/len, v.z/len else r.x, r.y, r.z = 0, 0, 0 end
    return r, len
  end
  Vec3Methods.dot = function(a, b)
    if not is_vec3(a) then err_not_vec3('dot', b, a) end
    if not is_vec3(b) then err_not_vec3('dot', a, b) end
    return a.x*b.x + a.y*b.y + a.z*b.z
  end
  Vec3Methods.cross = function(a, b)
    if not is_vec3(a) then err_not_vec3('cross', b, a) end
    if not is_vec3(b) then err_not_vec3('cross', a, b) end
    local r = vector3()
    r.x = a.y*b.z - a.z*b.y; r.y = a.z*b.x - a.x*b.z; r.z = a.x*b.y - a.y*b.x
    return r
  end
  Vec3Methods.emul = function(a, b)
    if not is_vec3(a) then err_not_vec3('multiply', b, a) end
    if not is_vec3(b) then err_not_vec3('multiply', a, b) end
    local r = vector3(); r.x, r.y, r.z = a.x*b.x, a.y*b.y, a.z*b.z; return r
  end
  Vec3Methods.ediv = function(a, b)
    if not is_vec3(a) then err_not_vec3('divide', b, a) end
    if not is_vec3(b) then err_not_vec3('divide', a, b) end
    local r = vector3(); r.x, r.y, r.z = a.x/b.x, a.y/b.y, a.z/b.z; return r
  end
  Vec3Methods.is = function(v) return is_vec3(v) end
  Vec3MT.__index = Vec3Methods
  vector3 = ffi.metatype(vector3_type, Vec3MT)
  return vector3
end

math.vector3 = function(x, y, z)
  if type(x) ~= 'number' then error('bad argument #1 to vector3 (number expected)', 2) end
  if type(y) ~= 'number' then error('bad argument #2 to vector3 (number expected)', 2) end
  if type(z) ~= 'number' then error('bad argument #3 to vector3 (number expected)', 2) end
  local vector3 = vector3_ctor
  if not vector3 then
    local ffi, cached = loadffi()
    vector3 = cached or build_vector3(ffi)
    vector3_ctor = vector3
    if not cached then loadffi(vector3) end
  end
  return vector3(x, y, z)
end
