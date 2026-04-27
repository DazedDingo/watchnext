import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/models/external_ratings.dart';
import 'package:watchnext/services/external_ratings_service.dart';

void main() {
  group('ExternalRatingsService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('disk cache hit returns from memo without CF call', () async {
      // Pre-seed disk with one entry. Service should hydrate on first
      // fetch and skip the fetcher entirely.
      const imdbId = 'tt0111161';
      final cached = ExternalRatings(
        imdbId: imdbId,
        imdbRating: 9.3,
        imdbVotes: 2_900_000,
        rtRating: 91,
        metascore: 82,
        fetchedAtMs: 1700000000000,
      );
      SharedPreferences.setMockInitialValues({
        kExternalRatingsCacheKey: jsonEncode({imdbId: cached.toMap()}),
      });

      var calls = 0;
      final svc = ExternalRatingsService(
        fetcher: (id) async {
          calls++;
          return {'imdbId': id};
        },
      );

      final result = await svc.fetch(imdbId);
      expect(calls, 0,
          reason: 'pre-seeded disk cache should skip the CF call');
      expect(result?.imdbRating, 9.3);
      expect(result?.imdbVotes, 2_900_000);
    });

    test('CF success writes through to disk', () async {
      const imdbId = 'tt0133093';
      final svc = ExternalRatingsService(
        fetcher: (id) async => {
          'imdbId': id,
          'imdbRating': 8.7,
          'imdbVotes': 1_000_000,
          'fetchedAtMs': 1700000000000,
        },
      );

      final result = await svc.fetch(imdbId);
      expect(result?.imdbRating, 8.7);

      // Read back the persisted blob — entry should be there for the
      // next cold-start session.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kExternalRatingsCacheKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map;
      expect(decoded.containsKey(imdbId), isTrue);
      expect((decoded[imdbId] as Map)['imdbRating'], 8.7);
    });

    test('corrupted disk cache is silently dropped', () async {
      SharedPreferences.setMockInitialValues({
        kExternalRatingsCacheKey: '{not json',
      });

      const imdbId = 'tt0068646';
      var calls = 0;
      final svc = ExternalRatingsService(
        fetcher: (id) async {
          calls++;
          return {
            'imdbId': id,
            'imdbRating': 9.2,
            'fetchedAtMs': 1700000000000,
          };
        },
      );

      final result = await svc.fetch(imdbId);
      // Service didn't crash on the malformed blob; fell through to
      // the CF and returned the fresh value.
      expect(calls, 1);
      expect(result?.imdbRating, 9.2);
    });

    test('in-memory memo prevents repeat CF calls in the same session',
        () async {
      const imdbId = 'tt0050083';
      var calls = 0;
      final svc = ExternalRatingsService(
        fetcher: (id) async {
          calls++;
          return {
            'imdbId': id,
            'imdbRating': 8.9,
            'fetchedAtMs': 1700000000000,
          };
        },
      );

      await svc.fetch(imdbId);
      await svc.fetch(imdbId);
      await svc.fetch(imdbId);
      expect(calls, 1);
    });

    test('CF throw returns null without poisoning the memo', () async {
      const imdbId = 'tt9999999';
      var calls = 0;
      final svc = ExternalRatingsService(
        fetcher: (id) async {
          calls++;
          throw StateError('CF down');
        },
      );

      final result = await svc.fetch(imdbId);
      expect(result, isNull);
      // A subsequent fetch should retry — failure is not cached.
      await svc.fetch(imdbId);
      expect(calls, 2);
    });

    test('ExternalRatings round-trips through toMap/fromMap', () {
      final r = ExternalRatings(
        imdbId: 'tt0133093',
        imdbRating: 8.7,
        imdbVotes: 1_000_000,
        rtRating: 88,
        metascore: 73,
        fetchedAtMs: 1700000000000,
        notFound: false,
      );
      final restored = ExternalRatings.fromMap(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(r.toMap())) as Map),
      );
      expect(restored.imdbId, r.imdbId);
      expect(restored.imdbRating, r.imdbRating);
      expect(restored.imdbVotes, r.imdbVotes);
      expect(restored.rtRating, r.rtRating);
      expect(restored.metascore, r.metascore);
      expect(restored.fetchedAtMs, r.fetchedAtMs);
      expect(restored.notFound, r.notFound);
    });
  });
}
