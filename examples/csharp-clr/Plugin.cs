// Three tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
using Ratatoskr.Wraith;

namespace ExampleCsClr
{
    sealed unsafe class Example : WraithPlugin
    {
        Hook? freeShopping;
        delegate* unmanaged[Cdecl]<GameStateManager*, uint, uint> spendMira;
        uint amount = 10000;
        Patch[] tailing = [];

        public override void Start(Context context)
        {
            var wraith = context.Wraith;
            var tweaks = wraith.Tweaks()!;

            // Shops still take your Mira, just none of it
            freeShopping = wraith.Hooks()!.Named("GameStateManager.spendMira", GameStateManager.SpendMiraHandler((self, _) => spendMira(self, 0)), new HookOptions { Disabled = true })!;
            spendMira = GameStateManager.SpendMiraAt(freeShopping.Original());
            tweaks.AddIn("Money", new TweakDefinition { Id = "free_shopping", Title = "Free shopping" }, e =>
            {
                if (e.Kind == TweakEventKind.On) freeShopping.Enable();
                else if (e.Kind == TweakEventKind.Off) freeShopping.Disable();
            });

            // Each field comes as a Changed just before it runs
            var give = new TweakDefinition
            {
                Id = "give_mira",
                Title = "Give Mira",
                Mode = TweakMode.Action,
                Fields = [new TweakField { Name = "amount", Type = TweakFieldType.U32, Value = amount, HasMin = true, Min = 1 }],
            };
            tweaks.AddIn("Money", give, e =>
            {
                if (e.Kind == TweakEventKind.Changed) amount = (uint)e.Value;
                // Throws before a save's loaded, and the overlay shows why
                else if (e.Kind == TweakEventKind.On) GameStateManager.InstanceOrFail()->GiveMira(amount);
            });

            // Being seen needs the gauge full, so skip both. Expect stops it patching a game that changed
            var code = wraith.Code()!;
            tailing =
            [
                code.PatchBytes(Schema.Addresses.TailingSeen(), [0xEB], new PatchOptions { Expect = "76", Disabled = true })!,
                code.PatchBytes(Schema.Addresses.TailingGauge(), [0xEB, 0x02], new PatchOptions { Expect = "F3 0F 5F FE", Disabled = true })!,
            ];
            tweaks.AddIn("Field", new TweakDefinition { Id = "tailing_stealth", Title = "Tailing without being seen" }, e =>
            {
                if (e.Kind == TweakEventKind.On) foreach (var p in tailing) p.Enable();
                else if (e.Kind == TweakEventKind.Off) foreach (var p in tailing) p.Disable();
            });
        }
    }
}

namespace Ratatoskr.Wraith
{
    // The plugin Wraith starts
    static partial class Entry
    {
        internal static partial WraithPlugin Create() => new ExampleCsClr.Example();
    }
}