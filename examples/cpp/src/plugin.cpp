// Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
//
// Wraith's API comes from `wraith.hpp`, and the game's code from `schema.hpp`: `GameStateManager::instance()`
// and `manager->giveMira(n)` find what they call by the schema's signatures. Calls that can fail give a
// sal::Result, and what Wraith calls back is any class with the right method.

#include <format>

#include "schema.hpp"
#include "wraith_plugin.hpp"

using namespace ExampleCpp;
using Wraith::Tweaks;

// Says what didn't work in Wraith's log, and gives false
template <class R>
static bool check(const R &r, std::string_view what) {
    if (r) return true;
    wraith::api().log().write(Wraith::Log::Level::err, "example_cpp", std::format("{} failed with code {}", what, r.code()));
    return false;
}

// Where the schema's code or static `name` is, found by its signature once, or 0
static uintptr_t find(std::string_view name) {
    auto at = wraith::api().schema().address(name);
    check(at, name);
    return at.value_or(0);
}

// Free shopping. Shops still take your Mira, just none of it

static GameStateManager_spendMira_fn spend_mira_original;

static uint32_t spend_mira(GameStateManager *self, uint32_t) { return spend_mira_original(self, 0); }

static bool add_free_shopping() {
    uintptr_t at = find(GameStateManager_spendMira_name);
    if (!at) return false;
    // Off till the tweak's on, so it's never called before `original` is known
    auto hook = wraith::api().hooks().detourNative(at, reinterpret_cast<uintptr_t>(&spend_mira), {.disabled = true});
    if (!check(hook, "Hooking spendMira")) return false;
    spend_mira_original = reinterpret_cast<GameStateManager_spendMira_fn>(hook->original());
    Tweaks::Definition definition{.id = sal::String::of("free_shopping"), .title = sal::String::of("Free shopping")};
    return check(wraith::api().tweaks().addHook("Money", definition, *hook), "Adding Free shopping");
}

// Give Mira, with an amount you choose. Each field comes as a `changed` just before it runs

struct GiveMira {
    uint32_t amount = 10000;

    sal::Result<void, Wraith::TweakError> operator()(Tweaks::Event event) {
        if (event.kind == Wraith::Tweaks_EventKind::changed) amount = static_cast<uint32_t>(event.value);
        if (event.kind != Wraith::Tweaks_EventKind::on) return {};
        GameStateManager *manager = GameStateManager::instance();
        if (!manager) {
            wraith::api().log().warn("Load a save first");
            return Wraith::TweakError::Failed;
        }
        manager->giveMira(amount);
        return {};
    }
};

static bool add_give_mira() {
    static const Tweaks::Field fields[] = {
        {.name = sal::String::of("amount"), .type = Wraith::Tweaks_FieldType::u32, .value = 10000, .has_min = true, .min = 1},
    };
    Tweaks::Definition definition{
        .id = sal::String::of("give_mira"),
        .title = sal::String::of("Give Mira"),
        .mode = Wraith::Tweaks_Mode::action,
        .fields = sal::Slice<Tweaks::Field>::of(fields),
    };
    // Wraith keeps it, so it's a heap copy it lets go of
    auto handler = sal::keep<Tweaks::Handler>(GiveMira{});
    return check(wraith::api().tweaks().addIn("Money", definition, handler), "Adding Give Mira");
}

// Tailing without being seen. Being seen needs the gauge full, so skip both. `expect` stops it
// patching a game that changed

static Wraith::Patch tailing[2];

static bool patch(std::string_view name, std::span<const uint8_t> bytes, std::string_view expect, Wraith::Patch &out) {
    uintptr_t at = find(name);
    if (!at) return false;
    auto p = wraith::api().code().patchBytes(at, bytes, {.expect = sal::String::of(expect), .disabled = true});
    if (!check(p, name)) return false;
    out = *p;
    return true;
}

static bool add_tailing_stealth() {
    static const uint8_t jump[] = {0xEB};
    static const uint8_t skip[] = {0xEB, 0x02};
    if (!patch(tailing_seen_name, jump, "76", tailing[0])) return false;
    if (!patch(tailing_gauge_name, skip, "F3 0F 5F FE", tailing[1])) return false;
    Tweaks::Definition definition{.id = sal::String::of("tailing_stealth"), .title = sal::String::of("Tailing without being seen")};
    auto handler = sal::keep<Tweaks::Handler>([](Tweaks::Event event) -> sal::Result<void, Wraith::TweakError> {
        for (auto &p : tailing) {
            if (event.kind == Wraith::Tweaks_EventKind::on) {
                if (auto r = p.enable(); !r) return static_cast<Wraith::TweakError>(r.code());
            } else if (event.kind == Wraith::Tweaks_EventKind::off) {
                p.disable();
            }
        }
        return {};
    });
    return check(wraith::api().tweaks().addIn("Field", definition, handler), "Adding Tailing without being seen");
}

// Or let it fill, slower. A mid hook runs with the registers right there in the game's code

// Set on the render thread, read on the game's
static std::atomic<float> gauge_speed = 0.25f;
static Wraith::Hook slow_gauge;

// xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept
static auto gauge_store = [](Wraith::Cpu *cpu) {
    auto *state = reinterpret_cast<TailingState *>(static_cast<uintptr_t>(cpu->rdi));
    float next = cpu->xmm7.f32x4[0];
    cpu->xmm7.f32x4[0] = state->gauge + (next - state->gauge) * gauge_speed.load(std::memory_order_relaxed);
};

static bool add_slow_tailing_gauge() {
    uintptr_t at = find(tailing_gauge_store_name);
    if (!at) return false;
    auto hook = wraith::api().hooks().mid(at, {.expect = sal::String::of("F3 0F 11 BF D4 00 00 00"), .disabled = true}, Wraith::Hooks::MidHandler::of(gauge_store));
    if (!check(hook, "Hooking the tailing gauge")) return false;
    slow_gauge = *hook;
    static const Tweaks::Field fields[] = {
        {.name = sal::String::of("speed"), .type = Wraith::Tweaks_FieldType::f32, .value = 0.25, .has_min = true, .min = 0, .has_max = true, .max = 1},
    };
    Tweaks::Definition definition{
        .id = sal::String::of("slow_tailing_gauge"),
        .title = sal::String::of("Slower tailing gauge"),
        .fields = sal::Slice<Tweaks::Field>::of(fields),
    };
    auto handler = sal::keep<Tweaks::Handler>([](Tweaks::Event event) -> sal::Result<void, Wraith::TweakError> {
        if (event.kind == Wraith::Tweaks_EventKind::changed) gauge_speed = static_cast<float>(event.value);
        else if (event.kind == Wraith::Tweaks_EventKind::on) {
            if (auto r = slow_gauge.enable(); !r) return static_cast<Wraith::TweakError>(r.code());
        } else if (event.kind == Wraith::Tweaks_EventKind::off) slow_gauge.disable();
        return {};
    });
    return check(wraith::api().tweaks().addIn("Field", definition, handler), "Adding Slower tailing gauge");
}

// What Wraith starts and stops

struct Example {
    bool start() {
        // Each adds what it can, so one the game changed doesn't stop the rest
        bool all = add_free_shopping();
        all = add_give_mira() && all;
        all = add_tailing_stealth() && all;
        all = add_slow_tailing_gauge() && all;
        if (!all) wraith::api().log().warn("Some tweaks couldn't be added, see above");
        return true;
    }

    // Wraith takes its hooks, patches and tweaks away itself
    void stop() {}
};

WRAITH_PLUGIN(Example)
