// Ported from the Tauri producer's input_inject.rs. Two changes from the
// original, both required by moving out of Tauri:
//   1. Screen dimensions come from Enigo's own Mouse::main_display() instead
//      of tauri::AppHandle::primary_monitor().
//   2. No #[tauri::command] - inject_input() is a plain flutter_rust_bridge
//      entry point instead, called with the raw JSON string received on the
//      calleeRecv data channel.
//
// InputEvent, the match-arm logic, and map_key() are kept as close to
// verbatim as possible - the key-mapping table was already tuned upstream
// (unmapped keys are deliberately dropped, not guessed at).
//
// Threading: docs.rs confirms `Enigo: Send` but `Enigo: !Sync` (auto-trait
// implementations on the Enigo struct page), so it can be moved to and owned
// by one dedicated thread, but can't be safely shared by reference across
// threads. Mousemove fires up to 60fps over the data channel, so recreating
// Enigo (a fresh OS-level connection) on every event, as the original Tauri
// command did per-call, is wasteful. Instead a single dedicated thread owns
// one long-lived Enigo instance for the process lifetime, fed via an mpsc
// channel - mirroring the capture/encode/network 3-thread split already used
// in the native video pipeline, rather than sharing one instance behind a
// Mutex (which would also be valid given Send, but adds lock contention on
// this hot path for no benefit here).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;

use enigo::{
    Button, Coordinate,
    Direction::{Press, Release},
    Enigo, Key, Keyboard, Mouse, Settings,
};
use serde::Deserialize;

/// Minimal libdispatch binding to run a closure synchronously on the main
/// queue. macOS's Text Input Sources API (TIS/TSM) hard-asserts it is called
/// on the main dispatch queue - dispatch_assert_queue() SIGTRAPs the whole
/// process otherwise, it is not a catchable error. enigo's keycode lookup
/// for layout-dependent keys (Key::Unicode, i.e. every plain character)
/// goes through TSMGetInputSourceProperty, so calling enigo.key() from the
/// injector thread crashed the app on the first typed character (crash
/// report: islGetInputSourceListWithAdditions -> _dispatch_assert_queue_fail
/// on thread "input-injector"). Mouse events use CGEvent posting only, which
/// is thread-safe - they stay on the injector thread. Raw FFI rather than a
/// dispatch crate: one function is not worth a new dependency.
#[cfg(target_os = "macos")]
mod main_thread {
    use std::ffi::c_void;

    #[repr(C)]
    struct DispatchQueue {
        _private: [u8; 0],
    }

    extern "C" {
        static _dispatch_main_q: DispatchQueue;
        fn dispatch_sync_f(
            queue: *const DispatchQueue,
            context: *mut c_void,
            work: extern "C" fn(*mut c_void),
        );
    }

    /// Blocks the calling thread until `f` has run on the main queue.
    /// Because the caller is parked for the duration, handing the closure
    /// mutable borrows from the calling thread is race-free. Must never be
    /// called from the main thread itself (dispatch_sync would deadlock) -
    /// the injector thread is the only caller.
    pub fn run_sync<F: FnOnce() + Send>(f: F) {
        extern "C" fn invoke<F: FnOnce()>(context: *mut c_void) {
            let f = unsafe { (*(context as *mut Option<F>)).take() };
            if let Some(f) = f {
                f();
            }
        }
        let mut f: Option<F> = Some(f);
        unsafe {
            dispatch_sync_f(
                &_dispatch_main_q,
                &mut f as *mut Option<F> as *mut c_void,
                invoke::<F>,
            );
        }
    }
}

/// Raw FFI to user32's ShowCursor, hiding/restoring the native OS cursor for
/// the duration of a remote-control session (the agent's own crosshair
/// overlay is the only pointer feedback meant to be visible - see
/// DECISIONS.md's "agent renders a local cursor" entry). Same "raw FFI, not
/// a new crate dependency" convention as the macOS `main_thread` module
/// above: ShowCursor is one function, not worth pulling in the `windows` or
/// `winapi` crate for.
///
/// Known caveat: ShowCursor's display counter is maintained per-thread by
/// Windows. If flutter_rust_bridge ever dispatches this call from a
/// different OS thread on each invocation, hide()/show() could under- or
/// over-shoot the counter relative to whichever thread actually owns the
/// desktop's cursor rendering. Verify this visibly hides/restores the
/// cursor at runtime, not just that the FFI call returns without error - if
/// it doesn't, the next step is a WH_MOUSE_LL hook or a dedicated
/// message-pump thread, not more calls to this same function.
///
/// Defined unconditionally (a no-op stub on non-Windows) rather than
/// `#[cfg(target_os = "windows")]`-gating the whole module: flutter_rust_
/// bridge's codegen inlines hide_cursor()/show_cursor()'s single-statement
/// bodies directly into frb_generated.rs *without* preserving the cfg gate
/// that was on the call site inside them (confirmed - it broke the macOS CI
/// build, which compiles frb_generated.rs unconditionally). Keeping the
/// module itself platform-unconditional means that generated call always
/// resolves, regardless of what the codegen does or doesn't inline.
#[cfg(target_os = "windows")]
pub(crate) mod win_cursor {
    #[link(name = "user32")]
    extern "system" {
        fn ShowCursor(bshow: i32) -> i32;
    }

    pub fn hide() {
        unsafe {
            while ShowCursor(0) >= 0 {}
        }
    }

    pub fn show() {
        unsafe {
            while ShowCursor(1) < 0 {}
        }
    }
}

#[cfg(not(target_os = "windows"))]
pub(crate) mod win_cursor {
    pub fn hide() {}
    pub fn show() {}
}

/// Hides the native OS cursor for the duration of an active session
/// (Windows only for now - see DECISIONS.md, macOS to follow; a no-op
/// elsewhere). Idempotent.
pub fn hide_cursor() {
    win_cursor::hide();
}

/// Restores the native OS cursor. Idempotent - safe to call unconditionally
/// on every session-end path, including abnormal termination, so a crash or
/// dropped connection never leaves the cursor hidden.
pub fn show_cursor() {
    win_cursor::show();
}

/// Whether the injector thread should act on queued events. Cleared between
/// sessions (teardown) so a stale in-flight event can't be injected after a
/// session has ended, and set again at the start of a new one. Does not
/// stop or recreate the injector thread itself - it's process-lifetime by
/// design (see the module doc comment above) - this just makes it inert.
static INJECTION_ARMED: AtomicBool = AtomicBool::new(true);

/// Arms the input injector for a new session. Idempotent.
pub fn start_input_injection() {
    INJECTION_ARMED.store(true, Ordering::SeqCst);
}

/// Disarms the input injector - queued/incoming events are dropped instead
/// of reaching enigo until the next `start_input_injection()`. Idempotent.
pub fn stop_input_injection() {
    INJECTION_ARMED.store(false, Ordering::SeqCst);
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}

#[derive(Deserialize)]
struct InputEvent {
    #[serde(rename = "type")]
    event_type: String,
    x: Option<f64>,
    y: Option<f64>,
    button: Option<String>,
    key: Option<String>,
    #[serde(rename = "deltaX")]
    #[allow(dead_code)] // not read yet - horizontal scroll isn't wired in the original either
    delta_x: Option<f64>,
    #[serde(rename = "deltaY")]
    delta_y: Option<f64>,
}

/// Most recent injection-side failure, surfaced back through inject_input()'s
/// Result so it reaches the Dart on-screen log. eprintln! alone is useless in
/// a packaged .app: Rust stderr never passes through Dart's print() capture,
/// which is how the real Enigo init error stayed invisible on macOS while the
/// UI only showed "sending on a closed channel".
fn last_error() -> &'static Mutex<Option<String>> {
    static LAST_ERROR: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    LAST_ERROR.get_or_init(|| Mutex::new(None))
}

fn record_error(msg: String) {
    eprintln!("[input_inject] {msg}");
    *last_error().lock().unwrap() = Some(msg);
}

fn injector_sender() -> &'static Sender<InputEvent> {
    static SENDER: OnceLock<Sender<InputEvent>> = OnceLock::new();
    SENDER.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<InputEvent>();
        thread::Builder::new()
            .name("input-injector".into())
            .spawn(move || injector_loop(rx))
            .expect("failed to spawn input-injector thread");
        tx
    })
}

fn injector_loop(rx: Receiver<InputEvent>) {
    // Enigo init is lazy and retried per event rather than done once up
    // front: on macOS Enigo::new() fails until the user grants Accessibility
    // permission (System Settings > Privacy & Security > Accessibility).
    // The original code returned from the thread on that first failure,
    // dropping the Receiver - so every later send hit a closed channel
    // forever, even after the user granted permission. Retrying lets
    // injection come alive mid-session the moment the grant lands.
    let mut enigo: Option<Enigo> = None;

    for event in rx {
        if enigo.is_none() {
            match Enigo::new(&Settings::default()) {
                Ok(e) => enigo = Some(e),
                Err(e) => {
                    record_error(format!(
                        "Enigo init failed: {e}. On macOS: System Settings > \
                         Privacy & Security > Accessibility > enable this app, \
                         then try again (input events are dropped until then)."
                    ));
                    continue;
                }
            }
        }
        if let Err(e) = handle_event(enigo.as_mut().unwrap(), event) {
            record_error(format!("error handling event: {e}"));
        }
    }
}

fn handle_event(enigo: &mut Enigo, payload: InputEvent) -> Result<(), String> {
    if !INJECTION_ARMED.load(Ordering::SeqCst) {
        return Ok(());
    }
    match payload.event_type.as_str() {
        "mousemove" => {
            let (screen_w, screen_h) = enigo.main_display().map_err(|e| e.to_string())?;
            let x = (payload.x.unwrap_or(0.0) * screen_w as f64) as i32;
            let y = (payload.y.unwrap_or(0.0) * screen_h as f64) as i32;
            enigo
                .move_mouse(x, y, Coordinate::Abs)
                .map_err(|e| e.to_string())?;
        }
        "mousedown" | "mouseup" => {
            let (screen_w, screen_h) = enigo.main_display().map_err(|e| e.to_string())?;
            let x = (payload.x.unwrap_or(0.0) * screen_w as f64) as i32;
            let y = (payload.y.unwrap_or(0.0) * screen_h as f64) as i32;
            enigo
                .move_mouse(x, y, Coordinate::Abs)
                .map_err(|e| e.to_string())?;
            let btn = match payload.button.as_deref().unwrap_or("Left") {
                "Right" => Button::Right,
                "Middle" => Button::Middle,
                _ => Button::Left,
            };
            let dir = if payload.event_type == "mousedown" {
                Press
            } else {
                Release
            };
            enigo.button(btn, dir).map_err(|e| e.to_string())?;
        }
        "scroll" => {
            let dy = payload.delta_y.unwrap_or(0.0);
            if dy.abs() > 0.0 {
                // delta_y is in pixels; convert to scroll clicks (~120px each)
                let clicks = (dy / 120.0).round() as i32;
                if clicks != 0 {
                    enigo
                        .scroll(clicks, enigo::Axis::Vertical)
                        .map_err(|e| e.to_string())?;
                }
            }
        }
        "keydown" | "keyup" => {
            let dir = if payload.event_type == "keydown" {
                Press
            } else {
                Release
            };
            if let Some(k) = payload.key.as_deref().and_then(map_key) {
                // macOS: must run on the main queue - see the main_thread
                // module docs. Everywhere else the direct call is fine.
                #[cfg(target_os = "macos")]
                {
                    let mut err: Option<String> = None;
                    {
                        let enigo_ref = &mut *enigo;
                        let err_ref = &mut err;
                        main_thread::run_sync(move || {
                            if let Err(e) = enigo_ref.key(k, dir) {
                                *err_ref = Some(e.to_string());
                            }
                        });
                    }
                    if let Some(e) = err {
                        return Err(e);
                    }
                }
                #[cfg(not(target_os = "macos"))]
                enigo.key(k, dir).map_err(|e| e.to_string())?;
            }
        }
        _ => {}
    }

    Ok(())
}

fn map_key(key: &str) -> Option<Key> {
    match key {
        "Enter" => Some(Key::Return),
        "Backspace" => Some(Key::Backspace),
        "Delete" => Some(Key::Delete),
        "Tab" => Some(Key::Tab),
        "Escape" => Some(Key::Escape),
        "ArrowUp" => Some(Key::UpArrow),
        "ArrowDown" => Some(Key::DownArrow),
        "ArrowLeft" => Some(Key::LeftArrow),
        "ArrowRight" => Some(Key::RightArrow),
        "Home" => Some(Key::Home),
        "End" => Some(Key::End),
        "PageUp" => Some(Key::PageUp),
        "PageDown" => Some(Key::PageDown),
        "F1" => Some(Key::F1),
        "F2" => Some(Key::F2),
        "F3" => Some(Key::F3),
        "F4" => Some(Key::F4),
        "F5" => Some(Key::F5),
        "F6" => Some(Key::F6),
        "F7" => Some(Key::F7),
        "F8" => Some(Key::F8),
        "F9" => Some(Key::F9),
        "F10" => Some(Key::F10),
        "F11" => Some(Key::F11),
        "F12" => Some(Key::F12),
        "Control" => Some(Key::Control),
        "Shift" => Some(Key::Shift),
        "Alt" => Some(Key::Alt),
        "Meta" | "OS" => Some(Key::Meta),
        "CapsLock" => Some(Key::CapsLock),
        k if k.chars().count() == 1 => Some(Key::Unicode(k.chars().next().unwrap())),
        _ => None,
    }
}

/// Called from Dart with the raw JSON string received on the calleeRecv
/// data channel - same shape the reference Tauri app already deserializes
/// with serde, no reformatting needed on the Dart side. Returns immediately
/// (just a channel send); actual injection happens on the dedicated thread.
pub fn inject_input(payload_json: String) -> Result<(), String> {
    let event: InputEvent = serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    injector_sender().send(event).map_err(|e| e.to_string())?;
    // Surface (and clear) any error recorded by the injector thread so the
    // real cause lands in the Dart-side log instead of a bare channel error.
    if let Some(msg) = last_error().lock().unwrap().take() {
        return Err(msg);
    }
    Ok(())
}
