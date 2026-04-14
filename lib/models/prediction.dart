import 'package:cloud_firestore/cloud_firestore.dart';

/// Per-title prediction doc written when a user predicts their rating
/// before watching. Both members predict independently; predictions are
/// hidden from each other until both have submitted (or one skips).
///
/// Path: /households/{hh}/predictions/{mediaType}:{tmdbId}
class Prediction {
  final String id; // 'mediaType:tmdbId'
  final String mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;

  /// uid → entry. Present only for members who have submitted.
  final Map<String, PredictionEntry> entries;

  /// uid → whether this user has already seen the reveal screen.
  final Map<String, bool> revealSeen;

  final DateTime? createdAt;

  const Prediction({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.posterPath,
    this.entries = const {},
    this.revealSeen = const {},
    this.createdAt,
  });

  static String buildId(String mediaType, int tmdbId) => '$mediaType:$tmdbId';

  PredictionEntry? entryFor(String uid) => entries[uid];
  bool revealSeenBy(String uid) => revealSeen[uid] ?? false;

  /// True when all provided uids have either predicted or skipped.
  bool allSubmitted(List<String> memberUids) =>
      memberUids.every((uid) => entries.containsKey(uid));

  factory Prediction.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final rawEntries = (d['entries'] as Map?) ?? const {};
    final rawSeen = (d['reveal_seen'] as Map?) ?? const {};
    return Prediction(
      id: doc.id,
      mediaType: d['media_type'] as String? ?? 'movie',
      tmdbId: (d['tmdb_id'] as num?)?.toInt() ?? 0,
      title: d['title'] as String? ?? 'Untitled',
      posterPath: d['poster_path'] as String?,
      entries: rawEntries.map((k, v) =>
          MapEntry(k as String, PredictionEntry.fromMap(v as Map))),
      revealSeen: rawSeen.map((k, v) => MapEntry(k as String, v as bool)),
      createdAt: (d['created_at'] as Timestamp?)?.toDate(),
    );
  }
}

class PredictionEntry {
  /// null when skipped.
  final int? stars;
  final bool skipped;
  final DateTime? submittedAt;

  const PredictionEntry({this.stars, this.skipped = false, this.submittedAt});

  bool get isSubmitted => skipped || stars != null;

  factory PredictionEntry.fromMap(Map raw) => PredictionEntry(
        stars: (raw['stars'] as num?)?.toInt(),
        skipped: raw['skipped'] as bool? ?? false,
        submittedAt: (raw['submitted_at'] as Timestamp?)?.toDate(),
      );

  Map<String, dynamic> toMap() => {
        if (stars != null) 'stars': stars,
        'skipped': skipped,
        'submitted_at': submittedAt != null
            ? Timestamp.fromDate(submittedAt!)
            : FieldValue.serverTimestamp(),
      };
}
