import 'package:cloud_firestore/cloud_firestore.dart';

/// A resolved Decide Together session. Path: /households/{id}/decisionHistory/{id}
///
/// [winnerTitle] is the title the pair ended up on. [picks] maps uid → the
/// title that user tapped during the "pick your #1" phase (only present if
/// negotiation didn't produce an Instant Match). [vetoes] is the ordered list
/// of vetoed titles. [wasCompromise] flags whether the winner came from the
/// Claude/TMDB compromise flow rather than a direct match.
class Decision {
  final String id;
  final String winnerMediaType;
  final int winnerTmdbId;
  final String winnerTitle;
  final String? winnerPosterPath;
  final Map<String, DecisionPick> picks;
  final List<DecisionPick> vetoes;
  final bool wasCompromise;
  final bool wasTiebreak;
  final String mood;
  final DateTime decidedAt;

  Decision({
    required this.id,
    required this.winnerMediaType,
    required this.winnerTmdbId,
    required this.winnerTitle,
    required this.picks,
    required this.vetoes,
    required this.wasCompromise,
    required this.wasTiebreak,
    required this.decidedAt,
    this.winnerPosterPath,
    this.mood = '',
  });

  Map<String, dynamic> toFirestore() => {
        'winner_media_type': winnerMediaType,
        'winner_tmdb_id': winnerTmdbId,
        'winner_title': winnerTitle,
        if (winnerPosterPath != null) 'winner_poster_path': winnerPosterPath,
        'picks': picks.map((uid, p) => MapEntry(uid, p.toMap())),
        'vetoes': vetoes.map((v) => v.toMap()).toList(),
        'was_compromise': wasCompromise,
        'was_tiebreak': wasTiebreak,
        'mood': mood,
        'decided_at': Timestamp.fromDate(decidedAt),
      };

  factory Decision.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    final rawPicks = (d['picks'] as Map?)?.cast<String, dynamic>() ?? {};
    final rawVetoes = (d['vetoes'] as List?) ?? const [];
    return Decision(
      id: doc.id,
      winnerMediaType: d['winner_media_type'] as String,
      winnerTmdbId: (d['winner_tmdb_id'] as num).toInt(),
      winnerTitle: d['winner_title'] as String? ?? 'Untitled',
      winnerPosterPath: d['winner_poster_path'] as String?,
      picks: rawPicks.map((uid, p) => MapEntry(
          uid, DecisionPick.fromMap((p as Map).cast<String, dynamic>()))),
      vetoes: rawVetoes
          .map((v) =>
              DecisionPick.fromMap((v as Map).cast<String, dynamic>()))
          .toList(),
      wasCompromise: d['was_compromise'] as bool? ?? false,
      wasTiebreak: d['was_tiebreak'] as bool? ?? false,
      mood: d['mood'] as String? ?? '',
      decidedAt: (d['decided_at'] as Timestamp).toDate(),
    );
  }
}

/// A single user's pick inside a decision — either their negotiate top pick
/// or the target of a veto. Kept denormalized so history rows render without
/// an extra TMDB lookup.
class DecisionPick {
  final String uid;
  final String mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;

  const DecisionPick({
    required this.uid,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.posterPath,
  });

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'media_type': mediaType,
        'tmdb_id': tmdbId,
        'title': title,
        if (posterPath != null) 'poster_path': posterPath,
      };

  factory DecisionPick.fromMap(Map<String, dynamic> m) => DecisionPick(
        uid: m['uid'] as String,
        mediaType: m['media_type'] as String,
        tmdbId: (m['tmdb_id'] as num).toInt(),
        title: m['title'] as String? ?? 'Untitled',
        posterPath: m['poster_path'] as String?,
      );
}
