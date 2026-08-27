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

// The sharer's cursor is now excluded from the captured video at the source,
// via a `cursor: 'never'` getDisplayMedia constraint honored by the vendored
// flutter_webrtc patch (see pubspec.yaml / DECISIONS.md). The earlier attempt
// to hide the OS cursor from Rust (user32 ShowCursor) was removed: ShowCursor's
// counter is per-thread and flutter_rust_bridge runs the call off the UI
// thread, so it never visibly hid anything.

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
    on: Option<bool>,
    #[serde(rename = "deltaX")]
    #[allow(dead_code)] // not read yet - horizontal scroll isn't wired in the original either
    delta_x: Option<f64>,
    #[serde(rename = "deltaY")]
    delta_y: Option<f64>,
    // Whether Ctrl (Windows/Linux) / Cmd (macOS) is held on this keydown/
    // keyup, as reported by the agent's KeyboardEvent.ctrlKey/metaKey. Used
    // to decide text() vs a real key() press in handle_event() below - see
    // the comment there. serde has no deny_unknown_fields, so before this
    // field existed the agent's already-sent `ctrl` value was silently
    // dropped on the floor; that was the root cause of Ctrl+C/A/Z-style
    // chords never registering.
    ctrl: Option<bool>,
    meta: Option<bool>,
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

/// Last CapsLock state actually applied to this OS by this process. Compared
/// against each incoming "capslock" message so a duplicate/replayed message
/// (the data channel is unordered with zero retransmits, same reliability
/// concern the mousemove seq staleness check elsewhere in this pipeline
/// handles) can never re-toggle an already-correct state.
fn caps_lock_state() -> &'static Mutex<bool> {
    static CAPS_LOCK_STATE: OnceLock<Mutex<bool>> = OnceLock::new();
    CAPS_LOCK_STATE.get_or_init(|| Mutex::new(false))
}

/// Runs a fallible Enigo-mutating operation, hopping onto the main thread
/// first on macOS (TSM/TIS's hard main-thread requirement - see the
/// main_thread module docs above). A plain direct call everywhere else.
fn run_keyboard_op(
    enigo: &mut Enigo,
    op: impl FnOnce(&mut Enigo) -> enigo::InputResult<()> + Send,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let mut err: Option<String> = None;
        {
            let err_ref = &mut err;
            main_thread::run_sync(move || {
                if let Err(e) = op(enigo) {
                    *err_ref = Some(e.to_string());
                }
            });
        }
        match err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        op(enigo).map_err(|e| e.to_string())
    }
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

/// Fires this customer's own native copy shortcut (Cmd+C on macOS, Ctrl+C
/// elsewhere) on itself, then gives the focused app a moment to react before
/// returning. Called ONLY from the explicit "Copy from Customer" request
/// handler (producer_home_page.dart's _handleClipboardCopyRequest) — never
/// from agent-forwarded input. This is deliberately not a general Ctrl<->Cmd
/// translation of forwarded keystrokes: that would hijack e.g. a terminal's
/// Ctrl+C (SIGINT) the moment an agent typed it for an unrelated reason, with
/// no way to tell the two apart from a raw key event alone. Firing only in
/// response to an explicit, already-authorized copy request is a fundamentally
/// different (and far rarer) risk than intercepting every incidental Ctrl+C -
/// see decision.md ("Cross-Platform Copy Shortcut Handling") for the full
/// design rationale, including why transparent interception was rejected.
///
/// Reuses the injector thread/channel (constructing InputEvents directly,
/// skipping the JSON round-trip inject_input() does for agent-sourced events)
/// so this gets the same macOS main-thread handling and Enigo lazy-init-with-
/// retry as every other injected key, instead of duplicating that logic.
pub fn press_native_copy_shortcut() -> Result<(), String> {
    let modifier = if cfg!(target_os = "macos") { "Meta" } else { "Control" };
    let sender = injector_sender();
    let held = |on: bool| InputEvent {
        event_type: String::new(),
        x: None,
        y: None,
        button: None,
        key: None,
        on: None,
        delta_x: None,
        delta_y: None,
        ctrl: Some(on && modifier == "Control"),
        meta: Some(on && modifier == "Meta"),
    };
    let synthetic = [
        InputEvent { event_type: "keydown".into(), key: Some(modifier.into()), ..held(true) },
        InputEvent { event_type: "keydown".into(), key: Some("c".into()), ..held(true) },
        InputEvent { event_type: "keyup".into(), key: Some("c".into()), ..held(false) },
        InputEvent { event_type: "keyup".into(), key: Some(modifier.into()), ..held(false) },
    ];
    for event in synthetic {
        sender.send(event).map_err(|e| e.to_string())?;
    }
    // No completion signal comes back from the injector thread - this is a
    // pragmatic settle delay (same category of heuristic already used
    // elsewhere in this app, e.g. the video reveal gate's resize debounce)
    // giving the target app time to actually update its clipboard before
    // the caller reads it.
    thread::sleep(std::time::Duration::from_millis(200));
    Ok(())
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
            // Ctrl (Windows/Linux) or Cmd (macOS) held on THIS event, per the
            // agent's KeyboardEvent.ctrlKey/metaKey.
            let modifier_held = payload.ctrl.unwrap_or(false) || payload.meta.unwrap_or(false);
            if let Some(k) = payload.key.as_deref().and_then(map_key) {
                match k {
                    // Printable characters are injected as literal Unicode
                    // text rather than a held key press/release, UNLESS a
                    // Ctrl/Cmd modifier is currently held - see the Release
                    // arm below for why, and why routing through key() here
                    // is still safe for the plain-typing case this sidesteps.
                    //
                    // The text() path exists to dodge a real bug in enigo
                    // 0.6.1's Windows backend: Key::Unicode's press/release
                    // path resolves the character via VkKeyScanExW, whose
                    // return value packs the layout's required shift-state
                    // into the high byte - the crate casts the raw i16
                    // straight into VIRTUAL_KEY without masking it off, so
                    // any character needing Shift on the layout (every
                    // uppercase letter, `!@#$%^&*()_+` etc.) produces an
                    // out-of-range virtual-key and silently fails to inject.
                    // text() (KEYEVENTF_UNICODE on Windows) bypasses VK/
                    // shift-state resolution entirely on both platforms -
                    // correct and necessary for ordinary typing.
                    //
                    // But text() ALSO bypasses modifier resolution by
                    // design: it inserts the literal character regardless of
                    // whatever is currently held, so a letter typed while
                    // Ctrl/Cmd is down never chords into "Ctrl+C"/"Cmd+C" at
                    // the OS level - the target app just sees an unrelated
                    // character inserted, and the shortcut silently does
                    // nothing. When a modifier is held, route through a
                    // real key() press instead so the OS sees an actual
                    // keydown on that key while the modifier is held (safe
                    // for the common Ctrl/Cmd+lowercase-letter case
                    // specifically - VkKeyScanExW's shift-state corruption
                    // only bites characters that need Shift on the layout,
                    // and a bare lowercase letter with Ctrl/Cmd held isn't
                    // one of those).
                    Key::Unicode(c) if dir == Press && !modifier_held => {
                        run_keyboard_op(enigo, move |e| e.text(&c.to_string()))?;
                    }
                    Key::Unicode(_) if dir == Release => {
                        // Always attempt a real release, regardless of
                        // whether THIS release event reports a modifier
                        // held. Browsers usually deliver a letter's keyup
                        // while its modifier is still held, but if the
                        // user releases Ctrl/Cmd before the letter, the
                        // letter's keyup would otherwise arrive with
                        // modifier_held == false and (under the old logic)
                        // fall through as a no-op - leaving the press-side
                        // key() call above (fired while the modifier WAS
                        // held) with no matching release, stuck down at the
                        // OS level. A synthetic release for a key that was
                        // actually inserted via text() on press (the
                        // ordinary no-modifier typing case) is a documented
                        // no-op on both platforms, so doing this
                        // unconditionally is safe for that case too, not
                        // just the modifier-held one.
                        run_keyboard_op(enigo, move |e| e.key(k, dir))?;
                    }
                    // Named keys (Control/Shift/Alt/Meta/arrows/etc.), plus
                    // a Unicode press with a modifier held (falls through
                    // from the first arm above) - both go through a real
                    // key() press/release, same as this branch always did.
                    _ => run_keyboard_op(enigo, move |e| e.key(k, dir))?,
                }
            }
        }
        "capslock" => {
            // CapsLock is a toggle, not a hold key, and browsers do not agree
            // on keydown/keyup cardinality per press across platforms - the
            // sender (agent app) already reduces this to a single
            // edge-triggered "the resulting state is now X" boolean via
            // getModifierState, so this only needs to reach that boolean
            // exactly once, guarded against duplicate/out-of-order delivery
            // on the unordered/no-retransmit data channel.
            let desired = payload.on.unwrap_or(false);
            let mut state = caps_lock_state().lock().unwrap();
            if *state != desired {
                run_keyboard_op(enigo, |e| {
                    e.key(Key::CapsLock, Press)?;
                    e.key(Key::CapsLock, Release)
                })?;
                *state = desired;
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
        // CapsLock is handled via the dedicated "capslock" message (see
        // handle_event) rather than the generic keydown/keyup path - it's
        // architecturally a toggle, not a hold key, see there for why.
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
