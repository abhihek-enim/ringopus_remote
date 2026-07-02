import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'mediasoup/mediasoup_client.dart';
import 'router_rtp_capabilities.dart';
import 'screen_source_picker.dart';

/// Phase 2 spike: Device.load() -> createSendTransport() -> produce()
/// against the real mediasoup server, via the throwaway phase2_bridge
/// (manual/hardcoded signaling stand-in - no XMPP in this app yet).
class ProduceSpikePage extends StatefulWidget {
  const ProduceSpikePage({super.key});

  @override
  State<ProduceSpikePage> createState() => _ProduceSpikePageState();
}

class _ProduceSpikePageState extends State<ProduceSpikePage> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final BridgeClient _bridge = BridgeClient();
  MediaStream? _stream;
  Transport? _sendTransport;

  bool _capturing = false;
  String _status = 'Idle';
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
  }

  @override
  void dispose() {
    _sendTransport?.close();
    _renderer.dispose();
    _stream?.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    // ignore: avoid_print
    print(line);
    setState(() => _log.add(line));
  }

  Future<void> _startCapture() async {
    final source = await showDialog<DesktopCapturerSource>(
      context: context,
      builder: (_) => const ScreenSourcePicker(),
    );
    if (source == null) return;

    setState(() => _status = 'Starting capture...');
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
        _status = 'Capturing: ${source.name}';
      });
    } catch (e) {
      setState(() => _status = 'Capture failed: $e');
    }
  }

  Future<void> _produce() async {
    if (_stream == null) return;
    _log.clear();
    setState(() => _status = 'Negotiating with bridge...');

    try {
      final params = await _bridge.getTransportParams();
      _appendLog('[bridge] sid=${params['sid']}');

      final device = Device();
      await device.load(
        routerRtpCapabilities: RtpCapabilities.fromMap(
          routerRtpCapabilitiesJson,
        ),
      );

      final canProduceVideo = device.canProduce(
        RTCRtpMediaType.RTCRtpMediaTypeVideo,
      );
      _appendLog('device.canProduce(video) = $canProduceVideo');
      if (!canProduceVideo) {
        setState(() => _status = 'Device cannot produce video - aborting');
        return;
      }

      // Router lists VP8 before H.264 (VP8 is fallback-only per project
      // convention), and Ortc.reduceCodecs() defaults to the first codec
      // when produce() isn't given an explicit preference - so without this,
      // produce() silently negotiates VP8 instead of H.264.
      final h264Capability = device.rtpCapabilities.codecs
          .where((c) => c.mimeType.toLowerCase() == 'video/h264')
          .firstOrNull;
      if (h264Capability == null) {
        _appendLog(
          'ERROR: no H.264 in device.rtpCapabilities - cannot force codec',
        );
      } else {
        _appendLog(
          'Forcing produce() codec preference: ${h264Capability.mimeType}',
        );
      }

      final send = params['send'] as Map<String, dynamic>;
      final sendTransport = device.createSendTransport(
        id: send['transportId'] as String,
        iceParameters: IceParameters.fromMap(send['iceParameters']),
        iceCandidates: (send['iceCandidates'] as List)
            .map((c) => IceCandidate.fromMap(c as Map))
            .toList(),
        dtlsParameters: DtlsParameters.fromMap(send['dtlsParameters']),
        sctpParameters: send['sctpParameters'] != null
            ? SctpParameters.fromMap(send['sctpParameters'])
            : null,
        producerCallback: (producer) => _onProducer(producer as Producer),
      );
      _sendTransport = sendTransport;

      sendTransport.on('connect', (data) async {
        final callback = data['callback'] as Function;
        final errback = data['errback'] as Function;
        try {
          final dtlsParameters = (data['dtlsParameters'] as DtlsParameters)
              .toMap();
          await _bridge.connectTransport(dtlsParameters);
          _appendLog('[transport] connect acked by server');
          callback();
        } catch (e) {
          errback(e);
        }
      });

      sendTransport.on('produce', (data) async {
        final callback = data['callback'] as Function;
        final errback = data['errback'] as Function;
        try {
          final kind = data['kind'] as String;
          final rtpParameters = (data['rtpParameters'] as RtpParameters)
              .toMap();
          final ack = await _bridge.produce(kind, rtpParameters);
          _appendLog(
            '[transport] produce acked, producerId=${ack['producerId']}',
          );
          callback(ack['producerId']);
        } catch (e) {
          errback(e);
        }
      });

      // Vendored bug workaround: the transport's underlying RTCPeerConnection
      // is created asynchronously by a handler.run() call that Transport's
      // (necessarily synchronous) constructor can't await. Without this,
      // produce() can run before it exists and crash on a null peer
      // connection. See handlerReady's doc comment in transport.dart.
      await sendTransport.handlerReady;

      setState(() => _status = 'Producing video...');
      sendTransport.produce(
        track: _stream!.getVideoTracks().first,
        stream: _stream!,
        source: 'screen',
        codec: h264Capability,
      );
    } catch (e) {
      _appendLog('ERROR: $e');
      setState(() => _status = 'Failed: $e');
    }
  }

  Future<void> _onProducer(Producer producer) async {
    _appendLog('--- Producer created: ${producer.id} ---');
    _logCodecParity(producer.rtpParameters);

    setState(() => _status = 'Producer created, waiting for real consumer...');
    try {
      final result = await _bridge.producerReady(producer.id);
      final consumer = result['consumer'] as Map<String, dynamic>;
      _appendLog(
        '--- Real consumer created by bridge caller: ${consumer['id']} ---',
      );
      final consumerRtp = consumer['rtpParameters'] as Map<String, dynamic>;
      final codecs = consumerRtp['codecs'] as List;
      final h264 = codecs.cast<Map<String, dynamic>>().firstWhere(
        (c) => (c['mimeType'] as String).toLowerCase() == 'video/h264',
        orElse: () => <String, dynamic>{},
      );
      if (h264.isNotEmpty) {
        final p = h264['parameters'] as Map<String, dynamic>;
        _appendLog(
          '[consume-side, from real server] profile-level-id=${p['profile-level-id']} '
          'packetization-mode=${p['packetization-mode']} '
          'level-asymmetry-allowed=${p['level-asymmetry-allowed']}',
        );
      }
      setState(
        () => _status = 'Done - real producer + real consumer confirmed',
      );
    } catch (e) {
      _appendLog('producer-ready/consume failed: $e');
      setState(() => _status = 'Produced, but consume-side proof failed: $e');
    }
  }

  void _logCodecParity(RtpParameters rtpParameters) {
    final h264 = rtpParameters.codecs.where(
      (c) => c.mimeType.toLowerCase() == 'video/h264',
    );
    if (h264.isEmpty) {
      _appendLog(
        'CODEC PARITY: no H.264 entry in negotiated rtpParameters (codecs: '
        '${rtpParameters.codecs.map((c) => c.mimeType).join(', ')})',
      );
      return;
    }
    final codec = h264.first;
    final profileLevelId = codec.parameters['profile-level-id'];
    final packetizationMode = codec.parameters['packetization-mode'];
    final levelAsymmetryAllowed = codec.parameters['level-asymmetry-allowed'];

    _appendLog('CODEC PARITY CHECK (produce-side, negotiated by libwebrtc):');
    _appendLog(
      '  profile-level-id:        $profileLevelId  '
      '(baseline: $baselineProfileLevelId)  '
      '${profileLevelId == baselineProfileLevelId ? 'MATCH' : 'MISMATCH'}',
    );
    _appendLog(
      '  packetization-mode:      $packetizationMode  '
      '(baseline: $baselinePacketizationMode)  '
      '${packetizationMode == baselinePacketizationMode ? 'MATCH' : 'MISMATCH'}',
    );
    _appendLog(
      '  level-asymmetry-allowed: $levelAsymmetryAllowed  '
      '(baseline: $baselineLevelAsymmetryAllowed)  '
      '${levelAsymmetryAllowed == baselineLevelAsymmetryAllowed ? 'MATCH' : 'MISMATCH'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 2 — Produce Spike')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _capturing ? null : _startCapture,
                  child: const Text('1. Share Screen'),
                ),
                FilledButton(
                  onPressed: _capturing ? _produce : null,
                  child: const Text('2. Produce to mediasoup'),
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
