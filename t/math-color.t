# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

my $cwd = cwd;
my $dir = tempdir "testlj_math_color_XXXXXXX", CLEANUP => 1;
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

local function assert_close(actual, expected, msg)
  if math.abs(actual - expected) > 0.000001 then
    fail(('%s: expected %.17g, got %.17g'):format(msg, expected, actual))
  end
end

local function assert_error(fn, msg)
  local ok, err = pcall(fn)
  if ok then fail(msg..': expected error') end
  return tostring(err)
end

local ffi_loaded_before_color_access = package.loaded.ffi ~= nil
local color = math.color
if color == nil then os.exit(77) end

if not ffi_loaded_before_color_access then
  assert_eq(package.loaded.ffi, nil, 'math.color table access should not load ffi')
end

local rgb = color.rgb(0.25, 0.5, 0.75)
if not ffi_loaded_before_color_access then
  assert_true(package.loaded.ffi ~= nil, 'first color constructor should load ffi')
end
assert_close(rgb.r, 0.25, 'rgb r field')
assert_close(rgb.g, 0.5, 'rgb g field')
assert_close(rgb.b, 0.75, 'rgb b field')
assert_close(rgb.a, 1, 'rgb alpha defaults to 1')
assert_eq(tostring(rgb), '(0.25, 0.5, 0.75, 1)', 'simple color tostring shape')
assert_eq(rgb:asHex(), '3f7fbf', 'finite RGB converts to lowercase six-digit hex')

local rgb_extra = color.rgb(0.1, 0.2, 0.3, 'ignored')
assert_close(rgb_extra.r, 0.1, 'rgb ignores extra argument r')
assert_close(rgb_extra.g, 0.2, 'rgb ignores extra argument g')
assert_close(rgb_extra.b, 0.3, 'rgb ignores extra argument b')
assert_close(rgb_extra.a, 1, 'rgb ignores extra argument alpha')

local clamped = color.rgba(-1, 2, 0.5, 99)
assert_close(clamped.r, 0, 'rgba clamps low component')
assert_close(clamped.g, 1, 'rgba clamps high component')
assert_close(clamped.b, 0.5, 'rgba keeps in-range component')
assert_close(clamped.a, 1, 'rgba clamps high alpha')

local hex = color.hex('Aa00fF')
assert_close(hex.r, 0xaa / 255, 'hex accepts mixed case r')
assert_close(hex.g, 0, 'hex accepts mixed case g')
assert_close(hex.b, 1, 'hex accepts mixed case b')
assert_close(hex.a, 1, 'hex alpha defaults to 1')
assert_eq(hex:asHex(), 'aa00ff', 'hex asHex is lowercase')

local comma_rgb = color.commaString('255, 128, 0')
assert_close(comma_rgb.r, 1, 'commaString RGB r byte')
assert_close(comma_rgb.g, 128 / 255, 'commaString RGB g byte')
assert_close(comma_rgb.b, 0, 'commaString RGB b byte')
assert_close(comma_rgb.a, 1, 'commaString RGB alpha defaults to 255')
assert_eq(comma_rgb:asHex(), 'ff8000', 'commaString RGB asHex')

local comma_rgba = color.commaString('0,64,255,128')
assert_close(comma_rgba.r, 0, 'commaString RGBA r byte')
assert_close(comma_rgba.g, 64 / 255, 'commaString RGBA g byte')
assert_close(comma_rgba.b, 1, 'commaString RGBA b byte')
assert_close(comma_rgba.a, 128 / 255, 'commaString RGBA alpha byte')

local ok = pcall(function() rgb.r = 0 end)
assert_false(ok, 'color fields are read-only')
assert_close(rgb.r, 0.25, 'failed write leaves r field unchanged')

local as_rgb = rgb:asRgb()
assert_close(as_rgb.x, rgb.r, 'asRgb x')
assert_close(as_rgb.y, rgb.g, 'asRgb y')
assert_close(as_rgb.z, rgb.b, 'asRgb z')

local as_rgba = rgb:asRgba()
assert_close(as_rgba.x, rgb.r, 'asRgba x')
assert_close(as_rgba.y, rgb.g, 'asRgba y')
assert_close(as_rgba.z, rgb.b, 'asRgba z')
assert_close(as_rgba.w, rgb.a, 'asRgba w')

assert_true(color.rgb(0.1, 0.2, 0.3) == color.rgb(0.1, 0.2, 0.3), 'same colors compare equal')
assert_false(color.rgb(0.1, 0.2, 0.3) == color.rgb(0.1, 0.2, 0.4), 'different colors compare unequal')

local nan = 0 / 0
local nan_color_a = color.rgba(nan, 0, 0, 1)
local nan_color_b = color.rgba(nan, 0, 0, 1)
assert_false(nan_color_a == nan_color_a, 'NaN color is not equal to itself')
assert_false(nan_color_a == nan_color_b, 'NaN colors are not equal to each other')

assert_error(function() color.hex('abc') end, 'invalid hex rejects')
assert_error(function() color.commaString('1,2,three') end, 'invalid comma string rejects')
local nan_hex_error = assert_error(function() nan_color_a:asHex() end, 'NaN asHex rejects')
assert_true(nan_hex_error:find('NaN', 1, true) ~= nil, 'NaN asHex error mentions NaN')

local v = math.vector3(1, 2, 3)
local swizzled = v.yx
assert_close(swizzled.x, 2, 'vector property swizzle x')
assert_close(swizzled.y, 1, 'vector property swizzle y')
assert_eq(v.swizzle, nil, 'vector swizzle method is absent')

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

plan skip_all => 'LuaJIT built without FFI math.color support' if $rc == 77;

plan tests => 1;

is "$rc:$out$err", "0:ok\n", 'math.color FFI-backed API regression coverage';
