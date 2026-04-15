import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/services/trakt_service.dart';

/// Covers the HTTP-only surface of TraktService. Methods that hit
/// FirebaseFunctions (exchangeCode / refreshToken / revoke) are not reached
/// here — those are proxied through Cloud Functions which have their own
/// TypeScript test coverage.
class _Recorder {
  final List<http.Request> calls = [];
  http.Client build({
    required Map<Pattern, http.Response Function(http.Request)> routes,
  }) {
    return MockClient((req) async {
      calls.add(req);
      for (final entry in routes.entries) {
        final p = entry.key;
        final match = p is RegExp
            ? p.hasMatch(req.url.toString())
            : req.url.path.endsWith(p.toString());
        if (match) return entry.value(req);
      }
      return http.Response('no mock for ${req.url}', 404);
    });
  }
}

void main() {
  group('TraktService.fetchHistory', () {
    test('paginates until x-pagination-page-count is reached', () async {
      final rec = _Recorder();
      http.Response handle(http.Request req) {
        final page = req.url.queryParameters['page'] ?? '1';
        final body = page == '1'
            ? [
                {'type': 'movie', 'id': 1},
                {'type': 'movie', 'id': 2},
              ]
            : [
                {'type': 'movie', 'id': 3},
              ];
        return http.Response(
          json.encode(body),
          200,
          headers: {
            'content-type': 'application/json',
            'x-pagination-page-count': '2',
          },
        );
      }

      final trakt = TraktService(
        client: rec.build(routes: {'/sync/history/movies': handle}),
        db: FakeFirebaseFirestore(),
      );
      final rows = await trakt.fetchHistory(token: 'T', type: 'movies');
      expect(rows, hasLength(3));
      expect(rec.calls, hasLength(2));
      expect(rec.calls[0].url.queryParameters['page'], '1');
      expect(rec.calls[1].url.queryParameters['page'], '2');
    });

    test('stops early when an empty page arrives', () async {
      final rec = _Recorder();
      http.Response handle(http.Request req) => http.Response(
            json.encode(const <dynamic>[]),
            200,
            headers: {
              'content-type': 'application/json',
              'x-pagination-page-count': '5',
            },
          );
      final trakt = TraktService(
        client: rec.build(routes: {'/sync/history/shows': handle}),
        db: FakeFirebaseFirestore(),
      );
      final rows = await trakt.fetchHistory(token: 'T', type: 'shows');
      expect(rows, isEmpty);
      expect(rec.calls, hasLength(1));
    });

    test('sends start_at when provided, omits it when null', () async {
      final rec = _Recorder();
      http.Response handle(_) => http.Response(
            json.encode(const <dynamic>[]),
            200,
            headers: {
              'content-type': 'application/json',
              'x-pagination-page-count': '1',
            },
          );
      final trakt = TraktService(
        client: rec.build(routes: {'/sync/history/movies': handle}),
        db: FakeFirebaseFirestore(),
      );
      await trakt.fetchHistory(token: 'T', type: 'movies');
      expect(rec.calls.single.url.queryParameters.containsKey('start_at'),
          isFalse);

      rec.calls.clear();
      await trakt.fetchHistory(
        token: 'T',
        type: 'movies',
        startAt: DateTime.utc(2025, 1, 1, 12),
      );
      expect(rec.calls.single.url.queryParameters['start_at'],
          '2025-01-01T12:00:00.000Z');
    });

    test('non-200 response throws with status and body', () async {
      final trakt = TraktService(
        client: MockClient((_) async => http.Response('nope', 429)),
        db: FakeFirebaseFirestore(),
      );
      expect(
        () => trakt.fetchHistory(token: 'T', type: 'movies'),
        throwsA(predicate(
            (e) => e.toString().contains('429') && e.toString().contains('nope'))),
      );
    });
  });

  group('TraktService.fetchRatings', () {
    test('returns parsed list for each type', () async {
      final rec = _Recorder();
      final trakt = TraktService(
        client: rec.build(routes: {
          '/sync/ratings/movies': (_) => http.Response(
              json.encode([
                {'movie': {'ids': {'trakt': 1}}, 'rating': 8},
              ]),
              200,
              headers: const {'content-type': 'application/json'}),
        }),
        db: FakeFirebaseFirestore(),
      );
      final rows = await trakt.fetchRatings(token: 'T', type: 'movies');
      expect(rows, hasLength(1));
      expect(rows.first['rating'], 8);
      expect(rec.calls.single.url.path, endsWith('/sync/ratings/movies'));
      expect(rec.calls.single.url.queryParameters['extended'], 'full');
    });
  });

  group('TraktService.pushRating (RatingPusher impl)', () {
    test('maps 1-5 stars onto 1-10 Trakt scale (ceil doubled)', () async {
      final rec = _Recorder();
      final trakt = TraktService(
        client: rec.build(routes: {
          '/sync/ratings': (_) => http.Response('{}', 201),
        }),
        db: FakeFirebaseFirestore(),
      );
      for (final pair in const [
        [1, 2],
        [2, 4],
        [3, 6],
        [4, 8],
        [5, 10],
      ]) {
        rec.calls.clear();
        await trakt.pushRating(
          token: 'T',
          level: 'movie',
          traktRef: {'ids': {'trakt': 1}},
          stars: pair[0],
        );
        final body =
            json.decode(rec.calls.single.body) as Map<String, dynamic>;
        expect((body['movies'] as List).single['rating'], pair[1]);
      }
    });

    test('routes to the correct body key per level', () async {
      final rec = _Recorder();
      final trakt = TraktService(
        client: rec.build(routes: {
          '/sync/ratings': (_) => http.Response('{}', 201),
        }),
        db: FakeFirebaseFirestore(),
      );
      for (final pair in const [
        ['movie', 'movies'],
        ['show', 'shows'],
        ['season', 'seasons'],
        ['episode', 'episodes'],
      ]) {
        rec.calls.clear();
        await trakt.pushRating(
          token: 'T',
          level: pair[0],
          traktRef: {'ids': {'trakt': 1}},
          stars: 3,
        );
        final body =
            json.decode(rec.calls.single.body) as Map<String, dynamic>;
        expect(body.keys.single, pair[1]);
      }
    });

    test('bad level throws ArgumentError before hitting the network',
        () async {
      final rec = _Recorder();
      final trakt = TraktService(
        client: rec.build(routes: const {}),
        db: FakeFirebaseFirestore(),
      );
      expect(
        () => trakt.pushRating(
          token: 'T',
          level: 'bogus',
          traktRef: {'ids': {'trakt': 1}},
          stars: 3,
        ),
        throwsArgumentError,
      );
      expect(rec.calls, isEmpty);
    });

    test('non-2xx response surfaces as exception', () async {
      final trakt = TraktService(
        client: MockClient((_) async => http.Response('rate limited', 429)),
        db: FakeFirebaseFirestore(),
      );
      expect(
        () => trakt.pushRating(
          token: 'T',
          level: 'movie',
          traktRef: {'ids': {'trakt': 1}},
          stars: 3,
        ),
        throwsA(predicate((e) => e.toString().contains('429'))),
      );
    });

    test('sends required Trakt headers', () async {
      final rec = _Recorder();
      final trakt = TraktService(
        client: rec.build(routes: {
          '/sync/ratings': (_) => http.Response('{}', 201),
        }),
        db: FakeFirebaseFirestore(),
      );
      await trakt.pushRating(
        token: 'T',
        level: 'movie',
        traktRef: {'ids': {'trakt': 1}},
        stars: 3,
      );
      final h = rec.calls.single.headers;
      expect(h['authorization'], 'Bearer T');
      expect(h['trakt-api-version'], '2');
      expect(h.containsKey('trakt-api-key'), isTrue);
      expect(h['content-type'], contains('application/json'));
    });
  });

  group('TraktService.isConfigured', () {
    test('reflects whether TRAKT_CLIENT_ID was passed at build', () {
      // Under `flutter test` without --dart-define, this is the empty string
      // so isConfigured is false. The production APK is built with it set.
      expect(TraktService.isConfigured, isFalse);
    });
  });
}
