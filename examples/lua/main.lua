-- Three tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
local sal = require("salamander")
local game = ExampleLua
local tweaks = Wraith.tweaks()

local on, off, changed = Wraith.Tweaks.EventKind.on, Wraith.Tweaks.EventKind.off, Wraith.Tweaks.EventKind.changed

-- Shops still take your Mira, just none of it
local spend_mira
local free_shopping = Wraith.hooks():named("GameStateManager.spendMira", sal.fn("GameStateManager.spendMira", function(self, _)
  return spend_mira(self, 0)
end), { disabled = true })
spend_mira = sal.native("GameStateManager.spendMira", free_shopping:original())

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
local code, schema = Wraith.code(), Wraith.schema()
local tailing = {
  code:patchBytes(schema:address("tailing_seen"), "\xEB", { expect = "76", disabled = true }),
  code:patchBytes(schema:address("tailing_gauge"), "\xEB\x02", { expect = "F3 0F 5F FE", disabled = true }),
}
tweaks:addIn("Field", { id = "tailing_stealth", title = "Tailing without being seen" }, function(event)
  if event.kind == on then
    for _, p in ipairs(tailing) do p:enable() end
  elseif event.kind == off then
    for _, p in ipairs(tailing) do p:disable() end
  end
end)