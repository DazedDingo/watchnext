import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the Home "Up Next" row presents itself.
///
/// `marquee` (default) — single ~36px row that auto-cycles through
///                        items with a fade transition.
/// `strip`             — single horizontal-scrollable row, all items
///                        pipe-delimited.
enum UpNextStyle {
  marquee('Auto-cycling marquee'),
  strip('Static strip');

  final String label;
  const UpNextStyle(this.label);

  static UpNextStyle fromName(String? name) {
    for (final s in UpNextStyle.values) {
      if (s.name == name) return s;
    }
    return UpNextStyle.marquee;
  }
}

const kUpNextStyleKey = 'wn_up_next_style';

class UpNextStyleController extends StateNotifier<UpNextStyle> {
  final SharedPreferences _prefs;

  UpNextStyleController(this._prefs)
      : super(UpNextStyle.fromName(_prefs.getString(kUpNextStyleKey)));

  Future<void> set(UpNextStyle style) async {
    state = style;
    await _prefs.setString(kUpNextStyleKey, style.name);
  }
}

final upNextStyleProvider =
    StateNotifierProvider<UpNextStyleController, UpNextStyle>((ref) {
  throw UnimplementedError('upNextStyleProvider not initialised');
});
