import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/decision.dart';

/// Persists finished Decide Together sessions and maintains the
/// `gamification.whose_turn` tiebreak counter used when both users exhaust
/// vetoes without landing on a title.
class DecideService {
  final FirebaseFirestore _db;
  DecideService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  /// Writes the decision and bumps the winning user's `whose_turn` counter.
  /// If [wasTiebreak] is true, the counter bumps for whoever *lost* the
  /// tiebreak so the next session leans toward them — matching the spec
  /// ("tiebreaker to person with fewer lifetime wins").
  Future<String> recordDecision(
    String householdId,
    Decision decision, {
    required String winnerUid,
    String? loserUid,
  }) async {
    final ref = await _db
        .collection('households/$householdId/decisionHistory')
        .add(decision.toFirestore());

    final gamificationRef = _db.doc('households/$householdId/gamification');
    await _db.runTransaction((tx) async {
      final snap = await tx.get(gamificationRef);
      final current = (snap.data()?['whose_turn'] as Map?)
              ?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final counters = <String, int>{
        for (final e in current.entries) e.key: (e.value as num).toInt(),
      };
      counters[winnerUid] = (counters[winnerUid] ?? 0) + 1;

      if (snap.exists) {
        tx.update(gamificationRef, {'whose_turn': counters});
      } else {
        tx.set(gamificationRef, {'whose_turn': counters});
      }
    });

    return ref.id;
  }

  /// Reads the current `whose_turn` map — used to decide a tiebreak. Returns
  /// an empty map if gamification hasn't been seeded yet.
  Future<Map<String, int>> readWhoseTurn(String householdId) async {
    final snap =
        await _db.doc('households/$householdId/gamification').get();
    final raw = (snap.data()?['whose_turn'] as Map?)?.cast<String, dynamic>();
    if (raw == null) return {};
    return {for (final e in raw.entries) e.key: (e.value as num).toInt()};
  }
}
