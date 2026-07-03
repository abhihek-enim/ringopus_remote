import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import 'mediasoup/mediasoup_client.dart';
import 'mediasoup_signaling.dart';
import 'router_rtp_capabilities.dart';
import 'screen_source_picker.dart';
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
  bool _logExpanded = false;
  final List<String> _log = [];

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
    super.dispose();
  }

  void _appendLog(String line) {
    // ignore: avoid_print
    print(line);
    if (mounted) setState(() => _log.add(line));
  }

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

  Color _phaseColor() {
    switch (_phase) {
      case _Phase.disconnected:
        return Colors.grey;
      case _Phase.connecting:
      case _Phase.sessionIncoming:
        return Colors.amber;
      case _Phase.connected:
      case _Phase.ready:
        return Colors.blue;
      case _Phase.sharing:
        return Colors.green;
      case _Phase.error:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _phase != _Phase.disconnected && _phase != _Phase.connecting && _phase != _Phase.error;

    return Scaffold(
      appBar: AppBar(title: const Text('Ringopus Remote — Producer')),
      body: Column(
        children: [
          if (!connected) _buildConnectForm() else _buildStatusBar(),
          Expanded(child: _buildPreviewArea()),
          _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _buildConnectForm() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Sign in', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _jidController,
                enabled: _phase != _Phase.connecting,
                decoration: const InputDecoration(labelText: 'JID', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                enabled: _phase != _Phase.connecting,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _phase == _Phase.connecting ? null : _connect,
                      child: Text(_phase == _Phase.connecting ? 'Connecting…' : 'Connect'),
                    ),
                  ),
                ],
              ),
              if (_phase == _Phase.error) ...[
                const SizedBox(height: 8),
                Text(_statusText, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: _phaseColor(), shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(_statusText, overflow: TextOverflow.ellipsis)),
          if (_phase == _Phase.ready)
            FilledButton.icon(
              onPressed: _startCapture,
              icon: const Icon(Icons.screen_share),
              label: const Text('Share Screen'),
            ),
          if (_phase == _Phase.sharing)
            OutlinedButton.icon(
              onPressed: _stopSharing,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop Sharing'),
            ),
        ],
      ),
    );
  }

  Widget _buildPreviewArea() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: _phase == _Phase.sharing
          ? RTCVideoView(_renderer, mirror: false)
          : Center(
              child: Text(
                switch (_phase) {
                  _Phase.disconnected => 'Sign in to get started',
                  _Phase.connecting => 'Connecting…',
                  _Phase.connected => 'Waiting for an incoming session request…',
                  _Phase.sessionIncoming => 'Setting up transports…',
                  _Phase.ready => 'Ready — click Share Screen above',
                  _Phase.sharing => '',
                  _Phase.error => _statusText,
                },
                style: const TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
            ),
    );
  }

  Widget _buildLogPanel() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Technical log'),
        initiallyExpanded: _logExpanded,
        onExpansionChanged: (v) => setState(() => _logExpanded = v),
        children: [
          SizedBox(
            height: 200,
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _log.length,
              itemBuilder: (context, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
