import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/rating.dart';

void main() {
  group('Rating', () {
    test('buildId is stable so rerates overwrite cleanly', () {
      expect(Rating.buildId('u1', 'movie', 'movie:42'), 'u1:movie:movie:42');
      expect(Rating.buildId('u1', 'episode', 'tv:100:1_2'),
          'u1:episode:tv:100:1_2');
    });

    test('toFirestore omits null note', () {
      final r = Rating(
        id: 'x',
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
        ratedAt: DateTime.utc(2025, 1, 1),
      );
      final m = r.toFirestore();
      expect(m.containsKey('note'), isFalse);
      expect(m['stars'], 4);
      expect(m['tags'], isEmpty);
      expect(m['pushed_to_trakt'], false);
      expect(m['rated_at'], isA<Timestamp>());
    });

    test('toFirestore includes note and tags when present', () {
      final r = Rating(
        id: 'x',
        uid: 'u1',
        level: 'show',
        targetId: 'tv:1',
        stars: 5,
        ratedAt: DateTime.utc(2025, 1, 1),
        tags: const ['funny', 'slow'],
        note: 'great',
        pushedToTrakt: true,
      );
      final m = r.toFirestore();
      expect(m['note'], 'great');
      expect(m['tags'], ['funny', 'slow']);
      expect(m['pushed_to_trakt'], true);
    });

    test('fromDoc roundtrip preserves fields', () async {
      final db = FakeFirebaseFirestore();
      final original = Rating(
        id: 'u1:movie:movie:42',
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 3,
        ratedAt: DateTime.utc(2025, 2, 3, 4, 5),
        tags: const ['slow'],
        note: 'meh',
        pushedToTrakt: true,
      );
      await db.doc('r/1').set(original.toFirestore());
      final snap = await db.doc('r/1').get();
      final parsed = Rating.fromDoc(snap);

      expect(parsed.uid, original.uid);
      expect(parsed.level, original.level);
      expect(parsed.targetId, original.targetId);
      expect(parsed.stars, original.stars);
      expect(parsed.tags, original.tags);
      expect(parsed.note, original.note);
      expect(parsed.ratedAt.isAtSameMomentAs(original.ratedAt), isTrue);
      expect(parsed.pushedToTrakt, true);
    });

    test('fromDoc defaults missing pushed_to_trakt to false', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('r/1').set({
        'uid': 'u1',
        'level': 'movie',
        'target_id': 'movie:42',
        'stars': 2,
        'rated_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final parsed = Rating.fromDoc(await db.doc('r/1').get());
      expect(parsed.pushedToTrakt, false);
      expect(parsed.tags, isEmpty);
      expect(parsed.note, isNull);
      expect(parsed.context, isNull);
    });

    test('toFirestore omits null context, emits it when set', () {
      final r1 = Rating(
        id: 'x',
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
        ratedAt: DateTime.utc(2025, 1, 1),
      );
      expect(r1.toFirestore().containsKey('context'), isFalse);

      final r2 = Rating(
        id: 'x',
        uid: 'u1',
        level: 'movie',
        targetId: 'movie:42',
        stars: 4,
        ratedAt: DateTime.utc(2025, 1, 1),
        context: 'solo',
      );
      expect(r2.toFirestore()['context'], 'solo');
    });

    test('fromDoc roundtrips context field', () async {
      final db = FakeFirebaseFirestore();
      for (final ctx in ['solo', 'together']) {
        final r = Rating(
          id: 'x',
          uid: 'u1',
          level: 'movie',
          targetId: 'movie:$ctx',
          stars: 4,
          ratedAt: DateTime.utc(2025, 1, 1),
          context: ctx,
        );
        await db.doc('r/$ctx').set(r.toFirestore());
        final parsed = Rating.fromDoc(await db.doc('r/$ctx').get());
        expect(parsed.context, ctx);
      }
    });

    test('fromDoc coerces unknown context values to null', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('r/1').set({
        'uid': 'u1',
        'level': 'movie',
        'target_id': 'movie:42',
        'stars': 2,
        'rated_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
        'context': 'shared', // not a valid value
      });
      final parsed = Rating.fromDoc(await db.doc('r/1').get());
      expect(parsed.context, isNull);
    });
  });
}
