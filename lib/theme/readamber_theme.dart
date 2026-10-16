import 'package:flutter/material.dart';

/// Keeps reading and form content comfortable on wide desktop windows while
/// allowing phones to use their full available width.
class ReadAmberContent extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ReadAmberContent({super.key, required this.child, this.maxWidth = 960});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}

/// Shared brand and semantic colors. Amber text uses a darker shade on paper;
/// the bright accent is reserved for decoration or backgrounds with ink text.
abstract final class ReadAmberColors {
  static const ink = Color(0xFF172D32);
  static const inkSoft = Color(0xFF35565B);
  static const amber = Color(0xFFE8AA50);
  static const amberText = Color(0xFF84500D);
  static const paper = Color(0xFFFFF3DC);
  static const canvas = Color(0xFFF7F4EC);
  static const surface = Color(0xFFFFFDF7);
  static const surfaceMuted = Color(0xFFF0EADB);
  static const outline = Color(0xFFDCD3C2);
  static const muted = Color(0xFF626B64);
  static const success = Color(0xFF38654F);
  static const error = Color(0xFFA33F32);
  static const logSuccess = Color(0xFFA8D5B8);
  static const logError = Color(0xFFFFB4A8);
}

abstract final class ReadAmberTheme {
  static ThemeData get light {
    const rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: ReadAmberColors.ink,
      brightness: Brightness.light,
      primary: ReadAmberColors.ink,
      onPrimary: ReadAmberColors.paper,
      primaryContainer: ReadAmberColors.paper,
      onPrimaryContainer: ReadAmberColors.ink,
      secondary: ReadAmberColors.amberText,
      onSecondary: ReadAmberColors.surface,
      secondaryContainer: ReadAmberColors.paper,
      onSecondaryContainer: ReadAmberColors.ink,
      tertiary: ReadAmberColors.success,
      surface: ReadAmberColors.surface,
      onSurface: ReadAmberColors.ink,
      onSurfaceVariant: ReadAmberColors.muted,
      surfaceContainerHighest: ReadAmberColors.surfaceMuted,
      outline: ReadAmberColors.muted,
      outlineVariant: ReadAmberColors.outline,
      error: ReadAmberColors.error,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: ReadAmberColors.canvas,
      dividerColor: ReadAmberColors.outline,
      appBarTheme: const AppBarTheme(
        backgroundColor: ReadAmberColors.canvas,
        foregroundColor: ReadAmberColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: ReadAmberColors.ink,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: ReadAmberColors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: ReadAmberColors.amber,
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: const WidgetStatePropertyAll(
          IconThemeData(color: ReadAmberColors.ink, size: 23),
        ),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(
              color: ReadAmberColors.ink,
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
      ),
      cardTheme: const CardThemeData(
        color: ReadAmberColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: ReadAmberColors.outline, width: 0.7),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        backgroundColor: ReadAmberColors.ink,
        foregroundColor: ReadAmberColors.paper,
        shape: rounded,
        minimumSize: const Size(48, 44),
      )),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
        backgroundColor: ReadAmberColors.ink,
        foregroundColor: ReadAmberColors.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded,
        minimumSize: const Size(48, 44),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        foregroundColor: ReadAmberColors.ink,
        side: const BorderSide(color: ReadAmberColors.outline),
        shape: rounded,
        minimumSize: const Size(48, 44),
      )),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: ReadAmberColors.surfaceMuted,
        hintStyle: TextStyle(color: ReadAmberColors.muted),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12))),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: ReadAmberColors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: ReadAmberColors.inkSoft, width: 1.5),
        ),
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: ReadAmberColors.surfaceMuted,
        selectedColor: ReadAmberColors.paper,
        side: BorderSide(color: ReadAmberColors.outline),
        labelStyle: TextStyle(color: ReadAmberColors.ink),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: ReadAmberColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: ReadAmberColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: rounded,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ReadAmberColors.ink,
        contentTextStyle: TextStyle(color: ReadAmberColors.paper),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ReadAmberColors.inkSoft,
        linearTrackColor: ReadAmberColors.surfaceMuted,
      ),
    );
  }
}
