/// External ratings for a title (IMDb / Rotten Tomatoes / Metascore).
///
/// Populated by the `fetchExternalRatings` Cloud Function which proxies
/// OMDb and caches results at `/externalRatings/{imdbId}` for 7 days.
class ExternalRatings {
  final String imdbId;
  final double? imdbRating;
  final int? imdbVotes;
  final double? rtRating;
  final double? metascore;
  final int fetchedAtMs;

  /// True when OMDb returned no data for this id (e.g. very obscure titles).
  /// We still cache the negative result to avoid re-querying on every open.
  final bool notFound;

  const ExternalRatings({
    required this.imdbId,
    this.imdbRating,
    this.imdbVotes,
    this.rtRating,
    this.metascore,
    required this.fetchedAtMs,
    this.notFound = false,
  });

  bool get hasAnyRating =>
      !notFound &&
      (imdbRating != null || rtRating != null || metascore != null);

  factory ExternalRatings.fromMap(Map<String, dynamic> m) {
    double? d(dynamic v) => v is num ? v.toDouble() : null;
    int? i(dynamic v) => v is num ? v.toInt() : null;
    return ExternalRatings(
      imdbId: (m['imdbId'] as String?) ?? '',
      imdbRating: d(m['imdbRating']),
      imdbVotes: i(m['imdbVotes']),
      rtRating: d(m['rtRating']),
      metascore: d(m['metascore']),
      fetchedAtMs: i(m['fetchedAtMs']) ?? 0,
      notFound: m['notFound'] == true,
    );
  }
}
