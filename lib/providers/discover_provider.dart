import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tmdb_provider.dart';

final trendingMoviesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(tmdbServiceProvider).trendingMovies();
  return (res['results'] as List? ?? const []).cast<Map<String, dynamic>>();
});

final trendingTvProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(tmdbServiceProvider).trendingTv();
  return (res['results'] as List? ?? const []).cast<Map<String, dynamic>>();
});

final upcomingMoviesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(tmdbServiceProvider).upcomingMovies();
  return (res['results'] as List? ?? const []).cast<Map<String, dynamic>>();
});

final topRatedMoviesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(tmdbServiceProvider).topRatedMovies();
  return (res['results'] as List? ?? const []).cast<Map<String, dynamic>>();
});

final discoverByGenreProvider =
    FutureProvider.family<List<Map<String, dynamic>>, int>((ref, genreId) async {
  final res = await ref.watch(tmdbServiceProvider).discoverMovies({
    'with_genres': '$genreId',
    'sort_by': 'popularity.desc',
  });
  return (res['results'] as List? ?? const []).cast<Map<String, dynamic>>();
});
