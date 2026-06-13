---@meta

---@class tablelib
table = table or {}

---@alias table.SortFunc fun(a: any, b: any): boolean

---@class table.PairsIterable
---@field __pairs fun(t: self): fun(): any, any

---@class table.IpairsIterable
---@field __ipairs fun(t: self): fun(): any, any

---@class table.ReadOnlyTable: table

---Inserts value into a sorted array and returns the inserted index.
---@generic V
---@param t V[]
---@param value V
---@param comp? fun(a: V, b: V): boolean Defaults to a < b.
---@return integer index
function table.bininsert(t, value, comp) end

---Finds value in a sorted array by binary search.
---With findall and a comparator, the returned range includes all
---comparator-equivalent values, where neither comp(a, b) nor comp(b, a) is
---true. Without a comparator, or when comp is false, default `<` only locates
---order-equivalent candidates; actual matches and findall ranges require
---rawequal(tbl[i], value).
---@generic V
---@param tbl V[]
---@param value V
---@param comp? table.SortFunc|false Defaults to a < b. False is treated like nil.
---@param findall? boolean Return lowest and highest matching indices.
---@return integer? index
---@return integer? highestmatch
function table.binsearch(tbl, value, comp, findall) end

---Calls event handlers in reverse order until one returns false.
---@param handlers (fun(...): boolean?)[]
---@param ... any
---@return boolean eventhandled True if no further handlers should be called.
function table.calleventhandlers(handlers, ...) end

---Calls arrays of event handlers until one group handles the event.
---@param handlers (fun(...): boolean?)[][]
---@param ... any
---@return boolean eventhandled True if no further handlers should be called.
function table.callmultipleeventhandlers(handlers, ...) end

---Returns a random value and key from a table.
---@generic K, V
---@param t table<K, V>
---@return V? value
---@return K? key
function table.choice(t) end

---Returns whether the table contains value.
---@generic K, V
---@param t table<K, V>
---@param value V
---@return boolean result
function table.contains(t, value) end

---Copies missing values from from into to, recursing through child tables.
---@param to table
---@param from table
function table.copymissing(to, from) end

---Deep-copies a table, preserving accessible metatables and repeated
---references. Tables with protected metatables are unsupported because the
---real metatable is intentionally hidden from getmetatable.
---@generic T: table
---@param root T
---@param copies? table<table, table>
---@return T cloned
function table.deepcopy(root, copies) end

---Recursively converts a value to a human-readable string.
---@param val any
---@param level? integer Maximum recursion depth. Defaults to 1.
---@param prefix? string Current indentation prefix.
---@return string result
function table.deeptostring(val, level, prefix) end

---Filters key/value pairs into a new table.
---@generic K, V
---@param t table<K, V>
---@param f fun(k: K, v: V, ...): boolean
---@param ... any
---@return table<K, V> result
function table.filter(t, f, ...) end

---Filters array values into a new compact array.
---@generic V
---@param arr V[]
---@param f fun(i: integer, v: V, ...): boolean
---@param ... any
---@return V[] result
function table.filterarray(arr, f, ...) end

---Returns the first key whose value equals value.
---@generic K, V
---@param t table<K, V>
---@param value V
---@return K? key
function table.find(t, value) end

---Finds the array element with the lowest score returned by scorefn.
---@generic V
---@param array V[]
---@param scorefn fun(x: V): number?
---@return V? element
---@return number? score
---@return integer? index
function table.findminscore(array, scorefn) end

---Returns t[key] or defaultvalue when t[key] is nil.
---@generic K, V, D
---@param t table<K, V>
---@param key K
---@param defaultvalue D
---@return V|D result
function table.get(t, key, defaultvalue) end

---Returns t[key], or stores and returns defaultvalue when t[key] is nil.
---@generic K, V, D
---@param t table<K, V>
---@param key K
---@param defaultvalue D
---@return V|D result
function table.getorset(t, key, defaultvalue) end

---Returns a printable multi-line representation of a table-like value.
---@param inputtable table|userdata
---@param maxdepth? integer Defaults to 50.
---@param indentstr? string Defaults to a tab.
---@param indentlevel? integer Defaults to 0.
---@return string result
function table.getprintabletable(inputtable, maxdepth, indentstr, indentlevel) end

---Splits a comma-separated string into a table.
---@param inputstring string
---@return string[] matchingparts
function table.gettablefromcommasplit(inputstring) end

---Splits a string using a Lua pattern and returns all captures/matches.
---@param inputstring string
---@param pattern string
---@return string[] matchingparts
function table.gettablefromsplit(inputstring, pattern) end

---Inverts keys and values into a new table.
---@generic K, V
---@param t table<K, V>
---@return table<V, K> result
function table.invert(t) end

---Returns true when all non-nil keys are integer number keys.
---This is the OpenResty C implementation; arrays may be sparse.
---@param t table
---@return boolean result
function table.isarray(t) end

---Returns true when the table has no non-nil values.
---This is the OpenResty C implementation.
---@param t table
---@return boolean result
function table.isempty(t) end

---Recursively compares tables by key/value equality without recursing forever
---on cycles.
---@param left any
---@param right any
---@return boolean result
function table.isequal(left, right) end

---Returns table keys, optionally sorted.
---@generic K
---@param t table<K, any>
---@param sortorsortfunc? boolean|table.SortFunc
---@return K[] keys
function table.keys(t, sortorsortfunc) end

---Returns a proxy that guards normal assignment through the returned table.
---This protects `t.k = v` and `t[k] = v` on the proxy/converted tables, but it
---only guards normal assignment. It is not a sandbox boundary against rawset,
---debug-library metatable/upvalue access, or hostile privileged code.
---Omitting copy uses copy=false: table.makereadonly(t) converts t in place and
---rehomes raw entries behind backing storage. rawget, next, and raw serializers
---see different storage after conversion.
---Builds without LUAJIT_ENABLE_LUA52COMPAT do not make pairs, ipairs, or #
---reflect readonly proxy backing storage. Normal field reads and normal
---assignment guarding still work.
---@generic T: table
---@param intable T
---@param copy? boolean Defaults to false. Copy instead of converting in place.
---@param strict? boolean Throw when reading missing keys.
---@param visited? table<table, table>
---@return table.ReadOnlyTable result
function table.makereadonly(intable, copy, strict, visited) end

---Maps key/value pairs into a new table.
---@generic K, V, N
---@param t table<K, V>
---@param f fun(k: K, v: V, ...): N
---@param ... any
---@return table<K, N> result
function table.map(t, f, ...) end

---Maps an array through scorefn, keeping values with non-false scores.
---@generic V, S
---@param array V[]
---@param scorefn fun(x: V): S?
---@return V[] output
---@return S[] scores
function table.mapfilter(array, scorefn) end

---Maps and filters an array, then sorts by returned scores.
---@generic V
---@param array V[]
---@param scorefn fun(x: V): number?
---@return V[] output
---@return number[] scores
function table.mapfiltersort(array, scorefn) end

---Prints table.getprintabletable(inputtable, ...).
---@param inputtable table|userdata
---@param maxdepth? integer
---@param indentstr? string
---@param indentlevel? integer
function table.print(inputtable, maxdepth, indentstr, indentlevel) end

---Removes the first sequence element equal to value.
---@generic V
---@param list V[]
---@param value V
---@return boolean removed
function table.removevalue(list, value) end

---Shallow-copies values from one table to another table.
---@generic F: table, T: table
---@param from F
---@param to? T
---@return F|T result
function table.shallowcopy(from, to) end

---Shuffles array values in place.
---@generic V
---@param t V[]
---@param n? integer Number of leading elements to shuffle. Defaults to #t.
function table.shuffle(t, n) end

---Returns an iterator over keys in sorted order.
---@generic K, V
---@param tbl table<K, V>
---@param comparator? fun(a: K, b: K): boolean
---@return fun(): K, V iterator
function table.sortedpairs(tbl, comparator) end

---Replaces t[key] and returns the old value.
---@generic K, V, N
---@param t table<K, V>
---@param key K
---@param value N
---@return V? oldvalue
function table.swap(t, key, value) end

---Traverses an array/list of root nodes depth-first, yielding each node.
---@param t table Array/list of root nodes.
---@param k? string Child array key. Defaults to "children".
---@return fun(): any iterator
function table.traverse(t, k) end

---Unpacks all values from an object iterable with pairs.
---@param object table.PairsIterable|table
---@return any ...
function table.unwind(object) end

---Unpacks all values from an object iterable with ipairs.
---@param object table.IpairsIterable|table
---@return any ...
function table.unwindarray(object) end

---Returns table values, optionally sorted.
---@generic V
---@param t table<any, V>
---@param sortorsortfunc? boolean|table.SortFunc
---@return V[] values
function table.values(t, sortorsortfunc) end

---Wraps an arbitrary index into the sequence's 1-based #t range.
---Throws when #t is zero because an empty sequence has no valid wrapped index.
---@param t any[]
---@param index integer
---@return integer index
function table.wrapindex(t, index) end
