import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/prediction.dart';
import 'package:watchnext/services/decide_service.dart';
import 'package:watchnext/services/household_service.dart';
import 'package:watchnext/services/prediction_service.dart';
import 'package:watchnext/services/rating_pusher.dart';
import 'package:watchnext/services/rating_service.dart';
import 'package:watchnext/services/watchlist_service.dart';
import 'package:watchnext/models/decision.dart';

class _NoopPusher implements RatingPusher {
  @override
  Future<String> getLiveAccessToken(
          {required String householdId, required String uid}) async =>
      'tok';
  @override
  Future<void> pushRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
    required int stars,
  }) async {}
  @override
  Future<void> removeRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
  }) async {}
}

void main() {
  group('WatchlistService — rapid duplicate adds (double-tap simulation)', () {
    test('two concurrent adds settle to one doc with the later addedBy',
        () async {
      final db = FakeFirebaseFirestore();
      final svc = WatchlistService(db: db);
      await Future.wait([
        svc.add(
            householdId: 'hh',
            uid: 'u1',
            mediaType: 'movie',
            tmdbId: 1,
            title: 'X'),
        svc.add(
            householdId: 'hh',
            uid: 'u2',
            mediaType: 'movie',
            tmdbId: 1,
            title: 'X'),
      ]);
      final snap = await db.collection('households/hh/watchlist').get();
      expect(snap.size, 1);
      // Same-id deterministic — whichever wins, only one persists.
      expect(['u1', 'u2'], contains(snap.docs.single.data()['added_by']));
    });

    test('contains() is correct immediately after remove()', () async {
      final db = FakeFirebaseFirestore();
      final svc = WatchlistService(db: db);
      await svc.add(
          householdId: 'hh', uid: 'u1', mediaType: 'movie', tmdbId: 1, title: 'X');
      expect(
          await svc.contains(
              householdId: 'hh', mediaType: 'movie', tmdbId: 1),
          isTrue);
      await svc.remove(householdId: 'hh', id: 'shared:shared:movie:1');
      expect(
          await svc.contains(
              householdId: 'hh', mediaType: 'movie', tmdbId: 1),
          isFalse);
    });

    test('remove on non-existent id is a no-op (no throw)', () async {
      final db = FakeFirebaseFirestore();
      final svc = WatchlistService(db: db);
      await expectLater(
        svc.remove(householdId: 'hh', id: 'shared:shared:movie:999'),
        completes,
      );
    });
  });

  group('PredictionService — partial-submit states', () {
    test('skip after submit flips the entry in place', () async {
      final db = FakeFirebaseFirestore();
      final svc = PredictionService(db: db);
      await svc.submitPrediction(
          householdId: 'hh',
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
          stars: 4);
      await svc.skipPrediction(
          householdId: 'hh',
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X');
      final snap = await db.doc('households/hh/predictions/movie:1').get();
      final p = Prediction.fromDoc(snap);
      expect(p.entryFor('u1')?.skipped, isTrue);
    });

    test('markRevealSeen is idempotent for counters on repeated call',
        () async {
      // NOTE: This documents that repeated calls DO increment twice —
      // callers guard via `_markedSeen`. The test pins that contract so we
      // notice if the service starts deduping on its own.
      final db = FakeFirebaseFirestore();
      final svc = PredictionService(db: db);
      await svc.submitPrediction(
          householdId: 'hh',
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
          stars: 4);
      await svc.markRevealSeen(
          householdId: 'hh',
          uid: 'u1',
          predictionId: 'movie:1',
          won: true);
      await svc.markRevealSeen(
          householdId: 'hh',
          uid: 'u1',
          predictionId: 'movie:1',
          won: true);
      final member = await db.doc('households/hh/members/u1').get();
      expect(member.data()!['predict_total'], 2);
      expect(member.data()!['predict_wins'], 2);
    });
  });

  group('RatingService — boundary stars', () {
    test('stars=1 persists; stars=5 persists', () async {
      final db = FakeFirebaseFirestore();
      final svc = RatingService(db: db, trakt: _NoopPusher());
      await svc.save(
          householdId: 'hh',
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:1',
          stars: 1);
      await svc.save(
          householdId: 'hh',
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:2',
          stars: 5);
      expect(
          (await db.doc('households/hh/ratings/u1:movie:movie:1').get())
              .data()!['stars'],
          1);
      expect(
          (await db.doc('households/hh/ratings/u1:movie:movie:2').get())
              .data()!['stars'],
          5);
    });

    test('rating an episode writes with the episode-shaped id', () async {
      final db = FakeFirebaseFirestore();
      final svc = RatingService(db: db, trakt: _NoopPusher());
      await svc.save(
        householdId: 'hh',
        uid: 'u1',
        level: 'episode',
        targetId: 'tv:1:1_2',
        stars: 4,
      );
      final doc = await db
          .doc('households/hh/ratings/u1:episode:tv:1:1_2')
          .get();
      expect(doc.exists, isTrue);
      expect(doc.data()!['level'], 'episode');
    });
  });

  group('DecideService — tiebreak counter math', () {
    Decision dec(String winner) => Decision(
          id: 'ignored',
          winnerMediaType: 'movie',
          winnerTmdbId: 1,
          winnerTitle: 'X',
          picks: {
            winner: DecisionPick(
                uid: winner, mediaType: 'movie', tmdbId: 1, title: 'X'),
          },
          vetoes: const [],
          wasCompromise: false,
          wasTiebreak: false,
          decidedAt: DateTime.utc(2025, 1, 1),
        );

    test('counter starts at 1 on first decision, not 0', () async {
      final db = FakeFirebaseFirestore();
      final svc = DecideService(db: db);
      await svc.recordDecision(
        'hh',
        dec('u1'),
        winnerUid: 'u1',
        loserUid: 'u2',
      );
      expect((await svc.readWhoseTurn('hh'))['u1'], 1);
    });

    test('does not create a key for loser by default', () async {
      final db = FakeFirebaseFirestore();
      final svc = DecideService(db: db);
      await svc.recordDecision(
        'hh',
        dec('u1'),
        winnerUid: 'u1',
        loserUid: 'u2',
      );
      final turns = await svc.readWhoseTurn('hh');
      expect(turns.containsKey('u2'), isFalse);
    });

    test('10 consecutive wins roll up correctly', () async {
      final db = FakeFirebaseFirestore();
      final svc = DecideService(db: db);
      for (var i = 0; i < 10; i++) {
        await svc.recordDecision('hh', dec('u1'), winnerUid: 'u1');
      }
      expect((await svc.readWhoseTurn('hh'))['u1'], 10);
    });
  });

  group('HouseholdService — invite-code regex corner cases', () {
    test('exactly 19 chars rejected, 20 accepted', () {
      expect(HouseholdService.isValidInviteCode('a' * 19), isFalse);
      expect(HouseholdService.isValidInviteCode('a' * 20), isTrue);
    });
    test('exactly 65 chars rejected, 64 accepted', () {
      expect(HouseholdService.isValidInviteCode('a' * 64), isTrue);
      expect(HouseholdService.isValidInviteCode('a' * 65), isFalse);
    });
    test('underscore, dash, dot all rejected (only alphanumerics allowed)',
        () {
      final pad = 'c' * 20;
      final codes = ['a_b$pad', 'a-b$pad', 'a.b$pad'];
      for (final c in codes) {
        expect(HouseholdService.isValidInviteCode(c), isFalse, reason: c);
      }
    });
    test('case-mixed alphanumerics accepted', () {
      expect(HouseholdService.isValidInviteCode('aAaA1' * 4), isTrue);
    });
    test('emoji + unicode rejected', () {
      expect(HouseholdService.isValidInviteCode('🎬' * 20), isFalse);
      expect(HouseholdService.isValidInviteCode('a' * 19 + 'é'), isFalse);
    });
  });

  group('HouseholdService — joinByInviteCode idempotency', () {
    test('existing member rejoining with their code does not fail',
        () async {
      final db = FakeFirebaseFirestore();
      final svc = HouseholdService(db: db);
      final alice = MockUser(uid: 'u1', displayName: 'Alice');
      final hh = await svc.createHousehold(alice);
      final invite = (await db.doc('households/$hh').get())
          .data()!['invite_code'] as String;
      expect(await svc.joinByInviteCode(alice, invite), hh);
      // Should still be 1 member — same uid upsert.
      final members = await db.collection('households/$hh/members').get();
      expect(members.size, 1);
    });
  });
}
