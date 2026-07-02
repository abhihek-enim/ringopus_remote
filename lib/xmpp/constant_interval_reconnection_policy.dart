import 'dart:async';

import 'package:whixp/whixp.dart';

/// whixp's own example/default is [RandomBackoffReconnectionPolicy], but
/// this project deliberately uses a constant 3-second retry for
/// XMPP-adjacent reconnection elsewhere (exponential backoff was explicitly
/// rejected). This matches that policy rather than whixp's default.
class ConstantIntervalReconnectionPolicy extends ReconnectionPolicy {
  ConstantIntervalReconnectionPolicy([
    this.interval = const Duration(seconds: 3),
  ]);

  final Duration interval;
  Timer? _timer;

  @override
  Future<void> onFailure() async {
    _timer?.cancel();
    _timer = Timer(interval, () async {
      if (!(await getShouldReconnect())) return;
      try {
        await performReconnect!();
      } catch (_) {
        await onFailure();
      }
    });
  }

  @override
  Future<void> onSuccess() async {
    await reset();
  }

  @override
  Future<void> reset() async {
    _timer?.cancel();
    _timer = null;
    await super.reset();
  }
}
