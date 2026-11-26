// Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
import { Wraith, ExampleTs } from "wraith";

const { GameStateManager, TailingState } = ExampleTs;
const { EventKind } = Wraith.Tweaks;
const tweaks = Wraith.tweaks();

// Shops still take your Mira, just none of it
const freeShopping = Wraith.hooks().hook(GameStateManager.spendMira, (self, _amount, hook) => hook.original()(self, 0), { disabled: true });
tweaks.addHook("Money", { id: "free_shopping", title: "Free shopping" }, freeShopping);

// Each field comes as a `changed` just before it runs
let amount = 10000;
tweaks.addIn(
    "Money",
    { id: "give_mira", title: "Give Mira", mode: "action", fields: [{ name: "amount", type: "u32", value: amount, has_min: true, min: 1 }] },
    (event) => {
        if (event.kind === EventKind.changed) amount = event.value ?? amount;
        else if (event.kind === EventKind.on) {
            const manager = GameStateManager.instance;
            // The overlay shows why it didn't run
            if (!manager) throw new Error("Load a save first");
            manager.giveMira(amount);
        }
    },
);

// Being seen needs the gauge full, so skip both. `expect` stops it patching a game that changed
const code = Wraith.code();
const tailing = [
    code.patchBytes(ExampleTs.addresses.tailing_seen(), [0xeb], { expect: "76", disabled: true }),
    code.patchBytes(ExampleTs.addresses.tailing_gauge(), [0xeb, 0x02], { expect: "F3 0F 5F FE", disabled: true }),
];
tweaks.addIn("Field", { id: "tailing_stealth", title: "Tailing without being seen" }, (event) => {
    if (event.kind === EventKind.on) for (const p of tailing) p.enable();
    else if (event.kind === EventKind.off) for (const p of tailing) p.disable();
});

// Or let it fill, slower. A mid hook runs with the registers right there in the game's code
let speed = 0.25;
const slowGauge = Wraith.hooks().mid(ExampleTs.addresses.tailing_gauge_store(), { expect: "F3 0F 11 BF D4 00 00 00", disabled: true }, (cpu) => {
    // xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept
    const state = TailingState.at(cpu.rdi);
    if (state) cpu.xmm7.f32x4[0] = state.gauge + (cpu.xmm7.f32x4[0] - state.gauge) * speed;
});
tweaks.addIn(
    "Field",
    { id: "slow_tailing_gauge", title: "Slower tailing gauge", fields: [{ name: "speed", type: "f32", value: speed, has_min: true, min: 0, has_max: true, max: 1 }] },
    (event) => {
        if (event.kind === EventKind.changed) speed = event.value ?? speed;
        else if (event.kind === EventKind.on) slowGauge.enable();
        else if (event.kind === EventKind.off) slowGauge.disable();
    },
);