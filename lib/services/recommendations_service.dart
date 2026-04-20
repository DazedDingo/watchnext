import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../models/recommendation.dart';
import '../models/watchlist_item.dart';
import '../providers/year_filter_provider.dart';
import '../utils/tmdb_genres.dart';
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
        // Callables live in europe-west2 (co-located with Firestore in London).
        _fns = fns ?? FirebaseFunctions.instanceFor(region: 'europe-west2'),
        _tmdb = tmdb ?? TmdbService();

  CollectionReference<Map<String, dynamic>> _col(String hh) =>
      _db.collection('households/$hh/recommendations');

  Stream<List<Recommendation>> stream(String householdId) {
    return _col(householdId)
        .orderBy('match_score', descending: true)
        .limit(120)
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

  /// Builds a candidate pool from the shared watchlist plus four TMDB
  /// sources (trending movies + TV, top-rated movies + TV) and Reddit buzz,
  /// then asks Claude to score them. Result lands in `/recommendations` and
  /// is picked up by the stream.
  ///
  /// Each TMDB source is fetched independently and best-effort: a failure
  /// in one (e.g. TMDB rate-limit on top-rated) doesn't blank the pool.
  /// [tmdbCap] defaults to 10 per source — with four sources that's up to 40
  /// TMDB candidates, which plus watchlist + Reddit stays comfortably inside
  /// the server-side MAX_CANDIDATES=50 slice the scoring CF enforces.
  Future<void> refresh(
    String householdId, {
    required List<WatchlistItem> watchlist,
    int tmdbCap = 10,
    Set<String> genreFilters = const {},
    YearRange yearRange = const YearRange.unbounded(),
  }) async {
    List<Map<String, dynamic>> redditRows = const [];
    try {
      final snap = await _db
          .collection('redditMentions')
          .orderBy('mention_score', descending: true)
          .limit(20)
          .get();
      redditRows = snap.docs.map((d) => d.data()).toList();
    } catch (_) {
      // Best-effort; no Reddit data is fine.
    }

    // Baseline four sources are always fetched — they give us a broad pool
    // even when the user hasn't picked filters.
    final baseline = await Future.wait([
      _safeTmdb(() => _tmdb.trendingMovies()),
      _safeTmdb(() => _tmdb.trendingTv()),
      _safeTmdb(() => _tmdb.topRatedMovies()),
      _safeTmdb(() => _tmdb.topRatedTv()),
    ]);

    // Discover sources fire only when the user has narrowed the request.
    // Unfiltered state gets the same pool as before, so we don't spend
    // TMDB quota / latency on queries that won't improve relevance.
    Map<String, dynamic> discoverMovies = const {};
    Map<String, dynamic> discoverTv = const {};
    final hasFilters = genreFilters.isNotEmpty || yearRange.hasAnyBound;
    if (hasFilters) {
      final movieIds = genreIdsFromNames(genreFilters, mediaType: 'movie');
      final tvIds = genreIdsFromNames(genreFilters, mediaType: 'tv');
      final discoverResults = await Future.wait([
        _safeTmdb(() => _tmdb.discoverPaged(
              mediaType: 'movie',
              genreIds: movieIds,
              minYear: yearRange.minYear,
              maxYear: yearRange.maxYear,
            )),
        _safeTmdb(() => _tmdb.discoverPaged(
              mediaType: 'tv',
              genreIds: tvIds,
              minYear: yearRange.minYear,
              maxYear: yearRange.maxYear,
            )),
      ]);
      discoverMovies = discoverResults[0];
      discoverTv = discoverResults[1];
    }

    final candidates = buildCandidates(
      watchlist: watchlist,
      redditMentions: redditRows,
      trendingMoviesPayload: baseline[0],
      trendingTvPayload: baseline[1],
      topRatedMoviesPayload: baseline[2],
      topRatedTvPayload: baseline[3],
      discoverMoviesPayload: discoverMovies,
      discoverTvPayload: discoverTv,
      tmdbCap: tmdbCap,
    );

    if (candidates.isEmpty) return;

    await _fns.httpsCallable('scoreRecommendations').call({
      'householdId': householdId,
      'candidates': candidates,
    });
  }

  /// Runs a TMDB fetch and swallows any error into an empty payload so
  /// `Future.wait` never rejects on a single transient TMDB failure.
  Future<Map<String, dynamic>> _safeTmdb(
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    try {
      return await fetch();
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}

/// Pure candidate-list builder — exposed for testing. Merges watchlist,
/// Reddit mentions, and four TMDB sources (trending movies + TV, top-rated
/// movies + TV) into the payload shape the `scoreRecommendations` CF
/// expects. Handles genre resolution (id → name) so the mood-pill filter
/// has something to match against.
///
/// Order: watchlist first, then Reddit, then TMDB sources in declaration
/// order. Dedup by `{mediaType}:{tmdbId}`. Each TMDB source is capped to
/// [tmdbCap] rows individually so one noisy source can't crowd out the
/// others.
List<Map<String, dynamic>> buildCandidates({
  required List<WatchlistItem> watchlist,
  List<Map<String, dynamic>> redditMentions = const [],
  Map<String, dynamic> trendingMoviesPayload = const {},
  Map<String, dynamic> trendingTvPayload = const {},
  Map<String, dynamic> topRatedMoviesPayload = const {},
  Map<String, dynamic> topRatedTvPayload = const {},
  Map<String, dynamic> discoverMoviesPayload = const {},
  Map<String, dynamic> discoverTvPayload = const {},
  int tmdbCap = 20,
  int discoverCap = 40,
}) {
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
        'runtime': w.runtime,
        'overview': w.overview,
        'source': 'watchlist',
      });
    }
  }

  for (final m in redditMentions) {
    final id = (m['tmdb_id'] as num?)?.toInt();
    if (id == null) continue;
    final mediaType = (m['media_type'] as String?) ?? 'movie';
    final key = '$mediaType:$id';
    if (!seen.add(key)) continue;
    candidates.add({
      'media_type': mediaType,
      'tmdb_id': id,
      'title': m['title'] as String? ?? 'Untitled',
      'year': (m['year'] as num?)?.toInt(),
      'poster_path': m['poster_path'] as String?,
      'genres': coerceGenres(m['genres'] ?? m['genre_ids'], mediaType: mediaType),
      'runtime': (m['runtime'] as num?)?.toInt(),
      'overview': m['overview'] as String?,
      'source': 'reddit',
    });
  }

  // TMDB sources: each has a default media_type (used when the row shape
  // doesn't carry one), a source tag so the UI can badge it, and a per-
  // source row cap. Discover sources get a larger cap because the user
  // explicitly narrowed the query — crowding out baseline pool by up to
  // `discoverCap` rows each is the whole point.
  final tmdbSources = <(Map<String, dynamic>, String, String, int)>[
    (trendingMoviesPayload, 'movie', 'trending', tmdbCap),
    (trendingTvPayload, 'tv', 'trending', tmdbCap),
    (topRatedMoviesPayload, 'movie', 'top_rated', tmdbCap),
    (topRatedTvPayload, 'tv', 'top_rated', tmdbCap),
    (discoverMoviesPayload, 'movie', 'discover', discoverCap),
    (discoverTvPayload, 'tv', 'discover', discoverCap),
  ];

  for (final (payload, defaultMediaType, source, cap) in tmdbSources) {
    final rows = (payload['results'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    for (final m in rows.take(cap)) {
      final id = (m['id'] as num?)?.toInt();
      if (id == null) continue;
      final mediaType = (m['media_type'] as String?) ?? defaultMediaType;
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
        'genres': coerceGenres(m['genre_ids'], mediaType: mediaType),
        'overview': m['overview'] as String?,
        'source': source,
      });
    }
  }

  return candidates;
}
