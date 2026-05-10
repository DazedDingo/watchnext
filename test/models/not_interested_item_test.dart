import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/not_interested_item.dart';

void main() {
  group('NotInterestedItem.buildId', () {
    test('shared scope ignores ownerUid (collapses to "shared")', () {
      expect(
        NotInterestedItem.buildId('movie', 42, scope: 'shared'),
        'shared:shared:movie:42',
      );
      expect(
        NotInterestedItem.buildId('movie', 42, scope: 'shared', ownerUid: 'u1'),
        'shared:shared:movie:42',
      );
    });

    test('solo scope encodes the owning uid', () {
      expect(
        NotInterestedItem.buildId('tv', 1399, scope: 'solo', ownerUid: 'u1'),
        'solo:u1:tv:1399',
      );
    });

    test('solo without ownerUid defaults the owner segment to "shared"', () {
      // Defensive — production callers always pass ownerUid for solo, but
      // the fallback keeps the id well-formed.
      expect(
        NotInterestedItem.buildId('movie', 1, scope: 'solo'),
        'solo:shared:movie:1',
      );
    });
  });

  group('NotInterestedItem.titleKey', () {
    test('returns the unscoped {mediaType}:{tmdbId} key', () {
      final item = NotInterestedItem(
        id: 'shared:shared:movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'X',
        markedByUid: 'u1',
        markedAt: DateTime(2026, 5, 1),
      );
      expect(item.titleKey, 'movie:42');
    });
  });

  group('NotInterestedItem.fromDoc', () {
    test('round-trips a shared entry', () async {
      final fake = FakeFirebaseFirestore();
      final ref = fake
          .collection('households/h1/notInterested')
          .doc('shared:shared:movie:42');
      await ref.set(NotInterestedItem(
        id: 'shared:shared:movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'Inception',
        posterPath: '/poster.jpg',
        scope: 'shared',
        markedByUid: 'u1',
        markedAt: DateTime(2026, 5, 1),
      ).toFirestore());

      final doc = await ref.get();
      final decoded = NotInterestedItem.fromDoc(doc);
      expect(decoded.scope, 'shared');
      expect(decoded.ownerUid, isNull);
      expect(decoded.title, 'Inception');
      expect(decoded.titleKey, 'movie:42');
    });

    test('round-trips a solo entry', () async {
      final fake = FakeFirebaseFirestore();
      final ref = fake
          .collection('households/h1/notInterested')
          .doc('solo:u1:tv:1399');
      await ref.set(NotInterestedItem(
        id: 'solo:u1:tv:1399',
        mediaType: 'tv',
        tmdbId: 1399,
        title: 'GoT',
        scope: 'solo',
        ownerUid: 'u1',
        markedByUid: 'u1',
        markedAt: DateTime(2026, 5, 1),
      ).toFirestore());

      final doc = await ref.get();
      final decoded = NotInterestedItem.fromDoc(doc);
      expect(decoded.scope, 'solo');
      expect(decoded.ownerUid, 'u1');
      expect(decoded.titleKey, 'tv:1399');
    });

    test('legacy doc with no scope field defaults to shared', () async {
      final fake = FakeFirebaseFirestore();
      final ref = fake
          .collection('households/h1/notInterested')
          .doc('legacy-id');
      // Pre-scope payload — older doc shape.
      await ref.set({
        'media_type': 'movie',
        'tmdb_id': 7,
        'title': 'Old',
        'marked_by_uid': 'u1',
      });
      final doc = await ref.get();
      final decoded = NotInterestedItem.fromDoc(doc);
      expect(decoded.scope, 'shared');
      expect(decoded.ownerUid, isNull);
    });
  });
}
