import 'dart:convert';
import 'dart:developer' as developer;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/external_ratings.dart';

/// SharedPreferences key holding the JSON-encoded memo. One blob keyed
/// by imdb id so a single read on first fetch hydrates the entire cache
/// instead of fanning per-id reads across the platform channel.
const String kExternalRatingsCacheKey = 'wn_external_ratings_cache';

/// Signature for the CF callable layer. Defaults to a real Firebase
/// Functions invocation; tests inject a stub so we don't need to mock
/// the platform plugin.
typedef ExternalRatingsFetcher = Future<Map<String, dynamic>> Function(
    String imdbId);

/// Thin wrapper around the `fetchExternalRatings` Cloud Function.
///
/// The CF handles OMDb calls + a 7-day Firestore cache; this class just
/// invokes it and normalizes the response. A two-tier cache keeps the
/// chip rows fast: an in-memory memo for the current session, and a
/// disk-backed copy (SharedPreferences) so cold-starts after install or
/// relaunch render previously-fetched chips immediately instead of
/// waiting on the CF round-trip.
class ExternalRatingsService {
  ExternalRatingsService({
    FirebaseFunctions? fns,
    @visibleForTesting ExternalRatingsFetcher? fetcher,
  })  : _fnsField = fns,
        _fetcherOverride = fetcher;

  FirebaseFunctions? _fnsField;
  FirebaseFunctions get _fns =>
      _fnsField ??= FirebaseFunctions.instanceFor(region: 'europe-west2');

  final ExternalRatingsFetcher? _fetcherOverride;

  Future<Map<String, dynamic>> _callCf(String imdbId) async {
    if (_fetcherOverride != null) return _fetcherOverride(imdbId);
    final res = await _fns
        .httpsCallable('fetchExternalRatings')
        .call({'imdbId': imdbId});
    return Map<String, dynamic>.from(res.data as Map);
  }

  final Map<String, ExternalRatings> _memo = {};

  // Hydrated lazily on the first `fetch` call so construction stays
  // synchronous (no boot-time await needed).
  bool _hydrated = false;

  Future<void> _hydrateFromDisk() async {
    if (_hydrated) return;
    _hydrated = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kExternalRatingsCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        if (k is String && v is Map) {
          try {
            _memo[k] = ExternalRatings.fromMap(Map<String, dynamic>.from(v));
          } catch (_) {
            // Skip individual malformed entries rather than dropping
            // the whole cache.
          }
        }
      });
    } catch (e) {
      developer.log(
        'External ratings cache corrupt, dropping: $e',
        name: 'external_ratings',
      );
    }
  }

  Future<void> _persistToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        _memo.map((k, v) => MapEntry(k, v.toMap())),
      );
      await prefs.setString(kExternalRatingsCacheKey, encoded);
    } catch (_) {
      // Persistence is best-effort — a failed write just means the
      // next session re-fetches from the CF.
    }
  }

  /// Fetches ratings for [imdbId] (e.g. `tt0133093`). Returns `null` if the
  /// call fails — callers should render a silent fallback rather than an
  /// error, since ratings are a nice-to-have.
  Future<ExternalRatings?> fetch(String imdbId) async {
    await _hydrateFromDisk();
    if (_memo.containsKey(imdbId)) return _memo[imdbId];
    try {
      final data = await _callCf(imdbId);
      final parsed = ExternalRatings.fromMap(data);
      _memo[imdbId] = parsed;
      // Write through after each successful CF call so the next cold
      // start has the entry on disk.
      await _persistToDisk();
      return parsed;
    } catch (_) {
      return null;
    }
  }
}
