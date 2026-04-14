import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/rating.dart';
import '../models/watch_entry.dart';
import 'auth_provider.dart';
import 'household_provider.dart';

/// All watch entries for the household, newest first.
final watchEntriesProvider = StreamProvider<List<WatchEntry>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield const [];
    return;
  }
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/watchEntries')
      .orderBy('last_watched_at', descending: true)
      .snapshots()
      .map((s) => s.docs.map(WatchEntry.fromDoc).toList());
});

/// Unrated queue: entries the current user has watched but hasn't rated at
/// show/movie level. Cheap client join — fine at household scale (≤ few
/// thousand entries). Episode-level unrated items are computed in Phase 3
/// when the History screen lands.
final unratedQueueProvider = StreamProvider<List<WatchEntry>>((ref) async* {
  final user = ref.watch(authStateProvider).value;
  final householdId = ref.watch(householdIdProvider).value;
  if (user == null || householdId == null) {
    yield const [];
    return;
  }

  final entries$ = FirebaseFirestore.instance
      .collection('households/$householdId/watchEntries')
      .snapshots()
      .map((s) => s.docs.map(WatchEntry.fromDoc).toList());

  final ratings$ = FirebaseFirestore.instance
      .collection('households/$householdId/ratings')
      .where('uid', isEqualTo: user.uid)
      .where('level', whereIn: ['movie', 'show'])
      .snapshots()
      .map((s) => s.docs.map(Rating.fromDoc).map((r) => r.targetId).toSet());

  await for (final entries in entries$) {
    final ratedIds = await ratings$.first;
    yield entries
        .where((e) => (e.watchedBy[user.uid] ?? false) && !ratedIds.contains(e.id))
        .toList();
  }
});
