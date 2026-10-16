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

/// Semantic surface and foreground pairs for both appearances.
class ReadAmberPalette {
  final Color ink;
  final Color inkSoft;
  final Color amber;
  final Color amberText;
  final Color paper;
  final Color canvas;
  final Color surface;
  final Color surfaceMuted;
  final Color outline;
  final Color muted;
  final Color success;
  final Color error;
  final Color action;
  final Color onAction;
  const ReadAmberPalette._(
      {required this.ink,
      required this.inkSoft,
      required this.amber,
      required this.amberText,
      required this.paper,
      required this.canvas,
      required this.surface,
      required this.surfaceMuted,
      required this.outline,
      required this.muted,
      required this.success,
      required this.error,
      required this.action,
      required this.onAction});
  static const light = ReadAmberPalette._(
    ink: Color(0xFF172D32),
    inkSoft: Color(0xFF35565B),
    amber: Color(0xFFE8AA50),
    amberText: Color(0xFF84500D),
    paper: Color(0xFFFFF3DC),
    canvas: Color(0xFFF7F4EC),
    surface: Color(0xFFFFFDF7),
    surfaceMuted: Color(0xFFF0EADB),
    outline: Color(0xFFDCD3C2),
    muted: Color(0xFF626B64),
    success: Color(0xFF38654F),
    error: Color(0xFFA33F32),
    action: Color(0xFF172D32),
    onAction: Color(0xFFFFF3DC),
  );
  static const dark = ReadAmberPalette._(
    ink: Color(0xFFFFF3DC),
    inkSoft: Color(0xFFD5E3DD),
    amber: Color(0xFFE8AA50),
    amberText: Color(0xFFE8AA50),
    paper: Color(0xFF30454A),
    canvas: Color(0xFF101F23),
    surface: Color(0xFF172D32),
    surfaceMuted: Color(0xFF223A40),
    outline: Color(0xFF405B61),
    muted: Color(0xFFB0C4BC),
    success: Color(0xFFA8D5B8),
    error: Color(0xFFFFB4A8),
    action: Color(0xFFE8AA50),
    onAction: Color(0xFF172D32),
  );
  static ReadAmberPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
  static ReadAmberPalette of(BuildContext context) =>
      forBrightness(Theme.of(context).brightness);
}

abstract final class ReadAmberTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colors = ReadAmberPalette.forBrightness(brightness);
    const rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: ReadAmberColors.ink,
      brightness: brightness,
      primary: colors.action,
      onPrimary: colors.onAction,
      primaryContainer: colors.paper,
      onPrimaryContainer: colors.ink,
      secondary: colors.amberText,
      onSecondary: colors.surface,
      secondaryContainer: colors.paper,
      onSecondaryContainer: colors.ink,
      tertiary: colors.success,
      surface: colors.surface,
      onSurface: colors.ink,
      onSurfaceVariant: colors.muted,
      surfaceContainerHighest: colors.surfaceMuted,
      outline: colors.muted,
      outlineVariant: colors.outline,
      error: colors.error,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.canvas,
      dividerColor: colors.outline,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.canvas,
        foregroundColor: colors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: colors.ink,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.amber,
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? ReadAmberColors.ink
                : colors.ink,
            size: 23)),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
              color: colors.ink, fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: colors.outline, width: 0.7),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
        backgroundColor: colors.action,
        foregroundColor: colors.onAction,
        shape: rounded,
        minimumSize: const Size(48, 44),
      )),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
        backgroundColor: colors.action,
        foregroundColor: colors.onAction,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: rounded,
        minimumSize: const Size(48, 44),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
        foregroundColor: colors.ink,
        side: BorderSide(color: colors.outline),
        shape: rounded,
        minimumSize: const Size(48, 44),
      )),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceMuted,
        hintStyle: TextStyle(color: colors.muted),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12))),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colors.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: colors.inkSoft, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surfaceMuted,
        selectedColor: colors.paper,
        side: BorderSide(color: colors.outline),
        labelStyle: TextStyle(color: colors.ink),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: rounded,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ReadAmberColors.ink,
        contentTextStyle: TextStyle(color: ReadAmberColors.paper),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.inkSoft,
        linearTrackColor: colors.surfaceMuted,
      ),
    );
  }
}
