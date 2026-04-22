import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/review.dart';
import 'tmdb_provider.dart';

/// Identifier for a title so we can key the reviews provider on it.
class TitleRef {
  final String mediaType; // 'movie' | 'tv'
  final int tmdbId;

  const TitleRef(this.mediaType, this.tmdbId);

  @override
  bool operator ==(Object other) =>
      other is TitleRef &&
      other.mediaType == mediaType &&
      other.tmdbId == tmdbId;

  @override
  int get hashCode => Object.hash(mediaType, tmdbId);
}

/// TMDB user reviews for a title, sorted by (content length desc) so the
/// most substantive reviews surface first — TMDB returns them unordered and
/// many entries are one-liners.
final reviewsProvider =
    FutureProvider.autoDispose.family<List<Review>, TitleRef>(
  (ref, title) async {
    final tmdb = ref.watch(tmdbServiceProvider);
    try {
      final payload = await tmdb.reviews(title.mediaType, title.tmdbId);
      final rows = (payload['results'] as List?) ?? const [];
      final reviews = rows
          .whereType<Map>()
          .map((m) => Review.fromMap(Map<String, dynamic>.from(m)))
          .where((r) => r.content.isNotEmpty)
          .toList();
      reviews.sort((a, b) => b.content.length.compareTo(a.content.length));
      return reviews;
    } catch (_) {
      return const <Review>[];
    }
  },
);
