// A C++ plugin for the loader's tests, built like `Plugin.initCpp` builds them.
// Its tweak `cpp_fixture:count` fails when `step` is 0.

#include "schema.hpp"
#include "wraith_plugin.hpp"

static uint32_t step = 1;
static uint32_t count;

extern "C" WRAITH_EXPORT uint32_t wraith_cpp_count(void) { return count; }

// Its schema's types use Wraith's own, from wraith.hpp
static_assert(std::is_same_v<decltype(CppFixture::Spot{}.at), Wraith::Vec3>);

// Kept by Wraith, so it's made with sal::keep
struct Run {
    sal::Result<void, Wraith::TweakError> operator()(Wraith::Tweaks::Event event) const {
        if (event.kind == Wraith::Tweaks_EventKind::changed) step = static_cast<uint32_t>(event.value);
        if (event.kind != Wraith::Tweaks_EventKind::on) return {};
        if (step == 0) return Wraith::TweakError::Failed;
        count += step;
        return {};
    }
};

struct Plugin {
    // What the fixture's service gave
    uint32_t got = 0;

    struct Service {
        Plugin *plugin;
        uint32_t total() const { return plugin->got; }
        // Half again what the fixture's service gives next, once a coroutine's had it
        sal::Future<uint32_t> later() const {
            uint32_t n = wraith::service<Fixture::FixtureService>("fixture").next();
            auto p = sal::promise<uint32_t>();
#if SAL_COROUTINES
            auto task = [](sal::Future<uint32_t> f) -> sal::Future<uint32_t> {
                auto r = co_await f;
                if (!r) co_return r.error();
                co_return r.value() * 3;
            };
            auto out = task(std::move(p.future));
            p.settle.resolve(n);
            return out;
#else
            // No coroutines on 32-bit Windows with MSVC's ABI, so the same with then
            auto out = sal::promise<uint32_t>();
            auto *in = new sal::Future<uint32_t>(std::move(p.future));
            in->then([in, settle = std::move(out.settle)]() mutable {
                auto r = in->take();
                if (r) settle.resolve(r.value() * 3);
                else settle.reject(r.error());
                delete in;
            });
            p.settle.resolve(n);
            return std::move(out.future);
#endif
        }
    } service_impl{this};

    bool start() {
        wraith::api().log().info("C++ plugin starting");
        // No table without the fixture, so the calls give 0
        auto counter = wraith::service<Fixture::FixtureService>("fixture");
        counter.next();
        got = counter.next();

        static const Wraith::Tweaks::Field fields[] = {
            {.name = sal::String::of("step"), .type = Wraith::Tweaks_FieldType::u32, .value = 1},
        };
        Wraith::Tweaks::Definition definition{
            .id = sal::String::of("count"),
            .title = sal::String::of("Count"),
            .mode = Wraith::Tweaks_Mode::action,
            .fields = sal::Slice<Wraith::Tweaks::Field>::of(fields),
        };
        auto handler = sal::keep<Wraith::Tweaks::Handler>(Run{});
        return wraith::api().tweaks().addIn("Test", definition, handler).ok();
    }

    void stop() {}

    // CppService for plugins that depend on this one, owned so it stops when this one goes
    sal::Object service(std::string_view trait) {
        if (wraith::asks_for<CppFixture::CppService>(trait)) return wraith::offer(CppFixture::CppService::of(service_impl));
        return {};
    }
};

WRAITH_PLUGIN(Plugin)
