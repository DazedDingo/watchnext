import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/tmdb_genres.dart';
import 'mode_provider.dart';
import 'stats_provider.dart';
import 'tmdb_provider.dart';
import 'watch_entries_provider.dart';

/// A single "Upcoming for you" row. Rendered as a horizontal poster carousel
/// on Home, sourced from TMDB's /movie/upcoming and /tv/on_the_air feeds and
/// re-ranked against the household's taste profile.
class UpcomingTitle {
  final String mediaType; // 'movie' | 'tv'
  final int tmdbId;
  final String title;
  final String? posterPath;
  final DateTime? releaseDate;
  final List<String> genres;
  final int matchScore;

  const UpcomingTitle({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.posterPath,
    this.releaseDate,
    this.genres = const [],
    required this.matchScore,
  });

  String get key => '$mediaType:$tmdbId';
}

/// Pulls TMDB's upcoming-movies + on-the-air-TV feeds, filters out anything
/// the household has already touched (watched or watching), and ranks by
/// overlap with the taste profile's top genres.
///
/// This is client-side only — intentionally *not* round-tripped through the
/// Phase 7 scoring CF. Upcoming titles rotate frequently and Claude scores
/// are expensive; a cheap genre-weight match is more than enough signal for
/// a Home carousel that exists to highlight what's *coming*, not to predict
/// 5-star hits.
final upcomingForYouProvider =
    FutureProvider.autoDispose<List<UpcomingTitle>>((ref) async {
  final tmdb = ref.watch(tmdbServiceProvider);
  final profile = ref.watch(tasteProfileProvider).value;
  final watchedKeys = ref.watch(watchedKeysProvider);
  final mode = ref.watch(viewModeProvider);
  final uid = FirebaseAuth.instance.currentUser?.uid;

  // Pick which profile slot to match against — per-mode when available,
  // combined as fallback for legacy households before signal-separation.
  final genreWeights = _resolveGenreWeights(profile, uid: uid, mode: mode);

  final results = await Future.wait([
    tmdb.upcomingMovies().catchError((_) => <String, dynamic>{}),
    tmdb.onTheAirTv().catchError((_) => <String, dynamic>{}),
  ]);
  final movieRows = (results[0]['results'] as List?) ?? const [];
  final tvRows = (results[1]['results'] as List?) ?? const [];

  // TMDB's /movie/upcoming occasionally returns rows whose `release_date`
  // is the ORIGINAL primary release (theatrical re-releases, TMDB data
  // edits) — we've seen a 1986 title land here. Gate movies on a
  // future-ish release date so the carousel actually shows upcoming
  // content. Allow a 14-day past window so just-released hits still
  // surface while the feed rotates. TV is unaffected: on_the_air returns
  // shows currently airing new episodes, and `first_air_date` being
  // decades old is legitimate (long-running series).
  final cutoff = DateTime.now().subtract(const Duration(days: 14));

  final out = <UpcomingTitle>[];
  for (final row in movieRows) {
    final t = _rowToTitle(row, 'movie', genreWeights);
    if (t == null) continue;
    if (watchedKeys.contains(t.key)) continue;
    if (t.releaseDate == null || t.releaseDate!.isBefore(cutoff)) continue;
    out.add(t);
  }
  for (final row in tvRows) {
    final t = _rowToTitle(row, 'tv', genreWeights);
    if (t == null) continue;
    if (watchedKeys.contains(t.key)) continue;
    out.add(t);
  }

  // Rank by genre-overlap score; ties break on soonest release.
  out.sort((a, b) {
    final s = b.matchScore.compareTo(a.matchScore);
    if (s != 0) return s;
    final ar = a.releaseDate;
    final br = b.releaseDate;
    if (ar == null && br == null) return 0;
    if (ar == null) return 1;
    if (br == null) return -1;
    return ar.compareTo(br);
  });

  return out.take(20).toList();
});

Map<String, double> _resolveGenreWeights(
  Map<String, dynamic>? profile, {
  String? uid,
  required ViewMode mode,
}) {
  if (profile == null) return const {};
  Map<String, dynamic>? slot;
  if (uid != null) {
    final perUserKey =
        mode == ViewMode.solo ? 'per_user_solo' : 'per_user_together';
    final perUser = profile[perUserKey] as Map<String, dynamic>?;
    slot = perUser?[uid] as Map<String, dynamic>?;
    slot ??= (profile['per_user'] as Map<String, dynamic>?)?[uid]
        as Map<String, dynamic>?;
  }
  slot ??= profile['combined'] as Map<String, dynamic>?;
  if (slot == null) return const {};
  final list = slot['top_genres'] as List?;
  if (list == null) return const {};
  final out = <String, double>{};
  for (final entry in list) {
    if (entry is! Map) continue;
    final genre = entry['genre'] as String?;
    final weight = (entry['weight'] as num?)?.toDouble();
    if (genre != null && weight != null) out[genre] = weight;
  }
  return out;
}

UpcomingTitle? _rowToTitle(
  dynamic row,
  String mediaType,
  Map<String, double> genreWeights,
) {
  if (row is! Map<String, dynamic>) return null;
  final tmdbId = (row['id'] as num?)?.toInt();
  final title = (row['title'] ?? row['name']) as String?;
  if (tmdbId == null || title == null) return null;

  final dateStr =
      (row['release_date'] ?? row['first_air_date']) as String?;
  DateTime? releaseDate;
  if (dateStr != null && dateStr.isNotEmpty) {
    releaseDate = DateTime.tryParse(dateStr);
  }

  final genres = coerceGenres(row['genre_ids'], mediaType: mediaType);
  final score = _scoreGenreOverlap(genres, genreWeights);

  return UpcomingTitle(
    mediaType: mediaType,
    tmdbId: tmdbId,
    title: title,
    posterPath: row['poster_path'] as String?,
    releaseDate: releaseDate,
    genres: genres,
    matchScore: score,
  );
}

/// Simple overlap score — sum of taste-profile weights for each of the
/// candidate's genres, normalised to an 0-100 integer. Titles with zero
/// overlap against the top genres still come through with score=0 so the
/// list isn't empty for households that haven't built a profile yet.
int _scoreGenreOverlap(
  List<String> candidateGenres,
  Map<String, double> weights,
) {
  if (weights.isEmpty || candidateGenres.isEmpty) return 0;
  double acc = 0;
  for (final g in candidateGenres) {
    acc += weights[g] ?? 0;
  }
  // weights are typically small (<= 1.0 per genre), so a title matching three
  // top genres at 0.3 each lands around 0.9 → 90.
  final clamped = acc.clamp(0.0, 1.0);
  return (clamped * 100).round();
}
