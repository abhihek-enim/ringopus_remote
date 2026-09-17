import Cocoa
import FlutterMacOS
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// The two macOS system permissions this app needs — Accessibility (for
/// enigo's synthetic input injection) and Screen Recording (for
/// flutter_webrtc's desktop capture) — exposed to Dart for the first-launch
/// permission setup screen (producer_home_page.dart) and for the safety-net
/// request at session start.
///
/// Why a setup screen and not just a silent request at launch (2026-09-17):
/// on a fresh Mac the old launch-time requestBoth() showed nothing, and the
/// first prompts only appeared once a session started. On recent macOS,
/// Screen Recording mostly cannot be granted from a prompt at all: TCC logs
/// "does not allow prompting", adds the app to Privacy & Security switched
/// off, and the user has to switch it on there and reopen the app. So the
/// app asks through every path that can raise a prompt, shows live status,
/// deep-links to the right Settings pane, and offers to reopen itself.
class PermissionsPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.oojack.app/permissions",
      binaryMessenger: registrar.messenger)
    let instance = PermissionsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestSessionPermissions":
      PermissionsPlugin.requestBoth()
      result(nil)
    case "checkSessionPermissions":
      result(PermissionsPlugin.checkBoth())
    case "requestAccessibility":
      result(PermissionsPlugin.requestAccessibility())
    case "requestScreenCapture":
      PermissionsPlugin.requestScreenCapture(result: result)
    case "openPrivacySettings":
      let pane = (call.arguments as? [String: Any])?["pane"] as? String ?? ""
      result(PermissionsPlugin.openPrivacySettings(pane: pane))
    case "relaunch":
      PermissionsPlugin.relaunch()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Session-start safety net: both requests, no UI of our own.
  static func requestBoth() {
    _ = requestAccessibility()
    if #available(macOS 10.15, *) {
      CGRequestScreenCaptureAccess()
    }
  }

  static func checkBoth() -> [String: Bool] {
    let accessibility = AXIsProcessTrusted()
    let screenCapture: Bool
    if #available(macOS 10.15, *) {
      screenCapture = CGPreflightScreenCaptureAccess()
    } else {
      screenCapture = true
    }
    return ["accessibility": accessibility, "screenCapture": screenCapture]
  }

  /// Shows the "would like to control this computer" alert if not yet
  /// trusted. Returns whether the app is trusted right now.
  static func requestAccessibility() -> Bool {
    // takeUnretainedValue: the option key is a global constant we do not own.
    // (takeRetainedValue, used here before, over-releases it on every call.)
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Asks for Screen Recording through both paths that can surface the
  /// system prompt: the classic CoreGraphics request, and ScreenCaptureKit —
  /// the path that did raise it at session start in the field. Replies with
  /// whether access is granted right now (it usually is not until the user
  /// switches the app on in Settings and reopens it).
  static func requestScreenCapture(result: @escaping FlutterResult) {
    if #available(macOS 10.15, *) {
      if CGPreflightScreenCaptureAccess() {
        result(true)
        return
      }
      _ = CGRequestScreenCaptureAccess()
    }
    if #available(macOS 12.3, *) {
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in
        DispatchQueue.main.async {
          result(CGPreflightScreenCaptureAccess())
        }
      }
    } else if #available(macOS 10.15, *) {
      result(CGPreflightScreenCaptureAccess())
    } else {
      result(true)
    }
  }

  /// Opens System Settings on the exact Privacy & Security page.
  static func openPrivacySettings(pane: String) -> Bool {
    let anchor = pane == "accessibility" ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
      return false
    }
    return NSWorkspace.shared.open(url)
  }

  /// Quits and starts the app again — macOS applies a newly granted Screen
  /// Recording permission only to a fresh process. The new copy is started
  /// by a detached shell a moment after this one has quit, so two copies
  /// (and two XMPP connections for the same identity) never overlap.
  static func relaunch() {
    let bundlePath = Bundle.main.bundlePath
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"$0\"", bundlePath]
    do {
      try task.run()
    } catch {
      return
    }
    NSApp.terminate(nil)
  }
}
