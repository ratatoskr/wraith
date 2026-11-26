/* The `wraith_plugin` export a C plugin needs. Everything else is Wraith's API in `wraith.h`.
 *
 *     static bool start(sal_Host host, wraith_Guest guest) {
 *         Wraith_Api w = wraith_root(guest);
 *         Wraith_Log_info(Wraith_Api_log(w), SAL_STR("Hello"));
 *         return true;
 *     }
 *     static void stop(void) {}
 *     WRAITH_PLUGIN(start, stop)
 *
 * Fallible calls return SAL_OK or a code, with the value through a trailing pointer.
 * Objects you hand Wraith are SAL_TABLE function tables, no longer called once unloading. */

#ifndef WRAITH_PLUGIN_H
#define WRAITH_PLUGIN_H

#include "wraith.h"

/* Only changes when Wraith's native entry does. */
#define WRAITH_NATIVE_VERSION 2u

/* What the plugin gets as it starts. */
typedef struct wraith_Guest {
    /* Its `Wraith_Api`, see `wraith_root`. Stops working once it's unloaded. */
    sal_object wraith;
    /* Its Salamander owner, for objects it provides to other plugins. */
    sal_Owner *owner;
    /* Polled on the render thread each frame. */
    sal_Queue render_queue;
    /* What the plugins it depends on offer. Only good during `start`. */
    Slice_Wraith_Plugin_Service services;
} wraith_Guest;

/* What `wraith_plugin` gives. */
typedef struct wraith_Entry {
    uint32_t version;
    /* False if it didn't start. `stop` gets called either way. */
    bool (*start)(sal_Host host, wraith_Guest guest);
    void (*stop)(void);
    /* What it offers for a [Service] trait in its schemas, or no table. */
    sal_object (*service)(sal_string trait);
} wraith_Entry;

_Static_assert(sizeof(wraith_Guest) == 7 * sizeof(void *), "wraith_Guest's size");
_Static_assert(offsetof(wraith_Entry, start) == sizeof(void *), "wraith_Entry.start's offset");

static inline Wraith_Api wraith_root(wraith_Guest guest) {
    Wraith_Api w = { guest.wraith.data, (const Wraith_Api_table *)guest.wraith.table };
    return w;
}

static inline bool wraith_same(sal_string a, sal_string b) {
    if (a.len != b.len) return false;
    for (uintptr_t i = 0; i < a.len; i++)
        if (a.ptr[i] != b.ptr[i]) return false;
    return true;
}

/* What dependency `plugin` offers as a [Service] trait, or no table. Only during `start`:
 *     sal_object o = wraith_service(host, guest, SAL_STR("freecam"), &sal_info_Freecam_Freecam);
 *     Freecam_Freecam cam = { o.data, o.table }; */
static inline sal_object wraith_service(sal_Host host, wraith_Guest guest, sal_string plugin, const sal_Info *want) {
    for (uintptr_t i = 0; i < guest.services.len; i++) {
        Wraith_Plugin_Service s = guest.services.ptr[i];
        if (wraith_same(s.plugin, plugin) && wraith_same(s.trait, want->name)) return sal_Host_adapt(host, s.obj, (sal_Info *)want);
    }
    sal_object none = { 0, NULL };
    return none;
}

/* Offers nothing. To offer a [Service] trait, pass `WRAITH_PLUGIN_WITH` a function like:
 *     static sal_object service(sal_string trait) {
 *         if (!wraith_same(trait, sal_info_Game_Freecam.name)) return wraith_no_service(trait);
 *         Game_Freecam cam = sal_own_Game_Freecam(host, (Game_Freecam){ (uintptr_t)&mine, &cam_table }, owner);
 *         return (sal_object){ cam.data, cam.table };
 *     }
 * with `host` and `owner`, the guest's, kept from `start`. */
static inline sal_object wraith_no_service(sal_string trait) {
    (void)trait;
    sal_object none = { 0, NULL };
    return none;
}

#if defined(_WIN32)
#  define WRAITH_EXPORT __declspec(dllexport)
#else
#  define WRAITH_EXPORT __attribute__((visibility("default")))
#endif

/* Exports `wraith_plugin`, starting the plugin with `start_fn` and stopping it with `stop_fn`. */
#define WRAITH_PLUGIN(start_fn, stop_fn) WRAITH_PLUGIN_WITH(start_fn, stop_fn, wraith_no_service)

/* The same, with what it offers for [Service] traits. */
#define WRAITH_PLUGIN_WITH(start_fn, stop_fn, service_fn)                                              \
    static const wraith_Entry wraith_entry_ = { WRAITH_NATIVE_VERSION, start_fn, stop_fn, service_fn }; \
    WRAITH_EXPORT const wraith_Entry *wraith_plugin(void);                                            \
    WRAITH_EXPORT const wraith_Entry *wraith_plugin(void) { return &wraith_entry_; }

#endif
