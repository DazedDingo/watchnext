import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

enum WatchMood {
  dateNight,
  chill,
  intense,
  laugh,
  mindBending,
  feelGood,
  documentary,
  custom,
}

extension WatchMoodExt on WatchMood {
  String get label {
    switch (this) {
      case WatchMood.dateNight:
        return 'Date Night';
      case WatchMood.chill:
        return 'Chill';
      case WatchMood.intense:
        return 'Intense';
      case WatchMood.laugh:
        return 'Laugh';
      case WatchMood.mindBending:
        return 'Mind-Bending';
      case WatchMood.feelGood:
        return 'Feel-Good';
      case WatchMood.documentary:
        return 'Documentary';
      case WatchMood.custom:
        return 'Custom';
    }
  }

  /// TMDB genre strings that map to this mood (matched against Recommendation.genres).
  List<String> get genres {
    switch (this) {
      case WatchMood.dateNight:
        return ['Romance', 'Drama'];
      case WatchMood.chill:
        return ['Comedy', 'Animation', 'Family'];
      case WatchMood.intense:
        return ['Thriller', 'Crime', 'Action'];
      case WatchMood.laugh:
        return ['Comedy'];
      case WatchMood.mindBending:
        return ['Science Fiction', 'Mystery', 'Fantasy'];
      case WatchMood.feelGood:
        return ['Comedy', 'Family', 'Animation', 'Romance'];
      case WatchMood.documentary:
        return ['Documentary'];
      case WatchMood.custom:
        return [];
    }
  }
}

/// Per-mode mood selection, persisted to SharedPreferences under two keys
/// (`wn_mood_solo` / `wn_mood_together`) so a Solo pick doesn't bleed into
/// Together and vice versa.
///
/// Reading [moodProvider] always returns the mood for the current
/// [viewModeProvider]; writing via [ModeMoodController.set] updates only
/// that slot.
class ModeMoodController extends StateNotifier<Map<ViewMode, WatchMood?>> {
  ModeMoodController(this._prefs, Map<ViewMode, WatchMood?> initial) : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_mood_solo' : 'wn_mood_together';

  static WatchMood? _decode(String? raw) {
    if (raw == null) return null;
    for (final m in WatchMood.values) {
      if (m.name == raw) return m;
    }
    return null;
  }

  static Map<ViewMode, WatchMood?> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together: _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, WatchMood? mood) async {
    state = {...state, mode: mood};
    final key = _keyFor(mode);
    if (mood == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, mood.name);
    }
  }
}

final _moodPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeMoodProvider =
    StateNotifierProvider<ModeMoodController, Map<ViewMode, WatchMood?>>((ref) {
  final prefs = ref.watch(_moodPrefsProvider).value;
  if (prefs == null) {
    return ModeMoodController(
      _UnsetPrefs(),
      const {ViewMode.solo: null, ViewMode.together: null},
    );
  }
  return ModeMoodController(prefs, ModeMoodController.readAll(prefs));
});

/// Mood for the active view mode. Reading this yields the Solo pick in Solo
/// mode and the Together pick in Together mode; switching modes instantly
/// swaps the value without losing the other slot.
final moodProvider = Provider<WatchMood?>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeMoodProvider);
  return map[mode];
});

/// Sentinel used while SharedPreferences loads on first build. Mirrors the
/// pattern in mode_provider.dart.
class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  String? getString(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
