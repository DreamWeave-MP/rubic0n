-------------------------------------------------------------------------------
-- Generate a C include that embeds one source file as a string literal.
-------------------------------------------------------------------------------

local args = {...}

local function usage(arg)
  io.stderr:write("Usage: ", arg and arg[0] or "genembed",
                  " -n symbol -o output input\n")
  os.exit(1)
end

local function parse_arg(arg)
  local name, outfile, infile
  local i = 1
  while arg and arg[i] do
    if arg[i] == "-n" then
      name = arg[i+1]
      i = i + 2
    elseif arg[i] == "-o" then
      outfile = arg[i+1]
      i = i + 2
    elseif not infile then
      infile = arg[i]
      i = i + 1
    else
      usage(arg)
    end
  end
  if not (name and outfile and infile) or not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    usage(arg)
  end
  return name, outfile, infile
end

local function read_file(path)
  local fp = assert(io.open(path, "rb"))
  local data = assert(fp:read("*a"))
  assert(fp:close())
  return data
end

local function c_quote_line(line)
  return line:gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function generate(name, data)
  data = data:gsub("\r\n", "\n"):gsub("\r", "\n")
  local out = {
    "/* This is a generated file. DO NOT EDIT! */\n",
    "static const char ", name, "[] =\n"
  }
  local pos = 1
  local emitted = false
  while pos <= #data do
    local nextpos = data:find("\n", pos, true)
    local line
    if nextpos then
      line = data:sub(pos, nextpos - 1)
      pos = nextpos + 1
      out[#out+1] = '"'..c_quote_line(line)..'\\n"\n'
      emitted = true
    else
      line = data:sub(pos)
      pos = #data + 1
      if #line > 0 then
        out[#out+1] = '"'..c_quote_line(line)..'"\n'
        emitted = true
      end
    end
  end
  if not emitted then out[#out+1] = '""\n' end
  out[#out+1] = ";\n"
  return table.concat(out)
end

local function write_file(path, data)
  local oldfp = io.open(path, "rb")
  if oldfp then
    local old = oldfp:read("*a")
    oldfp:close()
    if old == data then return end
  end
  local fp = assert(io.open(path, "wb"))
  assert(fp:write(data))
  assert(fp:close())
end

local name, outfile, infile = parse_arg(args)
write_file(outfile, generate(name, read_file(infile)))
