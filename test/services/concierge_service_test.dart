import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/models/concierge_turn.dart';
import 'package:watchnext/services/concierge_service.dart';
import 'package:watchnext/services/tmdb_service.dart';

/// Covers the Firestore-only surface of ConciergeService. The CF-backed
/// `chat` method is exercised via the functions/test suite (helpers) and
/// rules emulator — here we just verify the history stream contract.
void main() {
  group('ConciergeService.historyStream', () {
    late FakeFirebaseFirestore db;
    late ConciergeService svc;
    const hh = 'hh1';

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = ConciergeService(db: db);
    });

    test('emits empty list when no history exists', () async {
      final events = [];
      final sub = svc.historyStream(hh, 's1').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(events.first, isEmpty);
    });

    test('filters by session_id', () async {
      final col = db.collection('households/$hh/conciergeHistory');
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'in-session',
        'response_text': 'r',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      await col.add({
        'uid': 'u1',
        'session_id': 's2',
        'message': 'other-session',
        'response_text': 'r',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 2)),
      });
      final events = [];
      final sub = svc.historyStream(hh, 's1').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(events.last, hasLength(1));
      expect(events.last.first.message, 'in-session');
    });

    test('orders oldest-first by created_at', () async {
      final col = db.collection('households/$hh/conciergeHistory');
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'second',
        'response_text': '',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 5)),
      });
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'first',
        'response_text': '',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final events = [];
      final sub = svc.historyStream(hh, 's1').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      final last = events.last as List;
      expect(last.map((t) => t.message), ['first', 'second']);
    });

    test('verifyTitles replaces hallucinated tmdb_id with real search hit',
        () async {
      // Claude claims "The Shining" with the wrong id (e.g., Ice Age's).
      // TMDB search should return the real Shining id + poster.
      final tmdb = TmdbService(
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/search/multi'));
          return http.Response(
            json.encode({
              'results': [
                {
                  'id': 694,
                  'media_type': 'movie',
                  'title': 'The Shining',
                  'release_date': '1980-05-23',
                  'poster_path': '/shining.jpg',
                },
                {
                  'id': 12345,
                  'media_type': 'movie',
                  'title': 'Shining Unrelated',
                  'release_date': '2001-01-01',
                  'poster_path': '/other.jpg',
                },
              ],
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );
      final svc = ConciergeService(db: db, tmdb: tmdb);
      final verified = await svc.verifyTitles(const [
        TitleSuggestion(
          tmdbId: 8425,
          mediaType: 'movie',
          title: 'The Shining',
          year: 1980,
          reason: 'classic horror',
        ),
      ]);
      expect(verified, hasLength(1));
      expect(verified.first.tmdbId, 694);
      expect(verified.first.posterPath, '/shining.jpg');
      expect(verified.first.title, 'The Shining');
    });

    test('verifyTitles drops suggestions TMDB cannot resolve', () async {
      final tmdb = TmdbService(
        client: MockClient((_) async => http.Response(
              json.encode({'results': []}),
              200,
              headers: const {'content-type': 'application/json'},
            )),
      );
      final svc = ConciergeService(db: db, tmdb: tmdb);
      final verified = await svc.verifyTitles(const [
        TitleSuggestion(
          tmdbId: 1,
          mediaType: 'movie',
          title: 'Nonsense Title 9q8w7e',
          year: 2099,
          reason: '',
        ),
      ]);
      expect(verified, isEmpty);
    });

    test('verifyTitles prefers year-matching result when available', () async {
      final tmdb = TmdbService(
        client: MockClient((_) async => http.Response(
              json.encode({
                'results': [
                  {
                    'id': 10,
                    'media_type': 'movie',
                    'title': 'Dune',
                    'release_date': '1984-12-14',
                    'poster_path': '/old.jpg',
                  },
                  {
                    'id': 438631,
                    'media_type': 'movie',
                    'title': 'Dune',
                    'release_date': '2021-09-15',
                    'poster_path': '/new.jpg',
                  },
                ],
              }),
              200,
              headers: const {'content-type': 'application/json'},
            )),
      );
      final svc = ConciergeService(db: db, tmdb: tmdb);
      final verified = await svc.verifyTitles(const [
        TitleSuggestion(
          tmdbId: 999,
          mediaType: 'movie',
          title: 'Dune',
          year: 2021,
          reason: '',
        ),
      ]);
      expect(verified.single.tmdbId, 438631);
      expect(verified.single.posterPath, '/new.jpg');
    });

    test('new message mid-stream propagates', () async {
      final col = db.collection('households/$hh/conciergeHistory');
      final events = <List>[];
      final sub = svc
          .historyStream(hh, 's1')
          .listen((e) => events.add(e as List));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'live',
        'response_text': '',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(events.last.length, 1);
      expect(events.last.first.message, 'live');
    });
  });
}
