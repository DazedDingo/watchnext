import '../models/recommendation.dart';

/// Default number of Animation-tagged rows allowed in the Home pool when the
/// user hasn't explicitly selected the Animation genre.
const int kAnimationSoftCap = 2;

/// Soft-caps the number of `Animation`-tagged rows in [recs] when the user
/// hasn't explicitly opted into Animation via the genre filter.
///
/// Why: `/trending/tv/week` + `/tv/top_rated` are both heavily anime-weighted
/// by TMDB's global vote pool, and neither supports server-side genre
/// exclusion. Without a cap, Home's Recommended list reads as "mostly anime"
/// to households that aren't anime-first. The old Exclude-Animation toggle
/// was retired (see CLAUDE.md gotcha 10) because it duplicated genre
/// de-selection under award filters, but no-filter browsing had no such
/// de-dominator — this cap fills that gap with no new UI.
///
/// Semantics:
///   - When `userSelectedAnimation` is true (user picked `Animation` in the
///     genre filter), return [recs] untouched — they explicitly asked for it.
///   - Otherwise, walk [recs] in order and keep at most [cap] rows whose
///     genres include `'Animation'`. Non-Animation rows are always kept.
///
/// Order is preserved — this is a pass-through filter, not a re-rank.
List<Recommendation> capAnimation(
  List<Recommendation> recs, {
  required bool userSelectedAnimation,
  int cap = kAnimationSoftCap,
}) {
  if (userSelectedAnimation) return recs;
  final out = <Recommendation>[];
  var kept = 0;
  for (final r in recs) {
    if (r.genres.contains('Animation')) {
      if (kept >= cap) continue;
      kept++;
    }
    out.add(r);
  }
  return out;
}
