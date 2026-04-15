import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/watch_entry.dart';

void main() {
  group('WatchEntry', () {
    test('buildId is canonical mediaType:tmdbId', () {
      expect(WatchEntry.buildId('movie', 42), 'movie:42');
      expect(WatchEntry.buildId('tv', 1399), 'tv:1399');
    });

    test('toFirestore omits nullable fields that are null', () {
      final e = WatchEntry(
        id: 'movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'The Matrix',
      );
      final m = e.toFirestore();
      expect(m.containsKey('year'), isFalse);
      expect(m.containsKey('poster_path'), isFalse);
      expect(m.containsKey('runtime'), isFalse);
      expect(m.containsKey('last_watched_at'), isFalse);
      expect(m['genres'], isEmpty);
      expect(m['watched_by'], isEmpty);
      expect(m['added_source'], 'trakt');
    });

    test('toFirestore includes optional fields when present', () {
      final watched = DateTime.utc(2025, 3, 2, 10);
      final e = WatchEntry(
        id: 'tv:1',
        mediaType: 'tv',
        tmdbId: 1,
        title: 'Foo',
        year: 2020,
        posterPath: '/p.jpg',
        runtime: 50,
        genres: const ['Drama'],
        lastWatchedAt: watched,
        watchedBy: const {'u1': true},
        inProgressStatus: 'watching',
      );
      final m = e.toFirestore();
      expect(m['year'], 2020);
      expect(m['poster_path'], '/p.jpg');
      expect(m['runtime'], 50);
      expect(m['genres'], ['Drama']);
      expect(m['last_watched_at'], isA<Timestamp>());
      expect(m['watched_by'], {'u1': true});
      expect(m['in_progress_status'], 'watching');
    });

    test('fromDoc roundtrip preserves core fields', () async {
      final db = FakeFirebaseFirestore();
      final original = WatchEntry(
        id: 'movie:42',
        mediaType: 'movie',
        tmdbId: 42,
        title: 'The Matrix',
        year: 1999,
        posterPath: '/matrix.jpg',
        genres: const ['Action', 'Sci-Fi'],
        lastWatchedAt: DateTime.utc(2025, 1, 1),
        watchedBy: const {'u1': true, 'u2': true},
        addedSource: 'trakt',
      );
      await db.doc('w/movie:42').set(original.toFirestore());
      final parsed = WatchEntry.fromDoc(await db.doc('w/movie:42').get());

      expect(parsed.mediaType, 'movie');
      expect(parsed.tmdbId, 42);
      expect(parsed.title, 'The Matrix');
      expect(parsed.year, 1999);
      expect(parsed.posterPath, '/matrix.jpg');
      expect(parsed.genres, ['Action', 'Sci-Fi']);
      expect(parsed.lastWatchedAt!.isAtSameMomentAs(DateTime.utc(2025, 1, 1)), isTrue);
      expect(parsed.watchedBy, {'u1': true, 'u2': true});
      expect(parsed.addedSource, 'trakt');
    });

    test('fromDoc defaults title when missing', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('w/1').set({'media_type': 'movie', 'tmdb_id': 1});
      final parsed = WatchEntry.fromDoc(await db.doc('w/1').get());
      expect(parsed.title, 'Untitled');
      expect(parsed.addedSource, 'trakt');
    });
  });
}
