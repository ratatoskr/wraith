// Three tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
import { code, hooks, schema, tweaks } from "wraith";
import { fn, native } from "salamander";
import { GameStateManager, TweakEventKind } from "schema";

// Shops still take your Mira, just none of it
let spendMira: (self: GameStateManager, amount: number) => number;
const freeShopping = hooks.named(
    "GameStateManager.spendMira",
    fn("GameStateManager.spendMira", (self: GameStateManager, _amount: number) => spendMira(self, 0)),
    { disabled: true },
);
spendMira = native("GameStateManager.spendMira", freeShopping.original());

tweaks.addIn("Money", { id: "free_shopping", title: "Free shopping" }, (event) => {
    if (event.kind === TweakEventKind.on) freeShopping.enable();
    else if (event.kind === TweakEventKind.off) freeShopping.disable();
});

// Each field comes as a `changed` just before it runs
let amount = 10000;
tweaks.addIn(
    "Money",
    { id: "give_mira", title: "Give Mira", mode: "action", fields: [{ name: "amount", type: "u32", value: amount, has_min: true, min: 1 }] },
    (event) => {
        if (event.kind === TweakEventKind.changed) amount = event.value ?? amount;
        else if (event.kind === TweakEventKind.on) {
            const manager = GameStateManager.instance;
            // The overlay shows why it didn't run
            if (!manager) throw new Error("Load a save first");
            manager.giveMira(amount);
        }
    },
);

// Being seen needs the gauge full, so skip both. `expect` stops it patching a game that changed
const tailing = [
    code.patchBytes(schema.address("tailing_seen"), [0xeb], { expect: "76", disabled: true }),
    code.patchBytes(schema.address("tailing_gauge"), [0xeb, 0x02], { expect: "F3 0F 5F FE", disabled: true }),
];
tweaks.addIn("Field", { id: "tailing_stealth", title: "Tailing without being seen" }, (event) => {
    if (event.kind === TweakEventKind.on) for (const p of tailing) p.enable();
    else if (event.kind === TweakEventKind.off) for (const p of tailing) p.disable();
});