# vim:ft=

use lib '.';
use t::TestLJ;

plan tests => 3 * blocks();

run_tests();

__DATA__

=== TEST 1: hot global read observes global table mutation
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

globalspec_read = 1

local function f()
  return globalspec_read
end

local sum = 0
for i = 1, 20 do
  sum = sum + f()
end

_G.globalspec_read = 2

for i = 1, 20 do
  sum = sum + f()
end

assert(sum == 60, sum)
globalspec_read = nil
print("ok")
--- out
ok
--- err



=== TEST 2: setfenv after recording uses new environment for global read
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local env1 = { globalspec_env_read = 1 }
local env2 = { globalspec_env_read = 2 }

local function f()
  return globalspec_env_read
end

setfenv(f, env1)

local sum = 0
for i = 1, 20 do
  sum = sum + f()
end

setfenv(f, env2)

for i = 1, 20 do
  sum = sum + f()
end

assert(sum == 60, sum)
print("ok")
--- out
ok
--- err



=== TEST 3: setfenv after recording stores globals in new environment
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local env1 = {}
local env2 = {}

local function f(v)
  globalspec_env_store = v
end

setfenv(f, env1)

for i = 1, 20 do
  f(i)
end

setfenv(f, env2)
for i = 21, 40 do
  f(i)
end

assert(env1.globalspec_env_store == 20, env1.globalspec_env_store)
assert(env2.globalspec_env_store == 40, env2.globalspec_env_store)
assert(rawget(_G, "globalspec_env_store") == nil)
print("ok")
--- out
ok
--- err



=== TEST 4: missing global becomes present after recording
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

rawset(_G, "globalspec_missing", nil)

local function f()
  return globalspec_missing
end

for i = 1, 20 do
  assert(f() == nil)
end

_G.globalspec_missing = 7

for i = 1, 20 do
  assert(f() == 7)
end

globalspec_missing = nil
print("ok")
--- out
ok
--- err



=== TEST 5: global __index change after recording is observed
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local assert = assert
local getmetatable = getmetatable
local print = print
local rawset = rawset
local setmetatable = setmetatable
local _G = _G
local oldmt = getmetatable(_G)

rawset(_G, "globalspec_index", nil)
setmetatable(_G, { __index = function(_, key)
  if key == "globalspec_index" then
    return 1
  end
end })

local function f()
  return globalspec_index
end

local sum = 0
for i = 1, 20 do
  sum = sum + f()
end

setmetatable(_G, { __index = function(_, key)
  if key == "globalspec_index" then
    return 2
  end
end })

for i = 1, 20 do
  sum = sum + f()
end

setmetatable(_G, oldmt)
assert(sum == 60, sum)
print("ok")
--- out
ok
--- err



=== TEST 6: global __newindex replacement after recording is observed
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local assert = assert
local getmetatable = getmetatable
local print = print
local rawget = rawget
local rawset = rawset
local setmetatable = setmetatable
local _G = _G
local oldmt = getmetatable(_G)
local sink1 = {}
local sink2 = {}

rawset(_G, "globalspec_newindex", nil)
setmetatable(_G, { __newindex = sink1 })

local function f(v)
  globalspec_newindex = v
end

for i = 1, 20 do
  f(i)
end

setmetatable(_G, { __newindex = sink2 })
for i = 21, 40 do
  f(i)
end

setmetatable(_G, oldmt)
assert(rawget(_G, "globalspec_newindex") == nil)
assert(sink1.globalspec_newindex == 20, sink1.globalspec_newindex)
assert(sink2.globalspec_newindex == 40, sink2.globalspec_newindex)
print("ok")
--- out
ok
--- err



=== TEST 7: non-default function environment remains mutable
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local env = { globalspec_custom_env = 3 }

local function f()
  return globalspec_custom_env
end

setfenv(f, env)

local sum = 0
for i = 1, 20 do
  sum = sum + f()
end

env.globalspec_custom_env = 4

for i = 1, 20 do
  sum = sum + f()
end

assert(sum == 140, sum)
print("ok")
--- out
ok
--- err
