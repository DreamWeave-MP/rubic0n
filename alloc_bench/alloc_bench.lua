---@diagnostic disable: unused-local
-- alloc_bench.lua
-- Measures allocator throughput and fragmentation under game-loop-like patterns.
-- Run with: luajit alloc_bench.lua
-- Or:       LD_PRELOAD=.../libmimalloc.so luajit alloc_bench.lua
local clock = os.clock

local function bench(name, fn, ...)
  collectgarbage()
  collectgarbage()
  local t0 = clock()
  local result = fn(...)
  local t1 = clock()
  io.write(string.format("%-40s %.4f s\n", name, t1 - t0))
  return result
end

-- -----------------------------------------------------------------------
-- 1. Raw throughput: many small ephemeral tables.
--    Allocate and immediately abandon; GC must keep up.
--    Tests: alloc+free throughput for small, uniform objects.
-- -----------------------------------------------------------------------
bench("1. small ephemeral tables (2M)",
  function()
    for i = 1, 2e6 do
      local t = { i, i + 1, i + 2, i + 3 }
    end
  end)

-- -----------------------------------------------------------------------
-- 2. Fragmentation: fill, kill half non-contiguously, refill.
--    The surviving half creates holes; new allocations must fit into them.
--    Tests: allocator behaviour under realistic fragmentation.
-- -----------------------------------------------------------------------
bench("2. fragmentation (fill/kill/refill 500K)",
  function()
    local N = 500000
    local live = {}
    -- Fill
    for i = 1, N do
      live[i] = { i, i * 2, i * 3, i * 4, i * 5, i * 6, i * 7, i * 8 }
    end
    -- Kill every other entry (non-contiguous free)
    for i = 1, N, 2 do
      live[i] = false
    end
    collectgarbage()
    -- Refill into the holes with different-sized tables
    for i = 1, N, 2 do
      local sz = (i % 12) + 2
      local t = {}
      for j = 1, sz do t[j] = j end
      live[i] = t
    end
  end)

-- -----------------------------------------------------------------------
-- 3. String churn: allocation of short-lived strings of varying length.
--    LuaJIT interns strings, but concatenation produces temporaries.
--    Tests: small allocations of irregular sizes + immediate free.
-- -----------------------------------------------------------------------
bench("3. string churn (1M)", function()
  local sink = 0
  for i = 1, 1e6 do
    local s = tostring(i) .. "_" .. tostring(i * 6364136223846793005)
    sink = sink + #s
  end
  return sink
end)

-- -----------------------------------------------------------------------
-- 4. Simulated game frame: per-frame event tables + a persistent world.
--    1000 frames, each spawning 200 short-lived event tables and
--    updating 50 long-lived entity tables (realloc pressure via rehash).
--    Tests: sustained mixed-lifetime allocation, closest to real usage.
-- -----------------------------------------------------------------------
bench("4. simulated game frames (1000 x 200 events)",
  function()
    local FRAMES   = 1000
    local ENTITIES = 500
    local EVENTS   = 200

    -- Long-lived entity state
    local world    = {}
    for i = 1, ENTITIES do
      world[i] = { id = i, hp = 100, x = 0, y = 0, inventory = {} }
    end

    for frame = 1, FRAMES do
      -- Short-lived event tables (die at end of frame)
      for e = 1, EVENTS do
        local ev = {
          type   = "damage",
          source = (e % ENTITIES) + 1,
          target = ((e + frame) % ENTITIES) + 1,
          amount = e % 50,
        }
        -- Apply to entity, causing table growth (realloc path)
        local target = world[ev.target]
        target.hp = target.hp - ev.amount
        target.inventory[#target.inventory + 1] = frame
      end

      -- Trim inventories every 10 frames (free pressure)
      if frame % 10 == 0 then
        for i = 1, ENTITIES do
          world[i].inventory = {}
        end
        collectgarbage()
      end
    end
  end)
