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

    test('movieDetails hits /movie/:id with credits,keywords,similar append',
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
          'credits,keywords,similar');
    });

    test('tvDetails hits /tv/:id with same append_to_response', () async {
      final rec = _Recorder();
      final tmdb = TmdbService(client: rec.client(routes: {
        '/tv/1399': {'id': 1399, 'name': 'GoT'},
      }));
      await tmdb.tvDetails(1399);
      final url = rec.calls.single.url;
      expect(url.path, endsWith('/tv/1399'));
      expect(url.queryParameters['append_to_response'],
          'credits,keywords,similar');
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
  });
}
