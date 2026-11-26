// Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
using Wraith;

namespace ExampleCsClr
{
    sealed unsafe class Example : WraithPlugin
    {
        Hook? freeShopping;
        uint amount = 10000;
        Patch[] tailing = [];
        float speed = 0.25f;

        public override void Start(Context context)
        {
            var tweaks = Tweaks.Instance;

            // Shops still take your Mira, just none of it
            freeShopping = Hooks.Instance.Hook(GameStateManager.Fns.SpendMira, (hook, self, _) => hook.Original()(self, 0), new Hook.Options { Disabled = true });
            tweaks.AddHook("Money", new Tweaks.Definition { Id = "free_shopping", Title = "Free shopping" }, freeShopping);

            // Each field comes as a Changed just before it runs
            var give = new Tweaks.Definition
            {
                Id = "give_mira",
                Title = "Give Mira",
                Mode = Tweaks.Mode.Action,
                Fields = [new Tweaks.Field { Name = "amount", Type = Tweaks.FieldType.U32, Value = amount, HasMin = true, Min = 1 }],
            };
            tweaks.AddIn("Money", give, e =>
            {
                if (e.Kind == Tweaks.EventKind.Changed) amount = (uint)e.Value;
                // Throws before a save's loaded, and the overlay shows why
                else if (e.Kind == Tweaks.EventKind.On) GameStateManager.InstanceOrFail()->GiveMira(amount);
            });

            // Being seen needs the gauge full, so skip both. Expect stops it patching a game that changed
            var code = Code.Instance;
            tailing =
            [
                code.PatchBytes(Schema.Addresses.TailingSeen(), [0xEB], new Patch.Options { Expect = "76", Disabled = true })!,
                code.PatchBytes(Schema.Addresses.TailingGauge(), [0xEB, 0x02], new Patch.Options { Expect = "F3 0F 5F FE", Disabled = true })!,
            ];
            tweaks.AddIn("Field", new Tweaks.Definition { Id = "tailing_stealth", Title = "Tailing without being seen" }, e =>
            {
                if (e.Kind == Tweaks.EventKind.On) foreach (var p in tailing) p.Enable();
                else if (e.Kind == Tweaks.EventKind.Off) foreach (var p in tailing) p.Disable();
            });

            // Or let it fill, slower. A mid hook runs with the registers right there in the game's code
            var slowGauge = Hooks.Instance.Mid(Schema.Addresses.TailingGaugeStore(), new Hooks.MidOptions { Expect = "F3 0F 11 BF D4 00 00 00", Disabled = true }, (ref Cpu cpu) =>
            {
                // xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept
                var state = (TailingState*)cpu.Rdi;
                cpu.Xmm7.F32x4[0] = state->Gauge + (cpu.Xmm7.F32x4[0] - state->Gauge) * speed;
            })!;
            var slow = new Tweaks.Definition
            {
                Id = "slow_tailing_gauge",
                Title = "Slower tailing gauge",
                Fields = [new Tweaks.Field { Name = "speed", Type = Tweaks.FieldType.F32, Value = speed, HasMin = true, Min = 0, HasMax = true, Max = 1 }],
            };
            tweaks.AddIn("Field", slow, e =>
            {
                if (e.Kind == Tweaks.EventKind.Changed) speed = (float)e.Value;
                else if (e.Kind == Tweaks.EventKind.On) slowGauge.Enable();
                else if (e.Kind == Tweaks.EventKind.Off) slowGauge.Disable();
            });
        }
    }
}

namespace Wraith
{
    // The plugin Wraith starts
    static partial class Entry
    {
        internal static partial WraithPlugin Create() => new ExampleCsClr.Example();
    }
}