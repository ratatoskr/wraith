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
    { .name = SAL_STR_INIT("step"), .type = Wraith_Tweaks_FieldType_u32, .value = 1 },
};

/* What the fixture's service gave */
static uint32_t got;

static uint32_t total(uintptr_t self) {
    (void)self;
    return got;
}

static const CFixture_CService_table service_table = { SAL_TABLE(CFixture_CService), .total = total };

/* The Notes tab, many at once, which the loader's tests call like the Workbench does */
static uint32_t notes_made;
static uint32_t notes_drawn;
static char notes_id[2];
static char notes_title[32];

static Wraith_WorkbenchTab_Info notes_describe(uintptr_t self) {
    (void)self;
    Wraith_WorkbenchTab_Info info = { .title = SAL_STR_INIT("Notes"), .kind = SAL_STR_INIT("notes"), .place = Wraith_WorkbenchPanel_Place_bottom, .multi = true };
    return info;
}

static void notes_draw(uintptr_t self, sal_string id) {
    (void)self;
    (void)id;
    notes_drawn++;
}

static void notes_put(size_t *n, const char *text, uintptr_t len) {
    for (uintptr_t i = 0; i < len && *n < sizeof(notes_title); i++) notes_title[(*n)++] = text[i];
}

/* "Note <id> drawn <draws>", not saved */
static Wraith_WorkbenchTab_State notes_status(uintptr_t self, sal_string id) {
    (void)self;
    size_t n = 0;
    char draws = (char)('0' + notes_drawn % 10);
    notes_put(&n, "Note ", 5);
    notes_put(&n, id.ptr, id.len);
    notes_put(&n, " drawn ", 7);
    notes_put(&n, &draws, 1);
    Wraith_WorkbenchTab_State state = { .title = { notes_title, n }, .unsaved = true };
    return state;
}

static sal_string notes_create(uintptr_t self) {
    (void)self;
    notes_made++;
    notes_id[0] = (char)('0' + notes_made % 10);
    sal_string id = { notes_id, 1 };
    return id;
}

/* The first stays open */
static bool notes_keep_open(uintptr_t self, sal_string id) {
    (void)self;
    return id.len == 1 && id.ptr[0] == '1';
}

static const Wraith_WorkbenchTab_table notes_table = {
    SAL_TABLE(Wraith_WorkbenchTab),
    .describe = notes_describe,
    .draw = notes_draw,
    .status = notes_status,
    .create = notes_create,
    .keepOpen = notes_keep_open,
};

/* A counter for the fixture's `counters` slot, which only has one when the fixture's loaded */
static uint32_t nine(uintptr_t self) {
    (void)self;
    return 9;
}

static const Fixture_FixtureCounter_table counter_table = { SAL_TABLE(Fixture_FixtureCounter), .next = nine };

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
    if (Wraith_Tweaks_addIn(Wraith_Api_tweaks(w), SAL_STR("Test"), definition, handler) != SAL_OK) return false;

    sal_object counting = { 0, &counter_table };
    Wraith_Contribution counted;
    (void)Wraith_Ui_contributeTo(Wraith_Api_ui(w), SAL_STR("fixture.counters"), counting, &counted);

    Wraith_WorkbenchTab notes = { 0, &notes_table };
    Wraith_Contribution tab;
    return Wraith_Ui_addWorkbenchTab(Wraith_Api_ui(w), notes, &tab) == SAL_OK;
}

static void stop(void) {}

WRAITH_PLUGIN_WITH(start, stop, service)
