import 'dart:convert';
import 'package:http/http.dart' as http;

// Talks to the throwaway phase2_bridge (scratchpad, not part of this repo)
// which relays these calls over real XMPP to the real mediasoup server.
// Phase 3 replaces this whole file with real XMPP signaling in-app.
class BridgeClient {
  BridgeClient({this.baseUrl = 'http://127.0.0.1:4000'});

  final String baseUrl;

  Future<Map<String, dynamic>> getTransportParams() async {
    final res = await http.get(Uri.parse('$baseUrl/transport-params'));
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> connectTransport(
    Map<String, dynamic> dtlsParameters,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/connect-transport'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'dtlsParameters': dtlsParameters}),
    );
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> produce(
    String kind,
    Map<String, dynamic> rtpParameters,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/produce'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'kind': kind, 'rtpParameters': rtpParameters}),
    );
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> producerReady(String producerId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/producer-ready'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'producerId': producerId}),
    );
    _checkOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> reset() async {
    final res = await http.post(Uri.parse('$baseUrl/reset'));
    _checkOk(res);
  }

  void _checkOk(http.Response res) {
    if (res.statusCode != 200) {
      throw Exception('bridge call failed [${res.statusCode}]: ${res.body}');
    }
  }
}
