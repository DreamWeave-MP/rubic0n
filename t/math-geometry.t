# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

my $cwd = cwd;
my $dir = tempdir "testlj_math_geometry_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $fh <<'LUA';
local function fail(msg)
  error(msg, 2)
end

local function assert_true(v, msg)
  if not v then fail(msg) end
end

local function assert_false(v, msg)
  if v then fail(msg) end
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail(('%s: expected %s, got %s'):format(msg, tostring(expected), tostring(actual)))
  end
end

local function assert_close(actual, expected, msg, eps)
  eps = eps or 0.00001
  if math.abs(actual - expected) > eps then
    fail(('%s: expected %.17g, got %.17g'):format(msg, expected, actual))
  end
end

local function assert_vec2(v, x, y, msg)
  assert_close(v.x, x, msg..' x')
  assert_close(v.y, y, msg..' y')
end

local function assert_vec3(v, x, y, z, msg)
  assert_close(v.x, x, msg..' x')
  assert_close(v.y, y, msg..' y')
  assert_close(v.z, z, msg..' z')
end

local function assert_vec4(v, x, y, z, w, msg)
  assert_close(v.x, x, msg..' x')
  assert_close(v.y, y, msg..' y')
  assert_close(v.z, z, msg..' z')
  assert_close(v.w, w, msg..' w')
end

local function assert_error(fn, msg)
  local ok, err = pcall(fn)
  if ok then fail(msg..': expected error') end
  return tostring(err)
end

local function is_nan(v)
  return v ~= v
end

-- Accessing constructor tables/functions should stay lazy; constructing may
-- legitimately load ffi. Missing API support is skipped, but constructor
-- failures are fatal.
local ffi_loaded_before_geometry_access = package.loaded.ffi ~= nil
local have_api = type(math.vector3) == 'function' and type(math.box) == 'function' and
  type(math.transform) == 'table' and type(math.color) == 'table'
if not have_api then os.exit(77) end
if not ffi_loaded_before_geometry_access then
  assert_eq(package.loaded.ffi, nil, 'geometry API table/function access should not load ffi')
end
local ok_ctor, ctor_or_err = pcall(function() return math.vector3(1, 2, 3) end)
assert(ok_ctor, ctor_or_err)
if not ffi_loaded_before_geometry_access then
  assert_true(package.loaded.ffi ~= nil, 'first geometry constructor should load ffi')
end

local pi = math.pi

-- Mutable vectors expose writable fields for all dimensions.
local v2 = math.vector2(1, 2)
v2.x, v2.y = 3, 4
assert_vec2(v2, 3, 4, 'vector2 mutable fields')
local v3 = ctor_or_err
v3.x, v3.y, v3.z = 4, 5, 6
assert_vec3(v3, 4, 5, 6, 'vector3 mutable fields')
local v4 = math.vector4(1, 2, 3, 4)
v4.x, v4.y, v4.z, v4.w = 5, 6, 7, 8
assert_vec4(v4, 5, 6, 7, 8, 'vector4 mutable fields')
assert_vec4(v4.wzyx, 8, 7, 6, 5, 'vector4 reverse swizzle')

-- Immutable vectors reject writes and preserve the original value.
local iv2 = math.immutableVector2(1, 2)
local iv3 = math.immutableVector3(1, 2, 3)
local iv4 = math.immutableVector4(1, 2, 3, 4)
assert_error(function() iv2.x = 9 end, 'immutableVector2 rejects writes')
assert_error(function() iv3.y = 9 end, 'immutableVector3 rejects writes')
assert_error(function() iv4.w = 9 end, 'immutableVector4 rejects writes')
assert_vec2(iv2, 1, 2, 'immutableVector2 unchanged')
assert_vec3(iv3, 1, 2, 3, 'immutableVector3 unchanged')
assert_vec4(iv4, 1, 2, 3, 4, 'immutableVector4 unchanged')

-- Vector arithmetic, dot/cross/rotate, lengths, zero normalize, and NaN propagation.
assert_vec3(math.vector3(1, 2, 3) + math.immutableVector3(4, 5, 6), 5, 7, 9, 'vector add')
assert_vec4(math.vector4(1, 2, 3, 4) + math.immutableVector4(4, 3, 2, 1), 5, 5, 5, 5, 'vector4 add')
assert_vec3(math.vector3(5, 7, 9) - math.vector3(1, 2, 3), 4, 5, 6, 'vector subtract')
assert_vec3(-math.vector3(1, -2, 3), -1, 2, -3, 'vector unary minus')
assert_vec3(math.vector3(1, 2, 3) * 2, 2, 4, 6, 'vector scalar multiply rhs')
assert_vec3(3 * math.vector3(1, 2, 3), 3, 6, 9, 'vector scalar multiply lhs')
assert_vec3(math.vector3(2, 4, 6) / 2, 1, 2, 3, 'vector scalar divide')
assert_close(math.vector3(1, 2, 3) * math.vector3(4, 5, 6), 32, 'vector dot operator')
assert_close(math.vector3(1, 2, 3):dot(math.vector3(4, 5, 6)), 32, 'vector dot method')
assert_vec3(math.vector3(1, 0, 0) ^ math.vector3(0, 1, 0), 0, 0, 1, 'vector3 cross operator')
assert_vec3(math.vector3(0, 1, 0):cross(math.vector3(0, 0, 1)), 1, 0, 0, 'vector3 cross method')
assert_vec2(math.vector2(1, 0):rotate(pi / 2), 0, 1, 'vector2 rotate positive angle')
assert_close(math.vector3(2, 3, 6):length2(), 49, 'vector length2')
assert_close(math.vector3(2, 3, 6):length(), 7, 'vector length')
local norm, norm_len = math.vector3(0, 3, 4):normalize()
assert_vec3(norm, 0, 0.6, 0.8, 'vector normalize finite')
assert_close(norm_len, 5, 'vector normalize returns length')
local znorm, zlen = math.vector3(0, 0, 0):normalize()
assert_vec3(znorm, 0, 0, 0, 'zero vector normalize returns zero')
assert_close(zlen, 0, 'zero vector normalize length')
local nan = 0 / 0
local nnorm, nlen = math.vector3(nan, 1, 0):normalize()
assert_true(is_nan(nlen), 'NaN vector normalize length remains NaN')
assert_true(is_nan(nnorm.x) or is_nan(nnorm.y) or is_nan(nnorm.z), 'NaN vector normalize does not return finite zero')

-- Swizzles are property-based; there is intentionally no swizzle method.
local sw = math.vector3(1, 2, 3)
assert_vec2(sw.xy, 1, 2, 'vector xy swizzle')
assert_vec3(sw.zyx, 3, 2, 1, 'vector zyx swizzle')
assert_vec4(sw['0xy1'], 0, 1, 2, 1, 'vector constant swizzle')
assert_eq(sw.swizzle, nil, 'vector swizzle method is absent')
assert_true(math.vector3(1, 2, 3) == math.immutableVector3(1, 2, 3), 'equal vector values compare equal across mutability')
assert_false(math.vector3(1, 2, 3) == math.vector3(1, 2, 4), 'different vector values compare unequal')
assert_false(math.vector3(nan, 0, 0) == math.vector3(nan, 0, 0), 'NaN vector equality is false')

-- Box fields are immutable/readable; vertices preserve OpenMW ordering.
local b = math.box(math.vector3(10, 20, 30), math.vector3(1, 2, 3))
assert_vec3(b.center, 10, 20, 30, 'box center readable')
assert_vec3(b.halfSize, 1, 2, 3, 'box halfSize readable')
assert_error(function() b.center.x = 99 end, 'box center vector is immutable')
assert_error(function() b.halfSize.z = 99 end, 'box halfSize vector is immutable')
local verts = b.vertices
assert_eq(#verts, 8, 'box vertices count')
assert_vec3(verts[1], 9, 18, 27, 'box vertex 1 order')
assert_vec3(verts[2], 11, 18, 27, 'box vertex 2 order')
assert_vec3(verts[3], 11, 22, 27, 'box vertex 3 order')
assert_vec3(verts[4], 9, 22, 27, 'box vertex 4 order')
assert_vec3(verts[5], 9, 18, 33, 'box vertex 5 order')
assert_vec3(verts[8], 9, 22, 33, 'box vertex 8 order')
local bt = b.transform
assert_vec3(bt * math.vector3(1, 1, 1), 11, 22, 33, 'box transform applies halfSize scale and center')
local b2 = math.box(math.transform.move(1, 2, 3) * math.transform.scale(2, 3, 4))
assert_vec3(b2.center, 1, 2, 3, 'box from transform center')
assert_vec3(b2.halfSize, 2, 3, 4, 'box from transform scale')
local bq = math.box(math.transform.rotateZ(pi / 2))
assert_vec3(bq.center, 0, 0, 0, 'box from quaternion center')
assert_vec3(bq.halfSize, 1, 1, 1, 'box from quaternion halfSize')
assert_vec3(bq.vertices[1], -1, 1, -1, 'box from quaternion rotated vertex')

-- Transform construction, application signs, composition, inverse, errors, angles, tostring and equality.
local T = math.transform
assert_true(T.identity ~= nil, 'transform.identity exists')
assert_vec3(T.identity * math.vector3(1, 2, 3), 1, 2, 3, 'transform.identity applies as identity')
assert_vec3(T.move(1, 2, 3) * math.vector3(4, 5, 6), 5, 7, 9, 'transform move')
assert_vec3(T.scale(2, 3, 4) * math.vector3(1, 1, 1), 2, 3, 4, 'transform scale')
assert_vec3(T.rotate(pi / 2, math.vector3(0, 0, -1)) * math.vector3(1, 0, 0), 0, -1, 0, 'transform rotate axis')
assert_vec3(T.rotateX(pi / 2) * math.vector3(0, 1, 0), 0, 0, -1, 'transform rotateX sign')
assert_vec3(T.rotateY(pi / 2) * math.vector3(0, 0, 1), -1, 0, 0, 'transform rotateY sign')
assert_vec3(T.rotateZ(pi / 2) * math.vector3(1, 0, 0), 0, -1, 0, 'transform rotateZ sign')
assert_vec3((T.move(10, 0, 0) * T.scale(2, 3, 4)) * math.vector3(1, 1, 1), 12, 3, 4, 'transform composition applies rhs first')
assert_vec3((T.rotateZ(pi / 2) * T.rotateX(pi / 2)) * math.vector3(0, 1, 0), 0, 0, -1, 'TransformQ times TransformQ')
local q = T.rotateZ(0.75) * T.rotateX(-0.5)
assert_vec3(q:inverse() * (q * math.vector3(2, -3, 4)), 2, -3, 4, 'TransformQ inverse round-trip')
assert_vec3((T.move(1, 0, 0) * T.rotateZ(pi / 2)) * math.vector3(1, 0, 0), 1, -1, 0, 'TransformM times TransformQ')
assert_vec3((T.rotateZ(pi / 2) * T.move(1, 0, 0)) * math.vector3(1, 0, 0), 0, -2, 0, 'TransformQ times TransformM')
local finite = T.move(3, -4, 5) * T.rotateY(0.25) * T.scale(2, 3, 4)
local original = math.vector3(7, 8, 9)
assert_vec3(finite:inverse() * (finite * original), 7, 8, 9, 'finite transform inverse round-trip')
assert_error(function() return T.scale(1, 0, 1):inverse() end, 'singular matrix inverse throws')
local nan_rot = T.rotate(1, math.vector3(nan, 0, 0))
local nan_applied = nan_rot * math.vector3(0, 1, 0)
assert_true(is_nan(nan_applied.x) or is_nan(nan_applied.y) or is_nan(nan_applied.z), 'NaN axis rotate propagates')
assert_true(tostring(nan_rot):lower():find('nan', 1, true) ~= nil, 'NaN transform tostring includes nan')
assert_close(T.rotateZ(pi / 2):getYaw(), pi / 2, 'transform getYaw simple rotateZ')
assert_close(T.rotateZ(pi / 2):getPitch(), 0, 'transform getPitch simple rotateZ')
local pitch, yaw = T.rotateZ(pi / 2):getAnglesXZ()
assert_close(pitch, 0, 'transform getAnglesXZ pitch')
assert_close(yaw, pi / 2, 'transform getAnglesXZ yaw')
local z, y, x = T.rotateZ(pi / 2):getAnglesZYX()
assert_close(z, pi / 2, 'transform getAnglesZYX z')
assert_close(y, 0, 'transform getAnglesZYX y')
assert_close(x, 0, 'transform getAnglesZYX x')
assert_true(T.move(1, 2, 3) == T.move(1, 2, 3), 'TransformM equal finite')
assert_false(T.move(1, 2, 3) == T.move(1, 2, 4), 'TransformM different finite')
assert_true(T.rotateZ(1) == T.rotateZ(1), 'TransformQ equal finite')
assert_false(T.rotateZ(1) == T.rotateZ(2), 'TransformQ different finite')
assert_false(T.move(0, 0, 0) == T.rotateZ(0), 'mixed TransformM/TransformQ equality false')
assert_false(T.move(nan, 0, 0) == T.move(nan, 0, 0), 'NaN TransformM equality false')

print('ok')
LUA
close $fh;

my $rc;
{
    local $ENV{LUA_INIT};
    delete $ENV{LUA_INIT};
    system qq{"$luajit" test.lua >stdout.txt 2>stderr.txt};
    $rc = $? >> 8;
}

open my $outfh, '<', 'stdout.txt' or die "Cannot open stdout.txt: $!";
my $out = do { local $/; <$outfh> };
close $outfh;

open my $errfh, '<', 'stderr.txt' or die "Cannot open stderr.txt: $!";
my $err = do { local $/; <$errfh> };
close $errfh;

chdir $cwd or die $!;

plan skip_all => 'LuaJIT built without FFI math geometry support' if $rc == 77;

plan tests => 1;

is "$rc:$out$err", "0:ok\n", 'math geometry FFI-backed API regression coverage';
