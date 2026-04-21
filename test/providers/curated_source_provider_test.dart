import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/curated_source_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';

/// Per-mode persistence for the curator-list source selector (e.g. Criterion).
/// When a source is active, recommendations_service suppresses trending/top_rated
/// baseline — so this toggle has real teeth and a wrong persisted value would
/// show stale baseline rows.
void main() {
  group('CuratedSource.withCompanies', () {
    test('none returns null (no company filter)', () {
      expect(CuratedSource.none.withCompanies, isNull);
    });

    test('criterion maps to TMDB company id 1771', () {
      expect(CuratedSource.criterion.withCompanies, '1771');
    });
  });

  group('ModeCuratedSourceController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('defaults to none in both modes when prefs empty', () async {
      final prefs = await SharedPreferences.getInstance();
      final map = ModeCuratedSourceController.readAll(prefs);
      expect(map[ViewMode.solo], CuratedSource.none);
      expect(map[ViewMode.together], CuratedSource.none);
    });

    test('setting solo does not flip together (modes are independent)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeCuratedSourceController(
          prefs, ModeCuratedSourceController.readAll(prefs));
      await c.set(ViewMode.solo, CuratedSource.criterion);
      expect(c.state[ViewMode.solo], CuratedSource.criterion);
      expect(c.state[ViewMode.together], CuratedSource.none);
    });

    test('persists non-default under wn_curated_source_{solo,together}',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeCuratedSourceController(
          prefs, ModeCuratedSourceController.readAll(prefs));
      await c.set(ViewMode.solo, CuratedSource.criterion);
      expect(prefs.getString('wn_curated_source_solo'), 'criterion');
    });

    test('set(none) removes the key — keeps prefs tidy', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_curated_source_solo': 'criterion',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeCuratedSourceController(
          prefs, ModeCuratedSourceController.readAll(prefs));
      expect(c.state[ViewMode.solo], CuratedSource.criterion);

      await c.set(ViewMode.solo, CuratedSource.none);
      expect(c.state[ViewMode.solo], CuratedSource.none);
      expect(prefs.containsKey('wn_curated_source_solo'), isFalse);
    });

    test('rehydrates stored value across cold start', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_curated_source_together': 'criterion',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeCuratedSourceController.readAll(prefs);
      expect(map[ViewMode.together], CuratedSource.criterion);
      expect(map[ViewMode.solo], CuratedSource.none);
    });

    test('unknown stored value falls back to none (graceful rename)',
        () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_curated_source_solo': 'sight-and-sound',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeCuratedSourceController.readAll(prefs);
      expect(map[ViewMode.solo], CuratedSource.none);
    });
  });
}
