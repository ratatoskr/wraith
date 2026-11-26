/* Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
 *
 * There's no SDK on top: every call is Wraith's API from `wraith.h`, and the game's code is found by
 * the names `schema.h` gives, through the Schema area. Calls that can fail give SAL_OK or a code. */

#include <stdio.h>

#include "schema.h"
#include "wraith_plugin.h"

static Wraith_Api w;

/* Says what didn't work in Wraith's log, and gives false. */
static bool failed(const char *what, uint32_t code) {
    char text[160];
    int n = snprintf(text, sizeof text, "%s failed with code %u", what, (unsigned)code);
    sal_string message = { text, n > 0 ? (uintptr_t)n : 0 };
    Wraith_Log_write(Wraith_Api_log(w), Wraith_Log_Level_err, SAL_STR("example_c"), message);
    return false;
}

/* Where the schemas' code or static `name` is, found by its signature once, or 0. */
static uintptr_t find(sal_string name) {
    uintptr_t at = 0;
    uint32_t code = Wraith_Schema_address(Wraith_Api_schema(w), name, &at);
    if (code != SAL_OK) failed(name.ptr, code);
    return at;
}

/* Free shopping. Shops still take your Mira, just none of it */

static ExampleC_GameStateManager_spendMira_fn spend_mira_original;

static uint32_t spend_mira(ExampleC_GameStateManager *self, uint32_t amount) {
    (void)amount;
    return spend_mira_original(self, 0);
}

static bool add_free_shopping(void) {
    uintptr_t at = find(SAL_STR(ExampleC_GameStateManager_spendMira_name));
    if (!at) return false;
    // Off till the tweak's on, so it's never called before `original` is known
    Wraith_Hook_Options options = { .disabled = true };
    Wraith_Hook hook;
    uint32_t code = Wraith_Hooks_detourNative(Wraith_Api_hooks(w), at, (uintptr_t)spend_mira, options, &hook);
    if (code != SAL_OK) return failed("Hooking spendMira", code);
    spend_mira_original = (ExampleC_GameStateManager_spendMira_fn)Wraith_Hook_original(hook);
    Wraith_Tweaks_Definition definition = { .id = SAL_STR("free_shopping"), .title = SAL_STR("Free shopping") };
    code = Wraith_Tweaks_addHook(Wraith_Api_tweaks(w), SAL_STR("Money"), definition, hook);
    return code == SAL_OK || failed("Adding Free shopping", code);
}

/* Give Mira, with an amount you choose. Each field comes as a `changed` just before it runs */

static uint32_t give_amount = 10000;

static uint32_t give_mira(uintptr_t self, Wraith_Tweaks_Event event) {
    (void)self;
    if (event.kind == Wraith_Tweaks_EventKind_changed) give_amount = (uint32_t)event.value;
    if (event.kind != Wraith_Tweaks_EventKind_on) return SAL_OK;
    uintptr_t instance = find(SAL_STR(ExampleC_GameStateManager_instance_name));
    ExampleC_GameStateManager *manager = instance ? *(ExampleC_GameStateManager **)instance : NULL;
    if (!manager) {
        Wraith_Log_warn(Wraith_Api_log(w), SAL_STR("Load a save first"));
        return Wraith_TweakError_Failed;
    }
    uintptr_t give = find(SAL_STR(ExampleC_GameStateManager_giveMira_name));
    if (!give) return Wraith_TweakError_Failed;
    ((ExampleC_GameStateManager_giveMira_fn)give)(manager, give_amount);
    return SAL_OK;
}

static const Wraith_Tweaks_Handler_table give_mira_table = { SAL_TABLE(Wraith_Tweaks_Handler), .call = give_mira };

static const Wraith_Tweaks_Field give_mira_fields[] = {
    { .name = SAL_STR("amount"), .type = Wraith_Tweaks_FieldType_u32, .value = 10000, .has_min = true, .min = 1 },
};

static bool add_give_mira(void) {
    Wraith_Tweaks_Definition definition = {
        .id = SAL_STR("give_mira"),
        .title = SAL_STR("Give Mira"),
        .mode = Wraith_Tweaks_Mode_action,
        .fields = { give_mira_fields, 1 },
    };
    Wraith_Tweaks_Handler handler = { 0, &give_mira_table };
    uint32_t code = Wraith_Tweaks_addIn(Wraith_Api_tweaks(w), SAL_STR("Money"), definition, handler);
    return code == SAL_OK || failed("Adding Give Mira", code);
}

/* Tailing without being seen. Being seen needs the gauge full, so skip both. `expect` stops it
 * patching a game that changed */

static Wraith_Patch tailing[2];

static uint32_t tailing_stealth(uintptr_t self, Wraith_Tweaks_Event event) {
    (void)self;
    for (int i = 0; i < 2; i++) {
        uint32_t code = SAL_OK;
        if (event.kind == Wraith_Tweaks_EventKind_on) code = Wraith_Patch_enable(tailing[i]);
        else if (event.kind == Wraith_Tweaks_EventKind_off) Wraith_Patch_disable(tailing[i]);
        if (code != SAL_OK) return code;
    }
    return SAL_OK;
}

static const Wraith_Tweaks_Handler_table tailing_stealth_table = { SAL_TABLE(Wraith_Tweaks_Handler), .call = tailing_stealth };

static bool patch(sal_string name, const uint8_t *bytes, uintptr_t len, sal_string expect, Wraith_Patch *out) {
    uintptr_t at = find(name);
    if (!at) return false;
    Wraith_Patch_Options options = { .expect = expect, .disabled = true };
    Slice_u8 with = { bytes, len };
    uint32_t code = Wraith_Code_patchBytes(Wraith_Api_code(w), at, with, options, out);
    return code == SAL_OK || failed(name.ptr, code);
}

static bool add_tailing_stealth(void) {
    static const uint8_t jump[] = { 0xEB };
    static const uint8_t skip[] = { 0xEB, 0x02 };
    if (!patch(SAL_STR(ExampleC_tailing_seen_name), jump, sizeof jump, SAL_STR("76"), &tailing[0])) return false;
    if (!patch(SAL_STR(ExampleC_tailing_gauge_name), skip, sizeof skip, SAL_STR("F3 0F 5F FE"), &tailing[1])) return false;
    Wraith_Tweaks_Definition definition = { .id = SAL_STR("tailing_stealth"), .title = SAL_STR("Tailing without being seen") };
    Wraith_Tweaks_Handler handler = { 0, &tailing_stealth_table };
    uint32_t code = Wraith_Tweaks_addIn(Wraith_Api_tweaks(w), SAL_STR("Field"), definition, handler);
    return code == SAL_OK || failed("Adding Tailing without being seen", code);
}

/* Or let it fill, slower. A mid hook runs with the registers right there in the game's code */

/* Set on the render thread, read on the game's. A float's written whole */
static volatile float gauge_speed = 0.25f;
static Wraith_Hook slow_gauge;

/* xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept */
static void gauge_store(uintptr_t self, Wraith_Cpu *cpu) {
    (void)self;
    ExampleC_TailingState *state = (ExampleC_TailingState *)(uintptr_t)cpu->rdi;
    float next = cpu->xmm7.f32x4[0];
    cpu->xmm7.f32x4[0] = state->gauge + (next - state->gauge) * gauge_speed;
}

static const Wraith_Hooks_MidHandler_table gauge_store_table = { SAL_TABLE(Wraith_Hooks_MidHandler), .call = gauge_store };

static uint32_t slow_tailing_gauge(uintptr_t self, Wraith_Tweaks_Event event) {
    (void)self;
    if (event.kind == Wraith_Tweaks_EventKind_changed) gauge_speed = (float)event.value;
    else if (event.kind == Wraith_Tweaks_EventKind_on) return Wraith_Hook_enable(slow_gauge);
    else if (event.kind == Wraith_Tweaks_EventKind_off) Wraith_Hook_disable(slow_gauge);
    return SAL_OK;
}

static const Wraith_Tweaks_Handler_table slow_tailing_gauge_table = { SAL_TABLE(Wraith_Tweaks_Handler), .call = slow_tailing_gauge };

static const Wraith_Tweaks_Field slow_tailing_gauge_fields[] = {
    { .name = SAL_STR("speed"), .type = Wraith_Tweaks_FieldType_f32, .value = 0.25, .has_min = true, .min = 0, .has_max = true, .max = 1 },
};

static bool add_slow_tailing_gauge(void) {
    uintptr_t at = find(SAL_STR(ExampleC_tailing_gauge_store_name));
    if (!at) return false;
    Wraith_Hooks_MidOptions options = { .expect = SAL_STR("F3 0F 11 BF D4 00 00 00"), .disabled = true };
    Wraith_Hooks_MidHandler handler = { 0, &gauge_store_table };
    uint32_t code = Wraith_Hooks_mid(Wraith_Api_hooks(w), at, options, handler, &slow_gauge);
    if (code != SAL_OK) return failed("Hooking the tailing gauge", code);
    Wraith_Tweaks_Definition definition = {
        .id = SAL_STR("slow_tailing_gauge"),
        .title = SAL_STR("Slower tailing gauge"),
        .fields = { slow_tailing_gauge_fields, 1 },
    };
    Wraith_Tweaks_Handler tweak = { 0, &slow_tailing_gauge_table };
    code = Wraith_Tweaks_addIn(Wraith_Api_tweaks(w), SAL_STR("Field"), definition, tweak);
    return code == SAL_OK || failed("Adding Slower tailing gauge", code);
}

/* What Wraith calls */

static bool start(sal_Host host, wraith_Guest guest) {
    (void)host;
    w = wraith_root(guest);
    // Each adds what it can, so one the game changed doesn't stop the rest
    bool all = add_free_shopping();
    all = add_give_mira() && all;
    all = add_tailing_stealth() && all;
    all = add_slow_tailing_gauge() && all;
    if (!all) Wraith_Log_warn(Wraith_Api_log(w), SAL_STR("Some tweaks couldn't be added, see above"));
    return true;
}

/* Wraith takes its hooks, patches and tweaks away itself */
static void stop(void) {}

WRAITH_PLUGIN(start, stop)
