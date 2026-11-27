//! A Rust plugin for the loader's tests, built with cargo over what `wraith sdk rust types` writes.
//! Its tweak `rust_fixture:count` fails when `step` is 0.

use std::sync::atomic::{AtomicU32, Ordering};

use salamander::{Code, Object, Slice, Str};
use wraith::{TweakError, TweaksDefinition, TweaksEvent, TweaksEventKind, TweaksField, TweaksFieldType, TweaksHandler, TweaksMode};

#[allow(dead_code)]
mod schema {
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/.wraith/rust/schema.rs"));
}

static STEP: AtomicU32 = AtomicU32::new(1);
static COUNT: AtomicU32 = AtomicU32::new(0);

#[unsafe(no_mangle)]
pub extern "C" fn wraith_rust_count() -> u32 {
    COUNT.load(Ordering::Relaxed)
}

// Its schema's types use Wraith's own
const _: fn(schema::Spot) -> wraith::Vec3 = |s| s.at;

struct Service;

impl schema::RustServiceImpl for Service {
    fn total(&self) -> u32 {
        5
    }

    // Three times what a future settled first gives, once an async block's had it
    fn later(&self) -> salamander::Future<u32> {
        salamander::spawn(async {
            let (f, settle) = salamander::promise::<u32, Code>();
            settle.resolve(7);
            Ok(f.await? * 3)
        })
    }
}

static SERVICE: Service = Service;

static FIELDS: [TweaksField; 1] = [TweaksField { name: Str::new("step"), r#type: TweaksFieldType::U32, value: 1.0, ..unsafe { std::mem::zeroed() } }];

struct Fixture;

impl wraith::Plugin for Fixture {
    fn start() -> Option<Self> {
        wraith::api().log().info("Rust plugin starting");
        let definition = TweaksDefinition {
            id: Str::new("count"),
            title: Str::new("Count"),
            mode: TweaksMode::ACTION,
            fields: Slice::of(&FIELDS),
            ..Default::default()
        };
        // Wraith keeps it, so it's a heap copy it lets go of
        let handler = TweaksHandler::keep(|event: TweaksEvent| -> Result<(), TweakError> {
            if event.kind == TweaksEventKind::CHANGED {
                STEP.store(event.value as u32, Ordering::Relaxed);
            }
            if event.kind != TweaksEventKind::ON {
                return Ok(());
            }
            let step = STEP.load(Ordering::Relaxed);
            if step == 0 {
                return Err(TweakError::FAILED);
            }
            COUNT.fetch_add(step, Ordering::Relaxed);
            Ok(())
        });
        wraith::api().tweaks().add_in("Test", definition, handler).ok()?;
        Some(Fixture)
    }

    // RustService for plugins that depend on this one, owned so it stops when this one goes
    fn service(&self, trait_name: &str) -> Object {
        if wraith::asks_for::<schema::RustService>(trait_name) {
            return wraith::offer(schema::RustService::from_static(&SERVICE));
        }
        Object::default()
    }
}

wraith::plugin!(Fixture);
