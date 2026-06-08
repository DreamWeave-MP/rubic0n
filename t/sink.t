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

local bit = require "bit"
local jutil = require "jit.util"
local OPC_ASTORE, OPC_XSTORE = 74, 78
local OPC_TNEW, OPC_TDUP = 81, 82
local RID_SINK, RID_SUNK = 254, 253

local function sink_stats()
  local traces, allocs, stores, heavy, maxidx = 0, 0, 0, 0, 0
  for tr = 1, 100 do
    local info = jutil.traceinfo(tr)
    if info then
      traces = traces + 1
      for ref = 1, info.nins do
        local _, ot, _, _, ridsp = jutil.traceir(tr, ref)
        local op = bit.rshift(ot, 8)
        local rid = bit.band(ridsp, 255)
        local slot = bit.rshift(ridsp, 8)
        if rid == RID_SUNK and (op == OPC_TNEW or op == OPC_TDUP) then
          allocs = allocs + 1
          if slot > 0 then
            heavy = heavy + 1
            if slot > maxidx then maxidx = slot end
          end
        elseif rid == RID_SINK and op >= OPC_ASTORE and op <= OPC_XSTORE then
          stores = stores + 1
        end
      end
    end
  end
  return traces, allocs, stores, heavy, maxidx
end

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
local traces, allocs, stores, heavy, maxidx = sink_stats()
assert(traces > 0)
assert(allocs > 0)
assert(stores >= 2)
assert(heavy >= 2)
assert(maxidx >= 2)
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

local bit = require "bit"
local jutil = require "jit.util"
local OPC_ASTORE, OPC_XSTORE = 74, 78
local OPC_TNEW, OPC_TDUP = 81, 82
local RID_SINK, RID_SUNK = 254, 253

local function sink_stats()
  local traces, allocs, stores, heavy = 0, 0, 0, 0
  for tr = 1, 100 do
    local info = jutil.traceinfo(tr)
    if info then
      traces = traces + 1
      for ref = 1, info.nins do
        local _, ot, _, _, ridsp = jutil.traceir(tr, ref)
        local op = bit.rshift(ot, 8)
        local rid = bit.band(ridsp, 255)
        local slot = bit.rshift(ridsp, 8)
        if rid == RID_SUNK and (op == OPC_TNEW or op == OPC_TDUP) then
          allocs = allocs + 1
          if slot > 0 then heavy = heavy + 1 end
        elseif rid == RID_SINK and op >= OPC_ASTORE and op <= OPC_XSTORE then
          stores = stores + 1
        end
      end
    end
  end
  return traces, allocs, stores, heavy
end

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
local traces, allocs, stores, heavy = sink_stats()
assert(traces > 0)
assert(allocs > 0)
assert(stores > 0)
assert(heavy > 0)
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
require "jit.opt".start("hotloop=1", "maxrecord=800")

local bit = require "bit"
local jutil = require "jit.util"
local OPC_ASTORE, OPC_XSTORE = 74, 78
local OPC_TNEW, OPC_TDUP = 81, 82
local RID_SINK, RID_SUNK = 254, 253

local function sink_stats()
  local traces, allocs, stores, heavy = 0, 0, 0, 0
  for tr = 1, 100 do
    local info = jutil.traceinfo(tr)
    if info then
      traces = traces + 1
      for ref = 1, info.nins do
        local _, ot, _, _, ridsp = jutil.traceir(tr, ref)
        local op = bit.rshift(ot, 8)
        local rid = bit.band(ridsp, 255)
        local slot = bit.rshift(ridsp, 8)
        if rid == RID_SUNK and (op == OPC_TNEW or op == OPC_TDUP) then
          allocs = allocs + 1
          if slot > 0 then heavy = heavy + 1 end
        elseif rid == RID_SINK and op >= OPC_ASTORE and op <= OPC_XSTORE then
          stores = stores + 1
        end
      end
    end
  end
  return traces, allocs, stores, heavy
end

local parts = { "return function(i) local r = {}" }
for n = 1, 40 do
  parts[#parts + 1] = " local c"..n.." = { v = "..n.." }; r.k"..n.." = c"..n
end
parts[#parts + 1] = " if i > 10 then return r end end"

local f = assert(loadstring(table.concat(parts)))()
local r
for i = 1, 20 do
  r = f(i)
end

assert(r.k1.v == 1, r.k1.v)
assert(r.k20.v == 20, r.k20.v)
assert(r.k40.v == 40, r.k40.v)
local traces, allocs, stores, heavy = sink_stats()
assert(traces > 0)
assert(allocs > 0)
assert(stores > 0)
assert(heavy == 0, heavy)
print("ok")
--- out
ok
--- err
