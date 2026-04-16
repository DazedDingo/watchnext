import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/utils/tmdb_genres.dart';

void main() {
  group('genreNamesFromIds', () {
    test('maps well-known movie ids', () {
      expect(
        genreNamesFromIds(const [28, 18, 99], mediaType: 'movie'),
        ['Action', 'Drama', 'Documentary'],
      );
    });

    test('maps well-known tv ids (Action & Adventure is tv-only)', () {
      expect(
        genreNamesFromIds(const [10759, 99], mediaType: 'tv'),
        ['Action & Adventure', 'Documentary'],
      );
    });

    test('drops unknown ids silently (future-proof)', () {
      expect(
        genreNamesFromIds(const [28, 999999, 18], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('empty input yields empty list', () {
      expect(genreNamesFromIds(const [], mediaType: 'movie'), isEmpty);
    });

    test('tv lookup does NOT resolve movie-only id 28 (Action)', () {
      // Id 28 is "Action" in the movie domain but undefined for TV —
      // TV's action equivalent is 10759. Guards against a future edit
      // accidentally merging the two tables.
      expect(genreNamesFromIds(const [28], mediaType: 'tv'), isEmpty);
    });

    test('movie lookup does NOT resolve tv-only id 10759', () {
      expect(genreNamesFromIds(const [10759], mediaType: 'movie'), isEmpty);
    });

    test('documentary id 99 resolves in both domains', () {
      expect(genreNamesFromIds(const [99], mediaType: 'movie'), ['Documentary']);
      expect(genreNamesFromIds(const [99], mediaType: 'tv'), ['Documentary']);
    });

    test('bogus mediaType falls back to movie table (tv is the only special case)', () {
      // Anything !='tv' uses movies — defensive against arbitrary input
      // strings without crashing.
      expect(
        genreNamesFromIds(const [28], mediaType: 'unknown'),
        ['Action'],
      );
    });
  });

  group('coerceGenres', () {
    test('accepts List<int> of ids', () {
      expect(
        coerceGenres(const [28, 18], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('accepts List<num> (JSON numbers decode as num)', () {
      expect(
        coerceGenres(<num>[28, 18.0], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('accepts List<String> of already-resolved names (pass-through)', () {
      expect(
        coerceGenres(const ['Action', 'Drama'], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('accepts TMDB detail shape [{id, name}, ...]', () {
      expect(
        coerceGenres(const [
          {'id': 28, 'name': 'Action'},
          {'id': 18, 'name': 'Drama'},
        ], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('null returns empty list', () {
      expect(coerceGenres(null, mediaType: 'movie'), isEmpty);
    });

    test('non-list input returns empty list (defensive)', () {
      expect(coerceGenres('Action', mediaType: 'movie'), isEmpty);
      expect(coerceGenres(42, mediaType: 'movie'), isEmpty);
      expect(coerceGenres(const {'a': 'b'}, mediaType: 'movie'), isEmpty);
    });

    test('mixed ids + names dedup correctly', () {
      expect(
        coerceGenres(const [28, 'Action', 18], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('preserves insertion order', () {
      expect(
        coerceGenres(const [18, 28, 99], mediaType: 'movie'),
        ['Drama', 'Action', 'Documentary'],
      );
    });

    test('empty list returns empty list', () {
      expect(coerceGenres(const [], mediaType: 'movie'), isEmpty);
    });

    test('skips empty strings', () {
      expect(coerceGenres(const ['', 'Action', ''], mediaType: 'movie'), ['Action']);
    });

    test('skips malformed detail entries (missing name)', () {
      expect(
        coerceGenres(const [
          {'id': 28},
          {'name': 'Drama'},
          {'id': 18, 'name': 'Thriller'},
        ], mediaType: 'movie'),
        ['Drama', 'Thriller'],
      );
    });

    test('decimal num ids are truncated to int', () {
      // Firestore returns all numbers as num in Dart, and JSON number
      // literals can decode as double. We only care that toInt() reaches
      // the lookup table correctly.
      expect(
        coerceGenres(<num>[28.0, 18.9], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('unknown numeric id does not poison the result', () {
      expect(
        coerceGenres(const [28, 42, 18], mediaType: 'movie'),
        ['Action', 'Drama'],
      );
    });

    test('duplicate names dedup across id+name mix preserving first seen', () {
      expect(
        coerceGenres(const ['Drama', 28, 'Drama', 18], mediaType: 'movie'),
        ['Drama', 'Action'],
      );
    });
  });
}
