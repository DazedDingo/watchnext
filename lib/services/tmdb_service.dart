import 'dart:convert';
import 'package:http/http.dart' as http;

/// TMDB REST client. API key read from --dart-define=TMDB_API_KEY at build time.
/// Run with:  flutter run --dart-define=TMDB_API_KEY=xxx
class TmdbService {
  static const String _base = 'https://api.themoviedb.org/3';
  static const String _imageBase = 'https://image.tmdb.org/t/p';
  static const String _apiKey = String.fromEnvironment('TMDB_API_KEY');

  /// Per-request timeout. `discoverPaged` can fan out to ~18 TMDB calls in a
  /// single pull-to-refresh, and `http.Client` has no default timeout — one
  /// stuck request would hang the whole refresh spinner forever.
  static const Duration kRequestTimeout = Duration(seconds: 15);

  final http.Client _client;
  final Duration _timeout;
  TmdbService({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        _timeout = timeout ?? kRequestTimeout;

  Uri _uri(String path, [Map<String, String>? params]) => Uri.parse('$_base$path').replace(
        queryParameters: {
          'api_key': _apiKey,
          'language': 'en-US',
          ...?params,
        },
      );

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final res = await _client.get(uri).timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('TMDB ${res.statusCode}: ${res.body}');
    }
    return json.decode(res.body) as Map<String, dynamic>;
  }

  /// Multi search across movies + TV + people.
  Future<Map<String, dynamic>> searchMulti(String query, {int page = 1}) =>
      _get(_uri('/search/multi', {'query': query, 'page': '$page'}));

  Future<Map<String, dynamic>> movieDetails(int tmdbId) =>
      _get(_uri('/movie/$tmdbId',
          {'append_to_response': 'credits,keywords,similar,videos'}));

  Future<Map<String, dynamic>> tvDetails(int tmdbId) =>
      _get(_uri('/tv/$tmdbId',
          {'append_to_response': 'credits,keywords,similar,external_ids,videos'}));

  Future<Map<String, dynamic>> tvSeason(int tmdbId, int seasonNumber) =>
      _get(_uri('/tv/$tmdbId/season/$seasonNumber'));

  Future<Map<String, dynamic>> tvEpisode(int tmdbId, int season, int episode) =>
      _get(_uri('/tv/$tmdbId/season/$season/episode/$episode'));

  /// Per-episode IMDb id resolution. Trakt's `episode.ids.imdb` is often
  /// null; TMDB's episode-level `/external_ids` is the reliable path. Used
  /// by `_EpisodeRow` on title detail to deep-link directly to IMDb's
  /// episode page (`https://www.imdb.com/title/{episodeImdbId}/`) rather
  /// than the show's season page.
  Future<Map<String, dynamic>> tvEpisodeExternalIds(
          int tmdbId, int season, int episode) =>
      _get(_uri('/tv/$tmdbId/season/$season/episode/$episode/external_ids'));

  Future<Map<String, dynamic>> similarMovies(int tmdbId, {int page = 1}) =>
      _get(_uri('/movie/$tmdbId/similar', {'page': '$page'}));

  Future<Map<String, dynamic>> similarTv(int tmdbId, {int page = 1}) =>
      _get(_uri('/tv/$tmdbId/similar', {'page': '$page'}));

  Future<Map<String, dynamic>> trendingMovies({String window = 'week'}) =>
      _get(_uri('/trending/movie/$window'));

  Future<Map<String, dynamic>> trendingTv({String window = 'week'}) =>
      _get(_uri('/trending/tv/$window'));

  Future<Map<String, dynamic>> upcomingMovies({int page = 1}) =>
      _get(_uri('/movie/upcoming', {'page': '$page'}));

  /// TV titles currently in an active airing window. Used for the "Upcoming
  /// for you" Home section — TMDB has no first-run-only TV feed, so we treat
  /// "airing now and within the next week" as the TV analogue to
  /// `/movie/upcoming`.
  Future<Map<String, dynamic>> onTheAirTv({int page = 1}) =>
      _get(_uri('/tv/on_the_air', {'page': '$page'}));

  Future<Map<String, dynamic>> topRatedMovies({int page = 1}) =>
      _get(_uri('/movie/top_rated', {'page': '$page'}));

  Future<Map<String, dynamic>> topRatedTv({int page = 1}) =>
      _get(_uri('/tv/top_rated', {'page': '$page'}));

  Future<Map<String, dynamic>> listDetails(int listId) =>
      _get(_uri('/list/$listId'));

  /// Fetches user reviews for a title. TMDB caps at 20 per page; we typically
  /// only surface the top 3–5 in the UI so one page is plenty.
  Future<Map<String, dynamic>> reviews(
    String mediaType,
    int tmdbId, {
    int page = 1,
  }) =>
      _get(_uri('/$mediaType/$tmdbId/reviews', {'page': '$page'}));

  /// Lean `/external_ids` call — returns `{imdb_id, facebook_id, ...}` without
  /// the full details payload. Used to backfill `imdb_id` onto recommendation
  /// docs so the row-level IMDb rating chip can render.
  Future<Map<String, dynamic>> externalIds(String mediaType, int tmdbId) =>
      _get(_uri('/$mediaType/$tmdbId/external_ids'));

  /// Lean `/{mt}/{id}/keywords` call — returns just the keyword list without
  /// the full details payload. Used by the background genre-augmenter to
  /// widen a rec doc's `genres` via `kKeywordToExtraGenres`. Response shape
  /// differs by media type: movies carry `{keywords: [...]}`, tv carries
  /// `{results: [...]}`. Callers handle both.
  Future<Map<String, dynamic>> keywords(String mediaType, int tmdbId) =>
      _get(_uri('/$mediaType/$tmdbId/keywords'));

  Future<Map<String, dynamic>> discoverMovies(Map<String, String> params) =>
      _get(_uri('/discover/movie', params));

  Future<Map<String, dynamic>> discoverTv(Map<String, String> params) =>
      _get(_uri('/discover/tv', params));

  /// Fills a candidate pool via `/discover` with a fallback ladder so narrow
  /// filters (e.g. "Sci-Fi + War" or "War, 1970-1989") don't produce ~0
  /// results after the client-side AND intersection.
  ///
  /// Ladder (short-circuits once [poolFloor] is hit):
  ///  1. AND-join genres (`,`) + year bounds — matches the client-side
  ///     intersection exactly, so every row returned here survives the
  ///     filter. Skipped when only one genre is selected (AND ≡ OR for len
  ///     1, so rung 2 covers it).
  ///  2. OR-join genres (`|`) + year bounds — widens the pool to the union.
  ///     Feeds the keyword-augmenter: sci-fi titles with `space marine` /
  ///     `alien invasion` keywords get `War` added and pass the client
  ///     intersection.
  ///  3. Per-genre fallback (one discover per genre, year preserved) —
  ///     catches obscure single genres starved by the OR-joined popularity
  ///     sort.
  ///  4. AND-join without year — year was the limiter; try the strict
  ///     intersection again with a wider window.
  ///  5. OR-join without year — same union, no year floor.
  ///  6. Per-genre without year — last-resort catch for tiny pools.
  ///
  /// All results are deduped by `id` and returned in the normal
  /// `{results: [...]}` shape so [buildCandidates] treats them uniformly.
  /// [mediaType] is either `'movie'` or `'tv'`; the date field name and
  /// pagination endpoint differ but the response shape matches.
  Future<Map<String, dynamic>> discoverPaged({
    required String mediaType,
    List<int> genreIds = const [],
    List<int> keywordIds = const [],
    List<int> excludeGenreIds = const [],
    String? withCompanies,
    String? sortBy,
    int? maxVoteCount,
    int? minYear,
    int? maxYear,
    int? minRuntime,
    int? maxRuntime,
    int minVoteCount = 50,
    int poolFloor = 40,
    int maxPages = 5,
  }) async {
    final isTv = mediaType == 'tv';
    final dateGte = isTv ? 'first_air_date.gte' : 'primary_release_date.gte';
    final dateLte = isTv ? 'first_air_date.lte' : 'primary_release_date.lte';

    final seen = <int>{};
    final merged = <Map<String, dynamic>>[];

    void consume(Map<String, dynamic> payload) {
      final rows = (payload['results'] as List? ?? const [])
          .whereType<Map<String, dynamic>>();
      for (final r in rows) {
        final id = (r['id'] as num?)?.toInt();
        if (id == null || !seen.add(id)) continue;
        merged.add(r);
      }
    }

    Map<String, String> baseParams({
      required List<int> ids,
      required bool withYear,
      required String joinOp,
    }) {
      final p = <String, String>{
        'sort_by': sortBy ?? 'vote_average.desc',
        'vote_count.gte': '$minVoteCount',
      };
      // Vote-count ceiling is how we implement the "Underseen" sort — TMDB
      // has no native "hidden gems" sort, but `vote_count.lte` achieves the
      // same effect by cutting the blockbuster tail.
      if (maxVoteCount != null) p['vote_count.lte'] = '$maxVoteCount';
      // Company filter (e.g. Criterion Collection distributor = 1771).
      // Preserved across fallback rungs for the same reason as keywords —
      // a curated-source query that drops the company constraint isn't
      // Criterion anymore.
      if (withCompanies != null && withCompanies.isNotEmpty) {
        p['with_companies'] = withCompanies;
      }
      if (ids.isNotEmpty) p['with_genres'] = ids.join(joinOp);
      // Keywords (e.g. TMDB's "oscar-winning-film" keyword 210024) are
      // preserved across every fallback rung — dropping them would defeat
      // the whole point of the filter (e.g. an Oscar-only query that fell
      // back to "all genres" would suddenly show non-Oscar fare).
      if (keywordIds.isNotEmpty) p['with_keywords'] = keywordIds.join(',');
      // Negative genre filter — also preserved across every fallback rung
      // for the same reason as keywords: the whole point of the toggle is to
      // keep these titles out even when the pool is thin.
      if (excludeGenreIds.isNotEmpty) {
        p['without_genres'] = excludeGenreIds.join(',');
      }
      if (withYear && minYear != null) p[dateGte] = '$minYear-01-01';
      if (withYear && maxYear != null) p[dateLte] = '$maxYear-12-31';
      // Runtime bounds are server-side filtered by TMDB — the only way to
      // guarantee a runtime-aware pool since trending/top_rated strip runtime
      // from their payloads. On /discover/tv, `with_runtime` targets the
      // episode runtime (not season length), which matches how our
      // Recommendation.runtime behaves on the client for TV too.
      if (minRuntime != null) p['with_runtime.gte'] = '$minRuntime';
      if (maxRuntime != null) p['with_runtime.lte'] = '$maxRuntime';
      return p;
    }

    Future<void> drainPages(
      List<int> ids, {
      required bool withYear,
      String joinOp = '|',
    }) async {
      for (var page = 1; page <= maxPages; page++) {
        if (merged.length >= poolFloor) return;
        final params = {
          ...baseParams(ids: ids, withYear: withYear, joinOp: joinOp),
          'page': '$page',
        };
        try {
          final payload = isTv ? await discoverTv(params) : await discoverMovies(params);
          consume(payload);
          // TMDB returns a `total_pages` hint; stop if we've exhausted it.
          final totalPages = (payload['total_pages'] as num?)?.toInt() ?? 1;
          if (page >= totalPages) return;
        } catch (_) {
          // A single page failure (timeout, rate-limit blip) shouldn't kill
          // the whole rung — remaining pages are usually fine. Continue.
          continue;
        }
      }
    }

    final multiGenre = genreIds.length > 1;
    final hasYear = minYear != null || maxYear != null;

    // Rung 1: AND-joined genres + year. Only meaningful for multi-genre
    // queries — for a single genre, AND ≡ OR and rung 2 would re-fetch the
    // identical page. Matches the client-side intersection exactly so every
    // row here survives the filter.
    if (multiGenre) {
      await drainPages(genreIds, withYear: true, joinOp: ',');
    }

    // Rung 2: OR-joined genres + year. For single-genre queries this is the
    // primary rung; for multi-genre it widens the pool so the keyword
    // augmenter has more candidates to promote (e.g. sci-fi titles with
    // `alien invasion` → add War → pass intersection).
    if (merged.length < poolFloor) {
      await drainPages(genreIds, withYear: true, joinOp: '|');
    }

    // Rung 3: per-genre fallback (year preserved). Catches obscure single
    // genres starved by the union's popularity sort.
    if (merged.length < poolFloor && multiGenre) {
      for (final id in genreIds) {
        if (merged.length >= poolFloor) break;
        await drainPages([id], withYear: true, joinOp: ',');
      }
    }

    // Rung 4: AND-joined genres without year. Year bounds were the limiter;
    // retry the strict intersection with a wider window.
    if (merged.length < poolFloor && hasYear && multiGenre) {
      await drainPages(genreIds, withYear: false, joinOp: ',');
    }

    // Rung 5: OR-joined genres without year. Existing behaviour pre-AND —
    // last-ditch union across the whole catalog.
    if (merged.length < poolFloor && hasYear) {
      await drainPages(genreIds, withYear: false, joinOp: '|');
    }

    // Rung 6: per-genre without year. Final safety net — ensures we always
    // surface *something* for any individual genre that has entries on TMDB.
    if (merged.length < poolFloor && multiGenre) {
      for (final id in genreIds) {
        if (merged.length >= poolFloor) break;
        await drainPages([id], withYear: false, joinOp: ',');
      }
    }

    return {'results': merged};
  }

  /// Cross-reference an external ID (IMDb `tt…`, TVDB id, etc.) to TMDB ids.
  /// Used by the share-sheet flow to resolve IMDb/Letterboxd/generic links.
  Future<Map<String, dynamic>> findByExternalId(String externalId, {String source = 'imdb_id'}) =>
      _get(_uri('/find/$externalId', {'external_source': source}));

  /// Builds poster/backdrop URLs. `size` examples: 'w185', 'w342', 'w500', 'original'.
  static String? imageUrl(String? path, {String size = 'w500'}) =>
      path == null || path.isEmpty ? null : '$_imageBase/$size$path';

  void dispose() => _client.close();
}
