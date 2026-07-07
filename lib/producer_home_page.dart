import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:whixp/whixp.dart' show TransportState;

import 'app_log.dart';
import 'mediasoup/mediasoup_client.dart';
import 'mediasoup_signaling.dart';
import 'router_rtp_capabilities.dart';
import 'screen_source_picker.dart';
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

// Why a drop is being torn down - purely for status text / notifyPeer choice,
// not a new _Phase value (see DECISIONS.md-style reasoning in the plan this
// implements: reuses _Phase.error, orthogonal boolean flags for "still
// trying to recover" instead of new phases).
enum _TeardownReason { userRequested, remoteTerminated, xmppUnrecoverable, mediasoupUnrecoverable, appDisposed }

// Bounded-recovery tunables for the mediasoup/ICE drop path. Not measured
// against real network conditions yet - see the plan's Verification section.
const Duration _mediasoupIceGracePeriod = Duration(seconds: 5);
const Duration _mediasoupRecoveryAckTimeout = Duration(seconds: 5);
const Duration _mediasoupRecoveryRetrySpacing = Duration(seconds: 2);
const int _maxMediasoupRecoveryAttempts = 3;
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

  // Orthogonal to _Phase, not a new phase value: _Phase.sharing correctly
  // stays true throughout hold/transfer since capture/renderer/MediaStream
  // never stop - only whether an agent is actively watching/controlling
  // changes.
  bool _agentOnHold = false;
  String? _transientBanner;
  Timer? _transientBannerTimer;

  // Network-drop detection/recovery state (orthogonal to _Phase, same
  // convention as _agentOnHold above). _tearingDown guards _teardownSession
  // against double invocation - XMPP's unrecoverable timer and mediasoup's
  // recovery-exhaustion path are independent triggers that can both fire
  // close together.
  bool _tearingDown = false;
  bool _xmppReconnecting = false;
  Timer? _xmppUnrecoverableTimer;
  bool _mediasoupRecovering = false;
  final Map<String, Timer> _mediasoupGraceTimers = {};
  final Map<String, Timer> _mediasoupRecoveryTimers = {};
  final Map<String, int> _mediasoupRecoveryAttempts = {};
  final Map<String, int> _mediasoupCurrentAttemptId = {};

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _signaling.onTransportStateChanged = _onMediasoupStateChanged;
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
    _transientBannerTimer?.cancel();
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

    final xmpp = XmppClient(jid, password);
    _xmpp = xmpp;
    xmpp.onConnected = (boundJid) {
      _appendLog('[xmpp] connected as $boundJid');
      setState(() => _connectedJid = boundJid);
      _setPhase(_Phase.connected, 'Connected — requesting router capabilities…');
      xmpp.sendToComponent({'type': 'get-router-caps'});
    };
    xmpp.onAuthFailed = () {
      _appendLog('[xmpp] AUTH FAILED');
      _setPhase(_Phase.error, 'Login failed — check JID/password');
    };
    xmpp.onComponentMessage = _onComponentMessage;
    xmpp.onStateChanged = _onXmppStateChanged;
    xmpp.connect();
    _setPhase(_Phase.connecting, 'Connecting…');
  }

  Future<void> _disconnect() async {
    await _teardownSession(reason: _TeardownReason.userRequested, notifyPeer: true);
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
        _setPhase(_Phase.connected, 'Ready — waiting for an incoming session request…');

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
        _signaling.sid = sid;
        _signaling.sendToComponent = _xmpp!.sendToComponent;
        if (_signaling.device == null) {
          _appendLog('ERROR: session-incoming before device loaded');
          return;
        }
        _xmpp!.sendToComponent({
          'type': 'session-accept',
          'sid': sid,
          'rtpCapabilities': routerRtpCapabilitiesJson,
        });
        _setPhase(_Phase.sessionIncoming, 'Session accepted — setting up transports…');

      case 'transport-params':
        final send = msg['send'] as Map<String, dynamic>;
        final recv = msg['recv'] as Map<String, dynamic>;
        await _signaling.createSendTransport(send);
        await _signaling.createRecvTransport(recv);
        _appendLog('[mediasoup] send + recv transports created from real transport-params');
        _setPhase(_Phase.ready, 'Ready to share your screen');

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

      // Response to a client-initiated 'renegotiate-transports' request (see
      // _runMediasoupRecoveryAttempt) - NOT YET SENT BY THE ORCHESTRATOR
      // TODAY; this handler is the client's half of a protocol extension
      // that needs matching server-side support (see the plan's
      // Coordination Notes). 'attemptId' must be echoed back unchanged so a
      // stale/late reply from a superseded attempt can be told apart from
      // the current one.
      case 'renegotiate-transport-params':
        await _onRenegotiateTransportParams(msg);

      default:
        _appendLog('[xmpp] unhandled message type: ${msg['type']}');
    }
  }

  Future<void> _startCapture() async {
    final source = await showDialog<DesktopCapturerSource>(
      context: context,
      builder: (_) => const ScreenSourcePicker(),
    );
    if (source == null) return;

    try {
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': source.id},
          'mandatory': {'frameRate': 30.0},
        },
      });
      _stream = stream;
      _renderer.srcObject = stream;
      setState(() => _sourceName = source.name);
      _setPhase(_Phase.sharing, 'Sharing “${source.name}”');
      _tearingDown = false; // fresh session - re-arm the teardown choke point
      await hideCursor();
      await startInputInjection();
      await _produce();
    } catch (e) {
      _appendLog('Capture failed: $e');
    }
  }

  Future<void> _produce() async {
    final device = _signaling.device;
    final stream = _stream;
    if (device == null || stream == null) return;

    final h264 = device.rtpCapabilities.codecs
        .where((c) => c.mimeType.toLowerCase() == 'video/h264')
        .firstOrNull;
    if (h264 == null) {
      _appendLog('ERROR: no H.264 in device.rtpCapabilities — cannot force codec');
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
      codec: h264,
      scaleResolutionDownBy: scaleDown,
      onProducer: (producer) {
        _appendLog('--- Producer created: ${producer.id} ---');
        _logCodecParity(producer.rtpParameters);
      },
    );
  }

  void _logCodecParity(RtpParameters rtpParameters) {
    final h264 = rtpParameters.codecs.where((c) => c.mimeType.toLowerCase() == 'video/h264');
    if (h264.isEmpty) {
      _appendLog('CODEC PARITY: no H.264 entry in negotiated rtpParameters');
      return;
    }
    final codec = h264.first;
    _appendLog(
      'CODEC PARITY: profile-level-id=${codec.parameters['profile-level-id']} '
      '(baseline $baselineProfileLevelId) '
      'packetization-mode=${codec.parameters['packetization-mode']} '
      '(baseline $baselinePacketizationMode) '
      'level-asymmetry-allowed=${codec.parameters['level-asymmetry-allowed']} '
      '(baseline $baselineLevelAsymmetryAllowed)',
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
    for (final t in _mediasoupGraceTimers.values) {
      t.cancel();
    }
    _mediasoupGraceTimers.clear();
    for (final t in _mediasoupRecoveryTimers.values) {
      t.cancel();
    }
    _mediasoupRecoveryTimers.clear();
    // A session torn down mid-recovery (e.g. 2 of 3 attempts already used)
    // must not leave a fresh future session inheriting a stale attempt
    // count/attemptId and getting fewer real retries.
    _mediasoupRecoveryAttempts.clear();
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
  /// showCursor()/stopInputInjection() awaits) specifically so that when
  /// this is invoked via unawaited(...) from dispose(), its synchronous
  /// first line (_renderer.srcObject = null) still runs before dispose()
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
    await showCursor();
    await stopInputInjection();
    await _signaling.cleanup();
    _agentOnHold = false;
    _xmppReconnecting = false;
    _mediasoupRecovering = false;
    _cancelAllDropTimers();
    if (mounted) {
      _setPhase(
        reason == _TeardownReason.userRequested || reason == _TeardownReason.remoteTerminated
            ? _Phase.connected
            : _Phase.error,
        _statusTextFor(reason),
      );
    }
  }

  // --- XMPP drop detection -----------------------------------------------

  void _onXmppStateChanged(TransportState state) {
    if (_tearingDown) return;
    switch (state) {
      case TransportState.connected:
        _xmppUnrecoverableTimer?.cancel();
        _xmppUnrecoverableTimer = null;
        if (_xmppReconnecting && mounted) {
          setState(() => _xmppReconnecting = false);
        }
      case TransportState.connectionFailure:
      case TransportState.reconnecting:
      case TransportState.disconnected:
        // Not TransportState.killed/terminated - those are definitive stops
        // (an explicit disconnect() call), not a mid-session drop to
        // recover from. whixp's own reconnection policy + XEP-0198 resume
        // already self-heal brief blips with zero app involvement; only
        // escalate if this drags on past the grace window below.
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
        _mediasoupGraceTimers.remove(label)?.cancel();
        _mediasoupRecoveryAttempts.remove(label);
        _mediasoupCurrentAttemptId.remove(label);
        if (_mediasoupRecoveryAttempts.isEmpty && _mediasoupRecovering && mounted) {
          setState(() => _mediasoupRecovering = false);
        }
      case 'disconnected':
        // ICE's own transient state - can self-heal (ICE renegotiation/
        // trickle) without app involvement, mirroring XMPP's SM-resume
        // tolerance above. Give it a short grace window before treating it
        // as a confirmed drop.
        _mediasoupGraceTimers[label]?.cancel();
        _mediasoupGraceTimers[label] = Timer(_mediasoupIceGracePeriod, () {
          if (_tearingDown) return;
          unawaited(_attemptMediasoupRecovery(label));
        });
      case 'failed':
      case 'closed':
        _mediasoupGraceTimers.remove(label)?.cancel();
        unawaited(_attemptMediasoupRecovery(label));
      default:
      // 'connecting' - no action.
    }
  }

  Future<void> _attemptMediasoupRecovery(String label) async {
    if (_tearingDown) return;
    if (_mediasoupRecoveryAttempts.containsKey(label)) return; // already in flight
    if (mounted) setState(() => _mediasoupRecovering = true);
    _mediasoupRecoveryAttempts[label] = 0;
    _runMediasoupRecoveryAttempt(label);
  }

  void _runMediasoupRecoveryAttempt(String label) {
    if (_tearingDown) return;
    final attempt = (_mediasoupRecoveryAttempts[label] ?? 0) + 1;
    _mediasoupRecoveryAttempts[label] = attempt;
    final attemptId = (_mediasoupCurrentAttemptId[label] ?? 0) + 1;
    _mediasoupCurrentAttemptId[label] = attemptId;

    _appendLog('[recovery] $label attempt $attempt/$_maxMediasoupRecoveryAttempts (attemptId=$attemptId)');
    _xmpp?.sendToComponent({
      'type': 'renegotiate-transports',
      'sid': _signaling.sid,
      'direction': label,
      'attemptId': attemptId,
    });

    _mediasoupRecoveryTimers[label]?.cancel();
    _mediasoupRecoveryTimers[label] = Timer(_mediasoupRecoveryAckTimeout, () {
      if (_tearingDown) return;
      if (_mediasoupCurrentAttemptId[label] != attemptId) return; // superseded by a later attempt
      if (attempt >= _maxMediasoupRecoveryAttempts) {
        _onMediasoupRecoveryExhausted(label);
      } else {
        Timer(_mediasoupRecoveryRetrySpacing, () {
          if (_tearingDown) return;
          if (_mediasoupCurrentAttemptId[label] != attemptId) return;
          _runMediasoupRecoveryAttempt(label);
        });
      }
    });
  }

  void _onMediasoupRecoveryExhausted(String label) {
    if (_tearingDown) return;
    _appendLog('[recovery] $label exhausted retries — tearing down session');
    unawaited(_teardownSession(reason: _TeardownReason.mediasoupUnrecoverable, notifyPeer: true));
  }

  /// Handles the orchestrator's reply to a client-initiated
  /// 'renegotiate-transports' request. See the case in _onComponentMessage
  /// for the protocol-coordination caveat - the orchestrator doesn't send
  /// this message today.
  Future<void> _onRenegotiateTransportParams(Map<String, dynamic> msg) async {
    final label = msg['direction'] as String;
    final attemptId = msg['attemptId'] as int;
    if (_mediasoupCurrentAttemptId[label] != attemptId) {
      _appendLog(
        '[recovery] discarding stale renegotiate-transport-params for $label '
        '(attemptId=$attemptId, current=${_mediasoupCurrentAttemptId[label]})',
      );
      return;
    }
    if (_tearingDown) return;
    _mediasoupRecoveryTimers.remove(label)?.cancel();
    try {
      final transportParams = msg['transport'] as Map<String, dynamic>;
      if (label == 'send') {
        await _signaling.createSendTransport(transportParams);
        await _produce(); // recreates the producer against the still-alive capture track
      } else {
        await _signaling.createRecvTransport(transportParams);
        final dataConsumerParams = msg['dataConsumer'] as Map<String, dynamic>?;
        if (dataConsumerParams != null) {
          await _signaling.rebindDataConsumer(dataConsumerParams);
        }
      }
      _mediasoupRecoveryAttempts.remove(label);
      _mediasoupCurrentAttemptId.remove(label);
      if (_mediasoupRecoveryAttempts.isEmpty && mounted) {
        setState(() => _mediasoupRecovering = false);
      }
      _appendLog('[recovery] $label recovered');
    } catch (e) {
      _appendLog('[recovery] $label recreation failed: $e');
      _onMediasoupRecoveryExhausted(label);
    }
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
          Expanded(child: _isConnected ? _buildConnectedBody() : _buildSignInBody()),
          _buildLogPanel(),
        ],
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
        Expanded(child: _buildPreviewArea()),
      ],
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
                      : Center(
                          child: Text(
                            _previewPlaceholderText,
                            style: TextStyle(color: AppColors.textSecondary),
                            textAlign: TextAlign.center,
                          ),
                        ),
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
