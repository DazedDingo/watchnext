import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/episode.dart';

void main() {
  group('Episode', () {
    test('buildId is season_number', () {
      expect(Episode.buildId(1, 2), '1_2');
      expect(Episode.buildId(10, 0), '10_0');
    });

    test('toFirestore serializes watchedByAt map as Timestamps', () {
      final e = Episode(
        id: '1_1',
        season: 1,
        number: 1,
        title: 'Pilot',
        watchedByAt: {'u1': DateTime.utc(2025, 1, 1)},
      );
      final m = e.toFirestore();
      expect(m['season'], 1);
      expect(m['number'], 1);
      expect(m['title'], 'Pilot');
      expect(m['watched_by_at'], isA<Map>());
      expect((m['watched_by_at'] as Map)['u1'], isA<Timestamp>());
    });

    test('fromDoc roundtrip preserves watched timestamps', () async {
      final db = FakeFirebaseFirestore();
      final original = Episode(
        id: '1_2',
        season: 1,
        number: 2,
        title: 'Two',
        tmdbId: 99,
        runtime: 42,
        airedAt: DateTime.utc(2020, 6, 1),
        watchedByAt: {
          'u1': DateTime.utc(2025, 3, 1),
          'u2': DateTime.utc(2025, 3, 5),
        },
      );
      await db.doc('e/1_2').set(original.toFirestore());
      final parsed = Episode.fromDoc(await db.doc('e/1_2').get());

      expect(parsed.season, 1);
      expect(parsed.number, 2);
      expect(parsed.title, 'Two');
      expect(parsed.tmdbId, 99);
      expect(parsed.runtime, 42);
      expect(parsed.airedAt!.isAtSameMomentAs(DateTime.utc(2020, 6, 1)), isTrue);
      expect(parsed.watchedByAt['u1']!.isAtSameMomentAs(DateTime.utc(2025, 3, 1)), isTrue);
      expect(parsed.watchedByAt['u2']!.isAtSameMomentAs(DateTime.utc(2025, 3, 5)), isTrue);
    });
  });
}
