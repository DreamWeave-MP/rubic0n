# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

my $cwd = cwd;
my $dir = tempdir "testlj_math_geometry_noffi_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $fh <<'LUA';
local function fail(msg)
  error(msg, 2)
end

local ffi_ok, ffi = pcall(require, 'ffi')
if ffi_ok and type(ffi) == 'table' and type(ffi.cdef) == 'function' and
   type(ffi.typeof) == 'function' and pcall(ffi.typeof, 'int') then
  os.exit(77)
end

if math.vector3 ~= nil then fail('math.vector3 should be nil without FFI') end
if math.box ~= nil then fail('math.box should be nil without FFI') end
if math.transform ~= nil then fail('math.transform should be nil without FFI') end
if math.color ~= nil then fail('math.color should be nil without FFI') end

print('ok')
LUA
close $fh;

my $rc;
{
    local $ENV{LUA_INIT};
    local $ENV{LUA_PATH};
    local $ENV{LUA_CPATH};
    delete $ENV{LUA_INIT};
    delete $ENV{LUA_PATH};
    delete $ENV{LUA_CPATH};
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

plan skip_all => 'LuaJIT built with FFI support' if $rc == 77;

plan tests => 1;

is "$rc:$out$err", "0:ok\n", 'math geometry/color APIs are absent without FFI';
