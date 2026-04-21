import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// "Exclude animation" toggle for the Home recommendation list. Persisted
/// per mode — e.g. Together might want animated kid-pick nights allowed
/// while Solo's a live-action-only zone.
///
/// When active: `discoverPaged` receives TMDB's Animation id (16) as
/// `without_genres` so the server filters animated titles out before they
/// enter the pool, and `buildCandidates` drops animation-tagged rows from
/// the unfiltered trending/top_rated sources too. Was added because
/// `with_genres=<crime>` on /discover matches any title that *includes*
/// Crime, which leaks animated crime-adjacent films into otherwise-Oscar-
/// narrowed queries.
class ModeExcludeAnimationController extends StateNotifier<Map<ViewMode, bool>> {
  ModeExcludeAnimationController(this._prefs, Map<ViewMode, bool> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) => mode == ViewMode.solo
      ? 'wn_exclude_animation_solo'
      : 'wn_exclude_animation_together';

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

final _excludeAnimationPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeExcludeAnimationProvider = StateNotifierProvider<
    ModeExcludeAnimationController, Map<ViewMode, bool>>((ref) {
  final prefs = ref.watch(_excludeAnimationPrefsProvider).value;
  if (prefs == null) {
    return ModeExcludeAnimationController(
      _UnsetPrefs(),
      const {ViewMode.solo: false, ViewMode.together: false},
    );
  }
  return ModeExcludeAnimationController(
      prefs, ModeExcludeAnimationController.readAll(prefs));
});

/// Exclude-animation filter for the active view mode.
final excludeAnimationProvider = Provider<bool>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeExcludeAnimationProvider);
  return map[mode] ?? false;
});

/// Sentinel used while SharedPreferences loads on first build — mirrors
/// `oscar_filter_provider.dart`.
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
