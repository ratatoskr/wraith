-- Cheat Engine's Lua API on top of Wraith's, so imported CE tables can run. See API.md.
--
--   local ce = require("ce")
--   local handle = ce.install(env, { name = "My Table", records = manifest, tweaks = bridge })
--
-- Call `install` once per engine, before the table's code.

local M = { name = "ce", version = 1 }

local unpack = table.unpack
local floor = math.floor
local fmt = string.format

-- A hidden key, for an object's own state
local STATE = {}

local function fail(name, why, level)
  local text = "CE " .. name .. " isn't supported in Wraith yet"
  if why then text = text .. ": " .. why end
  error(text, (level or 1) + 1)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Whole numbers like CE takes them, from numbers, numeric text or floats cut toward zero
local function toint(v, what)
  local n = v
  if type(n) == "string" then n = tonumber(n) end
  if type(n) ~= "number" then
    error((what or "value") .. ": expected a number, got " .. type(v), 3)
  end
  local i = math.tointeger(n)
  if i then return i end
  if n ~= n or n == math.huge or n == -math.huge then error((what or "value") .. ": not a finite number", 3) end
  n = n >= 0 and floor(n) or -floor(-n)
  return math.tointeger(n) or error((what or "value") .. ": too big for 64 bits", 3)
end

---------------------------------------------------------------------------------------------------
-- Objects. Take both `obj.method(x)` and `obj:method(x)`; property names ignore case, like CE.

local function bind(obj, f)
  return function(first, ...)
    if first == obj then return f(obj, ...) end
    return f(obj, first, ...)
  end
end

-- Something you index like `rec.Child[0]`
local function indexed(get, set)
  return setmetatable({}, {
    __index = function(_, i) return get(i) end,
    __newindex = function(_, i, v)
      if not set then error("it's read-only", 2) end
      set(i, v)
    end,
  })
end

local Object = {
  props = {
    classname = { get = function(o) return getmetatable(o).class.name end },
    name = { get = function(o) return o[STATE].name or "" end, set = function(o, v) o[STATE].name = v end },
    tag = { get = function(o) return o[STATE].tag or 0 end, set = function(o, v) o[STATE].tag = v end },
    owner = { get = function(o) return o[STATE].owner end },
  },
  methods = {
    getclassname = function(o) return getmetatable(o).class.name end,
    destroy = function(o)
      local st = o[STATE]
      if st.destroyed then return end
      st.destroyed = true
      local on = getmetatable(o).class.on_destroy
      if on then on(o) end
    end,
  },
}

local function class(name, def)
  local c = { name = name, props = {}, methods = {}, unsupported = {}, on_destroy = def.on_destroy, index = def.index, setindex = def.setindex }
  for _, from in ipairs({ Object, def.base or {}, def }) do
    for k, v in pairs(from.props or {}) do c.props[k:lower()] = v end
    for k, v in pairs(from.methods or {}) do c.methods[k:lower()] = v end
  end
  for _, k in ipairs(def.unsupported or {}) do c.unsupported[k:lower()] = k end
  -- What errors call it, like MemoryRecord for TMemoryRecord
  local shown = name:gsub("^T(%u)", "%1")
  c.meta = {
    class = c,
    __name = name,
    __tostring = function() return name end,
    __index = function(o, k)
      if type(k) == "number" then
        if c.index then return c.index(o, k) end
        return nil
      end
      if type(k) ~= "string" then return nil end
      local lk = k:lower()
      local p = c.props[lk]
      if p then
        if not p.get then error("CE " .. shown .. "." .. k .. " can only be set", 2) end
        return p.get(o)
      end
      local m = c.methods[lk]
      if m then return bind(o, m) end
      if c.unsupported[lk] then fail(shown .. "." .. k, nil, 2) end
      return nil
    end,
    __newindex = function(o, k, v)
      if type(k) == "number" and c.setindex then return c.setindex(o, k, v) end
      if type(k) == "string" then
        local lk = k:lower()
        local p = c.props[lk]
        if p then
          if not p.set then error("CE " .. shown .. "." .. k .. " is read-only", 2) end
          return p.set(o, v)
        end
        if c.unsupported[lk] then fail(shown .. "." .. k, nil, 2) end
      end
      rawset(o, k, v)
    end,
  }
  return c
end

local function new(c, state)
  return setmetatable({ [STATE] = state or {} }, c.meta)
end

local function is_a(v, c)
  return type(v) == "table" and getmetatable(v) == c.meta
end

---------------------------------------------------------------------------------------------------
-- CE numbers: `10` is hex and `#10` decimal, unlike Wraith. Same rules as numbers.zig.

local function is_hex(w)
  return w ~= "" and not w:find("[^%x]")
end

-- Hex digits as they were, without leading zeros, as Wraith's
local function hex_text(digits)
  local d = digits:gsub("^0+", "")
  if d == "" then d = "0" end
  if #d == 1 and d:find("%d") then return d end
  return "0x" .. d:upper()
end

-- A CE number on its own, like an offset. Hex, `#` decimal, `$` or `0x` hex, maybe signed
local function parse_number(text)
  local t = trim(text)
  local negative = false
  local sign = t:sub(1, 1)
  if sign == "-" or sign == "+" then
    negative = sign == "-"
    t = trim(t:sub(2))
  end
  if t == "" then return nil end
  local v
  if t:sub(1, 1) == "#" then
    if t:find("^#%d+$") then v = math.tointeger(tonumber(t:sub(2), 10)) end
  elseif t:sub(1, 1) == "$" then
    if is_hex(t:sub(2)) then v = math.tointeger(tonumber(t:sub(2), 16)) end
  elseif t:sub(1, 2):lower() == "0x" then
    if is_hex(t:sub(3)) then v = math.tointeger(tonumber(t:sub(3), 16)) end
  elseif is_hex(t) then
    v = math.tointeger(tonumber(t, 16))
  end
  if not v then return nil end
  return negative and -v or v
end

local function is_module_char(c)
  return c:find("[%w_%.%- ]") ~= nil
end

-- Quotes names like `Tales of X.exe`, since Wraith ends a name at spaces and dashes
local function quote_modules(text)
  local out, i, copied, n = {}, 1, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      i = (text:find(c, i + 1, true) or n) + 1
    else
      local ext = text:sub(i, i + 3):lower()
      if ext ~= ".exe" and ext ~= ".dll" then
        i = i + 1
      else
        local start = i
        while start > copied and is_module_char(text:sub(start - 1, start - 1)) do start = start - 1 end
        while start < i and text:sub(start, start):find("[ %-\t]") do start = start + 1 end
        local stop = i + 4
        while stop <= n and text:sub(stop, stop):find("[%w_%.]") do stop = stop + 1 end
        local module = text:sub(start, stop - 1)
        if module:find("[^%w_%.]") and (start == 1 or text:sub(start - 1, start - 1) ~= '"') then
          out[#out + 1] = text:sub(copied, start - 1)
          out[#out + 1] = '"' .. module .. '"'
          copied = stop
        end
        i = stop
      end
    end
  end
  if copied == 1 then return text end
  out[#out + 1] = text:sub(copied)
  return table.concat(out)
end

local function is_word_char(c)
  return c:find("[%w_%.@%$#%?!]") ~= nil
end

-- One word of location text. `swap(word)` gives what a known name becomes, or nil.
local function convert_word(word, swap)
  local first = word:sub(1, 1)
  if first == "#" then
    local digits = word:sub(2)
    if not tonumber(digits) then error("'" .. word .. "' isn't a number", 0) end
    return digits
  end
  if swap then
    local s = swap(word)
    if s then return s end
  end
  if first == "$" and is_hex(word:sub(2)) then return hex_text(word:sub(2)) end
  if word:sub(1, 2):lower() == "0x" and is_hex(word:sub(3)) then return word end
  if word:find(".", 1, true) or not is_hex(word) then return word end
  return hex_text(word)
end

-- CE location text as Wraith's, like `[[base]+10]+8` to `[[base]+0x10]+8`
function M.location(text, swap)
  text = quote_modules(trim(text)):gsub("#%-", "-#")
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      local close = text:find(c, i + 1, true) or n
      out[#out + 1] = text:sub(i, close)
      i = close + 1
    elseif not is_word_char(c) then
      out[#out + 1] = c
      i = i + 1
    else
      local s = i
      while i <= n and is_word_char(text:sub(i, i)) do i = i + 1 end
      out[#out + 1] = convert_word(text:sub(s, i - 1), swap)
    end
  end
  return table.concat(out)
end

-- CE aob text like `48 8B ** xx 05` as a Wraith pattern. Half bytes like `4?` widen to `??`.
function M.pattern(text)
  local digits = {}
  for token in text:gmatch("[^%s,]+") do
    if #token == 1 then digits[#digits + 1] = "0" end
    digits[#digits + 1] = token
  end
  local all = table.concat(digits)
  if all == "" or #all % 2 ~= 0 then error("'" .. text .. "' isn't an aob pattern", 0) end
  local out = {}
  for k = 1, #all, 2 do
    local pair = all:sub(k, k + 1)
    if pair:find("[%?%*xX]") then
      out[#out + 1] = "??"
    elseif is_hex(pair) then
      out[#out + 1] = pair:upper()
    else
      error("'" .. text .. "' isn't an aob pattern", 0)
    end
  end
  return table.concat(out, " ")
end

M.parse_number = parse_number

---------------------------------------------------------------------------------------------------
-- Bytes

local function utf16(s)
  local out = {}
  for _, c in utf8.codes(s) do
    if c >= 0x10000 then
      c = c - 0x10000
      out[#out + 1] = string.pack("<I2I2", 0xD800 | (c >> 10), 0xDC00 | (c & 0x3FF))
    else
      out[#out + 1] = string.pack("<I2", c)
    end
  end
  return table.concat(out)
end

local function from_utf16(s)
  local out, i = {}, 1
  while i + 1 <= #s do
    local c = string.unpack("<I2", s, i)
    i = i + 2
    if c >= 0xD800 and c < 0xDC00 and i + 1 <= #s then
      local lo = string.unpack("<I2", s, i)
      i = i + 2
      c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)
    end
    out[#out + 1] = utf8.char(c)
  end
  return table.concat(out)
end

local function bytes_of(s)
  local t = {}
  for i = 1, #s do t[i] = s:byte(i) end
  return t
end

-- A byte table, from `index` on, as a string
local function string_of(t, index, count)
  index = index or 1
  local last = count and (index + count - 1) or #t
  local out = {}
  for i = index, last do
    local b = t[i]
    if b == nil then break end
    out[#out + 1] = string.char(toint(b) & 0xFF)
  end
  return table.concat(out)
end

-- 80-bit x87 floats, which Lua has no format for
local function extended_bytes(n)
  n = tonumber(n)
  local sign = 0
  if n < 0 or (n == 0 and 1 / n < 0) then
    sign = 0x8000
    n = -n
  end
  local mantissa, exponent = 0, 0
  if n ~= n then
    exponent, mantissa = 0x7FFF, 0xC000000000000000
  elseif n == math.huge then
    exponent, mantissa = 0x7FFF, 0x8000000000000000
  elseif n ~= 0 then
    local m, e = math.frexp(n)
    exponent = e - 1 + 16383
    -- m is in [0.5, 1), and the top bit's the explicit integer one
    mantissa = math.tointeger(m * 2 ^ 53) << 11
  end
  return string.pack("<i8I2", mantissa, sign | exponent)
end

local function extended_value(s)
  local mantissa, top = string.unpack("<i8I2", s)
  local sign = (top & 0x8000) ~= 0 and -1 or 1
  local exponent = top & 0x7FFF
  if exponent == 0x7FFF then
    if (mantissa << 1) == 0 then return sign * math.huge end
    return 0 / 0
  end
  -- `>>` is unsigned, so the top 53 bits come out whole, which is all a double keeps
  if exponent == 0 then exponent = 1 end
  return sign * (mantissa >> 11) * 2.0 ^ (exponent - 16383 - 52)
end

---------------------------------------------------------------------------------------------------
-- Value types, as CE numbers them

local vt = {
  byte = 0, word = 1, dword = 2, qword = 3, single = 4, double = 5, string = 6, unicode = 7,
  bytes = 8, binary = 9, all = 10, script = 11, pointer = 12, custom = 13, grouped = 14,
}
local vt_names = {
  [0] = "vtByte", "vtWord", "vtDword", "vtQword", "vtSingle", "vtDouble", "vtString", "vtUnicodeString",
  "vtByteArray", "vtBinary", "vtAll", "vtAutoAssembler", "vtPointer", "vtCustom", "vtGrouped",
}
-- The names CE tables use for VariableType
local vt_of_text = {
  ["byte"] = 0, ["2 bytes"] = 1, ["4 bytes"] = 2, ["8 bytes"] = 3, ["float"] = 4, ["double"] = 5,
  ["string"] = 6, ["unicode string"] = 7, ["array of byte"] = 8, ["binary"] = 9, ["all"] = 10,
  ["auto assembler script"] = 11, ["pointer"] = 12, ["custom"] = 13, ["grouped"] = 14,
}
local vt_sizes = { [0] = 1, 2, 4, 8, 4, 8 }

local function type_code(t)
  if t == nil then return nil end
  if type(t) == "number" then return toint(t) end
  local lower = tostring(t):lower()
  if vt_of_text[lower] then return vt_of_text[lower] end
  for k, name in pairs(vt_names) do
    if name:lower() == lower then return k end
  end
  error("CE value type '" .. tostring(t) .. "' isn't one Wraith knows", 3)
end

---------------------------------------------------------------------------------------------------

-- Windows' virtual key codes, as Wraith names keys and mouse buttons
local VK = {
  [0x01] = "mouse_left", [0x02] = "mouse_right", [0x04] = "mouse_middle", [0x05] = "mouse_x1", [0x06] = "mouse_x2",
  [0x08] = "backspace", [0x09] = "tab", [0x0D] = "enter", [0x10] = "shift", [0x11] = "ctrl", [0x12] = "alt",
  [0x13] = "pause", [0x14] = "caps_lock", [0x1B] = "escape", [0x20] = "space", [0x21] = "page_up",
  [0x22] = "page_down", [0x23] = "end", [0x24] = "home", [0x25] = "left", [0x26] = "up", [0x27] = "right",
  [0x28] = "down", [0x2C] = "print_screen", [0x2D] = "insert", [0x2E] = "delete", [0x5B] = "left_super",
  [0x5C] = "right_super", [0x5D] = "menu", [0x6A] = "keypad_multiply", [0x6B] = "keypad_add",
  [0x6D] = "keypad_subtract", [0x6E] = "keypad_decimal", [0x6F] = "keypad_divide", [0x90] = "num_lock",
  [0x91] = "scroll_lock", [0xA0] = "left_shift", [0xA1] = "right_shift", [0xA2] = "left_ctrl",
  [0xA3] = "right_ctrl", [0xA4] = "left_alt", [0xA5] = "right_alt", [0xBA] = "semicolon", [0xBB] = "equal",
  [0xBC] = "comma", [0xBD] = "minus", [0xBE] = "period", [0xBF] = "slash", [0xC0] = "grave",
  [0xDB] = "left_bracket", [0xDC] = "backslash", [0xDD] = "right_bracket", [0xDE] = "apostrophe",
}
for i = 0, 9 do
  VK[0x30 + i] = "digit_" .. i
  VK[0x60 + i] = "keypad_" .. i
end
for i = 0, 25 do VK[0x41 + i] = string.char(0x61 + i) end
for i = 1, 24 do VK[0x6F + i] = "f" .. i end
M.keys = VK

-- Wraith's areas as fields, like `w.memory`, from the `Wraith` global's accessors. Missing ones are nil
function M.areas(root)
  return setmetatable({}, { __index = function(t, k)
    local ok, area = pcall(function() return root[k]() end)
    if not ok then return nil end
    rawset(t, k, area)
    return area
  end })
end

-- Puts CE's globals in `env`. Gives a handle for whoever runs the table, see API.md.
function M.install(env, options)
  options = options or {}
  local w = options.wraith or M.areas(Wraith)
  local memory, log, threads = w.memory, w.log, w.threads

  -- Memory's bytes as a string, like CE's tables work with
  local function bytes_at(a, count)
    return memory:readBytes(a, count):string()
  end
  local table_name = options.name or "Cheat Engine table"
  local bridge = options.tweaks
  local handle = { env = env }

  -- What raising stubs and setup calls we can't do say, once each
  local warned = {}
  local function warn_once(key, text)
    if warned[key] then return end
    warned[key] = true
    log:warn(text)
  end

  local installed = {}
  local function def(name, f)
    env[name] = f
    installed[#installed + 1] = name
  end

  ---------------------------------------------------------------------------------------------
  -- Addresses and symbols

  -- Lowercase name to { name, address }
  local symbols = {}
  local symbol_order = {}
  local lookup_errors = true
  local publish = options.publish ~= false and w.addresses ~= nil

  local function unwrap(a)
    if type(a) == "number" then return math.tointeger(a) end
    local ok, good = pcall(function() return a:ok() end)
    if ok and not good then return nil, a:error() end
    local ok2, v = pcall(function() return a:unwrap() end)
    if ok2 then return v end
    return nil, v
  end

  -- Registered symbols become addresses, names Wraith knows stay names, anything else is hex
  local function swap(word)
    local s = symbols[word:lower()]
    if s then return fmt("0x%X", s.address) end
    if #word >= 3 and word:find("^%a+$") and is_hex(word) then
      local ok, a = pcall(w.addresses.resolve, w.addresses, "(" .. word .. ")", {})
      if ok and unwrap(a) then return "(" .. word .. ")" end
    end
    return nil
  end

  -- An integer address, or nil and why
  local function lookup(x)
    local kind = type(x)
    if kind == "number" then
      local i = math.tointeger(x)
      if not i then return nil, "not a whole number" end
      return i
    end
    if kind == "string" then
      local text = trim(x)
      if text == "" then return nil, "it's empty" end
      local s = symbols[text:lower()]
      if s then return s.address end
      local n = parse_number(text)
      if n then return n end
      local ok, location = pcall(M.location, text, swap)
      if not ok then return nil, location end
      local ok2, a = pcall(w.addresses.resolve, w.addresses, location, {})
      if not ok2 then return nil, tostring(a) end
      return unwrap(a)
    end
    if kind == "userdata" or kind == "table" then
      local v, why = unwrap(x)
      if v then return v end
      return nil, why or ("expected an address, got " .. kind)
    end
    return nil, "expected an address, got " .. kind
  end

  local function get_address(x)
    local a, why = lookup(x)
    if a then return a end
    if not lookup_errors then return 0 end
    error("CE getAddress couldn't find '" .. tostring(x) .. "': " .. tostring(why), 2)
  end

  def("getAddress", function(x) return get_address(x) end)
  def("getAddressSafe", function(x) return (lookup(x)) end)
  def("errorOnLookupFailure", function(state)
    local was = lookup_errors
    lookup_errors = state and true or false
    return was
  end)

  def("registerSymbol", function(name, address, _donotsave)
    if type(name) ~= "string" or name == "" then error("CE registerSymbol: expected a name", 2) end
    local a = get_address(address)
    local lower = name:lower()
    if not symbols[lower] then symbol_order[#symbol_order + 1] = lower end
    symbols[lower] = { name = name, address = a }
    if publish then
      pcall(w.addresses.remove, w.addresses, name)
      pcall(w.addresses.add, w.addresses, { id = name, address = fmt("0x%X", a) })
    end
  end)
  def("unregisterSymbol", function(name)
    if type(name) ~= "string" then return end
    local lower = name:lower()
    if not symbols[lower] then return end
    symbols[lower] = nil
    for i, n in ipairs(symbol_order) do
      if n == lower then
        table.remove(symbol_order, i)
        break
      end
    end
    if publish then pcall(w.addresses.remove, w.addresses, name) end
  end)
  def("enumRegisteredSymbols", function()
    local out = {}
    for _, lower in ipairs(symbol_order) do
      local s = symbols[lower]
      out[#out + 1] = { symbolname = s.name, address = s.address }
    end
    return out
  end)
  def("deleteAllRegisteredSymbols", function()
    for _, lower in ipairs(symbol_order) do
      if publish then pcall(w.addresses.remove, w.addresses, symbols[lower].name) end
      symbols[lower] = nil
    end
    symbol_order = {}
  end)

  local function module_at(a)
    local ok, m = pcall(memory.containing, memory, a)
    if ok and m then return m end
    return nil
  end

  local function module_named(name)
    if type(name) ~= "string" then return nil end
    local ok, m = pcall(memory.module, memory, name)
    if ok and m then return m end
    local main = memory:main()
    if main.name:lower() == name:lower() then return main end
    return nil
  end

  def("getNameFromAddress", function(x, module_names, use_symbols)
    local a = lookup(x)
    if not a then return tostring(x) end
    if use_symbols ~= false then
      for _, lower in ipairs(symbol_order) do
        if symbols[lower].address == a then return symbols[lower].name end
      end
    end
    if module_names ~= false then
      local m = module_at(a)
      if m then
        local base = unwrap(m.base)
        if a == base then return m.name end
        return fmt("%s+%X", m.name, a - base)
      end
    end
    return fmt("%08X", a)
  end)
  def("inModule", function(x)
    local a = lookup(x)
    return a ~= nil and module_at(a) ~= nil
  end)
  -- Wraith only gives a module's name, so this checks it against Windows' usual ones
  local system_modules = {
    ["ntdll.dll"] = true, ["kernel32.dll"] = true, ["kernelbase.dll"] = true, ["user32.dll"] = true,
    ["gdi32.dll"] = true, ["win32u.dll"] = true, ["advapi32.dll"] = true, ["msvcrt.dll"] = true,
    ["ucrtbase.dll"] = true, ["combase.dll"] = true, ["ole32.dll"] = true, ["shell32.dll"] = true,
    ["ws2_32.dll"] = true, ["rpcrt4.dll"] = true, ["sechost.dll"] = true, ["d3d11.dll"] = true,
    ["d3d12.dll"] = true, ["dxgi.dll"] = true, ["opengl32.dll"] = true, ["vulkan-1.dll"] = true,
  }
  def("inSystemModule", function(x)
    local a = lookup(x)
    local m = a and module_at(a)
    return m ~= nil and system_modules[m.name:lower()] == true
  end)
  def("getModuleSize", function(name)
    local m = module_named(name)
    if not m then return nil end
    return m.size
  end)
  def("getSymbolInfo", function(name)
    if type(name) ~= "string" then return nil end
    local s = symbols[name:lower()]
    if s then return { modulename = "", searchkey = s.name, address = s.address, size = 0 } end
    local m = module_named(name)
    if m then return { modulename = m.name, searchkey = m.name, address = unwrap(m.base), size = m.size } end
    return nil
  end)

  local target64 = string.packsize("T") == 8
  def("targetIs64Bit", function() return target64 end)
  def("cheatEngineIs64Bit", function() return target64 end)
  def("targetIsX86", function() return true end)
  def("targetIsArm", function() return false end)
  def("targetIsAndroid", function() return false end)
  def("targetIsRosetta", function() return false end)
  def("getABI", function() return 0 end)
  def("getPointerSize", function() return target64 and 8 or 4 end)
  -- Symbols are always ready in Wraith, so the waits and reloads have nothing to do
  for _, name in ipairs({
    "reinitializeSymbolhandler", "reinitializeDotNetSymbolhandler", "reinitializeSelfSymbolhandler",
    "waitForSections", "waitForExports", "waitForDotNet", "waitForPDB", "searchPDBWhileLoading",
    "waitforsymbols", "enableWindowsSymbols", "enableKernelSymbols",
  }) do
    def(name, function() end)
  end

  ---------------------------------------------------------------------------------------------
  -- Memory. Reads give nil when they can't, and writes give false, like CE's.

  local function readable(x)
    return (lookup(x))
  end

  -- `f` is one of memory's methods, like memory.readU8, so it takes memory first
  local function reader(f)
    return function(x)
      local a = readable(x)
      if not a then return nil end
      local ok, v = pcall(f, memory, a)
      if ok then return v end
      return nil
    end
  end

  local function signed_reader(unsigned, signed)
    return function(x, is_signed)
      local a = readable(x)
      if not a then return nil end
      local ok, v = pcall(is_signed and signed or unsigned, memory, a)
      if ok then return v end
      return nil
    end
  end

  local function writer(f, mask)
    return function(x, value)
      local a = readable(x)
      if not a then return false end
      local ok, v = pcall(toint, value)
      if not ok then return false end
      if mask then v = v & mask end
      return (pcall(f, memory, a, v))
    end
  end

  local function float_writer(f)
    return function(x, value)
      local a = readable(x)
      local n = tonumber(value)
      if not a or not n then return false end
      return (pcall(f, memory, a, n))
    end
  end

  local function read_bytes(x, count, as_table)
    local a = readable(x)
    if not a then return nil end
    count = count and toint(count, "bytecount") or 1
    if count <= 0 then return as_table and {} or nil end
    local ok, s = pcall(bytes_at, a, count)
    if not ok then return nil end
    local t = bytes_of(s)
    if as_table then return t end
    return unpack(t)
  end

  local function write_bytes(x, first, ...)
    local a = readable(x)
    if not a then return false end
    local list
    if type(first) == "table" then
      list = {}
      local count = select(1, ...)
      local n = count and toint(count) or #first
      for i = 1, n do list[i] = toint(first[i] or 0) & 0xFF end
    else
      list = { first, ... }
      for i = 1, #list do list[i] = toint(list[i]) & 0xFF end
    end
    if #list == 0 then return true end
    return (pcall(memory.writeBytes, memory, a, list))
  end

  local function read_string(x, max, wide)
    local a = readable(x)
    if not a then return nil end
    max = max and toint(max, "maxlength") or 6000
    local ok, s = pcall(wide and memory.readUtf16 or memory.readString, memory, a, max)
    if ok then return s end
    return nil
  end

  -- No 0 after it, same as CE
  local function write_string(x, text, wide)
    local a = readable(x)
    if not a then return false end
    text = tostring(text)
    if wide then text = utf16(text) end
    if text == "" then return true end
    return (pcall(memory.writeBytes, memory, a, text))
  end

  local family = {
    readBytes = read_bytes,
    writeBytes = write_bytes,
    readShortInteger = reader(memory.readU8),
    readByte = reader(memory.readU8),
    readSmallInteger = signed_reader(memory.readU16, memory.readI16),
    readInteger = signed_reader(memory.readU32, memory.readI32),
    readQword = reader(memory.readI64),
    readPointer = reader(memory.readPointer),
    readFloat = reader(memory.readF32),
    readDouble = reader(memory.readF64),
    readString = read_string,
    writeShortInteger = writer(memory.writeU8, 0xFF),
    writeByte = writer(memory.writeU8, 0xFF),
    writeSmallInteger = writer(memory.writeU16, 0xFFFF),
    writeInteger = writer(memory.writeU32, 0xFFFFFFFF),
    writeQword = writer(memory.writeI64),
    writePointer = target64 and writer(memory.writeI64) or writer(memory.writeU32, 0xFFFFFFFF),
    writeFloat = float_writer(memory.writeF32),
    writeDouble = float_writer(memory.writeF64),
    writeString = write_string,
  }
  for name, f in pairs(family) do
    def(name, f)
    -- Wraith runs in the game, so CE's own memory is the game's
    def(name .. "Local", f)
  end

  def("copyMemory", function(source, size, dest, _method)
    local from = get_address(source)
    size = toint(size, "size")
    local to = dest and get_address(dest) or unwrap(w.code:alloc(size))
    local ok, s = pcall(bytes_at, from, size)
    if not ok then return nil end
    if not pcall(memory.writeBytes, memory, to, s) then return nil end
    return to
  end)
  def("compareMemory", function(a1, a2, size, _method)
    size = toint(size, "size")
    local ok1, s1 = pcall(bytes_at, get_address(a1), size)
    local ok2, s2 = pcall(bytes_at, get_address(a2), size)
    if not (ok1 and ok2) then return false, 0 end
    if s1 == s2 then return true end
    for i = 1, size do
      if s1:byte(i) ~= s2:byte(i) then return false, i - 1 end
    end
    return true
  end)
  def("allocateMemory", function(size, base, _protection)
    local near = base and get_address(base) or nil
    return unwrap(w.code:alloc(toint(size, "size"), near))
  end)
  def("deAlloc", function(address)
    w.code:free(get_address(address))
  end)

  -- Windows' page protection numbers, which CE gives and takes
  local PAGE = { no_access = 0x01, read = 0x02, read_write = 0x04, read_execute = 0x20, read_write_execute = 0x40 }
  local function protection_of(r, x, wr)
    if x and wr then return "read_write_execute" end
    if x then return "read_execute" end
    if wr then return "read_write" end
    if r then return "read" end
    return "no_access"
  end
  def("fullAccess", function(address, size)
    memory:protect(get_address(address), toint(size, "size"), "read_write_execute")
  end)
  def("setMemoryProtection", function(address, size, flags)
    flags = flags or {}
    local function flag(k) return flags[k] or flags[k:lower()] end
    memory:protect(get_address(address), toint(size, "size"), protection_of(flag("R"), flag("X"), flag("W")))
  end)
  def("enumMemoryRegions", function()
    local out = {}
    for i, r in ipairs(memory:regions("", true)) do
      local start = unwrap(r.start)
      local protect = PAGE[protection_of(r.readable, r.executable, r.writable)]
      out[i] = {
        BaseAddress = start,
        AllocationBase = start,
        AllocationProtect = protect,
        RegionSize = r.length,
        State = 0x1000,
        Protect = protect,
        Type = r.module and 0x1000000 or 0x20000,
      }
    end
    return out
  end)

  ---------------------------------------------------------------------------------------------
  -- Byte tables and bits

  local function packer(format, mask)
    return function(v)
      v = toint(v)
      if mask then v = v & mask end
      return bytes_of(string.pack(format, v))
    end
  end
  def("wordToByteTable", packer("<I2", 0xFFFF))
  def("dwordToByteTable", packer("<I4", 0xFFFFFFFF))
  def("qwordToByteTable", packer("<i8"))
  def("floatToByteTable", function(v) return bytes_of(string.pack("<f", tonumber(v))) end)
  def("doubleToByteTable", function(v) return bytes_of(string.pack("<d", tonumber(v))) end)
  def("extendedToByteTable", function(v) return bytes_of(extended_bytes(v)) end)
  def("stringToByteTable", function(s) return bytes_of(tostring(s)) end)
  def("wideStringToByteTable", function(s) return bytes_of(utf16(tostring(s))) end)

  def("byteTableToWord", function(t, signed, index)
    return (string.unpack(signed and "<i2" or "<I2", string_of(t, index, 2) .. "\0\0"))
  end)
  def("byteTableToDword", function(t, signed, index)
    return (string.unpack(signed and "<i4" or "<I4", string_of(t, index, 4) .. "\0\0\0\0"))
  end)
  def("byteTableToQword", function(t, index)
    return (string.unpack("<i8", string_of(t, index, 8) .. string.rep("\0", 8)))
  end)
  def("byteTableToFloat", function(t, index)
    return (string.unpack("<f", string_of(t, index, 4) .. "\0\0\0\0"))
  end)
  def("byteTableToDouble", function(t, index)
    return (string.unpack("<d", string_of(t, index, 8) .. string.rep("\0", 8)))
  end)
  def("byteTableToExtended", function(t, index)
    return extended_value(string_of(t, index, 10) .. string.rep("\0", 10))
  end)
  def("byteTableToString", function(t, index) return string_of(t, index) end)
  def("byteTableToWideString", function(t, index) return from_utf16(string_of(t, index)) end)

  def("bOr", function(a, b) return toint(a) | toint(b) end)
  def("bXor", function(a, b) return toint(a) ~ toint(b) end)
  def("bAnd", function(a, b) return toint(a) & toint(b) end)
  def("bShl", function(a, b) return toint(a) << toint(b) end)
  def("bShr", function(a, b) return toint(a) >> toint(b) end)
  def("bNot", function(a) return ~toint(a) end)
  def("signExtend", function(value, msb)
    value, msb = toint(value), toint(msb)
    if value & (1 << msb) ~= 0 then return value | (-1 << msb) end
    return value & ((1 << (msb + 1)) - 1)
  end)

  ---------------------------------------------------------------------------------------------
  -- Stringlists

  local Strings
  local function new_strings(lines)
    return new(Strings, { lines = lines or {}, data = {}, sorted = false, case = false, duplicates = 1 })
  end

  local function split_lines(text)
    local out = {}
    text = tostring(text)
    if text == "" then return out end
    for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
    return out
  end

  local function strings_add(o, s, data)
    local st = o[STATE]
    s = tostring(s)
    if st.sorted then
      local pos = #st.lines + 1
      for i, v in ipairs(st.lines) do
        local a, b = s, v
        if not st.case then a, b = a:lower(), b:lower() end
        if a == b and st.duplicates == 0 then return i - 1 end
        if a < b then
          pos = i
          break
        end
      end
      table.insert(st.lines, pos, s)
      table.insert(st.data, pos, data or 0)
      return pos - 1
    end
    st.lines[#st.lines + 1] = s
    st.data[#st.lines] = data or 0
    return #st.lines - 1
  end

  local function strings_at(o, i)
    local st = o[STATE]
    i = toint(i, "index")
    if i < 0 or i >= #st.lines then error("CE Strings: index " .. i .. " is out of bounds", 3) end
    return i + 1
  end

  local function strings_index_of(o, s)
    local st = o[STATE]
    s = tostring(s)
    for i, v in ipairs(st.lines) do
      if v == s or (not st.case and v:lower() == s:lower()) then return i - 1 end
    end
    return -1
  end

  Strings = class("TStringList", {
    props = {
      text = {
        get = function(o)
          local lines = o[STATE].lines
          if #lines == 0 then return "" end
          return table.concat(lines, "\r\n") .. "\r\n"
        end,
        set = function(o, v)
          o[STATE].lines = split_lines(v)
          o[STATE].data = {}
        end,
      },
      count = { get = function(o) return #o[STATE].lines end },
      linebreak = { get = function() return "\r\n" end, set = function() end },
      string = {
        get = function(o)
          return indexed(function(i) return o[STATE].lines[strings_at(o, i)] end,
            function(i, v) o[STATE].lines[strings_at(o, i)] = tostring(v) end)
        end,
      },
      data = {
        get = function(o)
          return indexed(function(i) return o[STATE].data[strings_at(o, i)] or 0 end,
            function(i, v) o[STATE].data[strings_at(o, i)] = v end)
        end,
      },
      sorted = {
        get = function(o) return o[STATE].sorted end,
        set = function(o, v)
          local st = o[STATE]
          st.sorted = v and true or false
          if st.sorted then
            table.sort(st.lines, function(a, b)
              if st.case then return a < b end
              return a:lower() < b:lower()
            end)
          end
        end,
      },
      casesensitive = { get = function(o) return o[STATE].case end, set = function(o, v) o[STATE].case = v and true or false end },
      duplicates = { get = function(o) return o[STATE].duplicates end, set = function(o, v) o[STATE].duplicates = v end },
    },
    methods = {
      clear = function(o)
        o[STATE].lines = {}
        o[STATE].data = {}
      end,
      add = strings_add,
      addtext = function(o, text)
        for _, line in ipairs(split_lines(text)) do strings_add(o, line) end
      end,
      delete = function(o, i)
        local k = strings_at(o, i)
        table.remove(o[STATE].lines, k)
        table.remove(o[STATE].data, k)
      end,
      remove = function(o, s)
        local i = strings_index_of(o, s)
        if i >= 0 then
          table.remove(o[STATE].lines, i + 1)
          table.remove(o[STATE].data, i + 1)
        end
      end,
      gettext = function(o) return o.Text end,
      settext = function(o, v) o.Text = v end,
      indexof = strings_index_of,
      insert = function(o, i, s)
        i = toint(i, "index")
        table.insert(o[STATE].lines, i + 1, tostring(s))
        table.insert(o[STATE].data, i + 1, 0)
      end,
      getcount = function(o) return #o[STATE].lines end,
      getstring = function(o, i) return o[STATE].lines[strings_at(o, i)] end,
      setstring = function(o, i, s) o[STATE].lines[strings_at(o, i)] = tostring(s) end,
      getdata = function(o, i) return o[STATE].data[strings_at(o, i)] or 0 end,
      setdata = function(o, i, v) o[STATE].data[strings_at(o, i)] = v end,
      beginupdate = function() end,
      endupdate = function() end,
      assign = function(o, other)
        local st = other[STATE]
        o[STATE].lines = { unpack(st.lines) }
        o[STATE].data = { unpack(st.data) }
      end,
      getsorted = function(o) return o.Sorted end,
      setsorted = function(o, v) o.Sorted = v end,
      getcasesensitive = function(o) return o[STATE].case end,
      setcasesensitive = function(o, v) o[STATE].case = v and true or false end,
      getduplicates = function(o) return o[STATE].duplicates end,
      setduplicates = function(o, v) o[STATE].duplicates = v end,
    },
    unsupported = { "loadFromFile", "saveToFile" },
    index = function(o, i) return o[STATE].lines[strings_at(o, i)] end,
    setindex = function(o, i, v) o[STATE].lines[strings_at(o, i)] = tostring(v) end,
  })
  def("createStringlist", function() return new_strings() end)
  def("createStringList", function() return new_strings() end)

  -- CE adds these to Lua's string table, and so the strings' methods
  if string.split == nil then
    string.split = function(s, sep)
      local out = {}
      sep = sep or ","
      local start = 1
      while true do
        local i, j = s:find(sep, start, true)
        if not i or sep == "" then
          out[#out + 1] = s:sub(start)
          break
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = j + 1
      end
      return out
    end
  end
  if string.startsWith == nil then
    string.startsWith = function(s, prefix) return s:sub(1, #prefix) == prefix end
  end
  if string.endsWith == nil then
    string.endsWith = function(s, suffix) return suffix == "" or s:sub(-#suffix) == suffix end
  end
  -- Lua 5.1 leftovers CE tables still use
  if env.unpack == nil then def("unpack", unpack) end

  def("extractFileName", function(p) return (tostring(p):match("[^\\/]*$")) end)
  def("extractFileExt", function(p) return (tostring(p):match("[^\\/]*$"):match("%.[^.]*$") or "") end)
  def("extractFileNameWithoutExt", function(p)
    local name = tostring(p):match("[^\\/]*$")
    return (name:gsub("%.[^.]*$", ""))
  end)
  def("extractFilePath", function(p) return (tostring(p):match("^(.*[\\/])") or "") end)
  def("translate", function(s) return s end)
  def("translateID", function(_id, s) return s end)
  def("getTranslationFolder", function() return "" end)
  -- Wraith's strings are UTF-8 already
  def("ansiToUTF8", function(s) return s end)
  def("UTF8ToAnsi", function(s) return s end)

  ---------------------------------------------------------------------------------------------
  -- Messages

  local function joined(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    return table.concat(parts, " ")
  end

  local function toast(kind, title, text)
    pcall(w.ui.toast, w.ui, { style = kind, title = title, text = text })
  end

  def("print", function(...) log:info(joined(...)) end)
  def("printf", function(f, ...) log:info(fmt(f, ...)) end)
  def("outputDebugString", function(s) log:debug(tostring(s)) end)
  def("showMessage", function(text)
    text = tostring(text)
    log:info(text)
    toast("info", table_name, text)
  end)

  local kinds = { [0] = "warning", [1] = "failure", [2] = "info", [3] = "info" }
  -- A toast can't ask, so it answers the safest way the dialog offers
  def("messageDialog", function(a, b, ...)
    local title, text, kind, rest
    if type(b) == "string" then
      title, text, kind, rest = a, b, ..., { select(2, ...) }
    else
      title, text, kind, rest = table_name, a, b, { ... }
    end
    text = tostring(text)
    log:info(text)
    toast(kinds[kind or 2] or "info", tostring(title), text)
    local offered = {}
    for _, button in ipairs(rest) do
      if type(button) == "table" then
        for _, x in ipairs(button) do offered[x] = true end
      else
        offered[button] = true
      end
    end
    if next(offered) == nil then return 1 end
    if offered[3] then return 2 end -- mbCancel to mrCancel
    if offered[1] then return 7 end -- mbNo to mrNo
    if offered[2] then return 1 end -- mbOK to mrOK
    if offered[4] then return 3 end -- mbAbort to mrAbort
    if offered[6] then return 5 end -- mbIgnore to mrIgnore
    return 0
  end)
  def("inputQuery", function(caption)
    warn_once("inputQuery", "CE inputQuery can't ask in Wraith yet, so '" .. tostring(caption) .. "' acts as if cancelled")
    return nil
  end)
  def("showSelectionList", function(title)
    warn_once("showSelectionList", "CE showSelectionList can't ask in Wraith yet, so '" .. tostring(title) .. "' acts as if cancelled")
    return -1, ""
  end)

  ---------------------------------------------------------------------------------------------
  -- Timers and threads. Everything here runs on the game's frame, so there's just one thread.

  local timers = {}
  local Timer

  -- Due callbacks by id, checked each frame from one frame callback
  local due, next_due, ticking = {}, 1, nil
  local function tick()
    local now = threads:now()
    local ids = {}
    for id, d in pairs(due) do
      if now >= d.at then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local d = due[id]
      if d then
        if d.every then d.at = now + d.every else due[id] = nil end
        task.spawn(d.f)
      end
    end
  end
  -- Runs `f` in a task after `ms`, then every `ms` if `every`
  local function later(f, ms, every)
    ticking = ticking or threads:onDraw(tick)
    local id = next_due
    next_due = id + 1
    due[id] = { f = f, at = threads:now() + ms, every = every and ms or nil }
    return id
  end

  local function stop_timer(st)
    if st.id then
      due[st.id] = nil
      st.id = nil
    end
  end

  local function arm(t)
    local st = t[STATE]
    stop_timer(st)
    if st.destroyed or not st.enabled or not st.on_timer then return end
    st.id = later(function()
      local f = st.on_timer
      if type(f) == "string" then f = env[f] end
      if not f then return end
      local ok, err = pcall(f, t)
      if not ok then log:err(table_name .. ": timer: " .. tostring(err)) end
    end, math.max(st.interval, 1), true)
  end

  Timer = class("TTimer", {
    props = {
      interval = {
        get = function(o) return o[STATE].interval end,
        set = function(o, v)
          o[STATE].interval = toint(v, "Interval")
          arm(o)
        end,
      },
      enabled = {
        get = function(o) return o[STATE].enabled end,
        set = function(o, v)
          o[STATE].enabled = v and true or false
          arm(o)
        end,
      },
      ontimer = {
        get = function(o) return o[STATE].on_timer end,
        set = function(o, f)
          o[STATE].on_timer = f
          arm(o)
        end,
      },
    },
    methods = {
      getinterval = function(o) return o.Interval end,
      setinterval = function(o, v) o.Interval = v end,
      getenabled = function(o) return o.Enabled end,
      setenabled = function(o, v) o.Enabled = v end,
      getontimer = function(o) return o.OnTimer end,
      setontimer = function(o, f) o.OnTimer = f end,
    },
    on_destroy = function(o)
      stop_timer(o[STATE])
      timers[o] = nil
    end,
  })

  local function new_timer(owner, enabled)
    local t = new(Timer, { interval = 1000, enabled = enabled ~= false, owner = owner })
    timers[t] = true
    return t
  end

  def("createTimer", function(a, b, ...)
    if type(a) == "number" and type(b) == "function" then
      -- Runs once after `a` ms, then it's gone
      local t = new_timer(nil, true)
      local args = table.pack(...)
      t[STATE].interval = a
      t[STATE].on_timer = function(self)
        self.destroy()
        b(unpack(args, 1, args.n))
      end
      arm(t)
      return t
    end
    return new_timer(a, b)
  end)
  -- CE's own timers, which don't exist here, so changing them does nothing
  local fake_freeze, fake_update
  def("getFreezeTimer", function()
    fake_freeze = fake_freeze or new(Timer, { interval = 100, enabled = true })
    return fake_freeze
  end)
  def("getUpdateTimer", function()
    fake_update = fake_update or new(Timer, { interval = 500, enabled = true })
    return fake_update
  end)

  local function sleep(ms)
    ms = tonumber(ms) or 0
    if not coroutine.isyieldable() then
      error("CE sleep only works in a thread, timer or the table's main script in Wraith, since it can't stop the game", 2)
    end
    local until_ms = threads:now() + ms
    repeat threads:nextDraw():await() until threads:now() >= until_ms
  end
  def("sleep", sleep)
  def("getTickCount", function() return floor(threads:now()) end)
  -- Wraith's game speed, which keeps Wraith and its scripts on real time like CE's does
  def("speedhack_setSpeed", function(speed) w.game:setSpeed(tonumber(speed) or 1) end)
  def("speedhack_getSpeed", function() return w.game:speed() end)
  def("inMainThread", function() return true end)
  def("synchronize", function(f, ...) return f(...) end)
  def("queue", function(f, ...)
    local args = table.pack(...)
    later(function() f(unpack(args, 1, args.n)) end, 0)
  end)
  def("checkSynchronize", function() end)
  def("processMessages", function() end)

  local Thread = class("TThread", {
    props = {
      finished = { get = function(o) return o[STATE].finished end },
      terminated = { get = function(o) return o[STATE].terminated end },
      result = { get = function(o) return o[STATE].result end },
    },
    methods = {
      terminate = function(o) o[STATE].terminated = true end,
      freeonterminate = function() end,
      synchronize = function(o, f, ...) return f(o, ...) end,
      queue = function(o, f, ...)
        local args = table.pack(...)
        later(function() f(o, unpack(args, 1, args.n)) end, 0)
      end,
      waitfor = function(o)
        if o[STATE].finished then return end
        if not coroutine.isyieldable() then
          error("CE Thread.waitfor only works in a thread, timer or the table's main script in Wraith", 2)
        end
        repeat threads:nextDraw():await() until o[STATE].finished
      end,
      resume = function(o)
        local st = o[STATE]
        if st.started then return end
        st.started = true
        task.spawn(function()
          local ok, r = pcall(st.f, o, unpack(st.args, 1, st.args.n))
          st.finished = true
          if ok then
            st.result = r ~= nil and tostring(r) or nil
          else
            log:err(table_name .. ": thread " .. (st.name or "") .. ": " .. tostring(r))
          end
        end)
      end,
    },
    unsupported = { "suspend" },
  })
  local function new_thread(f, suspended, ...)
    if type(f) ~= "function" then error("CE createThread: expected a function", 3) end
    local t = new(Thread, { f = f, args = table.pack(...), finished = false, terminated = false })
    if not suspended then t.resume() end
    return t
  end
  def("createThread", function(f, ...) return new_thread(f, false, ...) end)
  def("createThreadSuspended", function(f, ...) return new_thread(f, true, ...) end)
  -- One thread, so there's nothing to lock
  local CriticalSection = class("TCriticalSection", {
    methods = {
      enter = function() end,
      leave = function() end,
      tryenter = function() return true end,
    },
  })
  def("createCriticalSection", function() return new(CriticalSection) end)

  ---------------------------------------------------------------------------------------------
  -- Scanning. Wraith scans modules, so these do too, the game's own unless told which.

  local function scan_text(first, ...)
    if type(first) == "number" then
      local parts = {}
      for i, b in ipairs({ first, ... }) do
        local n = math.tointeger(b)
        parts[i] = (n and n >= 0 and n <= 255) and fmt("%02X", n) or "??"
      end
      return table.concat(parts, " "), {}
    end
    return M.pattern(tostring(first)), { ... }
  end

  -- Keeps what fits CE's alignment settings
  local function aligned(list, kind, param)
    kind = kind and toint(kind) or 0
    if kind == 0 or param == nil or param == "" then return list end
    local p = toint(tonumber(param, 16) or 0)
    local out = {}
    for _, a in ipairs(list) do
      local keep
      if kind == 1 then
        keep = p == 0 or a % p == 0
      else
        local digits = #tostring(param)
        keep = (a & ((1 << (4 * digits)) - 1)) == p
      end
      if keep then out[#out + 1] = a end
    end
    return out
  end

  local function scan_module(m, pattern, max)
    local found = memory:findAll(m.name, pattern, max or 100000)
    local out = {}
    for i, a in ipairs(found) do out[i] = unwrap(a) end
    return out
  end

  def("AOBScan", function(...)
    local pattern, rest = scan_text(...)
    local found = aligned(scan_module(memory:main(), pattern), rest[2], rest[3])
    if #found == 0 then return nil end
    local list = new_strings()
    for _, a in ipairs(found) do list.add(fmt("%X", a)) end
    return list
  end)
  def("AOBScanUnique", function(text, _protection, kind, param)
    local found = aligned(scan_module(memory:main(), M.pattern(tostring(text))), kind, param)
    return found[1]
  end)
  def("AOBScanModuleUnique", function(module, text, _protection, kind, param)
    local m = module_named(module)
    if not m then return nil end
    return aligned(scan_module(m, M.pattern(tostring(text))), kind, param)[1]
  end)

  -- CE variable types as Wraith scan types. Bytes unsigned, the rest signed, like CE.
  local SCAN_TYPES = { [0] = "u8", "i16", "i32", "i64", "f32", "f64", "string", "utf16" }
  local function scan_value(vartype, input, hex)
    if vartype == 6 or vartype == 7 then return tostring(input) end
    local n = hex and tonumber(tostring(input), 16) or tonumber(input)
    if not n then error("CE MemScan: '" .. tostring(input) .. "' isn't a number", 4) end
    if vartype >= 4 then return n + 0.0 end
    return toint(n)
  end

  local MemScan, FoundList
  MemScan = class("TMemScan", {
    props = {
      onlyoneresult = { get = function(o) return o[STATE].one end, set = function(o, v) o[STATE].one = v end },
      result = { get = function(o) return o[STATE].found and o[STATE].found[1] end },
    },
    methods = {
      firstscan = function(o, option, vartype, _rounding, input1, _input2, start, stop, protection, align_kind, align_param, hex, _not_binary, unicode)
        local st = o[STATE]
        st.found, st.scan, st.pending = nil, nil, nil
        vartype = toint(vartype)
        if vartype == 6 and unicode then vartype = 7 end
        if vartype == 8 then
          if option ~= 1 then fail("MemScan.firstScan", "array of byte scans only look for an exact value", 2) end
          local from = start and get_address(start) or nil
          local m = from and module_at(from) or memory:main()
          if not m then fail("MemScan.firstScan", "array of byte scans only look inside a module", 2) end
          local found = aligned(scan_module(m, M.pattern(tostring(input1))), align_kind, align_param)
          local to = stop and get_address(stop)
          local out = {}
          for _, a in ipairs(found) do
            if (not from or a >= from) and (not to or a < to) then out[#out + 1] = a end
          end
          st.found = out
          return
        end
        local t = SCAN_TYPES[vartype]
        if not t then fail("MemScan.firstScan", "it scans bytes, numbers and strings", 2) end
        if option ~= 1 then fail("MemScan.firstScan", "first scans look for an exact value", 2) end
        st.type = t
        local options = { type = t, value = tostring(scan_value(vartype, input1, hex)), unaligned = toint(align_kind or 1) == 0 }
        local from = start and get_address(start) or 0
        local to = stop and get_address(stop) or 0
        -- CE's whole range is 0 to the top, which is all of memory
        if from > 0 and to > from and to < 0x7FFFFFFFFFFF then
          options.start, options.length = from, to - from
        else
          options.read_only = not (protection == nil or tostring(protection):find("+W", 1, true) ~= nil)
        end
        st.pending = memory:scan(options)
      end,
      nextscan = function(o, option, _rounding, input1, input2, hex)
        local st = o[STATE]
        o.waitTillDone()
        local scan = st.scan
        if not scan then fail("MemScan.nextScan", "only after a firstScan of a number or string", 2) end
        local compare = ({ [1] = "exact", [2] = "between", [3] = "greater", [4] = "less", [5] = "increased", [7] = "decreased", [9] = "changed", [10] = "unchanged" })[toint(option)]
        if not compare then fail("MemScan.nextScan", "it can't compare by an amount or to an unknown value", 2) end
        local vt = ({ u8 = 0, i16 = 1, i32 = 2, i64 = 3, f32 = 4, f64 = 5, string = 6, utf16 = 7 })[st.type]
        local low = input1 ~= nil and input1 ~= "" and scan_value(vt, input1, hex) or nil
        local high = input2 ~= nil and input2 ~= "" and scan_value(vt, input2, hex) or nil
        st.found = nil
        st.pending = scan:next(compare, low and tostring(low) or "", high and tostring(high) or "")
      end,
      newscan = function(o)
        local st = o[STATE]
        if st.scan then st.scan:destroy() end
        st.found, st.scan, st.pending = nil, nil, nil
      end,
      waittilldone = function(o)
        local st = o[STATE]
        local p = st.pending
        if not p then return end
        st.pending = nil
        local got = p:await()
        if got then st.scan = got end
      end,
      setonlyoneresult = function(o, v) o[STATE].one = v end,
      getonlyresult = function(o) return o[STATE].found and o[STATE].found[1] end,
    },
    unsupported = { "scan", "saveCurrentResults", "getProgress", "getAttachedFoundlist" },
  })
  -- What a scan found, as integers
  local function found_of(scan)
    local st = scan[STATE]
    if st.found then return st.found end
    if not st.scan then return {} end
    local out = {}
    for i, a in ipairs(st.scan:results(0, math.min(st.scan:count(), 0xFFFFFFFF))) do out[i] = a end
    return out
  end
  local VALUE_READERS = {
    u8 = memory.readU8, i16 = memory.readI16, i32 = memory.readI32, i64 = memory.readI64,
    f32 = memory.readF32, f64 = memory.readF64, string = memory.readString, utf16 = memory.readUtf16,
  }
  FoundList = class("TFoundList", {
    props = {
      count = { get = function(o) return #(o[STATE].list or {}) end },
      address = { get = function(o) return indexed(function(i) return o.getAddress(i) end) end },
      value = { get = function(o) return indexed(function(i) return o.getValue(i) end) end },
    },
    methods = {
      initialize = function(o) o[STATE].list = found_of(o[STATE].scan) end,
      deinitialize = function(o) o[STATE].list = nil end,
      getcount = function(o) return o.Count end,
      getaddress = function(o, i)
        local a = (o[STATE].list or {})[toint(i) + 1]
        return a and fmt("%X", a) or nil
      end,
      getvalue = function(o, i)
        local a = (o[STATE].list or {})[toint(i) + 1]
        if not a then return nil end
        local read = VALUE_READERS[o[STATE].scan[STATE].type]
        if not read then return nil end
        local ok, v = pcall(read, memory, a, 0)
        return ok and tostring(v) or "??"
      end,
    },
    index = function(o, i) return o.getAddress(i) end,
  })
  def("createMemScan", function() return new(MemScan, {}) end)
  def("createFoundList", function(scan)
    if not is_a(scan, MemScan) then error("CE createFoundList: expected a MemScan", 2) end
    return new(FoundList, { scan = scan })
  end)

  ---------------------------------------------------------------------------------------------
  -- Disassembly

  -- Like CE's `00401000 - 8B 45 FC - mov eax,[ebp-04]`, but with Wraith's spelling of the code
  def("disassemble", function(address)
    local a = get_address(address)
    local i = w.code:disassemble(a, 1)[1]
    local bytes = {}
    for k, b in ipairs(i.bytes) do bytes[k] = fmt("%02X", b) end
    return fmt("%X - %s - %s", a, table.concat(bytes, " "), i.text)
  end)
  def("splitDisassembledString", function(text)
    local address, bytes, code = tostring(text):match("^%s*(%x+)%s*%-%s*(.-)%s*%-%s*(.*)$")
    if not address then return "", tostring(text), "", "" end
    local opcode, extra = code:match("^(.-)%s*:%s*(.*)$")
    return extra or "", opcode or code, bytes, address
  end)
  def("getInstructionSize", function(address)
    local ok, n = pcall(w.code.instructionLength, w.code, get_address(address))
    return ok and n or nil
  end)
  -- Code can't be decoded backwards, so this tries a few starts and keeps the consensus
  def("getPreviousOpcode", function(address)
    local a = get_address(address)
    local votes, best, best_n = {}, nil, 0
    for back = 1, 32 do
      local ok, list = pcall(w.code.disassemble, w.code, a - back, 32)
      if ok then
        local at, last = a - back, nil
        for _, i in ipairs(list) do
          if at >= a then break end
          last = at
          at = at + i.length
        end
        if at == a and last then
          votes[last] = (votes[last] or 0) + 1
          if votes[last] > best_n then best, best_n = last, votes[last] end
        end
      end
    end
    return best or a - 1
  end)

  ---------------------------------------------------------------------------------------------
  -- Keys, the mouse, the clipboard and the screen


  local function key_down(name)
    local button = name:match("^mouse_(.+)$")
    if button then
      local ok, down = pcall(w.input.buttonDown, w.input, button)
      return ok and down
    end
    -- CE's shift, ctrl and alt are either side
    if name == "shift" or name == "ctrl" or name == "alt" then return key_down("left_" .. name) or key_down("right_" .. name) end
    local ok, down = pcall(w.input.keyDown, w.input, name)
    return ok and down
  end
  def("isKeyPressed", function(key)
    local name
    if type(key) == "string" then
      name = #key == 1 and (key:find("%d") and "digit_" .. key or key:lower()) or key
    else
      name = VK[toint(key, "key")]
    end
    if not name then return false end
    return key_down(name)
  end)
  -- In the game window's client pixels, not the screen's
  def("getMousePos", function()
    local p = w.input:mousePos()
    if not p then return 0, 0 end
    return p.x, p.y
  end)
  -- Off the game's threads, so it waits a frame, in a thread, timer or the main script
  def("readFromClipboard", function()
    return w.clipboard:text():await()
  end)
  def("writeToClipboard", function(text)
    w.clipboard:setText(tostring(text)):catch(function(e)
      log:warn(table_name .. ": couldn't write to the clipboard: " .. tostring(e))
    end)
  end)
  -- The game window's size, during a frame
  def("getScreenWidth", function() return floor(w.ui:displaySize().x) end)
  def("getScreenHeight", function() return floor(w.ui:displaySize().y) end)

  ---------------------------------------------------------------------------------------------
  -- Debug-register breakpoints. The callback runs a frame later with registers in CE's globals.

  local REGISTERS = {
    "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "rip", "rflags", "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp", "eip", "eflags",
  }
  local breakpoints = {}
  local function set_registers(cpu)
    for _, r in ipairs(REGISTERS) do
      local ok, v = pcall(function() return cpu[r] end)
      if ok and v ~= nil then
        env[r:upper()] = v
        -- CE's 32-bit names work in 64-bit games too
        if r:find("^r%a%a$") then env["E" .. r:sub(2):upper()] = v & 0xFFFFFFFF end
      end
    end
  end
  def("debug_setBreakpoint", function(address, ...)
    local a = get_address(address)
    local size, trigger, f = 1, 0, nil
    for i, v in ipairs({ ... }) do
      if type(v) == "function" then
        f = v
      elseif i == 1 then
        size = toint(v, "size")
      elseif i == 2 then
        trigger = toint(v, "trigger")
      end
    end
    local function hit(_, cpu)
      set_registers(cpu)
      if f then f() end
    end
    if breakpoints[a] then breakpoints[a]:remove() end
    breakpoints[a] = nil
    local kind = trigger == 0 and "execute" or trigger == 2 and "write" or "access"
    local ok, p = pcall(w.watches.add, w.watches, a, trigger == 0 and 1 or size, kind, hit)
    if not ok then
      log:warn(table_name .. ": couldn't set a breakpoint at " .. fmt("%X", a) .. ": " .. tostring(p))
      return false
    end
    breakpoints[a] = p
    return true
  end)
  def("debug_removeBreakpoint", function(address)
    local a = get_address(address)
    local p = breakpoints[a]
    if not p then return false end
    breakpoints[a] = nil
    p:remove()
    return true
  end)
  def("debug_getBreakpointList", function()
    local out = {}
    for a in pairs(breakpoints) do out[#out + 1] = a end
    table.sort(out)
    return out
  end)
  def("debug_isDebugging", function() return next(breakpoints) ~= nil end)

  ---------------------------------------------------------------------------------------------
  -- The process. Wraith's already in the game, so there's nothing to open.

  local main = memory:main()
  local function is_game(name)
    if type(name) ~= "string" then return false end
    return name:lower() == main.name:lower()
  end
  def("openProcess", function(what)
    if type(what) == "number" or is_game(what) then return true end
    fail("openProcess", "Wraith runs inside " .. main.name .. " and can't open '" .. tostring(what) .. "'", 2)
  end)
  -- There's no process id in Wraith's API, so this stands in for the game's
  local fake_pid = 1
  def("getOpenedProcessID", function() return fake_pid end)
  def("getProcessIDFromProcessName", function(name)
    if is_game(name) then return fake_pid end
    return nil
  end)
  def("getCEVersion", function() return 7.5 end)
  def("getCheatEngineFileVersion", function()
    return 0x0007000500000000, { major = 7, minor = 5, release = 0, build = 0 }
  end)
  def("getOperatingSystem", function() return 0 end)
  def("darkMode", function() return false end)
  def("activateProtection", function() end)
  def("enableDRM", function() end)
  ---------------------------------------------------------------------------------------------
  -- Table files, stored base64 in the tweak file since scripts can't read files. Decoded on use.

  local b64 = {}
  do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #alphabet do b64[alphabet:byte(i)] = i - 1 end
  end
  local function from_base64(text)
    local out, n, bits, have = {}, 0, 0, 0
    for i = 1, #text do
      local v = b64[text:byte(i)]
      if v then
        bits = ((bits << 6) | v) & 0xFFFFFF
        have = have + 6
        if have >= 8 then
          have = have - 8
          n = n + 1
          out[n] = string.char((bits >> have) & 0xFF)
        end
      end
    end
    return table.concat(out)
  end

  -- Just enough of CE's MemoryStream for what tables do with a table file's, like playSound
  local MemoryStream = class("TMemoryStream", {
    props = {
      size = { get = function(o) return #o[STATE].data end },
      position = { get = function(o) return o[STATE].pos end, set = function(o, v) o[STATE].pos = toint(v, "Position") end },
    },
    unsupported = { "read", "write", "readByte", "writeByte", "loadFromFile", "saveToFile", "copyFrom", "clear", "memory" },
  })

  local TableFile = class("TTableFile", {
    props = {
      name = { get = function(o) return o[STATE].name end },
      stream = { get = function(o) return o[STATE].stream end },
    },
    methods = {
      getdata = function(o) return o[STATE].stream end,
    },
    unsupported = { "saveToFile", "delete" },
  })

  -- Lowercase name to { name, text } till it's asked for, then { name, file }
  local table_files = {}
  function handle.files(list)
    for name, text in pairs(list) do table_files[name:lower()] = { name = name, text = text } end
  end

  def("findTableFile", function(name)
    local f = table_files[tostring(name):lower()]
    if not f then return nil end
    if not f.file then
      local stream = new(MemoryStream, { data = from_base64(f.text), pos = 0 })
      f.text = nil
      f.file = new(TableFile, { name = f.name, stream = stream })
    end
    return f.file
  end)

  def("beep", function() w.sound:playSystem("default") end)
  def("playSound", function(stream, wait)
    if is_a(stream, TableFile) then stream = stream[STATE].stream end
    local data
    if is_a(stream, MemoryStream) then
      data = stream[STATE].data
    elseif type(stream) == "string" then
      data = stream
    else
      fail("playSound", "it takes a table file, its stream or a WAV file's bytes in a string, since CE's other memory streams aren't supported yet", 2)
    end
    if wait then warn_once("playSound wait", table_name .. ": playSound doesn't wait for the sound to end in Wraith") end
    w.sound:play(data)
  end)
  def("getFormCount", function() return 0 end)
  def("getAutoAttachList", function() return new_strings() end)
  def("onAutoGuess", function() end)

  -- createRef and friends, which CE tables use to tuck Lua values into integers
  local refs, next_ref = {}, 1
  def("createRef", function(...)
    local id = next_ref
    next_ref = next_ref + 1
    refs[id] = table.pack(...)
    return id
  end)
  def("getRef", function(id)
    local r = refs[id]
    if not r then return nil end
    return unpack(r, 1, r.n)
  end)
  def("destroyRef", function(id) refs[id] = nil end)
  def("getGlobalVariable", function(name) return env[name] end)
  def("setGlobalVariable", function(name, v) env[name] = v end)

  ---------------------------------------------------------------------------------------------
  -- Memory records and the address list, from the importer's manifest. See API.md.

  local records = {}
  local by_id = {}
  local order = {}
  local AddressList, MemoryRecord, by_description
  local next_id = 0

  local function rec_state(r) return r[STATE] end

  local function call_handler(f, ...)
    if type(f) == "string" then f = env[f] end
    if type(f) ~= "function" then return nil end
    return f(...)
  end

  local function rec_address(r)
    local st = rec_state(r)
    if st.kind == "address" then
      local ok, a = pcall(w.addresses.get, w.addresses, st.address)
      if not ok then return nil end
      return unwrap(a)
    elseif st.kind == "data" then
      local ok, a = pcall(w.addresses.resolve, w.addresses, st.data, {})
      if not ok then return nil end
      return unwrap(a)
    elseif st.kind == "location" then
      local a
      local text = trim(st.location)
      local sign = text:sub(1, 1)
      if (sign == "+" or sign == "-") and st.parent then
        -- From the record it's under, like CE
        local base = rec_address(st.parent)
        local offset = base and lookup("0" .. text)
        a = offset and base + offset
      else
        a = lookup(text)
      end
      if not a then return nil end
      -- CE keeps them last applied first
      for i = #st.offsets, 1, -1 do
        local ok, p = pcall(memory.readPointer, memory, a)
        if not ok then return nil end
        local off = st.offsets[i]
        if type(off) == "string" then off = parse_number(off) or 0 end
        a = p + off
      end
      return a
    end
    return nil
  end

  local function read_number(a, t, signed)
    if t == 0 then return signed and memory:readI8(a) or memory:readU8(a) end
    if t == 1 then return signed and memory:readI16(a) or memory:readU16(a) end
    if t == 2 then return signed and memory:readI32(a) or memory:readU32(a) end
    if t == 3 then return memory:readI64(a) end
    if t == 4 then return memory:readF32(a) end
    if t == 5 then return memory:readF64(a) end
    if t == 12 then return memory:readPointer(a) end
    return nil
  end

  local masks = { [0] = 0xFF, 0xFFFF, 0xFFFFFFFF }

  local function show_number(v, t, hex)
    if t == 4 then return fmt("%.7g", v) end
    if t == 5 then return fmt("%.15g", v) end
    if hex or t == 12 then
      if masks[t] then v = v & masks[t] end
      return fmt("%X", v)
    end
    return fmt("%d", v)
  end

  local function rec_value(r)
    local st = rec_state(r)
    if st.kind == "tweak" then return "<script>" end
    if st.kind == "group" then return "" end
    local a = rec_address(r)
    if not a then return "??" end
    local t = st.type
    local ok, v = pcall(function()
      if t == vt.string or t == vt.unicode then
        local len = st.length or 10
        if st.unicode or t == vt.unicode then return memory:readUtf16(a, len) end
        return memory:readString(a, len)
      elseif t == vt.bytes then
        local s = bytes_at(a, st.length or 4)
        return (s:gsub(".", function(c) return fmt("%02X ", c:byte()) end):gsub(" $", ""))
      elseif t == vt.binary then
        local start, size = st.bitstart or 0, st.length or 1
        local bytes = (start + size + 7) // 8
        local s = bytes_at(a, bytes) .. string.rep("\0", 8)
        local n = string.unpack("<i8", s)
        n = (n >> start) & ((1 << size) - 1)
        if st.hex then return fmt("%X", n) end
        return fmt("%d", n)
      end
      local n = read_number(a, t, st.signed)
      if n == nil then return "??" end
      return show_number(n, t, st.hex)
    end)
    if ok then return v end
    return "??"
  end

  local function parse_value(st, v)
    local t = st.type
    if type(v) == "boolean" then v = v and 1 or 0 end
    if t == 4 or t == 5 then
      local n = tonumber(v)
      if not n then error("CE MemoryRecord.Value: '" .. tostring(v) .. "' isn't a number", 3) end
      return n
    end
    if type(v) == "number" then return toint(v) end
    local s = trim(tostring(v))
    local n
    if st.hex then
      n = tonumber((s:gsub("^0[xX]", "")), 16)
    elseif s:find("^%-?%d+$") then
      n = math.tointeger(tonumber(s))
    else
      n = parse_number(s) or tonumber(s)
    end
    if not n then error("CE MemoryRecord.Value: '" .. s .. "' isn't a number", 3) end
    return toint(n)
  end

  local writers = {
    [0] = memory.writeU8, memory.writeU16, memory.writeU32, memory.writeI64, memory.writeF32, memory.writeF64,
  }

  local function set_value(r, v)
    local st = rec_state(r)
    if st.kind == "tweak" or st.kind == "group" then return end
    local a = rec_address(r)
    if not a then return end
    local t = st.type
    if t == vt.string or t == vt.unicode then
      local s = tostring(v)
      if st.unicode or t == vt.unicode then s = utf16(s) end
      pcall(memory.writeBytes, memory, a, s)
      return
    elseif t == vt.bytes then
      local list = {}
      for b in tostring(v):gmatch("%x%x?") do list[#list + 1] = tonumber(b, 16) end
      pcall(memory.writeBytes, memory, a, list)
      return
    elseif t == vt.binary then
      local start, size = st.bitstart or 0, st.length or 1
      local bytes = (start + size + 7) // 8
      local ok, s = pcall(bytes_at, a, bytes)
      if not ok then return end
      local n = string.unpack("<i8", s .. string.rep("\0", 8))
      local mask = ((1 << size) - 1) << start
      n = (n & ~mask) | ((parse_value({ type = 2, hex = st.hex }, v) << start) & mask)
      pcall(memory.writeBytes, memory, a, string.pack("<i8", n):sub(1, bytes))
      return
    elseif t == 12 then
      t = target64 and 3 or 2
    end
    local f = writers[t]
    if not f then return end
    local n = parse_value(st, v)
    if masks[t] then n = n & masks[t] end
    pcall(f, memory, a, n)
  end

  -- Freezing writes the value back every 100ms, like CE's freeze timer
  local function freeze(r, on)
    local st = rec_state(r)
    if st.freeze then
      due[st.freeze] = nil
      st.freeze = nil
    end
    if not on then return true end
    local a = rec_address(r)
    if not a then return false end
    local size = vt_sizes[st.type] or (st.type == 12 and (target64 and 8 or 4)) or st.length
    if not size then return false end
    local ok, saved = pcall(bytes_at, a, size)
    if not ok then return false end
    st.freeze = later(function()
      local at = rec_address(r)
      if at then pcall(memory.writeBytes, memory, at, saved) end
    end, 100, true)
    return true
  end

  local function tweak_on(st)
    if not bridge or not bridge.isOn then return false end
    local ok, on = pcall(bridge.isOn, st.tweak)
    return ok and on and true or false
  end

  local function is_active(r)
    local st = rec_state(r)
    if st.kind == "tweak" then return tweak_on(st) end
    return st.active
  end

  local function has_option(st, name)
    return st.options ~= nil and st.options:lower():find(name:lower(), 1, true) ~= nil
  end

  local set_active
  -- Does the work, true if it's now how it was asked to be
  local function switch(r, on)
    local st = rec_state(r)
    if st.kind == "tweak" then
      if not bridge or not bridge.setOn then
        fail("MemoryRecord.Active", "turning '" .. st.description .. "' on or off needs the tweak bridge from whoever runs the table", 3)
      end
      -- It's heard back through `toggled`, whose events already ran here
      st.switching = on
      local ok, err = pcall(bridge.setOn, st.tweak, on)
      if not ok then
        st.switching = nil
        log:warn(table_name .. ": couldn't turn '" .. st.description .. "' " .. (on and "on" or "off") .. ": " .. tostring(err))
        return false
      end
      return tweak_on(st) == on
    elseif st.kind == "group" then
      st.active = on
      if (on and has_option(st, "moActivateChildrenAsWell")) or (not on and has_option(st, "moDeactivateChildrenAsWell")) then
        for _, c in ipairs(st.children) do set_active(c, on) end
      end
      return true
    end
    if not freeze(r, on) then return false end
    st.active = on
    return true
  end

  set_active = function(r, on)
    on = on and true or false
    local st = rec_state(r)
    if is_active(r) == on then return end
    local event = on and st.on_activate or st.on_deactivate
    if event ~= nil and call_handler(event, r, true, not on) ~= true then return end
    call_handler(env.onMemRecPreExecute, r, on)
    local done = switch(r, on)
    call_handler(env.onMemRecPostExecute, r, on, done)
    if done and event ~= nil then call_handler(event, r, false, on) end
  end

  local function detach(r)
    local st = rec_state(r)
    local siblings = st.parent and rec_state(st.parent).children or records
    for i, c in ipairs(siblings) do
      if c == r then
        table.remove(siblings, i)
        break
      end
    end
    st.parent = nil
  end

  local function rebuild_order()
    order = {}
    local function walk(list)
      for _, r in ipairs(list) do
        order[#order + 1] = r
        walk(rec_state(r).children)
      end
    end
    walk(records)
  end

  local function remove_record(r)
    for _, c in ipairs({ unpack(rec_state(r).children) }) do remove_record(c) end
    freeze(r, false)
    detach(r)
    by_id[rec_state(r).id] = nil
    rebuild_order()
  end

  local function child_at(r, i)
    return rec_state(r).children[toint(i, "index") + 1]
  end

  -- Its own list, or the one of the record it links to by description
  local function dropdown_of(r)
    local st = rec_state(r)
    local link = st.kept.dropdownlinkedmemrec
    if link and link ~= "" then
      local other = by_description(link)
      if other and other ~= r then return rec_state(other).dropdown end
    end
    return st.dropdown
  end

  local function dropdown_entry(r, i, part)
    local line = dropdown_of(r).getString(i)
    local value, text = line:match("^([^:]*):(.*)$")
    if part == 1 then return trim(value or line) end
    return trim(text or "")
  end

  local function index_of(r)
    for i, x in ipairs(order) do
      if x == r then return i - 1 end
    end
    return -1
  end

  -- Unmapped records stay readable; setting their address goes through CE location text
  local function set_location(r, text, offsets)
    local st = rec_state(r)
    st.kind = "location"
    st.location = tostring(text)
    st.offsets = offsets or st.offsets or {}
  end

  MemoryRecord = class("TMemoryRecord", {
    props = {
      id = { get = function(o) return rec_state(o).id end },
      index = { get = index_of },
      description = {
        get = function(o) return rec_state(o).description end,
        set = function(o, v) rec_state(o).description = tostring(v) end,
      },
      address = {
        get = function(o)
          local st = rec_state(o)
          if st.kind == "location" then return st.location end
          if st.kind == "address" then return "(" .. st.address .. ")" end
          if st.kind == "data" then return st.data end
          return ""
        end,
        set = function(o, v) set_location(o, v) end,
      },
      addressstring = { get = function(o) return o.Address end },
      currentaddress = { get = function(o) return rec_address(o) or 0 end },
      offsetcount = {
        get = function(o) return #(rec_state(o).offsets or {}) end,
        set = function(o, n)
          local st = rec_state(o)
          if st.kind ~= "location" then set_location(o, o.Address, {}) end
          n = toint(n, "OffsetCount")
          for i = 1, n do st.offsets[i] = st.offsets[i] or 0 end
          for i = #st.offsets, n + 1, -1 do st.offsets[i] = nil end
        end,
      },
      offset = {
        get = function(o)
          return indexed(function(i)
            local off = (rec_state(o).offsets or {})[toint(i) + 1]
            if type(off) == "string" then return parse_number(off) end
            return off
          end, function(i, v) rec_state(o).offsets[toint(i) + 1] = toint(v) end)
        end,
      },
      offsettext = {
        get = function(o)
          return indexed(function(i)
            local off = (rec_state(o).offsets or {})[toint(i) + 1]
            if off == nil then return nil end
            if type(off) == "string" then return off end
            return fmt("%X", off)
          end, function(i, v) rec_state(o).offsets[toint(i) + 1] = tostring(v) end)
        end,
      },
      type = {
        get = function(o) return rec_state(o).type end,
        set = function(o, v) rec_state(o).type = type_code(v) end,
      },
      vartype = {
        get = function(o) return vt_names[rec_state(o).type] end,
        set = function(o, v) rec_state(o).type = type_code(v) end,
      },
      value = { get = rec_value, set = set_value },
      numericalvalue = {
        get = function(o) return tonumber(rec_value(o)) end,
        set = set_value,
      },
      active = { get = is_active, set = set_active },
      selected = { get = function() return false end },
      showashex = {
        get = function(o) return rec_state(o).hex end,
        set = function(o, v) rec_state(o).hex = v and true or false end,
      },
      showassigned = {
        get = function(o) return rec_state(o).signed end,
        set = function(o, v) rec_state(o).signed = v and true or false end,
      },
      isgroupheader = { get = function(o) return rec_state(o).kind == "group" end },
      isreadable = { get = function(o) return rec_address(o) ~= nil end },
      options = {
        get = function(o) return rec_state(o).options or "[]" end,
        set = function(o, v) rec_state(o).options = tostring(v) end,
      },
      count = { get = function(o) return #rec_state(o).children end },
      child = { get = function(o) return indexed(function(i) return child_at(o, i) end) end },
      parent = { get = function(o) return rec_state(o).parent end },
      dropdownlist = { get = dropdown_of },
      dropdowncount = { get = function(o) return dropdown_of(o).Count end },
      dropdownvalue = { get = function(o) return indexed(function(i) return dropdown_entry(o, i, 1) end) end },
      dropdowndescription = { get = function(o) return indexed(function(i) return dropdown_entry(o, i, 2) end) end },
      onactivate = {
        get = function(o) return rec_state(o).on_activate end,
        set = function(o, f) rec_state(o).on_activate = f end,
      },
      ondeactivate = {
        get = function(o) return rec_state(o).on_deactivate end,
        set = function(o, f) rec_state(o).on_deactivate = f end,
      },
      string = {
        get = function(o)
          local st = rec_state(o)
          return setmetatable({}, {
            __index = function(_, k)
              k = tostring(k):lower()
              if k == "size" then return st.length or 10 end
              if k == "unicode" then return st.unicode or false end
              return nil
            end,
            __newindex = function(_, k, v)
              k = tostring(k):lower()
              if k == "size" then st.length = toint(v) end
              if k == "unicode" then st.unicode = v and true or false end
            end,
          })
        end,
      },
      aob = {
        get = function(o)
          local st = rec_state(o)
          return setmetatable({}, {
            __index = function(_, k) if tostring(k):lower() == "size" then return st.length or 4 end end,
            __newindex = function(_, k, v) if tostring(k):lower() == "size" then st.length = toint(v) end end,
          })
        end,
      },
      binary = {
        get = function(o)
          local st = rec_state(o)
          return setmetatable({}, {
            __index = function(_, k)
              k = tostring(k):lower()
              if k == "startbit" then return st.bitstart or 0 end
              if k == "size" then return st.length or 1 end
            end,
            __newindex = function(_, k, v)
              k = tostring(k):lower()
              if k == "startbit" then st.bitstart = toint(v) end
              if k == "size" then st.length = toint(v) end
            end,
          })
        end,
      },
    },
    methods = {
      getdescription = function(o) return o.Description end,
      setdescription = function(o, v) o.Description = v end,
      getaddress = function(o)
        local st = rec_state(o)
        if st.kind == "location" and #st.offsets > 0 then return st.location, { unpack(st.offsets) } end
        return o.Address
      end,
      setaddress = function(o, text, offsets) set_location(o, text, offsets and { unpack(offsets) } or nil) end,
      getoffsetcount = function(o) return o.OffsetCount end,
      setoffsetcount = function(o, n) o.OffsetCount = n end,
      getoffset = function(o, i) return o.Offset[i] end,
      setoffset = function(o, i, v) o.Offset[i] = v end,
      getcurrentaddress = function(o) return o.CurrentAddress end,
      appendtoentry = function(o, parent)
        if not is_a(parent, MemoryRecord) then error("CE MemoryRecord.appendToEntry: expected a memory record", 2) end
        detach(o)
        rec_state(o).parent = parent
        local kids = rec_state(parent).children
        kids[#kids + 1] = o
        rebuild_order()
      end,
      delete = function(o) o.destroy() end,
      reinterpret = function() end,
      beginedit = function() end,
      endedit = function() end,
      disablewithoutexecute = function(o)
        local st = rec_state(o)
        if st.kind == "tweak" then fail("MemoryRecord.disableWithoutExecute", "a tweak always runs its off part", 2) end
        freeze(o, false)
        st.active = false
      end,
    },
    on_destroy = remove_record,
    unsupported = {
      "Script", "CustomTypeName", "Hotkey", "AsyncProcessing", "AsyncProcessingTime", "HasMouseOver",
      "getHotkey", "getHotkeyByID", "createHotkey",
    },
    index = child_at,
  })

  -- Kept so scripts can set them, though nothing in Wraith shows them or calls them
  local kept = {
    color = 0x80000008, allowincrease = false, allowdecrease = false, collapsed = false,
    isaddressgroupheader = false, dropdownreadonly = false, dropdowndescriptiononly = false,
    displayasdropdownlistitem = false, dontsave = false, async = false, dropdownlinkedmemrec = "",
    ondestroy = false, ongetdisplayvalue = false, onvaluechanged = false, onvaluechangedbyuser = false,
  }
  for k, default in pairs(kept) do
    MemoryRecord.props[k] = {
      get = function(o)
        local v = rec_state(o).kept[k]
        if v ~= nil then return v end
        -- The events have no default
        if k:find("^on") then return nil end
        return default
      end,
      set = function(o, v) rec_state(o).kept[k] = v end,
    }
  end
  MemoryRecord.props.dropdownlinked = { get = function(o) return dropdown_of(o) ~= rec_state(o).dropdown end }
  MemoryRecord.props.hotkeycount = { get = function() return 0 end }

  local function make_record(e, parent)
    local st = {
      id = e.id,
      description = e.description or "No description",
      parent = parent,
      children = {},
      type = type_code(e.type) or (e.tweak and not e.data and vt.script) or vt.dword,
      hex = e.hex or false,
      signed = e.signed or false,
      length = e.length,
      unicode = e.unicode,
      bitstart = e.bitstart,
      options = e.options,
      offsets = {},
      active = false,
      kept = { dropdownlinkedmemrec = e.dropdownLink },
    }
    st.dropdown = new_strings()
    for _, line in ipairs(e.dropdown or {}) do st.dropdown.add(line) end
    if e.data then
      st.kind, st.data, st.tweak = "data", e.data, e.tweak
    elseif e.tweak then
      st.kind, st.tweak = "tweak", e.tweak
    elseif e.address then
      st.kind, st.address = "address", e.address
    elseif e.location then
      st.kind, st.location = "location", e.location
      for i, off in ipairs(e.offsets or {}) do st.offsets[i] = off end
    else
      st.kind = "group"
    end
    if st.id == nil then
      st.id = next_id
    end
    if type(st.id) == "number" and st.id >= next_id then next_id = st.id + 1 end
    local r = new(MemoryRecord, st)
    by_id[st.id] = r
    return r
  end

  -- Flat list in table order, children after their parent. `handle.load` can add more.
  local function load_records(list)
    for _, e in ipairs(list or {}) do
      local parent = e.parent ~= nil and by_id[e.parent] or nil
      if e.parent ~= nil and not parent then
        error("CE records manifest: record " .. tostring(e.id) .. " comes before its parent " .. tostring(e.parent), 3)
      end
      local r = make_record(e, parent)
      local siblings = parent and rec_state(parent).children or records
      siblings[#siblings + 1] = r
    end
    rebuild_order()
  end
  load_records(options.records)
  handle.load = load_records

  by_description = function(text)
    text = tostring(text)
    for _, r in ipairs(order) do
      if rec_state(r).description == text then return r end
    end
    return nil
  end

  local function by_index(i)
    return order[toint(i, "index") + 1]
  end

  AddressList = class("TAddresslist", {
    props = {
      count = { get = function() return #order end },
      memoryrecord = { get = function() return indexed(by_index) end },
      selcount = { get = function() return 0 end },
      selectedrecord = { get = function() return nil end, set = function() end },
      loadedtableversion = { get = function() return options.version or 0 end },
    },
    methods = {
      getcount = function() return #order end,
      getmemoryrecord = function(_, i) return by_index(i) end,
      getmemoryrecordbydescription = function(_, text) return by_description(text) end,
      getmemoryrecordbyid = function(_, id) return by_id[id] or by_id[tonumber(id)] end,
      creatememoryrecord = function()
        local r = make_record({ type = vt.dword, location = "0" }, nil)
        records[#records + 1] = r
        rebuild_order()
        return r
      end,
      getselectedrecords = function() return {} end,
      getselectedrecord = function() return nil end,
      setselectedrecord = function() end,
      rebuilddescriptioncache = function() end,
      disableallwithoutexecute = function()
        for _, r in ipairs(order) do
          if rec_state(r).kind ~= "tweak" then
            freeze(r, false)
            rec_state(r).active = false
          end
        end
      end,
    },
    unsupported = {
      "List", "doDescriptionChange", "doAddressChange", "doTypeChange", "doValueChange", "OnDescriptionChange",
      "OnAddressChange", "OnTypeChange", "OnValueChange", "OnAutoAssemblerEdit", "MouseHighlightedRecord",
    },
    index = function(_, i) return by_index(i) end,
  })

  local address_list = new(AddressList, {})
  def("getAddressList", function() return address_list end)
  def("AddressList", address_list)

  -- The tweak changed elsewhere (e.g. Tweaks panel), so OnActivate and friends still fire
  function handle.toggled(path, on)
    for _, r in ipairs(order) do
      local st = rec_state(r)
      if st.kind == "tweak" and st.tweak == path then
        if st.switching == on then
          st.switching = nil
        else
          st.switching = nil
          local event = on and st.on_activate or st.on_deactivate
          if event ~= nil then call_handler(event, r, false, on) end
        end
      end
    end
  end
  handle.addressList = address_list
  handle.record = function(id) return by_id[id] end

  ---------------------------------------------------------------------------------------------
  -- CE's GUI. Tables use the main form as a timer's owner, so it's here, but nothing on it is.

  local Form = class("TMainForm", {})
  Form.meta.__index = function(_, k)
    fail("MainForm." .. tostring(k), "there's no CE window in Wraith", 2)
  end
  Form.meta.__newindex = function(_, k)
    fail("MainForm." .. tostring(k), "there's no CE window in Wraith", 2)
  end
  local main_form = new(Form, {})
  def("getMainForm", function() return main_form end)
  def("MainForm", main_form)
  def("process", main.name)
  def("TrainerOrigin", nil)
  def("syntaxcheck", false)

  ---------------------------------------------------------------------------------------------
  -- Everything else

  -- Why, for the ones with more to say than "not yet"
  local reasons = {
    autoAssemble = "CE's Auto Assembler runs whole scripts with its own directives, so the importer turns those into tweaks ahead of time instead",
    autoAssembleCheck = "CE's Auto Assembler runs whole scripts with its own directives, so the importer turns those into tweaks ahead of time instead",
    assemble = "CE's assembler reads numbers as hex, use Wraith's code.assemble",
    executeCode = "use salamander.native to call game code",
    executeCodeEx = "use salamander.native to call game code",
    pause = "Wraith runs inside the game and can't pause it",
    unpause = "Wraith runs inside the game and can't pause it",
    closeCE = "there's no Cheat Engine to close",
    loadTable = "the importer turns tables into Wraith projects instead",
    saveTable = "the importer turns tables into Wraith projects instead",
    shellExecute = "scripts can't run programs in Wraith",
    runCommand = "scripts can't run programs in Wraith",
    debugProcess = "Wraith has no debugger, use its hooks instead",
    getMemoryViewForm = "there's no CE window in Wraith",
    createForm = "use Wraith's ui instead",
  }

  local function stub(name)
    return function() fail(name, reasons[name], 2) end
  end

  -- Setup calls that only matter later. They warn once so the main script carries on.
  local setup = {
    "registerAutoAssemblerCommand", "unregisterAutoAssemblerCommand", "registerLuaFunctionHighlight",
    "unregisterLuaFunctionHighlight", "registerSymbolLookupCallback", "unregisterSymbolLookupCallback",
    "registerAddressLookupCallback", "unregisterAddressLookupCallback", "registerStructureDissectOverride",
    "unregisterStructureDissectOverride", "registerStructureNameLookup", "unregisterStructureNameLookup",
    "registerFormAddNotification", "unregisterFormAddNotification", "registerEXETrainerFeature",
    "unregisterEXETrainerFeature", "registerAutoAssemblerPrologue", "unregisterAutoAssemblerPrologue",
    "registerAutoAssemblerTemplate", "unregisterAutoAssemblerTemplate", "registerGlobalStructureListUpdateNotification",
    "unregisterGlobalStructureListUpdateNotification", "registerStructureAndElementListCallback",
    "unregisterStructureAndElementListCallback", "registerAssembler", "unregisterAssembler",
    "registerGlobalDisassembleOverride", "unregisterGlobalDisassembleOverride", "registerBinUtil",
    "registerSpeedhackCallbacks", "unregisterSpeedhackCallbacks", "setGlobalKeyPollInterval",
    "setGlobalDelayBetweenHotkeyActivation", "gc_setPassive", "gc_setActive", "setProgressState",
    "setProgressValue", "loadPOFile",
  }
  for _, name in ipairs(setup) do
    if rawget(env, name) == nil then
      def(name, function()
        warn_once(name, table_name .. ": CE " .. name .. " isn't supported in Wraith yet, so it does nothing")
      end)
    end
  end

  -- @stubs
  -- Every other CE global raises. API.md says why for each.
  local stubbed = {
    "addCIncludePath", "addSnapshotAsComment", "allocateKernelMemory", "allocateSharedMemory",
    "allocateSharedMemoryLocal", "assemble", "autoAssemble", "autoAssembleCheck", "closeCE",
    "closeRemoteHandle", "compile", "compileCS", "compileFiles", "compileTCCLib",
    "connectToCEServer", "connectToPipe", "convertKeyComboToString", "convertToUTF8", "cpuid",
    "createAutoAssemblerForm", "createBitmap", "createButton", "createCalendar",
    "createCECustomButton", "createCheckBox", "createClass", "createColorBox", "createColorDialog",
    "createComboBox", "createComponentClass", "createD3DHook", "createDiagram",
    "createDisassembler", "createEdit", "createEvent", "createExecuteCodeExStub",
    "createExecuteMethodStub", "createFileStream", "createFindDialog", "createFont", "createForm",
    "createFormFromFile", "createFormFromStream", "createGroupBox", "createHotkey", "createIcon",
    "createImage", "createImageList", "createJpeg", "createLabel", "createListBox",
    "createListView", "createLuaEngine", "createMainMenu", "createMemo", "createMemoryStream",
    "createMemoryView", "createMenuItem", "createMultiReadExclusiveWriteSynchronizer",
    "createODBCConnection", "createOpenDialog", "createPaintBox", "createPanel", "createPicture",
    "createPipe", "createPNG", "createPopupMenu", "createProcess", "createProgressBar",
    "createRadioGroup", "createRegion", "createRemoteExecutor", "createRemoteThread",
    "createRipRelativeScanner", "createSaveDialog", "createSection", "createSelectDirectoryDialog",
    "createSemaphore", "createSplitter", "createSQLite3Connection", "createSQLQuery",
    "createSQLTransaction", "createStringStream", "createStructure", "createStructureForm",
    "createStructureFromName", "createSynEdit", "createTableFile", "createThreadNewState",
    "createToggleBox", "createTrackBar", "createTreeView", "createVirtualStringTree",
    "createXMLDocument", "createXMLDocumentFromFile", "createXMLDocumentFromStream",
    "dbk_executeKernelMemory", "dbk_getCR0", "dbk_getCR3", "dbk_getCR4", "dbk_getPEProcess",
    "dbk_getPEThread", "dbk_getPhysicalAddress", "dbk_initialize", "dbk_readMSR",
    "dbk_readPhysicalMemory", "dbk_setSaferPhysicalMemoryScanning", "dbk_useKernelmodeOpenProcess",
    "dbk_useKernelmodeProcessMemoryAccess", "dbk_useKernelmodeQueryMemoryRegions",
    "dbk_usePhysicalMemoryAccess", "dbk_writeMSR", "dbk_writePhysicalMemory",
    "dbk_writesIgnoreWriteProtection", "dbvm_addMemory", "dbvm_bp_getBrokenThreadEventFull",
    "dbvm_bp_getBrokenThreadEventShort", "dbvm_bp_getBrokenThreadListSize",
    "dbvm_bp_getProcessAndThreadIDFromEvent", "dbvm_bp_resumeBrokenThread",
    "dbvm_bp_setBrokenThreadEventFull", "dbvm_changeregonbp", "dbvm_cloak_activate",
    "dbvm_cloak_deactivate", "dbvm_cloak_readOriginal", "dbvm_cloak_writeOriginal", "dbvm_getCR4",
    "dbvm_getMemory", "dbvm_initialize", "dbvm_log_cr3_start", "dbvm_log_cr3_stop", "dbvm_readMSR",
    "dbvm_readPhysicalMemory", "dbvm_removechangeregonbp", "dbvm_setKeys", "dbvm_setTSCAdjust",
    "dbvm_speedhack_setSpeed", "dbvm_traceonbp", "dbvm_traceonbp_getstatus",
    "dbvm_traceonbp_remove", "dbvm_traceonbp_retrievelog", "dbvm_traceonbp_stoptrace",
    "dbvm_watch_disable", "dbvm_watch_executes", "dbvm_watch_reads", "dbvm_watch_retrievelog",
    "dbvm_watch_writes", "dbvm_writeMSR", "dbvm_writePhysicalMemory",
    "debug_addThreadToNoBreakList", "debug_breakThread", "debug_canBreak",
    "debug_continueFromBreakpoint", "debug_getContext", "debug_getCurrentDebuggerInterface",
    "debug_getLastBranchRecord", "debug_getMaxLastBranchRecord", "debug_getXMMPointer",
    "debug_isBroken", "debug_isStepping", "debug_removeThreadFromNoBreakList",
    "debug_setBreakpointForThread", "debug_setContext", "debug_setLastBranchRecording",
    "debug_updateGUI", "debugProcess", "decodeFunction", "deleteFile", "detachIfPossible",
    "disassembleBytes", "doKeyPress", "dotNetExecuteClassMethod", "duplicateHandle",
    "encodeFunction", "encodeFunctionEx", "enumModules", "enumStructureForms", "executeCode",
    "executeCodeEx", "executeCodeLocal", "executeCodeLocalEx", "executeMethod", "fileExists",
    "findWindow", "freeKernelMemory", "fuckCheatEngine",
    "generateAOBInjectionScript", "generateAPIHookScript", "generateCodeInjectionScript",
    "generateFullInjectionScript", "getApplication", "getAutorunPath", "getCEServerInterface",
    "getCEServerPath", "getCheatEngineDir", "getCheatEngineProcessID", "getCodeFilter",
    "getComment", "getCommonModuleList", "getCPUCount", "getCurrentMemscan",
    "getDefaultDisassembler", "getDirectoryList", "getDissectCode", "getDotNetDataCollector",
    "getFileList", "getFileVersion", "getForegroundProcess", "getForegroundWindow", "getForm",
    "getHandleList", "getHeader", "getHotkeyHandlerThread", "getLuaEngine", "getMemoryViewForm",
    "getMethodProperty", "getNextAllocNumber", "getOpenedFileSize", "getOpenedProcessHandle",
    "getPhysicalAddressCR3", "getPixel", "getProcesslist", "getProperty", "getPropertyList",
    "getRTTIClassName", "getScreenCanvas", "getScreenDPI", "getSettingsForm", "getStructure",
    "getStructureCount", "getSystemMetrics", "getTempFolder", "getThreadlist", "getUltimap2",
    "getUniqueAOB", "getUserRegistryEnvironmentVariable", "getVisibleDisassembler", "getWindow",
    "getWindowCaption", "getWindowClassName", "getWindowlist", "getWindowProcessID",
    "getWorkAreaHeight", "getWorkAreaWidth", "getXBox360ControllerState", "hideAllCEWindows",
    "hookWndProc", "inheritsFromComponent", "inheritsFromControl", "inheritsFromObject",
    "inheritsFromWinControl", "injectDLL", "injectDotNetDLL", "injectLibrary", "integerToUserData",
    "invertColor", "isConnectedToCEServer", "keyDown", "keyUp", "loadFontFromStream", "loadModule",
    "loadPlugin", "loadTable", "mapMemory", "mapViewOfSection", "md5file", "md5memory",
    "mouse_event", "onAPIPointerChange", "openFileAsProcess", "openLuaServer", "pause",
    "readProcessMemoryCR3", "readRegionFromFile", "removeCIncludePath", "resetLuaState",
    "runCommand", "saveOpenedFile", "saveTable", "sendMessage", "setAPIPointer", "setAssemblerMode",
    "setComment", "setHeader", "setMethodProperty", "setMousePos", "setPointerSize", "setProperty",
    "setSQLiteLibraryName", "setUserRegistryEnvironmentVariable", "setXBox360ControllerVibration",
    "shellExecute", "shortCutToText", "signTable", "speak", "speakEnglish", "stringToMD5String", "supportCheatEngine", "textToShortCut",
    "unhideMainCEwindow", "unhookWndProc", "unloadLoadedFont", "unmapMemory", "unMapViewOfSection",
    "unpause", "userDataToInteger", "writeProcessMemoryCR3", "writeRegionToFile",
  }
  for _, name in ipairs(stubbed) do
    if rawget(env, name) == nil then def(name, stub(name)) end
  end
  -- @end stubs

  -- CE has capitalised copies of most of these, like ReadInteger
  for _, k in ipairs({ unpack(installed) }) do
    local f = rawget(env, k)
    if type(f) == "function" and k:find("^%l") then
      local upper = k:sub(1, 1):upper() .. k:sub(2)
      if rawget(env, upper) == nil then env[upper] = f end
    end
  end

  -- CE's defines.lua
  for k, v in pairs(M.constants) do
    if rawget(env, k) == nil then env[k] = v end
  end

  -- Stops timers, threads' loops and freezes, for when the table's turned off
  function handle.stop()
    for t in pairs(timers) do t.destroy() end
    for _, r in ipairs(order) do freeze(r, false) end
    due = {}
    if ticking then ticking:cancel() end
    ticking = nil
    for a, p in pairs(breakpoints) do
      p:remove()
      breakpoints[a] = nil
    end
  end

  return handle
end

-- @constants
M.constants = {
  cbUnchecked = 0, cbChecked = 1, cbGrayed = 2, mbLeft = 0, mbRight = 1, mbMiddle = 2, mbExtra1 = 3,
  mbExtra2 = 4, ssNone = 0, ssHorizontal = 1, ssVertical = 2, ssBoth = 3, ssAutoHorizontal = 4,
  ssAutoVertical = 5, ssAutoBoth = 6, bsNone = 0, bsSingle = 1, bsSizeable = 2, bsDialog = 3,
  bsToolWindow = 4, bsSizeToolWin = 5, fsmNotAligned = 0, fsmAligned = 1, fsmLastDigits = 2,
  rtRounded = 0, rtExtremerounded = 1, rtTruncated = 2, soUnknownValue = 0, soExactValue = 1,
  soValueBetween = 2, soBiggerThan = 3, soSmallerThan = 4, soIncreasedValue = 5,
  soIncreasedValueBy = 6, soDecreasedValue = 7, soDecreasedValueBy = 8, soChanged = 9,
  soUnchanged = 10, bpmInt3 = 0, bpmDebugRegister = 1, bpmException = 2, bptExecute = 0,
  bptAccess = 1, bptWrite = 2, co_run = 0, co_stepinto = 1, co_stepover = 2, caNone = 0, caHide = 1,
  caFree = 2, caMinimize = 3, alNone = 0, alTop = 1, alBottom = 2, alLeft = 3, alRight = 4,
  alClient = 5, mtWarning = 0, mtError = 1, mtInformation = 2, mtConfirmation = 3, mbYes = 0,
  mbNo = 1, mbOK = 2, mbCancel = 3, mbAbort = 4, mbRetry = 5, mbIgnore = 6, mbAll = 7,
  mbNoToAll = 8, mbYesToAll = 9, mbHelp = 10, mbClose = 11, mrNone = 0, mrOK = 1, mrCancel = 2,
  mrAbort = 3, mrRetry = 4, mrIgnore = 5, mrYes = 6, mrNo = 7, mrAll = 8, mrNoToAll = 9,
  mrYesToAll = 10, mrLast = 10, dupIgnore = 0, dupAccept = 1, dupError = 2, vtByte = 0, vtWord = 1,
  vtDword = 2, vtQword = 3, vtSingle = 4, vtDouble = 5, vtString = 6, vtUnicodeString = 7,
  vtWideString = 7, vtByteArray = 8, vtBinary = 9, vtAll = 10, vtAutoAssembler = 11, vtPointer = 12,
  vtCustom = 13, vtGrouped = 14, VK_LBUTTON = 1, VK_RBUTTON = 2, VK_CANCEL = 3, VK_MBUTTON = 4,
  VK_XBUTTON1 = 5, VK_XBUTTON2 = 6, VK_BACK = 8, VK_TAB = 9, VK_CLEAR = 12, VK_RETURN = 13,
  VK_SHIFT = 16, VK_CONTROL = 17, VK_MENU = 18, VK_PAUSE = 19, VK_CAPITAL = 20, VK_ESCAPE = 27,
  VK_SPACE = 32, VK_PRIOR = 33, VK_NEXT = 34, VK_END = 35, VK_HOME = 36, VK_LEFT = 37, VK_UP = 38,
  VK_RIGHT = 39, VK_DOWN = 40, VK_SELECT = 41, VK_PRINT = 42, VK_EXECUTE = 43, VK_SNAPSHOT = 44,
  VK_INSERT = 45, VK_DELETE = 46, VK_HELP = 47, VK_0 = 48, VK_1 = 49, VK_2 = 50, VK_3 = 51,
  VK_4 = 52, VK_5 = 53, VK_6 = 54, VK_7 = 55, VK_8 = 56, VK_9 = 57, VK_A = 65, VK_B = 66, VK_C = 67,
  VK_D = 68, VK_E = 69, VK_F = 70, VK_G = 71, VK_H = 72, VK_I = 73, VK_J = 74, VK_K = 75, VK_L = 76,
  VK_M = 77, VK_N = 78, VK_O = 79, VK_P = 80, VK_Q = 81, VK_R = 82, VK_S = 83, VK_T = 84, VK_U = 85,
  VK_V = 86, VK_W = 87, VK_X = 88, VK_Y = 89, VK_Z = 90, VK_LWIN = 91, VK_RWIN = 92, VK_APPS = 93,
  VK_NUMPAD0 = 96, VK_NUMPAD1 = 97, VK_NUMPAD2 = 98, VK_NUMPAD3 = 99, VK_NUMPAD4 = 100,
  VK_NUMPAD5 = 101, VK_NUMPAD6 = 102, VK_NUMPAD7 = 103, VK_NUMPAD8 = 104, VK_NUMPAD9 = 105,
  VK_MULTIPLY = 106, VK_ADD = 107, VK_SEPARATOR = 108, VK_SUBTRACT = 109, VK_DECIMAL = 110,
  VK_DIVIDE = 111, VK_F1 = 112, VK_F2 = 113, VK_F3 = 114, VK_F4 = 115, VK_F5 = 116, VK_F6 = 117,
  VK_F7 = 118, VK_F8 = 119, VK_F9 = 120, VK_F10 = 121, VK_F11 = 122, VK_F12 = 123, VK_F13 = 124,
  VK_F14 = 125, VK_F15 = 126, VK_F16 = 127, VK_F17 = 128, VK_F18 = 129, VK_F19 = 130, VK_F20 = 131,
  VK_F21 = 132, VK_F22 = 133, VK_F23 = 134, VK_F24 = 135, VK_NUMLOCK = 144, VK_SCROLL = 145,
  VK_LSHIFT = 160, VK_LCONTROL = 162, VK_LMENU = 164, VK_RSHIFT = 161, VK_RCONTROL = 163,
  VK_RMENU = 165, VK_OEM1 = 186, VK_OEM2 = 191, VK_OEM3 = 192, SW_HIDE = 0, SW_MAXIMIZE = 3,
  SW_MINIMIZE = 6, SW_NORMAL = 1, SW_RESTORE = 9, SW_SHOW = 5, SW_SHOWDEFAULT = 10,
  SW_SHOWMAXIMIZED = 3, SW_SHOWMINIMIZED = 2, SW_SHOWMINNOACTIVE = 7, SW_SHOWNA = 8,
  SW_SHOWNOACTIVATE = 4, SW_SHOWNORMAL = 1, pfDevice = 0, pf1bit = 1, pf4bit = 2, pf8bit = 3,
  pf15bit = 4, pf16bit = 5, pf24bit = 6, pf32bit = 7, pfCustom = 8, dvtNone = 0, dvtAddress = 1,
  dvtValue = 2, jtCall = 0, jtUnconditional = 1, jtConditional = 2, jtMemory = 3, slStart = 0,
  slNotInt = 1, slNotModule = 2, slNotUserdefinedSymbol = 3, slNotSymbol = 4, slFailure = 5,
  poDesigned = 0, poDefault = 1, poDefaultPosOnly = 2, poDefaultSizeOnly = 3, poScreenCenter = 4,
  poDesktopCenter = 5, poMainFormCenter = 6, poOwnerFormCenter = 7, asrTop = 0, asrBottom = 1,
  asrCenter = 2, asrLeft = 0, asrRight = 1, vsIcon = 0, vsSmallIcon = 1, vsList = 2, vsReport = 3,
  LWA_COLORKEY = 1, LWA_ALPHA = 2, GW_HWNDFIRST = 0, GW_HWNDLAST = 1, GW_HWNDNEXT = 2,
  GW_HWNDPREV = 3, GW_HWNDOWNER = 4, GW_OWNER = 4, GW_CHILD = 5, GW_ENABLEDPOPUP = 6,
  mrhToggleActivation = 0, mrhToggleActivationAllowIncrease = 1,
  mrhToggleActivationAllowDecrease = 2, mrhActivate = 3, mrhDeactivate = 4, mrhSetValue = 5,
  mrhIncreaseValue = 6, mrhDecreaseValue = 7, MOUSEEVENTF_MOVE = 1, MOUSEEVENTF_LEFTDOWN = 2,
  MOUSEEVENTF_LEFTUP = 4, MOUSEEVENTF_RIGHTDOWN = 8, MOUSEEVENTF_RIGHTUP = 16,
  MOUSEEVENTF_MIDDLEDOWN = 32, MOUSEEVENTF_MIDDLEUP = 64, MOUSEEVENTF_XDOWN = 128,
  MOUSEEVENTF_XUP = 256, MOUSEEVENTF_WHEEL = 2048, MOUSEEVENTF_HWHEEL = 4096,
  MOUSEEVENTF_ABSOLUTE = 32768, SPF_DEFAULT = 0, SPF_ASYNC = 1, SPF_PURGEBEFORESPEAK = 2,
  SPF_IS_FILENAME = 4, SPF_IS_XML = 8, SPF_IS_NOT_XML = 16, SPF_PERSIST_XML = 32,
  SPF_NLP_SPEAK_PUNC = 64, SPF_PARSE_SAPI = 128, SPF_PARSE_SSML = 256, SPF_PARSE_AUTODETECT = 0,
  wrSignaled = 0, wrTimeout = 1, wrAbandoned = 2, wrError = 3, fsSurface = 0, fsBorder = 1,
  cdsSelected = 0, cdsGrayed = 1, cdsDisabled = 2, cdsChecked = 3, cdsFocused = 4, cdsDefault = 5,
  cdsHot = 6, cdsMarked = 7, cdsIndeterminate = 8, cdPrePaint = 0, cdPostPaint = 1, cdPreErase = 2,
  cdPostErase = 3, drBounds = 0, drIcon = 1, drLabel = 2, drSelectBounds = 3, fmCreate = 65280,
  fmOpenRead = 0, fmOpenWrite = 1, fmOpenReadWrite = 2, fmShareCompat = 0, fmShareExclusive = 16,
  fmShareDenyWrite = 32, fmShareDenyRead = 48, fmShareDenyNone = 64, crDefault = 0, crNone = -1,
  crArrow = -2, crCross = -3, crIBeam = -4, crSize = -22, crSizeNESW = -6, crSizeNS = -7,
  crSizeNWSE = -8, crSizeWE = -9, crSizeNW = -23, crSizeN = -24, crSizeNE = -25, crSizeW = -26,
  crSizeE = -27, crSizeSW = -28, crSizeS = -29, crSizeSE = -30, crUpArrow = -10, crHourGlass = -11,
  crDrag = -12, crNoDrop = -13, crHSplit = -14, crVSplit = -15, crMultiDrag = -16, crSQLWait = -17,
  crNo = -18, crAppStart = -19, crHelp = -20, crHandPoint = -21, crSizeAll = -22,
  CLR_NONE = 4294967295, CLR_DEFAULT = 4278190080, CLR_INVALID = 4294967295, COLOR_SCROLLBAR = 0,
  COLOR_BACKGROUND = 1, COLOR_ACTIVECAPTION = 2, COLOR_INACTIVECAPTION = 3, COLOR_MENU = 4,
  COLOR_WINDOW = 5, COLOR_WINDOWFRAME = 6, COLOR_MENUTEXT = 7, COLOR_WINDOWTEXT = 8,
  COLOR_CAPTIONTEXT = 9, COLOR_ACTIVEBORDER = 10, COLOR_INACTIVEBORDER = 11,
  COLOR_APPWORKSPACE = 12, COLOR_HIGHLIGHT = 13, COLOR_HIGHLIGHTTEXT = 14, COLOR_BTNFACE = 15,
  COLOR_BTNSHADOW = 16, COLOR_GRAYTEXT = 17, COLOR_BTNTEXT = 18, COLOR_INACTIVECAPTIONTEXT = 19,
  COLOR_BTNHIGHLIGHT = 20, COLOR_3DDKSHADOW = 21, COLOR_3DLIGHT = 22, COLOR_INFOTEXT = 23,
  COLOR_INFOBK = 24, COLOR_HOTLIGHT = 26, COLOR_GRADIENTACTIVECAPTION = 27,
  COLOR_GRADIENTINACTIVECAPTION = 28, COLOR_MENUHILIGHT = 29, COLOR_MENUBAR = 30, COLOR_FORM = 31,
  COLOR_ENDCOLORS = 31, COLOR_DESKTOP = 1, COLOR_3DFACE = 15, COLOR_3DSHADOW = 16,
  COLOR_3DHIGHLIGHT = 20, COLOR_3DHILIGHT = 20, COLOR_BTNHILIGHT = 20, MAX_SYS_COLORS = 31,
  SYS_COLOR_BASE = 2147483648, clBlack = 0, clMaroon = 128, clGreen = 32768, clOlive = 32896,
  clNavy = 8388608, clPurple = 8388736, clTeal = 8421376, clGray = 8421504, clSilver = 12632256,
  clOrange = 33023, clRed = 255, clLime = 65280, clYellow = 65535, clBlue = 16711680,
  clFuchsia = 16711935, clAqua = 16776960, clLtGray = 12632256, clDkGray = 8421504,
  clWhite = 16777215, StandardColorsCount = 16, clMoneyGreen = 12639424, clSkyBlue = 15780518,
  clCream = 15793151, clMedGray = 10789024, ExtendedColorCount = 4, clNone = 536870911,
  clDefault = 536870912, clScrollBar = 2147483648, clBackground = 2147483649,
  clActiveCaption = 2147483650, clInactiveCaption = 2147483651, clMenu = 2147483652,
  clWindowFrame = 2147483654, clMenuText = 2147483655, clCaptionText = 2147483657,
  clActiveBorder = 2147483658, clInactiveBorder = 2147483659, clAppWorkspace = 2147483660,
  clHighlight = 2147483661, clHighlightText = 2147483662, clBtnFace = 2147483663,
  clBtnShadow = 2147483664, clGrayText = 2147483665, clBtnText = 2147483666,
  clInactiveCaptionText = 2147483667, clBtnHighlight = 2147483668, cl3DDkShadow = 2147483669,
  cl3DLight = 2147483670, clInfoText = 2147483671, clInfoBk = 2147483672, clHotLight = 2147483674,
  clGradientActiveCaption = 2147483675, clGradientInactiveCaption = 2147483676,
  clMenuHighlight = 2147483677, clMenuBar = 2147483678, clForm = 2147483679,
  clColorDesktop = 2147483649, cl3DFace = 2147483663, cl3DShadow = 2147483664,
  cl3DHiLight = 2147483668, clBtnHiLight = 2147483668, clFirstSpecialColor = 2147483668,
  clMask = 16777215, clDontMask = 0, pmBlack = 0, pmWhite = 1, pmNop = 2, pmNot = 3, pmCopy = 4,
  pmNotCopy = 5, pmMergePenNot = 6, pmMaskPenNot = 7, pmMergeNotPen = 8, pmMaskNotPen = 9,
  pmMerge = 10, pmNotMerge = 11, pmMask = 12, pmNotMask = 13, pmXor = 14, pmNotXor = 15,
  tbpsNone = 0, tbpsIndeterminate = 1, tbpsNormal = 2, tbpsError = 3, tbpsPaused = 4,
  PAGE_READONLY = 2, PAGE_READWRITE = 4, PAGE_WRITECOPY = 8, PAGE_EXECUTE = 16,
  PAGE_EXECUTE_READ = 32, PAGE_EXECUTE_READWRITE = 64, PAGE_EXECUTE_WRITECOPY = 128, DT_UNKNOWN = 0,
  DT_FIFO = 1, DT_CHR = 2, DT_DIR = 4, DT_BLK = 6, DT_REG = 8, DT_LNK = 10, DT_SOCK = 12,
  DT_WHT = 14,
}
-- @end constants

return M
