import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'household_provider.dart';

/// Injection seam — tests override with a `FakeFirebaseFirestore`. Production
/// reads the singleton.
final tonightsPickFirestoreProvider =
    Provider<FirebaseFirestore>((_) => FirebaseFirestore.instance);

/// Mirror of the per-household Tonight's Pick doc that the
/// `updateTonightsPickDaily` Cloud Function writes to
/// `households/{hh}/tonightsPick/current`. The CF is the source of truth for
/// the home-screen widget — the in-app Home surface still picks locally so it
/// can react to filters + dismissals.
///
/// Field names mirror the CF's TypeScript shape (camelCase) — NOT the
/// snake_case shape used elsewhere in the recommendations collection.
class TonightsPick {
  final int tmdbId;
  final String mediaType;
  final String title;
  final String posterPath;
  final int? year;
  final int matchScore;
  final String aiBlurb;
  final String source;
  final DateTime? updatedAt;

  const TonightsPick({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    required this.posterPath,
    required this.matchScore,
    this.year,
    this.aiBlurb = '',
    this.source = 'unknown',
    this.updatedAt,
  });

  factory TonightsPick.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return TonightsPick(
      tmdbId: (d['tmdbId'] as num?)?.toInt() ?? 0,
      mediaType: d['mediaType'] as String? ?? 'movie',
      title: d['title'] as String? ?? '',
      posterPath: d['posterPath'] as String? ?? '',
      year: (d['year'] as num?)?.toInt(),
      matchScore: (d['matchScore'] as num?)?.toInt() ?? 0,
      aiBlurb: d['aiBlurb'] as String? ?? '',
      source: d['source'] as String? ?? 'unknown',
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Streams the current Tonight's Pick for the active household.
///
/// Deliberately NOT autoDispose — the home-screen-widget bridge listens
/// across navigation (Home → Library → back) and tearing the stream down on
/// every screen change would cause the widget pushes to flicker.
///
/// Yields null when no household is set or the doc doesn't exist yet (the CF
/// hasn't run for this household yet, or the daily sweep had no candidate).
final tonightsPickProvider = StreamProvider<TonightsPick?>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield null;
    return;
  }
  final db = ref.watch(tonightsPickFirestoreProvider);
  yield* db
      .doc('households/$householdId/tonightsPick/current')
      .snapshots()
      .map((snap) => snap.exists ? TonightsPick.fromDoc(snap) : null);
});
