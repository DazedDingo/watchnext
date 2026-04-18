import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/watchlist_item.dart';

void main() {
  group('WatchlistItem', () {
    test('buildId default scope is shared; shape is scope:owner:type:id', () {
      expect(WatchlistItem.buildId('movie', 42), 'shared:shared:movie:42');
      expect(WatchlistItem.buildId('tv', 9),
          equals(WatchlistItem.buildId('tv', 9)));
    });

    test('buildId with scope=solo encodes ownerUid', () {
      expect(WatchlistItem.buildId('movie', 42, scope: 'solo', ownerUid: 'u1'),
          'solo:u1:movie:42');
      // Different owners cannot collide on the same title.
      expect(WatchlistItem.buildId('movie', 42, scope: 'solo', ownerUid: 'u1'),
          isNot(WatchlistItem.buildId('movie', 42, scope: 'solo', ownerUid: 'u2')));
      // Shared + solo for the same title cannot collide either.
      expect(WatchlistItem.buildId('movie', 42, scope: 'solo', ownerUid: 'u1'),
          isNot(WatchlistItem.buildId('movie', 42)));
    });

    test('roundtrip preserves title, addedBy, and addedSource', () async {
      final db = FakeFirebaseFirestore();
      final original = WatchlistItem(
        id: 'shared:shared:movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'Foo',
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 5, 5),
        addedSource: 'share_sheet',
        year: 2020,
        genres: const ['Drama'],
      );
      await db.doc('w/shared:shared:movie:42').set(original.toFirestore());
      final parsed =
          WatchlistItem.fromDoc(await db.doc('w/shared:shared:movie:42').get());
      expect(parsed.title, 'Foo');
      expect(parsed.addedBy, 'u1');
      expect(parsed.addedSource, 'share_sheet');
      expect(parsed.year, 2020);
      expect(parsed.genres, ['Drama']);
      expect(parsed.addedAt.isAtSameMomentAs(DateTime.utc(2025, 5, 5)), isTrue);
    });

    test('toFirestore omits null year and posterPath; always emits scope', () {
      final w = WatchlistItem(
        id: 'shared:shared:movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
      );
      final m = w.toFirestore();
      expect(m.containsKey('year'), isFalse);
      expect(m.containsKey('poster_path'), isFalse);
      expect(m.containsKey('runtime'), isFalse);
      expect(m['added_source'], 'manual');
      expect(m['added_at'], isA<Timestamp>());
      expect(m['scope'], 'shared');
      expect(m.containsKey('owner_uid'), isFalse); // shared → no owner
    });

    test('toFirestore includes owner_uid for solo items', () {
      final w = WatchlistItem(
        id: 'solo:u1:movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 1, 1),
        scope: 'solo',
        ownerUid: 'u1',
      );
      final m = w.toFirestore();
      expect(m['scope'], 'solo');
      expect(m['owner_uid'], 'u1');
    });

    test('fromDoc defaults addedSource to manual when missing', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('w/1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'added_by': 'u1',
        'added_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final parsed = WatchlistItem.fromDoc(await db.doc('w/1').get());
      expect(parsed.addedSource, 'manual');
    });

    test('fromDoc treats legacy rows (no scope field) as shared', () async {
      final db = FakeFirebaseFirestore();
      // Legacy row written before the scope field existed.
      await db.doc('w/movie:1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'Legacy',
        'added_by': 'u1',
        'added_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final parsed = WatchlistItem.fromDoc(await db.doc('w/movie:1').get());
      expect(parsed.scope, 'shared');
      expect(parsed.ownerUid, isNull);
    });

    test('fromDoc honors scope=solo + owner_uid', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('w/solo:u1:movie:1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'Mine',
        'added_by': 'u1',
        'added_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
        'scope': 'solo',
        'owner_uid': 'u1',
      });
      final parsed =
          WatchlistItem.fromDoc(await db.doc('w/solo:u1:movie:1').get());
      expect(parsed.scope, 'solo');
      expect(parsed.ownerUid, 'u1');
    });

    test('fromDoc ignores owner_uid for shared rows', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('w/1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'added_by': 'u1',
        'added_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
        'scope': 'shared',
        // Stray owner_uid on a shared row — should be dropped.
        'owner_uid': 'u1',
      });
      final parsed = WatchlistItem.fromDoc(await db.doc('w/1').get());
      expect(parsed.scope, 'shared');
      expect(parsed.ownerUid, isNull);
    });
  });
}
