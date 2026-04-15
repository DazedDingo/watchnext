import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/recommendation.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/decide_provider.dart';

/// DecideCandidate is the pure data layer that powers the Decide Together
/// flow. Each factory shape is a separate conversion from a Firestore
/// model or TMDB response — all worth pinning.
void main() {
  group('DecideCandidate.key', () {
    test('combines mediaType:tmdbId canonically', () {
      const c = DecideCandidate(mediaType: 'movie', tmdbId: 42, title: 'X');
      expect(c.key, 'movie:42');
    });
  });

  group('DecideCandidate.fromWatchlist', () {
    test('carries genres and source=watchlist', () {
      final w = WatchlistItem(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'Foo',
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
        year: 2020,
        posterPath: '/p.jpg',
        genres: const ['Drama', 'Thriller'],
      );
      final c = DecideCandidate.fromWatchlist(w);
      expect(c.mediaType, 'movie');
      expect(c.tmdbId, 1);
      expect(c.title, 'Foo');
      expect(c.year, 2020);
      expect(c.posterPath, '/p.jpg');
      expect(c.genres, ['Drama', 'Thriller']);
      expect(c.source, 'watchlist');
    });
  });

  group('DecideCandidate.fromRecommendation', () {
    test('carries over the original source label (reddit/trending/etc)', () {
      const r = Recommendation(
        id: 'movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'The Matrix',
        matchScore: 90,
        source: 'reddit',
      );
      final c = DecideCandidate.fromRecommendation(r);
      expect(c.source, 'reddit');
      expect(c.tmdbId, 42);
    });
  });

  group('DecideCandidate.fromTmdb', () {
    test('movie shape: uses release_date for year', () {
      final c = DecideCandidate.fromTmdb({
        'id': 603,
        'title': 'The Matrix',
        'release_date': '1999-03-31',
        'poster_path': '/m.jpg',
        'media_type': 'movie',
      }, fallbackMediaType: 'movie');
      expect(c.mediaType, 'movie');
      expect(c.year, 1999);
      expect(c.title, 'The Matrix');
    });

    test('tv shape: uses first_air_date for year and name for title', () {
      final c = DecideCandidate.fromTmdb({
        'id': 1399,
        'name': 'Game of Thrones',
        'first_air_date': '2011-04-17',
        'media_type': 'tv',
      }, fallbackMediaType: 'tv');
      expect(c.mediaType, 'tv');
      expect(c.title, 'Game of Thrones');
      expect(c.year, 2011);
    });

    test('missing media_type falls back to the provided default', () {
      final c = DecideCandidate.fromTmdb(
        {'id': 1, 'title': 'X'},
        fallbackMediaType: 'movie',
      );
      expect(c.mediaType, 'movie');
    });

    test('missing title or name → "Untitled"', () {
      final c = DecideCandidate.fromTmdb(
        {'id': 1},
        fallbackMediaType: 'movie',
      );
      expect(c.title, 'Untitled');
    });

    test('too-short date string → year null', () {
      final c = DecideCandidate.fromTmdb(
        {'id': 1, 'title': 'X', 'release_date': '19'},
        fallbackMediaType: 'movie',
      );
      expect(c.year, isNull);
    });

    test('source defaults to "trending" but respects override', () {
      final c = DecideCandidate.fromTmdb(
        {'id': 1, 'title': 'X'},
        fallbackMediaType: 'movie',
        source: 'topRated',
      );
      expect(c.source, 'topRated');
    });
  });

  group('DecideSessionState.copyWith', () {
    test('preserves untouched fields', () {
      const state = DecideSessionState(
        phase: DecidePhase.negotiate,
        vetoesA: 2,
      );
      final next = state.copyWith(phase: DecidePhase.pick);
      expect(next.phase, DecidePhase.pick);
      expect(next.vetoesA, 2);
    });

    test('clearError wipes the error field regardless of other args', () {
      const state = DecideSessionState(error: 'boom');
      final next = state.copyWith(clearError: true);
      expect(next.error, isNull);
    });

    test('clearCompromise wipes currentCompromise even if copied over', () {
      const state = DecideSessionState(
        currentCompromise: DecideCandidate(
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
        ),
      );
      final next = state.copyWith(clearCompromise: true);
      expect(next.currentCompromise, isNull);
    });

    test('excluded set replaces rather than merges', () {
      const state = DecideSessionState(excluded: {'a'});
      final next = state.copyWith(excluded: {'b', 'c'});
      expect(next.excluded, {'b', 'c'});
      expect(next.excluded.contains('a'), isFalse);
    });
  });
}
