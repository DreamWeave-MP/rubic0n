local table = ...

local FCompDefault = function(a, b) return a < b end

local function readonlywriteerror(intable, key)
  error('Write attempt to key ' .. tostring(key) .. ' in read-only table ' .. tostring(intable), 2)
end

local function readonlymt(proxy, backing, strict)
  return {
    __index = function(_, key)
      local value = backing[key]
      if strict and value == nil then
        error('Failed to locate key ' .. tostring(key) .. ' in table ' .. tostring(proxy) .. '!', 2)
      end
      return value
    end,
    __newindex = readonlywriteerror,
    __pairs = function()
      return function(_, key)
        return next(backing, key)
      end, nil, nil
    end,
    __ipairs = function()
      local function iter(_, i)
        i = i + 1
        local value = backing[i]
        if value ~= nil then return i, value end
      end
      return iter, nil, 0
    end,
    __len = function()
      return #backing
    end,
    __metatable = false,
  }
end

local function collectreadonlyplan(intable, copy, visited, plan)
  local node = visited[intable]
  if node then return node.proxy end

  node = { source = intable, proxy = copy and {} or intable, backing = {}, entries = {} }
  visited[intable] = node
  plan[#plan + 1] = node

  for k, v in next, intable, nil do
    node.entries[#node.entries + 1] = k
    node.entries[#node.entries + 1] = v
    if type(k) == 'table' then collectreadonlyplan(k, copy, visited, plan) end
    if type(v) == 'table' then collectreadonlyplan(v, copy, visited, plan) end
  end

  return node.proxy
end

local function preflightreadonlyplan(plan)
  for i = 1, #plan do
    local t = plan[i].source
    local ok, err = pcall(setmetatable, t, getmetatable(t))
    if not ok then error(err, 3) end
  end
end

local function buildreadonlybacking(plan, visited)
  for i = 1, #plan do
    local node = plan[i]
    local entries = node.entries
    for j = 1, #entries, 2 do
      local k, v = entries[j], entries[j + 1]
      local newk = type(k) == 'table' and visited[k].proxy or k
      local newv = type(v) == 'table' and visited[v].proxy or v
      node.backing[newk] = newv
    end
  end
end

local function tablesize(inputtable)
  local count = 0
  for _ in pairs(inputtable) do count = count + 1 end
  return count
end

local function safepairs(val)
  return pcall(pairs, val)
end

local function safeipairs(val)
  return pcall(ipairs, val)
end

local function preflightdeepcopy(root, seen)
  if seen[root] then return end
  seen[root] = true

  local ok = pcall(setmetatable, root, getmetatable(root))
  if not ok then
    error('deepcopy: protected metatable in table graph', 3)
  end

  for k, v in next, root, nil do
    if type(k) == 'table' then preflightdeepcopy(k, seen) end
    if type(v) == 'table' then preflightdeepcopy(v, seen) end
  end
end

local function deepcopyimpl(root, copies)
  local copied = rawget(copies, root)
  if copied then return copied end

  local new = {}
  rawset(copies, root, new)

  for k, v in next, root, nil do
    local key = type(k) == 'table' and deepcopyimpl(k, copies) or k
    local val = type(v) == 'table' and deepcopyimpl(v, copies) or v
    new[key] = val
  end

  return setmetatable(new, getmetatable(root))
end

local function deepcopy(root, copies)
  if type(root) ~= 'table' then
    error('Invalid table provided to deepcopy: ' .. tostring(root), 2)
  end

  preflightdeepcopy(root, {})
  return deepcopyimpl(root, copies or {})
end

local function deeptostring(val, level, prefix)
  prefix = prefix or ''
  level = level or 1

  local ok, iter, state, initial = safepairs(val)
  if level <= 0 or not ok then
    return tostring(val)
  end

  local newprefix = prefix .. '  '
  local strs = { tostring(val) .. ' {\n' }

  for k, v in iter, state, initial do
    strs[#strs + 1] = newprefix .. tostring(k) .. ' = ' .. deeptostring(v, level - 1, newprefix) .. ',\n'
  end

  strs[#strs + 1] = prefix .. '}'
  return table.concat(strs)
end

local function gettablefromsplit(inputstring, pattern)
  local newtable = {}

  for value in string.gmatch(inputstring, pattern) do
    table.insert(newtable, value)
  end

  return newtable
end

local function gettablefromcommasplit(inputstring)
  return gettablefromsplit(inputstring, '%s*([^,]+)')
end

local function getprintabletable(inputtable, maxdepth, indentstr, indentlevel)
  local inputtype = type(inputtable)
  if inputtype ~= 'table' and inputtype ~= 'userdata' then
    return inputtype
  end

  indentlevel = indentlevel or 0
  indentstr = indentstr or '\t'
  maxdepth = maxdepth or 50

  local parts = {}
  local currentindent = string.rep(indentstr, indentlevel + 1)

  for index, value in pairs(inputtable) do
    local valuestr

    if type(value) == 'table' and maxdepth > 0 then
      valuestr = '\n' .. getprintabletable(value, maxdepth - 1, indentstr, indentlevel + 1)
    else
      valuestr = tostring(value) .. '\n'
    end

    parts[#parts + 1] = currentindent .. tostring(index) .. ': ' .. valuestr
  end

  return table.concat(parts, '')
end

local function tableprint(inputtable, maxdepth, indentstr, indentlevel)
  print(getprintabletable(inputtable, maxdepth, indentstr, indentlevel))
end

local function choice(t)
  local count = 0

  for _ in pairs(t) do
    count = count + 1
  end

  if count == 0 then return nil end

  local target = math.random(count)
  count = 0
  for k, v in pairs(t) do
    count = count + 1
    if count == target then
      return v, k
    end
  end
end

local function find(t, value)
  for i, v in pairs(t) do
    if v == value then
      return i
    end
  end
end

local function contains(t, value)
  return find(t, value) ~= nil
end

local function isequalimpl(left, right, leftseen, rightseen)
  local lefttype = type(left)
  local righttype = type(right)

  if lefttype ~= 'table' or righttype ~= 'table' then
    if lefttype == 'table' or righttype == 'table' then
      return false
    end
    return left == right
  end

  if rawequal(left, right) then
    return true
  end

  local mappedright = leftseen[left]
  if mappedright ~= nil then
    return rawequal(mappedright, right)
  end

  local mappedleft = rightseen[right]
  if mappedleft ~= nil then
    return rawequal(mappedleft, left)
  end

  leftseen[left] = right
  rightseen[right] = left

  local size1 = 0

  for k, v1 in pairs(left) do
    local v2 = right[k]
    if not isequalimpl(v1, v2, leftseen, rightseen) then
      return false
    end

    size1 = size1 + 1
  end

  local equal = size1 == tablesize(right)
  leftseen[left] = nil
  rightseen[right] = nil
  return equal
end

local function isequal(left, right)
  return isequalimpl(left, right, {}, {})
end

local function removevalue(list, value)
  for i = 1, #list do
    if list[i] == value then
      table.remove(list, i)
      return true
    end
  end

  return false
end

local function shallowcopy(from, to)
  to = to or {}

  for k, v in pairs(from) do
    to[k] = v
  end

  return to
end

local function copymissingimpl(to, from, visited)
  local seen = visited[from]
  if seen then
    if seen[to] then return end
  else
    seen = {}
    visited[from] = seen
  end
  seen[to] = true

  for k, v in pairs(from) do
    if type(to[k]) == 'table' and type(v) == 'table' then
      copymissingimpl(to[k], v, visited)
    elseif to[k] == nil then
      to[k] = v
    end
  end
end

local function copymissing(to, from)
  copymissingimpl(to, from, {})
end

local function traverse(t, k)
  k = k or 'children'

  local function iter(nodes)
    for _, node in ipairs(nodes or t) do
      if node then
        coroutine.yield(node)

        if node[k] then
          iter(node[k])
        end
      end
    end
  end

  return coroutine.wrap(iter)
end

local function keys(t, sortorsortfunc)
  local tablekeys = {}

  for k in pairs(t) do
    table.insert(tablekeys, k)
  end

  if sortorsortfunc then
    if sortorsortfunc == true then
      sortorsortfunc = nil
    end

    table.sort(tablekeys, sortorsortfunc)
  end

  return tablekeys
end

local function values(t, sortorsortfunc)
  local tablevalues = {}

  for _, v in pairs(t) do
    table.insert(tablevalues, v)
  end

  if sortorsortfunc then
    local sortfunction

    if type(sortorsortfunc) == 'function' then
      sortfunction = sortorsortfunc
    end

    table.sort(tablevalues, sortfunction)
  end

  return tablevalues
end

local function invert(t)
  local inverted = {}

  for k, v in pairs(t) do
    inverted[v] = k
  end

  return inverted
end

local function sortedpairs(tbl, comparator)
  local tablekeys = {}
  for key in pairs(tbl) do table.insert(tablekeys, key) end

  table.sort(tablekeys, comparator)
  local i = 0

  return function()
    i = i + 1
    return tablekeys[i], tbl[tablekeys[i]]
  end
end

local function swap(t, key, value)
  local old = t[key]
  t[key] = value
  return old
end

local function get(t, key, defaultvalue)
  local value = t[key]

  if value == nil then
    return defaultvalue
  end

  return value
end

local function getorset(t, key, defaultvalue)
  local value = t[key]

  if value ~= nil then
    return value
  end

  t[key] = defaultvalue
  return defaultvalue
end

local function wrapindex(t, index)
  local size = #t
  if size == 0 then
    error('wrapindex: empty sequence', 2)
  end

  local newindex = index % size
  if newindex == 0 then
    newindex = size
  end

  return newindex
end

local function shuffle(t, n)
  n = n or #t
  for i = n, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

local function binsearch(tbl, value, comp, findall)
  local size = #tbl
  local first, last, midpt = 1, size, 0
  local usecomp = comp ~= nil and comp ~= false
  if usecomp then
    if type(comp) ~= 'function' then
      error('binsearch: comparator must be a function', 2)
    end
  else
    comp = FCompDefault
  end

  while first <= last do
    midpt = math.floor((first + last) / 2)

    if comp(value, tbl[midpt]) then
      last = midpt - 1
    elseif comp(tbl[midpt], value) then
      first = midpt + 1
    else
      local lowestmatch, highestmatch = midpt, midpt
      if usecomp then
        if not findall then return midpt, midpt end

        while lowestmatch > 1 do
          local previous = tbl[lowestmatch - 1]
          if comp(value, previous) or comp(previous, value) then break end
          lowestmatch = lowestmatch - 1
        end
        while highestmatch < size do
          local following = tbl[highestmatch + 1]
          if comp(value, following) or comp(following, value) then break end
          highestmatch = highestmatch + 1
        end
      else
        if not rawequal(tbl[midpt], value) then
          while lowestmatch > 1 do
            local previous = tbl[lowestmatch - 1]
            if comp(value, previous) or comp(previous, value) then break end
            lowestmatch = lowestmatch - 1
          end
          while highestmatch < size do
            local following = tbl[highestmatch + 1]
            if comp(value, following) or comp(following, value) then break end
            highestmatch = highestmatch + 1
          end

          midpt = nil
          for i = lowestmatch, highestmatch do
            if rawequal(tbl[i], value) then
              midpt = i
              break
            end
          end
          if not midpt then return nil end
        end

        if not findall then return midpt, midpt end

        lowestmatch, highestmatch = midpt, midpt
        while lowestmatch > 1 and rawequal(tbl[lowestmatch - 1], value) do
          lowestmatch = lowestmatch - 1
        end
        while highestmatch < size and rawequal(tbl[highestmatch + 1], value) do
          highestmatch = highestmatch + 1
        end
      end
      return lowestmatch, highestmatch
    end
  end
end

local function bininsert(t, value, comp)
  comp = comp or FCompDefault
  local istart, iend, imid, istate = 1, #t, 1, 0
  while istart <= iend do
    imid = math.floor((istart + iend) / 2)
    if comp(value, t[imid]) then
      iend, istate = imid - 1, 0
    else
      istart, istate = imid + 1, 1
    end
  end

  table.insert(t, imid + istate, value)
  return imid + istate
end

local function map(t, f, ...)
  local tbl = {}

  for k, v in pairs(t) do
    tbl[k] = f(k, v, ...)
  end

  return tbl
end

local function filter(t, f, ...)
  local tbl = {}

  for k, v in pairs(t) do
    if f(k, v, ...) then
      tbl[k] = v
    end
  end

  return tbl
end

local function filterarray(arr, f, ...)
  local tbl = {}

  for i, v in ipairs(arr) do
    if f(i, v, ...) then
      table.insert(tbl, v)
    end
  end

  return tbl
end

local function unpackvalues(t)
  return (table.unpack or _G.unpack)(t)
end

local function unwind(object)
  local ok, iter, state, initial = safepairs(object)
  if not ok then
    error(tostring(object) .. ' cannot be iterated safely!', 2)
  end

  local results = {}

  for _, v in iter, state, initial do
    results[#results + 1] = v
  end

  return unpackvalues(results)
end

local function unwindarray(object)
  local ok, iter, state, initial = safeipairs(object)
  if not ok then
    error(tostring(object) .. ' cannot be iterated safely!', 2)
  end

  local results = {}

  for _, v in iter, state, initial do
    results[#results + 1] = v
  end

  return unpackvalues(results)
end

local function makereadonlyimpl(intable, copy, strict, visited)
  visited = visited or {}
  local plan = {}
  local proxy = collectreadonlyplan(intable, copy, visited, plan)

  if not copy then preflightreadonlyplan(plan) end
  buildreadonlybacking(plan, visited)

  if not copy then
    for i = 1, #plan do
      local entries = plan[i].entries
      for j = 1, #entries, 2 do
        rawset(plan[i].source, entries[j], nil)
      end
    end
  end

  for i = 1, #plan do
    local node = plan[i]
    setmetatable(node.proxy, readonlymt(node.proxy, node.backing, strict))
  end

  return proxy
end

local function makereadonly(intable, copy, strict)
  if type(intable) ~= 'table' then
    error('makereadonly: expected table, got ' .. type(intable), 2)
  end

  return makereadonlyimpl(intable, copy, strict, {})
end

local function findminscore(array, scorefn)
  local bestvalue, bestscore, bestindex
  for i = 1, #array do
    local v = array[i]
    local score = scorefn(v)
    if score and (not bestscore or bestscore > score) then
      bestvalue, bestscore, bestindex = v, score, i
    end
  end

  return bestvalue, bestscore, bestindex
end

local function mapfilter(array, scorefn)
  local res = {}
  local scores = {}
  for i = 1, #array do
    local v = array[i]
    local f = scorefn(v)
    if f then
      scores[#res + 1] = f
      res[#res + 1] = v
    end
  end
  return res, scores
end

local function mapfiltersort(array, scorefn)
  local mapvalues, scores = mapfilter(array, scorefn)
  local size = #mapvalues
  local ids = {}
  for i = 1, size do ids[i] = i end
  table.sort(ids, function(i, j) return scores[i] < scores[j] end)
  local sortedvalues = {}
  local sortedscores = {}
  for i = 1, size do
    sortedvalues[i] = mapvalues[ids[i]]
    sortedscores[i] = scores[ids[i]]
  end
  return sortedvalues, sortedscores
end

local function calleventhandlers(handlers, ...)
  for i = #handlers, 1, -1 do
    if handlers[i](...) == false then
      return true
    end
  end

  return false
end

local function callmultipleeventhandlers(handlers, ...)
  for i = 1, #handlers do
    if calleventhandlers(handlers[i], ...) then
      return true
    end
  end

  return false
end

--- @param t table
--- @return number result
function table.size(t)
  local tType = type(t)
  if (tType == "table") then
    return table.nkeys(t)
  else
    return #t
  end
end

table.bininsert = bininsert
table.binsearch = binsearch
table.calleventhandlers = calleventhandlers
table.callmultipleeventhandlers = callmultipleeventhandlers
table.choice = choice
table.contains = contains
table.copymissing = copymissing
table.deepcopy = deepcopy
table.deeptostring = deeptostring
table.filter = filter
table.filterarray = filterarray
table.find = find
table.findminscore = findminscore
table.get = get
table.getorset = getorset
table.getprintabletable = getprintabletable
table.gettablefromcommasplit = gettablefromcommasplit
table.gettablefromsplit = gettablefromsplit
table.invert = invert
table.isequal = isequal
table.keys = keys
table.makereadonly = makereadonly
table.map = map
table.mapfilter = mapfilter
table.mapfiltersort = mapfiltersort
table.print = tableprint
table.removevalue = removevalue
table.shallowcopy = shallowcopy
table.shuffle = shuffle
table.sortedpairs = sortedpairs
table.swap = swap
table.traverse = traverse
table.unwind = unwind
table.unwindarray = unwindarray
table.values = values
table.wrapindex = wrapindex
