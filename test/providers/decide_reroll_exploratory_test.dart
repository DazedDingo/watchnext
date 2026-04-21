import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/decide_provider.dart';
import 'package:watchnext/services/recommendations_service.dart';
import 'package:watchnext/services/tmdb_service.dart';

/// `rerollExploratory` is the Decide-only "Surprise me" path: opt-in,
/// fishes a random older decade via TMDB `/discover` to break the loop
/// when neither user is biting on watchlist + trending. Tests cover:
///  - decade picker is honored (year bounds on the discover URLs)
///  - vote_count floors differ for movie vs tv (older catalog has thinner
///    TV at high vote counts)
///  - exclude set prevents the same titles from cycling back
///  - interleaving keeps a movie/tv mix instead of one-type dominance
///  - failure modes: empty TMDB response and thrown error both leave the
///    existing pool intact and surface an error the UI can display
void main() {
  WatchlistItem watchlistItem(int id, String title) => WatchlistItem(
        id: 'movie:$id',
        mediaType: 'movie',
        tmdbId: id,
        title: title,
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
      );

  /// HTTP mock that records every TMDB request URL and routes
  /// `/discover/movie` and `/discover/tv` to caller-supplied payloads.
  /// Other endpoints (used by `start()`'s trending top-up) return empty.
  ({TmdbService tmdb, List<Uri> requests}) tmdbMock({
    Map<String, dynamic>? movies,
    Map<String, dynamic>? tv,
    bool throwOnDiscover = false,
  }) {
    final requests = <Uri>[];
    final client = MockClient((req) async {
      requests.add(req.url);
      if (throwOnDiscover &&
          (req.url.path.endsWith('/discover/movie') ||
              req.url.path.endsWith('/discover/tv'))) {
        throw http.ClientException('boom');
      }
      if (req.url.path.endsWith('/discover/movie')) {
        return http.Response(
            json.encode(movies ?? const {'results': []}), 200,
            headers: const {'content-type': 'application/json'});
      }
      if (req.url.path.endsWith('/discover/tv')) {
        return http.Response(json.encode(tv ?? const {'results': []}), 200,
            headers: const {'content-type': 'application/json'});
      }
      return http.Response(json.encode(const {'results': []}), 200,
          headers: const {'content-type': 'application/json'});
    });
    return (tmdb: TmdbService(client: client), requests: requests);
  }

  DecideController controllerFor(
    TmdbService tmdb, {
    (int, int) Function()? decadePicker,
  }) {
    final recs = RecommendationsService(db: FakeFirebaseFirestore(), tmdb: tmdb);
    return DecideController(tmdb, recs, null, decadePicker: decadePicker);
  }

  Map<String, dynamic> tmdbRow(int id, {String? title, String? name, String? date}) =>
      {
        'id': id,
        'title': ?title,
        'name': ?name,
        'release_date': ?date,
      };

  group('rerollExploratory — decade-sampled discover', () {
    test('queries /discover/movie and /discover/tv with the decade bounds',
        () async {
      final mock = tmdbMock(
        movies: {'results': [tmdbRow(1001, title: 'Apocalypse Now', date: '1979-08-15')]},
        tv: {'results': [tmdbRow(2001, name: 'Roots', date: '1977-01-23')]},
      );
      final ctrl = controllerFor(mock.tmdb, decadePicker: () => (1970, 1979));
      await ctrl.start([watchlistItem(1, 'Filler')]);

      await ctrl.rerollExploratory();

      final movieReq = mock.requests
          .firstWhere((u) => u.path.endsWith('/discover/movie'));
      final tvReq =
          mock.requests.firstWhere((u) => u.path.endsWith('/discover/tv'));
      expect(movieReq.queryParameters['primary_release_date.gte'],
          '1970-01-01');
      expect(movieReq.queryParameters['primary_release_date.lte'],
          '1979-12-31');
      expect(movieReq.queryParameters['vote_count.gte'], '300',
          reason: 'movies need a higher vote floor in older catalog');
      expect(tvReq.queryParameters['first_air_date.gte'], '1970-01-01');
      expect(tvReq.queryParameters['first_air_date.lte'], '1979-12-31');
      expect(tvReq.queryParameters['vote_count.gte'], '100',
          reason: '70s TV at vote_count >=300 returns nothing — ease the bar');
    });

    test('replaces the candidate pool with up to 5 fresh titles', () async {
      final mock = tmdbMock(
        movies: {
          'results': List.generate(
              4,
              (i) => tmdbRow(1000 + i,
                  title: 'M$i', date: '197${i % 10}-01-01')),
        },
        tv: {
          'results': List.generate(
              4,
              (i) => tmdbRow(2000 + i,
                  name: 'T$i', date: '197${i % 10}-01-01')),
        },
      );
      final ctrl = controllerFor(mock.tmdb, decadePicker: () => (1970, 1979));
      await ctrl.start(List.generate(5, (i) => watchlistItem(i, 'Old$i')));
      final originalKeys =
          ctrl.state.candidates.map((c) => c.key).toSet();

      await ctrl.rerollExploratory();

      expect(ctrl.state.candidates, hasLength(5));
      expect(
          ctrl.state.candidates.map((c) => c.key).toSet().intersection(
              originalKeys),
          isEmpty,
          reason: 'fresh pool should not include rolled-out watchlist titles');
      // Interleaving: should include both movie and tv rows, not all-one-type.
      final mediaTypes =
          ctrl.state.candidates.map((c) => c.mediaType).toSet();
      expect(mediaTypes, containsAll(['movie', 'tv']),
          reason: 'interleave keeps the mix interesting');
    });

    test('excludes watched titles from the surprise pool', () async {
      final mock = tmdbMock(
        movies: {
          'results': List.generate(
              5, (i) => tmdbRow(1000 + i, title: 'M$i', date: '1979-01-01')),
        },
      );
      final ctrl = controllerFor(mock.tmdb, decadePicker: () => (1970, 1979));
      await ctrl.start(const []);

      await ctrl.rerollExploratory(
          watchedKeys: {'movie:1000', 'movie:1001'});

      final keys = ctrl.state.candidates.map((c) => c.key).toSet();
      expect(keys.contains('movie:1000'), isFalse);
      expect(keys.contains('movie:1001'), isFalse);
    });

    test('preserves session state (picks survive a surprise reroll)', () async {
      final mock = tmdbMock(
        movies: {'results': [tmdbRow(1001, title: 'X', date: '1979-01-01')]},
      );
      final ctrl = controllerFor(mock.tmdb, decadePicker: () => (1970, 1979));
      final watchlist = List.generate(5, (i) => watchlistItem(i, 'W$i'));
      await ctrl.start(watchlist);
      ctrl.submitPickA(ctrl.state.candidates.first);
      final pickA = ctrl.state.pickA!;

      await ctrl.rerollExploratory();

      expect(ctrl.state.pickA, isNotNull);
      expect(ctrl.state.pickA!.key, pickA.key);
    });

    test('empty TMDB response sets an error and leaves pool intact', () async {
      final mock = tmdbMock(); // both movie + tv return {results: []}
      final ctrl = controllerFor(mock.tmdb, decadePicker: () => (1980, 1989));
      final watchlist = List.generate(5, (i) => watchlistItem(i, 'W$i'));
      await ctrl.start(watchlist);
      final originalKeys =
          ctrl.state.candidates.map((c) => c.key).toList();

      await ctrl.rerollExploratory();

      expect(ctrl.state.error, isNotNull);
      expect(ctrl.state.error, contains('1980'),
          reason: 'error should mention the decade so the user knows what failed');
      expect(ctrl.state.candidates.map((c) => c.key).toList(), originalKeys,
          reason: 'failed surprise should leave the user able to keep picking');
    });

    test('thrown TMDB error is caught and surfaced as a user-facing message',
        () async {
      final mock = tmdbMock(throwOnDiscover: true);
      final ctrl = controllerFor(mock.tmdb, decadePicker: () => (1990, 1999));
      final watchlist = List.generate(5, (i) => watchlistItem(i, 'W$i'));
      await ctrl.start(watchlist);
      final originalKeys =
          ctrl.state.candidates.map((c) => c.key).toList();

      await ctrl.rerollExploratory();

      expect(ctrl.state.error, isNotNull);
      expect(ctrl.state.candidates.map((c) => c.key).toList(), originalKeys);
    });

    test('default decade picker returns one of kExploratoryDecades', () {
      // Sanity: the constant excludes the current decade so the surprise rung
      // doesn't just resurface the same recent fare trending already covers.
      expect(kExploratoryDecades, isNotEmpty);
      expect(kExploratoryDecades.every((d) => d.$2 < 2020), isTrue);
    });
  });
}
