import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/rating.dart';
import '../models/watch_entry.dart';
import 'mode_provider.dart';
import 'ratings_provider.dart';
import 'watch_entries_provider.dart';

/// A single "Rewatch?" row — a past favorite the household hasn't touched
/// recently. Rendered as a horizontal poster carousel on Home.
class RewatchTitle {
  final String mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;
  final int stars;
  final DateTime? lastWatchedAt;

  const RewatchTitle({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.stars,
    this.posterPath,
    this.lastWatchedAt,
  });

  String get key => '$mediaType:$tmdbId';
}

/// Minimum stars to qualify for a rewatch suggestion. 4 not 5 because a
/// lot of "favorites" live in the 4-star bucket; 5-only would surface a
/// stingy carousel.
const _kRewatchStarsFloor = 4;

/// Months without any watch activity before a title is eligible to
/// resurface. One year balances "enough time to miss it" against "not
/// so long the user has moved on from the genre."
const _kRewatchStaleMonths = 12;

/// Titles the household (solo: current user; together: either member)
/// rated [_kRewatchStarsFloor]+ stars and hasn't watched in the last
/// [_kRewatchStaleMonths] months. Sorted by longest-since-watched first
/// so a rotating set surfaces over time. Client-side only — cheap at
/// household scale and reactive to both rating and watch-entry changes.
///
/// **Interaction with other filters**: this carousel is independent of
/// the Home filter stack (genre / year / runtime / media type / oscar /
/// exclude-animation / sort / curator). Those filters shape *discovery*
/// of new titles; rewatch is a separate surface sourced from the
/// household's own past ratings. Applying filters to it would be
/// counter-intuitive — you shouldn't have to un-set a Criterion filter
/// to see a Breaking Bad rewatch suggestion.
final rewatchForYouProvider = Provider.autoDispose<List<RewatchTitle>>((ref) {
  final ratings = ref.watch(ratingsProvider).value ?? const <Rating>[];
  final entries = ref.watch(watchEntriesProvider).value ?? const <WatchEntry>[];
  final mode = ref.watch(viewModeProvider);
  final uid = FirebaseAuth.instance.currentUser?.uid;

  if (ratings.isEmpty || entries.isEmpty) return const [];

  final staleCutoff = DateTime.now().subtract(
    const Duration(days: 30 * _kRewatchStaleMonths),
  );

  final entriesById = <String, WatchEntry>{
    for (final e in entries) e.id: e,
  };

  // Movie/show level only — skip season/episode ratings, which inflate
  // counts and don't map 1:1 to a WatchEntry.
  final eligibleRatings = ratings.where((r) {
    if (r.stars < _kRewatchStarsFloor) return false;
    if (r.level != 'movie' && r.level != 'show') return false;
    if (mode == ViewMode.solo && uid != null && r.uid != uid) return false;
    return true;
  });

  // Keep the highest star rating per targetId (handles both members
  // rating the same title in Together mode).
  final bestByTarget = <String, Rating>{};
  for (final r in eligibleRatings) {
    final existing = bestByTarget[r.targetId];
    if (existing == null || r.stars > existing.stars) {
      bestByTarget[r.targetId] = r;
    }
  }

  final out = <RewatchTitle>[];
  for (final entry in bestByTarget.entries) {
    final watchEntry = entriesById[entry.key];
    if (watchEntry == null) continue;
    final last = watchEntry.lastWatchedAt;
    if (last == null) continue;
    if (last.isAfter(staleCutoff)) continue;
    out.add(RewatchTitle(
      mediaType: watchEntry.mediaType,
      tmdbId: watchEntry.tmdbId,
      title: watchEntry.title,
      posterPath: watchEntry.posterPath,
      stars: entry.value.stars,
      lastWatchedAt: last,
    ));
  }

  out.sort((a, b) {
    final s = b.stars.compareTo(a.stars);
    if (s != 0) return s;
    final al = a.lastWatchedAt;
    final bl = b.lastWatchedAt;
    if (al == null && bl == null) return 0;
    if (al == null) return 1;
    if (bl == null) return -1;
    return al.compareTo(bl);
  });

  return out.take(20).toList();
});
