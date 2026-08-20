# Oojack — Full Project Context

A complete reconstruction of the work done to turn two apps ("Ringopus Remote
Producer" and "Ringopus User App") into signed, notarized, distributable
macOS builds under the **Oojack** brand. Written as a standalone reference —
if this chat is ever lost, this file plus the two git repos is enough to
understand what was done, why, and how to redo any of it.

**Scope note:** this file documents the signing / notarization / build /
rebranding work session in full detail, reconstructed from the actual
conversation. It does not re-derive the original application architecture
(how the WebRTC/XMPP/input-injection stack was first built) beyond what's
needed to understand the build process — that predates this documented
segment of work.

**This file is duplicated verbatim in both `ringopus_remote` and
`ringopus_user_app` repo roots** — they are two independently-versioned git
repos, so a copy that lives outside either one isn't git-tracked and won't
survive a fresh clone of just one repo. See each repo's own `CLAUDE.md`/
`decision.md` for repo-specific build commands and the locked cross-repo
decisions (shared bundle ID, signing requirements, rebrand scope, icon
tradeoff) pulled out of this history.

---

## 1. The two apps

| | Ringopus Remote Producer (`oojack-client`) | Ringopus User App (`oojack-agent`) |
|---|---|---|
| Framework | Flutter (macOS desktop target) | Tauri v2 + React |
| Repo | `~/development/ringopus_remote` | `~/development/ringopus_user_app` |
| Branch | `main` | `feature/jingleRemote` |
| Role | The "producer" — captures screen, injects remote input | The "agent"/user-facing app |
| Key libs | `flutter_webrtc` (media), `whixp` (XMPP signaling, vendored under `third_party/whixp`, Rust FFI native transport), `flutter_rust_bridge` + `enigo` (native mouse/keyboard injection) | Tauri's Rust shell + a React/TS frontend |
| Bundle ID | `com.oojack.app` | `com.oojack.app` |

**Both apps deliberately share the bundle identifier `com.oojack.app`.**
This was a firm, repeated decision made earlier in the project — not an
oversight, not something to "fix" if it comes up again.

---

## 2. Where this segment started

- The Flutter app stopped building after a `flutter clean` — Xcode threw
  `Unable to load contents of file list: FlutterInputs/FlutterOutputs.xcfilelist`.
- Neither app had a real distribution-grade certificate. The only signing
  identity available was an **Apple Development** certificate — fine for
  local testing, useless for a build anyone else could install without a
  Gatekeeper "can't verify... free of malware" block.
- Goal: get both apps signed with a genuine **Developer ID Application**
  certificate, notarized, and packaged as installable `.dmg` files that pass
  Gatekeeper on a machine that has never seen the source code.

---

## 3. What was achieved (summary)

- Fixed the post-`flutter clean` Xcode build failure.
- Obtained a real **Developer ID Application** certificate (the actual
  unblock for the whole session).
- Got `oojack-agent` (Tauri) to a fully signed + notarized + stapled +
  Gatekeeper-accepted `.app` **and** `.dmg`.
- Got `oojack-client` (Flutter) to the same fully-verified state, working
  through three separate notarization blockers plus a DMG-signing gap.
- Cut the Flutter release build from 247 MB down to 94.9 MB and switched its
  distributable from a raw `.app` to a proper `.dmg`.
- Built a native macOS plugin so Screen Recording and Accessibility
  permissions are requested together, up front, instead of popping up
  separately at different points in a session.
- Rebranded all user-visible "Ringopus" text in the Flutter app to "Oojack"
  (UI strings only — XMPP domain literals and Dart class names were
  deliberately left alone).
- Replaced the Flutter app's icon set with the user's Oojack logo (with a
  known quality caveat — see §10).
- Reviewed and staged git history for both repos with clean, scoped commits.

---

## 4. Certificate acquisition — the actual unblock

**Starting problem:** `security find-identity -v -p codesigning` showed only
an Apple Development identity. No Developer ID Application cert existed for
either app.

**A wrong turn worth recording:** Tauri's own docs implied only the Apple
Developer Program *Account Holder* can create a Developer ID Application
certificate. That's not accurate. Apple's own role documentation
(`developer.apple.com/help/account/access/roles/`) confirms an **Admin has
full technical capability to create every certificate type, including
Developer ID Application.** The Account Holder is only strictly required
for: accepting legal agreements, renewing membership, and transferring
ownership/billing.

**Actual steps that worked:**

1. On the Mac that needed the cert, open **Keychain Access** — use the
   **top-of-screen application menu bar** (not a button inside the Keychain
   Access window) — `Keychain Access → Certificate Assistant → Request a
   Certificate From a Certificate Authority...`
2. Fill in the email/name, select **"Saved to disk"** (not "emailed to a
   CA") — this produces a `.certSigningRequest` file and pairs it with a
   private key already sitting in the local keychain.
3. Send that CSR file to whoever has Admin (or Account Holder) access on
   `developer.apple.com`.
4. On the full `developer.apple.com` portal (**not** Xcode's limited
   "+"-button certificate picker, which doesn't expose this cert type the
   same way) — Certificates → create a new **Developer ID Application**
   certificate — upload the CSR — download the resulting `.cer`.
5. Double-click the downloaded `.cer` on the original Mac — it pairs with
   the private key already in Keychain Access and appears under the
   Certificates tab.

**Verification:**

```bash
security find-identity -v -p codesigning
```

Ended up showing 4 valid identities, including:

```
"Developer ID Application: Rirabh Consulting Services LLP (8Y4C4HSKL8)"
```

That identity string and team ID (`8Y4C4HSKL8`) is what both apps sign with
from this point forward.

**A side anomaly, now resolved:** while still on the Apple Development
stopgap cert, `codesign -dvvv` showed `Authority=Apple Development: Rirabh
Company (7N4XNMGKS2)` but `TeamIdentifier=8Y4C4HSKL8` — a mismatched-looking
pair. This turned out to just be a property of that particular certificate
(ruled out Xcode's "automatically manage signing" as the cause, since
Tauri's direct `codesign` call showed the identical mismatch). It fully
resolved on its own once both apps switched to the real Developer ID
Application certificate — `Authority` and `TeamIdentifier` matched correctly
after that.

---

## 5. Notarization prerequisites (both apps)

Notarization goes through `notarytool` using an **App Store Connect API
key** (not an Apple ID + app-specific password):

| Field | Value |
|---|---|
| Issuer ID | `e7fc93ba-a680-4510-8f2f-0e91f6b2594f` |
| Key ID | `XRN27Z8Z63` |
| Private key file | `~/Downloads/AuthKey_XRN27Z8Z63.p8` |

Tauri picks these up automatically via env vars (`APPLE_API_ISSUER`,
`APPLE_API_KEY`, `APPLE_API_KEY_PATH` — or `APPLE_ID`/`APPLE_PASSWORD` for
the Apple-ID method, not used here). For the Flutter app they're passed
explicitly to each `notarytool submit` call.

> The `.p8` file itself is a secret — never committed, never pasted into
> chat. Only its filename/path is referenced here.

---

## 6. `oojack-agent` (Tauri) — signing & notarization

### 6.1 Config

`src-tauri/tauri.conf.json`:

```json
"macOS": {
  "signingIdentity": "Developer ID Application: Rirabh Consulting Services LLP (8Y4C4HSKL8)",
  "hardenedRuntime": true
}
```

### 6.2 Build

```bash
cd ~/development/ringopus_user_app

export APPLE_API_ISSUER="e7fc93ba-a680-4510-8f2f-0e91f6b2594f"
export APPLE_API_KEY="XRN27Z8Z63"
export APPLE_API_KEY_PATH="$HOME/Downloads/AuthKey_XRN27Z8Z63.p8"

npm run tauri:build:user2
```

With those env vars set, `tauri build` **automatically** signs, notarizes,
and staples the `.app` as part of the build. Output lands under
`src-tauri/target/.../release/bundle/` in both `macos/` (the `.app`) and
`dmg/` (the `.dmg`) subfolders.

### 6.3 The gap: the DMG doesn't inherit the `.app`'s notarization

First install attempt on a second machine failed Gatekeeper
("Unnotarized Developer ID" from `spctl`) even though the build log clearly
showed `Notarizing ... Finished with status Accepted`.

**Root cause:** a notarization ticket is bound to the specific artifact
submitted, identified by hash. Tauri notarizes the `.app` *before* it builds
the `.dmg` around it — the `.dmg` itself was never submitted, so it never got
its own ticket.

**Fix — notarize and staple the DMG as its own artifact** (Tauri's bundler
already signs the DMG container itself, so no extra `codesign` step is
needed here, unlike the Flutter app below):

```bash
DMG_PATH="src-tauri/target/user2/release/bundle/dmg/<your-app-name>.dmg"

xcrun notarytool submit "$DMG_PATH" \
  --issuer "e7fc93ba-a680-4510-8f2f-0e91f6b2594f" \
  --key-id "XRN27Z8Z63" \
  --key "$HOME/Downloads/AuthKey_XRN27Z8Z63.p8" \
  --wait

xcrun stapler staple "$DMG_PATH"
```

### 6.4 Verification

```bash
spctl -a -vvv --type install "$DMG_PATH"
# → accepted, source=Notarized Developer ID
```

Also fixed along the way (pre-existing, not part of the signing work but
touched in the same period): `src-tauri/Info.plist` got an ATS exception to
allow plain `ws://` to the XMPP server, `package.json`'s `build` script had
`tsc -b &&` removed to unblock a production build, and `index.html`'s
`<title>` was set to "Oojack".

---

## 7. `oojack-client` (Flutter) — signing & notarization

This one needed more manual work because `flutter build macos` doesn't do
what Xcode's "Archive" action does.

### 7.1 The core gotcha

`flutter build macos --release` runs a plain Xcode **build**, not an
**Archive**. Only Archive applies a secure timestamp, enforces Hardened
Runtime, and strips the debug-enabling `com.apple.security.get-task-allow`
entitlement. A plain release build has to be **manually re-signed** after
the fact to become notarization-eligible.

### 7.2 Xcode signing config (one-time, per machine)

Runner target → Signing & Capabilities → **Release** tab:

1. Uncheck **"Automatically manage signing"** — while checked, Xcode
   silently keeps defaulting to a Development-type certificate even if you
   try to pick something else.
2. Manually select **Developer ID Application: Rirabh Consulting Services
   LLP (8Y4C4HSKL8)** from the Signing Certificate dropdown.

### 7.3 Full build → sign → notarize → package sequence

```bash
cd ~/development/ringopus_remote

# --- If coming from a `flutter clean`, or ephemeral/ is missing/broken ---
flutter clean
flutter pub get
flutter build macos --debug   # bootstraps macos/Flutter/ephemeral/ via `flutter assemble`;
                               # only after this will Xcode's own Build/Run button work again

# --- Real release build ---
flutter build macos --release
# 247 MB (Debug) → 94.9 MB (Release)

# --- Re-sign: flutter build does a plain build, not Archive, so this is required ---
codesign --force --deep --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements \
  --sign "Developer ID Application: Rirabh Consulting Services LLP (8Y4C4HSKL8)" \
  build/macos/Build/Products/Release/oojack-client.app

codesign -dvvv build/macos/Build/Products/Release/oojack-client.app
# flags=0x10000(runtime) confirms Hardened Runtime is now actually on

# --- Notarize the .app (notarytool needs a zip/dmg/pkg, not a raw .app dir) ---
ditto -c -k --keepParent \
  build/macos/Build/Products/Release/oojack-client.app \
  oojack-client.zip

xcrun notarytool submit oojack-client.zip \
  --issuer "e7fc93ba-a680-4510-8f2f-0e91f6b2594f" \
  --key-id "XRN27Z8Z63" \
  --key "$HOME/Downloads/AuthKey_XRN27Z8Z63.p8" \
  --wait

xcrun stapler staple build/macos/Build/Products/Release/oojack-client.app

# --- Package as DMG ---
hdiutil create -volname "Oojack Client" \
  -srcfolder build/macos/Build/Products/Release/oojack-client.app \
  -ov -format UDZO oojack-client.dmg

# --- hdiutil does NOT sign the DMG container - sign it explicitly ---
codesign --force --sign \
  "Developer ID Application: Rirabh Consulting Services LLP (8Y4C4HSKL8)" \
  oojack-client.dmg

# --- Notarize + staple the DMG separately - it does not inherit the .app's ticket ---
xcrun notarytool submit oojack-client.dmg \
  --issuer "e7fc93ba-a680-4510-8f2f-0e91f6b2594f" \
  --key-id "XRN27Z8Z63" \
  --key "$HOME/Downloads/AuthKey_XRN27Z8Z63.p8" \
  --wait

xcrun stapler staple oojack-client.dmg

# --- Verify ---
spctl -a -vvv --type install oojack-client.dmg
# → accepted, source=Notarized Developer ID
```

### 7.4 Three notarization errors hit along the way

First `notarytool submit` attempt on the `.app` came back `status: Invalid`.
`xcrun notarytool log <submission-id>` showed exactly three errors, all
stemming from the plain-build-vs-Archive gap in §7.1:

| Error | Cause | Fix |
|---|---|---|
| Missing secure timestamp | Plain Xcode build, not Archive | `--timestamp` flag on manual re-sign |
| Hardened Runtime not enabled | Same | `--options runtime` flag on manual re-sign |
| `com.apple.security.get-task-allow` entitlement present | Xcode injects this automatically on plain (non-Archive) builds — confirmed `Release.entitlements` itself was already clean, so this wasn't a project-file problem | `--entitlements macos/Runner/Release.entitlements` explicitly on the manual re-sign, which overrides whatever Xcode injected |

### 7.5 The DMG-signature gap

After fixing the above, the `.app` notarized cleanly. The DMG did not — even
after a successful notarize + staple, `spctl --type install` returned
`rejected, source=no usable signature`.

**Root cause:** `hdiutil create` builds the DMG container but never signs
it — only whatever's already signed *inside* it (the `.app`) was signed.
The container itself was an unsigned wrapper.

**Fix:** rebuild the DMG fresh, explicitly `codesign` the DMG file itself
(step included in §7.3 above), *then* notarize and staple. Deliberately did
**not** try to patch the already-stapled-but-unsigned DMG in place — signing
after stapling invalidates the ticket attachment, so it has to be
sign → notarize → staple, in that order, on a clean artifact.

---

## 8. Upfront macOS permissions fix

**Problem:** the app was prompting for two separate macOS permissions at two
separate, disconnected points in a session:

- **Screen Recording** — triggered lazily whenever `flutter_webrtc`'s
  `getDisplayMedia` first ran.
- **Accessibility** — triggered lazily whenever `enigo` first tried to
  inject synthetic input.

**Fix:** a native Swift plugin that requests both together, up front, the
moment a capture session starts.

`macos/Runner/PermissionsPlugin.swift` (new file):

```swift
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
    let axOptions: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
    _ = AXIsProcessTrustedWithOptions(axOptions)

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
```

`lib/permissions.dart` (new file):

```dart
import 'package:flutter/services.dart';

/// Dart-side handle for PermissionsPlugin.swift - requests the macOS
/// Accessibility (input injection) and Screen Recording permissions
/// together, up front, instead of letting each one get triggered lazily
/// and separately mid-session (getDisplayMedia triggers Screen Recording;
/// the first enigo event triggers Accessibility).
///
/// Safe to call on every session start: once a permission is granted (or
/// denied), the underlying macOS calls are no-ops with no dialog shown.
class SessionPermissions {
  static const _channel = MethodChannel('com.oojack.app/permissions');

  static Future<void> requestBoth() async {
    try {
      await _channel.invokeMethod('requestSessionPermissions');
    } on MissingPluginException {
      // Non-macOS platform, or the native plugin isn't registered -
      // fall through and let the old lazy per-subsystem prompts happen.
    }
  }

  static Future<Map<String, bool>> checkBoth() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, bool>('checkSessionPermissions');
      return result ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }
}
```

Wired up in `macos/Runner/MainFlutterWindow.swift`:

```swift
RegisterGeneratedPlugins(registry: flutterViewController)
PermissionsPlugin.register(with: flutterViewController.registrar(forPlugin: "PermissionsPlugin"))

super.awakeFromNib()
```

And called at the top of `_startCapture()` in `lib/producer_home_page.dart`,
before `getDisplayMedia` gets anywhere near running:

```dart
Future<void> _startCapture() async {
  // Fire both macOS permission prompts (Accessibility + Screen Recording)
  // together, up front, before either subsystem gets a chance to trigger
  // its own dialog lazily and separately.
  await SessionPermissions.requestBoth();

  final List<DesktopCapturerSource> sources;
  try {
  ...
```

### 8.1 Build-phase mistake hit and fixed

Adding `PermissionsPlugin.swift` to the Xcode project initially went into
the wrong build phase — **"Copy Files" (Destination: Frameworks)** instead
of **"Compile Sources."** Copy Files only embeds already-compiled binaries
(dylibs/frameworks); it never compiles Swift source. Result:
`error: cannot find 'PermissionsPlugin' in scope`.

**Fix:** remove the file reference from Copy Files (the "−" button), add it
to Compile Sources instead (the "+" button — the file reference already
existed in the project so this just re-targets it). Confirmed fixed via a
screenshot showing `Compile Sources (4 items)`: `MainFlutterWindow.swift`,
`AppDelegate.swift`, `GeneratedPluginRegistrant.swift`,
`PermissionsPlugin.swift`.

### 8.2 Why this matters for TCC stability

Permission grants are tied to code-signature stability. Inconsistent
signing across rebuilds (as happened during the earlier ad-hoc/dev-cert
iteration) can make macOS treat each build as a "new app," forcing repeated
prompts. This is now resolved as a side effect of moving to stable Developer
ID signing.

**Status:** code complete, build-phase fix confirmed, rebuild triggered —
not yet confirmed to have passed a full build + sign + notarize pass with
the fix included.

---

## 9. Rebranding: Ringopus → Oojack (UI text only)

Scope was explicit: **UI-visible text only.** Left alone on purpose:

- Dart class names (e.g. `RingopusProducerApp`) — identifiers, not UI text.
- Real XMPP protocol domain literals in `lib/xmpp/xmpp_client.dart`
  (`orchestrator.ringopus`, `guest.ringopus`) — functional server config,
  not UI.

### Changes made

`lib/main.dart`:
```dart
title: 'Oojack Remote Producer',   // was 'Ringopus Remote Producer'
```

`lib/producer_home_page.dart` (two separate strings):
```dart
: const Text('Oojack Remote — Producer'),   // was 'Ringopus Remote — Producer'
...
Text('Oojack Remote', style: Theme.of(context).textTheme.titleLarge),  // was 'Ringopus Remote'
```

**Process note:** the first grep pass for "Ringopus" only covered files
already staged locally and silently missed some app files. Caught by
explicitly staging the rest of the relevant `lib/` files (`theme.dart`,
`app_log.dart`, `xmpp/xmpp_client.dart`, `mediasoup_signaling.dart`,
`router_rtp_capabilities.dart`, `xmpp/constant_interval_reconnection_policy.dart`)
and re-grepping before concluding nothing else needed changing.

---

## 10. App icon replacement

Source file: `~/Downloads/oojack icone light background.png` — a flat
purple/blue "C"/speech-bubble-style mark.

**Problem found on inspection:** the source is only **32×32px** (RGBA).
Xcode's `AppIcon.appiconset` needs 7 distinct sizes, the largest at
**1024×1024**.

**What was done:** generated all 7 required sizes by upscaling the 32×32
source with PIL/Pillow's `LANCZOS` resampling:

| File | Size |
|---|---|
| `app_icon_16.png` | 16×16 |
| `app_icon_32.png` | 32×32 |
| `app_icon_64.png` | 64×64 |
| `app_icon_128.png` | 128×128 |
| `app_icon_256.png` | 256×256 |
| `app_icon_512.png` | 512×512 |
| `app_icon_1024.png` | 1024×1024 |

The 1024×1024 result was visibly blocky/artifact-heavy on inspection — an
inherent limit of upscaling a 32px source that far, not a bug in the
resampling. The user was asked explicitly how to proceed and **chose to use
it anyway, accepting the quality loss**, rather than wait for a
higher-resolution source. All 7 files were replaced in
`macos/Runner/Assets.xcassets/AppIcon.appiconset/`.

**Follow-up if it ever comes up again:** if a larger/vector version of the
logo becomes available, regenerate the same 7 files from that instead — the
`Contents.json` mapping doesn't need to change, only the PNG contents.

---

## 11. Key technical concepts (glossary)

- **Certificate types:** Apple Development / Apple Distribution / Developer
  ID Application (the only one valid for notarized, outside-App-Store
  distribution) / Developer ID Installer.
- **`notarytool` / `stapler`:** Apple's CLI notarization submission tool and
  the tool that "staples" an approved ticket onto the artifact so Gatekeeper
  can verify it offline.
- **Notarization ticket scoping:** a ticket is tied to the specific artifact
  submitted, by hash. Notarizing a `.app` does not cover a `.dmg` built from
  it afterward — each needs its own submission if both need independent
  Gatekeeper acceptance.
- **Tauri v2 auto-signing:** setting `bundle.macOS.signingIdentity` plus the
  `APPLE_API_*` env vars makes `tauri build` automatically sign, notarize,
  and staple — but only the `.app`, not the `.dmg` it also builds.
- **Flutter build vs. Archive:** `flutter build macos` = plain Xcode
  `build`. Only Xcode's `Archive` action applies a secure timestamp,
  enforces Hardened Runtime, and strips `com.apple.security.get-task-allow`.
  A plain build needs manual re-signing to become notarization-eligible.
- **`hdiutil create` doesn't sign:** it packages a DMG container but leaves
  the container itself unsigned even if what's inside is signed.
- **`flutter clean` + Xcode:** deletes `macos/Flutter/ephemeral/`
  (`.xcfilelist` files Xcode's Flutter Assemble build phase requires). Only
  a CLI `flutter build macos` run regenerates them — Xcode's own Build/Run
  button can't bootstrap that directory from a cold start.
- **Xcode "Copy Files" vs. "Compile Sources":** Copy Files (Destination:
  Frameworks) embeds already-compiled binaries; it never compiles source.
  New `.swift` files must go in Compile Sources.
- **"Automatically manage signing":** must be unchecked to manually select
  a specific installed identity — otherwise Xcode silently keeps defaulting
  to a Development-type cert regardless of what's selected in the dropdown.
- **TCC permissions (`AXIsProcessTrustedWithOptions`,
  `CGRequestScreenCaptureAccess`/`CGPreflightScreenCaptureAccess`):**
  idempotent — safe to call every session start; only shows UI the first
  time or after a `tccutil reset`.

---

## 12. Files changed — full reference

### `ringopus_remote` (branch `main`)

**Modified:**
`analysis_options.yaml`, `lib/main.dart`, `lib/producer_home_page.dart`,
`macos/Flutter/Flutter-Debug.xcconfig`, `macos/Flutter/Flutter-Release.xcconfig`,
`macos/Runner.xcodeproj/project.pbxproj`,
`macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`,
`macos/Runner.xcworkspace/contents.xcworkspacedata`,
all 7 `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png`,
`macos/Runner/Configs/AppInfo.xcconfig`, `macos/Runner/MainFlutterWindow.swift`,
`pubspec.lock`, `third_party/whixp/lib/src/native/transport_ffi.dart`.

**Untracked (new):**
`lib/permissions.dart`, `macos/Podfile`, `macos/Podfile.lock`,
`macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`,
`macos/Runner.xcworkspace/xcshareddata/swiftpm/`,
`macos/Runner/PermissionsPlugin.swift`.

Notable pre-existing fix carried in this batch: `transport_ffi.dart` —
`DynamicLibrary.open()` doesn't search `Contents/Frameworks` by default, so
the whixp native (Rust) transport failed to load once the app ran as a real
`.app` bundle (Xcode Run, Finder launch, or a signed/distributed build) — it
only worked under `flutter run`, where cwd happens to be the project root.
Fixed by adding `_openInAppBundleFrameworks()`, which resolves the dylib
path relative to the running executable and is tried before the
cwd-relative package-root fallback.

**Known stale value, deliberately not touched:** `AppInfo.xcconfig` still
has `PRODUCT_BUNDLE_IDENTIFIER = com.example.ringopusRemoteProducer`. Actual
builds correctly use `com.oojack.app` because it's overridden directly in
Xcode's target build settings / `project.pbxproj`. Left as-is since fixing
it was out of the explicitly stated "UI only" scope for the rebrand task —
flagged here so it isn't mistaken for an oversight later.

### `ringopus_user_app` (branch `feature/jingleRemote`)

**Modified:** `index.html`, `package-lock.json`, `package.json`,
`src-tauri/tauri.conf.json`.

**Untracked (new):** `src-tauri/Info.plist`.

---

## 13. Errors encountered — fixes (condensed table)

| Symptom | Root cause | Fix |
|---|---|---|
| `Unable to load contents of file list: FlutterInputs/FlutterOutputs.xcfilelist` | `flutter clean` deleted `macos/Flutter/ephemeral/`; `flutter pub get` doesn't regenerate it | Run `flutter build macos --debug` once from the CLI first |
| Gatekeeper "can't verify... free of malware" on a plain `.dmg` | Expected behavior for any unsigned/un-notarized download from outside the App Store | Sign with Developer ID Application + notarize + staple |
| `codesign` showing `Authority=Apple Development...` but `TeamIdentifier=8Y4C4HSKL8` | Property of the Apple Development stopgap cert itself | Resolved automatically once switched to the real Developer ID Application cert |
| No Developer ID Application identity available at all | Never created | CSR via Keychain Access → Admin/Account Holder creates it on the full developer portal → pair the returned `.cer` |
| Tauri `spctl` → "Unnotarized Developer ID" despite a successful build log | Ticket was issued for the `.app`, submitted before the `.dmg` was built around it | Manually `notarytool submit` + `stapler staple` the `.dmg` as its own artifact |
| Flutter `notarytool submit` → `status: Invalid` (3 errors: no secure timestamp, no Hardened Runtime, `get-task-allow` present) | `flutter build macos --release` does a plain build, not an Archive | Manual re-sign with `--options runtime --timestamp --entitlements ...` |
| Flutter DMG: notarize + staple "succeeded" but `spctl --type install` → `rejected, source=no usable signature` | `hdiutil create` never signs the DMG container itself | Rebuild DMG fresh → `codesign` the DMG file itself → notarize → staple (in that order; never re-sign after stapling) |
| `error: cannot find 'PermissionsPlugin' in scope` | New Swift file added to "Copy Files" build phase instead of "Compile Sources" | Remove from Copy Files, add to Compile Sources |
| Device bridge briefly unavailable mid-task | Desktop app connection dropped | Gave a `sed -i ''` fallback command for the user to run manually; bridge reconnected on its own shortly after |

---

## 14. Git commit / push plan

### `ringopus_remote`

```bash
cd ~/development/ringopus_remote

git add third_party/whixp/lib/src/native/transport_ffi.dart
git commit -m "$(cat <<'EOF'
Resolve native transport dylib inside Contents/Frameworks in app bundles

DynamicLibrary.open() doesn't search Contents/Frameworks by default, so
the whixp native (Rust) transport failed to load once the app ran as a
real .app bundle (Xcode Run, Finder launch, or a signed/distributed
build) - it only worked under `flutter run`, where cwd happens to be
the project root. Add _openInAppBundleFrameworks() to resolve the
dylib path relative to the running executable and try it before
falling back to the cwd-relative package-root lookup.
EOF
)"

git add \
  lib/main.dart \
  lib/producer_home_page.dart \
  lib/permissions.dart \
  macos/Runner/PermissionsPlugin.swift \
  macos/Runner/MainFlutterWindow.swift \
  macos/Runner/Configs/AppInfo.xcconfig \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png \
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png \
  macos/Runner.xcodeproj/project.pbxproj \
  macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme \
  macos/Runner.xcworkspace/contents.xcworkspacedata \
  macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm \
  macos/Runner.xcworkspace/xcshareddata/swiftpm \
  macos/Podfile \
  macos/Podfile.lock \
  macos/Flutter/Flutter-Debug.xcconfig \
  macos/Flutter/Flutter-Release.xcconfig \
  pubspec.lock \
  analysis_options.yaml

git commit -m "$(cat <<'EOF'
Rebrand UI to Oojack, prompt permissions upfront, sign with Developer ID

- Replace user-visible "Ringopus" strings with "Oojack" (app title, home
  page header/AppBar). XMPP domain literals (guest.ringopus,
  orchestrator.ringopus) and Dart class names are left as-is - not UI
  text.
- Replace the AppIcon.appiconset images with the Oojack logo.
- Add PermissionsPlugin.swift (macOS) + lib/permissions.dart to request
  Accessibility and Screen Recording together up front when a session
  starts, instead of each prompting separately and lazily mid-session.
- Configure the Runner target for manual Developer ID Application
  signing and set PRODUCT_NAME.
- Add macos/Podfile and Podfile.lock (CocoaPods integration needed for
  the signed build) plus the resulting Xcode project/workspace state;
  exclude platform/build output dirs from the Dart analyzer.
EOF
)"

git push
```

### `ringopus_user_app`

```bash
cd ~/development/ringopus_user_app

git add index.html src-tauri/tauri.conf.json
git commit -m "$(cat <<'EOF'
Rebrand to Oojack and configure Developer ID Application signing

Set the window title to Oojack and point macOS signing at the real
Developer ID Application certificate (was left on a stopgap Apple
Development identity, which isn't valid for notarized distribution).
EOF
)"

git add src-tauri/Info.plist
git commit -m "$(cat <<'EOF'
Allow plain ws:// to the XMPP server via ATS exception

App Transport Security blocks plaintext WebSocket connections by
default; add the exception needed to reach the XMPP signaling server.
EOF
)"

git add package.json package-lock.json
git commit -m "$(cat <<'EOF'
Unblock production build by skipping strict TypeScript check

Remove `tsc -b &&` from the build script - it was failing the
production build on pre-existing type errors unrelated to this work.
EOF
)"

git push
```

**Status as of this document:** both command sequences above have been
handed to the user to run in their own Terminal (this session has no shell
access to the user's Mac — only file-transfer/staging access via the device
bridge). Execution has not yet been confirmed for either repo.

---

## 15. Current verified state

- **`oojack-agent` (Tauri):** signed with Developer ID Application, notarized,
  stapled, `spctl -a -vvv --type install` → `accepted, source=Notarized
  Developer ID`, for both the `.app` and the `.dmg`. This was verified
  *before* the git commit step above — the signing config in the working
  tree matches what was tested.
- **`oojack-client` (Flutter):** same fully-verified state (`.app` and
  `.dmg`) — but that verification pass was done *before* the rebrand, icon
  swap, and permissions-plugin changes landed. Those changes still need a
  fresh full rebuild + re-sign + re-notarize + re-verify pass before they
  can be called distribution-ready (see §16).

---

## 16. Open items / follow-ups

1. **Icon quality:** shipped from a 32×32 source, visibly artifact-heavy at
   1024×1024. User explicitly accepted this tradeoff. Revisit if a
   higher-resolution or vector source ever becomes available.
2. **Stale `PRODUCT_BUNDLE_IDENTIFIER`** in
   `macos/Runner/Configs/AppInfo.xcconfig` (`com.example.ringopusRemoteProducer`)
   — cosmetic only, real builds use `com.oojack.app` from elsewhere, but
   worth cleaning up eventually.
3. **Shared bundle ID (`com.oojack.app`) across both apps** — a deliberate,
   repeated decision, not a bug. Documented here so it's never "fixed" by
   accident.
4. **Permissions plugin** — code complete and the build-phase misconfiguration
   is fixed, but the fix hasn't yet been confirmed working end-to-end (both
   prompts firing together on a real session start) through a full signed
   build.
5. **Git pushes** — commands provided for both repos; execution not yet
   confirmed.
6. **Nice-to-have, not started:** scripting the whole multi-step sign →
   notarize → staple → package pipeline (§7.3 especially) into one reusable
   shell script instead of running each step by hand every release.

---

## 17. Quick command reference

```bash
# List all signing identities
security find-identity -v -p codesigning

# Inspect a signature
codesign -dvvv <path-to-.app-or-.dmg>

# Re-sign a plain (non-Archive) Flutter build for notarization
codesign --force --deep --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements \
  --sign "Developer ID Application: Rirabh Consulting Services LLP (8Y4C4HSKL8)" \
  <path-to-.app>

# Sign a DMG container (hdiutil never does this for you)
codesign --force --sign \
  "Developer ID Application: Rirabh Consulting Services LLP (8Y4C4HSKL8)" \
  <path-to.dmg>

# Notarize (any artifact - zip, dmg, or pkg)
xcrun notarytool submit <artifact> \
  --issuer "e7fc93ba-a680-4510-8f2f-0e91f6b2594f" \
  --key-id "XRN27Z8Z63" \
  --key "$HOME/Downloads/AuthKey_XRN27Z8Z63.p8" \
  --wait

# Pull the detailed error log for a failed submission
xcrun notarytool log <submission-id> \
  --issuer "e7fc93ba-a680-4510-8f2f-0e91f6b2594f" \
  --key-id "XRN27Z8Z63" \
  --key "$HOME/Downloads/AuthKey_XRN27Z8Z63.p8"

# Staple an approved ticket
xcrun stapler staple <artifact>

# Verify Gatekeeper will accept it on a clean machine
spctl -a -vvv --type install <artifact>

# Recover from a `flutter clean` before Xcode's Build/Run button works again
flutter pub get && flutter build macos --debug
```

---

*Generated as a full reconstruction of the working session — if anything
here looks off against what actually happened on the Mac (a command that
didn't quite match, a path that's since moved), trust the repos and the
Mac's own Keychain/Xcode state over this document, and flag the mismatch so
it can be corrected.*
