# vim: set ss=4 ft= sw=4 et sts=4 ts=4:

use v5.10.1;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path cwd);
use FindBin qw($Bin);

my $luajit = abs_path("$Bin/../src/luajit");

plan skip_all => "src/luajit is not built" unless defined $luajit && -x $luajit;

my $cwd = cwd;
my $dir = tempdir "testlj_math_table_extensions_XXXXXXX", CLEANUP => 1;
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
  eps = eps or 0.000001
  if math.abs(actual - expected) > eps then
    fail(('%s: expected %.17g, got %.17g'):format(msg, expected, actual))
  end
end

local function has_lua52_table_metamethods()
  local marker = {}
  local proxy = setmetatable({}, {
    __pairs = function()
      return next, { x = marker }, nil
    end,
    __ipairs = function()
      local done = false
      return function()
        if done then return nil end
        done = true
        return 1, marker
      end
    end,
    __len = function()
      return 1
    end,
  })

  local pairs_ok = false
  for k, v in pairs(proxy) do
    pairs_ok = k == 'x' and v == marker
  end

  local ipairs_ok = false
  for i, v in ipairs(proxy) do
    ipairs_ok = i == 1 and v == marker
  end

  return pairs_ok and ipairs_ok and #proxy == 1
end

local lua52_table_metamethods = has_lua52_table_metamethods()

local math_added = {
  'approach', 'clamp', 'eerp', 'isclose', 'lerp', 'nextpoweroftwo',
  'normalizeangle', 'oscillate', 'remap', 'remapclamped', 'round',
  'smoothstep', 'smootherstep', 'snap',
}
assert_eq(#math_added, 14, 'math added function count')
for _, name in ipairs(math_added) do
  assert_eq(type(math[name]), 'function', 'math.' .. name .. ' exists')
end
assert_eq(type(math.epsilon), 'number', 'math.epsilon exists')
assert_eq(math.isClose, nil, 'math.isClose camelCase alias absent')
assert_eq(math.nextPowerOfTwo, nil, 'math.nextPowerOfTwo camelCase alias absent')
assert_eq(math.normalizeAngle, nil, 'math.normalizeAngle camelCase alias absent')
assert_eq(math.remapClamped, nil, 'math.remapClamped camelCase alias absent')

assert_close(math.lerp(10, 20, 0.25), 12.5, 'math.lerp')
assert_eq(math.approach(1, 5, 2), 3, 'math.approach step')
assert_eq(math.approach(4, 5, 2), 5, 'math.approach no overshoot')
assert_eq(math.clamp(5, 10, 0), 5, 'math.clamp reversed bounds')
assert_eq(math.remap(5, 0, 10, 0, 100), 50, 'math.remap')
assert_eq(math.remapclamped(15, 0, 10, 0, 100), 100, 'math.remapclamped')
assert_eq(math.round(1.25, 1), 1.3, 'math.round digits')
assert_true(math.isclose(1, 1 + 1e-10), 'math.isclose')
assert_eq(math.nextpoweroftwo(1), 1, 'math.nextpoweroftwo one')
assert_eq(math.nextpoweroftwo(2), 2, 'math.nextpoweroftwo exact power')
assert_eq(math.nextpoweroftwo(3), 4, 'math.nextpoweroftwo rounds up')
assert_eq(math.nextpoweroftwo(1.5), 2, 'math.nextpoweroftwo fractional')
assert_eq(math.nextpoweroftwo(2 ^ 29), 2 ^ 29, 'math.nextpoweroftwo large exact power')
local np2_ok, np2_err = pcall(function() math.nextpoweroftwo(0) end)
assert_false(np2_ok, 'math.nextpoweroftwo rejects zero')
assert_true(tostring(np2_err):find('finite number >= 1', 1, true) ~= nil,
  'math.nextpoweroftwo zero error message')
np2_ok = pcall(function() math.nextpoweroftwo(-3) end)
assert_false(np2_ok, 'math.nextpoweroftwo rejects negative')
np2_ok = pcall(function() math.nextpoweroftwo(0 / 0) end)
assert_false(np2_ok, 'math.nextpoweroftwo rejects NaN')
np2_ok = pcall(function() math.nextpoweroftwo(math.huge) end)
assert_false(np2_ok, 'math.nextpoweroftwo rejects infinity')
assert_close(math.normalizeangle(3 * math.pi), -math.pi, 'math.normalizeangle')
assert_close(math.eerp(2, 8, 0.5), 4, 'math.eerp')
assert_eq(math.oscillate(7, 0, 5), 3, 'math.oscillate')
assert_close(math.smoothstep(0, 1, 0.5), 0.5, 'math.smoothstep')
assert_close(math.smootherstep(0, 1, 0.5), 0.5, 'math.smootherstep')
assert_eq(math.snap(12, 5), 10, 'math.snap')

local table_added = {
  'bininsert', 'binsearch', 'calleventhandlers', 'callmultipleeventhandlers',
  'choice', 'contains', 'copymissing', 'deepcopy', 'deeptostring', 'filter',
  'filterarray', 'find', 'findminscore', 'get', 'getorset', 'getprintabletable',
  'gettablefromcommasplit', 'gettablefromsplit', 'invert', 'isequal', 'keys',
  'makereadonly', 'map', 'mapfilter', 'mapfiltersort', 'print', 'removevalue',
  'shallowcopy', 'shuffle', 'sortedpairs', 'swap', 'traverse', 'unwind',
  'unwindarray', 'values', 'wrapindex',
}
assert_eq(#table_added, 36, 'table added function count')
for _, name in ipairs(table_added) do
  assert_eq(type(table[name]), 'function', 'table.' .. name .. ' exists')
end
assert_eq(table.observabletable, nil, 'table.observabletable absent')
assert_eq(table.tablesubscribe, nil, 'table.tablesubscribe absent')
assert_eq(table.binSearch, nil, 'table.binSearch camelCase alias absent')
assert_eq(table.deepCopy, nil, 'table.deepCopy camelCase alias absent')
assert_eq(table.filterArray, nil, 'table.filterArray camelCase alias absent')
assert_eq(table.getOrSet, nil, 'table.getOrSet camelCase alias absent')
assert_eq(table.isEqual, nil, 'table.isEqual camelCase alias absent')
assert_eq(type(table.isarray), 'function', 'OpenResty table.isarray exists')
assert_true(table.isarray({}), 'OpenResty table.isarray empty table')
assert_true(table.isarray({ [3] = 'a', [5] = true }), 'OpenResty table.isarray integer hash keys')
assert_false(table.isarray({ [5.3] = true }), 'OpenResty table.isarray rejects non-integer number key')
assert_false(table.isarray({ ['1'] = true }), 'OpenResty table.isarray rejects string key')
assert_eq(type(table.isempty), 'function', 'OpenResty table.isempty exists')
assert_true(table.isempty({}), 'OpenResty table.isempty empty table')
assert_true(table.isempty({ nil }), 'OpenResty table.isempty nil-only array')
assert_false(table.isempty({ false }), 'OpenResty table.isempty false array value')
assert_false(table.isempty({ dogs = 3 }), 'OpenResty table.isempty hash value')

local sorted = { 1, 2, 2, 2, 4 }
local low, high = table.binsearch(sorted, 2, nil, true)
assert_eq(low, 2, 'table.binsearch low')
assert_eq(high, 4, 'table.binsearch high')
local rank_mt = {
  __lt = function(a, b) return a.rank < b.rank end,
  __eq = function(a, b) return a.rank == b.rank end,
}
local rank1 = setmetatable({ rank = 1 }, rank_mt)
local rank2a = setmetatable({ rank = 2 }, rank_mt)
local rank2b = setmetatable({ rank = 2 }, rank_mt)
local rank2c = setmetatable({ rank = 2 }, rank_mt)
local rank2d = setmetatable({ rank = 2 }, rank_mt)
local rank2e = setmetatable({ rank = 2 }, rank_mt)
local rank2missing = setmetatable({ rank = 2 }, rank_mt)
local rank3 = setmetatable({ rank = 3 }, rank_mt)
local rank_missing_run = { rank1, rank2a, rank2c, rank3 }
low, high = table.binsearch(rank_missing_run, rank2missing, nil, false)
assert_eq(low, nil, 'table.binsearch comp=nil raw inequality returns nil low')
assert_eq(high, nil, 'table.binsearch comp=nil raw inequality returns nil high')
low, high = table.binsearch(rank_missing_run, rank2missing, false, true)
assert_eq(low, nil, 'table.binsearch comp=false findall raw inequality returns nil low')
assert_eq(high, nil, 'table.binsearch comp=false findall raw inequality returns nil high')
local rank_run = { rank1, rank2a, rank2c, rank2d, rank2b, rank2b, rank2e, rank3 }
low, high = table.binsearch(rank_run, rank2b, nil, false)
assert_true(low ~= nil, 'table.binsearch comp=nil finds raw-equal entry inside equivalent run')
assert_true(rawequal(rank_run[low], rank2b), 'table.binsearch comp=nil returns raw-equal entry')
assert_eq(high, low, 'table.binsearch comp=nil non-findall returns single index')
low, high = table.binsearch(rank_run, rank2b, false, true)
assert_eq(low, 5, 'table.binsearch comp=false raw equality low')
assert_eq(high, 6, 'table.binsearch comp=false raw equality high')
local disjoint_x = setmetatable({ rank = 2 }, rank_mt)
local disjoint_y = setmetatable({ rank = 2 }, rank_mt)
local disjoint_raw_run = { disjoint_x, disjoint_y, disjoint_x }
low, high = table.binsearch(disjoint_raw_run, disjoint_x, nil, true)
assert_true(low ~= nil, 'table.binsearch raw findall finds one disjoint raw-equal run')
assert_true(rawequal(disjoint_raw_run[low], disjoint_x),
  'table.binsearch raw findall returned run is raw-equal')
assert_eq(high, low, 'table.binsearch raw findall does not merge disjoint raw-equal entries')
local search_ok, search_err = pcall(function() table.binsearch(sorted, 2, true) end)
assert_false(search_ok, 'table.binsearch rejects non-function comparator')
assert_true(tostring(search_err):find('comparator must be a function', 1, true) ~= nil,
  'table.binsearch non-function comparator error message')
local function rank_less(a, b) return a.rank < b.rank end
low, high = table.binsearch(rank_run, rank2missing, rank_less, true)
assert_eq(low, 2, 'table.binsearch comparator-equivalent rank objects low')
assert_eq(high, 7, 'table.binsearch comparator-equivalent rank objects high')
local records = { { rank = 1 }, { rank = 2 }, { rank = 2 }, { rank = 2 }, { rank = 3 } }
low, high = table.binsearch(records, { rank = 2 }, rank_less, true)
assert_eq(low, 2, 'table.binsearch comparator-equivalent records low')
assert_eq(high, 4, 'table.binsearch comparator-equivalent records high')
local lower = string.lower
local function caseless_less(a, b) return lower(a) < lower(b) end
low, high = table.binsearch({ 'A', 'a', 'B', 'b', 'C' }, 'b', caseless_less, true)
assert_eq(low, 3, 'table.binsearch comparator-equivalent strings low')
assert_eq(high, 4, 'table.binsearch comparator-equivalent strings high')
assert_eq(table.bininsert(sorted, 3), 5, 'table.bininsert index')
assert_eq(sorted[5], 3, 'table.bininsert value')

local mapped = table.map({ a = 2, b = 3 }, function(k, v) return k .. v end)
assert_eq(mapped.a, 'a2', 'table.map')
local filtered = table.filter({ a = 1, b = 2 }, function(_, v) return v > 1 end)
assert_eq(filtered.a, nil, 'table.filter removed')
assert_eq(filtered.b, 2, 'table.filter kept')
local filtered_array = table.filterarray({ 1, 2, 3, 4 }, function(_, v) return v % 2 == 0 end)
assert_eq(#filtered_array, 2, 'table.filterarray count')
assert_eq(filtered_array[2], 4, 'table.filterarray order')

local mt = { marker = true }
local original = setmetatable({ child = { x = 1 } }, mt)
local copied = table.deepcopy(original)
assert_false(copied == original, 'table.deepcopy creates new root')
assert_false(copied.child == original.child, 'table.deepcopy creates new child')
assert_eq(getmetatable(copied), mt, 'table.deepcopy preserves metatable')
local copy_cycle = { name = 'cycle' }
copy_cycle.self = copy_cycle
local copied_cycle = table.deepcopy(copy_cycle)
assert_false(copied_cycle == copy_cycle, 'table.deepcopy cyclic copy creates new root')
assert_eq(copied_cycle.self, copied_cycle, 'table.deepcopy cyclic copy preserves cycle')
local protected_deepcopy_root = setmetatable({ a = 1 }, { __metatable = 'locked' })
local copy_ok, copy_err = pcall(function() table.deepcopy(protected_deepcopy_root) end)
assert_false(copy_ok, 'table.deepcopy rejects root protected metatable')
assert_true(tostring(copy_err):find('protected metatable', 1, true) ~= nil,
  'table.deepcopy root protected metatable error message')
local protected_deepcopy_child = setmetatable({ secret = 7 }, { __metatable = 'locked' })
local protected_deepcopy_parent = { root = 1, child = protected_deepcopy_child }
copy_ok, copy_err = pcall(function() table.deepcopy(protected_deepcopy_parent) end)
assert_false(copy_ok, 'table.deepcopy rejects nested protected metatable')
assert_true(tostring(copy_err):find('protected metatable', 1, true) ~= nil,
  'table.deepcopy nested protected metatable error message')

assert_true(table.contains({ a = 'x' }, 'x'), 'table.contains')
assert_eq(table.find({ a = 'x' }, 'x'), 'a', 'table.find')
assert_true(table.isequal({ a = { 1, 2 } }, { a = { 1, 2 } }), 'table.isequal')
local equal_cycle_left = { name = 'cycle' }
equal_cycle_left.self = equal_cycle_left
local equal_cycle_right = { name = 'cycle' }
equal_cycle_right.self = equal_cycle_right
assert_true(table.isequal(equal_cycle_left, equal_cycle_right), 'table.isequal equal cycles')
local unequal_cycle_left = { name = 'cycle' }
unequal_cycle_left.self = unequal_cycle_left
local unequal_cycle_right = { name = 'cycle', self = { name = 'cycle' } }
unequal_cycle_right.self.self = unequal_cycle_right.self
assert_false(table.isequal(unequal_cycle_left, unequal_cycle_right), 'table.isequal unequal cycles')
local recursive_eq_calls = 0
local recursive_eq_mt = {
  __eq = function(a, b)
    recursive_eq_calls = recursive_eq_calls + 1
    return table.isequal(a, b)
  end,
}
local recursive_eq_left = setmetatable({ name = 'cycle' }, recursive_eq_mt)
recursive_eq_left.self = recursive_eq_left
local recursive_eq_right = setmetatable({ name = 'cycle' }, recursive_eq_mt)
recursive_eq_right.self = recursive_eq_right
assert_true(table.isequal(recursive_eq_left, recursive_eq_right),
  'table.isequal equal cycles with recursive __eq')
assert_eq(recursive_eq_calls, 0, 'table.isequal does not call table __eq for equal cycles')
recursive_eq_right.name = 'different'
assert_false(table.isequal(recursive_eq_left, recursive_eq_right),
  'table.isequal unequal cycles with recursive __eq')
assert_eq(recursive_eq_calls, 0, 'table.isequal does not call table __eq for unequal cycles')
assert_eq(table.get({ a = 1 }, 'b', 9), 9, 'table.get default')
local got = { a = 1 }
assert_eq(table.getorset(got, 'b', 2), 2, 'table.getorset default')
assert_eq(got.b, 2, 'table.getorset stored')
assert_eq(table.swap(got, 'b', 3), 2, 'table.swap old')
assert_eq(got.b, 3, 'table.swap new')

local keys = table.keys({ b = true, a = true }, true)
assert_eq(table.concat(keys, ','), 'a,b', 'table.keys sorted')
local values = table.values({ b = 2, a = 1 }, true)
assert_eq(table.concat(values, ','), '1,2', 'table.values sorted')
local inv = table.invert({ a = 'x' })
assert_eq(inv.x, 'a', 'table.invert')

local to = { nested = { keep = true } }
table.copymissing(to, { nested = { add = true }, top = true })
assert_true(to.nested.keep and to.nested.add and to.top, 'table.copymissing')
local shallow_to = {}
assert_eq(table.shallowcopy({ a = 1 }, shallow_to), shallow_to, 'table.shallowcopy return')
assert_eq(shallow_to.a, 1, 'table.shallowcopy value')

local parts = table.gettablefromcommasplit('a, b,c')
assert_eq(table.concat(parts, '|'), 'a|b|c', 'table.gettablefromcommasplit')
local printable = table.getprintabletable({ a = 1 }, 1, ' ')
assert_true(printable:find('a: 1', 1, true) ~= nil, 'table.getprintabletable')
assert_true(table.deeptostring({ a = 1 }, 1):find('a = 1', 1, true) ~= nil, 'table.deeptostring')

assert_eq(table.wrapindex({ 1, 2, 3 }, 4), 1, 'table.wrapindex wraps past end')
assert_eq(table.wrapindex({ 1, 2, 3, extra = true }, 5), 2, 'table.wrapindex uses sequence length')
local ok, err = pcall(function() table.wrapindex({}, 1) end)
assert_false(ok, 'table.wrapindex rejects empty sequence')
assert_true(tostring(err):find('empty sequence', 1, true) ~= nil, 'table.wrapindex empty error message')
math.randomseed(1)
local shuffled = { 1, 2, 3 }
table.shuffle(shuffled)
table.sort(shuffled)
assert_eq(table.concat(shuffled, ','), '1,2,3', 'table.shuffle preserves values')
assert_true(table.removevalue(shuffled, 2), 'table.removevalue removed')
assert_eq(table.concat(shuffled, ','), '1,3', 'table.removevalue result')
local metadata_only = { 1, 3, metadata = 2 }
assert_false(table.removevalue(metadata_only, 2), 'table.removevalue ignores matching hash metadata')
assert_eq(table.concat(metadata_only, ','), '1,3', 'table.removevalue metadata array unchanged')
assert_eq(metadata_only.metadata, 2, 'table.removevalue metadata field unchanged')

local sorted_pairs_seen = {}
for k, v in table.sortedpairs({ b = 2, a = 1 }) do
  sorted_pairs_seen[#sorted_pairs_seen + 1] = k .. v
end
assert_eq(table.concat(sorted_pairs_seen, ','), 'a1,b2', 'table.sortedpairs')

local traversal = {}
for node in table.traverse({ { id = 'root', children = { { id = 'leaf' } } } }) do
  traversal[#traversal + 1] = node.id
end
assert_eq(table.concat(traversal, ','), 'root,leaf', 'table.traverse')
local a, b = table.unwindarray({ 'x', 'y' })
assert_eq(a .. b, 'xy', 'table.unwindarray')

local best, score, index = table.findminscore({ 'aaa', 'b', 'cc' }, function(v) return #v end)
assert_eq(best, 'b', 'table.findminscore value')
assert_eq(score, 1, 'table.findminscore score')
assert_eq(index, 2, 'table.findminscore index')
local mapfiltered, scores = table.mapfilter({ 1, 2, 3 }, function(v) return v > 1 and v * 10 end)
assert_eq(table.concat(mapfiltered, ','), '2,3', 'table.mapfilter values')
assert_eq(table.concat(scores, ','), '20,30', 'table.mapfilter scores')
local sortedvalues, sortedscores = table.mapfiltersort({ 3, 1, 2 }, function(v) return v end)
assert_eq(table.concat(sortedvalues, ','), '1,2,3', 'table.mapfiltersort values')
assert_eq(table.concat(sortedscores, ','), '1,2,3', 'table.mapfiltersort scores')

local handled = table.calleventhandlers({ function() return true end, function() return false end })
assert_true(handled, 'table.calleventhandlers')
local multi = table.callmultipleeventhandlers({ { function() return true end }, { function() return false end } })
assert_true(multi, 'table.callmultipleeventhandlers')

local ro = table.makereadonly({ 'x', 'y', a = 1, nested = { x = 2 } }, true)
assert_eq(ro.a, 1, 'table.makereadonly reads existing key')
assert_eq(ro.nested.x, 2, 'table.makereadonly reads nested key')
local ok = pcall(function() ro.b = 2 end)
assert_false(ok, 'table.makereadonly rejects new-key write')
ok = pcall(function() ro.a = 2 end)
assert_false(ok, 'table.makereadonly rejects existing-key write')
ok = pcall(function() ro.nested.x = 3 end)
assert_false(ok, 'table.makereadonly rejects nested existing-key write')
assert_eq(ro.a, 1, 'table.makereadonly existing key unchanged')
assert_eq(ro.nested.x, 2, 'table.makereadonly nested key unchanged')

local poisoned_source = { a = 1, nested = { x = 2 } }
local poisoned_proxy = { a = 'poisoned', nested = { x = 'poisoned' } }
local poisoned_visited = {}
poisoned_visited[poisoned_source] = { proxy = poisoned_proxy }
local poisoned_ro = table.makereadonly(poisoned_source, true, false, poisoned_visited)
assert_false(poisoned_ro == poisoned_proxy, 'table.makereadonly ignores caller visited proxy')
assert_eq(poisoned_ro.a, 1, 'table.makereadonly poisoned visited reads source key')
assert_eq(poisoned_ro.nested.x, 2, 'table.makereadonly poisoned visited reads nested source key')
ok = pcall(function() poisoned_ro.a = 3 end)
assert_false(ok, 'table.makereadonly poisoned visited rejects existing-key write')
ok = pcall(function() poisoned_ro.b = 4 end)
assert_false(ok, 'table.makereadonly poisoned visited rejects new-key write')
ok = pcall(function() poisoned_ro.nested.x = 5 end)
assert_false(ok, 'table.makereadonly poisoned visited rejects nested write')

if lua52_table_metamethods then
  local ropairs = {}
  for k, v in pairs(ro) do
    ropairs[k] = v
  end
  assert_eq(ropairs.a, 1, 'table.makereadonly pairs sees backing key')
  assert_eq(ropairs.nested.x, 2, 'table.makereadonly pairs sees nested proxy')

  local roipairs = {}
  for _, v in ipairs(ro) do
    roipairs[#roipairs + 1] = v
  end
  assert_eq(table.concat(roipairs, ','), 'x,y', 'table.makereadonly ipairs sees backing array')

  local rochoice = table.makereadonly({ first = 'a', second = 'b' }, true)
  local choicevalue, choicekey = table.choice(rochoice)
  assert_true(choicevalue == 'a' or choicevalue == 'b', 'table.choice readonly value is present')
  assert_true(choicekey == 'first' or choicekey == 'second', 'table.choice readonly key is present')
end
math.randomseed(24601)
table.choice({ 'a', 'b', 'c', 'd', 'e' })
local after_choice = math.random()
math.randomseed(24601)
math.random(5)
assert_eq(after_choice, math.random(),
  'table.choice non-empty table consumes one random draw')
math.randomseed(13579)
local emptyvalue, emptykey = table.choice({})
local after_empty_choice = math.random()
math.randomseed(13579)
assert_eq(emptyvalue, nil, 'table.choice empty table returns nil value')
assert_eq(emptykey, nil, 'table.choice empty table returns nil key')
assert_eq(after_empty_choice, math.random(), 'table.choice empty table consumes no random draw')

local original_ro = { a = 1 }
local same_ro = table.makereadonly(original_ro, false)
assert_eq(same_ro, original_ro, 'table.makereadonly copy=false returns original proxy')
assert_eq(original_ro.a, 1, 'table.makereadonly copy=false reads through original')
ok = pcall(function() original_ro.a = 2 end)
assert_false(ok, 'table.makereadonly copy=false rejects existing-key write')

local hidden_source = setmetatable({ visible = 1, hidden = 2 }, {
  __pairs = function(t)
    return next, { visible = rawget(t, 'visible') }, nil
  end,
})
local hidden_ro = table.makereadonly(hidden_source, false)
assert_eq(hidden_ro.hidden, 2, 'table.makereadonly copy=false raw-freezes hidden __pairs key')
ok = pcall(function() hidden_ro.hidden = 3 end)
assert_false(ok, 'table.makereadonly rejects hidden existing-key write')
assert_eq(hidden_ro.hidden, 2, 'table.makereadonly hidden key unchanged')

local protected_source = setmetatable({ a = 1 }, { __metatable = 'locked' })
ok = pcall(function() table.makereadonly(protected_source, false) end)
assert_false(ok, 'table.makereadonly copy=false rejects protected source metatable')
assert_eq(rawget(protected_source, 'a'), 1, 'table.makereadonly protected source keeps raw entry')
assert_eq(getmetatable(protected_source), 'locked', 'table.makereadonly protected source keeps metatable')

local protected_child = setmetatable({ secret = 7 }, { __metatable = 'locked' })
local protected_parent = { root = 1, child = protected_child }
ok = pcall(function() table.makereadonly(protected_parent, false) end)
assert_false(ok, 'table.makereadonly copy=false rejects nested protected metatable')
assert_eq(rawget(protected_parent, 'root'), 1, 'table.makereadonly protected nested keeps root entry')
assert_eq(rawget(protected_parent, 'child'), protected_child, 'table.makereadonly protected nested keeps child ref')
assert_eq(rawget(protected_child, 'secret'), 7, 'table.makereadonly protected nested keeps child entry')

local cycle = { name = 'cycle' }
cycle.self = cycle
local rocycle = table.makereadonly(cycle, true)
assert_eq(rocycle.self, rocycle, 'table.makereadonly preserves cycles')
ok = pcall(function() rocycle.self.name = 'changed' end)
assert_false(ok, 'table.makereadonly rejects cyclic nested write')

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

plan tests => 1;

is "$rc:$out$err", "0:ok\n", 'math/table extension API smoke coverage';
