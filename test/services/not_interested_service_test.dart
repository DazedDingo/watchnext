import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/not_interested_service.dart';

void main() {
  group('NotInterestedService', () {
    late FakeFirebaseFirestore fake;
    late NotInterestedService svc;

    setUp(() {
      fake = FakeFirebaseFirestore();
      svc = NotInterestedService(db: fake);
    });

    Future<List<String>> listIds() async {
      final qs = await fake.collection('households/h1/notInterested').get();
      return qs.docs.map((d) => d.id).toList()..sort();
    }

    test('mark writes a shared doc with the expected scoped id', () async {
      await svc.mark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'Inception',
        markedByUid: 'u1',
      );
      expect(await listIds(), ['shared:shared:movie:42']);
    });

    test('mark with scope=solo writes a uid-scoped id', () async {
      await svc.mark(
        householdId: 'h1',
        mediaType: 'tv',
        tmdbId: 1399,
        title: 'GoT',
        markedByUid: 'u1',
        scope: 'solo',
        ownerUid: 'u1',
      );
      expect(await listIds(), ['solo:u1:tv:1399']);
    });

    test('shared + solo for the same title can coexist', () async {
      await svc.mark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'A',
        markedByUid: 'u1',
      );
      await svc.mark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'A',
        markedByUid: 'u1',
        scope: 'solo',
        ownerUid: 'u1',
      );
      await svc.mark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'A',
        markedByUid: 'u2',
        scope: 'solo',
        ownerUid: 'u2',
      );
      expect(await listIds(), [
        'shared:shared:movie:1',
        'solo:u1:movie:1',
        'solo:u2:movie:1',
      ]);
    });

    test('unmark targets a single scope', () async {
      await svc.mark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'A',
        markedByUid: 'u1',
      );
      await svc.mark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'A',
        markedByUid: 'u1',
        scope: 'solo',
        ownerUid: 'u1',
      );
      await svc.unmark(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 1,
        scope: 'solo',
        ownerUid: 'u1',
      );
      expect(await listIds(), ['shared:shared:movie:1']);
    });

    test('unmarkAllScopes clears shared + caller-solo in one call', () async {
      // Three entries: shared, my solo, partner solo.
      await svc.mark(
        householdId: 'h1', mediaType: 'movie', tmdbId: 9, title: 'A',
        markedByUid: 'u1',
      );
      await svc.mark(
        householdId: 'h1', mediaType: 'movie', tmdbId: 9, title: 'A',
        markedByUid: 'u1', scope: 'solo', ownerUid: 'u1',
      );
      await svc.mark(
        householdId: 'h1', mediaType: 'movie', tmdbId: 9, title: 'A',
        markedByUid: 'u2', scope: 'solo', ownerUid: 'u2',
      );
      await svc.unmarkAllScopes(
        householdId: 'h1',
        mediaType: 'movie',
        tmdbId: 9,
        uid: 'u1',
      );
      // Partner's solo dismissal must remain — that's their setting,
      // unmarkAllScopes only clears scopes the caller owns.
      expect(await listIds(), ['solo:u2:movie:9']);
    });

    test('stream emits newest-first order', () async {
      await svc.mark(
        householdId: 'h1', mediaType: 'movie', tmdbId: 1, title: 'A',
        markedByUid: 'u1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await svc.mark(
        householdId: 'h1', mediaType: 'movie', tmdbId: 2, title: 'B',
        markedByUid: 'u1',
      );
      final batch = await svc.stream('h1').first;
      expect(batch.map((n) => n.tmdbId).toList(), [2, 1]);
    });
  });
}
