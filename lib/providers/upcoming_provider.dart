import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/tmdb_genres.dart';
import 'auth_provider.dart';
import 'media_type_filter_provider.dart';
import 'mode_provider.dart';
import 'stats_provider.dart';
import 'tmdb_provider.dart';
import 'watch_entries_provider.dart';

/// A single "Upcoming for you" row. Rendered as a horizontal poster carousel
/// on Home, sourced from TMDB and re-ranked against the household's taste
/// profile.
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

/// Forward-looking window in days for both movie and TV discover queries.
/// Captures a full quarter of upcoming releases — wider than TMDB's curated
/// `/movie/upcoming` endpoint (~28 days) and `/tv/on_the_air` (~7 days),
/// which we previously used. Stretches the carousel from "what releases
/// next month" to "what to plan for this season".
const int kUpcomingWindowDays = 90;

/// Pulls upcoming candidates from TMDB and ranks by overlap with the
/// household's taste profile.
///
/// The carousel honours the active media-type filter so it matches what
/// the rest of Home is showing. Both branches use `/discover/{mt}` with a
/// today→today+90d release-date window so the pool is wide enough to make
/// a "for you" re-rank meaningful, regardless of TMDB's curated upcoming
/// endpoints (which are intentionally short-horizon).
///
/// - **Movies** (filter `movie` or `null`): `/discover/movie` with
///   `primary_release_date.gte=today` + `.lte=today+90d`.
/// - **TV** (filter `tv` or `null`): `/discover/tv` with `air_date.gte` +
///   `.lte` over the same window. The `air_date` filter naturally returns
///   both new series premiering in the window AND returning shows with
///   new episodes airing in the window. We deliberately don't filter
///   returning TV against `watchedKeys` — a new season is the whole point
///   of the surface.
///
/// All branches re-rank by genre-overlap against the per-mode taste
/// profile (`per_user_solo` / `per_user_together` with `combined`
/// fallback). This is client-side only and intentionally not round-
/// tripped through the Phase 7 scoring CF — Upcoming rotates frequently
/// and Claude scores are expensive; cheap genre-weight match is enough
/// signal for a "what's coming?" surface.
final upcomingForYouProvider =
    FutureProvider.autoDispose<List<UpcomingTitle>>((ref) async {
  final tmdb = ref.watch(tmdbServiceProvider);
  final profile = ref.watch(tasteProfileProvider).value;
  final watchedKeys = ref.watch(watchedKeysProvider);
  final mode = ref.watch(viewModeProvider);
  final mediaType = ref.watch(mediaTypeFilterProvider);
  final uid = ref.watch(currentUidProvider);

  final genreWeights = _resolveGenreWeights(profile, uid: uid, mode: mode);

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final windowEnd = today.add(const Duration(days: kUpcomingWindowDays));
  final from = _fmt(today);
  final to = _fmt(windowEnd);

  final out = <UpcomingTitle>[];

  if (mediaType == null || mediaType == MediaTypeFilter.movie) {
    final movies = await tmdb.discoverMovies({
      'primary_release_date.gte': from,
      'primary_release_date.lte': to,
      'sort_by': 'popularity.desc',
      'vote_count.gte': '0',
    }).catchError((_) => <String, dynamic>{});
    final movieRows = (movies['results'] as List?) ?? const [];
    for (final row in movieRows) {
      final t = _rowToTitle(row, 'movie', genreWeights);
      if (t == null) continue;
      if (watchedKeys.contains(t.key)) continue;
      // Defence against TMDB returning rows whose `release_date` somehow
      // sneaks past the server-side filter (community-edited primary
      // dates, theatrical re-releases). Strict floor: today or later.
      if (t.releaseDate == null || t.releaseDate!.isBefore(today)) continue;
      out.add(t);
    }
  }

  if (mediaType == null || mediaType == MediaTypeFilter.tv) {
    final tv = await tmdb.discoverTv({
      'air_date.gte': from,
      'air_date.lte': to,
      'sort_by': 'popularity.desc',
      'vote_count.gte': '10',
    }).catchError((_) => <String, dynamic>{});
    final tvRows = (tv['results'] as List?) ?? const [];
    for (final row in tvRows) {
      final t = _rowToTitle(row, 'tv', genreWeights);
      if (t == null) continue;
      // No watchedKeys filter — returning shows the household already
      // follows are what makes "new seasons" valuable here.
      out.add(t);
    }
  }

  // Rank by genre-overlap; ties break on soonest release.
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

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
