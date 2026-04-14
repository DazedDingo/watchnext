import 'package:cloud_firestore/cloud_firestore.dart';

/// A watched title in the household's history. Movies and TV share this shape;
/// TV titles additionally own an `/episodes` sub-collection (see `Episode`).
///
/// Lives at /households/{householdId}/watchEntries/{entryId}. `entryId` is the
/// canonical string "{mediaType}:{tmdbId}" so upserts are idempotent across
/// multiple Trakt rows (repeated rewatches, per-user history merges).
class WatchEntry {
  final String id;
  final String mediaType; // 'movie' | 'tv'
  final int tmdbId;
  final int? traktId;
  final String? imdbId;
  final String title;
  final int? year;
  final String? posterPath;
  final String? backdropPath;
  final int? runtime;
  final List<String> genres;
  final String? overview;

  /// Most recent watch timestamp across both members. TV shows roll up the
  /// max(`watched_at`) of their episodes here so History sorts correctly.
  final DateTime? lastWatchedAt;
  final DateTime? firstWatchedAt;

  /// Which member(s) have watched it. Keyed by uid → `true`. Makes solo/together
  /// filtering trivial on the client without a second query.
  final Map<String, bool> watchedBy;

  /// How this entry entered the household (`trakt` | `watchlist` | `share_sheet`
  /// | `manual`). Used by analytics + Discovery's "Added via" badge.
  final String addedSource;
  final String? addedBy;
  final DateTime? addedAt;

  /// For TV only — highest season/episode reached, surfaced by History "In
  /// progress" tab (Phase 3). Kept here so the list screen needs no extra read.
  final int? lastSeason;
  final int? lastEpisode;
  final String? inProgressStatus; // 'watching' | 'completed' | 'dropped' | null

  WatchEntry({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.traktId,
    this.imdbId,
    this.year,
    this.posterPath,
    this.backdropPath,
    this.runtime,
    this.genres = const [],
    this.overview,
    this.lastWatchedAt,
    this.firstWatchedAt,
    this.watchedBy = const {},
    this.addedSource = 'trakt',
    this.addedBy,
    this.addedAt,
    this.lastSeason,
    this.lastEpisode,
    this.inProgressStatus,
  });

  static String buildId(String mediaType, int tmdbId) => '$mediaType:$tmdbId';

  Map<String, dynamic> toFirestore() => {
        'media_type': mediaType,
        'tmdb_id': tmdbId,
        if (traktId != null) 'trakt_id': traktId,
        if (imdbId != null) 'imdb_id': imdbId,
        'title': title,
        if (year != null) 'year': year,
        if (posterPath != null) 'poster_path': posterPath,
        if (backdropPath != null) 'backdrop_path': backdropPath,
        if (runtime != null) 'runtime': runtime,
        'genres': genres,
        if (overview != null) 'overview': overview,
        if (lastWatchedAt != null) 'last_watched_at': Timestamp.fromDate(lastWatchedAt!),
        if (firstWatchedAt != null) 'first_watched_at': Timestamp.fromDate(firstWatchedAt!),
        'watched_by': watchedBy,
        'added_source': addedSource,
        if (addedBy != null) 'added_by': addedBy,
        if (addedAt != null) 'added_at': Timestamp.fromDate(addedAt!),
        if (lastSeason != null) 'last_season': lastSeason,
        if (lastEpisode != null) 'last_episode': lastEpisode,
        if (inProgressStatus != null) 'in_progress_status': inProgressStatus,
      };

  factory WatchEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return WatchEntry(
      id: doc.id,
      mediaType: d['media_type'] as String,
      tmdbId: (d['tmdb_id'] as num).toInt(),
      traktId: (d['trakt_id'] as num?)?.toInt(),
      imdbId: d['imdb_id'] as String?,
      title: d['title'] as String? ?? 'Untitled',
      year: (d['year'] as num?)?.toInt(),
      posterPath: d['poster_path'] as String?,
      backdropPath: d['backdrop_path'] as String?,
      runtime: (d['runtime'] as num?)?.toInt(),
      genres: (d['genres'] as List?)?.cast<String>() ?? const [],
      overview: d['overview'] as String?,
      lastWatchedAt: (d['last_watched_at'] as Timestamp?)?.toDate(),
      firstWatchedAt: (d['first_watched_at'] as Timestamp?)?.toDate(),
      watchedBy: (d['watched_by'] as Map?)?.map((k, v) => MapEntry(k as String, v as bool)) ?? const {},
      addedSource: d['added_source'] as String? ?? 'trakt',
      addedBy: d['added_by'] as String?,
      addedAt: (d['added_at'] as Timestamp?)?.toDate(),
      lastSeason: (d['last_season'] as num?)?.toInt(),
      lastEpisode: (d['last_episode'] as num?)?.toInt(),
      inProgressStatus: d['in_progress_status'] as String?,
    );
  }
}
