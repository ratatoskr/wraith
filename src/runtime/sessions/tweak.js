// Runs `.rwt` tweaks compiled into calls on `__t`, one per tweak line so errors say the tweak's line.
// Code changes all switch on in `done`, so a tweak that fails part way changes nothing.
(() => {
  "use strict";
  // What a part owns. Its code changes, names, data and schema
  const fresh = (name, parent) => ({
    name,
    parent,
    made: [],
    // Where each @data and @sym name is, its groups' too, for asm
    names: new Map(parent ? parent.names : []),
    // Just its own, for the game's names
    own: [],
    // `@data` names' types
    dataTypes: new Map(parent ? parent.dataTypes : []),
    fields: [],
    schemas: [],
    // `@data` and asm `@patch`es and `@inject`s not placed yet, see `flush`
    pending: { data: [], code: [], names: new Set() },
    // What its `@use`s' `install` gave back
    uses: [],
    schemaText: parent ? parent.schemaText : "",
    types: parent ? parent.types : undefined,
    data: parent ? Object.create(parent.data) : {},
    sym: parent ? Object.create(parent.sym) : {},
    // Its functions by name, for Choices, tick and off. The globals for the shared part
    lookup: (n) => globalThis[n],
    // Sets one of its names, for a group's
    assign: null,
    // What's in a nested group sees its names through this
    scope: null,
    // Where plain global writes go under `@globals shared`, the real globals for the file's group
    globals: parent ? parent.globals : null,
  });
  // A lone tweak's, or a group's shared part
  const shared = fresh("", null);
  const parts = new Map([["", shared]]);
  let cur = shared;
  const sizes = { u8: 1, i8: 1, bool: 1, u16: 2, i16: 2, u32: 4, i32: 4, f32: 4, u64: 8, i64: 8, f64: 8 };

  // Not an Error, so it shows without a stack, which would only point in here
  class Problem {
    constructor(message) {
      this.message = message;
    }
    toString() {
      return this.message;
    }
  }
  const at = (line, message) => new Problem(`line ${line}: ${message}`);
  // Without the error's name in front, which Wraith's errors have
  const messageOf = (e) => {
    const m = (e && e.message) || String(e);
    return e && e.name && m.startsWith(`${e.name}: `) ? m.slice(e.name.length + 2) : m;
  };
  const num = (a) => (typeof a === "number" ? a : Number(typeof a === "bigint" ? a : a.unwrap()));

  // Location text like `game.exe+0x10`; @sym and @data names come first
  const scope = () => [...cur.names].map(([name, address]) => ({ name, address }));
  const evaluate = (line, text) => {
    for (const name of cur.pending.names) {
      if (new RegExp(`(^|[^\\w.])${name}($|[^\\w.])`).test(text)) {
        flush(cur);
        break;
      }
    }
    try {
      return num(addresses.resolve(text, scope()));
    } catch (e) {
      throw at(line, messageOf(e));
    }
  };

  // Comment-free code and the comment, like the assembler sees them
  const splitComment = (l) => {
    let quote = null;
    for (let i = 0; i < l.length; i++) {
      const ch = l[i];
      if (quote) {
        if (ch === quote) quote = null;
      } else if (ch === '"' || ch === "'") quote = ch;
      else if (ch === "/" && l[i + 1] === "/") return [l.slice(0, i), l.slice(i)];
    }
    return [l, ""];
  };

  // Asm gets @data and @sym names through `names`, so they can't be labels too
  const checkNames = (line, src) => {
    src.split("\n").forEach((l, k) => {
      const [code] = splitComment(l);
      for (const m of code.matchAll(/(^|[^\w.$@?])([A-Za-z_][\w.]*)\s*:/g)) {
        if (cur.names.has(m[2]) || cur.pending.names.has(m[2])) throw at(line + k, `${m[2]} is a @data or @sym name, so it can't be a label too`);
      }
    });
    return src;
  };

  // `90 C3`, or `x"90C3"` like asm's db
  const bytesOf = (line, src) => {
    const out = [];
    src.split("\n").forEach((l, k) => {
      const add = (b) => {
        if (!/^[0-9a-fA-F]{2}$/.test(b)) throw at(line + k, `${b} isn't a byte, like 90 or C3`);
        out.push(parseInt(b, 16));
      };
      for (const m of splitComment(l)[0].matchAll(/[xX]"([^"]*)"|[^\s,]+/g)) {
        if (m[1] === undefined) {
          add(m[0]);
          continue;
        }
        for (const t of m[1].split(/\s+/).filter((t) => t)) {
          for (let i = 0; i < t.length; i += 2) add(t.slice(i, i + 2));
        }
      }
    });
    if (!out.length) throw at(line, "there are no bytes under it");
    return out;
  };

  // Error names from the runtime, said plainly
  const plain = {
    UnexpectedBytes: "the bytes there aren't what expect says",
    SplitsInstruction: "that ends inside an instruction, so give a size or expect that covers whole ones",
    AlreadyHooked: "something else already changed the code there",
  };

  // `src` is what was written, before names became addresses
  const asmError = (line, e, src) => {
    const text = messageOf(e);
    const m = /^line (\d+): ([\s\S]*)$/.exec(text);
    // Said plainly when the runtime didn't say more
    if (!m) return at(line, e && plain[e.name] && (!text || text === e.name) ? plain[e.name] : text);
    const n = Number(m[1]);
    let message = m[2];
    const written = src ? splitComment(src.split("\n")[n - 1] || "")[0] : "";
    const far = [...cur.names.keys()].find((name) => new RegExp(`(^|[^\\w.])${name}($|[^\\w.])`).test(written));
    if (far && message.startsWith("can't encode")) {
      message = `${message}. ${far} is too far from this code to use directly, so load it first, like mov rax, ${far} then [rax]`;
    }
    return at(line + n - 1, message);
  };

  const make = (line, create, src) => {
    let item;
    try {
      item = create();
    } catch (e) {
      throw asmError(line, e, src);
    }
    cur.made.push({ line, item });
  };

  // An asm `@patch` or `@inject`, made in `flush` with the part's data
  const later = (line, target, src, request) => {
    const slot = { line, item: null };
    cur.made.push(slot);
    cur.pending.code.push({ line, src, slot, request: { inject: false, size: 0, expect: "", ...request, target, source: src, names: scope() } });
  };

  // Typed reads and writes, for `@data` and `@sym`
  const kinds = { u8: "U8", i8: "I8", u16: "U16", i16: "I16", u32: "U32", i32: "I32", u64: "U64", i64: "I64", f32: "F32", f64: "F64", bool: "U8" };
  const load = (address, kind) => {
    const v = memory[`read${kinds[kind]}`](address);
    return kind === "bool" ? v !== 0 : v;
  };
  const store = (address, kind, v) => {
    const wide = kind === "u64" || kind === "i64";
    memory[`write${kinds[kind]}`](address, kind === "bool" ? (v ? 1 : 0) : wide ? BigInt(v) : v);
  };
  const cellAt = (address) => ({ address, load: (kind) => load(address, kind), store: (kind, v) => store(address, kind, v) });

  // Places the part's pending data and asm together, so the code always reaches it
  const flush = (part) => {
    const p = part.pending;
    if (!p.data.length && !p.code.length) return;
    part.pending = { data: [], code: [], names: new Set() };
    const was = cur;
    cur = part;
    try {
      const near = p.data.map((d) => d.near).find((n) => n !== undefined);
      const data = p.data.map((d) => ({ size: d.size, alignment: 0, names: d.placed.map((f) => ({ name: f.name, offset: f.offset })) }));
      let done;
      try {
        done = code.place({ near: near === undefined ? memory.main().base : near, data, code: p.code.map((c) => c.request) });
      } catch (e) {
        const text = messageOf(e);
        const m = /^code (\d+)(?:, (line \d+: [\s\S]*)|: ([\s\S]*))?$/.exec(text);
        if (m) {
          const c = p.code[Number(m[1]) - 1];
          throw asmError(c.line, { name: e.name, message: m[2] || m[3] || e.name }, c.src);
        }
        const line = (p.data[0] || p.code[0]).line;
        const bytes = /^no room for (\d+) bytes/.exec(text);
        const name = part.name || __t.file || "this tweak";
        if (bytes) throw at(line, `${name} needs ${bytes[1]} bytes for its code and data in one place, and there's no room for that`);
        throw at(line, `couldn't place its code and data: ${text}`);
      }
      p.code.forEach((c, i) => {
        c.slot.item = done.code[i];
      });
      p.data.forEach((d, i) => {
        const base = num(done.data[i]);
        for (const f of d.placed) {
          const address = base + f.offset;
          const cell = cellAt(address);
          const kind = f.type;
          const whole = !kind.startsWith("f") && kind !== "bool";
          try {
            cell.store(kind, kind === "bool" ? f.value !== 0 : whole ? Math.trunc(f.value) : f.value);
          } catch (e) {
            throw at(f.line, `${f.value} doesn't fit a ${kind}`);
          }
          part.names.set(f.name, address);
          Object.defineProperty(part.data, f.name, {
            get: () => cell.load(kind),
            set: (v) => cell.store(kind, v),
            enumerable: true,
          });
          part.fields.push({ name: f.name, address, line: f.line, choices: f.choices });
          part.dataTypes.set(f.name, kind);
        }
      });
    } finally {
      cur = was;
    }
  };

  // A mid hook calling `body(cpu, original, resume)`, where those two jump there when it returns
  const midHook = (line, target, body, options) =>
    make(line, () => {
      let originalAt = 0;
      let resumeAt = 0;
      const h = hooks.mid(target, { replace: false, size: 0, expect: "", names: [], ...options, disabled: true }, function (cpu) {
        const ip = "rip" in cpu ? "rip" : "eip";
        const wide = typeof cpu[ip] === "bigint";
        const original = () => {
          cpu[ip] = wide ? BigInt(originalAt) : originalAt;
        };
        try {
          body.call(this, cpu, original, () => {
            cpu[ip] = wide ? BigInt(resumeAt) : resumeAt;
          });
        } catch (e) {
          // The code it replaced runs, so a broken patch doesn't break the game
          original();
          log.warn(`line ${line}: ${messageOf(e)}`);
        }
      });
      originalAt = h.original();
      resumeAt = h.resume();
      return h;
    });

  // A `.sal` signature like `[Thiscall] f32 (Player* self, i32)`
  const signatureOf = (text) => {
    const open = text.indexOf("(");
    const close = text.lastIndexOf(")");
    if (open < 0 || close < open) return text;
    let head = text.slice(0, open).trim();
    if (!/(^|[\s\]])fn(\s|$)/.test(head)) {
      const attrs = /^(\[[^\]]*\]\s*)*/.exec(head)[0];
      head = `${attrs}fn ${head.slice(attrs.length)}`;
    }
    const params = text
      .slice(open + 1, close)
      .split(",")
      .map((p) => p.trim())
      .filter((p) => p)
      .map((p, i) => (/^[\w.]+[*\[\]0-9]*$/.test(p) || p.endsWith("*") ? `${p} a${i}` : p));
    return `${head} (${params.join(", ")})`;
  };

  const choicesOf = (part, f) => {
    let list;
    try {
      list = part.lookup(f.choices);
    } catch {}
    if (typeof list !== "function") throw at(f.line, `there's no function ${f.choices} for its Choices`);
    let items;
    try {
      items = Array.from(list());
    } catch (e) {
      throw at(f.line, `${f.choices}(): ${messageOf(e)}`);
    }
    return items.map((it) => {
      if (Array.isArray(it)) return { value: Number(it[0]), label: String(it[1]) };
      if (typeof it === "object") return { value: Number(it.value), label: String(it.label) };
      const s = String(it);
      const colon = s.indexOf(":");
      return { value: Number(s.slice(0, colon)), label: s.slice(colon + 1) };
    });
  };

  for (const name of ["data", "sym"]) {
    Object.defineProperty(globalThis, name, { value: shared[name], writable: true, configurable: true });
  }

  const own = (name, address) => {
    cur.names.set(name, address);
    cur.own.push(name);
  };

  // A function there, and not just one from a group it's in
  const ownFunction = (part, name) => {
    let f;
    try {
      f = part.lookup(name);
    } catch {}
    if (typeof f !== "function") return null;
    if (part === shared) return f;
    let above;
    try {
      above = part.parent.lookup(name);
    } catch {}
    return f !== above ? f : null;
  };

  // Names a nested group's code has, cached since they don't change once it's run
  const scopeOf = (part) => {
    const has = new Map();
    const owns = (n) => {
      if (typeof n !== "string") return false;
      let known = has.get(n);
      if (known === undefined) {
        known = false;
        try {
          const v = part.lookup(n);
          known = !(n in globalThis) || v !== globalThis[n];
        } catch {}
        has.set(n, known);
      }
      return known;
    };
    return new Proxy(Object.create(null), {
      has: (_, n) => owns(n),
      get: (_, n) => (n === Symbol.unscopables ? undefined : part.lookup(n)),
      set: (_, n, v) => {
        part.assign(n, v);
        return true;
      },
    });
  };

  // A nested group's `@globals shared`; names already in the real globals still go there
  const sharers = new Map();
  const sharerOf = (path) => {
    let proxy = sharers.get(path);
    if (proxy) return proxy;
    const env = () => {
      const part = parts.get(path);
      return part && part.globals;
    };
    proxy = new Proxy(Object.create(null), {
      has: (_, n) => {
        const e = env();
        return typeof n === "string" && !!e && (n in e || !(n in globalThis));
      },
      get: (_, n) => {
        const e = env();
        return typeof n === "string" && e ? e[n] : undefined;
      },
      set: (_, n, v) => {
        const e = env();
        if (e) e[n] = v;
        else globalThis[n] = v;
        return true;
      },
    });
    sharers.set(path, proxy);
    return proxy;
  };

  // A saved name, from `./x` or `.` in this file
  const absolute = (name) => {
    if (name === ".") return __t.file;
    if (name.startsWith("./")) return `${__t.file}/${name.slice(2)}`;
    return name;
  };
  const bridge = {
    isOn: (name) => tweaks.isOn(absolute(name)),
    setOn: (name, on) => tweaks.setOn(absolute(name), on),
  };

  globalThis.__t = {
    // One of a group's tweaks or nested groups, with its own state. `shares` is `@globals shared`
    part(name, body, parent, shares) {
      if (name === "") {
        cur = shared;
        return;
      }
      const above = parent ? parts.get(parent) : shared;
      if (!above) throw new Problem(`its group ${parent} isn't on`);
      cur = fresh(name, above);
      if (shares) cur.globals = Object.create(null);
      parts.set(name, cur);
      try {
        return body(cur.data, cur.sym, cur.types);
      } finally {
        cur = shared;
      }
    },

    // The file's group says `@globals shared`, so its globals are the real ones
    globals() {
      shared.globals = globalThis;
    },

    // What's in nested group `name` under `@globals shared` runs with this
    shared(name) {
      return sharerOf(name);
    },

    // A part's top-level `var` and `function` names, as `[name, get, set, isVar]`, kept live in the shared globals
    share(list) {
      const env = cur.globals;
      if (!env) return;
      for (const [n, get, set, isVar] of list) {
        const had = n in env;
        const old = had ? env[n] : undefined;
        try {
          Object.defineProperty(env, n, { get, set, enumerable: true, configurable: true });
          if (isVar && had) set(old);
        } catch {
          // One the file's group made with var or function can't be redefined
          if (!isVar) env[n] = get();
        }
      }
    },

    // What's in nested group `name` runs with this
    scope(name) {
      const part = parts.get(name);
      if (!part || !part.assign) throw new Problem(`its group ${name} isn't on`);
      return part.scope || (part.scope = scopeOf(part));
    },

    // `@use name`. Gives what `install` gave back, else the library. A handle's `stop` runs when the part stops
    use(line, name, title) {
      let lib;
      try {
        lib = require(name);
      } catch (e) {
        throw at(line, `@use ${name}: ${messageOf(e)}`);
      }
      let value = lib;
      if (lib && typeof lib.install === "function") {
        let handle;
        try {
          handle = lib.install(globalThis, { name: title, path: cur.name, tweaks: bridge });
        } catch (e) {
          throw at(line, `@use ${name}: ${messageOf(e)}`);
        }
        if (handle !== undefined) value = handle;
        cur.uses.push(value);
      }
      if (cur === shared) globalThis[name] = value;
      return value;
    },

    sym(line, name, text) {
      const v = evaluate(line, text);
      own(name, v);
      cur.sym[name] = cellAt(v);
    },

    data(line, near, list) {
      let size = 0;
      const placed = list.map((f) => {
        const n = sizes[f.type];
        size = Math.ceil(size / n) * n;
        const p = { ...f, offset: size };
        size += n;
        return p;
      });
      if (!placed.length) return;
      // Placed with the asm that reads it in `flush`, or now if read before then
      const where = near ? evaluate(line, near) : undefined;
      const part = cur;
      part.pending.data.push({ line, near: where, size: Math.max(size, 8), placed });
      for (const f of placed) {
        part.pending.names.add(f.name);
        // Listed now, so the game's names keep the tweak's order
        part.own.push(f.name);
        Object.defineProperty(part.data, f.name, {
          get: () => {
            flush(part);
            return part.data[f.name];
          },
          set: (v) => {
            flush(part);
            part.data[f.name] = v;
          },
          enumerable: true,
          configurable: true,
        });
      }
    },

    // Gives `types`, which a group's tweak keeps as its own
    schema(line, text) {
      const start = (cur.schemaText.match(/\n/g) || []).length + 1;
      cur.schemas.push({ start, line });
      cur.schemaText += text;
      try {
        // After its project's, so it can use their types
        const project = __t.project ? `${__t.project}\nfile "tweak.sal";\n` : "";
        cur.types = salamander.load("tweak", project + cur.schemaText);
        // So the runtime knows them too, for hooks' signatures
        schema.add("tweak.sal", cur.schemaText);
      } catch (e) {
        const message = messageOf(e).replace(/^tweak\.sal: ?/, "");
        const m = /^(\d+):\d+: ([\s\S]*)$/.exec(message);
        if (!m) throw at(line, message);
        const n = Number(m[1]);
        const from = cur.schemas.filter((l) => l.start <= n).pop();
        // In the shared part's, which the shared part already checked
        if (!from) throw at(line, m[2]);
        throw at(from.line + n - from.start, m[2]);
      }
      if (cur === shared) globalThis.types = cur.types;
      return cur.types;
    },

    patch(line, text, expect, size, src) {
      const target = evaluate(line, text);
      later(line, target, checkNames(line, src), { expect, size: size || undefined });
    },

    bytes(line, text, expect, src) {
      const target = evaluate(line, text);
      const bytes = bytesOf(line, src);
      make(line, () => code.patchBytes(target, new Uint8Array(bytes), { size: 0, expect: expect || "", disabled: true, names: scope() }));
    },

    inject(line, text, src) {
      const target = evaluate(line, text);
      later(line, target, checkNames(line, src), { inject: true });
    },

    // `body(cpu, original, resume)` in place of the code there
    patchJs(line, text, expect, size, body) {
      midHook(line, evaluate(line, text), body, { replace: true, expect: expect || "", size: size || 0, names: scope() });
    },

    // `body(cpu, original, resume)` before the instruction there
    injectJs(line, text, body) {
      midHook(line, evaluate(line, text), body, {});
    },

    // `body(original, ...args)` in place of the function there
    hook(line, text, signature, body) {
      const target = evaluate(line, text);
      const sig = signatureOf(signature);
      make(line, () => {
        let call = null;
        const original = (...args) => call(...args);
        const h = hooks.detour(
          target,
          sig,
          salamander.fn(sig, function (...args) {
            return body.call(this, original, ...args);
          }),
          { context: 0, disabled: true },
        );
        call = salamander.native(sig, h.original());
        return h;
      });
    },

    // Returns where its data went, for the UI
    done(lookup, assign) {
      const part = cur;
      flush(part);
      if (lookup) part.lookup = lookup;
      if (assign) part.assign = assign;
      const on = [];
      for (const m of part.made) {
        try {
          m.item.enable();
          on.push(m);
        } catch (e) {
          for (const o of on.reverse()) {
            try {
              o.item.disable();
            } catch {}
          }
          throw at(m.line, `couldn't turn it on: ${messageOf(e)}`);
        }
      }
      const tick = ownFunction(part, "tick");
      // Each tick, on the game thread like the tweak, where engines' objects can be used
      if (tick) part.tick = threads.onTick(tick);
      return JSON.stringify({
        fields: part.fields.map((f) => ({ name: f.name, address: f.address, choices: f.choices ? choicesOf(part, f) : null })),
        // For the game's names, like `xp.multiplier`
        names: part.own.map((name) => ({ name, address: part.names.get(name), type: part.dataTypes.get(name) || "" })),
      });
    },

    // Before what it made goes. `name` is a group's tweak or nested group, or empty for the rest
    stop(name) {
      const part = parts.get(name || "");
      if (!part) return;
      const off = ownFunction(part, "off");
      try {
        if (off) off();
      } finally {
        for (const h of part.uses.reverse()) {
          try {
            if (h && typeof h.stop === "function") h.stop();
          } catch {}
        }
        part.uses = [];
        // What it made, newest first
        if (part.tick) part.tick.cancel();
        for (const m of part.made.reverse()) {
          try {
            if (m.item) m.item.destroy();
          } catch {}
        }
        part.made = [];
        if (part !== shared) parts.delete(part.name);
      }
    },
  };
})();
