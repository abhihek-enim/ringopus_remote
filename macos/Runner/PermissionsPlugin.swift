import Cocoa
import FlutterMacOS
import ApplicationServices
import CoreGraphics

/// Bundles the two macOS system permission prompts this app needs
/// (Accessibility, for enigo's synthetic input injection, and Screen
/// Recording, for flutter_webrtc's desktop capture) behind one Dart call,
/// so both dialogs can be fired together up front when a remote-control
/// session starts, instead of each subsystem lazily triggering its own
/// prompt at a different point in the flow (getDisplayMedia triggers
/// Screen Recording; the first enigo event triggers Accessibility).
///
/// Both underlying calls are safe to invoke on every session start: they
/// only show a system dialog the first time (or after a `tccutil reset`);
/// once granted (or denied), they return immediately with no UI.
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
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func requestBoth() {
    // Accessibility (input injection). The prompt option makes macOS show
    // the "add to Accessibility" system alert if we're not already
    // trusted; if we already are (or were previously denied and the OS
    // has suppressed re-prompting), this just returns without any UI.
    let axOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
    _ = AXIsProcessTrustedWithOptions(axOptions)

    // Screen Recording. Same idempotent behavior as above.
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
}
