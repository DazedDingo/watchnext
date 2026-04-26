import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/services/tmdb_service.dart';

/// Record every outbound TMDB request. Each test asserts both that the
/// endpoint was hit (URL path + query params) and that the parsed JSON is
/// returned verbatim. Prevents silent regressions when someone renames
/// a TMDB route or drops a default query param.
class _Recorder {
  final List<http.Request> calls = [];
  http.Client client({Map<String, Map<String, dynamic>> routes = const {}}) {
    return MockClient((req) async {
      calls.add(req);
      for (final entry in routes.entries) {
        if (req.url.path.endsWith(entry.key)) {
          return http.Response(json.encode(entry.value), 200,
              headers: const {'content-type': 'application/json'});
        }
      }
      return http.Response('not mocked: ${req.url}', 404);
    });
  }
}

void main() {
  group('TmdbService.imageUrl', () {
    test('null and empty return null', () {
      expect(TmdbService.imageUrl(null), isNull);
      expect(TmdbService.imageUrl(''), isNull);
    });

    test('default size is w500', () {
      expect(TmdbService.imageUrl('/m.jpg'),
          'https://image.tmdb.org/t/p/w500/m.jpg');
    });

    test('honors explicit sizes', () {
      expect(TmdbService.imageUrl('/m.jpg', size: 'w92'),
          'https://image.tmdb.org/t/p/w92/m.jpg');
      expect(TmdbService.imageUrl('/m.jpg', size: 'w342'),
          'https://image.tmdb.org/t/p/w342/m.jpg');
      expect(TmdbService.imageUrl('/m.jpg', size: 'w500'),
          'https://image.tmdb.org/t/p/w500/m.jpg');
      expect(TmdbService.imageUrl('/m.jpg', size: 'w780'),
          'https://image.tmdb.org/t/p/w780/m.jpg');
      expect(TmdbService.imageUrl('/m.jpg', size: 'original'),
          'https://image.tmdb.org/t/p/original/m.jpg');
    });
  });

  group('TmdbService query structure', () {
    test('every request includes api_key and language=en-US', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/search/multi': {'results': []},
      }));
      await tmdb.searchMulti('foo');
      expect(rec.calls, hasLength(1));
      expect(rec.calls.single.url.queryParameters['language'], 'en-US');
      expect(rec.calls.single.url.queryParameters, contains('api_key'));
    });
  });

  group('TmdbService endpoints', () {
    test('searchMulti hits /search/multi with query param', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/search/multi': {
          'results': [
            {'id': 1, 'media_type': 'movie', 'title': 'X'},
          ],
        },
      }));
      final res = await tmdb.searchMulti('hackers', page: 3);
      expect(res['results'], isA<List>());
      final url = rec.calls.single.url;
      expect(url.path, endsWith('/search/multi'));
      expect(url.queryParameters['query'], 'hackers');
      expect(url.queryParameters['page'], '3');
    });

    test('movieDetails hits /movie/:id with credits,keywords,similar,videos append',
        () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/movie/603': {'id': 603, 'title': 'The Matrix'},
      }));
      final res = await tmdb.movieDetails(603);
      expect(res['id'], 603);
      final url = rec.calls.single.url;
      expect(url.path, endsWith('/movie/603'));
      expect(url.queryParameters['append_to_response'],
          'credits,keywords,similar,videos');
    });

    test('tvDetails hits /tv/:id with external_ids,videos append', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/tv/1399': {'id': 1399, 'name': 'GoT'},
      }));
      await tmdb.tvDetails(1399);
      final url = rec.calls.single.url;
      expect(url.path, endsWith('/tv/1399'));
      expect(url.queryParameters['append_to_response'],
          'credits,keywords,similar,external_ids,videos');
    });

    test('tvSeason hits /tv/:id/season/:n', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/tv/1/season/2': {'season_number': 2},
      }));
      await tmdb.tvSeason(1, 2);
      expect(rec.calls.single.url.path, endsWith('/tv/1/season/2'));
    });

    test('tvEpisode hits /tv/:id/season/:s/episode/:e', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/tv/1/season/2/episode/3': {'episode_number': 3},
      }));
      await tmdb.tvEpisode(1, 2, 3);
      expect(rec.calls.single.url.path, endsWith('/tv/1/season/2/episode/3'));
    });

    test('tvEpisodeExternalIds hits /external_ids and returns imdb_id', () async {
      // Per-episode IMDb deep-link enabler — Trakt's episode.imdb is often
      // null, so TMDB's episode-level external_ids is the reliable source.
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/tv/1399/season/1/episode/1/external_ids': {
          'imdb_id': 'tt1480055',
          'freebase_mid': null,
          'tvdb_id': 3254641,
        },
      }));
      final res = await tmdb.tvEpisodeExternalIds(1399, 1, 1);
      expect(res['imdb_id'], 'tt1480055');
      expect(rec.calls.single.url.path,
          endsWith('/tv/1399/season/1/episode/1/external_ids'));
    });

    test('similarMovies and similarTv route to TMDB similar endpoints',
        () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/movie/1/similar': {'results': []},
        '/tv/2/similar': {'results': []},
      }));
      await tmdb.similarMovies(1);
      await tmdb.similarTv(2, page: 4);
      expect(rec.calls[0].url.path, endsWith('/movie/1/similar'));
      expect(rec.calls[1].url.path, endsWith('/tv/2/similar'));
      expect(rec.calls[1].url.queryParameters['page'], '4');
    });

    test('trendingMovies defaults window to week but accepts day', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/trending/movie/week': {'results': []},
        '/trending/movie/day': {'results': []},
      }));
      await tmdb.trendingMovies();
      await tmdb.trendingMovies(window: 'day');
      expect(rec.calls[0].url.path, endsWith('/trending/movie/week'));
      expect(rec.calls[1].url.path, endsWith('/trending/movie/day'));
    });

    test('trendingTv mirrors the movie shape', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/trending/tv/week': {'results': []},
      }));
      await tmdb.trendingTv();
      expect(rec.calls.single.url.path, endsWith('/trending/tv/week'));
    });

    test('upcoming/topRated routes hit the right paths', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/movie/upcoming': {'results': []},
        '/movie/top_rated': {'results': []},
        '/tv/top_rated': {'results': []},
      }));
      await tmdb.upcomingMovies();
      await tmdb.topRatedMovies();
      await tmdb.topRatedTv();
      expect(rec.calls[0].url.path, endsWith('/movie/upcoming'));
      expect(rec.calls[1].url.path, endsWith('/movie/top_rated'));
      expect(rec.calls[2].url.path, endsWith('/tv/top_rated'));
    });

    test('discoverMovies forwards params verbatim', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/discover/movie': {'results': []},
      }));
      await tmdb.discoverMovies({'with_genres': '28', 'sort_by': 'popularity.desc'});
      final q = rec.calls.single.url.queryParameters;
      expect(q['with_genres'], '28');
      expect(q['sort_by'], 'popularity.desc');
    });

    test('findByExternalId hits /find/:id with external_source', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/find/tt0133093': {'movie_results': [], 'tv_results': []},
      }));
      await tmdb.findByExternalId('tt0133093');
      expect(rec.calls.single.url.queryParameters['external_source'],
          'imdb_id');
    });

    test('listDetails hits /list/:id', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/list/7': {'id': 7, 'items': []},
      }));
      await tmdb.listDetails(7);
      expect(rec.calls.single.url.path, endsWith('/list/7'));
    });
  });

  group('TmdbService error handling', () {
    test('non-200 response throws with status code visible', () async {
      final client = MockClient((_) async => http.Response('boom', 500));
      final tmdb = TmdbService(client: client);
      expect(
        () => tmdb.searchMulti('x'),
        throwsA(predicate(
            (e) => e.toString().contains('500') && e.toString().contains('boom'))),
      );
    });

    test('404 surfaces as exception with body in the message', () async {
      final client = MockClient(
          (_) async => http.Response('{"status":"nope"}', 404));
      final tmdb = TmdbService(client: client);
      expect(
        () => tmdb.movieDetails(99999999),
        throwsA(predicate((e) => e.toString().contains('404'))),
      );
    });

    test('hung request throws TimeoutException instead of waiting forever',
        () async {
      // Regression guard: `http.Client` has no default timeout. With a
      // narrow filter set, discoverPaged fans out ~18 TMDB calls per refresh;
      // one slow response would hang the pull-to-refresh spinner indefinitely.
      // The service now wraps every request in `.timeout(kRequestTimeout)` so
      // stuck requests surface as a throwable the caller can swallow.
      final client = MockClient((_) async {
        // Never completes — simulates a stuck socket.
        await Completer<http.Response>().future;
        return http.Response('unreachable', 200);
      });
      final tmdb = TmdbService(
        client: client,
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        tmdb.searchMulti('x'),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  // ─── discoverPaged fallback ladder ────────────────────────────────────────
  //
  // The narrow-filter problem: "Sci-Fi + War" or "War, 1970-1989" returns ~0
  // useful hits from a single OR-joined discover call because the union
  // pool is dominated by single-genre popular titles that fail the client's
  // AND intersection. `discoverPaged` has a six-rung ladder:
  //   1. AND-join genres + year (multi-genre only — matches client intersection)
  //   2. OR-join genres + year (widens pool for keyword-augmented titles)
  //   3. Per-genre + year (multi-genre only — salvages sparse single genres)
  //   4. AND-join without year (multi-genre + year-active only)
  //   5. OR-join without year
  //   6. Per-genre without year (multi-genre only — last resort)
  //
  // These tests script the mock server to simulate each rung being the one
  // that finally fills the pool, asserting the right queries fire + results
  // merge + dedup across rungs.
  group('TmdbService.discoverPaged — rung 1 (happy path)', () {
    test('single query paginates until pool floor is hit', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          final page = int.parse(req.url.queryParameters['page'] ?? '1');
          final start = (page - 1) * 2;
          return http.Response(
            json.encode({
              'results': [
                {'id': start + 1, 'title': 'M${start + 1}'},
                {'id': start + 2, 'title': 'M${start + 2}'},
              ],
              'total_pages': 5,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752], // War
        minYear: 1970,
        maxYear: 1989,
        poolFloor: 4,
      );
      expect((res['results'] as List), hasLength(4));
      // Paginated twice: 2 + 2 = 4, should stop once floor reached.
      expect(calls.length, 2);
      // Genre OR-join + year range on the first call.
      final q1 = calls.first.queryParameters;
      expect(q1['with_genres'], '10752');
      expect(q1['primary_release_date.gte'], '1970-01-01');
      expect(q1['primary_release_date.lte'], '1989-12-31');
      expect(q1['sort_by'], 'vote_average.desc');
      expect(q1['vote_count.gte'], '50');
    });

    test('tv uses first_air_date for bounds', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': List.generate(
                  30, (i) => {'id': i + 1, 'name': 'T${i + 1}'}),
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'tv',
        genreIds: const [10768], // War & Politics
        minYear: 2000,
        maxYear: 2010,
      );
      final q = calls.first.queryParameters;
      expect(q['first_air_date.gte'], '2000-01-01');
      expect(q['first_air_date.lte'], '2010-12-31');
      expect(q.containsKey('primary_release_date.gte'), isFalse);
    });

    test('AND-joins multiple genre ids with comma on rung 1', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({
              'results': List.generate(
                  30, (i) => {'id': i + 1, 'title': 'X${i + 1}'}),
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752, 36, 18], // War & History & Drama
      );
      // Rung 1 is AND-joined now — the strict intersection matches what the
      // client-side AND filter expects, so rows returned here survive.
      expect(captured!.queryParameters['with_genres'], '10752,36,18');
    });

    test('stops paginating once total_pages reached even below poolFloor',
        () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'Only One'},
              ],
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [99],
        poolFloor: 100,
        maxPages: 10,
      );
      // Rung 1: exhausted pages=1 at total_pages=1, then rung 3 won't fire
      // because no year bounds were set and rung 2 needs >1 genre.
      expect(calls, hasLength(1));
      expect((res['results'] as List), hasLength(1));
    });
  });

  group('TmdbService.discoverPaged — AND → OR → per-genre ladder', () {
    test('AND rung empty + OR sparse → per-genre fallback fires', () async {
      // Script the three primary multi-genre rungs:
      //   - AND (comma) → 0 rows (strict intersection is empty)
      //   - OR (pipe)   → 1 row (popularity-dominated union)
      //   - per-genre   → 10 rows each, ids namespaced by genre
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          final genres = req.url.queryParameters['with_genres']!;
          if (genres.contains('|')) {
            return http.Response(
              json.encode({
                'results': [
                  {'id': 1, 'title': 'union'},
                ],
                'total_pages': 1,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          if (genres.contains(',')) {
            // AND rung — intersection empty to force fallback down the ladder.
            return http.Response(
              json.encode({'results': const [], 'total_pages': 1}),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          // Per-genre: return 10 rows each, ids offset by genre id.
          final id = int.parse(genres);
          return http.Response(
            json.encode({
              'results': List.generate(
                  10, (i) => {'id': id * 1000 + i, 'title': 'g$id r$i'}),
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752, 36, 18],
        poolFloor: 15,
      );
      final andCalls = calls.where((u) {
        final g = u.queryParameters['with_genres']!;
        return g.contains(',') && !g.contains('|');
      });
      final unionCalls =
          calls.where((u) => u.queryParameters['with_genres']!.contains('|'));
      final perGenreCalls = calls.where((u) {
        final g = u.queryParameters['with_genres']!;
        return !g.contains(',') && !g.contains('|');
      });
      expect(andCalls.length, greaterThanOrEqualTo(1),
          reason: 'rung 1 (AND-join) must fire first for multi-genre');
      expect(unionCalls.length, greaterThanOrEqualTo(1),
          reason: 'rung 2 (OR-join) must fire when rung 1 is short');
      expect(perGenreCalls.length, greaterThanOrEqualTo(1),
          reason: 'rung 3 (per-genre) must fire when rung 2 is still short');
      // Pool should include union row + per-genre rows.
      final ids = (res['results'] as List)
          .map((r) => (r as Map)['id'])
          .toSet();
      expect(ids, contains(1));
      expect(ids.any((i) => (i as int) >= 10752000), isTrue);
    });

    test('per-genre rung does not fire with a single genre id', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'lonely'},
              ],
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752],
        poolFloor: 20,
      );
      // Only one call — rung 2 should not run because there's only one genre.
      // (Rung 3 won't run either: no year bounds.)
      expect(calls, hasLength(1));
    });

    test('results dedup across AND + OR + per-genre rungs', () async {
      // AND and OR both return id=1; per-genre returns id=1 + id=99. Final
      // merged list must contain id=1 only once.
      final tmdb = TmdbService(
        client: MockClient((req) async {
          final g = req.url.queryParameters['with_genres']!;
          Map<String, dynamic> payload;
          if (g.contains('|')) {
            // OR
            payload = {
              'results': [
                {'id': 1, 'title': 'shared'},
              ],
              'total_pages': 1,
            };
          } else if (g.contains(',')) {
            // AND
            payload = {
              'results': [
                {'id': 1, 'title': 'shared (AND)'},
              ],
              'total_pages': 1,
            };
          } else {
            // per-genre
            payload = {
              'results': [
                {'id': 1, 'title': 'shared again'},
                {'id': 99, 'title': 'unique to per-genre'},
              ],
              'total_pages': 1,
            };
          }
          return http.Response(json.encode(payload), 200,
              headers: const {'content-type': 'application/json'});
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752, 36],
        poolFloor: 20,
      );
      final ids =
          (res['results'] as List).map((r) => (r as Map)['id']).toList();
      expect(ids.toSet(), {1, 99});
      expect(ids.length, 2, reason: 'id=1 should not be double-counted');
    });
  });

  group('TmdbService.discoverPaged — rung 3 (drop-year fallback)', () {
    test('retries without year constraint when pool still short', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          final hasYear = req.url.queryParameters
              .containsKey('primary_release_date.gte');
          if (hasYear) {
            return http.Response(
              json.encode({
                'results': [
                  {'id': 1, 'title': 'in-bounds'},
                ],
                'total_pages': 1,
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response(
            json.encode({
              'results': List.generate(
                  20, (i) => {'id': 1000 + i, 'title': 'any year'}),
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752], // single genre → skip rung 2
        minYear: 1970,
        maxYear: 1989,
        poolFloor: 15,
      );
      final yearedCalls = calls.where((u) =>
          u.queryParameters.containsKey('primary_release_date.gte')).toList();
      final unYearedCalls = calls.where((u) =>
          !u.queryParameters.containsKey('primary_release_date.gte')).toList();
      expect(yearedCalls, isNotEmpty);
      expect(unYearedCalls, isNotEmpty,
          reason: 'rung 3 must fire a query without year bounds');
      // Pool should include the in-bounds id=1 plus any-year rows.
      final ids =
          (res['results'] as List).map((r) => (r as Map)['id']).toList();
      expect(ids, contains(1));
      expect(ids.any((id) => (id as int) >= 1000), isTrue);
    });

    test('drop-year rung does not fire when no year bounds were set',
        () async {
      int callCount = 0;
      final tmdb = TmdbService(
        client: MockClient((_) async {
          callCount++;
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'x'},
              ],
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752],
        poolFloor: 20,
      );
      // Single genre + no year: rung 1 AND skips (single), rung 2 OR fires
      // once, rungs 3-6 all skip (single or no-year gated). One call total.
      expect(callCount, 1);
    });

    test('pool below floor after all rungs still returns partial results',
        () async {
      // All rungs fail to reach the floor — we return what we have.
      final tmdb = TmdbService(
        client: MockClient((_) async {
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'lonely'},
              ],
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752],
        minYear: 1900,
        maxYear: 1905,
        poolFloor: 50,
      );
      expect((res['results'] as List), hasLength(1));
    });
  });

  group('TmdbService.discoverPaged — defensive paths', () {
    test('first HTTP error is swallowed; later rungs can still fire',
        () async {
      // First call errors. Subsequent rungs (including the drop-year OR
      // rung) salvage the pool.
      bool firstCall = true;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          if (firstCall) {
            firstCall = false;
            return http.Response('boom', 503);
          }
          return http.Response(
            json.encode({
              'results': [
                {'id': 7, 'title': 'rung-3'},
              ],
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752],
        minYear: 1970,
        maxYear: 1989,
        poolFloor: 50,
      );
      final ids =
          (res['results'] as List).map((r) => (r as Map)['id']).toList();
      expect(ids, [7]);
    });

    test('empty genre list still queries by year alone', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({'results': [], 'total_pages': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        minYear: 1970,
        maxYear: 1989,
      );
      expect(captured!.queryParameters.containsKey('with_genres'), isFalse);
      expect(captured!.queryParameters['primary_release_date.gte'],
          '1970-01-01');
    });

    test('result payload shape matches the normal discover response', () async {
      final tmdb = TmdbService(
        client: MockClient((_) async {
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'x'},
              ],
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final res = await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [10752],
      );
      // buildCandidates reads payload['results'] so that key must exist and
      // be a List of Maps just like the raw /discover response.
      expect(res.keys, contains('results'));
      expect(res['results'], isA<List>());
      expect((res['results'] as List).first, isA<Map>());
    });
  });

  group('TmdbService.discoverPaged — keyword filter (Oscar etc)', () {
    test('joins keywordIds into with_keywords on every paginated call',
        () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'A'},
              ],
              'total_pages': 3,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        keywordIds: const [210024],
        poolFloor: 3,
      );
      // Every page request must carry with_keywords — dropping it on a
      // fallback rung would silently widen the pool to non-Oscar titles.
      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.queryParameters['with_keywords'], '210024',
            reason: 'oscar keyword must survive every retry rung');
      }
    });

    test('omits with_keywords when keywordIds is empty (no regression)',
        () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': List.generate(40, (i) => {'id': i, 'title': 'X'}),
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(mediaType: 'movie', genreIds: const [28]);
      expect(calls.first.queryParameters.containsKey('with_keywords'), isFalse);
    });
  });

  group('TmdbService.discoverPaged — excludeGenreIds (no-animation etc)', () {
    test('joins excludeGenreIds into without_genres on every paginated call',
        () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'A'},
              ],
              'total_pages': 3,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [80], // Crime
        keywordIds: const [210024], // Oscar
        excludeGenreIds: const [16], // Animation
        poolFloor: 3,
      );
      // Every page request must carry without_genres — dropping it on a
      // fallback rung would silently let animated titles back into the pool.
      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.queryParameters['without_genres'], '16',
            reason: 'excludeGenreIds must survive every retry rung');
      }
    });

    test('omits without_genres when excludeGenreIds is empty', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({
              'results': List.generate(40, (i) => {'id': i, 'title': 'X'}),
              'total_pages': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(mediaType: 'movie', genreIds: const [28]);
      expect(captured!.queryParameters.containsKey('without_genres'), isFalse);
    });

    test('comma-joins multiple exclude ids', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({'results': [], 'total_pages': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        excludeGenreIds: const [16, 99], // Animation, Documentary
      );
      // TMDB's /discover treats without_genres as comma-AND (exclude all).
      expect(captured!.queryParameters['without_genres'], '16,99');
    });
  });

  group('TmdbService.discoverPaged — sortBy override', () {
    test('forwards sortBy param verbatim on every paginated call', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'A'},
              ],
              'total_pages': 3,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [28],
        sortBy: 'popularity.desc',
        poolFloor: 3,
      );
      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.queryParameters['sort_by'], 'popularity.desc',
            reason: 'sort override must survive every retry rung');
      }
    });

    test('defaults to vote_average.desc when sortBy omitted', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({'results': [], 'total_pages': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(mediaType: 'movie', genreIds: const [28]);
      expect(captured!.queryParameters['sort_by'], 'vote_average.desc');
    });
  });

  group('TmdbService.discoverPaged — maxVoteCount (Underseen)', () {
    test('emits vote_count.lte on every rung when set', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'A'},
              ],
              'total_pages': 3,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        genreIds: const [28],
        maxVoteCount: 500,
        poolFloor: 3,
      );
      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.queryParameters['vote_count.lte'], '500',
            reason: 'Underseen ceiling must survive every retry rung');
      }
    });

    test('omits vote_count.lte when maxVoteCount null', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({'results': [], 'total_pages': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(mediaType: 'movie', genreIds: const [28]);
      expect(captured!.queryParameters.containsKey('vote_count.lte'), isFalse);
    });
  });

  group('TmdbService.discoverPaged — withCompanies (Criterion)', () {
    test('forwards with_companies on every paginated call', () async {
      final calls = <Uri>[];
      final tmdb = TmdbService(
        client: MockClient((req) async {
          calls.add(req.url);
          return http.Response(
            json.encode({
              'results': [
                {'id': 1, 'title': 'A'},
              ],
              'total_pages': 3,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(
        mediaType: 'movie',
        withCompanies: '1771', // Criterion
        poolFloor: 3,
      );
      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.queryParameters['with_companies'], '1771',
            reason: 'curated-source company filter must survive every rung');
      }
    });

    test('omits with_companies when null or empty', () async {
      Uri? captured;
      final tmdb = TmdbService(
        client: MockClient((req) async {
          captured ??= req.url;
          return http.Response(
            json.encode({'results': [], 'total_pages': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      await tmdb.discoverPaged(mediaType: 'movie', genreIds: const [28]);
      expect(captured!.queryParameters.containsKey('with_companies'), isFalse);
    });
  });
}
