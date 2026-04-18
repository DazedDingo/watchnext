import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/providers/discover_provider.dart';
import 'package:watchnext/providers/tmdb_provider.dart';
import 'package:watchnext/services/tmdb_service.dart';

void main() {
  group('discoverByGenreProvider', () {
    test('hits /discover/movie with the supplied genreId and parses results',
        () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        return http.Response(
          json.encode({
            'results': [
              {'id': 123, 'poster_path': '/p.jpg'},
              {'id': 456, 'poster_path': '/q.jpg'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      final result = await container.read(discoverByGenreProvider(28).future);

      expect(result, hasLength(2));
      expect(result.first['id'], 123);
      expect(calls, hasLength(1));
      expect(calls.single.path, endsWith('/discover/movie'));
      expect(calls.single.queryParameters['with_genres'], '28');
      expect(calls.single.queryParameters['sort_by'], 'popularity.desc');
    });

    test('returns an empty list when results key missing', () async {
      final client = MockClient((_) async => http.Response('{}', 200,
          headers: const {'content-type': 'application/json'}));
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      final result = await container.read(discoverByGenreProvider(99).future);
      expect(result, isEmpty);
    });

    test('different genre ids hit the API independently (family caching)',
        () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        return http.Response(json.encode({'results': []}), 200,
            headers: const {'content-type': 'application/json'});
      });
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      await container.read(discoverByGenreProvider(28).future);
      await container.read(discoverByGenreProvider(35).future);
      await container.read(discoverByGenreProvider(28).future); // cached

      expect(calls, hasLength(2));
      expect(calls[0].queryParameters['with_genres'], '28');
      expect(calls[1].queryParameters['with_genres'], '35');
    });
  });
}
