import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import 'mediasoup/mediasoup_client.dart';
import 'mediasoup_signaling.dart';
import 'router_rtp_capabilities.dart';
import 'screen_source_picker.dart';
import 'xmpp/xmpp_client.dart';

/// Phase 3: real XMPP signaling (no bridge). Connects as the callee, waits
/// for a real incoming session request the same way the Tauri sharer does,
/// and produces video to a real viewer session.
class XmppProducePage extends StatefulWidget {
  const XmppProducePage({super.key});

  @override
  State<XmppProducePage> createState() => _XmppProducePageState();
}

class _XmppProducePageState extends State<XmppProducePage> {
  final _jidController = TextEditingController();
  final _passwordController = TextEditingController();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final MediasoupSignaling _signaling = MediasoupSignaling();

  XmppClient? _xmpp;
  MediaStream? _stream;
  bool _capturing = false;
  bool _connected = false;
  String _status = 'Disconnected';
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

  void _connect() {
    final jid = _jidController.text.trim();
    final password = _passwordController.text;
    if (jid.isEmpty || password.isEmpty) return;

    final xmpp = XmppClient(jid, password);
    _xmpp = xmpp;
    xmpp.onConnected = (boundJid) {
      _appendLog('[xmpp] connected as $boundJid');
      setState(() {
        _connected = true;
        _status = 'Connected, requesting router capabilities...';
      });
      xmpp.sendToComponent({'type': 'get-router-caps'});
    };
    xmpp.onAuthFailed = () => _appendLog('[xmpp] AUTH FAILED');
    xmpp.onComponentMessage = _onComponentMessage;
    xmpp.connect();
    setState(() => _status = 'Connecting...');
  }

  Future<void> _onComponentMessage(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'router-rtp-capabilities':
        await _signaling.loadDevice(
          msg['rtpCapabilities'] as Map<String, dynamic>,
        );
        _appendLog(
          '[mediasoup] device loaded from real router-rtp-capabilities',
        );
        setState(
          () => _status = 'Ready - waiting for incoming session request...',
        );

      case 'session-incoming':
        final sid = msg['sid'] as String;
        _appendLog('--- session-incoming from ${msg['from']} (sid=$sid) ---');
        _signaling.sid = sid;
        _signaling.sendToComponent = _xmpp!.sendToComponent;
        final device = _signaling.device;
        if (device == null) {
          _appendLog('ERROR: session-incoming before device loaded');
          return;
        }
        _xmpp!.sendToComponent({
          'type': 'session-accept',
          'sid': sid,
          'rtpCapabilities': routerRtpCapabilitiesJson,
        });
        setState(
          () => _status = 'Session accepted, waiting for transport params...',
        );

      case 'transport-params':
        final send = msg['send'] as Map<String, dynamic>;
        final recv = msg['recv'] as Map<String, dynamic>;
        await _signaling.createSendTransport(send);
        await _signaling.createRecvTransport(recv);
        _appendLog(
          '[mediasoup] send + recv transports created from real transport-params',
        );
        setState(
          () => _status = 'Transports ready - share your screen to produce',
        );

      case 'connect-transport-ack':
        _signaling.resolveConnect(msg['transportId'] as String);

      case 'producer-created':
        final producerId = msg['producerId'] as String;
        _signaling.resolveProduce(producerId);
        _appendLog('[transport] produce acked, producerId=$producerId');
        // Matches the real native producer's captured flow: tell the server
        // we're ready once the producer exists, so it creates the caller's
        // consumer.
        _xmpp!.sendToComponent({
          'type': 'producer-ready',
          'sid': _signaling.sid,
          'producerId': producerId,
        });

      case 'data-consumer-params':
        _appendLog(
          '[mediasoup] data-consumer-params received (Phase 4 will wire real injection)',
        );
        await _signaling.consumeData(msg);

      case 'session-error':
        _appendLog('SESSION ERROR: ${msg['reason']}');
        setState(() => _status = 'Session error: ${msg['reason']}');

      case 'session-terminated':
        _appendLog('--- session terminated ---');
        _signaling.cleanup();
        setState(
          () => _status = 'Session terminated - waiting for new request...',
        );

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
      setState(() {
        _capturing = true;
        _status = 'Capturing: ${source.name} - producing...';
      });
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
      _appendLog(
        'ERROR: no H.264 in device.rtpCapabilities - cannot force codec',
      );
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
    final h264 = rtpParameters.codecs.where(
      (c) => c.mimeType.toLowerCase() == 'video/h264',
    );
    if (h264.isEmpty) {
      _appendLog('CODEC PARITY: no H.264 entry in negotiated rtpParameters');
      return;
    }
    final codec = h264.first;
    final profileLevelId = codec.parameters['profile-level-id'];
    final packetizationMode = codec.parameters['packetization-mode'];
    final levelAsymmetryAllowed = codec.parameters['level-asymmetry-allowed'];
    _appendLog(
      'CODEC PARITY: profile-level-id=$profileLevelId (baseline $baselineProfileLevelId) '
      'packetization-mode=$packetizationMode (baseline $baselinePacketizationMode) '
      'level-asymmetry-allowed=$levelAsymmetryAllowed (baseline $baselineLevelAsymmetryAllowed)',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 3 — Real XMPP Signaling')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _jidController,
                    enabled: !_connected,
                    decoration: const InputDecoration(
                      labelText: 'JID',
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _passwordController,
                    enabled: !_connected,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      isDense: true,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: _connected ? null : _connect,
                  child: const Text('Connect'),
                ),
                OutlinedButton(
                  onPressed: (_connected && !_capturing) ? _startCapture : null,
                  child: const Text('Share Screen'),
                ),
                Text(_status),
              ],
            ),
          ),
          SizedBox(
            height: 160,
            child: Container(
              color: Colors.black,
              child: _capturing
                  ? RTCVideoView(_renderer, mirror: false)
                  : const Center(
                      child: Text(
                        'No capture',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _log.length,
              itemBuilder: (context, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
