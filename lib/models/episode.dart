import 'package:cloud_firestore/cloud_firestore.dart';

/// Per-episode watch record for TV entries.
/// Path: /households/{hh}/watchEntries/{entryId}/episodes/{season}_{episode}
///
/// We store per-user `watched_at` timestamps so that solo-mode filters and the
/// Unrated Queue can answer "did *this* user watch *this* episode" without
/// another collection or a Cloud Function.
class Episode {
  final String id; // '{season}_{episode}'
  final int season;
  final int number;
  final String? title;
  final int? tmdbId;
  final String? overview;
  final String? stillPath;
  final int? runtime;
  final DateTime? airedAt;

  /// uid → watched_at timestamp. Both members may have watched it at different
  /// times (independent sync); the newest becomes the show's `last_watched_at`.
  final Map<String, DateTime> watchedByAt;

  Episode({
    required this.id,
    required this.season,
    required this.number,
    this.title,
    this.tmdbId,
    this.overview,
    this.stillPath,
    this.runtime,
    this.airedAt,
    this.watchedByAt = const {},
  });

  static String buildId(int season, int episode) => '${season}_$episode';

  Map<String, dynamic> toFirestore() => {
        'season': season,
        'number': number,
        if (title != null) 'title': title,
        if (tmdbId != null) 'tmdb_id': tmdbId,
        if (overview != null) 'overview': overview,
        if (stillPath != null) 'still_path': stillPath,
        if (runtime != null) 'runtime': runtime,
        if (airedAt != null) 'aired_at': Timestamp.fromDate(airedAt!),
        'watched_by_at': watchedByAt.map((k, v) => MapEntry(k, Timestamp.fromDate(v))),
      };

  factory Episode.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    final rawWatched = (d['watched_by_at'] as Map?) ?? const {};
    return Episode(
      id: doc.id,
      season: (d['season'] as num).toInt(),
      number: (d['number'] as num).toInt(),
      title: d['title'] as String?,
      tmdbId: (d['tmdb_id'] as num?)?.toInt(),
      overview: d['overview'] as String?,
      stillPath: d['still_path'] as String?,
      runtime: (d['runtime'] as num?)?.toInt(),
      airedAt: (d['aired_at'] as Timestamp?)?.toDate(),
      watchedByAt: rawWatched.map((k, v) => MapEntry(k as String, (v as Timestamp).toDate())),
    );
  }
}
