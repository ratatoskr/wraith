// The C# plugin the `cs` kind's tests load. Each load gets its own context, so its statics start over.
using Ratatoskr.Wraith;
using Salamander;

namespace CsFixture
{
    sealed class Counter : ICsService
    {
        // Static, so a context shared between loads would keep counting
        static uint n;
        public uint Next() => ++n;
    }

    sealed class Fixture : WraithPlugin
    {
        readonly Counter counter = new();

        public override void Start(Context context)
        {
            // Through its root, like any plugin
            if (context.Wraith.Hooks() == null) throw new System.InvalidOperationException("no hooks");
        }

        public override AnyObject Service(string trait) => trait == CsService.TraitName ? CsService.From(counter).Raw.AsObject() : default;
    }
}

namespace Ratatoskr.Wraith
{
    static partial class Entry
    {
        internal static partial WraithPlugin Create() => new CsFixture.Fixture();
    }
}