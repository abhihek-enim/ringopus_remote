import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';
import 'producer_home_page.dart';
import 'src/rust/frb_generated.dart';
import 'theme.dart';

void main() {
  // Every print() call anywhere in the app - ours, whixp's internal stanza
  // traces, the vendored mediasoup lib's error logs - gets captured into
  // AppLog so a packaged .app with no attached terminal can still show real
  // diagnostic output on screen. parent.print still runs too, so `flutter
  // run`/Terminal output is unchanged.
  runZonedGuarded(
    () async {
      // window_manager needs the binding + its own (lightweight, reliable -
      // unlike the Rust bridge below) native init before anything can call
      // windowManager.minimize() later. Safe to await ahead of runApp(),
      // unlike RustLib.init() - see the comment on that below.
      WidgetsFlutterBinding.ensureInitialized();
      await windowManager.ensureInitialized();
      // Render the UI first, then bring up the Rust bridge. Gating runApp on
      // RustLib.init() means any init failure leaves a blank window with the
      // error buried in AppLog (which never renders) - render first so the log
      // panel is visible and the app is usable even if native init fails.
      runApp(const RingopusProducerApp());
      try {
        await RustLib.init();
        // ignore: avoid_print
        print('[rust] bridge initialized');
      } catch (e, s) {
        // ignore: avoid_print
        print('[rust] RustLib.init FAILED: $e\n$s');
      }
    },
    (error, stack) => AppLog.instance.add('UNCAUGHT EXCEPTION: $error\n$stack'),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        AppLog.instance.add(line);
        parent.print(zone, line);
      },
    ),
  );
}

class RingopusProducerApp extends StatelessWidget {
  const RingopusProducerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oojack Remote',
      theme: buildAppTheme(),
      home: const ProducerHomePage(),
    );
  }
}
