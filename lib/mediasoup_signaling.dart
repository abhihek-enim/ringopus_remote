import 'dart:async';
import 'dart:convert';

import 'mediasoup/mediasoup_client.dart';
import 'src/rust/api/input_inject.dart';

const Duration produceTimeout = Duration(seconds: 10);
const Duration connectTimeout = Duration(seconds: 10);

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

  Function? _pendingProduceCb;
  Timer? _pendingProduceTimer;

  Function? _pendingProduceDataCb;
  Timer? _pendingProduceDataTimer;

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

  Future<void> createSendTransport(Map<String, dynamic> params) async {
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
    );
    _sendTransport = transport;
    // ignore: avoid_print
    print('[MediasoupSignaling] send transport created: ${transport.id}');

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

  Future<void> createRecvTransport(Map<String, dynamic> params) async {
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
    );
    _recvTransport = transport;
    // ignore: avoid_print
    print('[MediasoupSignaling] recv transport created: ${transport.id}');

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
  Future<void> produce({
    required MediaStreamTrack track,
    required MediaStream stream,
    required RtpCodecCapability codec,
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
      onProducer?.call(_producer!);
    };
    transport.produce(
      track: track,
      stream: stream,
      source: 'screen',
      codec: codec,
    );
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

  void cleanup() {
    _pendingProduceTimer?.cancel();
    _pendingProduceDataTimer?.cancel();
    for (final p in _pendingConnect.values) {
      p.timer.cancel();
    }
    _pendingConnect.clear();
    _pendingProduceCb = null;
    _pendingProduceTimer = null;
    _pendingProduceDataCb = null;
    _pendingProduceDataTimer = null;
    _lastMoveSeq = -1;

    _producer?.close();
    _dataProducer?.close();
    _dataConsumer?.close();
    _sendTransport?.close();
    _recvTransport?.close();
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
