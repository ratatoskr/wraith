-- Typed hooks for Lua scripts, as methods on Wraith.Hooks. The handler gets the hooked function's
-- arguments, and a parameter named `hook` or `context` gets that instead, wherever it is.
local sal = require("salamander")

local function nameFor(target)
  local name = sal.nameOf(target)
  if name == nil then error("hook takes a function the schemas declare, like GameStateManager.spendMira", 3) end
  return name
end

local function make(name, handler, options, create)
  if type(handler) ~= "function" then error("hook takes a handler function", 3) end
  local context = options and options.context or 0
  local made, original
  local view = {
    original = function() return original end,
    context = context,
    enable = function() return made:enable() end,
    disable = function() return made:disable() end,
    destroy = function() return made:destroy() end,
  }
  -- 1 for the hook, 2 for the context, 0 for the next argument
  local plan, plain = {}, true
  for i, n in ipairs(sal.params(handler)) do
    plan[i] = (n == "hook" and 1) or (n == "context" and 2) or 0
    if plan[i] ~= 0 then plain = false end
  end
  local call = handler
  if not plain then
    call = function(...)
      local args, out, j = table.pack(...), {}, 1
      for k, p in ipairs(plan) do
        if p == 1 then
          out[k] = view
        elseif p == 2 then
          out[k] = context
        else
          out[k] = args[j]
          j = j + 1
        end
      end
      local n = #plan
      for k = j, args.n do
        n = n + 1
        out[n] = args[k]
      end
      return handler(table.unpack(out, 1, n))
    end
  end
  -- Made off, so nothing calls the handler before it knows the original
  made = create(sal.fn(name, call), { context = context, disabled = true })
  original = sal.native(name, made:original())
  if not (options and options.disabled) then made:enable() end
  return made
end

return {
  -- Hooks a function the schemas declare, like `GameStateManager.spendMira`.
  hook = function(self, target, handler, options)
    local name = nameFor(target)
    return make(name, handler, options, function(f, o) return self:named(name, f, o) end)
  end,
  -- The same at an address of your own, typed like `target`.
  hookAt = function(self, address, target, handler, options)
    local name = nameFor(target)
    return make(name, handler, options, function(f, o) return self:detour(address, name, f, o) end)
  end,
}
