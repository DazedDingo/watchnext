import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/tmdb_genres.dart';
import 'mode_provider.dart';

/// Per-mode selected TMDB genre names. Replaces the single-mood filter on
/// Home with a free-form multi-select.
///
/// Genre names are stored — not TMDB ids — because recommendations already
/// carry resolved names on `Recommendation.genres`, and the home filter does
/// client-side `selected.every(r.genres.contains)` (intersection — selecting
/// Western + Sci-Fi shows only titles tagged as both). Names are the stable
/// point across movie + TV domains (the two id maps overlap but aren't
/// identical).
///
/// Persistence: a JSON array of names under `wn_genres_solo` /
/// `wn_genres_together`, mirroring the other mode-keyed filter providers.
class ModeGenreController extends StateNotifier<Map<ViewMode, Set<String>>> {
  ModeGenreController(this._prefs, Map<ViewMode, Set<String>> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_genres_solo' : 'wn_genres_together';

  static Set<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final list = json.decode(raw);
      if (list is! List) return <String>{};
      return list.whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Map<ViewMode, Set<String>> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together: _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, Set<String> genres) async {
    state = {...state, mode: {...genres}};
    final key = _keyFor(mode);
    if (genres.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, json.encode(genres.toList()..sort()));
    }
  }

  Future<void> toggle(ViewMode mode, String genre) async {
    final current = {...state[mode] ?? const <String>{}};
    if (!current.add(genre)) current.remove(genre);
    await set(mode, current);
  }

  Future<void> clear(ViewMode mode) => set(mode, const <String>{});
}

/// Exposed so tests can `overrideWithValue(AsyncValue.data(prefs))` and
/// skip the real SharedPreferences.getInstance() async boot.
final genrePrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeGenreProvider =
    StateNotifierProvider<ModeGenreController, Map<ViewMode, Set<String>>>(
        (ref) {
  final prefs = ref.watch(genrePrefsProvider).value;
  if (prefs == null) {
    return ModeGenreController(
      _UnsetPrefs(),
      const {ViewMode.solo: <String>{}, ViewMode.together: <String>{}},
    );
  }
  return ModeGenreController(prefs, ModeGenreController.readAll(prefs));
});

/// Active-mode slice of [modeGenreProvider]. Empty = no filter.
final selectedGenresProvider = Provider<Set<String>>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeGenreProvider);
  return map[mode] ?? const <String>{};
});

/// Full union of movie + TV TMDB genre names, deduped and alphabetised —
/// the source of truth for the genre-picker chip grid.
final allGenresProvider = Provider<List<String>>((_) {
  final set = <String>{
    ...tmdbMovieGenres.values,
    ...tmdbTvGenres.values,
  };
  final list = set.toList()..sort();
  return List.unmodifiable(list);
});

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
