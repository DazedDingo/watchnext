import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/sort_mode_provider.dart';

/// Per-mode persistence + TMDB param derivation for the sort-mode chip.
/// Default is [SortMode.topRated]; Underseen is the only mode that suppresses
/// the trending/top_rated baseline and applies a vote-count ceiling.
void main() {
  group('SortMode tmdbSortBy', () {
    test('topRated and underseen both use vote_average.desc', () {
      expect(SortMode.topRated.tmdbSortBy('movie'), 'vote_average.desc');
      expect(SortMode.topRated.tmdbSortBy('tv'), 'vote_average.desc');
      expect(SortMode.underseen.tmdbSortBy('movie'), 'vote_average.desc');
      expect(SortMode.underseen.tmdbSortBy('tv'), 'vote_average.desc');
    });

    test('popularity uses popularity.desc regardless of media type', () {
      expect(SortMode.popularity.tmdbSortBy('movie'), 'popularity.desc');
      expect(SortMode.popularity.tmdbSortBy('tv'), 'popularity.desc');
    });

    test('recent picks the right date field per media type', () {
      expect(SortMode.recent.tmdbSortBy('movie'),
          'primary_release_date.desc');
      expect(SortMode.recent.tmdbSortBy('tv'), 'first_air_date.desc');
    });
  });

  group('SortMode maxVoteCount + suppressBaseline', () {
    test('only underseen sets a ceiling + suppresses baseline', () {
      for (final m in SortMode.values) {
        if (m == SortMode.underseen) continue;
        expect(m.maxVoteCount, isNull, reason: '$m must not cap votes');
        expect(m.suppressBaseline, isFalse,
            reason: '$m must not suppress baseline');
      }
      expect(SortMode.underseen.maxVoteCount, 500);
      expect(SortMode.underseen.suppressBaseline, isTrue);
    });
  });

  group('ModeSortController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('defaults to topRated in both modes when prefs empty', () async {
      final prefs = await SharedPreferences.getInstance();
      final map = ModeSortController.readAll(prefs);
      expect(map[ViewMode.solo], SortMode.topRated);
      expect(map[ViewMode.together], SortMode.topRated);
    });

    test('setting solo does not flip together (modes are independent)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeSortController(prefs, ModeSortController.readAll(prefs));
      await c.set(ViewMode.solo, SortMode.underseen);
      expect(c.state[ViewMode.solo], SortMode.underseen);
      expect(c.state[ViewMode.together], SortMode.topRated);
    });

    test('persists non-default values under wn_sort_mode_{solo,together}',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeSortController(prefs, ModeSortController.readAll(prefs));
      await c.set(ViewMode.solo, SortMode.underseen);
      await c.set(ViewMode.together, SortMode.popularity);
      expect(prefs.getString('wn_sort_mode_solo'), 'underseen');
      expect(prefs.getString('wn_sort_mode_together'), 'popularity');
    });

    test('set(topRated) removes the key — keeps prefs tidy', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_sort_mode_solo': 'underseen',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeSortController(prefs, ModeSortController.readAll(prefs));
      expect(c.state[ViewMode.solo], SortMode.underseen);

      await c.set(ViewMode.solo, SortMode.topRated);
      expect(c.state[ViewMode.solo], SortMode.topRated);
      expect(prefs.containsKey('wn_sort_mode_solo'), isFalse);
    });

    test('rehydrates stored value across cold start', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_sort_mode_together': 'recent',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeSortController.readAll(prefs);
      expect(map[ViewMode.together], SortMode.recent);
      expect(map[ViewMode.solo], SortMode.topRated);
    });

    test('unknown stored value falls back to topRated (graceful rename)',
        () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_sort_mode_solo': 'bogus-mode',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeSortController.readAll(prefs);
      expect(map[ViewMode.solo], SortMode.topRated);
    });
  });
}
