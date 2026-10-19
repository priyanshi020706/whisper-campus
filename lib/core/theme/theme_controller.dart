import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController extends ChangeNotifier {
  static const _preferenceKey = 'whisper_campus_theme_mode';

  ThemeMode _themeMode = ThemeMode.light;

  ThemeMode get themeMode => _themeMode;

  Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _themeMode = preferences.getString(_preferenceKey) == 'dark'
          ? ThemeMode.dark
          : ThemeMode.light;
      notifyListeners();
    } catch (_) {
      // Keep the light theme if local preference storage is unavailable.
    }
  }

  Future<void> toggle() async {
    _themeMode = _themeMode == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    notifyListeners();

    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _preferenceKey,
        _themeMode == ThemeMode.dark ? 'dark' : 'light',
      );
    } catch (_) {
      // The current selection still applies for this app session.
    }
  }
}

class AppThemeScope extends InheritedNotifier<ThemeController> {
  const AppThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppThemeScope>();
    assert(scope != null, 'AppThemeScope is missing above this context.');
    return scope!.notifier!;
  }
}
