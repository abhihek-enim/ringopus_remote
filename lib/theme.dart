import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens shared with the Tauri viewer's dark navy/broadcast
/// aesthetic, so the two apps read as one product. Reference these
/// constants directly wherever a custom-painted widget (status bar, preview
/// frame, log panel) needs exact control beyond what ThemeData's component
/// themes cover.
class AppColors {
  AppColors._();

  static const background = Color(0xFF0B0F14);
  static const surface = Color(0xFF131820);
  static const hairline = Color(0xFF232B36);
  static const textPrimary = Color(0xFFE8EDF2);
  static const textSecondary = Color(0xFF7C8896);

  /// Connect button, focus states, [xmpp] log lines.
  static const accent = Color(0xFF5B8DEF);

  /// Reserved strictly for connection-live/status-good indicators - do not
  /// reuse for action buttons, to keep "do this" and "this is currently
  /// true" visually distinct.
  static const live = Color(0xFF34D399);

  /// Stop Sharing, disconnect, errors.
  static const danger = Color(0xFFEF4444);

  /// [mediasoup]/[transport] log line prefixes - distinct from both the
  /// xmpp accent and the reserved live-green.
  static const logSubsystem = Color(0xFFD4A85A);
}

const double kCornerRadius = 8;

ThemeData buildAppTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
    surface: AppColors.surface,
    primary: AppColors.accent,
    error: AppColors.danger,
    onSurface: AppColors.textPrimary,
  );

  final textTheme = GoogleFonts.interTextTheme(base.textTheme).apply(
    bodyColor: AppColors.textPrimary,
    displayColor: AppColors.textPrimary,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: colorScheme,
    textTheme: textTheme,
    dividerColor: AppColors.hairline,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        side: const BorderSide(color: AppColors.hairline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.background,
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCornerRadius)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCornerRadius)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kCornerRadius)),
      ),
    ),
  );
}

/// Monospace style for machine-real data: JIDs, session/producer ids, and
/// the technical log - visually distinct from regular Inter UI chrome.
TextStyle appMonoStyle({
  double fontSize = 12,
  Color color = AppColors.textPrimary,
  FontWeight? fontWeight,
}) {
  return GoogleFonts.jetBrainsMono(fontSize: fontSize, color: color, fontWeight: fontWeight);
}
