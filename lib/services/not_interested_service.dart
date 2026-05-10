import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/not_interested_item.dart';

/// Firestore CRUD for `/households/{hh}/notInterested/*`. Mirrors the
/// WatchlistService shape — same scope contract, same id builder pattern.
class NotInterestedService {
  final FirebaseFirestore _db;
  NotInterestedService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String householdId) =>
      _db.collection('households/$householdId/notInterested');

  Future<void> mark({
    required String householdId,
    required String mediaType,
    required int tmdbId,
    required String title,
    String? posterPath,
    required String markedByUid,
    String scope = 'shared',
    String? ownerUid,
  }) async {
    final id = NotInterestedItem.buildId(
      mediaType,
      tmdbId,
      scope: scope,
      ownerUid: ownerUid,
    );
    final item = NotInterestedItem(
      id: id,
      mediaType: mediaType,
      tmdbId: tmdbId,
      title: title,
      posterPath: posterPath,
      scope: scope,
      ownerUid: scope == 'solo' ? ownerUid : null,
      markedByUid: markedByUid,
      markedAt: DateTime.now(),
    );
    await _col(householdId).doc(id).set(item.toFirestore());
  }

  Future<void> unmark({
    required String householdId,
    required String mediaType,
    required int tmdbId,
    String scope = 'shared',
    String? ownerUid,
  }) async {
    final id = NotInterestedItem.buildId(
      mediaType,
      tmdbId,
      scope: scope,
      ownerUid: ownerUid,
    );
    await _col(householdId).doc(id).delete();
  }

  /// Removes BOTH a shared entry (if any) and the caller's solo entry (if any)
  /// in one shot. Used by the title detail "Mark interested again" tap so a
  /// single toggle clears whichever scope marked the title — the user doesn't
  /// have to know whether they hid it solo or shared.
  Future<void> unmarkAllScopes({
    required String householdId,
    required String mediaType,
    required int tmdbId,
    required String uid,
  }) async {
    final batch = _db.batch();
    batch.delete(_col(householdId).doc(NotInterestedItem.buildId(
      mediaType, tmdbId,
      scope: 'shared',
    )));
    batch.delete(_col(householdId).doc(NotInterestedItem.buildId(
      mediaType, tmdbId,
      scope: 'solo',
      ownerUid: uid,
    )));
    await batch.commit();
  }

  Stream<List<NotInterestedItem>> stream(String householdId) {
    return _col(householdId)
        .orderBy('marked_at', descending: true)
        .snapshots()
        .map((s) => s.docs.map(NotInterestedItem.fromDoc).toList());
  }
}
