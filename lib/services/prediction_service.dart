import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/prediction.dart';

/// Manages per-title predictions (Phase 6: Predict & Rate).
class PredictionService {
  PredictionService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(
          String householdId, String predictionId) =>
      _db.doc('households/$householdId/predictions/$predictionId');

  Stream<Prediction?> stream(String householdId, String predictionId) =>
      _doc(householdId, predictionId).snapshots().map((snap) =>
          snap.exists ? Prediction.fromDoc(snap) : null);

  Future<void> submitPrediction({
    required String householdId,
    required String uid,
    required String mediaType,
    required int tmdbId,
    required String title,
    String? posterPath,
    required int stars,
    // 'solo' | 'together' | null (null = context unknown / legacy callers).
    String? context,
  }) {
    final id = Prediction.buildId(mediaType, tmdbId);
    final entry = PredictionEntry(stars: stars, skipped: false, context: context);
    return _doc(householdId, id).set({
      'media_type': mediaType,
      'tmdb_id': tmdbId,
      'title': title,
      'poster_path': ?posterPath,
      'entries': {uid: entry.toMap()},
      'reveal_seen': {uid: false},
      'created_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> skipPrediction({
    required String householdId,
    required String uid,
    required String mediaType,
    required int tmdbId,
    required String title,
    String? posterPath,
    String? context,
  }) {
    final id = Prediction.buildId(mediaType, tmdbId);
    final entry = PredictionEntry(skipped: true, context: context);
    return _doc(householdId, id).set({
      'media_type': mediaType,
      'tmdb_id': tmdbId,
      'title': title,
      'poster_path': ?posterPath,
      'entries': {uid: entry.toMap()},
      'reveal_seen': {uid: false},
      'created_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Mark that this user has seen the reveal. Also updates the household's
  /// prediction score counters so Phase 9 stats have something to read.
  ///
  /// With [context] = 'solo' or 'together' the counters bump the matching
  /// per-mode slot (`predict_total_solo`, `predict_wins_together`, etc).
  /// With [context] = null (legacy path), the pre-split `predict_total` /
  /// `predict_wins` fields are bumped instead — kept so historical
  /// leaderboards don't reset at rollout. New callers should always pass a
  /// context.
  Future<void> markRevealSeen({
    required String householdId,
    required String uid,
    required String predictionId,
    required bool won, // true if this user had the closer prediction
    String? context,
  }) async {
    final batch = _db.batch();

    // Mark reveal seen on prediction doc.
    batch.set(
      _doc(householdId, predictionId),
      {'reveal_seen': {uid: true}},
      SetOptions(merge: true),
    );

    // Increment predict counters on the member doc for Phase 9 stats.
    final Map<String, Object?> inc;
    if (context == 'solo') {
      inc = {
        'predict_total_solo': FieldValue.increment(1),
        if (won) 'predict_wins_solo': FieldValue.increment(1),
      };
    } else if (context == 'together') {
      inc = {
        'predict_total_together': FieldValue.increment(1),
        if (won) 'predict_wins_together': FieldValue.increment(1),
      };
    } else {
      // Legacy path: no mode known. Feed the pre-split lifetime fields.
      inc = {
        'predict_total': FieldValue.increment(1),
        if (won) 'predict_wins': FieldValue.increment(1),
      };
    }
    batch.set(
      _db.doc('households/$householdId/members/$uid'),
      inc,
      SetOptions(merge: true),
    );

    await batch.commit();
  }
}
