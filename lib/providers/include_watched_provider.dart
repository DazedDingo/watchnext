import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-level preference: when false (default), suggestion surfaces hide
/// titles the household has already watched (anything in `/watchEntries`).
/// When true, watched titles appear alongside unwatched ones.
///
/// Applies everywhere titles are *suggested*: Home recs, Discover rows &
/// search, Decide Together candidates, Concierge + "Like these" title cards,
/// TitleDetail's Similar carousel. Does NOT filter lookup UIs (seed pickers,
/// watchlist) where the user is asking for the full catalog.
class IncludeWatchedController extends StateNotifier<bool> {
  IncludeWatchedController(this._prefs, bool initial) : super(initial);
  final SharedPreferences _prefs;
  static const _key = 'wn_include_watched';

  static bool read(SharedPreferences prefs) => prefs.getBool(_key) ?? false;

  Future<void> set(bool v) async {
    state = v;
    await _prefs.setBool(_key, v);
  }

  Future<void> toggle() => set(!state);
}

final _prefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final includeWatchedProvider =
    StateNotifierProvider<IncludeWatchedController, bool>((ref) {
  final prefs = ref.watch(_prefsProvider).value;
  if (prefs == null) {
    return IncludeWatchedController(_UnsetPrefs(), false);
  }
  return IncludeWatchedController(prefs, IncludeWatchedController.read(prefs));
});

class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setBool(String key, bool value) async => true;
  @override
  bool? getBool(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
