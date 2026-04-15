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
      expect(snap.docs.first.id, 'movie:42');
      expect(snap.docs.first.data()['title'], 'The Matrix');
      expect(snap.docs.first.data()['added_by'], 'u1');

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
      await svc.remove(householdId: hh, id: 'movie:1');
      final snap = await db.collection('households/$hh/watchlist').get();
      expect(snap.size, 1);
      expect(snap.docs.first.id, 'tv:2');
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
      await svc.remove(householdId: hh, id: 'movie:42');
      expect(
          await svc.contains(
              householdId: hh, mediaType: 'movie', tmdbId: 42),
          isFalse);
    });

    test('add with default addedSource is "manual"', () async {
      await svc.add(
          householdId: hh, uid: 'u1', mediaType: 'movie', tmdbId: 1, title: 'X');
      final snap = await db.doc('households/$hh/watchlist/movie:1').get();
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
      final snap = await db.doc('households/$hh/watchlist/movie:1').get();
      expect(snap.data()!['added_source'], 'share_sheet');
    });
  });
}
