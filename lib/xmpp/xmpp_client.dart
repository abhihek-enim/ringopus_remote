import 'dart:convert';

import 'package:whixp/whixp.dart';

import 'constant_interval_reconnection_policy.dart';

// Routing/JID domain string - ejabberd's own hosts: config defines this as
// a served vhost regardless of which network interface accepts the
// connection, so it does NOT need to be a reachable address and must not
// be changed just because the connection target below changes.
const String componentJid = 'orchestrator.192.168.56.101';

// The orchestrator VM's bridged-adapter (enp0s9) IP is DHCP-assigned, not
// static, so it changes on lease renewal - this has already broken
// connectivity twice (.162 -> .8, then .8 -> .7). Update here when it
// changes again, and update MS_ANNOUNCE_IP in the server's config.js to
// match, or media/ICE will be wrong even if signaling connects fine.
// The real fix is a static IP or a DHCP reservation (MAC 08:00:27:76:5b:02)
// on the router for that adapter, so this stops moving entirely.
const String ejabberdWsHost = '192.168.1.7';

/// Dart port of the reference app's tempClient.ts, matched 1:1 against
/// whixp 3.3.1's actual API (checked, not assumed). Presence
/// subscribe/subscribed auto-accept and the constant-3s reconnection policy
/// are load-bearing, not incidental - see the doc comments on each.
class XmppClient {
  XmppClient(String jid, String password)
    : _whixp = Whixp(
        jabberID: jid,
        password: password,
        // Actual TCP/WebSocket connection target - see ejabberdWsHost above.
        host: ejabberdWsHost,
        port: 5280,
        useWebSocket: true,
        wsPath: '/ws',
        reconnectionPolicy: ConstantIntervalReconnectionPolicy(),
      ) {
    _registerEvents();
  }

  final Whixp _whixp;

  void Function(String jid)? onConnected;
  void Function()? onAuthFailed;
  void Function(Map<String, dynamic> msg)? onComponentMessage;

  void _registerEvents() {
    _whixp.addEventHandler('streamNegotiated', (_) {
      // ignore: avoid_print
      print('[XMPP] session started');
      _whixp.sendPresence();
      onConnected?.call(_whixp.transport.boundJID?.bare ?? '');
    });

    _whixp.addEventHandler<TransportState>('state', (state) {
      // ignore: avoid_print
      print('[XMPP] state: $state');
    });

    // Real event name/type confirmed from whixp's SASL feature source
    // (plugins/mechanisms/feature.dart's _processFailure): it emits
    // 'failedAuthentication' with a String reason, not the 'authFailed'
    // event name tempClient.ts's underlying library (stanza, a different
    // package) used.
    _whixp.addEventHandler<String>('failedAuthentication', (reason) {
      // ignore: avoid_print
      print('[XMPP] auth failed: $reason');
      onAuthFailed?.call();
    });

    // The orchestrator sends <presence type="subscribe"> once it sees us
    // online; replying <presence type="subscribed"> is how ejabberd knows to
    // route our unavailable presence (clean logout, crash, network drop) to
    // the component. Without this the server never notices an abrupt
    // disconnect - see the project's Generation 3 presence design.
    _whixp.addEventHandler<Presence>('presence_subscribe', (presence) {
      final from = presence?.from;
      if (from != null && from.bare.startsWith(componentJid)) {
        _whixp.sendPresence(type: 'subscribed', to: from);
        // ignore: avoid_print
        print('[XMPP] subscribed component to our presence');
      }
    });

    _whixp.addEventHandler<Presence>('presence', (presence) {
      // ignore: avoid_print
      print(
        '[XMPP] presence: ${presence?.from?.bare} ${presence?.type ?? 'available'}',
      );
    });

    _whixp.addEventHandler<Message>('message', (message) {
      final from = message?.from?.bare ?? '';
      final body = message?.body;
      if (from.startsWith(componentJid) && body != null) {
        try {
          final parsed = jsonDecode(body) as Map<String, dynamic>;
          // ignore: avoid_print
          print('[XMPP] <- component: ${parsed['type']}');
          onComponentMessage?.call(parsed);
        } catch (_) {
          // ignore: avoid_print
          print('[XMPP] failed to parse component message body');
        }
        return;
      }
      // ignore: avoid_print
      print('[XMPP] message from $from');
    });
  }

  void sendToComponent(Map<String, dynamic> payload) {
    _whixp.sendMessage(
      JabberID(componentJid),
      body: jsonEncode(payload),
      type: MessageType.chat,
    );
    // ignore: avoid_print
    print('[XMPP] -> component: ${payload['type']}');
  }

  void connect() => _whixp.connect();

  void disconnect() => _whixp.disconnect();

  String get jid => _whixp.transport.boundJID?.bare ?? '';
}
