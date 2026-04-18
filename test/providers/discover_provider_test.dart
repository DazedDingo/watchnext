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

  group('searchResultsProvider', () {
    test('empty query short-circuits — no network call, empty list', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      final result = await container.read(searchResultsProvider.future);
      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('whitespace-only query is treated as empty', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      container.read(searchQueryProvider.notifier).state = '   ';
      final result = await container.read(searchResultsProvider.future);
      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('non-empty query hits /search/multi and filters out people',
        () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        return http.Response(
          json.encode({
            'results': [
              {'id': 1, 'media_type': 'movie', 'title': 'Matrix'},
              {'id': 2, 'media_type': 'person', 'name': 'Keanu Reeves'},
              {'id': 3, 'media_type': 'tv', 'name': 'Matrix TV'},
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

      container.read(searchQueryProvider.notifier).state = 'matrix';
      final result = await container.read(searchResultsProvider.future);

      expect(calls, hasLength(1));
      expect(calls.single.path, endsWith('/search/multi'));
      expect(calls.single.queryParameters['query'], 'matrix');
      expect(result, hasLength(2));
      expect(result.map((r) => r['media_type']), ['movie', 'tv']);
    });

    test('changing query re-runs the search', () async {
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

      container.read(searchQueryProvider.notifier).state = 'foo';
      await container.read(searchResultsProvider.future);
      container.read(searchQueryProvider.notifier).state = 'bar';
      await container.read(searchResultsProvider.future);

      expect(calls, hasLength(2));
      expect(calls[0].queryParameters['query'], 'foo');
      expect(calls[1].queryParameters['query'], 'bar');
    });

    test('tab/newline-only query is treated as empty', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      container.read(searchQueryProvider.notifier).state = '\t\n  \r';
      final result = await container.read(searchResultsProvider.future);
      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('special characters and emoji are URL-encoded into query param',
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

      const nasty = 'a&b=c?d#e 🎬 "quoted"';
      container.read(searchQueryProvider.notifier).state = nasty;
      await container.read(searchResultsProvider.future);

      expect(calls, hasLength(1));
      // queryParameters decodes — round-trip should match the raw string.
      expect(calls.single.queryParameters['query'], nasty);
    });

    test('very long query (2 KB) still goes through unchanged', () async {
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

      final long = 'x' * 2048;
      container.read(searchQueryProvider.notifier).state = long;
      await container.read(searchResultsProvider.future);

      expect(calls.single.queryParameters['query'], long);
    });

    test('null results key falls back to empty list', () async {
      final client = MockClient((_) async => http.Response(
          json.encode({'results': null}), 200,
          headers: const {'content-type': 'application/json'}));
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      container.read(searchQueryProvider.notifier).state = 'matrix';
      final result = await container.read(searchResultsProvider.future);
      expect(result, isEmpty);
    });

    test('missing media_type is kept (not filtered) — only "person" is dropped',
        () async {
      final client = MockClient((_) async => http.Response(
          json.encode({
            'results': [
              {'id': 1, 'title': 'No media_type'},
              {'id': 2, 'media_type': 'person', 'name': 'Filtered'},
              {'id': 3, 'media_type': 'movie'},
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'}));
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      container.read(searchQueryProvider.notifier).state = 'q';
      final result = await container.read(searchResultsProvider.future);

      expect(result.map((r) => r['id']).toList(), [1, 3]);
    });

    test('TMDB 500 surfaces as an AsyncError, does not crash', () async {
      final client = MockClient(
          (_) async => http.Response('{"status_message":"boom"}', 500));
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      container.read(searchQueryProvider.notifier).state = 'matrix';
      await expectLater(
        container.read(searchResultsProvider.future),
        throwsA(isA<Exception>()),
      );
    });

    test('rapid query changes — only the latest value drives the result',
        () async {
      final calls = <Uri>[];
      final client = MockClient((req) async {
        calls.add(req.url);
        final q = req.url.queryParameters['query'] ?? '';
        return http.Response(
          json.encode({
            'results': [
              {'id': q.hashCode, 'media_type': 'movie', 'title': q},
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

      // Fire three state changes back-to-back without awaiting in between.
      container.read(searchQueryProvider.notifier).state = 'a';
      container.read(searchQueryProvider.notifier).state = 'ab';
      container.read(searchQueryProvider.notifier).state = 'abc';

      final result = await container.read(searchResultsProvider.future);
      expect(result.single['title'], 'abc');
      // The provider is only built once (lazily, on first read), so only the
      // final query value should reach TMDB.
      expect(calls.map((c) => c.queryParameters['query']).toList(), ['abc']);
    });

    test('clearing back to empty short-circuits — no extra network call',
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

      container.read(searchQueryProvider.notifier).state = 'foo';
      await container.read(searchResultsProvider.future);
      container.read(searchQueryProvider.notifier).state = '';
      final result = await container.read(searchResultsProvider.future);

      expect(result, isEmpty);
      expect(calls, hasLength(1)); // Only the 'foo' call hit the wire.
    });
  });

  group('discoverByGenreProvider — adversarial', () {
    test('non-200 response surfaces as AsyncError', () async {
      final client = MockClient((_) async => http.Response('nope', 503));
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      await expectLater(
        container.read(discoverByGenreProvider(28).future),
        throwsA(isA<Exception>()),
      );
    });

    test('null results key falls back to empty list', () async {
      final client = MockClient((_) async => http.Response(
          json.encode({'results': null}), 200,
          headers: const {'content-type': 'application/json'}));
      final container = ProviderContainer(overrides: [
        tmdbServiceProvider.overrideWithValue(TmdbService(client: client)),
      ]);
      addTearDown(container.dispose);

      final result = await container.read(discoverByGenreProvider(28).future);
      expect(result, isEmpty);
    });
  });
}
