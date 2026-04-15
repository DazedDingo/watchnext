import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/rating.dart';
import 'rating_pusher.dart';

/// Writes a Rating doc and (if Trakt is linked) pushes it to Trakt.
/// Partner-level privacy isn't a concern: both members can read all ratings
/// in the household (rules enforce that). The reveal-after-both-rated flow
/// (Phase 6 Predict & Rate) is a UI concern, not a storage one.
class RatingService {
  RatingService({FirebaseFirestore? db, required this.trakt})
      : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;
  final RatingPusher trakt;

  Future<void> save({
    required String householdId,
    required String uid,
    required String level, // 'movie' | 'show' | 'season' | 'episode'
    required String targetId,
    required int stars,
    List<String> tags = const [],
    String? note,
    // Trakt ids for push; null skips the push.
    int? traktId,
    int? season,
    int? episode,
  }) async {
    final id = Rating.buildId(uid, level, targetId);
    final rating = Rating(
      id: id,
      uid: uid,
      level: level,
      targetId: targetId,
      stars: stars,
      tags: tags,
      note: note,
      ratedAt: DateTime.now(),
      pushedToTrakt: false,
    );
    await _db.doc('households/$householdId/ratings/$id').set(rating.toFirestore());

    if (traktId != null) {
      try {
        final token = await trakt.getLiveAccessToken(householdId: householdId, uid: uid);
        final ref = <String, dynamic>{
          'ids': {'trakt': traktId},
          'season': ?season,
          'number': ?episode,
        };
        await trakt.pushRating(token: token, level: level, traktRef: ref, stars: stars);
        await _db.doc('households/$householdId/ratings/$id').set(
          {'pushed_to_trakt': true},
          SetOptions(merge: true),
        );
      } catch (_) {
        // Push is best-effort. Leave pushed_to_trakt=false; next sync can retry.
      }
    }
  }
}
