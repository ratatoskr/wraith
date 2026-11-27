//! What makes a Rust crate a Wraith plugin. Everything else is Wraith's API, from its schemas, in [`api`].
//!
//! ```ignore
//! struct Hello;
//!
//! impl wraith::Plugin for Hello {
//!     fn start() -> Option<Self> {
//!         wraith::api().log().info("Hello!");
//!         Some(Hello)
//!     }
//! }
//!
//! wraith::plugin!(Hello);
//! ```
//!
//! It's made as the plugin starts and dropped once it's stopped. Its schemas' game code, like
//! `Player::main()`, is found through Wraith. What it keeps or offers stops being called once it's unloading.

use std::sync::{Mutex, RwLock};

use salamander::{Host, Object, Owner, Queue, Slice, Str, TraitObject};

/// Wraith's API, for the pointer size it's built for.
pub mod api {
    #[cfg(target_pointer_width = "64")]
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/api_64.rs"));
    #[cfg(target_pointer_width = "32")]
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/api_32.rs"));
}

pub use api::wraith::*;
pub use salamander;

/// Only changes when Wraith's native entry does.
pub const NATIVE_VERSION: u32 = 2;

/// What the plugin gets as it starts.
#[repr(C)]
pub struct Guest {
    pub wraith: Object,
    pub owner: *mut Owner,
    pub render_queue: Queue,
    /// Only good during start.
    pub services: Slice<PluginService>,
}

/// What `wraith_plugin` gives.
#[repr(C)]
pub struct Entry {
    pub version: u32,
    pub start: extern "C" fn(host: Host, guest: Guest) -> bool,
    pub stop: extern "C" fn(),
    pub service: extern "C" fn(trait_name: Str) -> Object,
}

const _: () = assert!(std::mem::size_of::<Guest>() == 7 * std::mem::size_of::<usize>());

/// A plugin. `start` gives it, or None if it couldn't start.
pub trait Plugin: Sized + 'static {
    fn start() -> Option<Self>;

    fn stop(&mut self) {}

    /// What it offers for a [Service] trait in its schemas, like `wraith::offer(Freecam::from_static(&CAM))`.
    fn service(&self, trait_name: &str) -> Object {
        let _ = trait_name;
        Object::default()
    }
}

struct Shared {
    api: Api,
    render: Queue,
    services: Vec<PluginService>,
}

static SHARED: RwLock<Option<Shared>> = RwLock::new(None);
/// The plugin, boxed, while it runs.
static PLUGIN: Mutex<usize> = Mutex::new(0);

/// This plugin's Wraith. Stops working once it's unloading.
pub fn api() -> Api {
    SHARED.read().ok().and_then(|s| s.as_ref().map(|s| s.api)).unwrap_or_default()
}

pub fn host() -> Host {
    salamander::host()
}

/// Guards what it offers and keeps, which stop being called once it's unloading.
pub fn owner() -> *mut Owner {
    salamander::owner()
}

/// Polled on the render thread each frame.
pub fn render_queue() -> Queue {
    SHARED.read().ok().and_then(|s| s.as_ref().map(|s| s.render)).unwrap_or_default()
}

/// What dependency `plugin` offers as [Service] trait `T`, or one with no table.
pub fn service<T: TraitObject>(plugin: &str) -> T {
    let found = SHARED.read().ok().and_then(|s| {
        s.as_ref()?.services.iter().find(|x| unsafe { x.plugin.get() == plugin && x.r#trait.get() == T::INFO.name.get() }).map(|x| x.obj)
    });
    match found {
        Some(o) => T::from_object(host().adapt(o, T::INFO as *const salamander::Info as *mut salamander::Info)),
        None => T::default(),
    }
}

/// Whether a service call is asking for `T`.
pub fn asks_for<T: TraitObject>(trait_name: &str) -> bool {
    trait_name == unsafe { T::INFO.name.get() }
}

/// `obj` owned by this plugin, for its service to give back.
pub fn offer<T: TraitObject>(obj: T) -> Object {
    salamander::own(obj, owner()).object()
}

fn locate(name: &str) -> usize {
    api().schema().address(name).unwrap_or(0)
}

#[doc(hidden)]
pub fn entry<P: Plugin>() -> *const Entry {
    const { &Entry { version: NATIVE_VERSION, start: start::<P>, stop: stop::<P>, service: service_of::<P> } }
}

extern "C" fn start<P: Plugin>(host: Host, guest: Guest) -> bool {
    salamander::init(host, guest.owner);
    let services = unsafe { guest.services.get() }.to_vec();
    if let Ok(mut s) = SHARED.write() {
        *s = Some(Shared { api: Api::from_object(guest.wraith), render: guest.render_queue, services });
    }
    salamander::declared::set_locator(Some(locate));
    let Some(made) = std::panic::catch_unwind(P::start).ok().flatten() else { return false };
    if let Ok(mut p) = PLUGIN.lock() {
        *p = Box::into_raw(Box::new(made)) as usize;
    }
    true
}

// Called even when start failed
extern "C" fn stop<P: Plugin>() {
    let p = PLUGIN.lock().map(|mut p| std::mem::take(&mut *p)).unwrap_or(0);
    if p != 0 {
        let mut plugin = unsafe { Box::from_raw(p as *mut P) };
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            plugin.stop();
            drop(plugin);
        }));
    }
    salamander::declared::set_locator(None);
    if let Ok(mut s) = SHARED.write() {
        *s = None;
    }
}

extern "C" fn service_of<P: Plugin>(trait_name: Str) -> Object {
    let p = PLUGIN.lock().map(|p| *p).unwrap_or(0);
    if p == 0 {
        return Object::default();
    }
    let plugin = unsafe { &*(p as *const P) };
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| plugin.service(unsafe { trait_name.get() }))).unwrap_or_default()
}

/// Exports `wraith_plugin`, which Wraith starts the plugin through.
#[macro_export]
macro_rules! plugin {
    ($t:ty) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn wraith_plugin() -> *const $crate::Entry {
            $crate::entry::<$t>()
        }
    };
}
