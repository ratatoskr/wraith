-- Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
local wraith = require("wraith")
local Wraith, game = wraith.Wraith, wraith.ExampleLua
local tweaks = Wraith.tweaks()

local on, off, changed = Wraith.Tweaks.EventKind.on, Wraith.Tweaks.EventKind.off, Wraith.Tweaks.EventKind.changed

-- Shops still take your Mira, just none of it
local free_shopping = Wraith.hooks():hook(game.GameStateManager.spendMira, function(hook, self, _)
  return hook.original()(self, 0)
end, { disabled = true })
tweaks:addHook("Money", { id = "free_shopping", title = "Free shopping" }, free_shopping)

-- Each field comes as a `changed` just before it runs
local amount = 10000
tweaks:addIn("Money", {
  id = "give_mira",
  title = "Give Mira",
  mode = "action",
  fields = { { name = "amount", type = "u32", value = amount, has_min = true, min = 1 } },
}, function(event)
  if event.kind == changed then
    amount = event.value
  elseif event.kind == on then
    local manager = game.GameStateManager.instance
    -- The overlay shows why it didn't run
    if not manager then error("Load a save first") end
    manager:giveMira(amount)
  end
end)

-- Being seen needs the gauge full, so skip both. `expect` stops it patching a game that changed
local code = Wraith.code()
local tailing = {
  code:patchBytes(game.addresses.tailing_seen(), "\xEB", { expect = "76", disabled = true }),
  code:patchBytes(game.addresses.tailing_gauge(), "\xEB\x02", { expect = "F3 0F 5F FE", disabled = true }),
}
tweaks:addIn("Field", { id = "tailing_stealth", title = "Tailing without being seen" }, function(event)
  if event.kind == on then
    for _, p in ipairs(tailing) do p:enable() end
  elseif event.kind == off then
    for _, p in ipairs(tailing) do p:disable() end
  end
end)

-- Or let it fill, slower. A mid hook runs with the registers right there in the game's code
local speed = 0.25
local slow_gauge = Wraith.hooks():mid(game.addresses.tailing_gauge_store(), { expect = "F3 0F 11 BF D4 00 00 00", disabled = true }, function(cpu)
  -- xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept
  local state = game.TailingState.at(cpu.rdi)
  if state then cpu.xmm7.f32x4[1] = state.gauge + (cpu.xmm7.f32x4[1] - state.gauge) * speed end
end)
tweaks:addIn("Field", {
  id = "slow_tailing_gauge",
  title = "Slower tailing gauge",
  fields = { { name = "speed", type = "f32", value = speed, has_min = true, min = 0, has_max = true, max = 1 } },
}, function(event)
  if event.kind == changed then
    speed = event.value
  elseif event.kind == on then
    slow_gauge:enable()
  elseif event.kind == off then
    slow_gauge:disable()
  end
end)