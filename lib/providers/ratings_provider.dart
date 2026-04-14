import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/rating.dart';
import '../services/rating_service.dart';
import 'household_provider.dart';
import 'trakt_provider.dart';

final ratingServiceProvider = Provider<RatingService>((ref) {
  return RatingService(trakt: ref.watch(traktServiceProvider));
});

/// All ratings across the household. Cheap at household scale.
final ratingsProvider = StreamProvider<List<Rating>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield const [];
    return;
  }
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/ratings')
      .snapshots()
      .map((s) => s.docs.map(Rating.fromDoc).toList());
});

/// Convenience: ratings grouped by `targetId` → list of ratings (both users'
/// ratings live under the same targetId). Useful for rendering History rows.
final ratingsByTargetProvider = Provider<Map<String, List<Rating>>>((ref) {
  final all = ref.watch(ratingsProvider).value ?? const [];
  final out = <String, List<Rating>>{};
  for (final r in all) {
    out.putIfAbsent(r.targetId, () => []).add(r);
  }
  return out;
});
