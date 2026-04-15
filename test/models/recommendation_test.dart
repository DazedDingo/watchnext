import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/recommendation.dart';

void main() {
  group('Recommendation', () {
    test('scoreFor falls back to together score when uid missing', () {
      const r = Recommendation(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        matchScore: 70,
        matchScoreSolo: {'u1': 90},
      );
      expect(r.scoreFor(null), 70);
      expect(r.scoreFor('u1'), 90);
      expect(r.scoreFor('missing'), 70); // falls back to together
    });

    test('blurbFor falls back to together blurb when uid missing', () {
      const r = Recommendation(
        id: 'movie:1',
        mediaType: 'movie',
        tmdbId: 1,
        title: 'X',
        matchScore: 50,
        aiBlurb: 'together blurb',
        aiBlurbSolo: {'u1': 'solo blurb'},
      );
      expect(r.blurbFor(null), 'together blurb');
      expect(r.blurbFor('u1'), 'solo blurb');
      expect(r.blurbFor('missing'), 'together blurb');
    });

    test('fromDoc parses scored recommendation with per-uid fields',
        () async {
      final db = FakeFirebaseFirestore();
      await db.doc('r/movie:42').set({
        'media_type': 'movie',
        'tmdb_id': 42,
        'title': 'The Matrix',
        'year': 1999,
        'poster_path': '/m.jpg',
        'genres': ['Action'],
        'match_score': 85,
        'match_score_solo': {'u1': 90, 'u2': 80},
        'ai_blurb': 'together',
        'ai_blurb_solo': {'u1': 'solo u1'},
        'source': 'trending',
        'scored': true,
        'generated_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final parsed =
          Recommendation.fromDoc(await db.doc('r/movie:42').get());
      expect(parsed.title, 'The Matrix');
      expect(parsed.year, 1999);
      expect(parsed.matchScore, 85);
      expect(parsed.matchScoreSolo, {'u1': 90, 'u2': 80});
      expect(parsed.aiBlurb, 'together');
      expect(parsed.aiBlurbSolo, {'u1': 'solo u1'});
      expect(parsed.source, 'trending');
      expect(parsed.scored, isTrue);
    });

    test('fromDoc safely defaults when scoring hasn\'t run', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('r/blank').set({'tmdb_id': 1, 'title': 'X'});
      final parsed = Recommendation.fromDoc(await db.doc('r/blank').get());
      expect(parsed.matchScore, 0);
      expect(parsed.scored, isFalse);
      expect(parsed.source, 'unknown');
      expect(parsed.aiBlurb, '');
    });
  });
}
