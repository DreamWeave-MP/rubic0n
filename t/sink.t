# vim:ft=

use lib '.';
use t::TestLJ;

plan tests => 3 * blocks();

run_tests();

__DATA__

=== TEST 1: nested table alias survives side exit
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local function f(i)
  local child = { v = i }
  local parent = { a = child, b = child }
  if i > 10 then
    return parent
  end
end

local p
for i = 1, 20 do
  p = f(i)
end

assert(p.a == p.b)
assert(p.a.v == 20, p.a.v)
print("ok")
--- out
ok
--- err



=== TEST 2: self-cycle survives side exit
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local function f(i)
  local t = { v = i }
  t.self = t
  if i > 10 then
    return t
  end
end

local t
for i = 1, 20 do
  t = f(i)
end

assert(t.self == t)
assert(t.v == 20, t.v)
print("ok")
--- out
ok
--- err



=== TEST 3: nested TDUP and TNEW survive side exit
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local function f(i)
  local leaf = { 1, 2, tag = i }
  local parent = { leaf = leaf, fresh = { n = i + 1 } }
  if i > 10 then
    return parent
  end
end

local p
for i = 1, 20 do
  p = f(i)
end

assert(p.leaf[1] == 1)
assert(p.leaf[2] == 2)
assert(p.leaf.tag == 20, p.leaf.tag)
assert(p.fresh.n == 21, p.fresh.n)
print("ok")
--- out
ok
--- err



=== TEST 4: metatable restore survives side exit
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local mt = { marker = true }

local function f(i)
  local t = setmetatable({ v = i }, mt)
  if i > 10 then
    return t
  end
end

local t
for i = 1, 20 do
  t = f(i)
end

assert(getmetatable(t) == mt)
assert(t.v == 20, t.v)
print("ok")
--- out
ok
--- err



=== TEST 5: FFI cdata stored in sunk table survives side exit
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local ok, ffi = pcall(require, "ffi")
if not ok then
  print("ok")
  return
end

ffi.cdef[[typedef struct { int x; } sink_point_t;]]

local function f(i)
  local p = ffi.new("sink_point_t")
  p.x = i
  local t = { p = p }
  if i > 10 then
    return t
  end
end

local t
for i = 1, 20 do
  t = f(i)
end

assert(t.p.x == 20, t.p.x)
print("ok")
--- out
ok
--- err



=== TEST 6: many nested allocations exercise heavy sink budget fallback
--- lua
jit.on()
require "jit.opt".start("hotloop=1")

local parts = { "return function(i) local r = {}" }
for n = 1, 270 do
  parts[#parts + 1] = " r.k"..n.." = { v = "..n.." }"
end
parts[#parts + 1] = " if i > 10 then return r end end"

local f = assert(loadstring(table.concat(parts)))()
local r
for i = 1, 20 do
  r = f(i)
end

assert(r.k1.v == 1, r.k1.v)
assert(r.k254.v == 254, r.k254.v)
assert(r.k270.v == 270, r.k270.v)
print("ok")
--- out
ok
--- err
