import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/recommendation.dart';
import '../models/watchlist_item.dart';
import 'tmdb_service.dart';

/// Client for Phase 7's scored-recommendations pipeline:
/// - `refreshTasteProfile` → CF that recomputes `/tasteProfile` from ratings.
/// - `refresh` → assembles candidates (watchlist + trending) and hands them
///   to the `scoreRecommendations` CF which writes to `/recommendations`.
///
/// Streams + ad-hoc reads are kept here so providers stay thin.
class RecommendationsService {
  final FirebaseFirestore _db;
  final FirebaseFunctions _fns;
  final TmdbService _tmdb;

  RecommendationsService({
    FirebaseFirestore? db,
    FirebaseFunctions? fns,
    TmdbService? tmdb,
  })  : _db = db ?? FirebaseFirestore.instance,
        _fns = fns ?? FirebaseFunctions.instance,
        _tmdb = tmdb ?? TmdbService();

  CollectionReference<Map<String, dynamic>> _col(String hh) =>
      _db.collection('households/$hh/recommendations');

  Stream<List<Recommendation>> stream(String householdId) {
    return _col(householdId)
        .orderBy('match_score', descending: true)
        .limit(50)
        .snapshots()
        .map((s) => s.docs.map(Recommendation.fromDoc).toList());
  }

  Future<List<Recommendation>> fetchTopForDecide(
    String householdId, {
    int limit = 20,
    Set<String> exclude = const {},
  }) async {
    final snap = await _col(householdId)
        .orderBy('match_score', descending: true)
        .limit(limit + exclude.length)
        .get();
    return snap.docs
        .map(Recommendation.fromDoc)
        .where((r) => !exclude.contains('${r.mediaType}:${r.tmdbId}'))
        .take(limit)
        .toList();
  }

  Future<void> refreshTasteProfile(String householdId) async {
    await _fns
        .httpsCallable('generateTasteProfile')
        .call({'householdId': householdId});
  }

  /// Builds a candidate pool from the shared watchlist plus TMDB trending,
  /// then asks Claude to score them. Result lands in `/recommendations` and
  /// is picked up by the stream.
  Future<void> refresh(
    String householdId, {
    required List<WatchlistItem> watchlist,
    int trendingCap = 20,
  }) async {
    final candidates = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final w in watchlist) {
      final key = '${w.mediaType}:${w.tmdbId}';
      if (seen.add(key)) {
        candidates.add({
          'media_type': w.mediaType,
          'tmdb_id': w.tmdbId,
          'title': w.title,
          'year': w.year,
          'poster_path': w.posterPath,
          'genres': w.genres,
          'overview': w.overview,
          'source': 'watchlist',
        });
      }
    }

    try {
      final trending = await _tmdb.trendingMovies();
      final rows = (trending['results'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      for (final m in rows.take(trendingCap)) {
        final id = (m['id'] as num?)?.toInt();
        if (id == null) continue;
        final mediaType = (m['media_type'] as String?) ?? 'movie';
        final key = '$mediaType:$id';
        if (!seen.add(key)) continue;
        final date = (m['release_date'] ?? m['first_air_date']) as String?;
        candidates.add({
          'media_type': mediaType,
          'tmdb_id': id,
          'title': (m['title'] ?? m['name']) as String? ?? 'Untitled',
          'year': (date != null && date.length >= 4)
              ? int.tryParse(date.substring(0, 4))
              : null,
          'poster_path': m['poster_path'] as String?,
          'overview': m['overview'] as String?,
          'source': 'trending',
        });
      }
    } catch (_) {
      // Trending is best-effort — the watchlist alone is still a valid pool.
    }

    if (candidates.isEmpty) return;

    await _fns.httpsCallable('scoreRecommendations').call({
      'householdId': householdId,
      'candidates': candidates,
    });
  }
}
