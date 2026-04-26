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

/// TMDB `/tv/{id}/season/{s}/episode/{e}/external_ids` payload, keyed by
/// (showTmdbId, season, episode). Lazy per-row fetch on the title-detail
/// episodes section — without this, IMDb deep-links would have to fall
/// back to the show's season page. autoDispose so navigating away from
/// the detail screen releases the cache.
final episodeExternalIdsProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, (int, int, int)>((ref, key) {
  final (tmdbId, season, episode) = key;
  return ref
      .read(tmdbServiceProvider)
      .tvEpisodeExternalIds(tmdbId, season, episode);
});
