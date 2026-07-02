import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'produce_spike_page.dart';
import 'screen_source_picker.dart';
import 'src/rust/frb_generated.dart';
import 'xmpp_produce_page.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const RingopusProducerApp());
}

class RingopusProducerApp extends StatelessWidget {
  const RingopusProducerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ringopus Remote Producer',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const CaptureSpikePage(),
    );
  }
}

/// Phase 1 spike: trigger the desktop capture picker and render the
/// captured stream locally. No signaling/networking yet.
class CaptureSpikePage extends StatefulWidget {
  const CaptureSpikePage({super.key});

  @override
  State<CaptureSpikePage> createState() => _CaptureSpikePageState();
}

class _CaptureSpikePageState extends State<CaptureSpikePage> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  bool _capturing = false;
  String _status = 'Idle';

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
  }

  @override
  void dispose() {
    _stopCapture();
    _renderer.dispose();
    super.dispose();
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

  Future<void> _stopCapture() async {
    _renderer.srcObject = null;
    await _stream?.dispose();
    _stream = null;
    if (mounted) {
      setState(() {
        _capturing = false;
        _status = 'Idle';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ringopus Remote Producer — Capture Spike')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _capturing ? null : _startCapture,
                  child: const Text('Share Screen'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _capturing ? _stopCapture : null,
                  child: const Text('Stop'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProduceSpikePage()),
                  ),
                  child: const Text('Phase 2: Produce Spike'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const XmppProducePage()),
                  ),
                  child: const Text('Phase 3: Real XMPP'),
                ),
                const SizedBox(width: 16),
                Text(_status),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.black,
              child: _capturing
                  ? RTCVideoView(_renderer, mirror: false)
                  : const Center(
                      child: Text(
                        'No active capture',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
