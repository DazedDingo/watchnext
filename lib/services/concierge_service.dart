import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/concierge_turn.dart';

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
  })  : _db = db ?? FirebaseFirestore.instance,
        _fnsField = fns;

  final FirebaseFirestore _db;

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
    return (
      text: data['text'] as String? ?? '',
      titles: titles,
    );
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
