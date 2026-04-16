import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/providers/mood_provider.dart';

void main() {
  group('WatchMood', () {
    test('all enum values have a non-empty label', () {
      for (final m in WatchMood.values) {
        expect(m.label, isNotEmpty, reason: 'label missing for $m');
      }
    });

    test('Documentary mood exists and labels correctly', () {
      expect(WatchMood.values.contains(WatchMood.documentary), isTrue);
      expect(WatchMood.documentary.label, 'Documentary');
    });

    test('Documentary mood maps to the Documentary TMDB genre', () {
      expect(WatchMood.documentary.genres, ['Documentary']);
    });

    test('every non-custom mood maps to at least one genre', () {
      for (final m in WatchMood.values) {
        if (m == WatchMood.custom) continue;
        expect(m.genres, isNotEmpty,
            reason: '$m would never match any recommendation and produce '
                'a guaranteed-empty mood filter.');
      }
    });

    test('custom intentionally has no genre mapping (passes everything)', () {
      expect(WatchMood.custom.genres, isEmpty);
    });

    test('mood labels are unique (no duplicate pills on the home screen)', () {
      final labels = WatchMood.values.map((m) => m.label).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('mood genre strings match TMDB casing exactly', () {
      // The filter does a client-side .contains against Recommendation.genres
      // which come straight from TMDB. Typos here would silently break the
      // filter without crashing.
      final valid = {
        'Action', 'Adventure', 'Animation', 'Comedy', 'Crime',
        'Documentary', 'Drama', 'Family', 'Fantasy', 'History',
        'Horror', 'Music', 'Mystery', 'Romance', 'Science Fiction',
        'Thriller', 'War', 'Western',
        // TV-domain names that trending TV might surface.
        'Action & Adventure', 'Kids', 'News', 'Reality',
        'Sci-Fi & Fantasy', 'Soap', 'Talk', 'War & Politics',
      };
      for (final m in WatchMood.values) {
        for (final g in m.genres) {
          expect(valid.contains(g), isTrue,
              reason: 'mood $m references unknown TMDB genre "$g"');
        }
      }
    });
  });
}
