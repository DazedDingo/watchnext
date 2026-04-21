import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/decide_provider.dart';
import 'package:watchnext/services/recommendations_service.dart';
import 'package:watchnext/services/tmdb_service.dart';

/// `rerollCandidates` must (a) swap out the current five candidates without
/// wiping session state like picks/vetoes and (b) keep exclusions in-memory
/// only — a separate concern from the Decided-screen `reroll` that swaps a
/// single winner.
void main() {
  WatchlistItem watchlistItem(int id, String title, {int? year}) =>
      WatchlistItem(
        id: 'movie:$id',
        mediaType: 'movie',
        tmdbId: id,
        title: title,
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
        year: year,
      );

  TmdbService tmdbFor({Map<String, dynamic>? trending}) {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/trending/movie/week')) {
        return http.Response(json.encode(trending ?? {'results': []}), 200,
            headers: const {'content-type': 'application/json'});
      }
      return http.Response('not mocked: ${req.url}', 404);
    });
    return TmdbService(client: client);
  }

  DecideController controllerFor(TmdbService tmdb) {
    final recs = RecommendationsService(db: FakeFirebaseFirestore(), tmdb: tmdb);
    return DecideController(tmdb, recs, null);
  }

  group('rerollCandidates', () {
    test('swaps current five for the next five from the watchlist', () async {
      final tmdb = tmdbFor();
      final ctrl = controllerFor(tmdb);
      final watchlist = List.generate(10, (i) => watchlistItem(i, 'Title $i'));

      await ctrl.start(watchlist);
      final firstBatch = ctrl.state.candidates.map((c) => c.key).toList();
      expect(firstBatch, hasLength(5));

      await ctrl.rerollCandidates(watchlist);
      final secondBatch = ctrl.state.candidates.map((c) => c.key).toList();

      expect(secondBatch, hasLength(5));
      // None of the shuffled-out titles come back.
      expect(secondBatch.toSet().intersection(firstBatch.toSet()), isEmpty);
    });

    test('tops up from TMDB trending when watchlist is exhausted', () async {
      final tmdb = tmdbFor(trending: {
        'results': List.generate(10, (i) => {
              'id': 500 + i,
              'title': 'Trend $i',
              'media_type': 'movie',
            }),
      });
      final ctrl = controllerFor(tmdb);
      // Only 3 watchlist items — below the 5-candidate floor both times.
      final watchlist =
          List.generate(3, (i) => watchlistItem(i, 'Title $i'));

      await ctrl.start(watchlist);
      await ctrl.rerollCandidates(watchlist);

      final keys = ctrl.state.candidates.map((c) => c.key).toList();
      expect(keys, hasLength(5));
      // Watchlist items (0, 1, 2) were consumed by start(); reroll must find
      // only trending entries.
      for (final k in keys) {
        expect(k.startsWith('movie:5'), isTrue,
            reason: '$k should be a trending row (id 500+)');
      }
    });

    test('sets an error when nothing new is available', () async {
      final tmdb = tmdbFor(); // empty trending
      final ctrl = controllerFor(tmdb);
      final watchlist = List.generate(5, (i) => watchlistItem(i, 'Title $i'));

      await ctrl.start(watchlist);
      final originalBatch = ctrl.state.candidates.map((c) => c.key).toList();

      await ctrl.rerollCandidates(watchlist);

      expect(ctrl.state.error, isNotNull);
      // Existing pool stays put so the user can still pick from it.
      expect(ctrl.state.candidates.map((c) => c.key).toList(), originalBatch);
    });

    test('keeps session state (picks, vetoes) intact', () async {
      final tmdb = tmdbFor();
      final ctrl = controllerFor(tmdb);
      final watchlist = List.generate(10, (i) => watchlistItem(i, 'Title $i'));

      await ctrl.start(watchlist);
      // Pre-seed some session state that reroll must not touch. vetoes live
      // on DecideSessionState; we mutate via the controller's public surface
      // where possible, but picks are the simplest check.
      final first = ctrl.state.candidates.first;
      ctrl.submitPickA(first);
      expect(ctrl.state.pickA, isNotNull);

      await ctrl.rerollCandidates(watchlist);

      // pickA survives a candidate reroll — this distinguishes it from
      // `reset()` which would wipe everything.
      expect(ctrl.state.pickA, isNotNull);
      expect(ctrl.state.pickA!.key, first.key);
    });

    test('honors watchedKeys — watched titles never reappear', () async {
      final tmdb = tmdbFor();
      final ctrl = controllerFor(tmdb);
      final watchlist = List.generate(10, (i) => watchlistItem(i, 'Title $i'));
      final watched = {'movie:5', 'movie:6', 'movie:7'};

      await ctrl.start(watchlist, watchedKeys: watched);
      await ctrl.rerollCandidates(watchlist, watchedKeys: watched);

      final keys = ctrl.state.candidates.map((c) => c.key).toSet();
      expect(keys.intersection(watched), isEmpty);
    });
  });
}
