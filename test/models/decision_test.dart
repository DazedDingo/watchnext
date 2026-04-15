import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/decision.dart';

void main() {
  group('Decision', () {
    test('roundtrip preserves picks, vetoes, and tiebreak flags', () async {
      final db = FakeFirebaseFirestore();
      final original = Decision(
        id: 'ignored-on-write',
        winnerMediaType: 'movie',
        winnerTmdbId: 42,
        winnerTitle: 'The Matrix',
        winnerPosterPath: '/m.jpg',
        picks: const {
          'u1': DecisionPick(
            uid: 'u1',
            mediaType: 'movie',
            tmdbId: 42,
            title: 'The Matrix',
          ),
          'u2': DecisionPick(
            uid: 'u2',
            mediaType: 'tv',
            tmdbId: 7,
            title: 'Show',
          ),
        },
        vetoes: const [
          DecisionPick(uid: 'u2', mediaType: 'movie', tmdbId: 99, title: 'Bad'),
        ],
        wasCompromise: true,
        wasTiebreak: false,
        decidedAt: DateTime.utc(2025, 4, 1),
        mood: 'funny',
      );

      await db.doc('d/1').set(original.toFirestore());
      final parsed = Decision.fromDoc(await db.doc('d/1').get());

      expect(parsed.id, '1');
      expect(parsed.winnerTitle, 'The Matrix');
      expect(parsed.winnerTmdbId, 42);
      expect(parsed.winnerPosterPath, '/m.jpg');
      expect(parsed.picks.keys, containsAll(['u1', 'u2']));
      expect(parsed.picks['u2']!.title, 'Show');
      expect(parsed.vetoes, hasLength(1));
      expect(parsed.vetoes.first.title, 'Bad');
      expect(parsed.wasCompromise, isTrue);
      expect(parsed.wasTiebreak, isFalse);
      expect(parsed.mood, 'funny');
      expect(parsed.decidedAt.isAtSameMomentAs(DateTime.utc(2025, 4, 1)), isTrue);
    });

    test('DecisionPick.fromMap tolerates missing title', () {
      final p = DecisionPick.fromMap(<String, dynamic>{
        'uid': 'u1',
        'media_type': 'movie',
        'tmdb_id': 1,
      });
      expect(p.title, 'Untitled');
      expect(p.posterPath, isNull);
    });
  });
}
