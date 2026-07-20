// Real router.rtpCapabilities captured from a live 'get-router-caps' call
// against the actual orchestrator (2026-07-02). Reference/parity only — the
// client negotiates against the LIVE caps from the 'router-rtp-capabilities'
// message, not this snapshot.
//
// STALE re: codecs (2026-07-17): the router config now also advertises
// video/AV1 and video/VP9 (server/config.js codec preference chain
// AV1>H264>VP9>VP8). This captured snapshot predates them and still lists only
// VP8+H264; re-capture from a live get-router-caps if an exact snapshot is
// needed. Functionally harmless since this file isn't used for negotiation.
final Map<String, dynamic> routerRtpCapabilitiesJson = {
  'codecs': [
    {
      'kind': 'video',
      'mimeType': 'video/VP8',
      'clockRate': 90000,
      'rtcpFeedback': [
        {'type': 'nack', 'parameter': ''},
        {'type': 'nack', 'parameter': 'pli'},
        {'type': 'ccm', 'parameter': 'fir'},
        {'type': 'goog-remb', 'parameter': ''},
        {'type': 'transport-cc', 'parameter': ''},
      ],
      'parameters': {},
      'preferredPayloadType': 100,
    },
    {
      'kind': 'video',
      'mimeType': 'video/rtx',
      'preferredPayloadType': 101,
      'clockRate': 90000,
      'parameters': {'apt': 100},
      'rtcpFeedback': [],
    },
    {
      'kind': 'video',
      'mimeType': 'video/H264',
      'clockRate': 90000,
      'parameters': {
        'level-asymmetry-allowed': 1,
        'packetization-mode': 1,
        'profile-level-id': '42e01f',
      },
      'rtcpFeedback': [
        {'type': 'nack', 'parameter': ''},
        {'type': 'nack', 'parameter': 'pli'},
        {'type': 'ccm', 'parameter': 'fir'},
        {'type': 'goog-remb', 'parameter': ''},
        {'type': 'transport-cc', 'parameter': ''},
      ],
      'preferredPayloadType': 102,
    },
    {
      'kind': 'video',
      'mimeType': 'video/rtx',
      'preferredPayloadType': 103,
      'clockRate': 90000,
      'parameters': {'apt': 102},
      'rtcpFeedback': [],
    },
  ],
  'headerExtensions': [
    {
      'kind': 'audio',
      'uri': 'urn:ietf:params:rtp-hdrext:sdes:mid',
      'preferredId': 1,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'urn:ietf:params:rtp-hdrext:sdes:mid',
      'preferredId': 1,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id',
      'preferredId': 2,
      'preferredEncrypt': false,
      'direction': 'recvonly',
    },
    {
      'kind': 'video',
      'uri': 'urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id',
      'preferredId': 3,
      'preferredEncrypt': false,
      'direction': 'recvonly',
    },
    {
      'kind': 'audio',
      'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time',
      'preferredId': 4,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time',
      'preferredId': 4,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'audio',
      'uri':
          'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01',
      'preferredId': 5,
      'preferredEncrypt': false,
      'direction': 'recvonly',
    },
    {
      'kind': 'video',
      'uri':
          'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01',
      'preferredId': 5,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri':
          'https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension',
      'preferredId': 8,
      'preferredEncrypt': false,
      'direction': 'recvonly',
    },
    {
      'kind': 'audio',
      'uri': 'urn:ietf:params:rtp-hdrext:ssrc-audio-level',
      'preferredId': 10,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'urn:3gpp:video-orientation',
      'preferredId': 11,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'urn:ietf:params:rtp-hdrext:toffset',
      'preferredId': 12,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'audio',
      'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time',
      'preferredId': 13,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time',
      'preferredId': 13,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'audio',
      'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/playout-delay',
      'preferredId': 14,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
    {
      'kind': 'video',
      'uri': 'http://www.webrtc.org/experiments/rtp-hdrext/playout-delay',
      'preferredId': 14,
      'preferredEncrypt': false,
      'direction': 'sendrecv',
    },
  ],
};

// The real native producer's baseline (from a live devtools capture of its
// 'produce' message) - what our libwebrtc-negotiated H.264 params must match
// or be compatible with.
const String baselineProfileLevelId = '42e01f';
const int baselinePacketizationMode = 1;
const int baselineLevelAsymmetryAllowed = 1;
