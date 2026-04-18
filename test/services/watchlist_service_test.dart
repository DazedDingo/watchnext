import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/watchlist_service.dart';

void main() {
  group('WatchlistService', () {
    late FakeFirebaseFirestore db;
    late WatchlistService svc;
    const hh = 'hh1';

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = WatchlistService(db: db);
    });

    test('add writes a stable-id doc that survives a re-add', () async {
      await svc.add(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'The Matrix',
        year: 1999,
        posterPath: '/m.jpg',
        genres: const ['Action'],
      );
      final snap = await db.collection('households/$hh/watchlist').get();
      expect(snap.size, 1);
      expect(snap.docs.first.id, 'shared:shared:movie:42');
      expect(snap.docs.first.data()['title'], 'The Matrix');
      expect(snap.docs.first.data()['added_by'], 'u1');
      expect(snap.docs.first.data()['scope'], 'shared');

      // Re-adding same tmdbId/mediaType just overwrites — stays at 1 doc.
      await svc.add(
        householdId: hh,
        uid: 'u2',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'The Matrix',
      );
      final snap2 = await db.collection('households/$hh/watchlist').get();
      expect(snap2.size, 1);
      expect(snap2.docs.first.data()['added_by'], 'u2');
    });

    test('remove deletes the targeted item only', () async {
      await svc.add(
          householdId: hh, uid: 'u1', mediaType: 'movie', tmdbId: 1, title: 'A');
      await svc.add(
          householdId: hh, uid: 'u1', mediaType: 'tv', tmdbId: 2, title: 'B');
      await svc.remove(householdId: hh, id: 'shared:shared:movie:1');
      final snap = await db.collection('households/$hh/watchlist').get();
      expect(snap.size, 1);
      expect(snap.docs.first.id, 'shared:shared:tv:2');
    });

    test('contains reflects current state', () async {
      expect(
          await svc.contains(
              householdId: hh, mediaType: 'movie', tmdbId: 42),
          isFalse);
      await svc.add(
          householdId: hh, uid: 'u1', mediaType: 'movie', tmdbId: 42, title: 'X');
      expect(
          await svc.contains(
              householdId: hh, mediaType: 'movie', tmdbId: 42),
          isTrue);
      await svc.remove(householdId: hh, id: 'shared:shared:movie:42');
      expect(
          await svc.contains(
              householdId: hh, mediaType: 'movie', tmdbId: 42),
          isFalse);
    });

    test('add with default addedSource is "manual"', () async {
      await svc.add(
          householdId: hh, uid: 'u1', mediaType: 'movie', tmdbId: 1, title: 'X');
      final snap = await db.doc('households/$hh/watchlist/shared:shared:movie:1').get();
      expect(snap.data()!['added_source'], 'manual');
    });

    test('add with share_sheet source records the origin', () async {
      await svc.add(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        addedSource: 'share_sheet',
      );
      final snap = await db.doc('households/$hh/watchlist/shared:shared:movie:1').get();
      expect(snap.data()!['added_source'], 'share_sheet');
    });

    test('add with scope=solo stamps owner_uid and routes to per-user id', () async {
      await svc.add(
        householdId: hh,
        uid: 'u1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        scope: 'solo',
      );
      final snap = await db.doc('households/$hh/watchlist/solo:u1:movie:1').get();
      expect(snap.exists, isTrue);
      expect(snap.data()!['scope'], 'solo');
      expect(snap.data()!['owner_uid'], 'u1');
    });

    test('shared + both partners\' solo copies of one title coexist', () async {
      await svc.add(
          householdId: hh, uid: 'u1', mediaType: 'movie', tmdbId: 1, title: 'X');
      await svc.add(
          householdId: hh,
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
          scope: 'solo');
      await svc.add(
          householdId: hh,
          uid: 'u2',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
          scope: 'solo');
      final snap = await db.collection('households/$hh/watchlist').get();
      expect(snap.size, 3);
      final ids = snap.docs.map((d) => d.id).toSet();
      expect(ids, {
        'shared:shared:movie:1',
        'solo:u1:movie:1',
        'solo:u2:movie:1',
      });
    });

    test('contains(scope: solo) is scoped to the given ownerUid', () async {
      await svc.add(
          householdId: hh,
          uid: 'u1',
          mediaType: 'movie',
          tmdbId: 1,
          title: 'X',
          scope: 'solo');
      expect(
          await svc.contains(
              householdId: hh,
              mediaType: 'movie',
              tmdbId: 1,
              scope: 'solo',
              ownerUid: 'u1'),
          isTrue);
      expect(
          await svc.contains(
              householdId: hh,
              mediaType: 'movie',
              tmdbId: 1,
              scope: 'solo',
              ownerUid: 'u2'),
          isFalse);
      // Shared version isn't there even though a solo version is.
      expect(
          await svc.contains(
              householdId: hh, mediaType: 'movie', tmdbId: 1),
          isFalse);
    });
  });
}
