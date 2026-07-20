import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:whixp/whixp.dart' show TransportState;

import 'app_log.dart';
import 'mediasoup/mediasoup_client.dart';
import 'mediasoup_signaling.dart';
import 'router_rtp_capabilities.dart';
import 'src/rust/api/input_inject.dart';
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

enum _Phase { disconnected, connecting, connected, sessionIncoming, ready, sharing, error }

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
  String _connectedJid = '';
  String _sourceName = '';
  bool _logExpanded = false;
  final ScrollController _logScrollController = ScrollController();

  // Guest-code flow (the default entry path): the app connects anonymously
  // to guest.ringopus, asks the orchestrator for a short pairing code, and
  // the agent redeems that code instead of dialing a JID. The legacy
  // JID/password sign-in survives behind the "Advanced" toggle below.
  bool _guestMode = false;
  String _guestCode = ''; // raw digits; rendered grouped XXX-XXX-XXX
  bool _showLegacyLogin = false;

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

  // Chat (Phase 2). Purely additive to the JSON-over-message channel — no
  // whixp/XMPP protocol changes, same as every other message type here.
  // _chatAvailable reflects the server's chatAvailable flag on transport-
  // params (the customer never learns the actual room JID — see
  // DECISIONS.md's Phase 1 design), so "no chat this session" is a normal,
  // expected, always-possible state, not an error to special-case.
  bool _chatAvailable = false;
  bool _chatOpen = false;
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
    // Guest flow is the default: connect anonymously on launch so the
    // customer sees their pairing code without any sign-in step.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _phase == _Phase.disconnected) _connectGuest();
    });
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

  void _startXmpp(XmppClient xmpp) {
    _xmpp = xmpp;
    xmpp.onConnected = (boundJid) {
      _appendLog('[xmpp] connected as $boundJid');
      _xmppConnected = true; // stream is negotiated/bound — restart-ice can now travel
      setState(() => _connectedJid = boundJid);
      _setPhase(_Phase.connected, 'Connected — requesting router capabilities…');
      xmpp.sendToComponent({'type': 'get-router-caps'});
    };
    xmpp.onAuthFailed = () {
      _appendLog('[xmpp] AUTH FAILED');
      _setPhase(
        _Phase.error,
        _guestMode
            ? 'Could not start a guest session — check the server'
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
      _connectedJid = '';
      _phase = _Phase.disconnected;
      _statusText = 'Not connected';
    });
  }

  Future<void> _onComponentMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'router-rtp-capabilities':
        await _signaling.loadDevice(msg['rtpCapabilities'] as Map<String, dynamic>);
        _appendLog('[mediasoup] device loaded from real router-rtp-capabilities');
        if (_guestMode) {
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
        await _signaling.createSendTransport(send);
        await _signaling.createRecvTransport(recv);
        _appendLog('[mediasoup] send + recv transports created from real transport-params');
        if (mounted) {
          setState(() {
            _chatAvailable = (msg['chatAvailable'] as bool?) ?? false;
            _chatMessages.clear();
            _chatOpen = false;
          });
        }
        _setPhase(_Phase.ready, 'Ready to share your screen');

      case 'chat-message':
        final from = (msg['from'] as String?) ?? 'Agent';
        final body = (msg['body'] as String?) ?? '';
        if (mounted) {
          setState(() => _chatMessages.add(_ChatEntry(fromMe: false, from: from, body: body)));
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
        _setHold(true, 'On hold — agent stepped away');

      case 'session-resumed':
        _appendLog('--- session resumed (sid=${msg['sid']}) ---');
        _signaling.resumeSending();
        _setHold(false, 'Sharing "$_sourceName"');

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
  void _refreshGuestCode() {
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

  Future<void> _startCapture() async {
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

    final sid = _signaling.sid;
    if (notifyPeer && sid.isNotEmpty && _xmpp != null) {
      try {
        _xmpp!.sendToComponent({'type': 'session-terminate', 'sid': sid, 'reason': reason.name});
      } catch (_) {}
    }
    await _stopSharingLocally();
    // A Rust bridge failure here must not skip the rest of teardown
    // (signaling cleanup, timer cancellation, phase reset) - those are all
    // independent of input injection.
    try {
      await stopInputInjection();
    } catch (e) {
      _appendLog('stopInputInjection failed: $e');
    }
    await _signaling.cleanup();
    _agentOnHold = false;
    _xmppReconnecting = false;
    _mediasoupRecovering = false;
    _consentTimer?.cancel();
    _consentPending = false;
    _pendingSessionFrom = '';
    _chatAvailable = false;
    _chatOpen = false;
    _chatMessages.clear();
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

  bool get _isConnected =>
      _phase != _Phase.disconnected && _phase != _Phase.connecting && _phase != _Phase.error;

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
        return AppColors.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: _statusDotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _isConnected
                  ? Text(_connectedJid, style: appMonoStyle(fontSize: 13), overflow: TextOverflow.ellipsis)
                  : const Text('Ringopus Remote — Producer'),
            ),
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
        ],
      ),
      // Log panel lives outside the connected/sign-in split so it's visible
      // from the moment the app launches - the whole point of on-screen
      // logging is diagnosing failures that happen before/during sign-in on
      // a packaged .app with no attached terminal (see app_log.dart).
      body: Column(
        children: [
          Expanded(child: _isConnected ? _buildConnectedBody() : _buildStartBody()),
          _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _buildStartBody() =>
      _showLegacyLogin ? _buildSignInBody() : _buildGuestStartBody();

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
                  Text('Ringopus Remote', style: Theme.of(context).textTheme.titleLarge),
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
                      onPressed: _connectGuest,
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
      ),
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
                onPressed: () => setState(() => _chatOpen = !_chatOpen),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: Text(_chatOpen ? 'Hide Chat' : 'Chat'),
              ),
            ),
          if (_phase == _Phase.ready)
            FilledButton.icon(
              onPressed: _startCapture,
              icon: const Icon(Icons.screen_share_outlined, size: 18),
              label: const Text('Share Screen'),
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
    _Phase.ready => 'Ready — click Share Screen above',
    _Phase.sharing => '',
    _Phase.error => _statusText,
  };

  String get _formattedGuestCode {
    final d = _guestCode;
    if (d.length != 9) return d;
    return '${d.substring(0, 3)}-${d.substring(3, 6)}-${d.substring(6)}';
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Your share code',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            if (_guestCode.isEmpty)
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
                    _formattedGuestCode,
                    style: appMonoStyle(fontSize: 34, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Copy code',
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _guestCode));
                      _showTransientBanner('Code copied');
                    },
                  ),
                ],
              ),
            const SizedBox(height: 10),
            Text(
              'Read this code to your support agent to start a session.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              textAlign: TextAlign.center,
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
