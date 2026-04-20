import 'package:cloud_firestore/cloud_firestore.dart';

class TitleSuggestion {
  final int tmdbId;
  final String mediaType;
  final String title;
  final int? year;
  final String reason;

  /// Poster path as returned by TMDB (`/abc.jpg`). Populated during the
  /// client-side verification pass in `ConciergeService` — Claude's raw
  /// response doesn't carry a poster. When set the sheet renders directly
  /// instead of doing a second `movieDetails`/`tvDetails` fetch.
  final String? posterPath;

  const TitleSuggestion({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.year,
    required this.reason,
    this.posterPath,
  });

  factory TitleSuggestion.fromMap(Map<String, dynamic> m) => TitleSuggestion(
        tmdbId: (m['tmdb_id'] as num).toInt(),
        mediaType: m['media_type'] as String? ?? 'movie',
        title: m['title'] as String? ?? 'Untitled',
        year: (m['year'] as num?)?.toInt(),
        reason: m['reason'] as String? ?? '',
        posterPath: m['poster_path'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'tmdb_id': tmdbId,
        'media_type': mediaType,
        'title': title,
        'year': year,
        'reason': reason,
        if (posterPath != null) 'poster_path': posterPath,
      };

  TitleSuggestion copyWith({
    int? tmdbId,
    String? mediaType,
    String? posterPath,
  }) =>
      TitleSuggestion(
        tmdbId: tmdbId ?? this.tmdbId,
        mediaType: mediaType ?? this.mediaType,
        title: title,
        year: year,
        reason: reason,
        posterPath: posterPath ?? this.posterPath,
      );
}

class ConciergeTurn {
  final String id;
  final String uid;
  final String sessionId;
  final String message;
  final String responseText;
  final List<TitleSuggestion> titles;
  final DateTime createdAt;

  const ConciergeTurn({
    required this.id,
    required this.uid,
    required this.sessionId,
    required this.message,
    required this.responseText,
    required this.titles,
    required this.createdAt,
  });

  factory ConciergeTurn.fromDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data()!;
    final ts = d['created_at'] as Timestamp?;
    return ConciergeTurn(
      id: snap.id,
      uid: d['uid'] as String? ?? '',
      sessionId: d['session_id'] as String? ?? '',
      message: d['message'] as String? ?? '',
      responseText: d['response_text'] as String? ?? '',
      titles: (d['titles'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .map(TitleSuggestion.fromMap)
          .toList(),
      createdAt: ts?.toDate() ?? DateTime.now(),
    );
  }
}
