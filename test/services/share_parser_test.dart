import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/services/share_parser.dart';
import 'package:watchnext/services/tmdb_service.dart';

/// Returns a TmdbService wired to a canned-response http client. Each request
/// path is matched against [routes]; a missing match fails loudly so we never
/// accidentally assert on an unexpected endpoint.
TmdbService _tmdb(Map<String, Map<String, dynamic>> routes) {
  final client = MockClient((req) async {
    for (final entry in routes.entries) {
      if (req.url.path.endsWith(entry.key)) {
        return http.Response(json.encode(entry.value), 200,
            headers: {'content-type': 'application/json'});
      }
    }
    return http.Response('not mocked: ${req.url}', 404);
  });
  return TmdbService(client: client);
}

void main() {
  group('ShareMatch.fromTmdb', () {
    test('parses movie shape with release_date', () {
      final m = ShareMatch.fromTmdb({
        'id': 42,
        'title': 'The Matrix',
        'release_date': '1999-03-31',
        'poster_path': '/m.jpg',
        'overview': 'hackers',
      }, 'movie');
      expect(m.tmdbId, 42);
      expect(m.title, 'The Matrix');
      expect(m.year, 1999);
      expect(m.posterPath, '/m.jpg');
      expect(m.overview, 'hackers');
      expect(m.mediaType, 'movie');
    });

    test('parses tv shape with first_air_date', () {
      final m = ShareMatch.fromTmdb({
        'id': 1399,
        'name': 'Game of Thrones',
        'first_air_date': '2011-04-17',
      }, 'tv');
      expect(m.title, 'Game of Thrones');
      expect(m.year, 2011);
      expect(m.mediaType, 'tv');
    });

    test('year is null when date is missing or too short', () {
      final a = ShareMatch.fromTmdb({'id': 1, 'title': 'X'}, 'movie');
      expect(a.year, isNull);
      final b = ShareMatch.fromTmdb(
          {'id': 1, 'title': 'X', 'release_date': ''}, 'movie');
      expect(b.year, isNull);
    });
  });

  group('ShareParser.parse', () {
    test('returns null for empty or whitespace input', () async {
      final p = ShareParser(tmdb: _tmdb({}));
      expect(await p.parse(''), isNull);
      expect(await p.parse('   '), isNull);
    });

    test('TMDB movie URL resolves directly via /movie/:id', () async {
      final tmdb = _tmdb({
        '/movie/603': {
          'id': 603,
          'title': 'The Matrix',
          'release_date': '1999-03-31',
          'poster_path': '/m.jpg',
        },
      });
      final p = ShareParser(tmdb: tmdb);
      final m = await p.parse('https://www.themoviedb.org/movie/603-the-matrix');
      expect(m, isNotNull);
      expect(m!.tmdbId, 603);
      expect(m.title, 'The Matrix');
      expect(m.mediaType, 'movie');
    });

    test('TMDB tv URL resolves directly via /tv/:id', () async {
      final tmdb = _tmdb({
        '/tv/1399': {
          'id': 1399,
          'name': 'Game of Thrones',
          'first_air_date': '2011-04-17',
        },
      });
      final p = ShareParser(tmdb: tmdb);
      final m = await p.parse('Check this: https://www.themoviedb.org/tv/1399');
      expect(m!.mediaType, 'tv');
      expect(m.tmdbId, 1399);
      expect(m.title, 'Game of Thrones');
    });

    test('IMDb title URL resolves via /find/:ttid', () async {
      final tmdb = _tmdb({
        '/find/tt0133093': {
          'movie_results': [
            {
              'id': 603,
              'title': 'The Matrix',
              'release_date': '1999-03-31',
            },
          ],
          'tv_results': [],
        },
      });
      final p = ShareParser(tmdb: tmdb);
      final m = await p.parse('https://www.imdb.com/title/tt0133093/');
      expect(m!.tmdbId, 603);
      expect(m.title, 'The Matrix');
    });

    test('Letterboxd film slug falls back to TMDB search', () async {
      final tmdb = _tmdb({
        '/search/multi': {
          'results': [
            {
              'id': 603,
              'media_type': 'movie',
              'title': 'The Matrix',
              'release_date': '1999-03-31',
            },
          ],
        },
      });
      final p = ShareParser(tmdb: tmdb);
      final m = await p.parse('https://letterboxd.com/film/the-matrix/');
      expect(m!.mediaType, 'movie');
      expect(m.tmdbId, 603);
    });

    test('freeform text falls back to search', () async {
      final tmdb = _tmdb({
        '/search/multi': {
          'results': [
            {
              'id': 42,
              'media_type': 'movie',
              'title': 'The Answer',
              'release_date': '2001-01-01',
            },
          ],
        },
      });
      final p = ShareParser(tmdb: tmdb);
      final m = await p.parse('anybody seen The Answer?');
      expect(m!.tmdbId, 42);
      expect(m.title, 'The Answer');
    });

    test('person results are skipped in search fallback', () async {
      final tmdb = _tmdb({
        '/search/multi': {
          'results': [
            {'id': 500, 'media_type': 'person', 'name': 'Tom Cruise'},
            {
              'id': 42,
              'media_type': 'movie',
              'title': 'Mission',
              'release_date': '1996-01-01',
            },
          ],
        },
      });
      final p = ShareParser(tmdb: tmdb);
      final m = await p.parse('Tom Cruise');
      expect(m!.title, 'Mission');
      expect(m.mediaType, 'movie');
    });

    test('IMDb without matches returns null', () async {
      final tmdb = _tmdb({
        '/find/tt9999999': {'movie_results': [], 'tv_results': []},
      });
      final p = ShareParser(tmdb: tmdb);
      expect(await p.parse('https://www.imdb.com/title/tt9999999/'), isNull);
    });
  });

  group('TmdbService.imageUrl', () {
    test('returns null for null or empty path', () {
      expect(TmdbService.imageUrl(null), isNull);
      expect(TmdbService.imageUrl(''), isNull);
    });

    test('builds the w500 URL by default', () {
      expect(TmdbService.imageUrl('/m.jpg'),
          'https://image.tmdb.org/t/p/w500/m.jpg');
    });

    test('honors an explicit size', () {
      expect(TmdbService.imageUrl('/m.jpg', size: 'w342'),
          'https://image.tmdb.org/t/p/w342/m.jpg');
      expect(TmdbService.imageUrl('/m.jpg', size: 'original'),
          'https://image.tmdb.org/t/p/original/m.jpg');
    });
  });
}
