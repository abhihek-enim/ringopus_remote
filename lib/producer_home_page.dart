import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whixp/whixp.dart' show TransportState;
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';
import 'identity_store.dart';
import 'mediasoup/mediasoup_client.dart';
import 'mediasoup_signaling.dart';
import 'permissions.dart';
import 'router_rtp_capabilities.dart';
import 'src/rust/api/input_inject.dart';
import 'src/rust/api/persistent_identity.dart';
import 'theme.dart';
import 'xmpp/xmpp_client.dart';

/// The real producer screen: connect via XMPP, wait for an incoming session
/// request the same way the Tauri sharer does, and produce screen video
/// (plus consume the remote-control data channel) to a real viewer.
class ProducerHomePage extends StatefulWidget {
  const ProducerHomePage({super.key});

  @override
  State<ProducerHomePage> createState() => _ProducerHomePageState();
}

enum _Phase {
  disconnected,
  connecting,
  connected,
  sessionIncoming,
  ready,
  sharing,
  error,
  // This device's identity couldn't be found (secure storage wiped, a
  // deep/manual uninstall, a different OS user account — spec §7's
  // scenario list). A distinct top-level phase, not an orthogonal flag
  // within an existing one, because it replaces the entire home screen
  // with an explicit confirmation gate rather than layering onto the
  // normal connect/pairing-code flow. See _enterLostIdentityRecovery().
  identityRecovery,
}

/// One chat line. `fromMe` distinguishes local echo of our own sends from
/// incoming agent messages; `from` is the agent's display name (unused when
/// `fromMe` is true — rendered as "You" instead).
class _ChatEntry {
  _ChatEntry({required this.fromMe, required this.from, required this.body});
  final bool fromMe;
  final String from;
  final String body;
}

// Why a drop is being torn down - purely for status text / notifyPeer choice,
// not a new _Phase value (see DECISIONS.md-style reasoning in the plan this
// implements: reuses _Phase.error, orthogonal boolean flags for "still
// trying to recover" instead of new phases).
enum _TeardownReason { userRequested, remoteTerminated, xmppUnrecoverable, mediasoupUnrecoverable, appDisposed }

// Reconnection tunables for the mediasoup/ICE drop path. The recovery model is
// ICE restart (preserves the producer, so the agent's video resumes on its own)
// against the orchestrator's restart-ice handler. Not measured against real
// network conditions yet - see the plan's Verification section.
const Duration _mediasoupIceGracePeriod = Duration(seconds: 5); // ICE 'disconnected' self-heal window before acting
const Duration _mediasoupRecoveryResendCadence = Duration(seconds: 4); // re-send restart-ice this often while still down
const Duration _mediasoupReconnectWindow = Duration(seconds: 30); // overall give-up deadline once ICE drops
// Aligned to the mediasoup window so a pure-XMPP death gives up on the same ~30s
// budget; the server holds the session ~45s (a longer backstop) either way.
const Duration _xmppUnrecoverableWindow = Duration(seconds: 30);

class _ProducerHomePageState extends State<ProducerHomePage> {
  final _jidController = TextEditingController();
  final _passwordController = TextEditingController();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final MediasoupSignaling _signaling = MediasoupSignaling();

  XmppClient? _xmpp;
  MediaStream? _stream;
  _Phase _phase = _Phase.disconnected;
  String _statusText = 'Not connected';
  String _sourceName = '';
  bool _logExpanded = false;
  // Hidden by default for now - reveal is a follow-up keyboard shortcut
  // (backlog item 4), not yet wired. Kept as a build()-time toggle rather
  // than deleting the panel/_buildLogPanel() call so that follow-up is a
  // small diff (flip this from a shortcut handler) instead of re-adding
  // the panel from scratch.
  // Deliberately mutable (not final) - will be flipped by the
  // keyboard-shortcut handler once that follow-up lands.
  // ignore: prefer_final_fields
  bool _logPanelVisible = false;
  final ScrollController _logScrollController = ScrollController();

  // Guest-code flow (the default entry path): the app connects via a
  // persistent per-device identity (see _connectPersistent()) and asks the
  // orchestrator for a short pairing code, which the agent redeems instead
  // of dialing a JID. The legacy JID/password sign-in survives behind the
  // "Advanced" toggle below. _guestMode still means "auto-connected, no
  // manual sign-in UI" - it no longer implies an anonymous XMPP identity,
  // see decision.md ("persistent per-device identity via a registered
  // user.oojack ejabberd account").
  bool _guestMode = false;
  String _guestCode = ''; // raw digits; rendered grouped XXX-XXX-XXX
  bool _showLegacyLogin = false;

  // Permanent, HKDF-derived 12-digit connect code (see identity_store.dart
  // and rust/src/api/persistent_identity.rs) — non-null once a persistent
  // identity is established. Distinct from _guestCode (the ephemeral
  // 9-digit fallback, still used when this device has no identity at all
  // and connects fully anonymously). Never re-requested/refreshed like
  // _guestCode is — it's constant for the lifetime of the MasterKey.
  String? _permanentConnectCode;

  // The vhost that holds every persistent per-device identity — see
  // decision.md ("Persistent MasterKey-derived device identity"). The
  // server used to hand back a complete jid string on registration; now
  // the client derives everything itself and must know this domain to
  // construct its own full JID.
  static const _deviceIdentityVhost = 'user.oojack';

  // Consent gate for session-incoming: nothing is accepted until the
  // customer clicks Allow. Auto-declines after a minute so an unanswered
  // prompt doesn't strand the agent's request forever.
  bool _consentPending = false;
  String _pendingSessionFrom = '';
  Timer? _consentTimer;
  static const Duration _consentTimeout = Duration(seconds: 60);

  // Orthogonal to _Phase, not a new phase value: _Phase.sharing correctly
  // stays true throughout hold/transfer since capture/renderer/MediaStream
  // never stop - only whether an agent is actively watching/controlling
  // changes.
  bool _agentOnHold = false;
  String? _transientBanner;
  Timer? _transientBannerTimer;

  // Dock-to-corner (replaces the earlier minimize-on-share behavior): the
  // window's size/position from just before docking, restored verbatim on
  // session end. Null whenever the window isn't currently docked.
  Rect? _preDockBounds;

  // Chat (Phase 2). Purely additive to the JSON-over-message channel — no
  // whixp/XMPP protocol changes, same as every other message type here.
  // _chatAvailable reflects the server's chatAvailable flag on transport-
  // params (the customer never learns the actual room JID — see
  // DECISIONS.md's Phase 1 design), so "no chat this session" is a normal,
  // expected, always-possible state, not an error to special-case.
  bool _chatAvailable = false;
  bool _chatOpen = false;
  // Messages received while _chatOpen is false; cleared on open and on any
  // session boundary that also clears _chatMessages.
  int _unreadChatCount = 0;
  // Codec the server tells this customer to produce (AV1|H264|VP9|VP8), from
  // the callee transport-params. H264 until a session sets it (safe default).
  String _produceCodec = 'H264';
  final List<_ChatEntry> _chatMessages = [];
  final _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  // Network-drop detection/recovery state (orthogonal to _Phase, same
  // convention as _agentOnHold above). _tearingDown guards _teardownSession
  // against double invocation - XMPP's unrecoverable timer and mediasoup's
  // recovery-exhaustion path are independent triggers that can both fire
  // close together.
  bool _tearingDown = false;
  bool _xmppReconnecting = false;
  bool _xmppConnected = false; // gates mediasoup recovery — restart-ice can't travel while XMPP is down
  Timer? _xmppUnrecoverableTimer;
  bool _mediasoupRecovering = false;
  final Map<String, Timer> _mediasoupGraceTimers = {}; // per-label ICE-'disconnected' grace
  final Map<String, Timer> _mediasoupRecoveryTimers = {}; // per-label restart-ice resend cadence
  final Map<String, int> _mediasoupCurrentAttemptId = {}; // per-label, for discarding stale restart-ice-params
  final Set<String> _mediasoupNeedingRecovery = {}; // labels ('send'/'recv') currently dropped and being recovered
  Timer? _mediasoupReconnectDeadline; // single overall give-up timer for the whole reconnect episode

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _signaling.onTransportStateChanged = _onMediasoupStateChanged;
    _signaling.onClipboardPasteResult = _onClipboardPasteResult;
    // Auto-connect on launch, via the persistent device identity, so the
    // customer sees their pairing code without any sign-in step. Permissions
    // are requested first, on this same first frame, so Accessibility/Screen
    // Recording are asked for before the user ever sees any session UI - not
    // just at _startCapture() time (see _requestPermissionsOnFirstLaunch()).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _requestPermissionsOnFirstLaunch();
      if (mounted && _phase == _Phase.disconnected) _connectPersistent();
    });
  }

  static const _permissionsRequestedKey = 'permissions_requested_v1';

  /// Fires the combined Accessibility + Screen Recording prompt once, on the
  /// very first launch after install - before any session flow is reachable
  /// - rather than only at _startCapture() time deep into an accepted
  /// session. Persisted via shared_preferences so this never re-prompts on
  /// later launches. The existing SessionPermissions.requestBoth() call in
  /// _startCapture() is left in place unchanged: it's idempotent (a no-op
  /// dialog-wise once granted/denied) and stays as a safety net for a user
  /// who denied here and granted the permission later via System Settings.
  Future<void> _requestPermissionsOnFirstLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_permissionsRequestedKey) == true) return;
      await SessionPermissions.requestBoth();
      await prefs.setBool(_permissionsRequestedKey, true);
    } catch (e) {
      // Best-effort - a prefs/plugin failure here must never block the
      // guest-connect flow that follows.
      _appendLog('[permissions] first-launch request failed: $e');
    }
  }

  @override
  void dispose() {
    // _teardownSession is async and dispose() can't await it, so it's fired
    // unawaited - but _stopSharingLocally() (called first inside it) starts
    // executing synchronously up to its own first `await`, which includes
    // the critical `_renderer.srcObject = null` line, so that still runs
    // before _renderer.dispose() below. See _teardownSession's ordering
    // comment for why _stopSharingLocally() must stay first in its body.
    unawaited(_teardownSession(reason: _TeardownReason.appDisposed, notifyPeer: false));
    _xmpp?.disconnect();
    _renderer.dispose();
    _logScrollController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _transientBannerTimer?.cancel();
    _consentTimer?.cancel();
    super.dispose();
  }

  void _setHold(bool held, String status) {
    if (!mounted) return;
    setState(() {
      _agentOnHold = held;
      _statusText = status;
    });
  }

  void _showTransientBanner(String text) {
    if (!mounted) return;
    _transientBannerTimer?.cancel();
    setState(() => _transientBanner = text);
    _transientBannerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _transientBanner = null);
    });
  }

  // Fired by MediasoupSignaling once an inbound "Paste to Customer" payload
  // has been applied (or failed to apply) to the local OS clipboard. The
  // XMPP ack to the agent is sent by _signaling itself, independent of this
  // — this is purely local UI feedback.
  void _onClipboardPasteResult({required bool success, String? reason}) {
    _showTransientBanner(
      success ? 'Received clipboard from agent' : 'Clipboard from agent failed${reason != null ? ' ($reason)' : ''}',
    );
  }

  // Every print() call in the app - ours, whixp's internal traces,
  // mediasoup's error logs - feeds AppLog via the Zone override in
  // main.dart, so this is just a thin, readable alias for call sites here.
  // ignore: avoid_print
  void _appendLog(String line) => print(line);

  void _setPhase(_Phase phase, String status) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _statusText = status;
    });
  }

  void _connect() {
    final jid = _jidController.text.trim();
    final password = _passwordController.text;
    if (jid.isEmpty || password.isEmpty) return;

    _guestMode = false;
    _startXmpp(XmppClient(jid, password));
  }

  void _connectGuest() {
    _guestMode = true;
    _startXmpp(XmppClient.guest());
  }

  /// The default entry point. Implements the Migration state machine from
  /// ~/.claude/plans/vast-dreaming-haven.md — dispatches on the durably-true
  /// local facts (MasterKey present? legacy sha256(mac) credentials
  /// present? was this device ever provisioned before?) rather than any
  /// remembered in-progress state, so every branch is safe to re-enter from
  /// scratch after a crash.
  Future<void> _connectPersistent() async {
    _guestMode = true;
    String? masterKey;
    try {
      masterKey = await IdentityStore.loadMasterKey();
    } catch (e) {
      _appendLog('[identity] secure storage read failed: $e');
    }
    if (!mounted) return;

    if (masterKey != null) {
      DeviceIdentity identity;
      try {
        identity = await deriveIdentity(masterKeyHex: masterKey);
      } catch (e) {
        // A present-but-corrupted MasterKey must be treated exactly like a
        // lost one — never silently regenerate, never let this crash the
        // app (spec §7).
        _appendLog('[identity] stored MasterKey is corrupted/unreadable: $e');
        await _enterLostIdentityRecovery();
        return;
      }
      if (mounted) setState(() => _permanentConnectCode = identity.connectCode);

      final legacy = await IdentityStore.loadLegacyCredentials();
      if (legacy != null) {
        // Migration case 3: the new identity is already provisioned and
        // confirmed working (we have a valid MasterKey) — finish retiring
        // the old account FIRST, sequentially, then connect for real.
        // Never run this concurrently with the real connection: two
        // XmppClient/Whixp connections open at once from this app is not
        // safe — the native transport's SASL/stream state gets confused
        // across them (confirmed live: garbled SCRAM-SHA-1/PLAIN failures
        // on both connections when this was tried concurrently). Safely
        // repeatable if this was already attempted and interrupted on an
        // earlier launch.
        await _finishLegacyCleanup(legacy);
        if (!mounted) return;
        _connectWithDerivedIdentity(identity);
        return;
      }

      if (!await IdentityStore.wasEverProvisioned()) {
        // MasterKey was persisted but registration never finished (e.g. a
        // crash mid-attempt) — resume by (idempotently) re-registering this
        // same identity, then connect regardless so a slow/offline
        // registration attempt never blocks the app from being usable this
        // session. A successful connect via _connectWithDerivedIdentity is
        // itself the confirmation and calls markProvisioned() — no separate
        // probe connection needed.
        final fullJid = '${identity.jidLocalpart}@$_deviceIdentityVhost';
        final result = await _registerDeviceIdentity(identity, fullJid);
        if (!mounted) return;
        if (result == null) {
          _appendLog('[identity] resend of register-device failed or timed out — will retry next launch');
        }
        _connectWithDerivedIdentity(identity);
        return;
      }

      // True steady state.
      _connectWithDerivedIdentity(identity);
      return;
    }

    final legacy = await IdentityStore.loadLegacyCredentials();
    if (legacy != null) {
      await _migrateFromLegacy(legacy);
      return;
    }

    if (await IdentityStore.wasEverProvisioned()) {
      await _enterLostIdentityRecovery();
      return;
    }

    await _provisionFirstIdentity();
  }

  /// Connects on an already-derived identity. If the account somehow
  /// doesn't actually authenticate (removed server-side, or registration
  /// never truly completed), retries registration once before finally
  /// falling back to a plain anonymous connection — provisioning must never
  /// be a hard blocker to using the app.
  void _connectWithDerivedIdentity(DeviceIdentity identity) {
    final fullJid = '${identity.jidLocalpart}@$_deviceIdentityVhost';
    final xmpp = XmppClient(fullJid, identity.xmppPassword);
    _startXmpp(xmpp);
    // A successful connection here IS the confirmation that this identity
    // actually works — no separate throwaway probe connection needed
    // beforehand (removed; every extra connection a launch makes is one
    // more attempt for a network-level rate limiter to count — see
    // decision_log.md for a real lockout this caused). markProvisioned()
    // is idempotent, so calling it on every successful connect via this
    // helper (steady state included) is harmless.
    final genericConnected = xmpp.onConnected;
    xmpp.onConnected = (boundJid) {
      unawaited(IdentityStore.markProvisioned());
      genericConnected?.call(boundJid);
    };
    final generic = xmpp.onAuthFailed;
    xmpp.onAuthFailed = () async {
      _appendLog('[identity] derived credentials rejected — attempting one re-registration before falling back');
      final result = await _registerDeviceIdentity(identity, fullJid);
      if (result != null && mounted) {
        _connectWithDerivedIdentity(identity);
      } else {
        generic?.call();
      }
    };
  }

  /// Connects anonymously just long enough to submit this device's already
  /// -derived identity for registration, and awaits the server's ack.
  /// Idempotent server-side (see server/deviceIdentity.js) — safe to call
  /// again for an identity that's already registered. Returns the parsed
  /// `device-registered` message, or null on failure/timeout.
  Future<Map<String, dynamic>?> _registerDeviceIdentity(
    DeviceIdentity identity,
    String fullJid,
  ) async {
    final bootstrap = XmppClient.guest();
    final registered = Completer<Map<String, dynamic>?>();
    bootstrap.onComponentMessage = (msg) {
      if (msg['type'] == 'device-registered' || msg['type'] == 'device-registration-failed') {
        if (!registered.isCompleted) registered.complete(msg);
      }
    };
    bootstrap.onConnected = (_) {
      bootstrap.sendToComponent({
        'type': 'register-device',
        'jid': fullJid,
        'password': identity.xmppPassword,
        'connectCode': identity.connectCode,
      });
    };
    bootstrap.onAuthFailed = () {
      if (!registered.isCompleted) registered.complete(null);
    };
    bootstrap.connect();

    final result = await registered.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
    bootstrap.disconnect();
    return (result != null && result['type'] == 'device-registered') ? result : null;
  }

  /// Migration case 2: no MasterKey yet, but a legacy sha256(mac)-derived
  /// identity is present.
  ///
  /// Every step below runs strictly sequentially — one XmppClient connects,
  /// finishes, and fully disconnects before the next one opens. This
  /// deliberately abandons the original "connect on the old identity
  /// immediately, migrate in the background" design: two XmppClient/Whixp
  /// connections open at once from this app is NOT safe — confirmed live,
  /// running the legacy connection concurrently with a background
  /// bootstrap connection produced garbled, spurious SCRAM-SHA-1/PLAIN
  /// authentication failures on both, because the native transport's
  /// SASL/stream state gets confused across simultaneous connections.
  /// Every other flow in this codebase's history (the original
  /// `_provisionDeviceIdentity`, the current `_registerDeviceIdentity`/
  /// `_finishLegacyCleanup` helpers) already only ever holds one connection
  /// open at a time — this just extends that same discipline here.
  ///
  /// Only 2 connections this launch (bootstrap register, then the real
  /// connection) — not 4. Two simplifications on top of the sequential
  /// fix, both because every extra connection a launch makes is one more
  /// attempt for a network-level rate limiter to count (a real, self
  /// -inflicted lockout was hit here live — see decision_log.md):
  /// (1) no separate confirm-login probe — `_connectWithDerivedIdentity`'s
  /// own success already proves the identity works, and it calls
  /// `markProvisioned()` itself; (2) legacy-account cleanup is deferred
  /// entirely to a *future* launch's case-3 path (`_connectPersistent`),
  /// which is already correctly sequential and only runs once this new
  /// identity has been used successfully at least once — arguably stronger
  /// proof of it working than a disposable probe connection ever was.
  Future<void> _migrateFromLegacy(({String jid, String password}) legacy) async {
    String masterKey;
    try {
      masterKey = await generateMasterKey();
      // Persisted BEFORE any network call — this is what makes the whole
      // flow crash-safe. Once this write completes, re-entering this
      // branch after any later crash is impossible; the next launch always
      // resumes from the MasterKey-present cases above, which safely
      // retry the same (idempotent) registration rather than generating a
      // second, different MasterKey.
      await IdentityStore.persistMasterKey(masterKey);
    } catch (e) {
      _appendLog('[identity] migration: failed to generate/persist a new MasterKey — using the legacy identity for now: $e');
      _startXmpp(XmppClient(legacy.jid, legacy.password));
      return;
    }

    DeviceIdentity identity;
    try {
      identity = await deriveIdentity(masterKeyHex: masterKey);
    } catch (e) {
      _appendLog('[identity] migration: failed to derive the new identity — using the legacy identity for now: $e');
      _startXmpp(XmppClient(legacy.jid, legacy.password));
      return;
    }
    if (mounted) setState(() => _permanentConnectCode = identity.connectCode);

    final newJid = '${identity.jidLocalpart}@$_deviceIdentityVhost';
    final registered = await _registerDeviceIdentity(identity, newJid);
    if (!mounted) return;
    if (registered == null) {
      _appendLog('[identity] migration: register-device failed or timed out — using the legacy identity for now, will retry next launch');
      _startXmpp(XmppClient(legacy.jid, legacy.password));
      return;
    }

    _appendLog('[identity] migration: new identity $newJid registered — connecting on it now; legacy cleanup deferred to a later launch');
    _connectWithDerivedIdentity(identity);
  }

  /// Migration case 3 (and the tail of case 2): retires the legacy account
  /// by briefly reconnecting AS it — proving ownership the same way ejabberd
  /// authenticates every other stanza in this codebase, so the server-side
  /// handler needs no separate jid argument or ownership check (it always
  /// unregisters whoever the connection is authenticated as). Idempotent:
  /// a legacy account that's already gone (an earlier attempt succeeded but
  /// this device crashed before clearing local storage) is treated as
  /// success too, so this never gets stuck retrying forever.
  Future<void> _finishLegacyCleanup(({String jid, String password}) legacy) async {
    final probe = XmppClient(legacy.jid, legacy.password);
    final done = Completer<bool>();
    probe.onComponentMessage = (msg) {
      if (msg['type'] == 'legacy-device-unregistered' ||
          msg['type'] == 'legacy-device-unregister-failed') {
        if (!done.isCompleted) done.complete(msg['type'] == 'legacy-device-unregistered');
      }
    };
    probe.onConnected = (_) {
      probe.sendToComponent({'type': 'unregister-legacy-device'});
    };
    probe.onAuthFailed = () {
      // Can't even log in as the legacy identity anymore — most likely it's
      // already gone. Treat the same as a confirmed unregister so local
      // cleanup isn't stuck retrying forever.
      if (!done.isCompleted) done.complete(true);
    };
    probe.connect();
    final cleaned = await done.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => false,
    );
    probe.disconnect();
    if (cleaned) {
      await IdentityStore.clearLegacyCredentials();
      _appendLog('[identity] legacy identity retired and cleared');
    } else {
      _appendLog('[identity] legacy cleanup did not complete — will retry next launch');
    }
  }

  /// Genuine first launch: no MasterKey, no legacy credentials. Falls back
  /// to a plain anonymous connection (unchanged pre-redesign behavior) if
  /// provisioning fails for any reason — provisioning must never be a hard
  /// blocker to using the app.
  Future<void> _provisionFirstIdentity() async {
    String masterKey;
    try {
      masterKey = await generateMasterKey();
      await IdentityStore.persistMasterKey(masterKey);
    } catch (e) {
      _appendLog('[identity] could not generate/persist a MasterKey, connecting anonymously: $e');
      _connectGuest();
      return;
    }

    DeviceIdentity identity;
    try {
      identity = await deriveIdentity(masterKeyHex: masterKey);
    } catch (e) {
      _appendLog('[identity] could not derive an identity from a fresh MasterKey, connecting anonymously: $e');
      _connectGuest();
      return;
    }
    if (mounted) setState(() => _permanentConnectCode = identity.connectCode);

    final fullJid = '${identity.jidLocalpart}@$_deviceIdentityVhost';
    final result = await _registerDeviceIdentity(identity, fullJid);
    if (!mounted) return;

    if (result == null) {
      _appendLog('[identity] device registration failed or timed out — connecting anonymously');
      _connectGuest();
      return;
    }

    // The real connection below is itself the confirmation that this
    // identity works, and calls markProvisioned() on success — no separate
    // probe connection needed beforehand.
    _connectWithDerivedIdentity(identity);
  }

  /// Migration case 4 / spec §7: the identity was lost (secure storage
  /// wiped, deep-uninstalled, a different OS user account). Never silently
  /// generate a replacement — surface the explicit recovery screen instead
  /// and wait for the user to confirm before doing anything.
  Future<void> _enterLostIdentityRecovery() async {
    if (mounted) _setPhase(_Phase.identityRecovery, 'This device\'s identity could not be found');
  }

  /// The recovery screen's (or the connected app's "Reset identity" menu
  /// item's) confirmed action: generate a brand-new MasterKey and connect
  /// on it. This necessarily changes the JID, password, and connect code
  /// together — there is no way to change just the code, since it's
  /// deterministically derived from the same MasterKey (see Part D of the
  /// plan this implements). If an old MasterKey/identity still exists
  /// (a user-initiated reset, not a genuine recovery), it's simply
  /// abandoned/orphaned — no cross-repo unregister call is made for it,
  /// since unlike the sha256(mac) migration there is no reachable "legacy"
  /// credential slot for a MasterKey-based identity to hand off from.
  Future<void> _resetIdentity() async {
    await IdentityStore.clearMasterKey();
    if (mounted) setState(() => _permanentConnectCode = null);
    await _provisionFirstIdentity();
  }

  void _startXmpp(XmppClient xmpp) {
    _xmpp = xmpp;
    xmpp.onConnected = (boundJid) {
      _appendLog('[xmpp] connected as $boundJid');
      _xmppConnected = true; // stream is negotiated/bound — restart-ice can now travel
      _setPhase(_Phase.connected, 'Connected — requesting router capabilities…');
      xmpp.sendToComponent({'type': 'get-router-caps'});
    };
    xmpp.onAuthFailed = () {
      _appendLog('[xmpp] AUTH FAILED');
      _setPhase(
        _Phase.error,
        _guestMode
            ? 'Could not connect — check the server'
            : 'Login failed — check JID/password',
      );
    };
    xmpp.onComponentMessage = _onComponentMessage;
    xmpp.onStateChanged = _onXmppStateChanged;
    xmpp.connect();
    _setPhase(_Phase.connecting, 'Connecting…');
  }

  Future<void> _disconnect() async {
    await _teardownSession(reason: _TeardownReason.userRequested, notifyPeer: true);
    _xmppConnected = false;
    _xmpp?.disconnect();
    _xmpp = null;
    if (!mounted) return;
    setState(() {
      _phase = _Phase.disconnected;
      _statusText = 'Not connected';
    });
  }

  Future<void> _onComponentMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'router-rtp-capabilities':
        await _signaling.loadDevice(msg['rtpCapabilities'] as Map<String, dynamic>);
        _appendLog('[mediasoup] device loaded from real router-rtp-capabilities');
        if (_permanentConnectCode != null) {
          // A persistent identity already has its permanent code — never
          // request an ephemeral one for it (this was the original root
          // cause of the code changing every reconnect, see decision.md).
          _setPhase(_Phase.connected, 'Share your code with the agent to begin');
        } else if (_guestMode) {
          _setPhase(_Phase.connected, 'Requesting your share code…');
          _xmpp?.sendToComponent({'type': 'guest-code-request'});
        } else {
          _setPhase(_Phase.connected, 'Ready — waiting for an incoming session request…');
        }

      case 'guest-code':
        _appendLog('[guest] share code received (expires in ${msg['ttlMs']}ms)');
        if (mounted) setState(() => _guestCode = msg['code'] as String);
        if (_phase == _Phase.connected) {
          _setPhase(_Phase.connected, 'Share your code with the agent to begin');
        }

      case 'guest-code-expired':
        _appendLog('[guest] share code expired — requesting a fresh one');
        if (mounted) setState(() => _guestCode = '');
        _xmpp?.sendToComponent({'type': 'guest-code-request'});

      case 'session-incoming':
        if (_phase == _Phase.sessionIncoming ||
            _phase == _Phase.ready ||
            _phase == _Phase.sharing) {
          _appendLog(
            'WARNING: session-incoming ignored — already in a session '
            '(phase=$_phase, current sid=${_signaling.sid}, incoming sid=${msg['sid']})',
          );
          return;
        }
        final sid = msg['sid'] as String;
        _appendLog('--- session-incoming from ${msg['from']} (sid=$sid) ---');
        if (_signaling.device == null) {
          _appendLog('ERROR: session-incoming before device loaded');
          return;
        }
        _signaling.sid = sid;
        _signaling.sendToComponent = _xmpp!.sendToComponent;
        // Consent gate: the session proceeds only after the customer clicks
        // Allow (which sends the session-accept the old code sent here
        // unconditionally). Decline sends session-reject, which the server
        // already handles.
        _consentTimer?.cancel();
        _consentTimer = Timer(_consentTimeout, () {
          if (_consentPending) _declinePendingSession(auto: true);
        });
        if (mounted) {
          setState(() {
            _consentPending = true;
            _pendingSessionFrom = (msg['from'] as String?) ?? '';
          });
        }
        _setPhase(_Phase.sessionIncoming, 'Incoming session request');

      case 'transport-params':
        final send = msg['send'] as Map<String, dynamic>;
        final recv = msg['recv'] as Map<String, dynamic>;
        // The server walks the codec preference chain (AV1>H264>VP9>VP8)
        // against both sides' caps and names the one this customer must
        // produce; default H264 if an older server omits it.
        _produceCodec = (msg['produceCodec'] as String?) ?? 'H264';
        _appendLog('[mediasoup] server-selected produce codec: $_produceCodec');
        // Server-issued TURN creds (absent = direct-only, unchanged behavior).
        final iceServers = msg['iceServers'] as List<dynamic>?;
        await _signaling.createSendTransport(send, iceServers: iceServers);
        await _signaling.createRecvTransport(recv, iceServers: iceServers);
        _appendLog('[mediasoup] send + recv transports created from real transport-params');
        if (mounted) {
          setState(() {
            _chatAvailable = (msg['chatAvailable'] as bool?) ?? false;
            _chatMessages.clear();
            _chatOpen = false;
            _unreadChatCount = 0;
          });
        }
        _setPhase(_Phase.ready, 'Starting screen share…');
        // Consent was already given at Allow — no separate manual step to
        // start sharing. _startCapture() picks the first screen source
        // itself (no interactive picker), so this is safe to fire immediately.
        unawaited(_startCapture());

      case 'chat-message':
        final from = (msg['from'] as String?) ?? 'Agent';
        final body = (msg['body'] as String?) ?? '';
        if (mounted) {
          setState(() {
            _chatMessages.add(_ChatEntry(fromMe: false, from: from, body: body));
            if (!_chatOpen) _unreadChatCount++;
          });
        }
        _scrollChatToBottom();

      case 'chat-history':
        final entries = ((msg['messages'] as List<dynamic>?) ?? const [])
            .map((m) {
              final map = m as Map<String, dynamic>;
              final isMe = map['from'] == 'customer';
              return _ChatEntry(
                fromMe: isMe,
                from: isMe ? 'You' : ((map['from'] as String?) ?? 'Agent'),
                body: (map['body'] as String?) ?? '',
              );
            })
            .toList();
        if (mounted) {
          setState(() {
            _chatMessages
              ..clear()
              ..addAll(entries);
          });
        }
        _scrollChatToBottom();

      case 'chat-message-error':
        _appendLog('[chat] send failed: ${msg['reason']}');

      case 'connect-transport-ack':
        _signaling.resolveConnect(msg['transportId'] as String);

      case 'producer-created':
        final producerId = msg['producerId'] as String;
        _signaling.resolveProduce(producerId);
        _appendLog('[transport] produce acked, producerId=$producerId');
        // Matches the real native producer's captured flow: tell the server
        // we're ready once the producer exists, so it creates the caller's
        // consumer.
        _xmpp!.sendToComponent({'type': 'producer-ready', 'sid': _signaling.sid, 'producerId': producerId});

      case 'data-consumer-params':
        _appendLog('[mediasoup] data-consumer-params received — wiring input injection');
        await _signaling.rebindDataConsumer(msg);

      case 'session-held':
        _appendLog('--- session held (sid=${msg['sid']}) ---');
        _signaling.pauseSending();
        // Defence-in-depth: disarm input injection while held so a backgrounded
        // agent tab can never inject into this customer, independent of the
        // server pausing our input dataConsumer at the SFU. Re-armed on resume.
        try {
          await stopInputInjection();
        } catch (e) {
          _appendLog('stopInputInjection (hold) failed: $e');
        }
        _setHold(true, 'On hold — agent stepped away');

      case 'session-resumed':
        _appendLog('--- session resumed (sid=${msg['sid']}) ---');
        _signaling.resumeSending();
        try {
          await startInputInjection();
        } catch (e) {
          _appendLog('startInputInjection (resume) failed: $e');
        }
        _setHold(false, 'Sharing "$_sourceName"');

      // Cross-clipboard, both directions. All five message types are
      // signaling-channel (XMPP), not the clipboard DataChannel itself —
      // that channel's actual payload is handled entirely inside
      // MediasoupSignaling (consumeClipboardData/_handleClipboardMessage).
      case 'clipboard-copy-request':
        await _handleClipboardCopyRequest(msg);

      case 'clipboard-data-consumer-params':
        _appendLog('[clipboard] data-consumer-params received — wiring paste-to-customer');
        await _signaling.consumeClipboardData(msg);

      case 'clipboard-data-producer-created':
        _signaling.resolveClipboardProduceData(msg['dataProducerId'] as String);

      case 'clipboard-applied':
        _appendLog('[clipboard] agent applied the clipboard content we sent');
        _showTransientBanner('Clipboard shared with agent');

      case 'clipboard-apply-failed':
        _appendLog('[clipboard] agent failed to apply our clipboard content: ${msg['reason']}');
        _showTransientBanner('Agent could not use the clipboard');

      // Generic rejection of our own clipboard-produce-data (e.g. a
      // session-state race) — distinct from clipboard-copy-unavailable
      // (which _handleClipboardCopyRequest sends itself, before ever
      // calling produceClipboardData). Without this case the pending
      // produceClipboardData() call would just run out its own
      // produceTimeout instead of failing promptly.
      case 'clipboard-error':
        _appendLog('[clipboard] rejected: ${msg['reason']}');

      // Agent-side tab-backgrounding (multi-session) — deliberately NOT
      // session-held/session-resumed. Unlike genuine hold above, this must
      // NEVER touch _signaling.pauseSending()/resumeSending(): the agent
      // merely looking at a different tab must not stop this customer's
      // screen from flowing (future recording needs it live, and a customer
      // must never be put on hold just because the agent looked away). Only
      // input authority changes — disarm/re-arm injection as defense-in-depth
      // (the server's own dataProducer pause at the SFU is the authoritative
      // barrier). No banner: this is fully invisible to the customer, unlike
      // genuine hold's "On hold" banner above.
      case 'agent-attention-paused':
        _appendLog('--- agent attention paused (sid=${msg['sid']}) ---');
        try {
          await stopInputInjection();
        } catch (e) {
          _appendLog('stopInputInjection (attention-paused) failed: $e');
        }

      case 'agent-attention-resumed':
        _appendLog('--- agent attention resumed (sid=${msg['sid']}) ---');
        try {
          await startInputInjection();
        } catch (e) {
          _appendLog('startInputInjection (attention-resumed) failed: $e');
        }

      case 'session-agent-changed':
        _appendLog('--- new agent attached (sid=${msg['sid']}) ---');
        _showTransientBanner('Agent connected');

      case 'session-error':
        _appendLog('SESSION ERROR: ${msg['reason']}');
        _setPhase(_Phase.error, 'Session error: ${msg['reason']}');

      case 'session-terminated':
        _appendLog('--- session terminated ---');
        await _teardownSession(reason: _TeardownReason.remoteTerminated, notifyPeer: false);

      // Orchestrator's reply to a client-initiated 'restart-ice' request:
      // fresh iceParameters for the customer's send/recv transport. 'attemptId'
      // is echoed back unchanged so a stale/late reply from a superseded resend
      // can be discarded.
      case 'restart-ice-params':
        _onRestartIceParams(msg);

      default:
        _appendLog('[xmpp] unhandled message type: ${msg['type']}');
    }
  }

  void _acceptPendingSession() {
    if (!_consentPending || _xmpp == null) return;
    _consentTimer?.cancel();
    setState(() => _consentPending = false);
    _xmpp!.sendToComponent({
      'type': 'session-accept',
      'sid': _signaling.sid,
      // Advertise the device's REAL negotiated capabilities (native ∩ router),
      // not the stale hardcoded snapshot — otherwise the server's codec walk
      // only ever sees VP8/H264 and can never select AV1/VP9 even when both
      // sides support them. Falls back to the snapshot only if the device
      // somehow isn't loaded (it always is by accept time).
      'rtpCapabilities':
          _signaling.device?.rtpCapabilities.toMap() ?? routerRtpCapabilitiesJson,
    });
    _setPhase(_Phase.sessionIncoming, 'Session accepted — setting up transports…');
  }

  void _declinePendingSession({bool auto = false}) {
    if (!_consentPending) return;
    _consentTimer?.cancel();
    _xmpp?.sendToComponent({
      'type': 'session-reject',
      'sid': _signaling.sid,
      'reason': auto ? 'timeout' : 'declined',
    });
    _signaling.sid = '';
    if (mounted) {
      setState(() {
        _consentPending = false;
        _pendingSessionFrom = '';
      });
    }
    _setPhase(_Phase.connected, auto ? 'Request timed out' : 'Request declined');
    // The code was consumed when the agent's request created the session -
    // the customer needs a fresh one for the next attempt.
    _refreshGuestCode();
  }

  /// Requests a replacement pairing code. The server invalidates any prior
  /// pending code for this JID, so this is always safe to call when idle.
  /// A no-op for a persistent identity — its connect code is permanent, it
  /// never needs refreshing (see decision.md).
  void _refreshGuestCode() {
    if (_permanentConnectCode != null) return;
    if (!_guestMode || _xmpp == null || !_xmppConnected) return;
    if (mounted) setState(() => _guestCode = '');
    _xmpp!.sendToComponent({'type': 'guest-code-request'});
  }

  void _sendChatMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty || _xmpp == null || _signaling.sid.isEmpty) return;
    _xmpp!.sendToComponent({'type': 'chat-message', 'sid': _signaling.sid, 'body': text});
    if (mounted) {
      setState(() => _chatMessages.add(_ChatEntry(fromMe: true, from: 'You', body: text)));
    }
    _chatController.clear();
    _scrollChatToBottom();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.jumpTo(_chatScrollController.position.maxScrollExtent);
      }
    });
  }

  // Docked window size while sharing — small enough to stay out of the way,
  // tall enough for the chat panel's message list + compose box to still be
  // usable.
  static const Size _dockedSize = Size(340, 520);

  /// Shrinks the window to a small bottom-right, always-on-top dock instead
  /// of the old minimize-on-share behavior — the customer keeps the chat
  /// panel visible/reachable while the agent works, rather than the app
  /// disappearing from view entirely. `setSize` before `setAlignment`
  /// (alignment is computed from the window's *current* size).
  Future<void> _dockToCorner() async {
    _preDockBounds = await windowManager.getBounds();
    await windowManager.setResizable(false);
    await windowManager.setSize(_dockedSize);
    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.setAlwaysOnTop(true);
    if (mounted) setState(() {});
  }

  /// Reverses _dockToCorner. Safe to call even if never docked (no-op via
  /// the null check) - every _teardownSession path funnels through here.
  Future<void> _undockAndRestore() async {
    final bounds = _preDockBounds;
    if (bounds == null) return;
    _preDockBounds = null;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    await windowManager.setBounds(bounds);
    if (mounted) setState(() {});
  }

  Future<void> _startCapture() async {
    // Fire both macOS permission prompts (Accessibility + Screen Recording)
    // together, up front, before either subsystem gets a chance to trigger
    // its own dialog lazily and separately (getDisplayMedia below would
    // otherwise be the one surfacing Screen Recording, and
    // startInputInjection - only reached after capture succeeds - would
    // surface Accessibility much later in the flow). No-op if already
    // granted/denied, so safe to call on every session start.
    await SessionPermissions.requestBoth();

    final List<DesktopCapturerSource> sources;
    try {
      sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
    } catch (e) {
      _appendLog('Capture failed: could not enumerate screens: $e');
      return;
    }
    if (sources.isEmpty) {
      _appendLog('Capture failed: no screen source available');
      return;
    }
    final source = sources.first;

    try {
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': source.id},
          // frameRate must live under 'mandatory' as a plain number — the
          // Windows/darwin capturers parse only video.mandatory.frameRate.
          'mandatory': {'frameRate': 30.0},
          // Vendored-plugin patch (Windows screen capture): excludes the
          // sharer's cursor from the captured frame. No-op on window capture.
          'cursor': 'never',
        },
      });
      _stream = stream;
      _renderer.srcObject = stream;
      setState(() => _sourceName = source.name);
      _setPhase(_Phase.sharing, 'Sharing “${source.name}”');
      // Dock to a small always-on-top corner the instant sharing actually
      // starts, instead of minimizing - the customer keeps the chat panel
      // reachable while the agent works. Also doubles as a second guard
      // against this app's own window ever showing up inside the capture
      // (the in-app preview loopback is handled separately, see
      // _buildPreviewPlaceholder()'s _Phase.sharing branch above).
      unawaited(_dockToCorner());
      _tearingDown = false; // fresh session - re-arm the teardown choke point
      // Input injection is independent of video capture/produce - a Rust
      // bridge failure here (e.g. a debug-build content-hash mismatch) must
      // not abort screen sharing, which doesn't depend on it at all.
      try {
        await startInputInjection();
      } catch (e) {
        _appendLog('startInputInjection failed (input injection unavailable this session): $e');
      }
      await _produce();
    } catch (e) {
      _appendLog('Capture failed: $e');
    }
  }

  Future<void> _produce() async {
    final device = _signaling.device;
    final stream = _stream;
    if (device == null || stream == null) return;

    // Produce the codec the server selected from the preference chain
    // (AV1>H264>VP9>VP8, matched against our own send caps + the agent's recv
    // caps). Fall back to H264 if — impossibly — the named codec isn't in our
    // device caps, so we never fail to produce.
    final wantMime = 'video/${_produceCodec.toLowerCase()}';
    var codec = device.rtpCapabilities.codecs
        .where((c) => c.mimeType.toLowerCase() == wantMime)
        .firstOrNull;
    if (codec == null) {
      _appendLog('WARNING: server-selected $_produceCodec not in device caps — falling back to H264');
      codec = device.rtpCapabilities.codecs
          .where((c) => c.mimeType.toLowerCase() == 'video/h264')
          .firstOrNull;
    }
    if (codec == null) {
      _appendLog('ERROR: no usable video codec in device.rtpCapabilities — cannot produce');
      return;
    }

    // The desktop capturer always captures at native resolution (its macOS
    // implementation parses only frameRate from the constraints — width/
    // height are silently ignored), so a Retina Mac produces 5-6 MP frames
    // that starve the 8 Mbps budget and collapse the frame rate. Wait
    // briefly for the first frame to learn the real capture size, then have
    // the encoder downscale to ~1080p-class output. Falls back to no
    // scaling if no frame arrives in time (same behavior as before).
    for (var i = 0; i < 20 && _renderer.videoWidth == 0; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    var scaleDown = 1.0;
    final capturedWidth = _renderer.videoWidth;
    if (capturedWidth > 1920) {
      scaleDown = capturedWidth / 1920.0;
      _appendLog(
        '[capture] native ${capturedWidth.toInt()}x${_renderer.videoHeight.toInt()} '
        '— encoder downscale ${scaleDown.toStringAsFixed(2)}x to ~1920 wide',
      );
    } else if (capturedWidth > 0) {
      _appendLog('[capture] native ${capturedWidth.toInt()}x${_renderer.videoHeight.toInt()} — no downscale needed');
    } else {
      _appendLog('[capture] WARNING: no frame within 2s — producing without downscale');
    }

    await _signaling.produce(
      track: stream.getVideoTracks().first,
      stream: stream,
      codec: codec,
      scaleResolutionDownBy: scaleDown,
      onProducer: (producer) {
        _appendLog('--- Producer created: ${producer.id} ---');
        _logCodecParity(producer.rtpParameters);
      },
    );
  }

  void _logCodecParity(RtpParameters rtpParameters) {
    // Codec-agnostic now that produce can be AV1/H264/VP9/VP8 — log whatever
    // primary video codec was actually negotiated (ignore rtx). For H264 the
    // profile-level-id still matters, so surface it when present.
    final videoCodecs = rtpParameters.codecs.where((c) {
      final m = c.mimeType.toLowerCase();
      return m.startsWith('video/') && m != 'video/rtx';
    });
    if (videoCodecs.isEmpty) {
      _appendLog('CODEC: no video codec in negotiated rtpParameters');
      return;
    }
    final codec = videoCodecs.first;
    final profile = codec.parameters['profile-level-id'];
    _appendLog(
      'CODEC: negotiated ${codec.mimeType}'
      '${profile != null ? ' profile-level-id=$profile (baseline $baselineProfileLevelId)' : ''}'
      ' params=${codec.parameters}',
    );
  }

  Future<void> _stopSharingLocally() async {
    _renderer.srcObject = null;
    for (final track in _stream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _stream?.dispose();
    _stream = null;
  }

  Future<void> _stopSharing() async {
    await _teardownSession(reason: _TeardownReason.userRequested, notifyPeer: true);
  }

  String _statusTextFor(_TeardownReason reason) => switch (reason) {
    _TeardownReason.userRequested => 'Stopped — waiting for a new session request…',
    _TeardownReason.remoteTerminated => 'Session ended — waiting for a new request…',
    _TeardownReason.xmppUnrecoverable => 'Connection lost — session ended',
    _TeardownReason.mediasoupUnrecoverable => 'Connection lost — session ended',
    _TeardownReason.appDisposed => 'App closing',
  };

  void _cancelAllDropTimers() {
    _xmppUnrecoverableTimer?.cancel();
    _xmppUnrecoverableTimer = null;
    _mediasoupReconnectDeadline?.cancel();
    _mediasoupReconnectDeadline = null;
    for (final t in _mediasoupGraceTimers.values) {
      t.cancel();
    }
    _mediasoupGraceTimers.clear();
    for (final t in _mediasoupRecoveryTimers.values) {
      t.cancel();
    }
    _mediasoupRecoveryTimers.clear();
    // A session torn down mid-recovery must not leave a fresh future session
    // inheriting stale recovery bookkeeping (needing-recovery labels or
    // attemptId watermarks).
    _mediasoupNeedingRecovery.clear();
    _mediasoupCurrentAttemptId.clear();
  }

  /// The single choke point for ending a session, whatever the cause -
  /// consolidates what used to be 4 separately-maintained cleanup sites
  /// (user stop, remote termination, disconnect, and dispose(), which
  /// previously didn't call this at all). Guarded against double invocation
  /// since XMPP's unrecoverable timer and mediasoup's recovery-exhaustion
  /// path are independent triggers that can fire close together.
  ///
  /// Ordering note: _stopSharingLocally() is called first (before the
  /// stopInputInjection() await) specifically so that when this is invoked
  /// via unawaited(...) from dispose(), its synchronous first line
  /// (_renderer.srcObject = null) still runs before dispose()
  /// proceeds to _renderer.dispose() a few lines later - see dispose()'s own
  /// comment. Dart async functions run synchronously up to their first
  /// await, so anything placed after an earlier await in this function
  /// would NOT get that guarantee.
  Future<void> _teardownSession({required _TeardownReason reason, bool notifyPeer = true}) async {
    if (_tearingDown) return;
    _tearingDown = true;
    unawaited(_undockAndRestore()); // no-op if never docked this session

    final sid = _signaling.sid;
    if (notifyPeer && sid.isNotEmpty && _xmpp != null) {
      try {
        _xmpp!.sendToComponent({'type': 'session-terminate', 'sid': sid, 'reason': reason.name});
      } catch (_) {}
    }
    // Every cleanup call below is independently try/caught: a failure in ANY
    // one of them (WebRTC stream/track disposal, the Rust input bridge,
    // native mediasoup transport close) must not skip the rest of teardown -
    // above all, must not skip the phase reset a few lines down. Before this
    // guard existed, an exception here (e.g. closing a transport mid-
    // negotiation) silently left the app stuck in _Phase.sharing/.ready
    // forever, and the session-incoming guard above then silently dropped
    // every future request with no error shown anywhere - the app looked
    // "stuck" or "unresponsive" with no diagnostic beyond the (hidden-by-
    // default) log panel. See decision_log.md.
    try {
      await _stopSharingLocally();
    } catch (e) {
      _appendLog('_stopSharingLocally failed: $e');
    }
    try {
      await stopInputInjection();
    } catch (e) {
      _appendLog('stopInputInjection failed: $e');
    }
    try {
      await _signaling.cleanup();
    } catch (e) {
      _appendLog('_signaling.cleanup failed: $e');
    }
    _agentOnHold = false;
    _xmppReconnecting = false;
    _mediasoupRecovering = false;
    _consentTimer?.cancel();
    _consentPending = false;
    _pendingSessionFrom = '';
    _chatAvailable = false;
    _chatOpen = false;
    _chatMessages.clear();
    _unreadChatCount = 0;
    _cancelAllDropTimers();
    if (mounted) {
      final backToIdle =
          reason == _TeardownReason.userRequested || reason == _TeardownReason.remoteTerminated;
      _setPhase(backToIdle ? _Phase.connected : _Phase.error, _statusTextFor(reason));
      // Back on the idle screen: the old code is gone (consumed when this
      // session was created), so fetch a fresh one for the next agent.
      if (backToIdle) _refreshGuestCode();
    }
  }

  // --- XMPP drop detection -----------------------------------------------

  void _onXmppStateChanged(TransportState state) {
    if (_tearingDown) return;
    switch (state) {
      case TransportState.connected:
        _xmppConnected = true;
        _xmppUnrecoverableTimer?.cancel();
        _xmppUnrecoverableTimer = null;
        if (_xmppReconnecting && mounted) {
          setState(() => _xmppReconnecting = false);
          // Request an authoritative chat resync. XEP-0198 SM resume would
          // have redelivered any queued chat-message stanzas transparently
          // anyway, but this covers the case where the drop actually forced
          // a fresh bind instead of a resume.
          if (_chatAvailable && _signaling.sid.isNotEmpty) {
            _xmpp?.sendToComponent({'type': 'chat-history-request', 'sid': _signaling.sid});
          }
        }
        // XMPP is the transport for restart-ice signaling. Any mediasoup
        // recovery that was waiting for XMPP to come back can now fire
        // immediately, rather than idling until its next cadence tick.
        for (final label in _mediasoupNeedingRecovery.toList()) {
          _pumpMediasoupRecovery(label);
        }
      case TransportState.connectionFailure:
      case TransportState.reconnecting:
      case TransportState.disconnected:
        // Not TransportState.killed/terminated - those are definitive stops
        // (an explicit disconnect() call), not a mid-session drop to
        // recover from. whixp's own reconnection policy + XEP-0198 resume
        // already self-heal brief blips with zero app involvement; only
        // escalate if this drags on past the grace window below.
        _xmppConnected = false;
        if (_xmppUnrecoverableTimer == null) {
          if (mounted) setState(() => _xmppReconnecting = true);
          _xmppUnrecoverableTimer = Timer(_xmppUnrecoverableWindow, _declareXmppUnrecoverable);
        }
      default:
      // pickingAddress/connecting/tlsSuccess/killed/terminated - no action.
    }
  }

  void _declareXmppUnrecoverable() {
    if (_tearingDown) return;
    _appendLog('[xmpp] no reconnect within the grace window — tearing down session');
    unawaited(_teardownSession(reason: _TeardownReason.xmppUnrecoverable, notifyPeer: false));
  }

  // --- Mediasoup/ICE drop detection & bounded recovery --------------------

  void _onMediasoupStateChanged(String label, String state) {
    if (_tearingDown) return;
    switch (state) {
      case 'connected':
        // ICE (re)connected for this transport. If it was in recovery, it's
        // now healed - the restart-ice actually worked. Clear its recovery
        // bookkeeping; if nothing else is still dropped, the whole episode is
        // over.
        _mediasoupGraceTimers.remove(label)?.cancel();
        _mediasoupRecoveryTimers.remove(label)?.cancel();
        _mediasoupCurrentAttemptId.remove(label);
        if (_mediasoupNeedingRecovery.remove(label)) {
          _appendLog('[recovery] $label reconnected');
        }
        if (_mediasoupNeedingRecovery.isEmpty) {
          _mediasoupReconnectDeadline?.cancel();
          _mediasoupReconnectDeadline = null;
          if (_mediasoupRecovering && mounted) {
            setState(() => _mediasoupRecovering = false);
          }
        }
      case 'disconnected':
        // ICE's own transient state - can self-heal (ICE trickle/keepalive)
        // without app involvement, mirroring XMPP's SM-resume tolerance. Give
        // it a short grace window before treating it as a confirmed drop.
        _mediasoupGraceTimers[label]?.cancel();
        _mediasoupGraceTimers[label] = Timer(_mediasoupIceGracePeriod, () {
          if (_tearingDown) return;
          _beginMediasoupRecovery(label);
        });
      case 'failed':
      case 'closed':
        _mediasoupGraceTimers.remove(label)?.cancel();
        _beginMediasoupRecovery(label);
      default:
      // 'connecting' - no action.
    }
  }

  /// Enter (or re-enter) ICE-restart recovery for one transport. Recovery is a
  /// single episode bounded by one overall deadline; per-label it re-sends
  /// restart-ice on a cadence until that transport reports 'connected' again or
  /// the deadline fires.
  void _beginMediasoupRecovery(String label) {
    if (_tearingDown) return;
    if (!_mediasoupNeedingRecovery.add(label)) return; // already recovering this label
    if (mounted) setState(() => _mediasoupRecovering = true);
    // One deadline governs the whole episode (both transports usually drop
    // together on a real network blip); don't restart it per-label.
    _mediasoupReconnectDeadline ??= Timer(_mediasoupReconnectWindow, _onMediasoupReconnectDeadline);
    _pumpMediasoupRecovery(label);
  }

  /// Sends one restart-ice for [label] (only if XMPP is actually up — the
  /// request can't travel otherwise, and burning the budget on a dead channel
  /// is exactly the bug this gating fixes), then re-arms itself on a cadence.
  /// When XMPP comes back, _onXmppStateChanged re-pumps immediately instead of
  /// waiting for the next tick.
  void _pumpMediasoupRecovery(String label) {
    if (_tearingDown) return;
    if (!_mediasoupNeedingRecovery.contains(label)) return; // already reconnected
    if (_xmppConnected) {
      final attemptId = (_mediasoupCurrentAttemptId[label] ?? 0) + 1;
      _mediasoupCurrentAttemptId[label] = attemptId;
      _appendLog('[recovery] restart-ice $label (attemptId=$attemptId)');
      _xmpp?.sendToComponent({
        'type': 'restart-ice',
        'sid': _signaling.sid,
        'direction': label,
        'attemptId': attemptId,
      });
    } else {
      _appendLog('[recovery] $label waiting for XMPP before restart-ice');
    }
    _mediasoupRecoveryTimers[label]?.cancel();
    _mediasoupRecoveryTimers[label] = Timer(
      _mediasoupRecoveryResendCadence,
      () => _pumpMediasoupRecovery(label),
    );
  }

  void _onMediasoupReconnectDeadline() {
    if (_tearingDown) return;
    _appendLog('[recovery] reconnect window elapsed — tearing down session');
    unawaited(_teardownSession(reason: _TeardownReason.mediasoupUnrecoverable, notifyPeer: true));
  }

  /// Applies the orchestrator's fresh iceParameters to the existing transport.
  /// Success isn't declared here - we wait for that transport's
  /// 'connectionstatechange' → 'connected' (in _onMediasoupStateChanged) to
  /// confirm the restart actually took; if it didn't, the cadence keeps
  /// retrying and the deadline governs.
  void _onRestartIceParams(Map<String, dynamic> msg) {
    if (_tearingDown) return;
    final label = msg['direction'] as String;
    final attemptId = msg['attemptId'] as int;
    if (_mediasoupCurrentAttemptId[label] != attemptId) {
      _appendLog('[recovery] discarding stale restart-ice-params for $label (attemptId=$attemptId)');
      return;
    }
    if (!_mediasoupNeedingRecovery.contains(label)) return; // already reconnected
    _signaling.restartIce(label, msg['iceParameters'] as Map<String, dynamic>);
    _appendLog('[recovery] applied restart-ice for $label — awaiting reconnect');
  }

  /// Customer-side half of "Copy from Customer": read our own OS clipboard
  /// and, on success, produce+send it to whichever agent asked. Gated the
  /// same way hold already gates input injection — a held or stale session
  /// must not let a backgrounded/superseded agent pull clipboard content.
  Future<void> _handleClipboardCopyRequest(Map<String, dynamic> msg) async {
    final sid = msg['sid'] as String?;
    if (_phase != _Phase.sharing || _agentOnHold || sid != _signaling.sid) {
      _xmpp?.sendToComponent({
        'type': 'clipboard-copy-unavailable',
        'sid': sid,
        'reason': 'session-not-active',
      });
      return;
    }

    ClipboardData? data;
    try {
      // Flutter's own cross-platform clipboard API (already used elsewhere
      // in this app for the connect-code copy button) — no native Rust
      // needed for plain text get/set. A null return means "nothing text
      // there," not an error — distinct from a thrown PlatformException.
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (e) {
      _appendLog('[clipboard] read failed: $e');
      _xmpp?.sendToComponent({
        'type': 'clipboard-copy-unavailable',
        'sid': sid,
        'reason': 'read-failed',
      });
      return;
    }

    final text = data?.text;
    if (text == null || text.isEmpty) {
      _xmpp?.sendToComponent({
        'type': 'clipboard-copy-unavailable',
        'sid': sid,
        'reason': 'empty',
      });
      return;
    }

    if (utf8.encode(text).length > kClipboardMaxPayloadBytes) {
      _xmpp?.sendToComponent({
        'type': 'clipboard-copy-unavailable',
        'sid': sid,
        'reason': 'oversized-payload',
      });
      return;
    }

    try {
      await _signaling.produceClipboardData();
    } catch (e) {
      _appendLog('[clipboard] produce failed: $e');
      _xmpp?.sendToComponent({
        'type': 'clipboard-copy-unavailable',
        'sid': sid,
        'reason': 'clipboard-unavailable',
      });
      return;
    }

    final transferId = _signaling.sendClipboardData(text);
    _appendLog('[clipboard] sent our clipboard content (transferId=$transferId)');
  }

  bool get _isConnected =>
      _phase != _Phase.disconnected &&
      _phase != _Phase.connecting &&
      _phase != _Phase.error &&
      _phase != _Phase.identityRecovery;

  Color get _statusDotColor {
    if (_phase == _Phase.sharing && (_agentOnHold || _xmppReconnecting || _mediasoupRecovering)) {
      return Colors.amber;
    }
    switch (_phase) {
      case _Phase.disconnected:
        return AppColors.textSecondary;
      case _Phase.connecting:
      case _Phase.sessionIncoming:
        return Colors.amber;
      case _Phase.connected:
      case _Phase.ready:
      case _Phase.sharing:
        return AppColors.live;
      case _Phase.error:
      case _Phase.identityRecovery:
        return AppColors.danger;
    }
  }

  /// Compact status word next to the dot in the AppBar — the detailed
  /// message (_statusText) already appears in the preview area, this is
  /// just the at-a-glance summary.
  String get _connectionStatusLabel {
    if (_phase == _Phase.sharing && (_agentOnHold || _xmppReconnecting || _mediasoupRecovering)) {
      return 'Reconnecting…';
    }
    switch (_phase) {
      case _Phase.disconnected:
        return 'Not connected';
      case _Phase.connecting:
        return 'Connecting…';
      case _Phase.sessionIncoming:
        return 'Incoming request';
      case _Phase.connected:
      case _Phase.ready:
      case _Phase.sharing:
        return 'Connected';
      case _Phase.error:
        return 'Error';
      case _Phase.identityRecovery:
        return 'Action needed';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Docked, always-on-top, small — the whole window IS the chat panel
    // while sharing. See _dockToCorner()/_undockAndRestore().
    if (_phase == _Phase.sharing) {
      return Scaffold(body: SafeArea(child: _buildDockedView()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/images/oojack_logo.png', width: 30, height: 30),
            ),
            const SizedBox(width: 12),
            // Always the static branded title, never the raw connected JID -
            // for a guest session that JID's domain is guest.ringopus, which
            // has no reason to ever reach the customer's screen.
            const Text('Oojack Remote', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          ],
        ),
        actions: [
          if (_isConnected)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: OutlinedButton(
                onPressed: _disconnect,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger),
                ),
                child: const Text('Disconnect'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: _statusDotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(_connectionStatusLabel, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
      // Log panel lives outside the connected/sign-in split so it's visible
      // from the moment the app launches - the whole point of on-screen
      // logging is diagnosing failures that happen before/during sign-in on
      // a packaged .app with no attached terminal (see app_log.dart).
      // Hidden by default (_logPanelVisible) until a keyboard shortcut to
      // reveal it lands - see the _logPanelVisible field doc above.
      body: Column(
        children: [
          Expanded(child: _isConnected ? _buildConnectedBody() : _buildStartBody()),
          if (_logPanelVisible) _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _buildStartBody() {
    if (_phase == _Phase.identityRecovery) return _buildIdentityRecoveryBody();
    return _showLegacyLogin ? _buildSignInBody() : _buildGuestStartBody();
  }

  /// Spec §7's explicit recovery state: this device's identity couldn't be
  /// found. Never silently regenerate — require an explicit confirmation
  /// first, since continuing creates a brand-new identity with no link to
  /// whatever connect code anyone already had for this device.
  Widget _buildIdentityRecoveryBody() {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Identity not found', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Text(
                    "This device's identity could not be found. This can happen after "
                    'certain uninstall methods, a cleared credential store, or switching '
                    'OS user accounts.\n\n'
                    'Continuing will create a new identity — a new connect code will be '
                    'issued, and anyone who had the previous code will need the new one.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () async {
                      _setPhase(_Phase.connecting, 'Creating a new identity…');
                      await _resetIdentity();
                    },
                    child: const Text('Create New Identity'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Default entry screen: no credentials, just the guest session spinning
  /// up (it auto-starts on launch). Errors land here with a retry button;
  /// the legacy JID/password card stays reachable via the Advanced toggle.
  Widget _buildGuestStartBody() {
    final connecting = _phase == _Phase.connecting;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Oojack Remote', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Get a share code and read it to your support agent.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  if (connecting)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    )
                  else
                    FilledButton(
                      onPressed: _connectPersistent,
                      child: Text(_phase == _Phase.error ? 'Retry' : 'Get a share code'),
                    ),
                  if (_phase == _Phase.error) ...[
                    const SizedBox(height: 12),
                    Text(_statusText, style: const TextStyle(color: AppColors.danger)),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: connecting
                        ? null
                        : () => setState(() => _showLegacyLogin = true),
                    child: const Text('Advanced: sign in with JID'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignInBody() {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Sign in', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Connect to the orchestrator to start producing.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _jidController,
                    enabled: _phase != _Phase.connecting,
                    decoration: const InputDecoration(labelText: 'JID'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    enabled: _phase != _Phase.connecting,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => _connect(),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _phase == _Phase.connecting ? null : _connect,
                    child: Text(_phase == _Phase.connecting ? 'Connecting…' : 'Connect'),
                  ),
                  if (_phase == _Phase.error) ...[
                    const SizedBox(height: 12),
                    Text(_statusText, style: const TextStyle(color: AppColors.danger)),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _phase == _Phase.connecting
                        ? null
                        : () => setState(() => _showLegacyLogin = false),
                    child: const Text('Back to guest session'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedBody() {
    return Column(
      children: [
        _buildControlRow(),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildPreviewArea()),
              if (_chatOpen && _chatAvailable) _buildChatPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChatPanel() {
    return Container(
      width: 300,
      margin: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(kCornerRadius + 4),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: [
                Text('Chat', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _chatOpen = false),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.hairline),
          Expanded(child: _buildChatBody()),
        ],
      ),
    );
  }

  /// Message list + compose row, shared between the normal fixed-width chat
  /// panel above and the docked compact view below — the only thing that
  /// differs between them is the surrounding chrome (header/close button vs.
  /// a slim status bar), not this part.
  Widget _buildChatBody() {
    return Column(
      children: [
        Expanded(
          child: _chatMessages.isEmpty
              ? Center(
                  child: Text(
                    'No messages yet',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _chatMessages.length,
                  itemBuilder: (context, i) => _buildChatBubble(_chatMessages[i]),
                ),
        ),
        const Divider(height: 1, color: AppColors.hairline),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Message…',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Send',
                icon: const Icon(Icons.send, size: 18),
                onPressed: _sendChatMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The whole window's content while docked (_Phase.sharing) — a slim
  /// status bar plus the chat body filling the rest of the small window. No
  /// AppBar, no preview area, no log panel: the point of docking is to get
  /// everything but chat out of the way. Falls back to a plain status card
  /// when this session has no chat room (chatAvailable false) — there's
  /// nothing to dock a chat view around in that case.
  Widget _buildDockedView() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.hairline)),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: _statusDotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sharing your screen',
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _chatAvailable
              ? _buildChatBody()
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Sharing your screen with the agent.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildChatBubble(_ChatEntry entry) {
    return Align(
      alignment: entry.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: entry.fromMe ? AppColors.accent.withValues(alpha: 0.22) : AppColors.background,
          borderRadius: BorderRadius.circular(kCornerRadius),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!entry.fromMe)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  entry.from,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ),
            Text(entry.body, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildControlRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _statusText,
              style: TextStyle(color: AppColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if ((_phase == _Phase.ready || _phase == _Phase.sharing) && _chatAvailable)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _chatOpen = !_chatOpen;
                  if (_chatOpen) _unreadChatCount = 0;
                }),
                icon: _unreadChatCount > 0
                    ? Badge(
                        label: Text('$_unreadChatCount'),
                        child: const Icon(Icons.chat_bubble_outline, size: 18),
                      )
                    : const Icon(Icons.chat_bubble_outline, size: 18),
                label: Text(_chatOpen ? 'Hide Chat' : 'Chat'),
              ),
            ),
          if (_phase == _Phase.sharing)
            OutlinedButton.icon(
              onPressed: _stopSharing,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
              ),
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('Stop Sharing'),
            ),
        ],
      ),
    );
  }

  String get _previewPlaceholderText => switch (_phase) {
    _Phase.disconnected => 'Sign in to get started',
    _Phase.connecting => 'Connecting…',
    _Phase.connected => 'Waiting for an incoming session request…',
    _Phase.sessionIncoming => 'Setting up transports…',
    _Phase.ready => 'Starting screen share…',
    _Phase.sharing => '',
    _Phase.error => _statusText,
    _Phase.identityRecovery => _statusText,
  };

  String get _formattedGuestCode {
    final d = _guestCode;
    if (d.length != 9) return d;
    return '${d.substring(0, 3)}-${d.substring(3, 6)}-${d.substring(6)}';
  }

  String get _formattedPermanentCode {
    final d = _permanentConnectCode ?? '';
    if (d.length != 12) return d;
    return '${d.substring(0, 4)} ${d.substring(4, 8)} ${d.substring(8)}';
  }

  /// What fills the preview box when there's no video: the share code while
  /// idle in guest mode, the Allow/Decline consent card while a request is
  /// pending, or the plain status text otherwise.
  Widget _buildPreviewPlaceholder() {
    if (_phase == _Phase.sessionIncoming && _consentPending) {
      final agentName = _pendingSessionFrom.split('@').first;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.screen_share_outlined, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              agentName.isEmpty
                  ? 'An agent wants to view your screen'
                  : '"$agentName" wants to view your screen',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'They will see your screen and control your mouse and keyboard.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: _declinePendingSession,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: const BorderSide(color: AppColors.danger),
                  ),
                  child: const Text('Decline'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _acceptPendingSession,
                  child: const Text('Allow'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_phase == _Phase.connected && _guestMode) {
      // A persistent identity's permanent code takes priority over the
      // ephemeral guest code — a device with one never requests the other
      // (see the router-rtp-capabilities handler).
      final displayCode = _permanentConnectCode ?? _guestCode;
      final isPermanent = _permanentConnectCode != null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.live.withValues(alpha: 0.08),
                border: Border.all(color: AppColors.live.withValues(alpha: 0.35), width: 1.5),
              ),
              child: Icon(Icons.lock_rounded, color: AppColors.live, size: 36),
            ),
            const SizedBox(height: 22),
            Text(
              isPermanent ? 'YOUR CONNECT CODE' : 'YOUR SHARE CODE',
              style: TextStyle(
                color: AppColors.live,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 14),
            if (displayCode.isEmpty)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    isPermanent ? _formattedPermanentCode : _formattedGuestCode,
                    style: appMonoStyle(fontSize: 34, fontWeight: FontWeight.w700).copyWith(letterSpacing: 3),
                  ),
                  const SizedBox(width: 14),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(kCornerRadius),
                      border: Border.all(color: AppColors.live.withValues(alpha: 0.4)),
                    ),
                    child: IconButton(
                      tooltip: 'Copy code',
                      icon: Icon(Icons.copy_rounded, size: 20, color: AppColors.live),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: displayCode));
                        _showTransientBanner('Code copied');
                      },
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: 220,
              child: Divider(color: AppColors.hairline),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_user_rounded, color: AppColors.live, size: 16),
                const SizedBox(width: 8),
                Text(
                  'Read this code to your support agent to start a session.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Center(
      child: Text(
        _previewPlaceholderText,
        style: TextStyle(color: AppColors.textSecondary),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildPreviewArea() {
    final onHold = _phase == _Phase.sharing && _agentOnHold;
    final cornerLabel = onHold
        ? 'ON HOLD'
        : _phase == _Phase.sharing
        ? _sourceName
        : 'Preview';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(kCornerRadius + 4),
          border: Border.all(color: AppColors.hairline),
        ),
        padding: const EdgeInsets.all(10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kCornerRadius),
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: AppColors.background,
                  child: _phase == _Phase.sharing
                      ? RTCVideoView(_renderer, mirror: false)
                      : _buildPreviewPlaceholder(),
                ),
              ),
              Positioned(
                top: 10,
                left: 10,
                child: _buildCornerBadge(cornerLabel, live: _phase == _Phase.sharing && !onHold),
              ),
              if (_transientBanner != null)
                Positioned(
                  top: 10,
                  right: 10,
                  child: _buildCornerBadge(_transientBanner!, live: true),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCornerBadge(String text, {bool live = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(color: AppColors.live, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            text.toUpperCase(),
            style: appMonoStyle(fontSize: 10, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('Technical log', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          iconColor: AppColors.textSecondary,
          collapsedIconColor: AppColors.textSecondary,
          initiallyExpanded: _logExpanded,
          onExpansionChanged: (v) => setState(() => _logExpanded = v),
          children: [
            Container(
              color: AppColors.surface,
              height: 260,
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              // Rebuilds whenever any print() happens anywhere in the app -
              // see app_log.dart. Auto-scrolls to the newest line each time,
              // so it reads like a live console rather than a static dump.
              child: ListenableBuilder(
                listenable: AppLog.instance,
                builder: (context, _) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_logScrollController.hasClients) {
                      _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
                    }
                  });
                  final lines = AppLog.instance.lines;
                  return ListView.builder(
                    controller: _logScrollController,
                    itemCount: lines.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: _buildLogLine(lines[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Color-codes the bracketed subsystem prefix ([xmpp], [mediasoup],
  /// [transport]) so the log reads as a console, not a wall of text. Lines
  /// mentioning an error are shown fully in the danger color instead.
  Widget _buildLogLine(String line) {
    if (line.contains('ERROR') || line.contains('AUTH FAILED')) {
      return Text(line, style: appMonoStyle(fontSize: 11, color: AppColors.danger));
    }
    final match = RegExp(r'^\[(\w+)\]').firstMatch(line);
    if (match != null) {
      final prefix = match.group(0)!;
      final rest = line.substring(prefix.length);
      final prefixColor = prefix == '[xmpp]' ? AppColors.accent : AppColors.logSubsystem;
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(text: prefix, style: appMonoStyle(fontSize: 11, color: prefixColor, fontWeight: FontWeight.w700)),
            TextSpan(text: rest, style: appMonoStyle(fontSize: 11, color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    return Text(line, style: appMonoStyle(fontSize: 11, color: AppColors.textSecondary));
  }
}
