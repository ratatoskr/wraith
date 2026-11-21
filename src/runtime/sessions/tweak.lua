-- Runs `.rwt` tweaks. A session compiles one into calls on `__t`, one line for each of the
-- tweak's, so whatever fails can say the tweak's own line. Code changes are made off and all
-- switched on in `done`, so a tweak that fails part way changes nothing, and `stop` undoes them.
-- Wraith's areas are globals here.

local sal = require("salamander")
--
-- A group's file runs its shared part like a lone tweak but in an env of its own, then each of
-- its tweaks in `part`, with an env and state of their own that fall back to the shared part's.
-- A nested group's shared part runs the same way, and what's in it falls back to its.
-- Under a group's `@globals shared`, plain global writes from what's in it go to that group's
-- env, but `off`, `tick` and the like stay in each part's own.

-- What a part owns. Its code changes, names, data and schema
local function fresh(name, parent, env)
  local p = {
    name = name,
    parent = parent,
    made = {},
    -- `@sym` and `@data` names in order, its groups' too for asm, and where each is
    names = {},
    where = {},
    -- Just its own, for the game's names
    own = {},
    -- `@data` names' types
    data_types = {},
    fields = {},
    cells = {},
    schemas = {},
    -- `@data` and asm `@patch`es and `@inject`s not placed yet, see `flush`
    pending = { data = {}, code = {} },
    pending_names = {},
    -- What its `@use`s' `install` gave back
    uses = {},
    schema_text = parent and parent.schema_text or "",
    types = parent and parent.types,
    env = env,
    -- The env plain global writes go to, under `@globals shared`
    globals = parent and parent.globals,
  }
  if parent then
    for i, n in ipairs(parent.names) do
      p.names[i] = n
      p.where[n] = parent.where[n]
    end
    for k, v in pairs(parent.data_types) do p.data_types[k] = v end
  end
  return p
end

-- A lone tweak's, or a group's shared part
local shared = fresh("", nil, _G)
local parts = { [""] = shared }
local cur = shared
local sizes = { u8 = 1, i8 = 1, bool = 1, u16 = 2, i16 = 2, u32 = 4, i32 = 4, f32 = 4, u64 = 8, i64 = 8, f64 = 8 }
-- Names the runner finds in each part's own env, so they stay there even when globals are shared
local per_part = { off = true, tick = true, data = true, sym = true, types = true }

-- A table, so it's told apart from errors in the tweak's own code
local Problem = { __name = "Problem" }
Problem.__index = Problem
Problem.__tostring = function(p) return p.message end

local function at(line, message)
  return setmetatable({ message = "line " .. line .. ": " .. message }, Problem)
end

local function fail(line, message)
  error(at(line, message), 0)
end

-- Without the error's name in front, which Wraith's errors have
local function message_of(e)
  if getmetatable(e) == Problem then return e.message end
  if type(e) == "string" then return e end
  if type(e) == "table" and type(e.message) == "string" then
    local m = e.message
    if type(e.name) == "string" and m:sub(1, #e.name + 2) == e.name .. ": " then m = m:sub(#e.name + 3) end
    return m
  end
  return tostring(e)
end

local function num(a)
  return math.tointeger(a) or a
end

-- Typed reads and writes, for `@data` and `@sym`
local kinds = { u8 = "U8", i8 = "I8", u16 = "U16", i16 = "I16", u32 = "U32", i32 = "I32", u64 = "U64", i64 = "I64", f32 = "F32", f64 = "F64", bool = "U8" }
local function cell_at(address)
  local cell = { address = address }
  function cell.load(_, kind)
    local v = memory["read" .. kinds[kind]](memory, address)
    if kind == "bool" then return v ~= 0 end
    return v
  end
  function cell.store(_, kind, v)
    if kind == "bool" then v = v and 1 or 0 end
    memory["write" .. kinds[kind]](memory, address, v)
  end
  return cell
end

local function set_name(name, address)
  if cur.where[name] == nil then cur.names[#cur.names + 1] = name end
  cur.where[name] = address
  cur.own[#cur.own + 1] = name
end

-- Location text like `game.exe+0x10`, `sig("48 8B ??", Rip)` or `[ptr]+8`, see
-- `addresses.resolve`. Names from @sym and @data come first
local function scope()
  local list = {}
  for i, name in ipairs(cur.names) do list[i] = { name = name, address = cur.where[name] } end
  return list
end

local function evaluate(line, text)
  for name in pairs(cur.pending_names) do
    if text:find("%f[%w_.]" .. name .. "%f[^%w_.]") then
      __t.flush()
      break
    end
  end
  local ok, v = pcall(function() return num(addresses:resolve(text, scope())) end)
  if not ok then fail(line, message_of(v)) end
  return v
end

-- Comment-free code and the comment, like the assembler sees them
local function split_comment(l)
  local quote
  for i = 1, #l do
    local ch = l:sub(i, i)
    if quote then
      if ch == quote then quote = nil end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "/" and l:sub(i + 1, i + 1) == "/" then
      return l:sub(1, i - 1), l:sub(i)
    end
  end
  return l, ""
end

local function lines_of(src)
  local list = {}
  for l in (src .. "\n"):gmatch("(.-)\n") do list[#list + 1] = l end
  return list
end

-- Asm gets @data and @sym names through `names`, so they can't be labels too
local function check_names(line, src)
  for k, l in ipairs(lines_of(src)) do
    local code = split_comment(l)
    for _, name in (" " .. code):gmatch("([^%w_.$@?])([A-Za-z_][%w_.]*)%s*:") do
      if cur.where[name] or cur.pending_names[name] then fail(line + k - 1, name .. " is a @data or @sym name, so it can't be a label too") end
    end
  end
  return src
end

-- `90 C3`, or `x"90C3"` like asm's db
local function bytes_of(line, src)
  local out = {}
  for k, l in ipairs(lines_of(src)) do
    local function add(b)
      if not b:match("^%x%x$") then fail(line + k - 1, b .. " isn't a byte, like 90 or C3") end
      out[#out + 1] = tonumber(b, 16)
    end
    local code, at = split_comment(l), 1
    while true do
      local s = code:find("[^%s,]", at)
      if not s then break end
      local hex, e = code:match('^[xX]"([^"]*)"()', s)
      if hex then
        for t in hex:gmatch("%S+") do
          for i = 1, #t, 2 do add(t:sub(i, i + 1)) end
        end
        at = e
      else
        local b = code:match("^[^%s,]+", s)
        add(b)
        at = s + #b
      end
    end
  end
  if #out == 0 then fail(line, "there are no bytes under it") end
  return out
end

-- Error names from the runtime, said plainly
local plain = {
  UnexpectedBytes = "the bytes there aren't what expect says",
  SplitsInstruction = "that ends inside an instruction, so give a size or expect that covers whole ones",
  AlreadyHooked = "something else already changed the code there",
}

-- `src` is what was written, before names became addresses
local function asm_error(line, e, src)
  local text = message_of(e)
  local n, message = text:match("^line (%d+): (.*)$")
  if not n then
    -- Said plainly when the runtime didn't say more
    local bare = type(e) == "table" and plain[e.name] and (text == "" or text == e.name)
    return at(line, bare and plain[e.name] or text)
  end
  n = tonumber(n)
  local written = src and split_comment(lines_of(src)[n] or "") or ""
  local far
  for _, name in ipairs(cur.names) do
    if written:find("%f[%w_.]" .. name .. "%f[^%w_.]") then
      far = name
      break
    end
  end
  if far and message:sub(1, 12) == "can't encode" then
    message = message .. ". " .. far .. " is too far from this code to use directly, so load it first, like mov rax, " .. far .. " then [rax]"
  end
  return at(line + n - 1, message)
end

local function make(line, create, src)
  local ok, item = pcall(create)
  if not ok then error(asm_error(line, item, src), 0) end
  cur.made[#cur.made + 1] = { line = line, item = item }
end

-- An asm `@patch` or `@inject`, made in `flush` with the part's data
local function later(line, target, src, options)
  local slot = { line = line }
  cur.made[#cur.made + 1] = slot
  options.target = target
  options.source = src
  options.names = scope()
  options.inject = options.inject or false
  options.size = options.size or 0
  options.expect = options.expect or ""
  cur.pending.code[#cur.pending.code + 1] = { line = line, src = src, slot = slot, request = options }
end

-- A signature like `[Thiscall] f32 (Player* self, i32)`, in `.sal`'s way, with `fn` and a
-- name for each parameter
local function signature_of(text)
  local open = text:find("(", 1, true)
  local close = text:match(".*()%)")
  if not open or not close or close < open then return text end
  local head = text:sub(1, open - 1):gsub("%s+$", "")
  if not head:find("%f[%w]fn%f[%W]") then
    local attrs = head:match("^(%b[]%s*)") or ""
    head = attrs .. "fn " .. head:sub(#attrs + 1)
  end
  local params = {}
  for raw in text:sub(open + 1, close - 1):gmatch("[^,]+") do
    local p = raw:match("^%s*(.-)%s*$")
    if p ~= "" then
      if p:match("^[%w_.]+[%*%[%]%d]*$") or p:sub(-1) == "*" then p = p .. " a" .. #params end
      params[#params + 1] = p
    end
  end
  return head .. " (" .. table.concat(params, ", ") .. ")"
end

-- A mid hook calling `body(cpu, original, resume)`, where those two jump there when it returns
local function mid_hook(line, target, body, options)
  make(line, function()
    local original_at, resume_at = 0, 0
    options.replace = options.replace or false
    options.size = options.size or 0
    options.expect = options.expect or ""
    options.names = options.names or {}
    options.disabled = true
    local h = hooks:mid(target, options, function(cpu)
      local ip = cpu.rip ~= nil and "rip" or "eip"
      local function original() cpu[ip] = original_at end
      local ok, e = pcall(body, cpu, original, function() cpu[ip] = resume_at end)
      if not ok then
        -- The code it replaced runs, so a broken patch doesn't break the game
        original()
        log:warn("line " .. line .. ": " .. message_of(e))
      end
    end)
    original_at = h:original()
    resume_at = h:resume()
    return h
  end)
end

-- A function a part can call, its own or the shared part's
local function lookup(part, name)
  if part.env == _G then return rawget(_G, name) end
  return part.env[name]
end

local function choices_of(part, f)
  local list = lookup(part, f.choices)
  if type(list) ~= "function" then fail(f.line, "there's no function " .. f.choices .. " for its Choices") end
  local ok, items = pcall(list)
  if not ok then fail(f.line, f.choices .. "(): " .. message_of(items)) end
  if type(items) ~= "table" then fail(f.line, f.choices .. "(): expected a table of choices") end
  local out = {}
  for i, it in ipairs(items) do
    if type(it) == "table" and it[1] ~= nil then
      out[i] = { value = tonumber(it[1]), label = tostring(it[2]) }
    elseif type(it) == "table" then
      out[i] = { value = tonumber(it.value), label = tostring(it.label) }
    else
      local s = tostring(it)
      local colon = s:find(":", 1, true) or (#s + 1)
      out[i] = { value = tonumber(s:sub(1, colon - 1)), label = s:sub(colon + 1) }
    end
  end
  return out
end

-- Just what `done` sends. Strings, numbers, nil, and records of them with their keys in order
local function to_json(v, keys)
  local t = type(v)
  if v == nil then return "null" end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return math.type(v) == "integer" and string.format("%d", v) or string.format("%.17g", v)
  end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(ch) return string.format("\\u%04x", ch:byte()) end) .. '"'
  end
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = to_json(k) .. ":" .. to_json(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function json_list(items)
  return "[" .. table.concat(items, ",") .. "]"
end

-- A cell in a group `part` is in
local function above_has(part, name)
  local p = part.parent
  while p do
    if p.cells[name] then return true end
    p = p.parent
  end
  return false
end

-- Reads and writes `part`'s cells, then whatever `parent` has. Its data gets placed first if
-- it's not yet
local function data_of(part, parent)
  local function cell(name)
    if part.pending_names[name] then __t.flush(part) end
    return part.cells[name]
  end
  return setmetatable({}, {
    __index = function(_, name)
      local c = cell(name)
      if c then return c.cell:load(c.kind) end
      if parent then return parent[name] end
    end,
    __newindex = function(t, name, v)
      local c = cell(name)
      if c then return c.cell:store(c.kind, v) end
      if parent and above_has(part, name) then
        parent[name] = v
        return
      end
      rawset(t, name, v)
    end,
  })
end

data = data_of(shared, nil)
sym = {}
shared.sym = sym
shared.data = data

__t = {}

-- Gives the env a part's code runs in. The shared part's falls back to the globals, and each
-- of a group's tweaks or nested groups to its group's. `parent` is the nested group it's in.
-- `shares` is a group's `@globals shared`, and then plain writes from what's in it go to its env
function __t.part(name, parent, shares)
  if name == "" then
    if shared.env == _G then shared.env = setmetatable({}, { __index = _G }) end
    if shares then shared.globals = shared.env end
    cur = shared
    return shared.env
  end
  local above = parts[parent or ""]
  if not above then error(at(1, "its group " .. tostring(parent) .. " isn't on"), 0) end
  local env = {}
  local meta = { __index = above.env }
  cur = fresh(name, above, env)
  cur.sym = setmetatable({}, { __index = above.sym })
  cur.data = data_of(cur, above.data)
  env.data = cur.data
  env.sym = cur.sym
  env.types = cur.types
  if shares then
    cur.globals = env
  elseif cur.globals then
    local globals = cur.globals
    meta.__newindex = function(t, k, v)
      if per_part[k] then return rawset(t, k, v) end
      rawset(globals, k, v)
    end
  end
  setmetatable(env, meta)
  parts[name] = cur
  return env
end

-- The tweak file's saved id, like `kai`, set by the provider
__t.file = ""
-- Its project's schemas, which a tweak's own come after
__t.project = ""

-- An absolute saved id as `./` relative to this file if it's in it
local function relative(name)
  local file = __t.file
  if name == file then return "." end
  if file ~= "" and name:sub(1, #file + 1) == file .. "/" then return "./" .. name:sub(#file + 2) end
  return name
end

-- A saved name, from `./x` or `.` in this file
local function absolute(name)
  local file = __t.file
  if name == "." then return file end
  if name:sub(1, 2) == "./" then return file .. "/" .. name:sub(3) end
  return name
end

-- What `@use` libraries get as `tweaks`: Wraith's, taking names like `./Combat` in this file
local bridge = {
  isOn = function(name) return tweaks:isOn(absolute(name)) end,
  setOn = function(name, on) tweaks:setOn(absolute(name), on) end,
}

-- `@use name`. A library with `install(env, options)` installs into this part's env, and the
-- name holds what it gave back. Else the name holds the library. Either way before the part's
-- own code. A handle with `toggled` hears every tweak switched, and its `stop` runs when the
-- part stops
function __t.use(line, name, title)
  local ok, lib = pcall(require, name)
  if not ok then fail(line, "@use " .. name .. ": " .. message_of(lib)) end
  local part = cur
  local value = lib
  if type(lib) == "table" and type(lib.install) == "function" then
    local options = { name = title ~= "" and title or __t.file, path = part.name, tweaks = bridge }
    local ok2, handle = pcall(lib.install, part.env, options)
    if not ok2 then fail(line, "@use " .. name .. ": " .. message_of(handle)) end
    if handle ~= nil then value = handle end
    part.uses[#part.uses + 1] = value
    if type(value) == "table" and type(value.toggled) == "function" then
      local heard = tweaks:onSwitched(function(n, on) value.toggled(relative(n), on) end)
      part.uses[#part.uses + 1] = { stop = function() heard:cancel() end }
    end
  end
  rawset(part.env, name, value)
end

function __t.sym(line, name, text)
  local v = evaluate(line, text)
  set_name(name, v)
  cur.sym[name] = cell_at(v)
end

function __t.data(line, near, list)
  local size = 0
  local placed = {}
  for i, f in ipairs(list) do
    local n = sizes[f.type]
    size = (size + n - 1) // n * n
    placed[i] = { f = f, offset = size }
    size = size + n
  end
  if #placed == 0 then return end
  -- Placed with the patches and injects that read it, in `flush`
  local where = near ~= "" and evaluate(line, near) or nil
  cur.pending.data[#cur.pending.data + 1] = { line = line, near = where, size = math.max(size, 8), placed = placed }
  for _, p in ipairs(placed) do
    cur.pending_names[p.f.name] = true
    -- Listed now, so the game's names keep the tweak's order
    cur.own[#cur.own + 1] = p.f.name
  end
end

-- Places the part's pending data and asm together, so the code always reaches it, then fills
-- in the data. Before anything needs it, or in `done`
function __t.flush(part)
  part = part or cur
  local p = part.pending
  if #p.data == 0 and #p.code == 0 then return end
  part.pending = { data = {}, code = {} }
  part.pending_names = {}
  local was = cur
  cur = part
  local near
  local data = {}
  for i, d in ipairs(p.data) do
    near = near or d.near
    local names = {}
    for k, placed in ipairs(d.placed) do names[k] = { name = placed.f.name, offset = placed.offset } end
    data[i] = { size = d.size, alignment = 0, names = names }
  end
  local list = {}
  for i, c in ipairs(p.code) do list[i] = c.request end
  local ok, done = pcall(code.place, code, { near = near or memory:main().base, data = data, code = list })
  if not ok then
    cur = was
    local text = message_of(done)
    local n, rest = text:match("^code (%d+), (line %d+: .*)$")
    if not n then n, rest = text:match("^code (%d+): (.*)$") end
    if n then
      local c = p.code[tonumber(n)]
      error(asm_error(c.line, { name = type(done) == "table" and done.name or nil, message = rest }, c.src), 0)
    end
    local line = (p.data[1] or p.code[1]).line
    local bytes = text:match("^no room for (%d+) bytes")
    local name = part.name ~= "" and part.name or __t.file
    if bytes then fail(line, name .. " needs " .. bytes .. " bytes for its code and data in one place, and there's no room for that") end
    fail(line, "couldn't place its code and data: " .. text)
  end
  for i, c in ipairs(p.code) do c.slot.item = done.code[i] end
  for i, d in ipairs(p.data) do
    local base = num(done.data[i])
    for _, placed in ipairs(d.placed) do
      local f = placed.f
      local address = base + placed.offset
      local cell = cell_at(address)
      local kind = f.type
      local value = f.value
      if kind == "bool" then
        value = value ~= 0
      elseif kind:sub(1, 1) ~= "f" and math.type(value) == "float" then
        value = value >= 0 and math.floor(value) or math.ceil(value)
      end
      if not pcall(cell.store, cell, kind, value) then
        cur = was
        fail(f.line, tostring(f.value) .. " doesn't fit a " .. kind)
      end
      if cur.where[f.name] == nil then cur.names[#cur.names + 1] = f.name end
      cur.where[f.name] = address
      cur.cells[f.name] = { cell = cell, kind = kind }
      cur.fields[#cur.fields + 1] = { name = f.name, address = address, line = f.line, choices = f.choices }
      cur.data_types[f.name] = kind
    end
  end
  cur = was
end

-- Gives `types`, which a group's tweak keeps as its own
function __t.schema(line, text)
  local _, lines_before = cur.schema_text:gsub("\n", "")
  cur.schemas[#cur.schemas + 1] = { start = lines_before + 1, line = line }
  cur.schema_text = cur.schema_text .. "\n" .. text
  local project = __t.project ~= "" and (__t.project .. '\nfile "tweak.sal";\n') or ""
  local ok, parsed = pcall(sal.load, "tweak", project .. cur.schema_text)
  if ok then
    -- So the runtime knows them too, for hooks' signatures
    schema:add("tweak.sal", cur.schema_text)
    cur.types = parsed
    if cur == shared then types = parsed end
    return parsed
  end
  local message = message_of(parsed):gsub("^tweak%.sal: ?", "")
  local n, rest = message:match("^(%d+):%d+: (.*)$")
  if not n then fail(line, message) end
  n = tonumber(n)
  local from
  for _, l in ipairs(cur.schemas) do
    if l.start <= n then from = l end
  end
  -- In the shared part's, which the shared part already checked
  if not from then fail(line, rest) end
  fail(from.line + n - from.start, rest)
end

function __t.patch(line, text, expect, size, src)
  src = "\n" .. src
  local target = evaluate(line, text)
  later(line, target, check_names(line, src), { expect = expect, size = size ~= 0 and size or nil })
end

function __t.bytes(line, text, expect, src)
  src = "\n" .. src
  local target = evaluate(line, text)
  local bytes = bytes_of(line, src)
  make(line, function() return code:patchBytes(target, string.char(table.unpack(bytes)), { size = 0, expect = expect or "", disabled = true, names = scope() }) end)
end

function __t.inject(line, text, src)
  src = "\n" .. src
  local target = evaluate(line, text)
  later(line, target, check_names(line, src), { inject = true })
end

-- `body(cpu, original, resume)` in place of the code there
function __t.patchLua(line, text, expect, size, body)
  mid_hook(line, evaluate(line, text), body, { replace = true, expect = expect, size = size, names = scope() })
end

-- `body(cpu, original, resume)` before the instruction there
function __t.injectLua(line, text, body)
  mid_hook(line, evaluate(line, text), body, {})
end

-- `body(original, ...)` in place of the function there
function __t.hook(line, text, signature, body)
  local target = evaluate(line, text)
  local sig = signature_of(signature)
  make(line, function()
    local call
    local function original(...) return call(...) end
    local h = hooks:detour(target, sig, sal.fn(sig, function(...) return body(original, ...) end), { context = 0, disabled = true })
    call = sal.native(sig, h:original())
    return h
  end)
end

-- Gives where its data went, for the UI
function __t.done()
  local part = cur
  __t.flush(part)
  cur = shared
  local on = {}
  for _, m in ipairs(part.made) do
    local ok, e = pcall(m.item.enable, m.item)
    if not ok then
      for i = #on, 1, -1 do pcall(on[i].item.disable, on[i].item) end
      fail(m.line, "couldn't turn it on: " .. message_of(e))
    end
    on[#on + 1] = m
  end
  local tick = rawget(part.env, "tick")
  if type(tick) == "function" then part.tick = frame:onFrame(tick) end
  local out_fields = {}
  for i, f in ipairs(part.fields) do
    local choices = "null"
    if f.choices then
      local list = {}
      for k, c in ipairs(choices_of(part, f)) do list[k] = to_json(c, { "value", "label" }) end
      choices = json_list(list)
    end
    out_fields[i] = '{"name":' .. to_json(f.name) .. ',"address":' .. to_json(f.address) .. ',"choices":' .. choices .. "}"
  end
  -- For the game's names, like `xp.multiplier`
  local out_names = {}
  for i, name in ipairs(part.own) do
    out_names[i] = to_json({ name = name, address = part.where[name], type = part.data_types[name] or "" }, { "name", "address", "type" })
  end
  return '{"fields":' .. json_list(out_fields) .. ',"names":' .. json_list(out_names) .. "}"
end

-- Before what it made goes. `name` is a group's tweak, or empty for the rest
function __t.stop(name)
  local part = parts[name or ""]
  if not part then return end
  local off = rawget(part.env, "off")
  local ok, e = true, nil
  if type(off) == "function" then ok, e = pcall(off) end
  for i = #part.uses, 1, -1 do
    local h = part.uses[i]
    if type(h) == "table" and type(h.stop) == "function" then pcall(h.stop) end
  end
  part.uses = {}
  -- What it made, newest first
  if part.tick then pcall(part.tick.cancel, part.tick) end
  for i = #part.made, 1, -1 do
    local item = part.made[i].item
    if item then pcall(item.destroy, item) end
  end
  part.made = {}
  if part ~= shared then parts[part.name] = nil end
  if not ok then error(e, 0) end
end
