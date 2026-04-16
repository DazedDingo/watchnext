import 'package:cloud_firestore/cloud_firestore.dart';

/// Scored recommendation doc written by the `scoreRecommendations` Cloud
/// Function. Path: /households/{hh}/recommendations/{mediaType:tmdbId}.
///
/// `matchScore` is the Together score (0–100). `matchScoreSolo` + `aiBlurbSolo`
/// are per-uid so the Home screen can render the right framing depending on
/// which mode the viewer is in.
class Recommendation {
  final String id;
  final String mediaType;
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterPath;
  final List<String> genres;
  /// Minutes. Null when the source (trending) didn't carry it.
  final int? runtime;
  final int matchScore;
  final Map<String, int> matchScoreSolo;
  final String aiBlurb;
  final Map<String, String> aiBlurbSolo;
  final String source;
  final bool scored;
  final DateTime? generatedAt;

  const Recommendation({
    required this.id,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    required this.matchScore,
    this.year,
    this.posterPath,
    this.genres = const [],
    this.runtime,
    this.matchScoreSolo = const {},
    this.aiBlurb = '',
    this.aiBlurbSolo = const {},
    this.source = 'unknown',
    this.scored = false,
    this.generatedAt,
  });

  static String buildId(String mediaType, int tmdbId) => '$mediaType:$tmdbId';

  int scoreFor(String? uid) {
    if (uid == null) return matchScore;
    return matchScoreSolo[uid] ?? matchScore;
  }

  String blurbFor(String? uid) {
    if (uid == null) return aiBlurb;
    return aiBlurbSolo[uid] ?? aiBlurb;
  }

  factory Recommendation.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return Recommendation(
      id: doc.id,
      mediaType: d['media_type'] as String? ?? 'movie',
      tmdbId: (d['tmdb_id'] as num?)?.toInt() ?? 0,
      title: d['title'] as String? ?? 'Untitled',
      year: (d['year'] as num?)?.toInt(),
      posterPath: d['poster_path'] as String?,
      genres: (d['genres'] as List?)?.cast<String>() ?? const [],
      runtime: (d['runtime'] as num?)?.toInt(),
      matchScore: (d['match_score'] as num?)?.toInt() ?? 0,
      matchScoreSolo: (d['match_score_solo'] as Map?)
              ?.map((k, v) => MapEntry(k as String, (v as num).toInt())) ??
          const {},
      aiBlurb: d['ai_blurb'] as String? ?? '',
      aiBlurbSolo: (d['ai_blurb_solo'] as Map?)
              ?.map((k, v) => MapEntry(k as String, v as String)) ??
          const {},
      source: d['source'] as String? ?? 'unknown',
      scored: d['scored'] as bool? ?? false,
      generatedAt: (d['generated_at'] as Timestamp?)?.toDate(),
    );
  }
}
