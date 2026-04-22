import 'package:cloud_functions/cloud_functions.dart';

import '../models/external_ratings.dart';

/// Thin wrapper around the `fetchExternalRatings` Cloud Function.
///
/// The CF handles OMDb calls + a 7-day Firestore cache; this class just
/// invokes it and normalizes the response. An in-memory cache prevents a
/// scroll-heavy screen from re-calling the CF for the same imdb id within
/// a single app session (the CF would hit its own cache, but that's still
/// a round-trip we don't need).
class ExternalRatingsService {
  ExternalRatingsService({FirebaseFunctions? fns}) : _fnsField = fns;

  FirebaseFunctions? _fnsField;
  FirebaseFunctions get _fns =>
      _fnsField ??= FirebaseFunctions.instanceFor(region: 'europe-west2');

  final Map<String, ExternalRatings> _memo = {};

  /// Fetches ratings for [imdbId] (e.g. `tt0133093`). Returns `null` if the
  /// call fails — callers should render a silent fallback rather than an
  /// error, since ratings are a nice-to-have.
  Future<ExternalRatings?> fetch(String imdbId) async {
    if (_memo.containsKey(imdbId)) return _memo[imdbId];
    try {
      final res = await _fns
          .httpsCallable('fetchExternalRatings')
          .call({'imdbId': imdbId});
      final data = Map<String, dynamic>.from(res.data as Map);
      final parsed = ExternalRatings.fromMap(data);
      _memo[imdbId] = parsed;
      return parsed;
    } catch (_) {
      return null;
    }
  }
}
