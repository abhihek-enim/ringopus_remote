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

use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::OnceLock;
use std::thread;

use enigo::{
    Button, Coordinate,
    Direction::{Press, Release},
    Enigo, Key, Keyboard, Mouse, Settings,
};
use serde::Deserialize;

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
    let mut enigo = match Enigo::new(&Settings::default()) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("[input_inject] failed to initialize Enigo: {e}");
            return;
        }
    };

    for event in rx {
        if let Err(e) = handle_event(&mut enigo, event) {
            eprintln!("[input_inject] error handling event: {e}");
        }
    }
}

fn handle_event(enigo: &mut Enigo, payload: InputEvent) -> Result<(), String> {
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
    injector_sender().send(event).map_err(|e| e.to_string())
}
