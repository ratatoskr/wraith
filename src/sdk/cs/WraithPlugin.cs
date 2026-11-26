// Wraith's SDK for C# plugins. Derive from WraithPlugin and return it from Entry.Create:
//
//     namespace Wraith { static partial class Entry { internal static partial WraithPlugin Create() => new MyPlugin(); } }
//
// Runs the same JIT'd or NativeAOT. Areas are each one's Instance, like Wraith.Tweaks.Instance.

#nullable enable

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Salamander;

namespace Wraith;

/// <summary>What a C# plugin is. Make one from it, and have Entry.Create give one.</summary>
public abstract class WraithPlugin
{
    /// <summary>Once, as it loads. Throwing means it didn't start, and the log says why.</summary>
    public abstract void Start(Context context);

    /// <summary>As it unloads. What it gave Wraith, like hooks and settings, goes after this by itself.</summary>
    public virtual void Stop() { }

    /// <summary>Its object for a [Service] trait by name, like Freecam.Camera.From(new MyCamera()).Raw.AsObject().</summary>
    public virtual AnyObject Service(string trait) => default;
}

/// <summary>What a plugin gets as it starts.</summary>
public sealed class Context
{
    readonly Raw.Wraith_Plugin_Service[] services;

    internal Context(Raw.Wraith_Plugin_Service[] services)
    {
        this.services = services;
    }

    /// <summary>What a dependency offers as [Service] trait T, or null. T.Instance throws instead.</summary>
    public T? Service<T>(string plugin) where T : class, ITrait<T>
    {
        foreach (var s in services)
        {
            if (s.plugin.ToString() == plugin && s.trait.ToString() == T.TraitName) return T.FromObject(s.obj);
        }
        return null;
    }
}

/// <summary>Typed hooks on what the schemas declare, like the other languages have.</summary>
public partial class Hooks
{
    /// <summary>Hooks a schema function, like GameStateManager.Fns.SpendMira, with (hook, self, amount) => ...</summary>
    public Hook Hook<H, W>(DeclaredFunction<H, W> target, H handler, Hook.Options? options = null) where H : Delegate where W : Delegate =>
        Named(target.Name, target.Lower(handler), options ?? new())!;

    public Hook Hook<H, W>(DeclaredFunction<H, W> target, W handler, Hook.Options? options = null) where H : Delegate where W : Delegate
    {
        var cell = new HookCell { Context = options?.Context ?? 0 };
        return Ready(Named(target.Name, target.Lower(handler, cell), Off(options))!, cell, options);
    }

    /// <summary>The same at an address of your own, typed like target.</summary>
    public Hook HookAt<H, W>(nuint address, DeclaredFunction<H, W> target, H handler, Hook.Options? options = null) where H : Delegate where W : Delegate =>
        Detour(address, target.Name, target.Lower(handler), options ?? new())!;

    public Hook HookAt<H, W>(nuint address, DeclaredFunction<H, W> target, W handler, Hook.Options? options = null) where H : Delegate where W : Delegate
    {
        var cell = new HookCell { Context = options?.Context ?? 0 };
        return Ready(Detour(address, target.Name, target.Lower(handler, cell), Off(options))!, cell, options);
    }

    // Made off, so nothing calls the handler before it knows the original
    static Hook.Options Off(Hook.Options? options) => new() { Context = options?.Context ?? 0, Disabled = true };

    static Hook Ready(Hook made, HookCell cell, Hook.Options? options)
    {
        cell.Original = made.Original();
        if (options?.Disabled != true) made.Enable();
        return made;
    }
}

/// <summary>Where Wraith starts the plugin, the same for the cs kind and NativeAOT.</summary>
public static unsafe partial class Entry
{
    /// <summary>The plugin, which its own code gives with a partial of Entry.</summary>
    internal static partial WraithPlugin Create();

    /// <summary>What a native plugin's `wraith_plugin` gives, see NativeEntry in Wraith's api.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct NativeEntry
    {
        public uint version;
        public delegate* unmanaged[Cdecl]<Salamander.Raw.Host, NativeGuest, Bool> start;
        public delegate* unmanaged[Cdecl]<void> stop;
        public delegate* unmanaged[Cdecl]<Str, AnyObject> service;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NativeGuest
    {
        public AnyObject wraith;
        public Owner* owner;
        public Salamander.Raw.Queue render_queue;
        public Raw.Wraith_Plugin_Service* services;
        public nuint services_len;
    }

    /// <summary>Only changes when Wraith's NativeEntry does.</summary>
    const uint NativeVersion = 2;

    static NativeEntry* entry;
    static WraithPlugin? plugin;
    static Api? wraith;

    /// <summary>What Wraith calls first. Exported by NativeAOT, and called by the cs kind.</summary>
    [UnmanagedCallersOnly(EntryPoint = "wraith_plugin", CallConvs = [typeof(CallConvCdecl)])]
    public static NativeEntry* Get()
    {
        if (entry == null)
        {
            var e = (NativeEntry*)NativeMemory.AllocZeroed((nuint)sizeof(NativeEntry));
            e->version = NativeVersion;
            e->start = &Start;
            e->stop = &Stop;
            e->service = &Service;
            entry = e;
        }
        return entry;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static Bool Start(Salamander.Raw.Host host, NativeGuest guest)
    {
        try
        {
            Runtime.Init(host, guest.owner);
            wraith = Api.FromRaw(Raw.Wraith_Api.FromObject(guest.wraith));
            if (wraith == null) return false;
            Api.Instance = wraith;
            var schema = wraith.Schema();
            Declared.Locator = name => schema?.Address(name) ?? 0;
            Abi.OnException = e => Log(Wraith.Log.Level.Err, e.ToString());
            // Only good while starting, so they're copied
            var services = new Raw.Wraith_Plugin_Service[(int)guest.services_len];
            for (var i = 0; i < services.Length; i++)
            {
                services[i] = guest.services[i];
                // So Freecam.Camera.Instance and the like give them
                Singletons.Set(services[i].trait.ToString(), services[i].obj);
            }
            plugin = Create();
            plugin.Start(new Context(services));
            return true;
        }
        catch (Exception e)
        {
            Log(Wraith.Log.Level.Err, $"Couldn't start: {e}");
            return false;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static void Stop()
    {
        try
        {
            plugin?.Stop();
        }
        catch (Exception e)
        {
            Log(Wraith.Log.Level.Err, $"Couldn't stop: {e}");
        }
        plugin = null;
        wraith = null;
        Api.Instance = null;
        Singletons.Clear();
        Declared.Locator = null;
        Abi.OnException = null;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    static AnyObject Service(Str trait)
    {
        try
        {
            return plugin?.Service(trait.ToString()) ?? default;
        }
        catch (Exception e)
        {
            Log(Wraith.Log.Level.Err, $"Couldn't offer {trait}: {e}");
            return default;
        }
    }

    static void Log(Wraith.Log.Level level, string message) => wraith?.Log()?.Write(level, "", message);
}
