// Three tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
using Wraith;

namespace ExampleCsAot
{
    sealed unsafe class Example : WraithPlugin
    {
        Hook? freeShopping;
        delegate* unmanaged[Cdecl]<GameStateManager*, uint, uint> spendMira;
        uint amount = 10000;
        Patch[] tailing = [];

        public override void Start(Context context)
        {
            var tweaks = Tweaks.Instance;

            // Shops still take your Mira, just none of it
            freeShopping = Hooks.Instance.Named("GameStateManager.spendMira", GameStateManager.SpendMiraHandler((self, _) => spendMira(self, 0)), new Hook.Options { Disabled = true })!;
            spendMira = GameStateManager.SpendMiraAt(freeShopping.Original());
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
        }
    }
}

namespace Wraith
{
    // The plugin Wraith starts
    static partial class Entry
    {
        internal static partial WraithPlugin Create() => new ExampleCsAot.Example();
    }
}