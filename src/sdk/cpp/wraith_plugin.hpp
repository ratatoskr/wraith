// What makes a C++ class a Wraith plugin. Everything else is Wraith's API in `wraith.hpp`.
//
//     struct Hello {
//         bool start() {
//             wraith::api().log().info("Hello");
//             return true;
//         }
//         void stop() {}
//     };
//     WRAITH_PLUGIN(Hello)
//
// It's made as the plugin starts and destroyed once it's stopped. Its schemas' game code, like
// `Player::main()`, is found through Wraith. What it keeps or offers stops being called once it's unloading.
// To offer a [Service] trait, give it `sal::Object service(std::string_view trait)`, see `wraith::offer`.

#ifndef WRAITH_PLUGIN_HPP
#define WRAITH_PLUGIN_HPP

#include <optional>
#include <vector>

#include "wraith.hpp"

#if defined(_WIN32)
#  define WRAITH_EXPORT __declspec(dllexport)
#else
#  define WRAITH_EXPORT __attribute__((visibility("default")))
#endif

namespace wraith {

// Only changes when Wraith's native entry does
inline constexpr uint32_t native_version = 2;

// What the plugin gets as it starts
struct Guest {
    ::sal::Object wraith;
    ::sal::Owner *owner;
    ::sal::Queue render_queue;
    // Only good during start
    ::sal::Slice<::Wraith::Plugin_Service> services;
};

// What wraith_plugin gives
struct Entry {
    uint32_t version;
    bool (*start)(::sal::Host host, Guest guest);
    void (*stop)();
    ::sal::Object (*service)(::sal::String trait);
};

static_assert(sizeof(Guest) == 7 * sizeof(void *), "Guest's size");
static_assert(offsetof(Entry, start) == sizeof(void *), "Entry.start's offset");

namespace detail {

struct State {
    ::Wraith::Api api{};
    ::sal::Queue render{};
    std::vector<::Wraith::Plugin_Service> services;
};

inline State &state() {
    static State s;
    return s;
}

} // namespace detail

// This plugin's Wraith. Stops working once it's unloading.
inline ::Wraith::Api api() { return detail::state().api; }

inline ::sal::Host host() { return ::sal::Runtime::host; }

// Guards what it offers and keeps, which stop being called once it's unloading
inline ::sal::Owner *owner() { return ::sal::Runtime::owner; }

// Polled on the render thread each frame, like for `future.on(wraith::render_queue())`
inline ::sal::Queue render_queue() { return detail::state().render; }

// What dependency plugin offers as [Service] trait T, or no table
template <class T>
T service(std::string_view plugin) {
    for (const auto &s : detail::state().services) {
        if (s.plugin.view() == plugin && s.trait.view() == T::salamander_info.name.view())
            return T::from_object(host().adapt(s.obj, const_cast<::sal::Info *>(&T::salamander_info)));
    }
    return T{};
}

// Whether a service call is asking for T
template <class T>
bool asks_for(std::string_view trait) {
    return trait == T::salamander_info.name.view();
}

// obj owned by this plugin, for its service to give back:
//     sal::Object service(std::string_view trait) {
//         if (wraith::asks_for<Game::Freecam>(trait)) return wraith::offer(Game::Freecam::of(cam));
//         return {};
//     }
template <class T>
::sal::Object offer(T obj) {
    return ::sal::own(obj, owner(), host()).object();
}

namespace detail {

inline void attach(::sal::Host h, Guest guest) {
    ::sal::init(h, guest.owner);
    State &s = state();
    s.api = ::Wraith::Api::from_object(guest.wraith);
    s.render = guest.render_queue;
    // Copied, since what it points at lives as long as those plugins
    s.services.assign(guest.services.begin(), guest.services.end());
    ::sal::declared::locator = [](std::string_view name) -> uintptr_t {
        auto r = api().schema().address(name);
        return r ? *r : 0;
    };
}

inline void detach() {
    ::sal::declared::locator = nullptr;
    State &s = state();
    s.api = {};
    s.render = {};
    s.services.clear();
}

template <class P>
struct Hosted {
    static inline std::optional<P> plugin;

    static bool make() {
        SAL_TRY
        plugin.emplace();
        return plugin->start();
        SAL_CATCH(false)
    }

    static void finish() {
        SAL_TRY
        if constexpr (requires(P &p) { p.stop(); }) plugin->stop();
        plugin.reset();
        SAL_CATCH()
    }

    static bool start(::sal::Host h, Guest guest) {
        attach(h, guest);
        return make();
    }

    // Called even when start failed
    static void stop() {
        if (plugin) finish();
        plugin.reset();
        detach();
    }

    static ::sal::Object service(::sal::String trait) {
        if constexpr (requires(P &p, std::string_view t) { p.service(t); }) {
            if (plugin) {
                SAL_TRY
                return plugin->service(trait.view());
                SAL_CATCH({})
            }
        }
        return {};
    }

    static inline const Entry entry{native_version, &start, &stop, &service};
};

} // namespace detail

} // namespace wraith

// Exports wraith_plugin, which Wraith starts the plugin through
#define WRAITH_PLUGIN(Type)                                                                     \
    extern "C" WRAITH_EXPORT const ::wraith::Entry *wraith_plugin(void);                        \
    extern "C" WRAITH_EXPORT const ::wraith::Entry *wraith_plugin(void) { return &::wraith::detail::Hosted<Type>::entry; }

#endif
