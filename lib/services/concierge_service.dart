import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/concierge_turn.dart';
import 'tmdb_service.dart';

/// Client for Phase 8's conversational concierge.
///
/// [chat] calls the `concierge` CF and returns the structured response.
/// [historyStream] streams the persisted turns for a session from Firestore
/// (the CF writes them too, but we optimistically insert locally so the UI
/// feels instant).
class ConciergeService {
  ConciergeService({
    FirebaseFirestore? db,
    FirebaseFunctions? fns,
    TmdbService? tmdb,
  })  : _db = db ?? FirebaseFirestore.instance,
        _fnsField = fns,
        _tmdb = tmdb ?? TmdbService();

  final FirebaseFirestore _db;
  final TmdbService _tmdb;

  // Lazy so historyStream (Firestore only) can be unit-tested without a
  // live FirebaseFunctions instance.
  // Callables live in europe-west2 (co-located with Firestore in London).
  FirebaseFunctions? _fnsField;
  FirebaseFunctions get _fns =>
      _fnsField ??= FirebaseFunctions.instanceFor(region: 'europe-west2');

  CollectionReference<Map<String, dynamic>> _col(String householdId) =>
      _db.collection('households/$householdId/conciergeHistory');

  /// Calls the concierge CF and returns the text + title suggestions.
  Future<({String text, List<TitleSuggestion> titles})> chat({
    required String householdId,
    required String message,
    required String sessionId,
    required String mode,
    String? moodLabel,
    required List<({String user, String assistant})> history,
  }) async {
    final result = await _fns.httpsCallable('concierge').call({
      'householdId': householdId,
      'message': message,
      'sessionId': sessionId,
      'mode': mode,
      'moodLabel': ?moodLabel,
      'history': history
          .map((t) => {'user': t.user, 'assistant': t.assistant})
          .toList(),
    });

    // Android's platform channel returns Map<Object?, Object?> for callable
    // responses, so `as Map<String, dynamic>` blows up with
    // "type Map<Object?, Object?> is not a subtype of Map<String, dynamic>".
    // Convert defensively at both the top level and for each inner title map.
    final data = Map<String, dynamic>.from(result.data as Map);
    final rawTitles = (data['titles'] as List?) ?? const [];
    final titles = rawTitles
        .whereType<Map>()
        .map((m) => TitleSuggestion.fromMap(Map<String, dynamic>.from(m)))
        .toList();
    final verified = await _verifyTitles(titles);
    return (
      text: data['text'] as String? ?? '',
      titles: verified,
    );
  }

  /// Claude hallucinates tmdb_ids — we've seen it say "The Shining" and
  /// return an id that actually belongs to Ice Age. Run each suggestion
  /// through TMDB search and replace the id with the real match; also
  /// capture the poster path so the card renders without a second detail
  /// fetch. Suggestions that fail to resolve are dropped rather than shown
  /// as broken rows.
  @visibleForTesting
  Future<List<TitleSuggestion>> verifyTitles(List<TitleSuggestion> raw) =>
      _verifyTitles(raw);

  Future<List<TitleSuggestion>> _verifyTitles(List<TitleSuggestion> raw) async {
    if (raw.isEmpty) return const [];
    final resolved = await Future.wait(raw.map(_verifyOne));
    return resolved.whereType<TitleSuggestion>().toList();
  }

  Future<TitleSuggestion?> _verifyOne(TitleSuggestion s) async {
    try {
      final data = await _tmdb.searchMulti(s.title);
      final results = (data['results'] as List?) ?? const [];
      final candidates = results
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .where((r) {
            final mt = r['media_type'] as String?;
            return mt == 'movie' || mt == 'tv';
          })
          .toList();
      if (candidates.isEmpty) return null;

      Map<String, dynamic>? pick;
      if (s.year != null) {
        for (final r in candidates) {
          final mt = r['media_type'] as String;
          if (mt != s.mediaType) continue;
          final date =
              (r['release_date'] ?? r['first_air_date']) as String? ?? '';
          if (date.startsWith('${s.year}')) { pick = r; break; }
        }
      }
      pick ??= candidates.firstWhere(
        (r) => (r['media_type'] as String) == s.mediaType,
        orElse: () => candidates.first,
      );

      return s.copyWith(
        tmdbId: (pick['id'] as num).toInt(),
        mediaType: pick['media_type'] as String,
        posterPath: pick['poster_path'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Streams persisted turns for [sessionId] ordered oldest-first.
  Stream<List<ConciergeTurn>> historyStream(
      String householdId, String sessionId) {
    return _col(householdId)
        .where('session_id', isEqualTo: sessionId)
        .orderBy('created_at')
        .snapshots()
        .map((s) => s.docs
            .map((d) => ConciergeTurn.fromDoc(
                d as DocumentSnapshot<Map<String, dynamic>>))
            .toList());
  }
}
