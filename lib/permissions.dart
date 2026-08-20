import 'package:flutter/services.dart';

/// Dart-side handle for [PermissionsPlugin.swift] - requests the macOS
/// Accessibility (input injection) and Screen Recording permissions
/// together, up front, instead of letting each one get triggered lazily
/// and separately mid-session (getDisplayMedia triggers Screen Recording;
/// the first enigo event triggers Accessibility).
///
/// Safe to call on every session start: once a permission is granted (or
/// denied), the underlying macOS calls are no-ops with no dialog shown.
class SessionPermissions {
  static const _channel = MethodChannel('com.oojack.app/permissions');

  static Future<void> requestBoth() async {
    try {
      await _channel.invokeMethod('requestSessionPermissions');
    } on MissingPluginException {
      // Non-macOS platform, or the native plugin isn't registered
      // (shouldn't happen on macOS after MainFlutterWindow wires it up) -
      // fall through and let the old lazy per-subsystem prompts happen.
    }
  }

  /// Best-effort status check - not required for requestBoth() to work,
  /// but useful if the UI ever wants to show "permissions needed" state
  /// before the user hits start.
  static Future<Map<String, bool>> checkBoth() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, bool>('checkSessionPermissions');
      return result ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }
}
