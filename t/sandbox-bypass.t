# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;
plan tests => 1;

my $expect_enabled = $ENV{LUAJIT_TEST_SANDBOX_BYPASS} ? 1 : 0;
my $cwd = cwd;
my $dir = tempdir "testlj_sandbox_bypass_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
print $fh "local expect_enabled = $expect_enabled\n";
print $fh <<'LUA';
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(msg, tostring(expected), tostring(actual)), 2)
  end
end

assert_eq(select('#', 1, nil, 3), 3, 'select count')
assert_eq(select(2, 'a', 'b', 'c'), 'b', 'select index')

if expect_enabled == 1 then
  local bypass = select('sandbox.bypass')
  assert_eq(type(bypass), 'table', 'bypass table')
  assert_eq(select('sandbox.bypass'), bypass, 'bypass cache')
  assert_eq(type(bypass.require), 'function', 'bypass require')
  assert_eq(type(bypass.package), 'table', 'bypass package')
  assert_eq(type(bypass.io), 'table', 'bypass io')
  assert_eq(type(bypass.os), 'table', 'bypass os')
  assert_eq(type(bypass.debug), 'table', 'bypass debug')
else
  local ok = pcall(select, 'sandbox.bypass')
  assert_eq(ok, false, 'bypass disabled')
end

print('ok')
LUA
close $fh;

system qq{"$luajit" test.lua >stdout.txt 2>stderr.txt};
my $rc = $? >> 8;

open my $outfh, '<', 'stdout.txt' or die "Cannot open stdout.txt: $!";
my $out = do { local $/; <$outfh> };
close $outfh;

open my $errfh, '<', 'stderr.txt' or die "Cannot open stderr.txt: $!";
my $err = do { local $/; <$errfh> };
close $errfh;

chdir $cwd or die $!;

my $desc = $expect_enabled ?
    'sandbox bypass is available when explicitly enabled' :
    'sandbox bypass is disabled by default';
is "$rc:$out$err", "0:ok\n", $desc;
