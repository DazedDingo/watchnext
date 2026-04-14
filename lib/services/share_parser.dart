import 'tmdb_service.dart';

/// Resolves a URL or freeform text from the Android share sheet to a TMDB
/// title. Strategy (in order):
///   1. Pull a URL out of the incoming text — share targets often arrive as
///      "Check this out! https://imdb.com/title/tt0133093".
///   2. Pattern-match the host:
///        - themoviedb.org/movie/ID or /tv/ID → use ID directly.
///        - imdb.com/title/ttXXXXXXX → TMDB /find by external id.
///        - letterboxd.com/film/slug → slug → title → TMDB search.
///        - Google/fallback → extract query/title → TMDB search.
///   3. If nothing matched, fall back to searching TMDB with the full text.
class ShareParser {
  ShareParser({required this.tmdb});
  final TmdbService tmdb;

  Future<ShareMatch?> parse(String input) async {
    final text = input.trim();
    if (text.isEmpty) return null;

    final url = _firstUrl(text);
    if (url != null) {
      final direct = await _resolveUrl(url);
      if (direct != null) return direct;
    }

    // Fallback: treat the whole payload as a search query (strip URLs first).
    final query = _stripUrls(text);
    if (query.isEmpty) return null;
    return _searchFirst(query);
  }

  Future<ShareMatch?> _resolveUrl(Uri url) async {
    final host = url.host.toLowerCase();
    final segments = url.pathSegments;

    if (host.contains('themoviedb.org')) {
      // /movie/123 or /tv/456 (optionally trailing slug).
      if (segments.length >= 2 && (segments[0] == 'movie' || segments[0] == 'tv')) {
        final id = int.tryParse(segments[1].split('-').first);
        if (id != null) return _fetchDirect(mediaType: segments[0], tmdbId: id);
      }
    }

    if (host.contains('imdb.com')) {
      // /title/tt0133093/…
      final idx = segments.indexOf('title');
      if (idx != -1 && idx + 1 < segments.length) {
        final imdbId = segments[idx + 1];
        if (imdbId.startsWith('tt')) {
          return _resolveImdb(imdbId);
        }
      }
    }

    if (host.contains('letterboxd.com')) {
      // /film/slug/ — slug becomes our search query.
      final idx = segments.indexOf('film');
      if (idx != -1 && idx + 1 < segments.length) {
        final title = _deslug(segments[idx + 1]);
        return _searchFirst(title);
      }
    }

    if (host.contains('google.') && url.queryParameters['q'] != null) {
      return _searchFirst(url.queryParameters['q']!);
    }

    // Unknown host — try the URL's last path segment as a title hint.
    if (segments.isNotEmpty) {
      final guess = _deslug(segments.last);
      if (guess.length > 2) return _searchFirst(guess);
    }
    return null;
  }

  Future<ShareMatch?> _resolveImdb(String imdbId) async {
    final res = await tmdb.findByExternalId(imdbId, source: 'imdb_id');
    final movies = (res['movie_results'] as List?) ?? const [];
    final tv = (res['tv_results'] as List?) ?? const [];
    if (movies.isNotEmpty) return ShareMatch.fromTmdb(movies.first as Map<String, dynamic>, 'movie');
    if (tv.isNotEmpty) return ShareMatch.fromTmdb(tv.first as Map<String, dynamic>, 'tv');
    return null;
  }

  Future<ShareMatch?> _fetchDirect({required String mediaType, required int tmdbId}) async {
    final data = mediaType == 'tv' ? await tmdb.tvDetails(tmdbId) : await tmdb.movieDetails(tmdbId);
    return ShareMatch.fromTmdb(data, mediaType);
  }

  Future<ShareMatch?> _searchFirst(String query) async {
    final res = await tmdb.searchMulti(query);
    final results = (res['results'] as List?) ?? const [];
    for (final r in results) {
      final item = r as Map<String, dynamic>;
      final mt = item['media_type'];
      if (mt == 'movie' || mt == 'tv') return ShareMatch.fromTmdb(item, mt as String);
    }
    return null;
  }

  static final _urlRegex = RegExp(r'https?://[^\s]+', caseSensitive: false);
  Uri? _firstUrl(String text) {
    final m = _urlRegex.firstMatch(text);
    if (m == null) return null;
    return Uri.tryParse(m.group(0)!);
  }

  String _stripUrls(String text) => text.replaceAll(_urlRegex, '').trim();

  String _deslug(String slug) =>
      slug.replaceAll(RegExp(r'\.html?$'), '').replaceAll('-', ' ').replaceAll('_', ' ').trim();
}

class ShareMatch {
  ShareMatch({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.year,
    this.posterPath,
    this.overview,
  });

  final String mediaType;
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterPath;
  final String? overview;

  factory ShareMatch.fromTmdb(Map<String, dynamic> j, String mediaType) {
    final title = (j['title'] ?? j['name'] ?? '') as String;
    final dateStr = (j['release_date'] ?? j['first_air_date']) as String?;
    final year = (dateStr != null && dateStr.length >= 4) ? int.tryParse(dateStr.substring(0, 4)) : null;
    return ShareMatch(
      mediaType: mediaType,
      tmdbId: (j['id'] as num).toInt(),
      title: title,
      year: year,
      posterPath: j['poster_path'] as String?,
      overview: j['overview'] as String?,
    );
  }
}
