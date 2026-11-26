// Typed hooks for JS scripts, as methods on Wraith.Hooks. The handler gets the hooked function's
// arguments, and a parameter named `hook` or `context` gets that instead, wherever it is.
(() => {
    const { fn, native, nameOf, params } = require("salamander");

    function nameFor(target) {
        const name = nameOf(target);
        if (name === undefined) throw new TypeError("hook takes a function the schemas declare, like GameStateManager.spendMira");
        return name;
    }

    function make(name, handler, options, create) {
        if (typeof handler !== "function") throw new TypeError("hook takes a handler function");
        const context = options?.context ?? 0;
        let made;
        let original;
        const view = {
            original: () => original,
            context,
            enable: () => made.enable(),
            disable: () => made.disable(),
            destroy: () => made.destroy(),
        };
        // 1 for the hook, 2 for the context, 0 for the next argument
        const plan = params(handler).map((n) => (n === "hook" ? 1 : n === "context" ? 2 : 0));
        const plain = plan.every((p) => p === 0);
        const call = plain ? handler : (...args) => {
            const out = [];
            let i = 0;
            for (const p of plan) out.push(p === 1 ? view : p === 2 ? context : args[i++]);
            while (i < args.length) out.push(args[i++]);
            return handler(...out);
        };
        // Made off, so nothing calls the handler before it knows the original
        made = create(fn(name, call), { context, disabled: true });
        original = native(name, made.original());
        if (!options?.disabled) made.enable();
        return made;
    }

    return {
        /** Hooks a function the schemas declare, like `GameStateManager.spendMira`. */
        hook(target, handler, options) {
            const name = nameFor(target);
            return make(name, handler, options, (f, o) => this.named(name, f, o));
        },
        /** The same at an address of your own, typed like `target`. */
        hookAt(address, target, handler, options) {
            const name = nameFor(target);
            return make(name, handler, options, (f, o) => this.detour(address, name, f, o));
        },
    };
})()
