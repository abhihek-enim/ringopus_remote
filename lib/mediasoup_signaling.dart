import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

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

// SCTP label distinguishing clipboard DataProducers/Consumers from the
// existing "remote-control" input channel — deliberately a SEPARATE
// DataProducer/DataConsumer pair, not multiplexed onto the input channel's
// JSON stream: consumeData()'s message handler below has no `type` switch
// and blind-forwards every payload to injectInput(), which would silently
// swallow a clipboard-shaped message as a no-op InputEvent rather than
// erroring (verified against input_inject.rs's InputEvent, which has no
// deny_unknown_fields).
const String kClipboardDataLabel = 'oojack-clipboard-v1';

// Reliable/ordered SCTP label for discrete input events (keydown/keyup/
// capslock/mousedown/mouseup) — separate from the existing unordered/lossy
// "remote-control" channel (mousemove/scroll). A modifier chord like Ctrl+C
// is 4 separate packets; on the lossy channel they could arrive reordered
// or get dropped with nothing downstream to buffer/correlate them before
// injecting into the OS, so the OS could see an unmodified letter with no
// real modifier held. This channel fixes that by construction.
const String kKeyboardDataLabel = 'oojack-keyboard-v1';

// Matches the plan's application-level cap — see decision docs. Enforced
// both sender-side (never send an oversized payload) and receiver-side
// (defense-in-depth against a modified peer).
const int kClipboardMaxPayloadBytes = 131072;

String _generateClipboardTransferId() {
  final rand = Random();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
      '${rand.nextInt(0xFFFFFF).toRadixString(16)}';
}

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
  // Reliable/ordered discrete-input channel — see kKeyboardDataLabel. A
  // fully separate DataConsumer from _dataConsumer above, but its message
  // handler forwards straight to injectInput() exactly the same way (Rust's
  // handle_event() is agnostic to which DataChannel a payload arrived on;
  // this channel's whole point is stronger delivery guarantees, not a
  // different consumer).
  DataConsumer? _keyboardDataConsumer;
  String sid = '';
  void Function(Map<String, dynamic> msg)? sendToComponent;

  void Function(Map<String, dynamic> payload)? onDataMessage;

  // Separate from _dataProducer/_dataConsumer above (see kClipboardDataLabel).
  // _clipboardDataProducer: lazily created the first time this customer
  // needs to SEND clipboard content (responding to a "Copy from Customer"
  // request) — closed and recreated fresh on every request within the same
  // session, not reused (see produceClipboardData()'s own doc comment for
  // why: reuse broke the server's per-request produce-data protocol).
  // _clipboardDataConsumer: (re)created per inbound "Paste to Customer".
  DataProducer? _clipboardDataProducer;
  DataConsumer? _clipboardDataConsumer;

  Function? _pendingClipboardProduceDataCb;
  Timer? _pendingClipboardProduceDataTimer;

  /// Fired once an inbound "Paste to Customer" payload has been applied (or
  /// failed to apply) to the local OS clipboard — drives a transient UI
  /// banner in producer_home_page.dart. Separate from the XMPP
  /// clipboard-applied/clipboard-apply-failed ack this class sends to the
  /// agent, which happens regardless of whether this callback is set.
  // appliedText: the content actually written to the OS clipboard on
  // success — used by producer_home_page.dart's clipboard watcher (Part 3)
  // to update its own change-detection baseline the moment inbound synced
  // content lands, so it doesn't mistake that write for a new LOCAL change
  // and loop it straight back to the agent.
  void Function({required bool success, String? reason, String? appliedText})? onClipboardPasteResult;

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

    // No existing listener for this today — the dead _pendingProduceDataCb/
    // resolveProduceData() scaffolding above was never wired to a
    // 'producedata' handler, so produceData() would have thrown ("no
    // producedata listener set") had anything ever called it. Clipboard is
    // the first real caller; this listener is specifically for the
    // clipboard producer (see produceClipboardData() below).
    transport.on('producedata', (data) {
      // ignore: avoid_print
      print('[MediasoupSignaling] producedata event fired (clipboard)');
      final callback = data['callback'] as Function;
      final errback = data['errback'] as Function;
      _pendingClipboardProduceDataCb = callback;
      _pendingClipboardProduceDataTimer = Timer(produceTimeout, () {
        _pendingClipboardProduceDataCb = null;
        _pendingClipboardProduceDataTimer = null;
        errback(StateError('clipboard-produce-data: server ack timeout'));
      });
      final sctp = data['sctpStreamParameters'] as SctpStreamParameters;
      sendToComponent?.call({
        'type': 'clipboard-produce-data',
        'sid': sid,
        'sctpStreamParameters': sctp.toMap(),
        'label': data['label'],
        'protocol': data['protocol'],
        'contentType': 'text/plain',
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

    transport.produce(
      track: track,
      stream: stream,
      source: 'screen',
      codec: codec,
      // Per-call callback (see Transport.produce()'s doc comment) - not a
      // shared Transport.producerCallback field. No live bug here today
      // (only caller), converted for consistency with the data-channel
      // call sites now that the mechanism exists.
      callback: (producer) {
        _producer = producer as Producer;
        _applySenderTuning(_producer!);
        _startSenderStatsPoller(_producer!);
        onProducer?.call(_producer!);
      },
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

    // No SctpStreamParameters.fromMap in the vendored library - built
    // manually. Real captured shape (see the earlier devtools capture) is
    // just {"streamId": 0, "ordered": false}.
    final sctpJson = params['sctpStreamParameters'] as Map<String, dynamic>;
    final completer = Completer<void>();
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
      // Per-call callback (see Transport.consumeData()'s doc comment) - not
      // a shared Transport.dataConsumerCallback field, so this call's own
      // consumer can't be clobbered by a concurrent consumeKeyboardData()/
      // consumeClipboardData() call on the same recv transport.
      // dataConsumerCallback?.call(dataConsumer, accept) - transport.dart
      // invokes it with 2 args (same MediaSFU-specific `accept` addition as
      // consume()'s callback above); this crashed live with NoSuchMethodError
      // until the second param was added.
      callback: (dataConsumer, [accept]) {
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
        if (!completer.isCompleted) completer.complete();
      },
    );
    // Previously returned here without waiting for this call's own consumer
    // to actually exist - the gap that made the shared-callback-field race
    // (now closed by the per-call `callback:` above) practically reachable.
    // Bounded so a genuinely stuck consumer fails loudly instead of hanging
    // this call (and rebindDataConsumer()'s await of it) forever.
    await completer.future.timeout(
      produceTimeout,
      onTimeout: () => throw StateError(
        'consume-data: local ack timeout (dataConsumer never created)',
      ),
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

  /// Reliable/ordered discrete-input consumer — see kKeyboardDataLabel.
  /// Message handler forwards straight to injectInput(), same as
  /// consumeData()'s (input) above, minus the mousemove-seq logic (this
  /// channel never carries mousemove, so there's nothing to discard).
  Future<void> consumeKeyboardData(Map<String, dynamic> params) async {
    final transport = _recvTransport;
    if (transport == null) {
      throw StateError('[MediasoupSignaling] recv transport not created');
    }
    await transport.handlerReady;

    final completer = Completer<void>();
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
      label: (params['label'] as String?) ?? kKeyboardDataLabel,
      protocol: (params['protocol'] as String?) ?? '',
      // Per-call callback - see consumeData()'s (input) identical comment
      // above. This consumer's callback can no longer be clobbered by a
      // concurrent consumeData()/consumeClipboardData() call on this same
      // recv transport.
      callback: (dataConsumer, [accept]) {
        _keyboardDataConsumer = dataConsumer as DataConsumer;
        // ignore: avoid_print
        print('[MediasoupSignaling] keyboard dataConsumer created: ${_keyboardDataConsumer!.id}');
        _keyboardDataConsumer!.on('message', (event) {
          final message = (event as Map)['data'] as RTCDataChannelMessage;
          if (message.isBinary) return;
          injectInput(payloadJson: message.text).catchError((Object e) {
            // ignore: avoid_print
            print('[MediasoupSignaling] inject_input (keyboard channel) failed: $e');
          });
        });
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future.timeout(
      produceTimeout,
      onTimeout: () => throw StateError(
        'consume-data (keyboard): local ack timeout (dataConsumer never created)',
      ),
    );
  }

  /// Closes and replaces the keyboard consumer — same "different agent takes
  /// over" case rebindDataConsumer() handles for input, kept as a separate
  /// method since they're two independent DataConsumer objects.
  Future<void> rebindKeyboardDataConsumer(Map<String, dynamic> params) async {
    _keyboardDataConsumer?.close();
    _keyboardDataConsumer = null;
    await consumeKeyboardData(params);
  }

  /// "Copy from Customer": creates a fresh clipboard DataProducer on the
  /// send transport for THIS request. Deliberately NOT reused across
  /// requests — an earlier version reused an existing open producer as an
  /// optimization, which broke the protocol: the server only learns which
  /// agent is waiting, and only creates that agent's consumer, in response
  /// to receiving clipboard-produce-data (see clipboardHandlers.js's
  /// handleClipboardProduceData). Skipping that message on a "reuse" meant
  /// the server's pendingClipboardCopy was never fulfilled or cleared on any
  /// request after the first, silently hanging every subsequent copy until
  /// its own 10s timeout. A fresh DataProducer per request (closing the
  /// prior one first) is the actual fix — this is a human-paced, occasional
  /// action, not a hot path, so the extra signaling round trip costs nothing
  /// that matters.
  ///
  /// Does not return until the underlying RTCDataChannel has actually
  /// reached the "open" state, not just until the produce-data signaling
  /// round trip (transport.produceData()'s local SDP renegotiation +
  /// clipboard-produce-data/clipboard-data-producer-created ack) has
  /// completed. Those two are NOT the same thing: this is the first-ever
  /// data channel added to _sendTransport (previously video-only), so the
  /// SDP renegotiation that provisions it happens well after the transport's
  /// original connect — the RTCDataChannel object exists and the vendored
  /// mediasoup-client's own signaling considers the producer "created" the
  /// moment that renegotiation completes, but the channel can still take a
  /// little longer to actually finish opening at the WebRTC layer. Calling
  /// DataProducer.send() before that finishes doesn't throw (it's not
  /// guarded by a readyState check - see data_producer.dart) - it appears to
  /// succeed and the bytes are simply never delivered, which is exactly the
  /// "signaling completes, agent never receives anything" symptom this fixes.
  Future<void> produceClipboardData() async {
    _clipboardDataProducer?.close();
    _clipboardDataProducer = null;
    final transport = _sendTransport;
    if (transport == null) {
      throw StateError('[MediasoupSignaling] send transport not created');
    }
    await transport.handlerReady;

    final completer = Completer<void>();
    // ordered:true + a generous maxRetransmits is the closest this vendored
    // fork's produceData() can express to "fully reliable" - its public
    // signature requires a concrete int (transport.dart's `required int
    // maxRetransmits`), unlike the real mediasoup-client (JS/TS) used on the
    // agent side, where these fields are genuinely optional and omitting
    // them yields a true W3C-reliable channel. A capped, one-shot text
    // payload on an already-connected session should comfortably succeed
    // well within this retry budget.
    transport.produceData(
      ordered: true,
      maxRetransmits: 30,
      label: kClipboardDataLabel,
      // Per-call callback (see Transport.produceData()'s doc comment) - not
      // a shared Transport.dataProducerCallback field.
      callback: (dataProducer) {
        _clipboardDataProducer = dataProducer as DataProducer;
        // ignore: avoid_print
        print('[MediasoupSignaling] clipboard dataProducer created: ${_clipboardDataProducer!.id}, readyState=${_clipboardDataProducer!.readyState}');
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future.timeout(
      produceTimeout,
      onTimeout: () =>
          throw StateError('produce-data (clipboard): local ack timeout'),
    );
    await _waitForDataProducerOpen(_clipboardDataProducer!);
  }

  /// Resolves once [producer]'s underlying RTCDataChannel reports
  /// RTCDataChannelOpen — immediately if it's already reached that (the
  /// negotiation round trip sometimes finishes fast enough on its own),
  /// otherwise waits for its "open" event. See produceClipboardData()'s doc
  /// comment for why this distinction is load-bearing here specifically,
  /// unlike the input data channel (which has never needed this - it's
  /// created early, well before anything is sent on it).
  Future<void> _waitForDataProducerOpen(DataProducer producer) async {
    // ignore: avoid_print
    print('[MediasoupSignaling] clipboard dataProducer readyState at wait-entry: ${producer.readyState}');
    if (producer.readyState == RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    // ignore: avoid_print
    print('[MediasoupSignaling] clipboard dataProducer not yet open (readyState=${producer.readyState}) — waiting');
    // DIAGNOSTIC (see decision.md, repeat-clipboard-push bug): ask the NATIVE
    // layer what it thinks this channel's state is, independently of Dart's
    // own cached mirror. dataChannelGetBufferedAmount is the one method
    // channel that gates on the real native readyState (it errors unless the
    // channel is genuinely open), so it doubles as an oracle for "Dart's
    // mirror disagrees with reality". If this reports OPEN while readyState
    // is still null, the channel is fine and only the Dart-side state
    // notification was lost.
    unawaited(_probeNativeDataChannelState(producer.dataChannel));
    final completer = Completer<void>();
    // once(), not on() — self-removes after firing, so there's no listener
    // to leak and no risk of a manual off('open') clobbering some other
    // 'open' listener on this same emitter (off() here removes ALL
    // listeners for the event, not just this one — events2's API, not this
    // codebase's choice).
    producer.once('open', (dynamic _) {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future.timeout(
      produceTimeout,
      onTimeout: () => throw StateError(
        'clipboard data channel never reached open (readyState=${producer.readyState})',
      ),
    );
    // ignore: avoid_print
    print('[MediasoupSignaling] clipboard dataProducer now open');
  }

  /// Diagnostic only — see the call site in [_waitForDataProducerOpen].
  /// Never throws; purely logs whether the native side considers this channel
  /// open at a moment when the Dart side does not.
  Future<void> _probeNativeDataChannelState(RTCDataChannel channel) async {
    try {
      final amount = await channel.getBufferedAmount();
      // ignore: avoid_print
      print(
        '[MediasoupSignaling] NATIVE-PROBE: channel is OPEN natively '
        '(bufferedAmount=$amount) while Dart readyState reports '
        '${channel.state} — the Dart-side mirror is stale, the channel '
        'itself is fine',
      );
    } catch (e) {
      // ignore: avoid_print
      print(
        '[MediasoupSignaling] NATIVE-PROBE: native side ALSO reports not-open '
        '($e) — this is a real transport-level failure, not a lost '
        'state notification',
      );
    }
  }

  /// Sends `text` over this customer's already-open clipboard producer.
  /// Generates and returns the envelope's transferId (useful for logging) —
  /// the caller does not construct one itself. Caller must have already
  /// awaited produceClipboardData() and validated the payload against
  /// kClipboardMaxPayloadBytes; this only guards against a producer that
  /// isn't actually open, it does not re-validate size.
  String sendClipboardData(String text) {
    final transferId = _generateClipboardTransferId();
    final producer = _clipboardDataProducer;
    if (producer == null || producer.closed) {
      // ignore: avoid_print
      print('[MediasoupSignaling] sendClipboardData: no open clipboard producer, dropping');
      return transferId;
    }
    producer.send(jsonEncode({
      'type': 'clipboard-data',
      'version': 1,
      'transferId': transferId,
      'direction': 'customer-to-agent',
      'contentType': 'text/plain',
      'encoding': 'utf8',
      'payload': text,
      'size': utf8.encode(text).length,
      'sourceTimestamp': DateTime.now().millisecondsSinceEpoch,
    }));
    return transferId;
  }

  /// "Paste to Customer": starts consuming an inbound clipboard DataChannel.
  /// A fully separate DataConsumer from _dataConsumer (input) — see
  /// kClipboardDataLabel — with its own message handler that writes to the
  /// OS clipboard instead of injecting input, and sends the delivery ack
  /// (clipboard-applied/clipboard-apply-failed) back over XMPP itself rather
  /// than delegating that decision to producer_home_page.dart.
  Future<void> consumeClipboardData(Map<String, dynamic> params) async {
    final transport = _recvTransport;
    if (transport == null) {
      throw StateError('[MediasoupSignaling] recv transport not created');
    }
    await transport.handlerReady;

    _clipboardDataConsumer?.close();
    _clipboardDataConsumer = null;

    final completer = Completer<void>();
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
      label: (params['label'] as String?) ?? kClipboardDataLabel,
      protocol: (params['protocol'] as String?) ?? '',
      // Per-call callback (see consumeData()'s (input) identical comment) -
      // not a shared Transport.dataConsumerCallback field, so this consumer
      // can no longer be clobbered by a concurrent consumeData()/
      // consumeKeyboardData() call on this same recv transport. This was
      // the confirmed root cause of "Paste to Customer" failing with
      // "clipboard temporarily unavailable" - the callback below could be
      // silently stolen by an overlapping consume call, leaving the
      // completer below unresolved forever (previously with no timeout at
      // all - see the timeout added below).
      callback: (dataConsumer, [accept]) {
        _clipboardDataConsumer = dataConsumer as DataConsumer;
        // ignore: avoid_print
        print('[MediasoupSignaling] clipboard dataConsumer created: ${_clipboardDataConsumer!.id}');
        _clipboardDataConsumer!.on('message', (event) {
          final message = (event as Map)['data'] as RTCDataChannelMessage;
          unawaited(_handleClipboardMessage(message));
        });
        if (!completer.isCompleted) completer.complete();
      },
    );
    // Previously an unbounded `await completer.future;` - the one wait in
    // this file with no timeout. If the callback above were ever not
    // invoked (the race this per-call callback now prevents, or any other
    // future cause), this hung forever with zero error. Now bounded and
    // fails loudly, matching every other wait in this file.
    await completer.future.timeout(
      produceTimeout,
      onTimeout: () => throw StateError(
        'consume-data (clipboard): local ack timeout (dataConsumer never created)',
      ),
    );

    // consumeData()'s completer resolving confirms the DataConsumer object/
    // local negotiation, not that its RTCDataChannel has actually finished
    // opening — same reasoning as produceClipboardData()'s
    // _waitForDataProducerOpen. This is the receiving-side half of "Paste to
    // Customer"; sendClipboardData() (agent side) now waits for the
    // clipboard-consumer-ready ack this triggers below before sending, so
    // getting this right matters just as much as the producer-side fix.
    final consumer = _clipboardDataConsumer!;
    if (consumer.readyState != RTCDataChannelState.RTCDataChannelOpen) {
      // ignore: avoid_print
      print('[MediasoupSignaling] clipboard dataConsumer not yet open (readyState=${consumer.readyState}) — waiting');
      final openCompleter = Completer<void>();
      consumer.once('open', (dynamic _) {
        if (!openCompleter.isCompleted) openCompleter.complete();
      });
      await openCompleter.future.timeout(
        produceTimeout,
        onTimeout: () => throw StateError(
          'clipboard consumer never reached open (readyState=${consumer.readyState})',
        ),
      );
      // ignore: avoid_print
      print('[MediasoupSignaling] clipboard dataConsumer now open');
    }
  }

  Future<void> _handleClipboardMessage(RTCDataChannelMessage message) async {
    if (message.isBinary) return; // clipboard channel is text-only, matches the input channel's convention

    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(message.text) as Map<String, dynamic>;
    } catch (_) {
      await _sendClipboardApplyFailed(null, 'malformed');
      return;
    }

    final transferId = envelope['transferId'] as String?;
    final contentType = envelope['contentType'] as String?;
    final payload = envelope['payload'] as String?;

    if (contentType != 'text/plain' || payload == null) {
      await _sendClipboardApplyFailed(transferId, 'unsupported-content-type');
      return;
    }
    if (utf8.encode(payload).length > kClipboardMaxPayloadBytes) {
      await _sendClipboardApplyFailed(transferId, 'oversized-payload');
      return;
    }

    try {
      // Flutter's own cross-platform clipboard API (already used elsewhere
      // in this app for the connect-code copy button) — no native Rust
      // needed for plain text get/set.
      await Clipboard.setData(ClipboardData(text: payload));
    } catch (e) {
      // ignore: avoid_print
      print('[MediasoupSignaling] Clipboard.setData failed: $e');
      await _sendClipboardApplyFailed(transferId, 'write-failed');
      return;
    }

    sendToComponent?.call({
      'type': 'clipboard-applied',
      'sid': sid,
      'transferId': transferId,
      'contentType': contentType,
      'size': utf8.encode(payload).length,
    });
    onClipboardPasteResult?.call(success: true, appliedText: payload);
    // ignore: avoid_print
    print('[MediasoupSignaling] clipboard paste applied (transferId=$transferId)');
  }

  Future<void> _sendClipboardApplyFailed(String? transferId, String reason) async {
    sendToComponent?.call({
      'type': 'clipboard-apply-failed',
      'sid': sid,
      if (transferId != null) 'transferId': transferId,
      'reason': reason,
    });
    onClipboardPasteResult?.call(success: false, reason: reason);
    // ignore: avoid_print
    print('[MediasoupSignaling] clipboard paste failed: $reason (transferId=$transferId)');
  }

  void resolveClipboardProduceData(String dataProducerId) {
    _pendingClipboardProduceDataTimer?.cancel();
    _pendingClipboardProduceDataTimer = null;
    final cb = _pendingClipboardProduceDataCb;
    if (cb != null) {
      cb(dataProducerId);
      _pendingClipboardProduceDataCb = null;
    }
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
    _pendingClipboardProduceDataTimer?.cancel();
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
    _pendingClipboardProduceDataCb = null;
    _pendingClipboardProduceDataTimer = null;
    _lastMoveSeq = -1;

    // Producer/DataProducer/DataConsumer.close() are synchronous (void);
    // only Transport.close() (and Consumer.close(), not held here) actually
    // return Future<void> - awaiting those two is what makes cleanup()
    // actually wait for the underlying RTCPeerConnection/handler teardown
    // instead of firing-and-forgetting it.
    _producer?.close();
    _dataProducer?.close();
    _dataConsumer?.close();
    _clipboardDataProducer?.close();
    _clipboardDataConsumer?.close();
    _keyboardDataConsumer?.close();
    await _sendTransport?.close();
    await _recvTransport?.close();
    _producer = null;
    _dataProducer = null;
    _dataConsumer = null;
    _clipboardDataProducer = null;
    _clipboardDataConsumer = null;
    _keyboardDataConsumer = null;
    _sendTransport = null;
    _recvTransport = null;
    sid = '';
    // ignore: avoid_print
    print('[MediasoupSignaling] cleaned up');
  }
}
