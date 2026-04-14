import 'dart:convert';
import 'package:http/http.dart' as http;

/// TMDB REST client. API key read from --dart-define=TMDB_API_KEY at build time.
/// Run with:  flutter run --dart-define=TMDB_API_KEY=xxx
class TmdbService {
  static const String _base = 'https://api.themoviedb.org/3';
  static const String _imageBase = 'https://image.tmdb.org/t/p';
  static const String _apiKey = String.fromEnvironment('TMDB_API_KEY');

  final http.Client _client;
  TmdbService({http.Client? client}) : _client = client ?? http.Client();

  Uri _uri(String path, [Map<String, String>? params]) => Uri.parse('$_base$path').replace(
        queryParameters: {
          'api_key': _apiKey,
          'language': 'en-US',
          ...?params,
        },
      );

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final res = await _client.get(uri);
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

  /// Builds poster/backdrop URLs. `size` examples: 'w185', 'w342', 'w500', 'original'.
  static String? imageUrl(String? path, {String size = 'w500'}) =>
      path == null || path.isEmpty ? null : '$_imageBase/$size$path';

  void dispose() => _client.close();
}
