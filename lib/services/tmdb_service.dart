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
      _get(_uri('/movie/$tmdbId', {'append_to_response': 'credits,keywords,similar'}));

  Future<Map<String, dynamic>> tvDetails(int tmdbId) =>
      _get(_uri('/tv/$tmdbId', {'append_to_response': 'credits,keywords,similar'}));

  Future<Map<String, dynamic>> tvSeason(int tmdbId, int seasonNumber) =>
      _get(_uri('/tv/$tmdbId/season/$seasonNumber'));

  Future<Map<String, dynamic>> tvEpisode(int tmdbId, int season, int episode) =>
      _get(_uri('/tv/$tmdbId/season/$season/episode/$episode'));

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

  Future<Map<String, dynamic>> topRatedMovies({int page = 1}) =>
      _get(_uri('/movie/top_rated', {'page': '$page'}));

  Future<Map<String, dynamic>> topRatedTv({int page = 1}) =>
      _get(_uri('/tv/top_rated', {'page': '$page'}));

  Future<Map<String, dynamic>> listDetails(int listId) =>
      _get(_uri('/list/$listId'));

  Future<Map<String, dynamic>> discoverMovies(Map<String, String> params) =>
      _get(_uri('/discover/movie', params));

  Future<Map<String, dynamic>> discoverTv(Map<String, String> params) =>
      _get(_uri('/discover/tv', params));

  /// Fills a candidate pool via `/discover` with a fallback ladder so narrow
  /// filters (e.g. "War, 1970-1989") don't produce ~0 results.
  ///
  /// Ladder:
  ///  1. OR-join all genre ids (`|` delimiter) + year bounds. Paginate until
  ///     the pool hits [poolFloor] or [maxPages].
  ///  2. If still below [poolFloor] and there are multiple genres, fire one
  ///     discover per genre and merge (catches obscure genres starved by
  ///     popularity sort).
  ///  3. If still below [poolFloor] and year bounds were applied, drop the
  ///     year constraint and retry step 1.
  ///
  /// All results are deduped by `id` and returned in the normal
  /// `{results: [...]}` shape so [buildCandidates] treats them uniformly.
  /// [mediaType] is either `'movie'` or `'tv'`; the date field name and
  /// pagination endpoint differ but the response shape matches.
  Future<Map<String, dynamic>> discoverPaged({
    required String mediaType,
    List<int> genreIds = const [],
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
    }) {
      final p = <String, String>{
        'sort_by': 'vote_average.desc',
        'vote_count.gte': '$minVoteCount',
      };
      if (ids.isNotEmpty) p['with_genres'] = ids.join('|');
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

    Future<void> drainPages(List<int> ids, {required bool withYear}) async {
      for (var page = 1; page <= maxPages; page++) {
        if (merged.length >= poolFloor) return;
        final params = {...baseParams(ids: ids, withYear: withYear), 'page': '$page'};
        try {
          final payload = isTv ? await discoverTv(params) : await discoverMovies(params);
          consume(payload);
          // TMDB returns a `total_pages` hint; stop if we've exhausted it.
          final totalPages = (payload['total_pages'] as num?)?.toInt() ?? 1;
          if (page >= totalPages) return;
        } catch (_) {
          return; // give up this rung on error; later rungs can still fire
        }
      }
    }

    // Rung 1: OR-joined genres with year bounds.
    await drainPages(genreIds, withYear: true);

    // Rung 2: per-genre fallback if multi-genre query was sparse.
    if (merged.length < poolFloor && genreIds.length > 1) {
      for (final id in genreIds) {
        if (merged.length >= poolFloor) break;
        await drainPages([id], withYear: true);
      }
    }

    // Rung 3: drop year entirely if the year constraint was the limiter.
    final hasYear = minYear != null || maxYear != null;
    if (merged.length < poolFloor && hasYear) {
      await drainPages(genreIds, withYear: false);
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
