import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/tmdb_service.dart';

final tmdbServiceProvider = Provider<TmdbService>((ref) {
  final service = TmdbService();
  ref.onDispose(service.dispose);
  return service;
});

/// TMDB `/tv/{id}/season/{n}` payload, keyed by (showTmdbId, seasonNumber).
/// autoDispose so seasons we navigate away from don't pin in memory.
final tvSeasonProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, (int, int)>((ref, key) {
  final (tmdbId, seasonNumber) = key;
  return ref.read(tmdbServiceProvider).tvSeason(tmdbId, seasonNumber);
});
