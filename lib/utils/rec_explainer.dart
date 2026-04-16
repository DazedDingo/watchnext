import '../models/rating.dart';
import '../models/recommendation.dart';
import '../models/watch_entry.dart';

/// Chooses a watched title to name-drop under a recommendation card so the
/// user sees *why* the AI picked this one.
///
/// Pure function — no Firestore, no widgets. The home screen passes in the
/// signed-in user's ratings + the household watch entries; we pick the
/// highest-rated watched title that shares at least one genre with [rec].
///
/// Returns null if no suitable citation exists (no 4★+ ratings, no genre
/// overlap, or no watch entry matching a rating's targetId). The caller
/// should hide the chip when null — an empty "Because you loved" string is
/// worse than no chip at all.
///
/// Tiebreakers, in order:
///   1. highest stars (5 > 4)
///   2. most recent [Rating.ratedAt]
///   3. deterministic by title (stable across rebuilds for a flicker-free UI)
String? pickExplainer({
  required Recommendation rec,
  required Iterable<Rating> myRatings,
  required Iterable<WatchEntry> entries,
  int minStars = 4,
}) {
  if (rec.genres.isEmpty) return null;
  final recGenres = rec.genres.toSet();

  // Index entries by id so the rating.targetId lookup is O(1).
  final entryById = <String, WatchEntry>{
    for (final e in entries) e.id: e,
  };

  // Candidate = (rating, entry) pair where:
  //   - rating is a strong endorsement from this user,
  //   - entry exists in the household history,
  //   - the entry's genres overlap the rec's genres,
  //   - the entry isn't the recommendation itself.
  final candidates = <({Rating rating, WatchEntry entry})>[];
  for (final r in myRatings) {
    if (r.stars < minStars) continue;
    final e = entryById[r.targetId];
    if (e == null) continue;
    if (e.id == rec.id) continue;
    if (!e.genres.any(recGenres.contains)) continue;
    candidates.add((rating: r, entry: e));
  }
  if (candidates.isEmpty) return null;

  candidates.sort((a, b) {
    final byStars = b.rating.stars.compareTo(a.rating.stars);
    if (byStars != 0) return byStars;
    final byDate = b.rating.ratedAt.compareTo(a.rating.ratedAt);
    if (byDate != 0) return byDate;
    return a.entry.title.compareTo(b.entry.title);
  });

  return candidates.first.entry.title;
}

/// Pre-formats the chip label. Kept separate from [pickExplainer] so the
/// tests can assert the selection logic independently of the copy.
String explainerLabel(String title) => 'Because you loved $title';
