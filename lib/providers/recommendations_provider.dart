import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recommendation.dart';
import '../services/recommendations_service.dart';
import '../utils/oscar_winners.dart';
import 'awards_filter_provider.dart';
import 'curated_source_provider.dart';
import 'genre_filter_provider.dart';
import 'household_provider.dart';
import 'include_watched_provider.dart';
import 'media_type_filter_provider.dart';
import 'mode_provider.dart';
import 'ratings_provider.dart';
import 'runtime_filter_provider.dart';
import 'sort_mode_provider.dart';
import 'watch_entries_provider.dart';
import 'watchlist_provider.dart';
import 'year_filter_provider.dart';

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

/// One-shot trigger that rebuilds the recommendation pool. Writes the
/// candidates to Firestore with default scores (so Home lights up fast) and
/// fires Claude scoring + taste-profile refresh in the background. When
/// [force] is true, the taste profile is regenerated as part of the
/// background pass AND the state-hash dedupe is bypassed.
///
/// Returns true if the refresh actually ran, false if it was short-circuited
/// because the input state (filters + ratings + watches + mode) matched the
/// last successful refresh. Callers can use the bool to render "Already up
/// to date" feedback instead of a spinner.
final refreshRecommendationsProvider =
    FutureProvider.family<bool, bool>((ref, force) async {
  final householdId = await ref.read(householdIdProvider.future);
  if (householdId == null) return false;
  final service = ref.read(recommendationsServiceProvider);
  final watchlist = ref.read(watchlistProvider).value ?? const [];

  final genres = ref.read(selectedGenresProvider);
  final year = ref.read(yearRangeProvider);
  final runtime = ref.read(runtimeFilterProvider);
  final mediaType = ref.read(mediaTypeFilterProvider);
  final awards = ref.read(awardsFilterProvider);
  final sortMode = ref.read(sortModeProvider);
  final curatedSource = ref.read(curatedSourceProvider);
  final includeWatched = ref.read(includeWatchedProvider);
  final mode = ref.read(viewModeProvider);
  final ratings = ref.read(ratingsProvider).value ?? const [];
  final watchEntries = ref.read(watchEntriesProvider).value ?? const [];

  // State-hash covers everything the scorer would see differently between
  // runs. Changes to any of these busts the cache; anything else is a no-op
  // refresh that would burn Claude tokens for identical output.
  final hash = computeRefreshStateHash(
    householdId: householdId,
    genres: genres,
    yearMin: year.minYear,
    yearMax: year.maxYear,
    runtime: runtime?.name,
    mediaType: mediaType?.name,
    awards: awards == AwardCategory.none ? null : awards.name,
    sortMode: sortMode.name,
    curatedSource: curatedSource.name,
    includeWatched: includeWatched,
    mode: mode.name,
    ratingSignature:
        '${ratings.length}:${ratings.map((r) => '${r.id}@${r.stars}').join(',')}',
    watchSignature: watchEntries
        .map((w) => '${w.id}@${w.inProgressStatus ?? ""}@${w.watchedBy.length}')
        .join(','),
  );

  return await service.refresh(
    householdId,
    watchlist: watchlist,
    genreFilters: genres,
    yearRange: year,
    runtimeBucket: runtime,
    mediaTypeFilter: mediaType,
    awardsFilter: awards,
    sortMode: sortMode,
    curatedSource: curatedSource,
    forceTasteProfile: force,
    stateHash: hash,
  );
});
