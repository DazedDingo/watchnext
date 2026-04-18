import 'package:cloud_firestore/cloud_firestore.dart';

/// Watchlist item. Path: /households/{hh}/watchlist/{id}
///
/// `id` encodes scope so a shared copy and each partner's solo copy can
/// coexist without collision:
///   shared: "shared:shared:{mediaType}:{tmdbId}"
///   solo:   "solo:{ownerUid}:{mediaType}:{tmdbId}"
///
/// Legacy rows written before the scope field use the old
/// "{mediaType}:{tmdbId}" form; `fromDoc` treats a missing `scope` as
/// 'shared' so they remain visible in Together mode.
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
  /// 'shared' (both partners, shown in Together + Solo) or 'solo' (owner only,
  /// shown in Solo mode only).
  final String scope;
  /// Non-null for solo-scoped items, echoing whose list it belongs to.
  /// Always null for shared items.
  final String? ownerUid;

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
    this.scope = 'shared',
    this.ownerUid,
  });

  /// Build a watchlist doc id. `scope` defaults to 'shared'; for solo items
  /// pass `scope: 'solo'` and `ownerUid: <uid>`.
  static String buildId(
    String mediaType,
    int tmdbId, {
    String scope = 'shared',
    String? ownerUid,
  }) {
    final owner = scope == 'solo' ? (ownerUid ?? 'shared') : 'shared';
    return '$scope:$owner:$mediaType:$tmdbId';
  }

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
        'scope': scope,
        if (ownerUid != null) 'owner_uid': ownerUid,
      };

  factory WatchlistItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final rawScope = d['scope'] as String?;
    final scope = (rawScope == 'solo') ? 'solo' : 'shared';
    return WatchlistItem(
      id: doc.id,
      mediaType: d['media_type'] as String? ?? 'movie',
      tmdbId: (d['tmdb_id'] as num?)?.toInt() ?? 0,
      title: d['title'] as String? ?? 'Untitled',
      year: (d['year'] as num?)?.toInt(),
      posterPath: d['poster_path'] as String?,
      genres: (d['genres'] as List?)?.whereType<String>().toList() ?? const [],
      runtime: (d['runtime'] as num?)?.toInt(),
      overview: d['overview'] as String?,
      addedBy: d['added_by'] as String? ?? '',
      addedAt:
          (d['added_at'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
      addedSource: d['added_source'] as String? ?? 'manual',
      scope: scope,
      ownerUid: scope == 'solo' ? d['owner_uid'] as String? : null,
    );
  }
}
