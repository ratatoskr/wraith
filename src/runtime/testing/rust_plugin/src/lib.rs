//! A Rust plugin for the loader's tests, built with cargo over what `wraith sdk rust types` writes.
//! Its tweak `rust_fixture:count` fails when `step` is 0.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};

use salamander::{Code, Object, Slice, Str};
use wraith::{
    TweakError, TweaksDefinition, TweaksEvent, TweaksEventKind, TweaksField, TweaksFieldType,
    TweaksHandler, TweaksMode,
};

#[allow(dead_code)]
mod schema {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/.wraith/rust/schema.rs"
    ));
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

// The Notes tab, many at once, which the loader's tests call like the Workbench does
struct Notes {
    made: AtomicU32,
    drawn: AtomicU32,
    title: Mutex<String>,
}

impl wraith::WorkbenchTabImpl for Notes {
    fn describe(&self) -> wraith::WorkbenchTabInfo {
        wraith::WorkbenchTabInfo {
            title: Str::new("Notes"),
            kind: Str::new("notes"),
            place: wraith::WorkbenchPanelPlace::BOTTOM,
            multi: true,
            ..unsafe { std::mem::zeroed() }
        }
    }

    fn draw(&self, _id: &str) {
        self.drawn.fetch_add(1, Ordering::Relaxed);
    }

    // "Note <id> drawn <draws>", not saved. The title lasts till the next one
    fn status(&self, id: &str) -> wraith::WorkbenchTabState {
        let mut title = self.title.lock().unwrap();
        *title = format!("Note {id} drawn {}", self.drawn.load(Ordering::Relaxed));
        wraith::WorkbenchTabState {
            title: Str::new(&title),
            unsaved: true,
            ..unsafe { std::mem::zeroed() }
        }
    }

    fn create(&self) -> &str {
        const IDS: [&str; 10] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
        IDS[(self.made.fetch_add(1, Ordering::Relaxed) as usize + 1) % 10]
    }

    // The first stays open
    fn keep_open(&self, id: &str) -> bool {
        id == "1"
    }
}

static NOTES: Notes = Notes {
    made: AtomicU32::new(0),
    drawn: AtomicU32::new(0),
    title: Mutex::new(String::new()),
};

static FIELDS: [TweaksField; 1] = [TweaksField {
    name: Str::new("step"),
    r#type: TweaksFieldType::U32,
    value: 1.0,
    ..unsafe { std::mem::zeroed() }
}];

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
        wraith::api()
            .tweaks()
            .add_in("Test", definition, handler)
            .ok()?;
        wraith::api()
            .ui()
            .add_workbench_tab(wraith::WorkbenchTab::from_static(&NOTES))
            .ok()?;
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
