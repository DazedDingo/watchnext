import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-selectable accent colors for the app theme. The seed drives a full
/// Material 3 ColorScheme via `ColorScheme.fromSeed`, so picking an accent
/// recolors buttons, chips, tabs, and the "Next" shimmer in one shot.
enum AppAccent {
  red('Streaming red', Color(0xFFE50914)),
  coral('Coral', Color(0xFFFF6E5A)),
  orange('Neon orange', Color(0xFFFF7A00)),
  amber('Amber', Color(0xFFFFC107)),
  yellow('Sunlit yellow', Color(0xFFFFEB3B)),
  lime('Lime', Color(0xFFCDDC39)),
  green('Neon green', Color(0xFF00E676)),
  forest('Forest', Color(0xFF2E7D32)),
  teal('Teal', Color(0xFF26A69A)),
  cyan('Cyan', Color(0xFF00BCD4)),
  sky('Sky', Color(0xFF4FC3F7)),
  blue('Electric blue', Color(0xFF2979FF)),
  indigo('Indigo', Color(0xFF3F51B5)),
  violet('Violet', Color(0xFF8E24AA)),
  magenta('Magenta', Color(0xFFE91E63)),
  pink('Bubblegum pink', Color(0xFFFF80AB)),
  rose('Dusty rose', Color(0xFFD98299)),
  slate('Slate', Color(0xFF78909C));

  final String label;
  final Color seed;
  const AppAccent(this.label, this.seed);

  static AppAccent fromName(String? name) {
    for (final a in AppAccent.values) {
      if (a.name == name) return a;
    }
    return AppAccent.red;
  }
}

const _kAccentKey = 'wn_accent';

class AccentController extends StateNotifier<AppAccent> {
  final SharedPreferences _prefs;

  AccentController(this._prefs)
      : super(AppAccent.fromName(_prefs.getString(_kAccentKey)));

  Future<void> set(AppAccent accent) async {
    state = accent;
    await _prefs.setString(_kAccentKey, accent.name);
  }
}

final accentProvider =
    StateNotifierProvider<AccentController, AppAccent>((ref) {
  throw UnimplementedError('accentProvider not initialised');
});

/// Derived theme that rebuilds when the accent changes. All screens receive
/// this via the MaterialApp.theme so swapping the accent recolors the whole
/// app instantly without restart.
final themeDataProvider = Provider<ThemeData>((ref) {
  final accent = ref.watch(accentProvider);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent.seed,
      brightness: Brightness.dark,
    ),
  );
});
