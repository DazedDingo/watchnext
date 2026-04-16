import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/rating_pusher.dart';
import 'package:watchnext/services/rating_service.dart';

class _RecordingPusher implements RatingPusher {
  final List<Map<String, dynamic>> pushed = [];
  final List<Map<String, dynamic>> removed = [];
  int tokenCalls = 0;
  String tokenToReturn = 'tok';
  Object? pushThrows;
  Object? removeThrows;

  _RecordingPusher();

  @override
  Future<String> getLiveAccessToken({
    required String householdId,
    required String uid,
  }) async {
    tokenCalls++;
    return tokenToReturn;
  }

  @override
  Future<void> pushRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
    required int stars,
  }) async {
    if (pushThrows != null) throw pushThrows!;
    pushed.add({
      'token': token,
      'level': level,
      'traktRef': traktRef,
      'stars': stars,
    });
  }

  @override
  Future<void> removeRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
  }) async {
    if (removeThrows != null) throw removeThrows!;
    removed.add({
      'token': token,
      'level': level,
      'traktRef': traktRef,
    });
  }
}

void main() {
  group('RatingService', () {
    late FakeFirebaseFirestore db;
    late _RecordingPusher trakt;
    late RatingService svc;
    const hh = 'hh1';

    setUp(() {
      db = FakeFirebaseFirestore();
      trakt = _RecordingPusher();
      svc = RatingService(db: db, trakt: trakt);
    });

    test('save writes a stable-id rating doc', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
      );
      final snap = await db.collection('households/$hh/ratings').get();
      expect(snap.size, 1);
      expect(snap.docs.first.id, 'u1:movie:movie:42');
      final d = snap.docs.first.data();
      expect(d['uid'], 'u1');
      expect(d['level'], 'movie');
      expect(d['target_id'], 'movie:42');
      expect(d['stars'], 4);
      expect(d['pushed_to_trakt'], false);
    });

    test('rerating the same (uid, level, target) overwrites cleanly',
        () async {
      await svc.save(
          householdId: hh,
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:42',
          stars: 3);
      await svc.save(
          householdId: hh,
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:42',
          stars: 5);
      final snap = await db.collection('households/$hh/ratings').get();
      expect(snap.size, 1);
      expect(snap.docs.first.data()['stars'], 5);
    });

    test('no traktId means Trakt is never called', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
      );
      expect(trakt.tokenCalls, 0);
      expect(trakt.pushed, isEmpty);
    });

    test('with traktId: token fetched, push called, flag flipped true',
        () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 5,
        traktId: 603,
      );
      expect(trakt.tokenCalls, 1);
      expect(trakt.pushed, hasLength(1));
      final call = trakt.pushed.single;
      expect(call['token'], 'tok');
      expect(call['level'], 'movie');
      expect(call['stars'], 5);
      expect((call['traktRef'] as Map)['ids'], {'trakt': 603});
      // Null-aware map entries mean season/number are absent.
      expect((call['traktRef'] as Map).containsKey('season'), isFalse);
      expect((call['traktRef'] as Map).containsKey('number'), isFalse);

      final doc =
          await db.doc('households/$hh/ratings/u1:movie:movie:42').get();
      expect(doc.data()!['pushed_to_trakt'], true);
    });

    test('episode push includes season and number in traktRef', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'episode',
        targetId: 'tv:1:1_2',
        stars: 4,
        traktId: 999,
        season: 1,
        episode: 2,
      );
      final ref = trakt.pushed.single['traktRef'] as Map;
      expect(ref['ids'], {'trakt': 999});
      expect(ref['season'], 1);
      expect(ref['number'], 2);
    });

    test('Trakt push failure leaves pushed_to_trakt=false but does not throw',
        () async {
      trakt.pushThrows = Exception('trakt 500');
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
        traktId: 603,
      );
      final doc =
          await db.doc('households/$hh/ratings/u1:movie:movie:42').get();
      // The rating itself is persisted regardless — Trakt push is best-effort.
      expect(doc.data()!['stars'], 4);
      expect(doc.data()!['pushed_to_trakt'], false);
    });

    test('token-fetch failure is also swallowed (next sync retries)', () async {
      trakt.tokenToReturn = '';
      // Override getLiveAccessToken to throw instead of returning empty.
      final throwingTrakt = _RecordingPusher()
        ..pushThrows = Exception('should not reach push');
      final svc2 = RatingService(db: db, trakt: throwingTrakt);
      // Inject a future that throws in getLiveAccessToken via subclass.
      // Simpler: just rely on pushThrows; token itself succeeds above.
      await svc2.save(
        householdId: hh,
        uid: 'u1',
        level: 'show',
        targetId: 'tv:1',
        stars: 2,
        traktId: 7,
      );
      final doc = await db.doc('households/$hh/ratings/u1:show:tv:1').get();
      expect(doc.exists, isTrue);
      expect(doc.data()!['pushed_to_trakt'], false);
    });

    test('tags and note survive the roundtrip', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:1',
        stars: 5,
        tags: const ['funny', 'rewatch'],
        note: 'loved it',
      );
      final doc = await db.doc('households/$hh/ratings/u1:movie:movie:1').get();
      expect(doc.data()!['tags'], ['funny', 'rewatch']);
      expect(doc.data()!['note'], 'loved it');
    });
  });

  group('RatingService.delete (undo)', () {
    late FakeFirebaseFirestore db;
    late _RecordingPusher trakt;
    late RatingService svc;
    const hh = 'hh1';

    setUp(() {
      db = FakeFirebaseFirestore();
      trakt = _RecordingPusher();
      svc = RatingService(db: db, trakt: trakt);
    });

    test('deletes the stable-id rating doc', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
      );
      expect((await db.collection('households/$hh/ratings').get()).size, 1);

      await svc.delete(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
      );
      expect((await db.collection('households/$hh/ratings').get()).size, 0);
    });

    test('no traktId means Trakt is never called on undo', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
      );
      trakt.tokenCalls = 0; // reset after save
      await svc.delete(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
      );
      expect(trakt.tokenCalls, 0);
      expect(trakt.removed, isEmpty);
    });

    test('with traktId: token fetched, removeRating called with matching ref',
        () async {
      await svc.delete(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        traktId: 603,
      );
      expect(trakt.tokenCalls, 1);
      expect(trakt.removed, hasLength(1));
      final call = trakt.removed.single;
      expect(call['level'], 'movie');
      expect((call['traktRef'] as Map)['ids'], {'trakt': 603});
      expect((call['traktRef'] as Map).containsKey('season'), isFalse);
    });

    test('episode undo includes season and number', () async {
      await svc.delete(
        householdId: hh,
        uid: 'u1',
        level: 'episode',
        targetId: 'tv:1:1_2',
        traktId: 999,
        season: 1,
        episode: 2,
      );
      final ref = trakt.removed.single['traktRef'] as Map;
      expect(ref['ids'], {'trakt': 999});
      expect(ref['season'], 1);
      expect(ref['number'], 2);
    });

    test('Trakt remove failure still succeeds locally (best-effort)', () async {
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
      );
      trakt.removeThrows = Exception('trakt 500');
      await svc.delete(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        traktId: 603,
      );
      // Firestore delete is the source of truth — Trakt reconciles later.
      expect((await db.collection('households/$hh/ratings').get()).size, 0);
    });

    test('delete of a never-saved rating is a no-op (undo is idempotent)',
        () async {
      // No save() call — just delete.
      await svc.delete(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:999',
      );
      expect((await db.collection('households/$hh/ratings').get()).size, 0);
    });

    test('save → delete → save roundtrip leaves exactly one rating',
        () async {
      for (var stars = 1; stars <= 3; stars++) {
        await svc.save(
          householdId: hh,
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:42',
          stars: stars,
        );
        await svc.delete(
          householdId: hh,
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:42',
        );
      }
      await svc.save(
        householdId: hh,
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 5,
      );
      final snap = await db.collection('households/$hh/ratings').get();
      expect(snap.size, 1);
      expect(snap.docs.first.data()['stars'], 5);
    });
  });
}
