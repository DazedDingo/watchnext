import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/external_ratings.dart';
import '../services/external_ratings_service.dart';

final externalRatingsServiceProvider =
    Provider<ExternalRatingsService>((ref) => ExternalRatingsService());

/// Fetches IMDb / RT / Metascore ratings for an imdb id. Returns `null` when
/// the CF fails or no imdb id is available. Autodispose so a scrolled-past
/// title's future gets cleaned up.
final externalRatingsProvider =
    FutureProvider.autoDispose.family<ExternalRatings?, String>(
  (ref, imdbId) async {
    if (imdbId.isEmpty) return null;
    final svc = ref.watch(externalRatingsServiceProvider);
    return svc.fetch(imdbId);
  },
);
