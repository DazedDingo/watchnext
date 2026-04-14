import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared watchlist item. Path: /households/{hh}/watchlist/{id}
/// id == "{mediaType}:{tmdbId}" so both partners can only add once.
class WatchlistItem {
  final String id;
  final String mediaType;
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterPath;
  final List<String> genres;
  final int? runtime;
  final String? overview;
  final String addedBy;
  final DateTime addedAt;
  final String addedSource;

  WatchlistItem({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.addedBy,
    required this.addedAt,
    this.year,
    this.posterPath,
    this.genres = const [],
    this.runtime,
    this.overview,
    this.addedSource = 'manual',
  });

  static String buildId(String mediaType, int tmdbId) => '$mediaType:$tmdbId';

  Map<String, dynamic> toFirestore() => {
        'media_type': mediaType,
        'tmdb_id': tmdbId,
        'title': title,
        if (year != null) 'year': year,
        if (posterPath != null) 'poster_path': posterPath,
        'genres': genres,
        if (runtime != null) 'runtime': runtime,
        if (overview != null) 'overview': overview,
        'added_by': addedBy,
        'added_at': Timestamp.fromDate(addedAt),
        'added_source': addedSource,
      };

  factory WatchlistItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return WatchlistItem(
      id: doc.id,
      mediaType: d['media_type'] as String,
      tmdbId: (d['tmdb_id'] as num).toInt(),
      title: d['title'] as String? ?? 'Untitled',
      year: (d['year'] as num?)?.toInt(),
      posterPath: d['poster_path'] as String?,
      genres: (d['genres'] as List?)?.cast<String>() ?? const [],
      runtime: (d['runtime'] as num?)?.toInt(),
      overview: d['overview'] as String?,
      addedBy: d['added_by'] as String,
      addedAt: (d['added_at'] as Timestamp).toDate(),
      addedSource: d['added_source'] as String? ?? 'manual',
    );
  }
}
