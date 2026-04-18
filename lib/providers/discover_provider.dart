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

/// Current search query for the Discover screen. Empty string means
/// "not searching" — the screen falls back to its browse content.
final searchQueryProvider = StateProvider<String>((ref) => '');

/// TMDB multi search restricted to titles (movies + TV; people filtered out).
/// Empty query short-circuits to an empty list — no network call, no spinner.
final searchResultsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) return const [];
  final res = await ref.watch(tmdbServiceProvider).searchMulti(query);
  final results =
      (res['results'] as List? ?? const []).cast<Map<String, dynamic>>();
  return results.where((r) => r['media_type'] != 'person').toList();
});
