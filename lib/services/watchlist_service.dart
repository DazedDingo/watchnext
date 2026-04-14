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
  }) async {
    final item = WatchlistItem(
      id: WatchlistItem.buildId(mediaType, tmdbId),
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
    );
    await _coll(householdId).doc(item.id).set(item.toFirestore());
  }

  Future<void> remove({required String householdId, required String id}) async {
    await _coll(householdId).doc(id).delete();
  }

  Future<bool> contains({required String householdId, required String mediaType, required int tmdbId}) async {
    final doc = await _coll(householdId).doc(WatchlistItem.buildId(mediaType, tmdbId)).get();
    return doc.exists;
  }
}
