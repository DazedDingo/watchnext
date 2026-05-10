import 'package:cloud_firestore/cloud_firestore.dart';

/// "Not interested" entry. Path: /households/{hh}/notInterested/{id}
///
/// Same scope contract as WatchlistItem so a shared dismissal and each
/// partner's solo dismissal can coexist:
///   shared: "shared:shared:{mediaType}:{tmdbId}"
///   solo:   "solo:{ownerUid}:{mediaType}:{tmdbId}"
///
/// In Solo mode the visible set is `shared` ∪ my-`solo`. In Together mode
/// only `shared` entries hide titles — your partner's solo dismissals
/// don't pollute the joint surface.
class NotInterestedItem {
  final String id;
  final String mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;
  /// 'shared' (both partners) or 'solo' (owner only).
  final String scope;
  /// Non-null for solo-scoped items.
  final String? ownerUid;
  /// uid of the member who marked the item.
  final String markedByUid;
  final DateTime markedAt;

  const NotInterestedItem({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.markedByUid,
    required this.markedAt,
    this.posterPath,
    this.scope = 'shared',
    this.ownerUid,
  });

  /// Returns the unscoped key used by the recommendation pipeline to
  /// match a NI entry against a Recommendation (`{mediaType}:{tmdbId}`).
  String get titleKey => '$mediaType:$tmdbId';

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
        if (posterPath != null) 'poster_path': posterPath,
        'scope': scope,
        if (ownerUid != null) 'owner_uid': ownerUid,
        'marked_by_uid': markedByUid,
        'marked_at': Timestamp.fromDate(markedAt),
      };

  factory NotInterestedItem.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final rawScope = d['scope'] as String?;
    final scope = (rawScope == 'solo') ? 'solo' : 'shared';
    return NotInterestedItem(
      id: doc.id,
      mediaType: d['media_type'] as String? ?? 'movie',
      tmdbId: (d['tmdb_id'] as num?)?.toInt() ?? 0,
      title: d['title'] as String? ?? 'Untitled',
      posterPath: d['poster_path'] as String?,
      scope: scope,
      ownerUid: scope == 'solo' ? d['owner_uid'] as String? : null,
      markedByUid: d['marked_by_uid'] as String? ?? '',
      markedAt: (d['marked_at'] as Timestamp?)?.toDate() ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
