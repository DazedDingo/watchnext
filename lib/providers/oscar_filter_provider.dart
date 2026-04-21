import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// "Won an Oscar" toggle for the Home recommendation list. Persisted per
/// mode like every other filter — a user might want oscar winners only on
/// Together night and an open pool when picking solo.
///
/// When active, the recommendations refresh fires `/discover` with TMDB's
/// "oscar-winning-film" keyword (id 210024) and stamps `is_oscar_winner=true`
/// on those rows. The Home filter then keeps only flagged recs.
class ModeOscarController extends StateNotifier<Map<ViewMode, bool>> {
  ModeOscarController(this._prefs, Map<ViewMode, bool> initial) : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_oscar_winners_solo' : 'wn_oscar_winners_together';

  static Map<ViewMode, bool> readAll(SharedPreferences prefs) => {
        ViewMode.solo: prefs.getBool(_keyFor(ViewMode.solo)) ?? false,
        ViewMode.together: prefs.getBool(_keyFor(ViewMode.together)) ?? false,
      };

  Future<void> set(ViewMode mode, bool value) async {
    state = {...state, mode: value};
    final key = _keyFor(mode);
    if (value) {
      await _prefs.setBool(key, true);
    } else {
      await _prefs.remove(key);
    }
  }
}

final _oscarPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeOscarProvider =
    StateNotifierProvider<ModeOscarController, Map<ViewMode, bool>>((ref) {
  final prefs = ref.watch(_oscarPrefsProvider).value;
  if (prefs == null) {
    return ModeOscarController(
      _UnsetPrefs(),
      const {ViewMode.solo: false, ViewMode.together: false},
    );
  }
  return ModeOscarController(prefs, ModeOscarController.readAll(prefs));
});

/// Oscar-winners-only filter for the active view mode.
final oscarFilterProvider = Provider<bool>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeOscarProvider);
  return map[mode] ?? false;
});

/// Sentinel used while SharedPreferences loads on first build — mirrors the
/// pattern in `media_type_filter_provider.dart`.
class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setBool(String key, bool value) async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  bool? getBool(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
