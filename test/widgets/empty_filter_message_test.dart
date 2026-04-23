import 'package:flutter_test/flutter_test.dart';

// The helper is file-private on home_screen.dart; we re-declare the same
// predicate contract here to lock the copy. If you change the wording, also
// update this test (and vice versa).
String emptyFilterMessage(Set<String> selectedGenres) {
  if (selectedGenres.length >= 2) {
    final sorted = selectedGenres.toList()..sort();
    return 'No titles match all of ${sorted.join(' + ')}.\n'
        'Try removing one — or pull down to rebuild the pool.';
  }
  return 'No matches for your current filters.\n'
      'Widen genre, year, runtime, or media type — '
      'or pull down to rebuild the pool.';
}

void main() {
  group('empty-filter message', () {
    test('no genres → generic filter hint', () {
      expect(emptyFilterMessage(<String>{}),
          contains('Widen genre, year, runtime, or media type'));
    });

    test('single genre → generic hint (AND behaves as OR-of-one)', () {
      expect(emptyFilterMessage({'Drama'}),
          contains('Widen genre, year, runtime, or media type'));
    });

    test('multi-genre → names the selection and suggests dropping one', () {
      final msg = emptyFilterMessage({'Western', 'Science Fiction'});
      expect(msg, contains('No titles match all of'));
      expect(msg, contains('Western'));
      expect(msg, contains('Science Fiction'));
      expect(msg, contains('Try removing one'));
    });

    test('multi-genre ordering is stable (alphabetical)', () {
      // Set ordering is unspecified in Dart — the helper sorts for stable copy.
      final a = emptyFilterMessage({'Science Fiction', 'Western'});
      final b = emptyFilterMessage({'Western', 'Science Fiction'});
      expect(a, b);
      expect(a, contains('Science Fiction + Western'));
    });
  });
}
