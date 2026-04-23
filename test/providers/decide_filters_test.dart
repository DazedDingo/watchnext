import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/decide_provider.dart';
import 'package:watchnext/providers/media_type_filter_provider.dart';
import 'package:watchnext/providers/runtime_filter_provider.dart';
import 'package:watchnext/services/recommendations_service.dart';
import 'package:watchnext/services/tmdb_service.dart';

/// Decide honors a snapshot of the Home filter stack (genre / year / runtime /
/// media type) so sessions started with filters active don't surface titles
/// the user just narrowed away from on Home. Awards / sort / curated are
/// deliberately excluded — see [DecideFilters] doc.
void main() {
  WatchlistItem item({
    required int id,
    required String title,
    String mediaType = 'movie',
    int? year,
    int? runtime,
    List<String> genres = const [],
  }) =>
      WatchlistItem(
        id: '$mediaType:$id',
        mediaType: mediaType,
        tmdbId: id,
        title: title,
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
        year: year,
        runtime: runtime,
        genres: genres,
      );

  TmdbService tmdbFor({
    List<Map<String, dynamic>>? movies,
    List<Map<String, dynamic>>? tv,
  }) {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/trending/movie/week')) {
        return http.Response(
          json.encode({'results': movies ?? const []}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (req.url.path.endsWith('/trending/tv/week')) {
        return http.Response(
          json.encode({'results': tv ?? const []}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('not mocked: ${req.url}', 404);
    });
    return TmdbService(client: client);
  }

  DecideController controllerFor(TmdbService tmdb) {
    final recs = RecommendationsService(db: FakeFirebaseFirestore(), tmdb: tmdb);
    return DecideController(tmdb, recs, null);
  }

  group('DecideFilters.matches — pure predicate', () {
    test('isEmpty passes every candidate through', () {
      const filters = DecideFilters();
      expect(filters.isEmpty, isTrue);
      final c = DecideCandidate(
          mediaType: 'movie', tmdbId: 1, title: 't', year: 1999);
      expect(filters.matches(c), isTrue);
    });

    test('media type drops the wrong-type row', () {
      const filters = DecideFilters(mediaType: MediaTypeFilter.movie);
      final tv = DecideCandidate(mediaType: 'tv', tmdbId: 1, title: 't');
      final movie = DecideCandidate(mediaType: 'movie', tmdbId: 2, title: 't');
      expect(filters.matches(tv), isFalse);
      expect(filters.matches(movie), isTrue);
    });

    test('year range drops null-year when any bound set', () {
      const filters = DecideFilters(minYear: 2000);
      final knownOld = DecideCandidate(
          mediaType: 'movie', tmdbId: 1, title: 't', year: 1990);
      final knownNew = DecideCandidate(
          mediaType: 'movie', tmdbId: 2, title: 't', year: 2010);
      final unknown =
          DecideCandidate(mediaType: 'movie', tmdbId: 3, title: 't');
      expect(filters.matches(knownOld), isFalse);
      expect(filters.matches(knownNew), isTrue);
      expect(filters.matches(unknown), isFalse,
          reason: 'unknown-year drops when any bound is set');
    });

    test('runtime bucket drops null-runtime (strict)', () {
      const filters = DecideFilters(runtime: RuntimeBucket.medium);
      final mid = DecideCandidate(
          mediaType: 'movie', tmdbId: 1, title: 't', runtime: 100);
      final long =
          DecideCandidate(mediaType: 'movie', tmdbId: 2, title: 't', runtime: 180);
      final unknown =
          DecideCandidate(mediaType: 'movie', tmdbId: 3, title: 't');
      expect(filters.matches(mid), isTrue);
      expect(filters.matches(long), isFalse);
      expect(filters.matches(unknown), isFalse);
    });

    test('genre set requires at least one overlap', () {
      const filters = DecideFilters(genres: {'Drama'});
      final drama = DecideCandidate(
          mediaType: 'movie', tmdbId: 1, title: 't', genres: const ['Drama']);
      final horror = DecideCandidate(
          mediaType: 'movie', tmdbId: 2, title: 't', genres: const ['Horror']);
      final mixed = DecideCandidate(
          mediaType: 'movie',
          tmdbId: 3,
          title: 't',
          genres: const ['Drama', 'Comedy']);
      expect(filters.matches(drama), isTrue);
      expect(filters.matches(horror), isFalse);
      expect(filters.matches(mixed), isTrue);
    });

    test('composes across all axes — AND, not OR', () {
      const filters = DecideFilters(
        genres: {'Drama'},
        minYear: 2000,
        maxYear: 2020,
        runtime: RuntimeBucket.medium,
        mediaType: MediaTypeFilter.movie,
      );
      final pass = DecideCandidate(
        mediaType: 'movie',
        tmdbId: 1,
        title: 'Parasite',
        year: 2019,
        runtime: 110,
        genres: const ['Drama'],
      );
      final wrongGenre = DecideCandidate(
        mediaType: 'movie',
        tmdbId: 2,
        title: 'X',
        year: 2019,
        runtime: 100,
        genres: const ['Comedy'],
      );
      final wrongYear = DecideCandidate(
        mediaType: 'movie',
        tmdbId: 3,
        title: 'X',
        year: 1990,
        runtime: 100,
        genres: const ['Drama'],
      );
      expect(filters.matches(pass), isTrue);
      expect(filters.matches(wrongGenre), isFalse);
      expect(filters.matches(wrongYear), isFalse);
    });
  });

  group('DecideController.start — applies filters', () {
    test('watchlist is pruned client-side by every axis', () async {
      final tmdb = tmdbFor();
      final ctrl = controllerFor(tmdb);
      final watchlist = [
        item(
            id: 1,
            title: 'keep',
            year: 2010,
            runtime: 100,
            genres: const ['Drama']),
        item(
            id: 2,
            title: 'wrong genre',
            year: 2010,
            runtime: 100,
            genres: const ['Horror']),
        item(
            id: 3,
            title: 'too old',
            year: 1980,
            runtime: 100,
            genres: const ['Drama']),
        item(
            id: 4,
            title: 'too short',
            year: 2010,
            runtime: 60,
            genres: const ['Drama']),
        item(
            id: 5,
            title: 'tv',
            mediaType: 'tv',
            year: 2010,
            runtime: 100,
            genres: const ['Drama']),
      ];

      await ctrl.start(
        watchlist,
        filters: const DecideFilters(
          genres: {'Drama'},
          minYear: 2000,
          runtime: RuntimeBucket.medium,
          mediaType: MediaTypeFilter.movie,
        ),
      );

      final keys = ctrl.state.candidates.map((c) => c.key).toList();
      expect(keys, ['movie:1'],
          reason: 'only the one row matching every predicate survives');
    });

    test('mediaType=tv swaps trending source to /trending/tv', () async {
      final tmdb = tmdbFor(
        movies: [
          {'id': 100, 'title': 'A Movie', 'media_type': 'movie'},
        ],
        tv: [
          {'id': 200, 'name': 'A Show', 'media_type': 'tv'},
        ],
      );
      final ctrl = controllerFor(tmdb);

      await ctrl.start(
        const [],
        filters: const DecideFilters(mediaType: MediaTypeFilter.tv),
      );

      final keys = ctrl.state.candidates.map((c) => c.key).toList();
      expect(keys, contains('tv:200'));
      expect(keys.any((k) => k.startsWith('movie:')), isFalse,
          reason: 'movie trending must not leak in under tv filter');
    });

    test('trending rows inherit genre_ids so genre filter can match', () async {
      // TMDB genre id 18 = Drama, 35 = Comedy.
      final tmdb = tmdbFor(movies: [
        {
          'id': 100,
          'title': 'Drama Flick',
          'media_type': 'movie',
          'genre_ids': [18],
        },
        {
          'id': 101,
          'title': 'Comedy Flick',
          'media_type': 'movie',
          'genre_ids': [35],
        },
      ]);
      final ctrl = controllerFor(tmdb);

      await ctrl.start(
        const [],
        filters: const DecideFilters(genres: {'Drama'}),
      );

      final keys = ctrl.state.candidates.map((c) => c.key).toList();
      expect(keys, contains('movie:100'));
      expect(keys.contains('movie:101'), isFalse,
          reason: 'genre filter must drop the comedy trending row');
    });
  });

  group('DecideController.rerollCandidates — applies filters', () {
    test('reroll honours filter mediaType when topping up from TMDB', () async {
      final tmdb = tmdbFor(
        tv: [
          {'id': 200, 'name': 'Show A', 'media_type': 'tv'},
          {'id': 201, 'name': 'Show B', 'media_type': 'tv'},
          {'id': 202, 'name': 'Show C', 'media_type': 'tv'},
          {'id': 203, 'name': 'Show D', 'media_type': 'tv'},
          {'id': 204, 'name': 'Show E', 'media_type': 'tv'},
        ],
      );
      final ctrl = controllerFor(tmdb);

      const filters = DecideFilters(mediaType: MediaTypeFilter.tv);
      await ctrl.start(const [], filters: filters);
      await ctrl.rerollCandidates(const [], filters: filters);

      final keys = ctrl.state.candidates.map((c) => c.key).toSet();
      expect(keys, isNotEmpty);
      for (final k in keys) {
        expect(k.startsWith('tv:'), isTrue,
            reason: '$k should be a tv row under mediaType=tv');
      }
    });
  });
}
