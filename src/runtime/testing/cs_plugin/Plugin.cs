// The C# plugin the `cs` kind's tests load. Each load gets its own context, so its statics start over.
using Wraith;
using Salamander;

namespace CsFixture
{
    sealed class Counter : ICsService
    {
        // Static, so a context shared between loads would keep counting
        static uint n;
        public uint Next() => ++n;
    }

    sealed unsafe class Fixture : WraithPlugin
    {
        readonly Counter counter = new();

        public override void Start(Context context)
        {
            // Through its areas' Instance, like any plugin. It throws if there are none
            var hooks = Hooks.Instance;
            // One more than it gives. The test plants it
            hooks.Hook(CsFixture.Schema.Fns.Seven, (hook, x) => hook.Original()(x) + 1);
        }

        public override AnyObject Service(string trait) => trait == CsService.TraitName ? CsService.From(counter).Raw.AsObject() : default;
    }
}

namespace Wraith
{
    static partial class Entry
    {
        internal static partial WraithPlugin Create() => new CsFixture.Fixture();
    }
}