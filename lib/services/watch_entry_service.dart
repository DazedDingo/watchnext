import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/watch_entry.dart';

/// Manual "mark as watched" writes to /households/{hh}/watchEntries/{id}.
///
/// Trakt sync is the usual path into this collection; this service is the
/// manual one-tap fallback for users who aren't Trakt-linked, or who rated
/// something the Trakt history didn't capture. `addedSource` is stamped
/// `'manual'` so we can tell manual entries apart from Trakt imports later.
class WatchEntryService {
  WatchEntryService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;
  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _ref(String householdId, String entryId) =>
      _db.doc('households/$householdId/watchEntries/$entryId');

  /// Marks the title watched for `uid`. On first write, captures TMDB metadata
  /// from [details] (the map returned by `TmdbService.movieDetails` /
  /// `tvDetails`) so History / Stats / Unrated queues have the fields they
  /// need. Subsequent marks only flip `watched_by[uid]=true` and bump
  /// `last_watched_at`.
  Future<void> markWatched({
    required String householdId,
    required String uid,
    required String mediaType, // 'movie' | 'tv'
    required int tmdbId,
    required Map<String, dynamic> details,
  }) async {
    final entryId = WatchEntry.buildId(mediaType, tmdbId);
    final ref = _ref(householdId, entryId);
    final existing = await ref.get();
    final now = DateTime.now();

    if (!existing.exists) {
      final title = (details['title'] ?? details['name']) as String? ?? 'Untitled';
      final dateStr = (details['release_date'] ?? details['first_air_date']) as String?;
      final year = (dateStr == null || dateStr.isEmpty)
          ? null
          : int.tryParse(dateStr.split('-').first);
      final runtime = (details['runtime'] as num?)?.toInt() ??
          (((details['episode_run_time'] as List?)?.isNotEmpty ?? false)
              ? ((details['episode_run_time'] as List).first as num).toInt()
              : null);
      final genres = ((details['genres'] as List?) ?? const [])
          .whereType<Map>()
          .map((g) => g['name'] as String?)
          .whereType<String>()
          .toList();

      final entry = WatchEntry(
        id: entryId,
        mediaType: mediaType,
        tmdbId: tmdbId,
        title: title,
        year: year,
        posterPath: details['poster_path'] as String?,
        backdropPath: details['backdrop_path'] as String?,
        runtime: runtime,
        genres: genres,
        overview: details['overview'] as String?,
        firstWatchedAt: now,
        lastWatchedAt: now,
        watchedBy: {uid: true},
        addedSource: 'manual',
        addedBy: uid,
        addedAt: now,
      );
      await ref.set(entry.toFirestore());
      return;
    }

    await ref.set({
      'watched_by.$uid': true,
      'last_watched_at': Timestamp.fromDate(now),
    }, SetOptions(merge: true));
  }

  /// Clears `watched_by[uid]`. Leaves the entry in place because the partner
  /// may still have watched it, and episodes/ratings hang off the doc id.
  Future<void> unmarkWatched({
    required String householdId,
    required String uid,
    required String mediaType,
    required int tmdbId,
  }) async {
    final entryId = WatchEntry.buildId(mediaType, tmdbId);
    await _ref(householdId, entryId).set({
      'watched_by.$uid': false,
    }, SetOptions(merge: true));
  }
}
