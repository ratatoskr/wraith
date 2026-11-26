/* A C plugin for the loader's tests, built like `Plugin.initC` builds them, with -Wpedantic too.
 * Its tweak `c_fixture:count` fails when `step` is 0. */

#include "schema.h"
#include "wraith_plugin.h"

static Wraith_Api w;
static uint32_t step = 1;
static uint32_t count;

WRAITH_EXPORT uint32_t wraith_c_count(void);
WRAITH_EXPORT uint32_t wraith_c_count(void) { return count; }

/* Its schema's types use Wraith's own, from wraith.h */
static CFixture_Spot spot;
_Static_assert(sizeof(spot.at) == sizeof(Wraith_Vec3), "Spot.at is a Wraith_Vec3");

static uint32_t run(uintptr_t self, Wraith_Tweaks_Event event) {
    uint32_t *total = (uint32_t *)self;
    if (event.kind == Wraith_Tweaks_EventKind_changed) step = (uint32_t)event.value;
    if (event.kind != Wraith_Tweaks_EventKind_on) return SAL_OK;
    if (step == 0) return Wraith_TweakError_Failed;
    *total += step;
    return SAL_OK;
}

static const Wraith_Tweaks_Handler_table run_table = { SAL_TABLE(Wraith_Tweaks_Handler), .call = run };

static const Wraith_Tweaks_Field fields[] = {
    { .name = SAL_STR("step"), .type = Wraith_Tweaks_FieldType_u32, .value = 1 },
};

/* What the fixture's service gave */
static uint32_t got;

static uint32_t total(uintptr_t self) {
    (void)self;
    return got;
}

static const CFixture_CService_table service_table = { SAL_TABLE(CFixture_CService), .total = total };

static sal_Host host_;
static sal_Owner *owner_;

/* CService for plugins that depend on this one, owned so it stops when this one goes */
static sal_object service(sal_string trait) {
    if (!wraith_same(trait, sal_info_CFixture_CService.name)) return wraith_no_service(trait);
    CFixture_CService mine = { 0, &service_table };
    CFixture_CService owned = sal_own_CFixture_CService(host_, mine, owner_);
    sal_object o = { owned.data, owned.table };
    return o;
}

static bool start(sal_Host host, wraith_Guest guest) {
    host_ = host;
    owner_ = guest.owner;
    w = wraith_root(guest);
    Wraith_Log_info(Wraith_Api_log(w), SAL_STR("C plugin starting"));
    spot.at.x = 1;

    // No table without the fixture, so the calls give 0
    sal_object o = wraith_service(host, guest, SAL_STR("fixture"), &sal_info_Fixture_FixtureService);
    Fixture_FixtureService counter = { o.data, o.table };
    Fixture_FixtureService_next(counter);
    got = Fixture_FixtureService_next(counter);

    Wraith_Tweaks_Definition definition = {
        .id = SAL_STR("count"),
        .title = SAL_STR("Count"),
        .mode = Wraith_Tweaks_Mode_action,
        .fields = { fields, 1 },
    };
    Wraith_Tweaks_Handler handler = { (uintptr_t)&count, &run_table };
    return Wraith_Tweaks_addIn(Wraith_Api_tweaks(w), SAL_STR("Test"), definition, handler) == SAL_OK;
}

static void stop(void) {}

WRAITH_PLUGIN_WITH(start, stop, service)
