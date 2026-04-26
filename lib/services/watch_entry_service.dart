import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/episode.dart';
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

    // Dot notation is only honoured by update(); set(merge:true) would store
    // the literal key "watched_by.<uid>" with a dot in the name.
    await ref.update({
      'watched_by.$uid': true,
      'last_watched_at': Timestamp.fromDate(now),
    });
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
    final ref = _ref(householdId, entryId);
    final snap = await ref.get();
    if (!snap.exists) return;
    await ref.update({'watched_by.$uid': false});
  }

  /// Marks the title as currently-being-watched for the household. Used for
  /// TV where "in progress" is a real state distinct from "watched".
  /// Creates the entry on first write the same way `markWatched` does.
  Future<void> markWatching({
    required String householdId,
    required String uid,
    required String mediaType,
    required int tmdbId,
    required Map<String, dynamic> details,
  }) async {
    final entryId = WatchEntry.buildId(mediaType, tmdbId);
    final ref = _ref(householdId, entryId);
    final existing = await ref.get();
    final now = DateTime.now();

    if (!existing.exists) {
      final title =
          (details['title'] ?? details['name']) as String? ?? 'Untitled';
      final dateStr =
          (details['release_date'] ?? details['first_air_date']) as String?;
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
        watchedBy: {uid: false},
        inProgressStatus: 'watching',
        addedSource: 'manual',
        addedBy: uid,
        addedAt: now,
      );
      await ref.set(entry.toFirestore());
      return;
    }

    await ref.update({
      'watched_by.$uid': false,
      'in_progress_status': 'watching',
    });
  }

  /// Clears the in-progress watching status without touching watched_by.
  Future<void> unmarkWatching({
    required String householdId,
    required String mediaType,
    required int tmdbId,
  }) async {
    final entryId = WatchEntry.buildId(mediaType, tmdbId);
    final ref = _ref(householdId, entryId);
    final snap = await ref.get();
    if (!snap.exists) return;
    await ref.update({'in_progress_status': FieldValue.delete()});
  }

  /// Marks a single TV episode watched for `uid`. Ensures the parent
  /// watchEntry exists (creates it as `inProgressStatus='watching'` on first
  /// write so the show shows up under Library → Watching), then deep-merges
  /// the episode metadata + `watched_by_at[uid]=now` onto the episode
  /// sub-doc. Bumps the parent's `last_watched_at` / `last_season` /
  /// `last_episode` when the new mark is newer than what's stored.
  ///
  /// `set(merge: true)` with a NESTED MAP value (`watched_by_at: {uid: t}`)
  /// deep-merges per-key — the partner's existing entry is preserved. This
  /// is different from FLAT dot-notation keys (`'watched_by_at.<uid>'`),
  /// which `set(merge:true)` would store as a literal field name. See
  /// gotcha 27.
  Future<void> markEpisodeWatched({
    required String householdId,
    required String uid,
    required int tmdbId,
    required int season,
    required int number,
    Map<String, dynamic> parentDetails = const {},
    Map<String, dynamic> episodeMeta = const {},
  }) async {
    final entryId = WatchEntry.buildId('tv', tmdbId);
    final entryRef = _ref(householdId, entryId);
    final now = DateTime.now();

    final existingEntry = await entryRef.get();
    if (!existingEntry.exists) {
      await markWatching(
        householdId: householdId,
        uid: uid,
        mediaType: 'tv',
        tmdbId: tmdbId,
        details: parentDetails,
      );
    }

    final existingLast =
        (existingEntry.data()?['last_watched_at'] as Timestamp?)?.toDate();
    if (existingLast == null || now.isAfter(existingLast)) {
      await entryRef.update({
        'last_watched_at': Timestamp.fromDate(now),
        'last_season': season,
        'last_episode': number,
      });
    }

    final epRef = entryRef.collection('episodes').doc(Episode.buildId(season, number));
    final epDoc = <String, dynamic>{
      'season': season,
      'number': number,
      'watched_by_at': {uid: Timestamp.fromDate(now)},
    };
    final title = episodeMeta['name'] as String?;
    if (title != null && title.isNotEmpty) epDoc['title'] = title;
    final overview = episodeMeta['overview'] as String?;
    if (overview != null && overview.isNotEmpty) epDoc['overview'] = overview;
    final still = episodeMeta['still_path'] as String?;
    if (still != null && still.isNotEmpty) epDoc['still_path'] = still;
    final epTmdbId = (episodeMeta['id'] as num?)?.toInt();
    if (epTmdbId != null) epDoc['tmdb_id'] = epTmdbId;
    final runtime = (episodeMeta['runtime'] as num?)?.toInt();
    if (runtime != null) epDoc['runtime'] = runtime;
    final airDateStr = episodeMeta['air_date'] as String?;
    final airedAt = (airDateStr == null || airDateStr.isEmpty)
        ? null
        : DateTime.tryParse(airDateStr);
    if (airedAt != null) epDoc['aired_at'] = Timestamp.fromDate(airedAt);

    await epRef.set(epDoc, SetOptions(merge: true));
  }

  /// Clears `watched_by_at[uid]` on the episode sub-doc. Leaves the rest of
  /// the episode metadata + the partner's timestamp intact. No-op if the
  /// episode doc doesn't exist (typical after Trakt-only households mark
  /// episodes manually).
  Future<void> unmarkEpisodeWatched({
    required String householdId,
    required String uid,
    required int tmdbId,
    required int season,
    required int number,
  }) async {
    final entryId = WatchEntry.buildId('tv', tmdbId);
    final epRef = _ref(householdId, entryId)
        .collection('episodes')
        .doc(Episode.buildId(season, number));
    final snap = await epRef.get();
    if (!snap.exists) return;
    await epRef.update({'watched_by_at.$uid': FieldValue.delete()});
  }
}
