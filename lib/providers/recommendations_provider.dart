import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recommendation.dart';
import '../services/recommendations_service.dart';
import 'household_provider.dart';
import 'watchlist_provider.dart';

final recommendationsServiceProvider =
    Provider<RecommendationsService>((_) => RecommendationsService());

/// Live recommendations list ordered by together match score.
final recommendationsProvider =
    StreamProvider<List<Recommendation>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  final service = ref.watch(recommendationsServiceProvider);
  if (householdId == null) {
    yield const [];
    return;
  }
  yield* service.stream(householdId);
});

/// Single recommendation doc — used by TitleDetail to show AI blurb.
/// Auto-disposes when the screen is popped so there's no lingering listener.
final singleRecProvider =
    StreamProvider.autoDispose.family<Recommendation?, String>((ref, recId) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) { yield null; return; }
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/recommendations')
      .doc(recId)
      .snapshots()
      .map((snap) => snap.exists ? Recommendation.fromDoc(snap) : null);
});

/// One-shot trigger that refreshes taste profile then kicks off Claude
/// scoring. Safe to call from a pull-to-refresh or settings action; wrapped
/// in FutureProvider so the UI can show progress/errors.
final refreshRecommendationsProvider =
    FutureProvider.family<void, bool>((ref, force) async {
  final householdId = await ref.read(householdIdProvider.future);
  if (householdId == null) return;
  final service = ref.read(recommendationsServiceProvider);
  final watchlist = ref.read(watchlistProvider).value ?? const [];

  if (force) {
    await service.refreshTasteProfile(householdId);
  }
  await service.refresh(householdId, watchlist: watchlist);
});
