import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/external_ratings.dart';

void main() {
  group('ExternalRatings.fromMap', () {
    test('parses a full payload', () {
      final r = ExternalRatings.fromMap({
        'imdbId': 'tt0133093',
        'imdbRating': 8.5,
        'imdbVotes': 1234567,
        'rtRating': 92,
        'metascore': 82,
        'fetchedAtMs': 1700000000000,
      });
      expect(r.imdbId, 'tt0133093');
      expect(r.imdbRating, 8.5);
      expect(r.imdbVotes, 1234567);
      expect(r.rtRating, 92.0);
      expect(r.metascore, 82.0);
      expect(r.fetchedAtMs, 1700000000000);
      expect(r.notFound, isFalse);
      expect(r.hasAnyRating, isTrue);
    });

    test('handles missing fields', () {
      final r = ExternalRatings.fromMap({
        'imdbId': 'tt9999999',
        'fetchedAtMs': 1,
      });
      expect(r.imdbRating, isNull);
      expect(r.imdbVotes, isNull);
      expect(r.rtRating, isNull);
      expect(r.metascore, isNull);
      expect(r.hasAnyRating, isFalse);
    });

    test('notFound flips hasAnyRating off even with stray values', () {
      final r = ExternalRatings.fromMap({
        'imdbId': 'tt0000001',
        'imdbRating': 1.0,
        'fetchedAtMs': 1,
        'notFound': true,
      });
      expect(r.notFound, isTrue);
      expect(r.hasAnyRating, isFalse);
    });

    test('coerces int fields from doubles and vice versa', () {
      final r = ExternalRatings.fromMap({
        'imdbId': 'tt1',
        'imdbRating': 7, // int
        'imdbVotes': 1000.0, // double
        'fetchedAtMs': 1,
      });
      expect(r.imdbRating, 7.0);
      expect(r.imdbVotes, 1000);
    });
  });
}
