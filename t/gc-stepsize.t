# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

$ENV{LUA_CPATH} = "$Bin/../?.so;;";
$ENV{LUA_PATH} = "$Bin/../lua/?.lua;;";

my $luajit = abs_path("$Bin/../src/luajit");

plan tests => 4;

my $cwd = cwd;
my $dir = tempdir "testlj_gc_stepsize_XXXXXXX", CLEANUP => 1;
chdir $dir or die "Cannot chdir to $dir: $!";

sub run_lua {
    my ($name, $lua) = @_;
    open my $fh, '>', 'test.lua' or die "Cannot open test.lua: $!";
    print $fh $lua;
    close $fh;

    my $out = `"$luajit" test.lua 2>&1`;
    my $rc = $? >> 8;
    is "$rc:$out", "0:ok\n", $name;
}

run_lua 'collectgarbage setstepsize semantics', <<'LUA';
assert(collectgarbage("setstepsize", 1) == 1)
assert(collectgarbage("setstepsize", 4) == 1)
assert(collectgarbage("setstepsize", 1) == 4)
assert(collectgarbage("setstepsize", 0) == 1)
assert(collectgarbage("setstepsize", 1) == 1)
assert(collectgarbage("setstepsize", -42) == 1)
assert(collectgarbage("setstepsize", 1) == 1)
print("ok")
LUA

run_lua 'existing collectgarbage options still map correctly', <<'LUA';
assert(type(collectgarbage("count")) == "number")
assert(type(collectgarbage("step", 0)) == "boolean")
local pause = collectgarbage("setpause", 200)
assert(type(pause) == "number")
assert(collectgarbage("setpause", pause) == 200)
local stepmul = collectgarbage("setstepmul", 200)
assert(type(stepmul) == "number")
assert(collectgarbage("setstepmul", stepmul) == 200)
assert(type(collectgarbage("isrunning")) == "boolean")
collectgarbage("stop")
assert(collectgarbage("isrunning") == false)
collectgarbage("restart")
assert(collectgarbage("isrunning") == true)
collectgarbage("collect")
print("ok")
LUA

run_lua 'huge collectgarbage setstepsize stays usable', <<'LUA';
local huge = 2147483647
assert(collectgarbage("setstepsize", huge) >= 1)
local effective = collectgarbage("setstepsize", 1)
assert(effective >= 1)
assert(effective < huge)
assert(collectgarbage("setstepsize", huge) == 1)
collectgarbage("stop")
assert(collectgarbage("isrunning") == false)
collectgarbage("restart")
assert(collectgarbage("isrunning") == true)
assert(type(collectgarbage("step", 0)) == "boolean")
assert(collectgarbage("isrunning") == true)
assert(type(collectgarbage("step", 1)) == "boolean")
assert(collectgarbage("isrunning") == true)
assert(collectgarbage("setstepsize", 1) >= 1)
print("ok")
LUA

run_lua 'huge setstepsize and high stepmul do not overflow work limit', <<'LUA';
local huge = 2147483647
local oldmul = collectgarbage("setstepmul", huge)
assert(type(oldmul) == "number")
assert(collectgarbage("setstepsize", huge) >= 1)
collectgarbage("restart")
assert(collectgarbage("isrunning") == true)
assert(type(collectgarbage("step", 0)) == "boolean")
assert(collectgarbage("isrunning") == true)
assert(type(collectgarbage("step", 1)) == "boolean")
assert(collectgarbage("isrunning") == true)
assert(collectgarbage("setstepmul", oldmul) == huge)
assert(collectgarbage("setstepsize", 1) >= 1)
print("ok")
LUA

chdir $cwd or die $!;
