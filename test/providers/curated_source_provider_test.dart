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

    test('a24 maps to TMDB company id 41077 (verified against /discover)',
        () {
      expect(CuratedSource.a24.withCompanies, '41077');
    });

    test('neon maps to TMDB company id 90733 (verified against /discover)',
        () {
      expect(CuratedSource.neon.withCompanies, '90733');
    });

    test('ghibli maps to TMDB company id 10342', () {
      expect(CuratedSource.ghibli.withCompanies, '10342');
    });

    test(
        'searchlight unions pre-Disney (43) + current brand (127929) via '
        'pipe-OR', () {
      expect(CuratedSource.searchlight.withCompanies, '43|127929');
    });

    test('every case except none emits a non-empty company id', () {
      for (final c in CuratedSource.values) {
        if (c == CuratedSource.none) continue;
        expect(c.withCompanies, isNotNull,
            reason: '${c.name} should have a company id');
        expect(c.withCompanies, isNotEmpty,
            reason: '${c.name} should not emit empty string');
      }
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
      await c.set(ViewMode.solo, CuratedSource.a24);
      expect(c.state[ViewMode.solo], CuratedSource.a24);
      expect(c.state[ViewMode.together], CuratedSource.none);
    });

    test('persists non-default under wn_curated_source_{solo,together}',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeCuratedSourceController(
          prefs, ModeCuratedSourceController.readAll(prefs));
      await c.set(ViewMode.solo, CuratedSource.a24);
      expect(prefs.getString('wn_curated_source_solo'), 'a24');
    });

    test('set(none) removes the key — keeps prefs tidy', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_curated_source_solo': 'a24',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeCuratedSourceController(
          prefs, ModeCuratedSourceController.readAll(prefs));
      expect(c.state[ViewMode.solo], CuratedSource.a24);

      await c.set(ViewMode.solo, CuratedSource.none);
      expect(c.state[ViewMode.solo], CuratedSource.none);
      expect(prefs.containsKey('wn_curated_source_solo'), isFalse);
    });

    test('rehydrates stored value across cold start', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_curated_source_together': 'a24',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeCuratedSourceController.readAll(prefs);
      expect(map[ViewMode.together], CuratedSource.a24);
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
