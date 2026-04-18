import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/prediction.dart';

void main() {
  group('Prediction', () {
    test('buildId uses canonical mediaType:tmdbId form', () {
      expect(Prediction.buildId('tv', 1399), 'tv:1399');
    });

    test('entryFor returns null for unknown uid', () {
      const p = Prediction(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
      );
      expect(p.entryFor('unknown'), isNull);
      expect(p.revealSeenBy('unknown'), isFalse);
    });

    test('allSubmitted returns true only when every member has an entry', () {
      final p = Prediction(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        entries: {
          'u1': const PredictionEntry(stars: 4),
          'u2': const PredictionEntry(skipped: true),
        },
      );
      expect(p.allSubmitted(['u1', 'u2']), isTrue);
      expect(p.allSubmitted(['u1', 'u2', 'u3']), isFalse);
    });

    test('PredictionEntry.isSubmitted true when skipped or stars set', () {
      expect(const PredictionEntry(stars: 5).isSubmitted, isTrue);
      expect(const PredictionEntry(skipped: true).isSubmitted, isTrue);
      expect(const PredictionEntry().isSubmitted, isFalse);
    });

    test('fromDoc parses nested entries and revealSeen', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('p/movie:1').set({
        'media_type': 'movie',
        'tmdb_id': 1,
        'title': 'X',
        'poster_path': '/x.jpg',
        'entries': {
          'u1': {
            'stars': 4,
            'skipped': false,
            'submitted_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
          },
          'u2': {'skipped': true},
        },
        'reveal_seen': {'u1': true, 'u2': false},
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final parsed = Prediction.fromDoc(await db.doc('p/movie:1').get());
      expect(parsed.mediaType, 'movie');
      expect(parsed.tmdbId, 1);
      expect(parsed.title, 'X');
      expect(parsed.posterPath, '/x.jpg');
      expect(parsed.entryFor('u1')?.stars, 4);
      expect(parsed.entryFor('u1')?.skipped, isFalse);
      expect(parsed.entryFor('u2')?.skipped, isTrue);
      expect(parsed.entryFor('u2')?.stars, isNull);
      expect(parsed.revealSeenBy('u1'), isTrue);
      expect(parsed.revealSeenBy('u2'), isFalse);
    });

    test('PredictionEntry.context defaults to null', () {
      expect(const PredictionEntry(stars: 4).context, isNull);
      expect(const PredictionEntry(skipped: true).context, isNull);
    });

    test('PredictionEntry.toMap omits context when null', () {
      final m = const PredictionEntry(stars: 4).toMap();
      expect(m.containsKey('context'), isFalse);
    });

    test('PredictionEntry.toMap emits context when solo/together', () {
      expect(const PredictionEntry(stars: 4, context: 'solo').toMap()['context'],
          'solo');
      expect(
          const PredictionEntry(skipped: true, context: 'together')
              .toMap()['context'],
          'together');
    });

    test('PredictionEntry.fromMap roundtrips solo/together context', () {
      expect(PredictionEntry.fromMap(const {'stars': 4, 'context': 'solo'})
          .context, 'solo');
      expect(PredictionEntry.fromMap(const {'stars': 4, 'context': 'together'})
          .context, 'together');
    });

    test('PredictionEntry.fromMap coerces unknown context value to null', () {
      expect(PredictionEntry.fromMap(const {'stars': 4, 'context': 'bogus'})
          .context, isNull);
      expect(PredictionEntry.fromMap(const {'stars': 4}).context, isNull);
    });

    test('fromDoc tolerates missing fields with safe defaults', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('p/blank').set(<String, dynamic>{});
      final parsed = Prediction.fromDoc(await db.doc('p/blank').get());
      expect(parsed.mediaType, 'movie');
      expect(parsed.tmdbId, 0);
      expect(parsed.title, 'Untitled');
      expect(parsed.entries, isEmpty);
      expect(parsed.revealSeen, isEmpty);
    });
  });
}
