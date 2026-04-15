import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/decision.dart';
import 'package:watchnext/services/decide_service.dart';

void main() {
  group('DecideService', () {
    late FakeFirebaseFirestore db;
    late DecideService svc;
    const hh = 'hh1';

    Decision decision({String winner = 'u1'}) => Decision(
          id: 'ignored',
          winnerMediaType: 'movie',
          winnerTmdbId: 42,
          winnerTitle: 'X',
          picks: {
            winner: DecisionPick(
                uid: winner, mediaType: 'movie', tmdbId: 42, title: 'X'),
          },
          vetoes: const [],
          wasCompromise: false,
          wasTiebreak: false,
          decidedAt: DateTime.utc(2025, 1, 1),
        );

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = DecideService(db: db);
    });

    test('recordDecision persists to decisionHistory and bumps whose_turn',
        () async {
      final id = await svc.recordDecision(hh, decision(),
          winnerUid: 'u1', loserUid: 'u2');
      expect(id, isNotEmpty);

      final history = await db
          .collection('households/$hh/decisionHistory')
          .get();
      expect(history.size, 1);
      expect(history.docs.first.data()['winner_tmdb_id'], 42);

      final g = await db.doc('households/$hh/gamification/default').get();
      expect((g.data()!['whose_turn'] as Map)['u1'], 1);
    });

    test('sequential wins for same uid increment the counter', () async {
      await svc.recordDecision(hh, decision(winner: 'u1'), winnerUid: 'u1');
      await svc.recordDecision(hh, decision(winner: 'u1'), winnerUid: 'u1');
      await svc.recordDecision(hh, decision(winner: 'u2'), winnerUid: 'u2');
      final turns = await svc.readWhoseTurn(hh);
      expect(turns['u1'], 2);
      expect(turns['u2'], 1);
    });

    test('readWhoseTurn returns empty map when gamification doc missing',
        () async {
      expect(await svc.readWhoseTurn(hh), isEmpty);
    });
  });
}
