import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/watchlist_item.dart';

void main() {
  group('WatchlistItem', () {
    test('buildId prevents duplicate adds', () {
      expect(WatchlistItem.buildId('movie', 42), 'movie:42');
      expect(WatchlistItem.buildId('tv', 9),
          equals(WatchlistItem.buildId('tv', 9)));
    });

    test('roundtrip preserves title, addedBy, and addedSource', () async {
      final db = FakeFirebaseFirestore();
      final original = WatchlistItem(
        id: 'movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'Foo',
        addedBy: 'u1',
        addedAt: DateTime.utc(2025, 5, 5),
        addedSource: 'share_sheet',
        year: 2020,
        genres: const ['Drama'],
      );
      await db.doc('w/movie:42').set(original.toFirestore());
      final parsed = WatchlistItem.fromDoc(await db.doc('w/movie:42').get());
      expect(parsed.title, 'Foo');
      expect(parsed.addedBy, 'u1');
      expect(parsed.addedSource, 'share_sheet');
      expect(parsed.year, 2020);
      expect(parsed.genres, ['Drama']);
      expect(parsed.addedAt.isAtSameMomentAs(DateTime.utc(2025, 5, 5)), isTrue);
    });

    test('toFirestore omits null year and posterPath', () {
      final w = WatchlistItem(
        id: 'movie:1',
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
  });
}
