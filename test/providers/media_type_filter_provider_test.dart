import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/media_type_filter_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';

void main() {
  group('MediaTypeFilter', () {
    test('recMediaType matches the string we write into /recommendations', () {
      // These strings are the contract with `Recommendation.mediaType` and
      // with CF scoring. Don't rename without migrating rec docs.
      expect(MediaTypeFilter.movie.recMediaType, 'movie');
      expect(MediaTypeFilter.tv.recMediaType, 'tv');
    });

    test('labels are non-empty and distinct', () {
      final labels =
          MediaTypeFilter.values.map((v) => v.label).toList();
      for (final l in labels) {
        expect(l, isNotEmpty);
      }
      expect(labels.toSet().length, labels.length);
    });
  });

  group('ModeMediaTypeController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('setting solo does not affect together', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMediaTypeController(
          prefs, ModeMediaTypeController.readAll(prefs));
      await c.set(ViewMode.solo, MediaTypeFilter.movie);
      expect(c.state[ViewMode.solo], MediaTypeFilter.movie);
      expect(c.state[ViewMode.together], isNull);

      await c.set(ViewMode.together, MediaTypeFilter.tv);
      expect(c.state[ViewMode.solo], MediaTypeFilter.movie);
      expect(c.state[ViewMode.together], MediaTypeFilter.tv);
    });

    test('persists under two keys', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMediaTypeController(
          prefs, ModeMediaTypeController.readAll(prefs));
      await c.set(ViewMode.solo, MediaTypeFilter.movie);
      await c.set(ViewMode.together, MediaTypeFilter.tv);

      expect(prefs.getString('wn_media_type_solo'), 'movie');
      expect(prefs.getString('wn_media_type_together'), 'tv');
    });

    test('set(null) removes the key', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_media_type_solo': 'movie',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeMediaTypeController(
          prefs, ModeMediaTypeController.readAll(prefs));
      expect(c.state[ViewMode.solo], MediaTypeFilter.movie);

      await c.set(ViewMode.solo, null);
      expect(c.state[ViewMode.solo], isNull);
      expect(prefs.containsKey('wn_media_type_solo'), isFalse);
    });

    test('unknown stored value decodes to null (forward-compat)', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_media_type_solo': 'anime',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeMediaTypeController.readAll(prefs);
      expect(map[ViewMode.solo], isNull);
    });
  });
}
