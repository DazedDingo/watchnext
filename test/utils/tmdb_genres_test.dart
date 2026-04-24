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

  group('genreIdsFromNames — cross-taxonomy synonym expansion', () {
    test('movie pick of TV-only "Kids" resolves to 10751/Family', () {
      // Kids (10762) is TV-only; Family (10751) is its movie equivalent.
      // Without synonym expansion this would return []; the client filter
      // then demands rec.genres.contains("Kids") which no movie satisfies.
      expect(
        genreIdsFromNames(const ['Kids'], mediaType: 'movie'),
        [10751],
      );
    });

    test('tv pick of movie-only "Science Fiction" resolves to 10765', () {
      expect(
        genreIdsFromNames(const ['Science Fiction'], mediaType: 'tv'),
        [10765],
      );
    });

    test('Sci-Fi + War picks return both movie ids (multi-genre AND pool)', () {
      // The user-reported failure mode: picking ["Science Fiction", "War"]
      // with the TV variant of one of them dropped one id on each media
      // type's side, so multiGenre was false and the AND rung never fired.
      expect(
        genreIdsFromNames(const ['Science Fiction', 'War'], mediaType: 'movie')
          ..sort(),
        [878, 10752],
      );
      // On TV: both are movie-only names, so both expand to their TV
      // synonyms.
      expect(
        genreIdsFromNames(const ['Science Fiction', 'War'], mediaType: 'tv')
          ..sort(),
        [10765, 10768],
      );
    });

    test('Sci-Fi + Kids (cross-taxonomy pick) fills both pools', () {
      // Family (10751) is in BOTH the movie and TV maps — so a "Kids" pick
      // expands to Family on both sides, giving TV a three-id pool
      // (Family + Kids + Sci-Fi & Fantasy). The AND rung will return 0 on
      // that narrow intersection but the OR fallback rung will populate a
      // legitimate sci-fi + family/kids TV pool.
      expect(
        genreIdsFromNames(const ['Science Fiction', 'Kids'], mediaType: 'movie')
          ..sort(),
        [878, 10751],
      );
      expect(
        genreIdsFromNames(const ['Science Fiction', 'Kids'], mediaType: 'tv')
          ..sort(),
        [10751, 10762, 10765],
      );
    });

    test('dedupes when canonical + synonym land on the same id', () {
      // Family (10751) is a shared id in both maps; Kids expands to Family
      // via synonym. Picking both names on the movie side collapses to the
      // single id 10751 (the Set dedupe in genreIdsFromNames kicks in).
      expect(
        genreIdsFromNames(const ['Family', 'Kids'], mediaType: 'movie'),
        [10751],
      );
    });
  });

  group('genreMatches — client-side intersection', () {
    test('direct name match passes', () {
      expect(genreMatches(const ['Drama', 'War'], 'War'), isTrue);
    });

    test('synonym match passes (War ≡ War & Politics)', () {
      expect(
        genreMatches(const ['Drama', 'War & Politics'], 'War'),
        isTrue,
      );
    });

    test('Kids pick matches a Family-tagged movie', () {
      expect(
        genreMatches(const ['Animation', 'Family'], 'Kids'),
        isTrue,
      );
    });

    test('Science Fiction pick matches a Sci-Fi & Fantasy-tagged TV show', () {
      expect(
        genreMatches(const ['Sci-Fi & Fantasy', 'Drama'], 'Science Fiction'),
        isTrue,
      );
    });

    test('no match when neither canonical nor synonym is present', () {
      expect(
        genreMatches(const ['Comedy', 'Romance'], 'Horror'),
        isFalse,
      );
    });

    test('unmapped pick falls back to strict contains', () {
      // "Horror" has no synonym entry — equivalent to the pre-fix behavior.
      expect(genreMatches(const ['Horror'], 'Horror'), isTrue);
      expect(genreMatches(const ['Comedy'], 'Horror'), isFalse);
    });

    test('Sci-Fi + War AND intersection passes on a TV rec tagged both', () {
      // The cross-taxonomy regression case: user picks ["Science Fiction",
      // "War"] (movie labels from a picker that unions both taxonomies);
      // a rec doc tagged ["Sci-Fi & Fantasy", "War & Politics"] (TV taxonomy)
      // must satisfy the AND intersection via synonyms on both names.
      const rec = ['Sci-Fi & Fantasy', 'War & Politics', 'Drama'];
      const picks = ['Science Fiction', 'War'];
      expect(picks.every((g) => genreMatches(rec, g)), isTrue);
    });

    test('Sci-Fi + Kids AND intersection passes on a Family-tagged sci-fi movie', () {
      const rec = ['Adventure', 'Science Fiction', 'Family'];
      const picks = ['Science Fiction', 'Kids'];
      expect(picks.every((g) => genreMatches(rec, g)), isTrue);
    });
  });
}
