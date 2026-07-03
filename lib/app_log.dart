import 'package:flutter/foundation.dart';

/// Global sink for every print() call in the app - our own log lines,
/// whixp's internal stanza traces, the vendored mediasoup lib's error
/// logs, all of it. Wired up in main.dart via a Zone print override, so a
/// packaged .app (no attached terminal, e.g. a double-clicked DMG install)
/// can still show real diagnostic output on screen instead of it vanishing
/// into stdout no one can see.
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int maxLines = 4000;
  final List<String> lines = [];

  void add(String line) {
    lines.add(line);
    if (lines.length > maxLines) {
      lines.removeRange(0, lines.length - maxLines);
    }
    notifyListeners();
  }
}
