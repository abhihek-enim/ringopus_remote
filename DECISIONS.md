# Decisions & Bugs Log

Running record of architectural decisions, bugs encountered, and dead ends for the Ringopus Remote Flutter producer app. Does not duplicate CLAUDE.md (stack, commands, conventions).

---

## Shared Architecture — inherited from `ringopus_user_app`

This app talks to the **same orchestrator and the same ejabberd server** as the Tauri/React viewer in `ringopus_user_app`, and follows the same signaling protocol and transport topology. The underlying architectural decisions were made there first, over multiple iterations and dead ends fully recorded in that repo's `DECISIONS.md` — this section captures the *current, settled* shape of that architecture as it applies here, not the journey to get there. Read `ringopus_user_app/DECISIONS.md` for the dead ends (manual register/unregister, explicit heartbeats, mod_privilege alone, VP8-only, server-push capabilities, `device.load(callerCaps)` as a congruency check, etc.) — none of those were ever live in this codebase; they're inherited-as-already-rejected, not re-litigated here.

### Decision: single-channel XMPP signaling via component JID

All session negotiation, mediasoup transport parameters, and presence events travel as `<message type="chat">` stanzas with JSON bodies addressed to `orchestrator.192.168.56.101`, over the same authenticated XMPP connection used for everything else — no second WebSocket or connection type. `lib/xmpp/xmpp_client.dart` wraps `whixp` for this; `lib/mediasoup_signaling.dart`'s `sendToComponent` callback is how it hands outgoing messages to the XMPP layer. Same rationale as the original: the client already has one authenticated channel to ejabberd, and a second transport would mean a second auth mechanism for no benefit.

### Decision: XEP-0114 external component, not a regular XMPP user

The orchestrator owns the `orchestrator.192.168.56.101` subdomain via ejabberd's `ejabberd_service` (port 5275, shared secret). Unchanged from the original design — see `ringopus_user_app/CLAUDE.md`'s Infrastructure section and `server/component.js` for the server side, which this repo does not duplicate.

### Decision: ejabberd presence-subscription routing for disconnect detection (the "Generation 3" design)

The component subscribes to each user's presence on first sight (`<presence type="subscribe">`); the client auto-accepts (`<presence type="subscribed">`). This is what lets ejabberd route *all* unavailable-presence cases — clean logout, abrupt kill, network drop, SM-timeout — to the component without a heartbeat of any kind. This app's half of that contract lives in `xmpp_client.dart`'s `presence_subscribe` handler, which auto-replies `subscribed` — see the doc comment there, which explicitly cites "the project's Generation 3 presence design." Two heavier alternatives (manual register/unregister messages, an explicit heartbeat) were tried and rejected in `ringopus_user_app` before landing here; this app never had to make that choice itself, it simply inherits the already-settled answer.

### Decision: 4 mediasoup transports per session, this app is always the callee/sharer

Same topology as the original: `callerSend`/`callerRecv`/`calleeSend`/`calleeRecv`, one send and one recv transport per participant because mediasoup `WebRtcTransport` is directional. This repo has no caller/viewer UI at all — `producer_home_page.dart` only ever plays the callee (sharer) role: it waits for `session-incoming`, accepts, and drives `calleeSend` (screen video out) and `calleeRecv` (remote-control data channel in). The caller/viewer role lives entirely in `ringopus_user_app`.

### Decision: SCTP data channel for remote-control input, not XMPP messages

Mouse/keyboard events ride the mediasoup data channel end to end: viewer input → `calleeRecv` → `inject_input()` → enigo. Same reasoning as the original — routing 60fps mouse events through ejabberd and the component on every event would add avoidable round trips; the data channel is a direct path once established.

### Decision: normalized (0.0–1.0) coordinates for input injection

Confirmed unchanged in `rust/src/api/input_inject.rs`'s `handle_event`: `x`/`y` arrive as fractions and are multiplied by `enigo.main_display()`'s actual resolution at injection time. Same limitation as the original too: this only maps correctly to the primary display, and only enigo. Coordinate normalization/key filtering on the *sending* side (metaKey/altKey exclusion, canvas-to-fraction conversion) lives in the peer app (`ringopus_user_app`'s input listeners), not here — this repo only ever receives already-normalized, already-filtered events.

### Where this implementation actually differs from `ringopus_user_app`

Verified against the current code, not assumed:

- **The `transport.connect` ack race is fixed here, not just flagged.** `ringopus_user_app/DECISIONS.md`'s Open Question 5 documents that the Tauri viewer's `connect` callback fires immediately, without waiting for the server's ack — a known, deferred bug. This app's `MediasoupSignaling` does not have that bug: `_pendingConnect` holds the callback/errback pair with a timeout until `resolveConnect(transportId)` is actually called from the `connect-transport-ack` message handler in `producer_home_page.dart`. If the server never acks, the errback fires on timeout instead of silently proceeding. Worth carrying this pattern back into `ringopus_user_app` at some point rather than leaving that asymmetry in place.
- **No client-side pre-flight codec congruency check on `session-incoming`.** The original design has the callee run a codec-intersection check against `callerCaps` before ever showing accept/reject UI (see "Pre-flight media capability exchange" in `ringopus_user_app/DECISIONS.md`). This app's `session-incoming` handler only checks that `device` is loaded, then always sends `session-accept` — there's no accept/reject prompt to gate in the first place, since this producer auto-accepts any incoming session while idle. The server's authoritative `checkCongruency()` is still the real backstop either way (it always was, even in the original); this app just doesn't duplicate that check client-side before committing to accept.
- **No 2-second "terminated" pause.** The original transitions through a `sessionState = "terminated"` hold before returning to idle, purely for UX feedback. This app's `session-terminated` handler goes straight back to `_Phase.connected` ("Session ended — waiting for a new request…") with no delay.
- **Screen-share track cleanup and mediasoup resource cleanup were correct from the start here**, not retrofitted the way they were in the original (see `ringopus_user_app/DECISIONS.md`'s "Screen capture track never stopped" and "mediasoup resources not released" bugs). `_stopSharingLocally()` stops and disposes every video track and the stream itself; `MediasoupSignaling.cleanup()` cancels all pending timers/connects before clearing state. Both are called from every session-ending path (`session-terminated`, manual disconnect, manual stop-sharing).

---

## WebRTC / MediaSoup

### Decision: vendored fork of MediaSFU's `mediasoup_client`, not the pub.dev `mediasoup_client_flutter` package — 2026-07-02

The Dart client used for mediasoup transports, producers, and consumers (`lib/mediasoup/`) is a vendored copy of MediaSFU's MIT-licensed `mediasoup_client` fork, not the package published on pub.dev under `mediasoup_client_flutter`.

**Why not the pub.dev package:** its own README states data channels are not implemented ("No datachannels yet"), and the package has been untouched since 2023. This app's entire remote-control input path (mouse/keyboard) depends on SCTP data channels — `produceData`/`consumeData` — so the pub.dev package is a non-starter regardless of how well its media path works.

**Consequence:** the vendored fork is not a drop-in dependency — it's checked into this repo and patched directly (see the two bugs below). Any future upgrade means re-diffing against upstream MediaSFU, not a routine `pub upgrade`.

---

### Bug: mediasoup silently negotiates VP8 instead of H.264 unless explicitly forced

**Problem:** the server's router advertises both VP8 and H.264 (VP8 listed first in `RTP_CAPABILITIES.codecs`). Producing without specifying a codec resulted in VP8 being negotiated even though H.264 was the intended codec for this pipeline.

**Root cause:** `Ortc.reduceCodecs()` (`lib/mediasoup/src/ortc.dart`) — when no capability codec is explicitly given, its documented behavior is to "take the first one(s)" from the list. It does not infer intent from anything else; it silently defaults to whatever the router lists first.

**Fix:** `MediasoupSignaling.produce()` (`lib/mediasoup_signaling.dart`) requires a `codec` parameter and passes it straight into `transport.produce(codec: codec)`, forcing the choice explicitly rather than relying on `reduceCodecs`'s default. See the doc comment directly above that method.

**Consequence:** any future call site that adds a new `produce()` call (e.g. a second video source) must also pass an explicit codec — there is no safe "just call produce() and get H.264" default anywhere in this stack.

---

### Bug: `Transport.run()` returning `void` let `produce()`/`consume()` race ahead of `RTCPeerConnection` creation

**Problem:** intermittent failures where `send()`/`receive()` calls on a freshly-created `Transport` would fail because the underlying `RTCPeerConnection` didn't exist yet.

**Root cause:** the upstream MediaSFU handler interface declared `void run(...) async` for the method that sets up the `RTCPeerConnection`. As `void`, its `Future` was unobservable — `Transport`'s constructor (necessarily synchronous) had no way to await it, so `Transport` could be considered "ready" and have `produce()`/`consume()` called on it before `run()` had actually finished.

**Fix:** changed the interface signature to `Future<void> run({required HandlerRunOptions options})` (`lib/mediasoup/src/handlers/handler_interface.dart`), and added a `Transport._handlerReady` field / `handlerReady` getter (`lib/mediasoup/src/transport.dart`) that resolves once `run()` completes. Call sites — `MediasoupSignaling.produce()` and `.consumeData()` — now explicitly `await transport.handlerReady` before calling into the transport.

**Consequence:** any new code path that calls `produce`/`consume`/`consumeData` on a transport must await `handlerReady` first, the same way the existing two call sites do. There is no implicit guarantee elsewhere in the API that a `Transport` object being non-null means its peer connection exists.

---

### Bug: `consumeData`'s callback invoked with an undocumented second `accept` parameter

**Problem:** `NoSuchMethodError` at runtime, at the point `transport.dart` invoked the assigned `dataConsumerCallback` — not at the point the callback was assigned or compiled.

**Root cause:** stock mediasoup-client's `dataConsumerCallback` is a single-argument callback (`(dataConsumer) => ...`). MediaSFU's fork invokes it with a second, undocumented `accept` argument: `dataConsumerCallback?.call(dataConsumer, accept)` (`lib/mediasoup/src/transport.dart`). Dart doesn't check callback arity until the call actually happens, so a callback written against the single-argument stock signature compiles fine and only crashes the first time a real `consumeData()` completes and the transport tries to invoke it with two arguments.

**Fix:** `MediasoupSignaling.consumeData()` assigns `transport.dataConsumerCallback = (dataConsumer, [accept]) { ... }` — the optional second positional parameter absorbs the extra argument. See the comment directly above that assignment in `lib/mediasoup_signaling.dart`.

**Consequence:** this is a MediaSFU-fork-specific quirk, not stock mediasoup-client behavior. If this fork is ever swapped for a different mediasoup client (stock or another fork), re-check whether `consumeData`'s callback arity assumption still holds — don't assume the `[accept]` pattern is needed elsewhere by default.

---

### Bug: `unified_plan.dart`'s `send()` crashed on any encoding that omits `scalabilityMode` — 2026-07-05

**Problem:** the first time `transport.produce()` was called with a real `encodings` list (see the sender-tuning decision below) instead of the empty-list default every prior call site used, the vendored MediaSFU handler crashed with a null-check failure before ever touching the peer connection.

**Root cause:** `UnifiedPlanHandler.send()` (`lib/mediasoup/src/handlers/unified_plan.dart`) parsed `ScalabilityMode.parse(options.encodings.first.scalabilityMode!)`. The `!` assumed every caller-supplied encoding sets `scalabilityMode`, but `RtpEncodingParameters.scalabilityMode` is legitimately nullable — a caller that only sets `maxBitrate` (exactly what the latency fix below needed) leaves it null.

**Fix:** changed `.scalabilityMode!` to `.scalabilityMode ?? ''`, matching the fallback already used one line above for the empty-encodings case, so an encoding with no `scalabilityMode` is treated the same as "no encodings given" for this specific parse instead of crashing.

**Consequence:** every `produce()` call site in this app passed no `encodings` at all until now, so this path was effectively unexercised. Don't assume other optional `RtpEncodingParameters` fields are handled this gracefully elsewhere in `unified_plan.dart` just because this one crash site is now fixed — re-check on first use.

---

### Decision: producer-side bitrate cap + degradation preference, one leg of a three-repo video-latency fix — 2026-07-05

**Problem:** remote-control input (mouse/keyboard) felt instant, but the shared screen video visibly lagged — a sign the two channels were suffering from unrelated causes, not one shared network problem.

**Root cause, three independent layers each defaulting toward "smooth camera call" over "instant remote control":**
1. **This repo (producer):** `transport.produce()` was called with no `encodings` at all, so libwebrtc capped the sender near its generic ~2.5 Mbps camera-call default — too low for a full desktop capture — with no expressed preference for how to degrade under pressure.
2. **`ringopus_user_app` (viewer):** the browser's default jitter buffer trades latency for smoothness against network jitter — the wrong trade for remote control.
3. **`ringopus_user_app/server`, deployed to the shared EC2 instance:** mediasoup's default `initialAvailableOutgoingBitrate` starts low (~600 kbps) and ramps up over several seconds, so every session started blurry.

**Fix, this repo's share of it:** `MediasoupSignaling.produce()` (`lib/mediasoup_signaling.dart`) now passes `encodings: [RtpEncodingParameters(maxBitrate: 8_000_000)]`. A new `_applySenderTuning()` sets `degradationPreference = RTCDegradationPreference.MAINTAIN_FRAMERATE` on the producer's `RTCRtpSender` right after creation, so a stalling frame stream (which reads as "lag" during remote control) is avoided at the cost of resolution instead. `flutter_webrtc` 1.5.x has no `track.contentHint`, so `degradationPreference` is the knob actually available here. The other two layers were fixed in `ringopus_user_app` (`mediasoupClient.ts`'s `consumeStream` sets `jitterBufferTarget`/`playoutDelayHint` to 0; `server/mediasoupManager.js`'s `createWebRtcTransport` call sets `initialAvailableOutgoingBitrate: 10_000_000`) and redeployed to the Mumbai EC2 instance — see that repo's own DECISIONS.md for the full record of those two.

**Consequence:** exercising `produce()` with a non-empty `encodings` list for the first time surfaced the vendored-fork null-crash documented in the bug entry directly above. Any future change to encoding parameters passed into `produce()` should be treated as lightly-tested territory in this fork until proven otherwise.

---

### Bug: interaction lag — root cause was pipeline starvation, not the relay — 2026-07-07

**Problem:** after the 2026-07-05 three-repo latency fix, remote control still felt very laggy: input events landed on the customer instantly, but the video feedback ran hundreds of ms behind.

**Diagnosis (the key logical step):** input and video traverse the *same* Mumbai SFU in opposite directions. Instant input + laggy video therefore rules out the network path as the dominant cost — the lag lives in the video pipeline. The chain: the desktop capturer captures at native Retina resolution (~5–6 MP) unconstrained; 8 Mbps is starvation-level for that size; under starvation libwebrtc's *screencast* adaptation sacrifices **frame rate**, not resolution; low fps (each interaction waits up to ~200 ms just to be captured) plus huge bursty frames inflate the receiver's adaptive jitter buffer (`jitterBufferTarget = 0` is only a hint) by another ~100–250 ms.

**Verified capturer fact:** flutter_webrtc 1.5.2's desktop capturers parse **only `frameRate`** from `getDisplayMedia` constraints — width/height are silently ignored (checked in `FlutterRTCDesktopCapturer.m`). Resolution can only be controlled at the encoder.

**Fix (this repo):** `_produce()` waits ≤2 s for the first frame on the preview renderer to learn the true capture size, then passes `scaleResolutionDownBy` (targeting ~1920-wide encoded output) and an explicit `maxFramerate: 30` — both confirmed marshaled through flutter_webrtc's darwin native layer, so neither silently no-ops. The on-screen log line `[capture] native WxH — encoder downscale …` confirms engagement at runtime.

**Agent-side counterparts (in `ringopus_user_app`):** direct `<video>` rendering replaced a `requestAnimationFrame`+`drawImage` canvas mirror (removing ~16–33 ms + vsync-quantized sampling); the video `Consumer` is now retained and a 1 s `getStats` poller logs `[VideoStats] fps/res/jb/dec/rtt/rate` — the attribution line for any remaining lag.

**Consequence / next decision gate:** if `[VideoStats]` shows fps ≥ 25 and jb < 50 ms during interaction yet lag persists, the residual is relay RTT — the then-justified next step is a customer-region-colocated SFU router. **Not pure P2P**: hold/transfer hard-depends on the SFU's stable-producer/swap-consumer model.

---

### Decision: agent renders a local cursor — pointer feedback decoupled from the video pipeline — 2026-07-07

**Problem:** the agent's only pointer feedback was the remote cursor image baked into the video (the agent UI deliberately set `cursor: none`), so every mouse movement was felt at full glass-to-glass latency. The cursor is what the eye locks onto; pointer lag *is* perceived lag.

**Fix (the standard remote-desktop trick):** the agent now shows its own local cursor (crosshair) at native input latency; because input injection uses absolute normalized coordinates, the remote cursor always converges on the local one. The Windows-native producer additionally excludes the cursor from capture (`scap` `show_cursor: false`), making the local cursor the only one on that path.

**Limitation on this repo's path:** flutter_webrtc 1.5.2 **hardcodes `showsCursor = YES`** in its macOS ScreenCaptureKit capturer (`macos/Classes/FlutterScreenCaptureKitCapturer.m:61`) with no Dart-side control — the macOS customer's stream keeps the remote cursor, so agents see their instant crosshair plus a trailing remote arrow. Removing it means forking/patching the flutter_webrtc native plugin (or a future version exposing it). Deliberately deferred.

---

## Session Lifecycle — Hold & Transfer (customer side)

### Decision: the customer is purely reactive in the agent hold/transfer protocol — 2026-07-06

Agents can put a session on hold/resume it, or transfer it to another agent picked from a live roster — with the customer's screen share never dropping. The server (orchestrator) and agent implementation live in `ringopus_user_app` (`server/sessionHandlers.js`, `server/agentRegistry.js`, `useRemoteSession.ts`); this repo only *reacts*: `session-held` → `pauseSending()` + amber "ON HOLD" badge; `session-resumed` → `resumeSending()`; `session-agent-changed` → transient "Agent connected" banner; a re-sent `data-consumer-params` → `rebindDataConsumer()`. The customer never initiates any of it and is never re-prompted for consent on transfer.

Hold state is an **orthogonal flag (`_agentOnHold`) on top of `_Phase.sharing`, not a new phase** — capture/renderer/producer stay alive throughout; only whether an agent is watching changes. `pauseSending`/`resumeSending` are the first real call sites of the vendored `Producer.pause()/resume()`.

### Decision: transfer swaps only the input leg — `rebindDataConsumer` partial teardown — 2026-07-06

A `WebRtcTransport` connects this customer to the *server*, not to any specific agent — so when a different agent takes over, nothing about the screen-share leg (`_sendTransport`/`_producer`/`sid`) or even `_recvTransport` itself needs to change. `rebindDataConsumer()` closes only the `DataConsumer` object (bound to the old agent's `dataProducerId`), resets `_lastMoveSeq` (a new agent's input sequence isn't comparable to the old one's), and consumes the new params. `cleanup()` remains the full-teardown path for genuine session end; don't conflate the two.

### Bug: `session-incoming` had no phase guard — a second incoming session silently clobbered a live one — 2026-07-06

**Problem:** the `session-incoming` handler ran identically regardless of `_phase` — including mid-`sharing`. A second incoming session overwrote `_signaling.sid` in place, auto-accepted, and switched the UI away, while the original session's transports/producer stayed open but unreachable (never `.close()`d — a real leak).

**Fix:** the handler now ignores (with a logged warning) any `session-incoming` arriving during `sessionIncoming`/`ready`/`sharing`. Load-bearing counterpart on the server: `handleSessionRequest` rejects requests targeting an already-in-session customer with `session-error: target-busy`, so the requesting agent gets a proper error instead of silence.

**Consequence:** transfer-related events reach the customer via *distinct* message types (`session-agent-changed`, re-sent `data-consumer-params`) — never via a second `session-incoming`. Any future protocol change must preserve that distinction or the guard will eat it.

---

## Input Injection

### Bug: stale mousemove replay over the unreliable data channel — 2026-07-02

**Problem:** after any brief network stall, the remote cursor would visibly "replay" through several old positions in quick succession rather than jumping straight to the current one.

**Root cause:** the remote-control SCTP data channel is unordered and unreliable by design (`ordered: false`, confirmed from the real `sctpStreamParameters` shape captured off the wire — `{"streamId": 0, "ordered": false}` — and from the `maxRetransmits` field read alongside it in `MediasoupSignaling.consumeData()`). This is the right transport choice for 60fps mouse events — waiting for retransmission of a lost mousemove is pointless once a newer one exists — but it means a stall can let several mousemove packets queue up and then arrive as a burst, in whatever order the network delivered them.

**Fix:** ported the original app's sequence-based staleness check into `MediasoupSignaling`'s data-channel message handler. The sender stamps each mousemove with an incrementing `seq`; the receiver (`_lastMoveSeq` in `lib/mediasoup_signaling.dart`) discards any mousemove at or behind the last `seq` it already injected, rather than injecting every queued historical position. Reset to `-1` on cleanup so a new session doesn't inherit a stale watermark from the previous one.

**Consequence / rule:** this logic lives in Dart (the message handler, before the payload ever reaches Rust), **not** in `input_inject.rs`. Don't move it into Rust during any future refactor without a specific reason — the discard decision only makes sense at the point where out-of-order delivery is first observed, which is the Dart-side data channel handler, not the injection call itself (which has no visibility into sequencing, only into individual already-deserialized events).

---

### Bug: typing a character crashed the whole app on macOS (TIS main-thread requirement) — 2026-07-03

**Problem:** mouse injection worked correctly end to end. The moment a regular character key (a letter, digit, punctuation — not Enter, arrows, or function keys) was typed, the entire app crashed immediately and unconditionally. This was a guaranteed crash, not intermittent.

**Root cause:** enigo resolves a character key to a keycode via macOS's Text Input Sources API (TIS/TSM) — specifically `TSMGetInputSourceProperty`, reached through `keycode_to_string` / `get_layoutdependent_keycode` in enigo's macOS backend. That API contains a hard `dispatch_assert_queue(main)` check. Calling it off the main thread doesn't raise a catchable error or panic — it traps the entire process at the OS level (confirmed from the crash report: `EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`, on thread `input-injector`, called from `islGetInputSourceListWithAdditions`).

This app's input injector deliberately runs on its own dedicated thread — see `input_inject.rs`'s existing top-of-file comment on `Enigo: Send` but `Enigo: !Sync` — so every single typed character was guaranteed to kill the app. Special keys (Enter, arrows, function keys, modifiers) have fixed keycodes and never touch TIS at all, which is exactly why only regular typed characters triggered this and mouse/special-key input never did.

**Fix:** mouse events stay exactly where they were — on the dedicated injector thread, since `CGEventPost`-based mouse injection is thread-agnostic and this path was already proven working. Only keyboard **character** events (the `Key::Unicode` path through enigo) get hopped onto the main thread, via a minimal hand-rolled `dispatch_sync_f` FFI binding (`main_thread::run_sync` in `input_inject.rs`) rather than pulling in a dispatch crate for one function call.

`dispatch_sync` (not `dispatch_async`) was a deliberate choice: keyboard events, unlike mousemove, are not discarded or reordered on delivery — typing order matters, so the call must block until the keypress has actually been applied before the injector loop moves on to the next queued event.

**Known trade-off — watch for this specifically:** `dispatch_sync` parks the injector thread until Flutter's main/UI thread picks up and runs the closure. If the main thread is ever heavily busy at the exact moment a character is typed, that keypress could stall waiting for main-thread availability. If keyboard input specifically (not mouse, not general video) ever feels laggy under heavy UI load, this is the first place to look — it's a distinct failure mode from network-related lag and needs to be diagnosed separately from it.

**Platform scope:** this fix — and the underlying restriction — is macOS-only, gated behind `#[cfg(target_os = "macos")]` on the entire `main_thread` module. Windows' `SendInput` (enigo's Windows backend) has no equivalent main-thread requirement; keyboard and mouse injection both call directly into enigo from the injector thread on Windows, and this has been tested working with no crash. Linux support does not currently exist in this app; if it's ever added, this needs to be re-investigated from scratch rather than assumed safe — X11/Wayland input injection APIs have their own, different set of threading constraints and nothing here should be assumed to carry over.

---

## Infrastructure — Server Access & Deployment

### Decision: SSH to the shared EC2 instance via AWS SSM Session Manager, not an IP-allowlisted port-22 rule — 2026-07-05

**Problem:** the orchestrator/ejabberd EC2 instance's security group allowed inbound SSH only from a single home `/32` IP. Every time the dev's ISP reassigned that IP — repeatedly, and across unrelated address blocks (not just a slow drift within one CIDR) — the rule went stale and SSH access broke until someone manually updated it in the console.

**Root cause:** IP-based allowlisting ties access to a client-side network attribute that neither party controls or can predict. No CIDR is wide enough to fix this reliably when successive IPs land in unrelated ranges.

**Fix:** moved access control from network location to IAM identity. The instance was given an IAM role (`ringopus-ssm`, trust: EC2, policy: `AmazonSSMManagedInstanceCore`) as its instance profile, letting its already-installed SSM Agent authenticate to AWS and hold an *outbound* control-channel connection open (`wss://ssmmessages.ap-south-1.amazonaws.com`) — the instance calls out, so nothing needs to be reachable inbound at all. A local IAM user (`abhishek-cli`, admin) plus one-time `aws configure` gives the dev machine permission to open SSM sessions. `~/.ssh/config` has a `ringopus-mumbai` host entry whose `ProxyCommand` runs `aws ssm start-session --document-name AWS-StartSSHSession`, so plain `ssh`/`scp` keep working exactly as before — the same `.pem` key still does the actual SSH authentication, only the transport underneath changed. Once verified working end to end, the port-22 inbound rule was deleted from the security group entirely.

**Gotcha hit along the way:** the SSM Agent had been running since before the IAM role was attached, and had cached a "no role" result from instance metadata at boot. It kept failing with `EC2RoleProvider ... Systems Manager's instance management role is not configured for account` — a message that reads like an account-level SSM configuration problem but isn't — until the agent service was restarted (`sudo systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service`) to force a fresh IMDS lookup and pick up the newly attached role.

**Consequence:** there is no inbound SSH path to this instance from the public internet anymore, under any IP — only `aws ssm start-session`, gated by IAM permission (`ssm:StartSession` on this specific instance). Anyone who needs shell access needs an IAM user with that permission, not a security-group edit. If this instance is ever replaced (as happened with the Stockholm→Mumbai region move), the new instance needs the `ringopus-ssm` role reattached explicitly — it does not carry over automatically from an AMI copy or a fresh launch.

---
