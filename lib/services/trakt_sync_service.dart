import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/episode.dart';
import '../models/rating.dart';
import '../models/watch_entry.dart';
import 'tmdb_service.dart';
import 'trakt_service.dart';

/// Pulls Trakt history + ratings into Firestore. Runs client-side by design
/// (avoids requiring the Blaze plan for Cloud Functions at this stage).
///
/// Strategy:
///   • Full sync: no `start_at` → every page of /sync/history/{movies,shows}.
///   • Incremental: passes `last_trakt_sync` timestamp as `start_at`.
///   • Upserts by canonical id (`media_type:tmdbId` for entries;
///     `season_episode` for episodes) so repeat runs are idempotent.
///   • TMDB cross-ref: Trakt returns TMDB id on each item; a missing id
///     falls back to a title+year search, best-effort.
class TraktSyncService {
  TraktSyncService({
    required this.trakt,
    required this.tmdb,
    FirebaseFirestore? db,
  }) : _db = db ?? FirebaseFirestore.instance;

  final TraktService trakt;
  final TmdbService tmdb;
  final FirebaseFirestore _db;

  /// Run an incremental sync if >1hr since `last_trakt_sync` (or full if never
  /// synced). Returns true if any work was done.
  Future<bool> syncIfStale({
    required String householdId,
    required String uid,
    Duration minInterval = const Duration(hours: 1),
  }) async {
    final memberRef = _db.doc('households/$householdId/members/$uid');
    final snap = await memberRef.get();
    final data = snap.data();
    if (data == null || data['trakt_access_token'] == null) return false;
    final last = (data['last_trakt_sync'] as Timestamp?)?.toDate();
    if (last != null && DateTime.now().difference(last) < minInterval) return false;
    await runSync(householdId: householdId, uid: uid, startAt: last);
    return true;
  }

  /// `startAt == null` → full history pull. Otherwise delta from that point.
  Future<void> runSync({
    required String householdId,
    required String uid,
    DateTime? startAt,
  }) async {
    final token = await trakt.getLiveAccessToken(householdId: householdId, uid: uid);

    // Read the user's trakt_history_scope choice so we can stamp Rating.context
    // correctly on historical imports (shared→together, personal→solo,
    // mixed→null). Defaults to 'mixed' for legacy users who linked before the
    // field existed.
    final memberSnap = await _db.doc('households/$householdId/members/$uid').get();
    final scopeRaw = memberSnap.data()?['trakt_history_scope'] as String?;
    final ratingContext = _decodeRatingContext(scopeRaw);

    final movieRows = await trakt.fetchHistory(token: token, type: 'movies', startAt: startAt);
    final showRows = await trakt.fetchHistory(token: token, type: 'shows', startAt: startAt);

    for (final row in movieRows) {
      await _upsertMovieRow(householdId: householdId, uid: uid, row: row);
    }
    for (final row in showRows) {
      await _upsertShowEpisodeRow(householdId: householdId, uid: uid, row: row);
    }

    // Pull ratings at each level and mirror into Firestore for the current user.
    for (final level in const ['movies', 'shows', 'seasons', 'episodes']) {
      final ratings = await trakt.fetchRatings(token: token, type: level);
      for (final r in ratings) {
        await _upsertRatingRow(
          householdId: householdId,
          uid: uid,
          level: level,
          row: r,
          context: ratingContext,
        );
      }
    }

    await _db.doc('households/$householdId/members/$uid').set({
      'last_trakt_sync': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Maps the trakt_history_scope flag → Rating.context value for imports.
  /// Intentionally defined here (not as a dependency on TraktHistoryScope
  /// from providers/) so the service stays Flutter-free.
  static String? _decodeRatingContext(String? scope) {
    switch (scope) {
      case 'shared':
        return 'together';
      case 'personal':
        return 'solo';
      default:
        return null; // 'mixed', null, or any unknown value
    }
  }

  Future<void> _upsertMovieRow({
    required String householdId,
    required String uid,
    required Map<String, dynamic> row,
  }) async {
    final movie = row['movie'] as Map<String, dynamic>?;
    if (movie == null) return;
    final ids = movie['ids'] as Map<String, dynamic>? ?? const {};
    final tmdbId = (ids['tmdb'] as num?)?.toInt();
    if (tmdbId == null) return; // Can't link without TMDB.

    final watchedAt = DateTime.tryParse(row['watched_at'] as String? ?? '');
    final entryId = WatchEntry.buildId('movie', tmdbId);
    final ref = _db.doc('households/$householdId/watchEntries/$entryId');

    // Fetch TMDB metadata only for first insert; later writes just stamp fields.
    final existing = await ref.get();
    if (!existing.exists) {
      final details = await _safeTmdbMovie(tmdbId);
      final entry = WatchEntry(
        id: entryId,
        mediaType: 'movie',
        tmdbId: tmdbId,
        traktId: (ids['trakt'] as num?)?.toInt(),
        imdbId: ids['imdb'] as String?,
        title: (details?['title'] ?? movie['title'] ?? 'Untitled') as String,
        year: (details?['release_date'] as String?)?.split('-').first.let(int.tryParse) ??
            (movie['year'] as num?)?.toInt(),
        posterPath: details?['poster_path'] as String?,
        backdropPath: details?['backdrop_path'] as String?,
        runtime: (details?['runtime'] as num?)?.toInt(),
        genres: ((details?['genres'] as List?) ?? const [])
            .map((g) => (g as Map)['name'] as String)
            .toList(),
        overview: details?['overview'] as String?,
        firstWatchedAt: watchedAt,
        lastWatchedAt: watchedAt,
        watchedBy: {uid: true},
        addedSource: 'trakt',
        addedAt: DateTime.now(),
      );
      await ref.set(entry.toFirestore());
      return;
    }

    final update = <String, dynamic>{
      'watched_by.$uid': true,
    };
    if (watchedAt != null) {
      final existingLast = (existing.data()?['last_watched_at'] as Timestamp?)?.toDate();
      if (existingLast == null || watchedAt.isAfter(existingLast)) {
        update['last_watched_at'] = Timestamp.fromDate(watchedAt);
      }
    }
    await ref.set(update, SetOptions(merge: true));
  }

  Future<void> _upsertShowEpisodeRow({
    required String householdId,
    required String uid,
    required Map<String, dynamic> row,
  }) async {
    final show = row['show'] as Map<String, dynamic>?;
    final ep = row['episode'] as Map<String, dynamic>?;
    if (show == null || ep == null) return;
    final showIds = show['ids'] as Map<String, dynamic>? ?? const {};
    final tmdbId = (showIds['tmdb'] as num?)?.toInt();
    if (tmdbId == null) return;

    final watchedAt = DateTime.tryParse(row['watched_at'] as String? ?? '');
    final season = (ep['season'] as num?)?.toInt() ?? 0;
    final number = (ep['number'] as num?)?.toInt() ?? 0;
    final entryId = WatchEntry.buildId('tv', tmdbId);
    final entryRef = _db.doc('households/$householdId/watchEntries/$entryId');
    final epId = Episode.buildId(season, number);
    final epRef = entryRef.collection('episodes').doc(epId);

    final existingEntry = await entryRef.get();
    if (!existingEntry.exists) {
      final details = await _safeTmdbTv(tmdbId);
      final entry = WatchEntry(
        id: entryId,
        mediaType: 'tv',
        tmdbId: tmdbId,
        traktId: (showIds['trakt'] as num?)?.toInt(),
        imdbId: showIds['imdb'] as String?,
        title: (details?['name'] ?? show['title'] ?? 'Untitled') as String,
        year: (details?['first_air_date'] as String?)?.split('-').first.let(int.tryParse) ??
            (show['year'] as num?)?.toInt(),
        posterPath: details?['poster_path'] as String?,
        backdropPath: details?['backdrop_path'] as String?,
        runtime: ((details?['episode_run_time'] as List?)?.isNotEmpty ?? false)
            ? ((details!['episode_run_time'] as List).first as num).toInt()
            : null,
        genres: ((details?['genres'] as List?) ?? const [])
            .map((g) => (g as Map)['name'] as String)
            .toList(),
        overview: details?['overview'] as String?,
        firstWatchedAt: watchedAt,
        lastWatchedAt: watchedAt,
        watchedBy: {uid: true},
        lastSeason: season,
        lastEpisode: number,
        inProgressStatus: 'watching',
        addedSource: 'trakt',
        addedAt: DateTime.now(),
      );
      await entryRef.set(entry.toFirestore());
    } else {
      final update = <String, dynamic>{
        'watched_by.$uid': true,
      };
      if (watchedAt != null) {
        final existingLast = (existingEntry.data()?['last_watched_at'] as Timestamp?)?.toDate();
        if (existingLast == null || watchedAt.isAfter(existingLast)) {
          update['last_watched_at'] = Timestamp.fromDate(watchedAt);
          update['last_season'] = season;
          update['last_episode'] = number;
        }
      }
      await entryRef.set(update, SetOptions(merge: true));
    }

    // Episode doc — merge per-user timestamp without clobbering partner's.
    final updates = <String, dynamic>{
      'season': season,
      'number': number,
    };
    if ((ep['title'] as String?)?.isNotEmpty ?? false) updates['title'] = ep['title'];
    if ((ep['ids'] as Map?)?['tmdb'] != null) updates['tmdb_id'] = (ep['ids']['tmdb'] as num).toInt();
    if (watchedAt != null) updates['watched_by_at.$uid'] = Timestamp.fromDate(watchedAt);
    await epRef.set(updates, SetOptions(merge: true));
  }

  Future<void> _upsertRatingRow({
    required String householdId,
    required String uid,
    required String level, // 'movies' | 'shows' | 'seasons' | 'episodes'
    required Map<String, dynamic> row,
    String? context,
  }) async {
    final rating10 = (row['rating'] as num?)?.toInt();
    if (rating10 == null) return;
    final stars = TraktService.mapTraktToStars(rating10);
    if (stars == 0) return;
    final ratedAt = DateTime.tryParse(row['rated_at'] as String? ?? '') ?? DateTime.now();

    String? targetId;
    String ratingLevel;
    switch (level) {
      case 'movies':
        final tmdbId = (row['movie']?['ids']?['tmdb'] as num?)?.toInt();
        if (tmdbId == null) return;
        targetId = WatchEntry.buildId('movie', tmdbId);
        ratingLevel = 'movie';
        break;
      case 'shows':
        final tmdbId = (row['show']?['ids']?['tmdb'] as num?)?.toInt();
        if (tmdbId == null) return;
        targetId = WatchEntry.buildId('tv', tmdbId);
        ratingLevel = 'show';
        break;
      case 'seasons':
        final tmdbId = (row['show']?['ids']?['tmdb'] as num?)?.toInt();
        final season = (row['season']?['number'] as num?)?.toInt();
        if (tmdbId == null || season == null) return;
        targetId = '${WatchEntry.buildId('tv', tmdbId)}:s$season';
        ratingLevel = 'season';
        break;
      case 'episodes':
        final tmdbId = (row['show']?['ids']?['tmdb'] as num?)?.toInt();
        final season = (row['episode']?['season'] as num?)?.toInt();
        final number = (row['episode']?['number'] as num?)?.toInt();
        if (tmdbId == null || season == null || number == null) return;
        targetId = '${WatchEntry.buildId('tv', tmdbId)}:${Episode.buildId(season, number)}';
        ratingLevel = 'episode';
        break;
      default:
        return;
    }

    final id = Rating.buildId(uid, ratingLevel, targetId);
    final rating = Rating(
      id: id,
      uid: uid,
      level: ratingLevel,
      targetId: targetId,
      stars: stars,
      ratedAt: ratedAt,
      pushedToTrakt: true, // it came *from* Trakt
      context: context,
    );
    await _db.doc('households/$householdId/ratings/$id').set(rating.toFirestore());
  }

  Future<Map<String, dynamic>?> _safeTmdbMovie(int id) async {
    try {
      return await tmdb.movieDetails(id);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _safeTmdbTv(int id) async {
    try {
      return await tmdb.tvDetails(id);
    } catch (_) {
      return null;
    }
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
