-- Three tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
local wraith = require("wraith")
local sal = require("salamander")
local game = require("schema")

local on, off, changed = game.TweakEventKind.on, game.TweakEventKind.off, game.TweakEventKind.changed

-- Shops still take your Mira, just none of it
local spend_mira
local free_shopping = wraith.hooks:named("GameStateManager.spendMira", sal.fn("GameStateManager.spendMira", function(self, _)
  return spend_mira(self, 0)
end), { disabled = true })
spend_mira = sal.native("GameStateManager.spendMira", free_shopping:original())

wraith.tweaks:addIn("Money", { id = "free_shopping", title = "Free shopping" }, function(event)
  if event.kind == on then free_shopping:enable()
  elseif event.kind == off then free_shopping:disable() end
end)

-- Each field comes as a `changed` just before it runs
local amount = 10000
wraith.tweaks:addIn("Money", {
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
local tailing = {
  wraith.code:patchBytes(wraith.schema:address("tailing_seen"), "\xEB", { expect = "76", disabled = true }),
  wraith.code:patchBytes(wraith.schema:address("tailing_gauge"), "\xEB\x02", { expect = "F3 0F 5F FE", disabled = true }),
}
wraith.tweaks:addIn("Field", { id = "tailing_stealth", title = "Tailing without being seen" }, function(event)
  if event.kind == on then
    for _, p in ipairs(tailing) do p:enable() end
  elseif event.kind == off then
    for _, p in ipairs(tailing) do p:disable() end
  end
end)