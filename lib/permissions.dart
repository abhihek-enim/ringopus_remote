import 'package:flutter/services.dart';

/// Thin Dart side of macos/Runner/PermissionsPlugin.swift - the two macOS
/// system permissions a remote-control session needs (Accessibility for input
/// injection, Screen Recording for capture). Every call is a safe no-op
/// (returns "granted"/false as noted) on platforms without the plugin, so
/// callers need no platform checks of their own beyond what the UI wants.
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

  /// Current status: `{'accessibility': bool, 'screenCapture': bool}`.
  /// Empty map where the plugin does not exist (non-macOS).
  static Future<Map<String, bool>> checkBoth() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, bool>('checkSessionPermissions');
      return result ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Raises the Accessibility system alert if not yet trusted. Returns
  /// whether the app is trusted right now.
  static Future<bool> requestAccessibility() => _invokeBool('requestAccessibility');

  /// Asks for Screen Recording (may add the app to Settings switched off
  /// rather than show a prompt, on recent macOS). Returns whether access is
  /// granted right now.
  static Future<bool> requestScreenRecording() => _invokeBool('requestScreenCapture');

  static Future<void> openScreenRecordingSettings() => _openSettings('screen');

  static Future<void> openAccessibilitySettings() => _openSettings('accessibility');

  /// Quits and reopens the app, so a newly granted Screen Recording
  /// permission takes effect.
  static Future<void> relaunch() async {
    try {
      await _channel.invokeMethod('relaunch');
    } on MissingPluginException {
      // nothing to do off macOS
    }
  }

  static Future<bool> _invokeBool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> _openSettings(String pane) async {
    try {
      await _channel.invokeMethod('openPrivacySettings', {'pane': pane});
    } on MissingPluginException {
      // nothing to do off macOS
    }
  }
}
