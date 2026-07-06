## Stack
Flutter (Dart, Windows + macOS) producer app · Rust via `flutter_rust_bridge` for native input injection (enigo) · a vendored/patched fork of `whixp` for XMPP · a vendored fork of MediaSFU's `mediasoup_client` for WebRTC transports/signaling · `flutter_webrtc` as the underlying WebRTC engine · orchestrator (Node.js, `@xmpp/component` + `mediasoup`) and ejabberd deployed on AWS EC2 (`ap-south-1`, Mumbai) — that server-side source lives in the `ringopus_user_app` repo (`server/`), not here; this repo is the Flutter/Rust producer client only.

## Build & Run

```bash
flutter pub get
flutter run -d windows          # or -d macos
flutter analyze                 # run before any commit — CI does not lint separately
```

Regenerating Rust FFI bindings after changing `rust/src/api/`:
```bash
flutter_rust_bridge_codegen generate     # safe, idempotent — uses flutter_rust_bridge.yaml
```
**Never run `flutter_rust_bridge_codegen integrate` again after initial setup.** `integrate` is a one-time scaffolding command — it overwrites `lib/main.dart` with its own demo template, silently deleting the working app UI. If bindings need regenerating, use `generate` only.

macOS DMG builds run via `.github/workflows/macos-build.yml` on every push to `main`, publishing to the rolling `releases/latest`. Unsigned/ad-hoc — expect a Gatekeeper warning on first open.

## Server Access

The orchestrator/ejabberd EC2 instance (`ap-south-1`, Mumbai) is reached via AWS SSM Session Manager, not a direct SSH port — inbound port 22 is closed entirely on its security group (see DECISIONS.md for why: IP-allowlisted SSH kept breaking every time the dev's ISP rotated their public IP).

```bash
ssh ringopus-mumbai      # alias in ~/.ssh/config; ProxyCommand tunnels through `aws ssm start-session`
```

Requires locally: AWS CLI v2 + the Session Manager Plugin installed, and `aws configure` run once with an IAM user that has `ssm:StartSession` permission on the instance. Common ops once connected:

```bash
sudo systemctl status ejabberd mediasoup-server
sudo journalctl -u mediasoup-server -f            # live logs
sudo systemctl restart mediasoup-server           # after a config/deploy change
```

Server-side source (`ejabberd.yml`, the mediasoup/orchestrator Node.js code) lives in `ringopus_user_app`'s `server/` directory, not here. Deploy a changed server file with `scp <local-file> ringopus-mumbai:<remote-path>`, then restart the affected service.

## Project Structure

- `lib/producer_home_page.dart` — the entire app is one screen, one `StatefulWidget`. See "State machine" below.
- `lib/theme.dart` — centralized design system: `AppColors`, `buildAppTheme()`, `appMonoStyle()`. New widgets pull colors/fonts from here, never hardcode them.
- `lib/app_log.dart` — global `AppLog`, fed by a `Zone` `print()` interceptor wired in `main.dart`. See "On-screen logging" below.
- `lib/xmpp/xmpp_client.dart` — `whixp`-based XMPP client wrapper; `ejabberdWsHost`/`componentJid` constants live here.
- `lib/mediasoup_signaling.dart` — orchestrates the vendored `lib/mediasoup/` client against the JSON-over-XMPP signaling protocol (transport creation, produce/consume, connect acks); also applies producer-side bitrate cap and degradation-preference tuning on produce — see DECISIONS.md.
- `lib/mediasoup/` — vendored fork of MediaSFU's `mediasoup_client` Dart package (MIT, see `LICENSE_UPSTREAM.md`). Patched in place — see DECISIONS.md for the specific bugs fixed and why this fork was chosen over the pub.dev package.
- `lib/router_rtp_capabilities.dart` — a captured real `router.rtpCapabilities` payload, kept for reference/parity with the server's actual codec config.
- `lib/screen_source_picker.dart` — screen/window picker UI over `flutter_webrtc`'s `getDisplayMedia`.
- `rust/src/api/input_inject.rs` — enigo-based mouse/keyboard injection, exposed via `flutter_rust_bridge`. See DECISIONS.md for the macOS main-thread keyboard crash and its fix.
- `native/whixp_transport/` — this repo's own build of `whixp`'s required native (Rust) transport crate for Windows/macOS; CI and local dev both build this and copy the resulting `.dll`/`.dylib` into place. Not the same as whatever `whixp`'s own pub.dev tarball bundles (it doesn't bundle Windows/macOS binaries at all — only Android/iOS).
- `third_party/whixp/` — vendored, patched copy of `whixp` 3.1.0's Dart source (see "Dependency pins" below).
- `macos/Runner/*.entitlements` — App Sandbox is deliberately **off** in both (Debug and Release) — this build is unsigned/unnotarized/local-testing-only, and sandboxing was actively breaking `whixp`'s database path resolution. Do not re-enable without solving that first.
- `.github/workflows/macos-build.yml` — builds `native/whixp_transport` for macOS, runs `flutter build macos --debug`, wires the dylib into the `.app`, **re-signs both the dylib and the app bundle** (required — dropping an unsigned dylib into an already-signed bundle leaves the whole thing unsigned), packages a DMG, publishes to `releases/latest`.

## Architecture

**Single-screen explicit state machine.** `producer_home_page.dart` has one `_Phase` enum: `disconnected -> connecting -> connected -> sessionIncoming -> ready -> sharing -> error`. Every transition goes through one `_setPhase(phase, status)` call — there is no scattered `setState` driving phase-dependent UI elsewhere in the file. The earlier debug-spike pages (`produce_spike_page.dart`, `bridge_client.dart`, deleted in `73de16e`) existed only to manually exercise pieces of this flow before the real XMPP path was proven end to end; **don't recreate that pattern.** If a future feature needs its own throwaway harness to prove something out, fine — but once it's proven, fold the real behavior into `_Phase` and delete the harness, the same way that consolidation did, rather than letting a second permanent screen accumulate.

**On-screen logging exists because a packaged macOS `.app` has no attached terminal.** `main.dart` wraps `runApp` in `runZonedGuarded` with a `print` `ZoneSpecification` that forwards every `print()` call — ours, `whixp`'s internal stanza traces, the vendored mediasoup client's internal logs — into `AppLog`, which `producer_home_page.dart` renders as a live-scrolling panel. This panel is visible from the sign-in screen onward (not just post-connect), since sign-in failures are exactly the case this exists to diagnose.

**Signaling / media / input path:** see `DECISIONS.md` for the full record — this file documents structure and conventions, not the history of how the pipeline got here.

## Conventions & Rules

- **Never run `flutter_rust_bridge_codegen integrate` after initial setup.** It regenerates `main.dart` from a demo template. Use `flutter_rust_bridge_codegen generate` for all subsequent binding changes.
- **`whixp` is pinned to exactly `3.1.0`, not `^3.1.0`.** Every version from 3.2.0 through 3.3.1's published pub.dev tarball is missing `lib/src/native/` (`transport_ffi.dart`), which `transport.dart` imports unconditionally — this breaks the build on every non-web platform. 3.1.0 is the last version where that directory actually shipped, and its `whixp.dart`/`reconnection.dart`/`mixins.dart`/`feature.dart` are byte-identical to 3.3.1's, so pinning to it loses no API surface.
- **`whixp` is *also* overridden via `dependency_overrides` to a vendored copy at `third_party/whixp/`** (Dart source only — the package's own 377MB `native/` build cache is excluded, since this repo builds its own copy via `native/whixp_transport/`). This vendored copy patches real bugs found in 3.1.0 that upstream (`vsevex/whixp`) hasn't fixed: a database-init race in `DatabaseController.initialize()`, a `'/'` (filesystem root) default database path that only fails on macOS, and `enableError`/`enableWarning` defaulting to `false` in the logger (which was silently swallowing the actual exception behind every connection failure). If upstream ever ships equivalent fixes, re-evaluate whether the override is still needed before blindly keeping it.
- **New widgets pull from `theme.dart`, not hardcoded colors/fonts.** `AppColors` for palette, `buildAppTheme()` for the base `ThemeData`, `appMonoStyle()` (JetBrains Mono) specifically for anything that's machine-real data — JIDs, session IDs, the log panel — as distinct from Inter, which is the UI chrome typeface.
- **App Sandbox stays off in `macos/Runner/*.entitlements`.** This build is unsigned/unnotarized/local-testing-only (see the CI workflow's own header comments), so sandboxing has no upside here and previously broke `whixp`'s database path. Don't re-enable it without first confirming the database path issue is fixed some other way.
- **The macOS CI codesign step is not optional.** Any change to how `libwhixp_transport.dylib` gets embedded must keep the re-sign step (dylib + app bundle) — see `.github/workflows/macos-build.yml`.
