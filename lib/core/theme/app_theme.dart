import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const lavender = Color(0xFF7054C5);
  static const berry = Color(0xFFAA4F83);
  static const teal = Color(0xFF187B75);

  static final light = ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: lavender,
          brightness: Brightness.light,
        ).copyWith(
          primary: lavender,
          secondary: berry,
          tertiary: teal,
          surface: const Color(0xFFFFFCFE),
        ),
    scaffoldBackgroundColor: const Color(0xFFF7F3FA),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 26,
        height: 1.16,
        letterSpacing: -0.45,
      ),
      titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 15, height: 1.4),
      bodyMedium: TextStyle(fontSize: 14, height: 1.4),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF7F3FA),
      foregroundColor: Color(0xFF211C2B),
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: Color(0xFF211C2B),
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFFFFFCFE),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xFFE8E0EC)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF1ECF6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE5DEEC)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: lavender, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
  );

  static final dark = ThemeData(
    useMaterial3: true,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF9B82FF),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFFB6A3FF),
          secondary: const Color(0xFF62DFD0),
          tertiary: const Color(0xFFFFB66F),
          surface: const Color(0xFF151621),
        ),
    scaffoldBackgroundColor: const Color(0xFF0D0F17),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 26,
        height: 1.16,
        letterSpacing: -0.45,
      ),
      titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 15, height: 1.4),
      bodyMedium: TextStyle(fontSize: 14, height: 1.4),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0D0F17),
      foregroundColor: Color(0xFFF2F0FF),
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: Color(0xFFF2F0FF),
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF171A27),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xFF30374B)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF191D2B),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF35394F)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF9B82FF), width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
  );
}
