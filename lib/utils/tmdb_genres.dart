/// TMDB genre id → name lookup.
///
/// TMDB returns `genre_ids: [28, 12, ...]` on /trending and /search responses
/// (cheaper than the /movie/{id} detail fetch which returns `genres: [{...}]`).
/// We store genre *names* on Recommendation so the mood-pill filter can match
/// without a second round-trip per candidate.
///
/// Source: https://developers.themoviedb.org/3/genres/get-movie-list and
/// /genre/tv/list — these ids are stable; TMDB hasn't changed them in years.
/// Note the two domains share ids where the concept overlaps (e.g. 10751
/// Family, 16 Animation, 99 Documentary) but each also has domain-only ids
/// (e.g. 37 Western is movie-only; 10768 War & Politics is tv-only).
const Map<int, String> tmdbMovieGenres = {
  28: 'Action',
  12: 'Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  14: 'Fantasy',
  36: 'History',
  27: 'Horror',
  10402: 'Music',
  9648: 'Mystery',
  10749: 'Romance',
  878: 'Science Fiction',
  10770: 'TV Movie',
  53: 'Thriller',
  10752: 'War',
  37: 'Western',
};

const Map<int, String> tmdbTvGenres = {
  10759: 'Action & Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  10762: 'Kids',
  9648: 'Mystery',
  10763: 'News',
  10764: 'Reality',
  10765: 'Sci-Fi & Fantasy',
  10766: 'Soap',
  10767: 'Talk',
  10768: 'War & Politics',
  37: 'Western',
};

/// Resolves an iterable of genre ids to human-readable names for a given
/// media type. Unknown ids are silently skipped (defensive against TMDB
/// adding new ids we haven't seen yet).
List<String> genreNamesFromIds(Iterable<int> ids, {required String mediaType}) {
  final lookup = mediaType == 'tv' ? tmdbTvGenres : tmdbMovieGenres;
  final out = <String>[];
  for (final id in ids) {
    final name = lookup[id];
    if (name != null) out.add(name);
  }
  return out;
}

/// Resolves genre *names* to TMDB ids for a given media type. Used by
/// `/discover` calls which want ids, not names. Unknown names are skipped
/// — e.g. a movie-only genre name will not resolve under mediaType='tv'.
List<int> genreIdsFromNames(Iterable<String> names, {required String mediaType}) {
  final lookup = mediaType == 'tv' ? tmdbTvGenres : tmdbMovieGenres;
  final inverted = <String, int>{for (final e in lookup.entries) e.value: e.key};
  final out = <int>[];
  for (final n in names) {
    final id = inverted[n];
    if (id != null) out.add(id);
  }
  return out;
}

/// Coerces whatever shape a caller has (`List<int>`, `List<num>`,
/// `List<dynamic>`) into genre names. Returns an empty list if the input is
/// null or has no resolvable ids. Accepts either int ids or already-resolved
/// string names (pass-through) so we can feed it candidate data that may
/// already carry names from a detail fetch.
List<String> coerceGenres(dynamic raw, {required String mediaType}) {
  if (raw == null) return const [];
  if (raw is! List) return const [];

  final ids = <int>[];
  final names = <String>[];
  for (final item in raw) {
    if (item is int) {
      ids.add(item);
    } else if (item is num) {
      ids.add(item.toInt());
    } else if (item is String && item.isNotEmpty) {
      names.add(item);
    } else if (item is Map && item['name'] is String) {
      // TMDB detail shape: { "id": 28, "name": "Action" }
      names.add(item['name'] as String);
    }
  }

  if (ids.isNotEmpty) {
    names.addAll(genreNamesFromIds(ids, mediaType: mediaType));
  }
  // Dedup while preserving order.
  final seen = <String>{};
  return names.where(seen.add).toList();
}
