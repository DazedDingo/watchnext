import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// How the TMDB /discover call should rank candidate titles.
///
/// - [topRated]: `vote_average.desc` with the default vote-count floor.
///   Default. What 99% of users want most of the time.
/// - [popularity]: `popularity.desc`. Surfaces what's buzzing now regardless
///   of quality.
/// - [recent]: newest first. TMDB's sort field is media-type-dependent
///   (`primary_release_date.desc` for movies, `first_air_date.desc` for TV),
///   so `tmdbSortBy(mediaType)` returns the right token per call.
/// - [underseen]: cinephile-bait. `vote_average.desc` + a vote-count ceiling
///   (`vote_count.lte=500`) so the pool fills with acclaimed-but-obscure
///   titles. The service also suppresses the trending/top_rated baseline
///   when this mode is active — those surfaces are popularity-biased by
///   definition and would drown the underseen signal.
enum SortMode {
  topRated('Top rated'),
  popularity('Popularity'),
  recent('Recent'),
  underseen('Underseen');

  final String label;
  const SortMode(this.label);

  /// Returns the TMDB /discover `sort_by` parameter. Per-media-type for
  /// [recent] because TMDB names the date field differently on movie vs tv.
  String tmdbSortBy(String mediaType) {
    switch (this) {
      case SortMode.topRated:
      case SortMode.underseen:
        return 'vote_average.desc';
      case SortMode.popularity:
        return 'popularity.desc';
      case SortMode.recent:
        return mediaType == 'tv'
            ? 'first_air_date.desc'
            : 'primary_release_date.desc';
    }
  }

  /// Vote-count ceiling applied only for [underseen]. Narrow enough to
  /// exclude blockbusters, wide enough to keep the pool non-empty after the
  /// server-side genre/year/keyword filters run.
  int? get maxVoteCount => this == SortMode.underseen ? 500 : null;

  /// When true, the service should skip trending + top_rated baseline sources
  /// in buildCandidates — they'd dilute/invalidate this sort mode.
  bool get suppressBaseline => this == SortMode.underseen;
}

class ModeSortController extends StateNotifier<Map<ViewMode, SortMode>> {
  ModeSortController(this._prefs, Map<ViewMode, SortMode> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_sort_mode_solo' : 'wn_sort_mode_together';

  static SortMode _decode(String? raw) {
    if (raw == null) return SortMode.topRated;
    for (final m in SortMode.values) {
      if (m.name == raw) return m;
    }
    return SortMode.topRated;
  }

  static Map<ViewMode, SortMode> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together: _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, SortMode value) async {
    state = {...state, mode: value};
    final key = _keyFor(mode);
    if (value == SortMode.topRated) {
      // Default — remove the key so export/import doesn't ship noise.
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value.name);
    }
  }
}

final _sortModePrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeSortProvider =
    StateNotifierProvider<ModeSortController, Map<ViewMode, SortMode>>((ref) {
  final prefs = ref.watch(_sortModePrefsProvider).value;
  if (prefs == null) {
    return ModeSortController(
      _UnsetPrefs(),
      const {ViewMode.solo: SortMode.topRated, ViewMode.together: SortMode.topRated},
    );
  }
  return ModeSortController(prefs, ModeSortController.readAll(prefs));
});

/// Sort mode for the active view mode. Defaults to [SortMode.topRated].
final sortModeProvider = Provider<SortMode>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeSortProvider);
  return map[mode] ?? SortMode.topRated;
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
