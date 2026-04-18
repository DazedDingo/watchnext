import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/mode_provider.dart';
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

  group('ModeMoodController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('starts empty and returns null for both modes', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMoodController(
        prefs,
        ModeMoodController.readAll(prefs),
      );
      expect(c.state[ViewMode.solo], isNull);
      expect(c.state[ViewMode.together], isNull);
    });

    test('setting solo does not affect together and vice versa', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMoodController(
        prefs,
        ModeMoodController.readAll(prefs),
      );
      await c.set(ViewMode.solo, WatchMood.intense);
      expect(c.state[ViewMode.solo], WatchMood.intense);
      expect(c.state[ViewMode.together], isNull);

      await c.set(ViewMode.together, WatchMood.chill);
      expect(c.state[ViewMode.solo], WatchMood.intense);
      expect(c.state[ViewMode.together], WatchMood.chill);
    });

    test('persists to SharedPreferences under two keys', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMoodController(
        prefs,
        ModeMoodController.readAll(prefs),
      );
      await c.set(ViewMode.solo, WatchMood.intense);
      await c.set(ViewMode.together, WatchMood.chill);

      expect(prefs.getString('wn_mood_solo'), 'intense');
      expect(prefs.getString('wn_mood_together'), 'chill');
    });

    test('set(null) removes the key', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_mood_solo': 'intense',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMoodController(
        prefs,
        ModeMoodController.readAll(prefs),
      );
      expect(c.state[ViewMode.solo], WatchMood.intense);

      await c.set(ViewMode.solo, null);
      expect(c.state[ViewMode.solo], isNull);
      expect(prefs.containsKey('wn_mood_solo'), isFalse);
    });

    test('readAllForTest recovers enum values from string', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_mood_solo': 'documentary',
        'wn_mood_together': 'dateNight',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeMoodController.readAll(prefs);
      expect(map[ViewMode.solo], WatchMood.documentary);
      expect(map[ViewMode.together], WatchMood.dateNight);
    });

    test('unknown stored value decodes to null (forward-compat)', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_mood_solo': 'totally-not-a-mood',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeMoodController.readAll(prefs);
      expect(map[ViewMode.solo], isNull);
    });
  });

}
