import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/utils/keyword_genre_augment.dart';

void main() {
  group('augmentGenresWithKeywords', () {
    test('returns existing genres unchanged when no keyword matches', () {
      final out = augmentGenresWithKeywords(
        const ['Drama', 'Thriller'],
        const [999999], // unknown id
      );
      expect(out, ['Drama', 'Thriller']);
    });

    test('unions mapped extras into the genre list', () {
      // 9951 = alien (seeded → Science Fiction)
      final out = augmentGenresWithKeywords(
        const ['Horror'],
        const [9951],
      );
      expect(out, ['Horror', 'Science Fiction']);
    });

    test('dedupes when the keyword implies a genre already present', () {
      final out = augmentGenresWithKeywords(
        const ['Science Fiction', 'Drama'],
        const [9951], // alien → Science Fiction
      );
      expect(out, ['Science Fiction', 'Drama'],
          reason: 'Sci-Fi already present, no duplicate entry');
    });

    test('handles multiple keywords, unions all extras', () {
      final out = augmentGenresWithKeywords(
        const ['Thriller'],
        const [4458, 9951], // post-apocalyptic + alien → both Science Fiction
      );
      expect(out, ['Thriller', 'Science Fiction'],
          reason: 'distinct keyword ids collapsing to same genre is one entry');
    });

    test('preserves existing-genre order; extras land in iteration order', () {
      final out = augmentGenresWithKeywords(
        const ['Horror', 'Drama'],
        const [4565], // dystopia → Science Fiction
      );
      expect(out, ['Horror', 'Drama', 'Science Fiction']);
    });

    test('empty inputs return empty list', () {
      expect(
        augmentGenresWithKeywords(const [], const []),
        isEmpty,
      );
    });

    test('empty-string genres are dropped from the existing list', () {
      final out = augmentGenresWithKeywords(
        const ['Drama', ''],
        const [],
      );
      expect(out, ['Drama']);
    });

    test('mapping is never subtractive — canonical genres always survive', () {
      // Regression guard: augmenter widens only. A Comedy stays a Comedy
      // even if a keyword implies a totally different genre bucket.
      final out = augmentGenresWithKeywords(
        const ['Comedy'],
        const [9951], // alien → +Science Fiction, but Comedy stays
      );
      expect(out, contains('Comedy'));
      expect(out, contains('Science Fiction'));
    });

    test('unknown keyword ids mixed with known ones still work', () {
      final out = augmentGenresWithKeywords(
        const ['Drama'],
        const [999999, 9715], // unknown + superhero → Action
      );
      expect(out, ['Drama', 'Action']);
    });
  });
}
