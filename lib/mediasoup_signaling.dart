import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';

import 'mediasoup/mediasoup_client.dart';
// The fork's ICE types live in handler_interface.dart, which the barrel
// (mediasoup_client.dart) does not re-export. Shown explicitly so the
// signaling layer can build RTCIceServer entries for TURN. No clash with
// flutter_webrtc (it has no RTCIceServer class).
import 'mediasoup/src/handlers/handler_interface.dart'
    show RTCIceServer, RTCIceTransportPolicy, RTCIceCredentialType;
import 'src/rust/api/input_inject.dart';

const Duration produceTimeout = Duration(seconds: 10);
const Duration connectTimeout = Duration(seconds: 10);

// Debug-only: force ICE to use ONLY relay candidates, to prove the TURN path
// in isolation. Build with `flutter run -d windows --dart-define=FORCE_TURN_RELAY=true`;
// false in every normal build. Compile-time const, so zero runtime cost when off.
const bool _kForceTurnRelay = bool.fromEnvironment('FORCE_TURN_RELAY');

/// Converts the server's JSON `iceServers` (from transport-params) into the
/// vendored fork's [RTCIceServer]. The fork's type REQUIRES `username` and
/// `credentialType` (unlike the DOM shape), so both are always set. Null/absent
/// ⇒ empty list ⇒ direct-only, exactly as before TURN existed.
List<RTCIceServer> _parseIceServers(List<dynamic>? raw) {
  if (raw == null) return const <RTCIceServer>[];
  return raw.map((s) {
    final m = s as Map<String, dynamic>;
    return RTCIceServer(
      urls: List<String>.from(m['urls'] as List),
      username: (m['username'] as String?) ?? '',
      credential: m['credential'],
      credentialType: RTCIceCredentialType.password,
    );
  }).toList();
}

class _ConnectPending {
  _ConnectPending(this.callback, this.errback, this.timer);
  final Function callback;
  final Function errback;
  final Timer timer;
}

/// Dart port of the reference app's mediasoupClient.ts. Signaling-transport
/// agnostic by design (matches the reference): callers wire [sendToComponent]
/// and feed incoming component messages into [resolveConnect]/
/// [resolveProduce]/[resolveProduceData] themselves.
class MediasoupSignaling {
  Device? _device;
  Transport? _sendTransport;
  Transport? _recvTransport;
  Producer? _producer;
  DataProducer? _dataProducer;
  DataConsumer? _dataConsumer;
  String sid = '';
  void Function(Map<String, dynamic> msg)? sendToComponent;

  void Function(Map<String, dynamic> payload)? onDataMessage;

  // ICE-derived connection state for whichever transport just changed -
  // label is 'send'/'recv', state is 'connecting'/'connected'/'failed'/
  // 'disconnected'/'closed' (see Transport._handleHandler's
  // '@connectionstatechange' -> 'connectionstatechange' re-emit). Drives
  // network-drop detection in producer_home_page.dart; this class only
  // reports the raw signal, it doesn't interpret severity itself.
  void Function(String label, String connectionState)? onTransportStateChanged;

  Function? _pendingProduceCb;
  Timer? _pendingProduceTimer;

  Function? _pendingProduceDataCb;
  Timer? _pendingProduceDataTimer;

  // Diagnostic pass for the session-start quality ramp-up (see DECISIONS.md
  // and the reconnection-adjacent plan) - not gated behind a feature flag,
  // since it's cheap (1/s) and useful for any future latency debugging, same
  // as the agent's existing [VideoStats] poller.
  Timer? _senderStatsTimer;
  int? _prevSenderBytesSent;
  double? _prevSenderStatsTimestampMs;

  final Map<String, _ConnectPending> _pendingConnect = {};

  // mousemove sequence tracking, matching mediasoupClient.ts's design: the
  // unordered/unreliable remote-control channel can deliver a burst of
  // buffered mousemove packets at once after any stall. Sender stamps each
  // mousemove with an incrementing seq; discard anything at or behind the
  // last one we've already injected instead of replaying through every
  // queued historical position.
  int _lastMoveSeq = -1;

  Device? get device => _device;

  Future<void> loadDevice(
    Map<String, dynamic> routerRtpCapabilitiesJson,
  ) async {
    _device = Device();
    await _device!.load(
      routerRtpCapabilities: RtpCapabilities.fromMap(routerRtpCapabilitiesJson),
    );
    // ignore: avoid_print
    print(
      '[MediasoupSignaling] device loaded, canProduce(video)=${_device!.canProduce(RTCRtpMediaType.RTCRtpMediaTypeVideo)}',
    );
  }

  Future<void> createSendTransport(
    Map<String, dynamic> params, {
    List<dynamic>? iceServers,
  }) async {
    final device = _device;
    if (device == null) {
      throw StateError('[MediasoupSignaling] device not loaded');
    }

    final transport = device.createSendTransport(
      id: params['transportId'] as String,
      iceParameters: IceParameters.fromMap(params['iceParameters']),
      iceCandidates: (params['iceCandidates'] as List)
          .map((c) => IceCandidate.fromMap(c as Map))
          .toList(),
      dtlsParameters: DtlsParameters.fromMap(params['dtlsParameters']),
      sctpParameters: params['sctpParameters'] != null
          ? SctpParameters.fromMap(params['sctpParameters'])
          : null,
      // TURN relay (server-issued; empty list = direct-only, as before).
      iceServers: _parseIceServers(iceServers),
      iceTransportPolicy: _kForceTurnRelay ? RTCIceTransportPolicy.relay : null,
    );
    _sendTransport = transport;
    // ignore: avoid_print
    print('[MediasoupSignaling] send transport created: ${transport.id}');

    transport.on('connectionstatechange', (data) {
      final state = (data as Map)['connectionState'] as String;
      // ignore: avoid_print
      print('[MediasoupSignaling] send transport connectionstatechange: $state');
      onTransportStateChanged?.call('send', state);
    });

    transport.on('connect', (data) {
      // ignore: avoid_print
      print('[MediasoupSignaling] send transport connect fired');
      final callback = data['callback'] as Function;
      final errback = data['errback'] as Function;
      final transportId = transport.id;
      final timer = Timer(connectTimeout, () {
        _pendingConnect.remove(transportId);
        errback(
          StateError('connect-transport ack timeout (send $transportId)'),
        );
      });
      _pendingConnect[transportId] = _ConnectPending(callback, errback, timer);
      sendToComponent?.call({
        'type': 'connect-transport',
        'sid': sid,
        'transportId': transportId,
        'dtlsParameters': (data['dtlsParameters'] as DtlsParameters).toMap(),
        'direction': 'send',
      });
    });

    transport.on('produce', (data) {
      final kind = data['kind'] as String;
      // ignore: avoid_print
      print('[MediasoupSignaling] produce event fired, kind: $kind');
      final callback = data['callback'] as Function;
      final errback = data['errback'] as Function;
      _pendingProduceCb = callback;
      _pendingProduceTimer = Timer(produceTimeout, () {
        _pendingProduceCb = null;
        _pendingProduceTimer = null;
        errback(StateError('produce: server ack timeout'));
      });
      sendToComponent?.call({
        'type': 'produce',
        'sid': sid,
        'transportId': transport.id,
        'kind': kind,
        'rtpParameters': (data['rtpParameters'] as RtpParameters).toMap(),
      });
    });
  }

  Future<void> createRecvTransport(
    Map<String, dynamic> params, {
    List<dynamic>? iceServers,
  }) async {
    final device = _device;
    if (device == null) {
      throw StateError('[MediasoupSignaling] device not loaded');
    }

    final transport = device.createRecvTransport(
      id: params['transportId'] as String,
      iceParameters: IceParameters.fromMap(params['iceParameters']),
      iceCandidates: (params['iceCandidates'] as List)
          .map((c) => IceCandidate.fromMap(c as Map))
          .toList(),
      dtlsParameters: DtlsParameters.fromMap(params['dtlsParameters']),
      sctpParameters: params['sctpParameters'] != null
          ? SctpParameters.fromMap(params['sctpParameters'])
          : null,
      // TURN relay (server-issued; empty list = direct-only, as before).
      iceServers: _parseIceServers(iceServers),
      iceTransportPolicy: _kForceTurnRelay ? RTCIceTransportPolicy.relay : null,
    );
    _recvTransport = transport;
    // ignore: avoid_print
    print('[MediasoupSignaling] recv transport created: ${transport.id}');

    transport.on('connectionstatechange', (data) {
      final state = (data as Map)['connectionState'] as String;
      // ignore: avoid_print
      print('[MediasoupSignaling] recv transport connectionstatechange: $state');
      onTransportStateChanged?.call('recv', state);
    });

    transport.on('connect', (data) {
      // ignore: avoid_print
      print('[MediasoupSignaling] recv transport connect fired');
      final callback = data['callback'] as Function;
      final errback = data['errback'] as Function;
      final transportId = transport.id;
      final timer = Timer(connectTimeout, () {
        _pendingConnect.remove(transportId);
        errback(
          StateError('connect-transport ack timeout (recv $transportId)'),
        );
      });
      _pendingConnect[transportId] = _ConnectPending(callback, errback, timer);
      sendToComponent?.call({
        'type': 'connect-transport',
        'sid': sid,
        'transportId': transportId,
        'dtlsParameters': (data['dtlsParameters'] as DtlsParameters).toMap(),
        'direction': 'recv',
      });
    });
  }

  /// Produces [track] on the send transport, forcing [codec] (mediasoup's
  /// Ortc.reduceCodecs() otherwise silently defaults to the router's first
  /// listed codec - see the Phase 2 VP8-vs-H264 finding).
  ///
  /// [scaleResolutionDownBy] shrinks the encoded output relative to the
  /// captured size (encoder-side downscale). The macOS desktop capturer
  /// ignores width/height constraints entirely - only frameRate is parsed
  /// (verified in flutter_webrtc 1.5.2's FlutterRTCDesktopCapturer.m) - so
  /// this is the only working resolution knob on that path.
  Future<void> produce({
    required MediaStreamTrack track,
    required MediaStream stream,
    required RtpCodecCapability codec,
    double scaleResolutionDownBy = 1.0,
    void Function(Producer producer)? onProducer,
  }) async {
    final transport = _sendTransport;
    if (transport == null) {
      throw StateError('[MediasoupSignaling] send transport not created');
    }
    // See handlerReady's doc comment in transport.dart: the underlying
    // RTCPeerConnection is created asynchronously by a handler.run() call
    // Transport's constructor can't await.
    await transport.handlerReady;

    transport.producerCallback = (producer) {
      _producer = producer as Producer;
      _applySenderTuning(_producer!);
      _startSenderStatsPoller(_producer!);
      onProducer?.call(_producer!);
    };
    transport.produce(
      track: track,
      stream: stream,
      source: 'screen',
      codec: codec,
      // videoGoogleStartBitrate hints the encoder to start near full quality
      // instead of libwebrtc's ~300kbps BWE cold-start default - confirmed via
      // [SenderStats] on a live session: qualityLimitationReason=='bandwidth'
      // for the entire startup ramp (res climbing 640x360 -> 1280x720 over
      // hundreds of frames). This is a HINT, not a guaranteed startup bitrate -
      // actual bitrate is still governed by TWCC/BWE. Deliberately no min/max
      // bitrate hints here: a floor stacked on MAINTAIN_RESOLUTION below risks
      // fighting a genuinely constrained link into packet loss instead of
      // graceful degradation, and the existing maxBitrate encoding param
      // already caps the ceiling.
      codecOptions: ProducerCodecOptions(videoGoogleStartBitrate: 5000),
      // Without an explicit cap libwebrtc applies generic camera-call
      // defaults (~2.5 Mbps), which smears a full desktop capture. 8 Mbps
      // gives the encoder headroom; actual usage still adapts downward via
      // bandwidth estimation. Merged into the SDP-derived encoding by the
      // handler's single-encoding path and signaled to the router, so the
      // server-side BWE allocates for it too.
      //
      // maxFramerate makes the 30fps target explicit at the encoder, and
      // scaleResolutionDownBy (when > 1) shrinks the encoded frames so the
      // bitrate budget isn't starved by a native-Retina capture - starvation
      // makes libwebrtc's screencast adaptation collapse the frame rate,
      // which is exactly what reads as interaction lag on the agent side.
      encodings: [
        RtpEncodingParameters(
          maxBitrate: 8000000,
          maxFramerate: 30,
          scaleResolutionDownBy:
              scaleResolutionDownBy > 1.0 ? scaleResolutionDownBy : null,
        ),
      ],
    );
  }

  /// Post-produce sender tuning that can't be expressed through produce()
  /// arguments. Was MAINTAIN_FRAMERATE (prefer dropping resolution over fps,
  /// since a stalling frame stream reads as "lag" during remote control) -
  /// switched to MAINTAIN_RESOLUTION (2026-07-09): confirmed via live
  /// [SenderStats] that the session-start blurry-ramp was BWE-cold-start
  /// driven (qualityLimitationReason=='bandwidth'), which the
  /// videoGoogleStartBitrate hint above now addresses directly - so the
  /// original tradeoff (MAINTAIN_FRAMERATE's resolution collapse under low
  /// startup BWE) is no longer the dominant cost, and prioritizing sharp/
  /// readable text matters more for a desktop-sharing use case than holding
  /// fps under genuine sustained pressure. (flutter_webrtc 1.5.x exposes no
  /// track.contentHint, so degradationPreference is the available knob.)
  Future<void> _applySenderTuning(Producer producer) async {
    final sender = producer.rtpSender;
    if (sender == null) return;
    try {
      final params = sender.parameters;
      params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
      await sender.setParameters(params);
      // ignore: avoid_print
      print('[MediasoupSignaling] sender degradationPreference set to maintain-resolution');
    } catch (e) {
      // Non-fatal: platform sender may not support setParameters mid-stream.
      // ignore: avoid_print
      print('[MediasoupSignaling] sender tuning skipped: $e');
    }
  }

  /// Diagnostic pass for the session-start quality ramp-up: logs the
  /// outbound-rtp video stats WebRTC itself attributes the encoder's
  /// resolution/bitrate choices to (qualityLimitationReason in particular -
  /// 'bandwidth' confirms the BWE-cold-start hypothesis, 'cpu' would mean a
  /// completely different fix is needed). actualBitrate isn't a native stats
  /// field - computed as a bytesSent delta over the poll interval, same
  /// pattern as the agent's existing [VideoStats] rate= line.
  void _startSenderStatsPoller(Producer producer) {
    _senderStatsTimer?.cancel();
    _prevSenderBytesSent = null;
    _prevSenderStatsTimestampMs = null;
    final sender = producer.rtpSender;
    if (sender == null) return;
    _senderStatsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final reports = await sender.getStats();
        final outbound = reports.firstWhereOrNull(
          (r) => r.type == 'outbound-rtp' && r.values['kind'] == 'video',
        );
        if (outbound == null) return;
        final v = outbound.values;
        final bytesSent = (v['bytesSent'] as num?)?.toInt();
        final tsMs = outbound.timestamp;
        String actualBitrateKbps = '?';
        if (bytesSent != null &&
            _prevSenderBytesSent != null &&
            _prevSenderStatsTimestampMs != null) {
          final dtSec = (tsMs - _prevSenderStatsTimestampMs!) / 1000.0;
          if (dtSec > 0) {
            actualBitrateKbps =
                (((bytesSent - _prevSenderBytesSent!) * 8) / 1000 / dtSec).toStringAsFixed(0);
          }
        }
        _prevSenderBytesSent = bytesSent;
        _prevSenderStatsTimestampMs = tsMs;
        // Relay evidence (field-debugging value; the server iceSelectedTuple is
        // the authoritative gate): the selected candidate-pair's local
        // candidate has candidateType 'relay' when TURN carries the session.
        // RISK: sender-scoped getStats() may omit candidate-pair/local-candidate
        // on Windows flutter_webrtc — then path shows '?' (fall back to
        // PC-level stats if it matters).
        final pair = reports.firstWhereOrNull(
          (r) =>
              r.type == 'candidate-pair' &&
              (r.values['nominated'] == true || r.values['selected'] == true) &&
              r.values['state'] == 'succeeded',
        );
        String path = '?';
        if (pair != null) {
          final localId = pair.values['localCandidateId'];
          final local = reports.firstWhereOrNull(
            (r) => r.type == 'local-candidate' && r.id == localId,
          );
          final ct = local?.values['candidateType'];
          if (ct == 'relay') {
            path = 'relay/${local?.values['relayProtocol'] ?? '?'}';
          } else if (ct != null) {
            path = ct.toString();
          }
        }
        // ignore: avoid_print
        print(
          '[SenderStats] qLimit=${v['qualityLimitationReason']} '
          'qLimitDur=${v['qualityLimitationDurations']} '
          'target=${v['targetBitrate']}bps actual=${actualBitrateKbps}kbps '
          'res=${v['frameWidth']}x${v['frameHeight']} '
          'framesEncoded=${v['framesEncoded']} '
          'encoder=${v['encoderImplementation']} '
          'path=$path',
        );
      } catch (e) {
        // ignore: avoid_print
        print('[SenderStats] poll failed: $e');
      }
    });
  }

  Future<MediaStream?> consumeStream(Map<String, dynamic> params) async {
    final transport = _recvTransport;
    if (transport == null) {
      throw StateError('[MediasoupSignaling] recv transport not created');
    }
    await transport.handlerReady;

    final completer = Completer<Consumer>();
    // consumerCallback?.call(consumer, arguments.accept) - transport.dart
    // invokes it with 2 args (accept is a MediaSFU-specific addition, not
    // present in stock mediasoup-client); a 1-arg closure throws
    // NoSuchMethodError at the call site, not at assignment time.
    transport.consumerCallback = (consumer, [accept]) =>
        completer.complete(consumer as Consumer);
    transport.consume(
      id: params['consumerId'] as String,
      producerId: params['producerId'] as String,
      // peerId is a MediaSFU-specific addition not present in stock
      // mediasoup-client (JS) - it's opaque app bookkeeping (see
      // consumer.dart), not used in ORTC/SDP negotiation, so the session id
      // is a reasonable value.
      peerId: sid,
      kind: RTCRtpMediaTypeExtension.fromString(params['kind'] as String),
      rtpParameters: RtpParameters.fromMap(params['rtpParameters']),
    );
    final consumer = await completer.future;
    // ignore: avoid_print
    print('[MediasoupSignaling] consumer created: ${consumer.id}');
    final stream = await createLocalMediaStream('consumer-${consumer.id}');
    await stream.addTrack(consumer.track);
    return stream;
  }

  Future<void> consumeData(Map<String, dynamic> params) async {
    final transport = _recvTransport;
    if (transport == null) {
      throw StateError('[MediasoupSignaling] recv transport not created');
    }
    await transport.handlerReady;

    // dataConsumerCallback?.call(dataConsumer, accept) - transport.dart
    // invokes it with 2 args (same MediaSFU-specific `accept` addition as
    // consume()'s callback above); this crashed live with NoSuchMethodError
    // until the second param was added.
    transport.dataConsumerCallback = (dataConsumer, [accept]) {
      _dataConsumer = dataConsumer as DataConsumer;
      // ignore: avoid_print
      print('[MediasoupSignaling] dataConsumer created: ${_dataConsumer!.id}');
      // Payload shape confirmed from data_consumer.dart: {'data': RTCDataChannelMessage}.
      // Forwards the raw JSON string straight through to Rust - same shape
      // the reference Tauri app's input_inject.rs already deserializes with
      // serde, no reformatting of the payload itself. The seq-discard check
      // below is a forwarding decision, not a reformat.
      _dataConsumer!.on('message', (event) {
        final message = (event as Map)['data'] as RTCDataChannelMessage;
        if (message.isBinary) return; // remote-control channel is text-only

        final text = message.text;
        try {
          final parsed = jsonDecode(text) as Map<String, dynamic>;
          if (parsed['type'] == 'mousemove' && parsed['seq'] != null) {
            final seq = parsed['seq'] as int;
            if (seq <= _lastMoveSeq) return;
            _lastMoveSeq = seq;
          }
        } catch (_) {
          // Malformed JSON - let Rust's serde report it rather than
          // silently dropping, matching the original's forward-and-let-the-
          // deserializer-fail behavior for non-mousemove parse issues.
        }

        injectInput(payloadJson: text).catchError((Object e) {
          // ignore: avoid_print
          print('[MediasoupSignaling] inject_input failed: $e');
        });
      });
    };
    // No SctpStreamParameters.fromMap in the vendored library - built
    // manually. Real captured shape (see the earlier devtools capture) is
    // just {"streamId": 0, "ordered": false}.
    final sctpJson = params['sctpStreamParameters'] as Map<String, dynamic>;
    transport.consumeData(
      id: params['dataConsumerId'] as String,
      dataProducerId: params['dataProducerId'] as String,
      sctpStreamParameters: SctpStreamParameters(
        streamId: sctpJson['streamId'] as int,
        ordered: sctpJson['ordered'] as bool?,
        maxPacketLifeTime: sctpJson['maxPacketLifeTime'] as int?,
        maxRetransmits: sctpJson['maxRetransmits'] as int?,
      ),
      label: (params['label'] as String?) ?? 'remote-control',
      protocol: (params['protocol'] as String?) ?? '',
    );
  }

  /// Closes and replaces only the data-channel consumer — used when a
  /// different agent takes over remote-control input for this same customer
  /// session (transfer). _sendTransport/_producer/sid (the screen-share leg)
  /// and _recvTransport itself are untouched: a transport connects this
  /// customer to the *server*, not to any specific agent, so only the
  /// DataConsumer object bound to a specific agent's dataProducerId needs to
  /// move. Safe to call even when no prior _dataConsumer exists (first attach).
  Future<void> rebindDataConsumer(Map<String, dynamic> params) async {
    _dataConsumer?.close();
    _dataConsumer = null;
    _lastMoveSeq = -1; // a new agent's input isn't comparable to the old agent's seq numbers
    await consumeData(params);
  }

  /// Local bandwidth/CPU optimization for hold: stops the encoder from
  /// consuming CPU while nobody is watching. Not required for correctness -
  /// the server's own producer.pause()/consumer.pause() are what actually
  /// stop RTP from being relayed.
  void pauseSending() => _producer?.pause();
  void resumeSending() => _producer?.resume();

  /// Restarts ICE on the still-open send/recv transport after a network blip,
  /// using fresh iceParameters the orchestrator returned from its own
  /// WebRtcTransport.restartIce(). This preserves the producer/consumer (unlike
  /// a full transport rebuild), so the agent's video resumes without any
  /// agent-side change. Transport.restartIce enqueues on the transport's flex
  /// queue (sync) and no-ops if the transport never completed its initial
  /// connect. Mirrors rebindDataConsumer() in reaching a private transport
  /// field via a small public method.
  void restartIce(String label, Map<String, dynamic> iceParametersJson) {
    final transport = label == 'send' ? _sendTransport : _recvTransport;
    if (transport == null) return;
    transport.restartIce(IceParameters.fromMap(iceParametersJson));
    // ignore: avoid_print
    print('[MediasoupSignaling] restartIce applied to $label transport');
  }

  void resolveConnect(String transportId) {
    final pending = _pendingConnect[transportId];
    if (pending == null) return;
    pending.timer.cancel();
    _pendingConnect.remove(transportId);
    pending.callback();
    // ignore: avoid_print
    print(
      '[MediasoupSignaling] connect ack received for transport: $transportId',
    );
  }

  void resolveProduce(String producerId) {
    _pendingProduceTimer?.cancel();
    _pendingProduceTimer = null;
    final cb = _pendingProduceCb;
    if (cb != null) {
      cb(producerId);
      _pendingProduceCb = null;
    }
  }

  void resolveProduceData(String dataProducerId) {
    _pendingProduceDataTimer?.cancel();
    _pendingProduceDataTimer = null;
    final cb = _pendingProduceDataCb;
    if (cb != null) {
      cb(dataProducerId);
      _pendingProduceDataCb = null;
    }
  }

  Future<void> cleanup() async {
    _pendingProduceTimer?.cancel();
    _pendingProduceDataTimer?.cancel();
    _senderStatsTimer?.cancel();
    _senderStatsTimer = null;
    _prevSenderBytesSent = null;
    _prevSenderStatsTimestampMs = null;
    for (final p in _pendingConnect.values) {
      p.timer.cancel();
    }
    _pendingConnect.clear();
    _pendingProduceCb = null;
    _pendingProduceTimer = null;
    _pendingProduceDataCb = null;
    _pendingProduceDataTimer = null;
    _lastMoveSeq = -1;

    // Producer/DataProducer/DataConsumer.close() are synchronous (void);
    // only Transport.close() (and Consumer.close(), not held here) actually
    // return Future<void> - awaiting those two is what makes cleanup()
    // actually wait for the underlying RTCPeerConnection/handler teardown
    // instead of firing-and-forgetting it.
    _producer?.close();
    _dataProducer?.close();
    _dataConsumer?.close();
    await _sendTransport?.close();
    await _recvTransport?.close();
    _producer = null;
    _dataProducer = null;
    _dataConsumer = null;
    _sendTransport = null;
    _recvTransport = null;
    sid = '';
    // ignore: avoid_print
    print('[MediasoupSignaling] cleaned up');
  }
}
