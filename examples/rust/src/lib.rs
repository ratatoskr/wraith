// Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.
//
// Wraith's API is the wraith crate, and the game's code comes from schema below:
// `GameStateManager::instance()` and `manager.give_mira(n)` find what they call by the schema's signatures.
// Calls that can fail give a Result, and what Wraith calls back is a closure or any type with the right method.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::OnceLock;

use salamander::{Slice, Str};
use wraith::{
    Cpu, Hook, HookOptions, HooksMidHandler, HooksMidOptions, LogLevel, Patch, PatchOptions, TweakError, TweaksDefinition, TweaksEvent,
    TweaksEventKind, TweaksField, TweaksFieldType, TweaksHandler, TweaksMode,
};

#[allow(dead_code)]
mod schema {
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/.wraith/rust/schema.rs"));
}

use schema::*;

/// Says what didn't work in Wraith's log.
fn check<T, E: std::fmt::Display>(r: Result<T, E>, what: &str) -> Option<T> {
    r.map_err(|e| wraith::api().log().write(LogLevel::ERR, "example_rust", &format!("{what} failed: {e}"))).ok()
}

/// Where the schema's code or static `name` is, found by its signature once.
fn find(name: &str) -> Option<usize> {
    check(wraith::api().schema().address(name), name)
}

fn field(name: &'static str, kind: TweaksFieldType, value: f64) -> TweaksField {
    TweaksField { name: Str::new(name), r#type: kind, value, ..unsafe { std::mem::zeroed() } }
}

// Free shopping. Shops still take your Mira, just none of it

static SPEND_MIRA_ORIGINAL: OnceLock<GameStateManagerSpendMiraFn> = OnceLock::new();

unsafe extern "C" fn spend_mira(this: *mut GameStateManager, _amount: u32) -> u32 {
    unsafe { SPEND_MIRA_ORIGINAL.get().unwrap()(this, 0) }
}

fn add_free_shopping() -> Option<()> {
    let at = find(GAME_STATE_MANAGER_SPEND_MIRA_NAME)?;
    // Off till the tweak's on, so it's never called before the original is known
    let detour: GameStateManagerSpendMiraFn = spend_mira;
    let hook = check(wraith::api().hooks().detour_native(at, detour as usize, HookOptions { disabled: true, ..Default::default() }), "Hooking spendMira")?;
    let _ = SPEND_MIRA_ORIGINAL.set(unsafe { std::mem::transmute::<usize, GameStateManagerSpendMiraFn>(hook.original()) });
    let definition = TweaksDefinition { id: Str::new("free_shopping"), title: Str::new("Free shopping"), ..Default::default() };
    check(wraith::api().tweaks().add_hook("Money", definition, hook), "Adding Free shopping")
}

// Give Mira, with an amount you choose. Each field comes as a `changed` just before it runs

static GIVE_FIELDS: OnceLock<[TweaksField; 1]> = OnceLock::new();

fn add_give_mira() -> Option<()> {
    let fields = GIVE_FIELDS.get_or_init(|| [TweaksField { has_min: true, min: 1.0, ..field("amount", TweaksFieldType::U32, 10000.0) }]);
    let definition = TweaksDefinition {
        id: Str::new("give_mira"),
        title: Str::new("Give Mira"),
        mode: TweaksMode::ACTION,
        fields: Slice::of(fields),
        ..Default::default()
    };
    let amount = AtomicU32::new(10000);
    // Wraith keeps it, so it's a heap copy it lets go of
    let handler = TweaksHandler::keep(move |event: TweaksEvent| -> Result<(), TweakError> {
        if event.kind == TweaksEventKind::CHANGED {
            amount.store(event.value as u32, Ordering::Relaxed);
        }
        if event.kind != TweaksEventKind::ON {
            return Ok(());
        }
        let manager = unsafe { GameStateManager::instance() };
        if manager.is_null() {
            wraith::api().log().warn("Load a save first");
            return Err(TweakError::FAILED);
        }
        unsafe { (*manager).give_mira(amount.load(Ordering::Relaxed)) };
        Ok(())
    });
    check(wraith::api().tweaks().add_in("Money", definition, handler), "Adding Give Mira")
}

// Tailing without being seen. Being seen needs the gauge full, so skip both. `expect` stops it
// patching a game that changed

fn patch(name: &str, bytes: &'static [u8], expect: &'static str) -> Option<Patch> {
    let at = find(name)?;
    check(wraith::api().code().patch_bytes(at, bytes, PatchOptions { expect: Str::new(expect), disabled: true, ..Default::default() }), name)
}

fn add_tailing_stealth() -> Option<()> {
    let tailing = [patch(TAILING_SEEN_NAME, &[0xEB], "76")?, patch(TAILING_GAUGE_NAME, &[0xEB, 0x02], "F3 0F 5F FE")?];
    let definition = TweaksDefinition { id: Str::new("tailing_stealth"), title: Str::new("Tailing without being seen"), ..Default::default() };
    let handler = TweaksHandler::keep(move |event: TweaksEvent| -> Result<(), TweakError> {
        for p in &tailing {
            if event.kind == TweaksEventKind::ON {
                p.enable().map_err(|e| TweakError(e.0))?;
            } else if event.kind == TweaksEventKind::OFF {
                let _ = p.disable();
            }
        }
        Ok(())
    });
    check(wraith::api().tweaks().add_in("Field", definition, handler), "Adding Tailing without being seen")
}

// Or let it fill, slower. A mid hook runs with the registers right there in the game's code

// Set on the render thread, read on the game's
static GAUGE_SPEED: AtomicU32 = AtomicU32::new(0x3E80_0000); // 0.25

// xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept
static GAUGE_STORE: fn(*mut Cpu) = |cpu| unsafe {
    let cpu = &mut *cpu;
    let state = &*(cpu.rdi as usize as *const TailingState);
    let next = cpu.xmm7.f32x4[0];
    cpu.xmm7.f32x4[0] = state.gauge + (next - state.gauge) * f32::from_bits(GAUGE_SPEED.load(Ordering::Relaxed));
};

static SLOW_FIELDS: OnceLock<[TweaksField; 1]> = OnceLock::new();

fn add_slow_tailing_gauge() -> Option<()> {
    let at = find(TAILING_GAUGE_STORE_NAME)?;
    let options = HooksMidOptions { expect: Str::new("F3 0F 11 BF D4 00 00 00"), disabled: true, ..Default::default() };
    let hook: Hook = check(wraith::api().hooks().mid(at, options, HooksMidHandler::from_static(&GAUGE_STORE)), "Hooking the tailing gauge")?;
    let fields = SLOW_FIELDS.get_or_init(|| {
        [TweaksField { has_min: true, min: 0.0, has_max: true, max: 1.0, ..field("speed", TweaksFieldType::F32, 0.25) }]
    });
    let definition = TweaksDefinition {
        id: Str::new("slow_tailing_gauge"),
        title: Str::new("Slower tailing gauge"),
        fields: Slice::of(fields),
        ..Default::default()
    };
    let handler = TweaksHandler::keep(move |event: TweaksEvent| -> Result<(), TweakError> {
        if event.kind == TweaksEventKind::CHANGED {
            GAUGE_SPEED.store((event.value as f32).to_bits(), Ordering::Relaxed);
        } else if event.kind == TweaksEventKind::ON {
            hook.enable().map_err(|e| TweakError(e.0))?;
        } else if event.kind == TweaksEventKind::OFF {
            let _ = hook.disable();
        }
        Ok(())
    });
    check(wraith::api().tweaks().add_in("Field", definition, handler), "Adding Slower tailing gauge")
}

// What Wraith starts and stops

struct Example;

impl wraith::Plugin for Example {
    fn start() -> Option<Self> {
        // Each adds what it can, so one the game changed doesn't stop the rest
        let added = [add_free_shopping(), add_give_mira(), add_tailing_stealth(), add_slow_tailing_gauge()];
        if added.iter().any(Option::is_none) {
            wraith::api().log().warn("Some tweaks couldn't be added, see above");
        }
        Some(Example)
    }

    // Wraith takes its hooks, patches and tweaks away itself
}

wraith::plugin!(Example);
