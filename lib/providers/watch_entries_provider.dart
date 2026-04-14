import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/episode.dart';
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

/// Episodes sub-collection for a single TV watch entry, newest first.
/// Lazy-loaded per-entry so the Unrated tab doesn't open N listeners at once.
/// Key: (householdId, entryId).
final episodesProvider =
    FutureProvider.autoDispose.family<List<Episode>, (String, String)>(
        (ref, args) async {
  final (householdId, entryId) = args;
  final snap = await FirebaseFirestore.instance
      .collection('households/$householdId/watchEntries/$entryId/episodes')
      .get();
  return snap.docs.map(Episode.fromDoc).toList()
    ..sort((a, b) {
      final sc = a.season.compareTo(b.season);
      return sc != 0 ? sc : a.number.compareTo(b.number);
    });
});

/// Unrated episodes for the current user across all TV entries.
/// Returns a map of entryId → list of unrated Episode objects so the UI
/// can group them by show without extra work.
/// Only TV entries the user has watched are considered.
final unratedEpisodesProvider =
    StreamProvider<Map<String, List<Episode>>>((ref) async* {
  final user = ref.watch(authStateProvider).value;
  final householdId = ref.watch(householdIdProvider).value;
  if (user == null || householdId == null) { yield const {}; return; }

  // Stream all TV watchEntries this user has watched.
  final entries$ = FirebaseFirestore.instance
      .collection('households/$householdId/watchEntries')
      .where('media_type', isEqualTo: 'tv')
      .snapshots()
      .map((s) => s.docs
          .map(WatchEntry.fromDoc)
          .where((e) => e.watchedBy[user.uid] ?? false)
          .toList());

  // Stream episode-level ratings for this user.
  final episodeRatings$ = FirebaseFirestore.instance
      .collection('households/$householdId/ratings')
      .where('uid', isEqualTo: user.uid)
      .where('level', isEqualTo: 'episode')
      .snapshots()
      .map((s) => s.docs.map(Rating.fromDoc).map((r) => r.targetId).toSet());

  await for (final tvEntries in entries$) {
    final ratedTargetIds = await episodeRatings$.first;
    final result = <String, List<Episode>>{};
    for (final entry in tvEntries) {
      final epSnap = await FirebaseFirestore.instance
          .collection('households/$householdId/watchEntries/${entry.id}/episodes')
          .get();
      final episodes = epSnap.docs.map(Episode.fromDoc).toList();
      final unrated = episodes.where((ep) {
        if (!(ep.watchedByAt.containsKey(user.uid))) return false;
        final targetId = '${entry.id}:${ep.id}';
        return !ratedTargetIds.contains(targetId);
      }).toList()
        ..sort((a, b) {
          final sc = a.season.compareTo(b.season);
          return sc != 0 ? sc : a.number.compareTo(b.number);
        });
      if (unrated.isNotEmpty) result[entry.id] = unrated;
    }
    yield result;
  }
});
