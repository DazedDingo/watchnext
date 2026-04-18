import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/watchlist_item.dart';

/// Minimal CRUD for the shared watchlist. Rules allow any household member to
/// read/write here, so ownership logic lives in `added_by`.
class WatchlistService {
  WatchlistService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _coll(String householdId) =>
      _db.collection('households/$householdId/watchlist');

  Future<void> add({
    required String householdId,
    required String uid,
    required String mediaType,
    required int tmdbId,
    required String title,
    int? year,
    String? posterPath,
    List<String> genres = const [],
    int? runtime,
    String? overview,
    String addedSource = 'manual',
    // 'shared' (default) or 'solo'. Solo items only show in Solo mode and
    // only to the owner (enforced client-side via watchlistProvider filters).
    String scope = 'shared',
  }) async {
    final ownerUid = scope == 'solo' ? uid : null;
    final item = WatchlistItem(
      id: WatchlistItem.buildId(mediaType, tmdbId, scope: scope, ownerUid: ownerUid),
      mediaType: mediaType,
      tmdbId: tmdbId,
      title: title,
      year: year,
      posterPath: posterPath,
      genres: genres,
      runtime: runtime,
      overview: overview,
      addedBy: uid,
      addedAt: DateTime.now(),
      addedSource: addedSource,
      scope: scope,
      ownerUid: ownerUid,
    );
    await _coll(householdId).doc(item.id).set(item.toFirestore());
  }

  Future<void> remove({required String householdId, required String id}) async {
    await _coll(householdId).doc(id).delete();
  }

  /// Checks whether a title is on the watchlist for a given scope. Defaults
  /// to shared — callers that want to check a user's solo slot must pass
  /// `scope: 'solo'` + the owner uid.
  Future<bool> contains({
    required String householdId,
    required String mediaType,
    required int tmdbId,
    String scope = 'shared',
    String? ownerUid,
  }) async {
    final doc = await _coll(householdId)
        .doc(WatchlistItem.buildId(mediaType, tmdbId, scope: scope, ownerUid: ownerUid))
        .get();
    return doc.exists;
  }
}
