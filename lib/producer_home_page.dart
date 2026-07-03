import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import 'app_log.dart';
import 'mediasoup/mediasoup_client.dart';
import 'mediasoup_signaling.dart';
import 'router_rtp_capabilities.dart';
import 'screen_source_picker.dart';
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

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
  }

  @override
  void dispose() {
    _xmpp?.disconnect();
    _signaling.cleanup();
    _renderer.dispose();
    _stream?.dispose();
    _logScrollController.dispose();
    super.dispose();
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
    xmpp.connect();
    _setPhase(_Phase.connecting, 'Connecting…');
  }

  Future<void> _disconnect() async {
    await _stopSharingLocally();
    _signaling.cleanup();
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
        await _signaling.consumeData(msg);

      case 'session-error':
        _appendLog('SESSION ERROR: ${msg['reason']}');
        _setPhase(_Phase.error, 'Session error: ${msg['reason']}');

      case 'session-terminated':
        _appendLog('--- session terminated ---');
        await _stopSharingLocally();
        _signaling.cleanup();
        _setPhase(_Phase.connected, 'Session ended — waiting for a new request…');

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

    await _signaling.produce(
      track: stream.getVideoTracks().first,
      stream: stream,
      codec: h264,
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
    final sid = _signaling.sid;
    if (sid.isNotEmpty) {
      _xmpp?.sendToComponent({'type': 'session-terminate', 'sid': sid});
    }
    await _stopSharingLocally();
    _signaling.cleanup();
    _setPhase(_Phase.connected, 'Stopped — waiting for a new session request…');
  }

  bool get _isConnected =>
      _phase != _Phase.disconnected && _phase != _Phase.connecting && _phase != _Phase.error;

  Color get _statusDotColor {
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
      body: _isConnected ? _buildConnectedBody() : _buildSignInBody(),
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
        _buildLogPanel(),
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
    final cornerLabel = _phase == _Phase.sharing ? _sourceName : 'Preview';
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
                child: _buildCornerBadge(cornerLabel, live: _phase == _Phase.sharing),
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
