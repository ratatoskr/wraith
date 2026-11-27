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

    // The Notes tab, many at once, which the loader's tests call like the Workbench does
    sealed class Notes : IWorkbenchTab
    {
        uint made, drawn;

        public WorkbenchTab.Info Describe() => new() { Title = "Notes", Kind = "notes", Place = WorkbenchPanel.Place.Bottom, Multi = true };
        public void Draw(string id) => drawn++;
        // Not saved
        public WorkbenchTab.State Status(string id) => new() { Title = $"Note {id} drawn {drawn}", Unsaved = true };
        public string Create() => (++made).ToString();
        // The first stays open
        public bool KeepOpen(string id) => id == "1";
    }

    // Only what it needs: the rest are the interface's defaults
    sealed class Plain : IWorkbenchTab
    {
        public uint drawn;
        public WorkbenchTab.Info Describe() => new() { Title = "Plain", Kind = "plain" };
        public void Draw(string id) => drawn++;
    }

    sealed unsafe class Fixture : WraithPlugin
    {
        readonly Counter counter = new();
        readonly Notes notes = new();
        readonly Plain plain = new();

        public override void Start(Context context)
        {
            // Through its areas' Instance, like any plugin. It throws if there are none
            var hooks = Hooks.Instance;
            // One more than it gives. The test plants it
            hooks.Hook(CsFixture.Schema.Fns.Seven, (hook, x) => hook.Original()(x) + 1);
            Ui.Instance.AddWorkbenchTab(WorkbenchTab.From(notes));
            Ui.Instance.AddWorkbenchTab(WorkbenchTab.From(plain));
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