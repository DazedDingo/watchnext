import 'package:cloud_firestore/cloud_firestore.dart';

/// A single user's rating of a title at a given level.
/// Path: /households/{hh}/ratings/{ratingId}
/// ratingId = "{uid}:{level}:{targetId}" (stable so re-rates overwrite cleanly).
///
/// Scale is 1–5 stars in WatchNext. Trakt is 1–10 on the wire — mapping happens
/// in TraktService (ceil(trakt/2)).
class Rating {
  final String id;
  final String uid;
  final String level; // 'movie' | 'show' | 'season' | 'episode'
  final String targetId; // watchEntry.id, or "{entryId}:{s}_{e}" for episodes
  final int stars; // 1..5
  final List<String> tags; // funny, slow, beautiful, overhyped, ...
  final String? note;
  final DateTime ratedAt;
  final bool pushedToTrakt;

  Rating({
    required this.id,
    required this.uid,
    required this.level,
    required this.targetId,
    required this.stars,
    required this.ratedAt,
    this.tags = const [],
    this.note,
    this.pushedToTrakt = false,
  });

  static String buildId(String uid, String level, String targetId) => '$uid:$level:$targetId';

  Map<String, dynamic> toFirestore() => {
        'uid': uid,
        'level': level,
        'target_id': targetId,
        'stars': stars,
        'tags': tags,
        if (note != null) 'note': note,
        'rated_at': Timestamp.fromDate(ratedAt),
        'pushed_to_trakt': pushedToTrakt,
      };

  factory Rating.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Rating(
      id: doc.id,
      uid: d['uid'] as String? ?? '',
      level: d['level'] as String? ?? 'movie',
      targetId: d['target_id'] as String? ?? '',
      stars: (d['stars'] as num?)?.toInt() ?? 0,
      tags: (d['tags'] as List?)?.whereType<String>().toList() ?? const [],
      note: d['note'] as String?,
      ratedAt:
          (d['rated_at'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0),
      pushedToTrakt: d['pushed_to_trakt'] as bool? ?? false,
    );
  }
}
