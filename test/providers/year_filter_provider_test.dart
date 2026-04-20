import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/year_filter_provider.dart';

void main() {
  group('YearRange.matches', () {
    test('unbounded matches every year — including null (no filter active)', () {
      const r = YearRange.unbounded();
      expect(r.hasAnyBound, isFalse);
      expect(r.matches(null), isTrue);
      expect(r.matches(1927), isTrue);
      expect(r.matches(2026), isTrue);
    });

    test('min-only bound accepts year ≥ min, rejects null + below', () {
      const r = YearRange(minYear: 1970);
      expect(r.hasAnyBound, isTrue);
      expect(r.matches(null), isFalse);
      expect(r.matches(1969), isFalse);
      expect(r.matches(1970), isTrue);
      expect(r.matches(2020), isTrue);
    });

    test('max-only bound accepts year ≤ max, rejects null + above', () {
      const r = YearRange(maxYear: 1989);
      expect(r.hasAnyBound, isTrue);
      expect(r.matches(null), isFalse);
      expect(r.matches(1990), isFalse);
      expect(r.matches(1989), isTrue);
      expect(r.matches(1920), isTrue);
    });

    test('70s-80s range is inclusive on both ends', () {
      const r = YearRange(minYear: 1970, maxYear: 1989);
      expect(r.matches(1969), isFalse);
      expect(r.matches(1970), isTrue);
      expect(r.matches(1984), isTrue);
      expect(r.matches(1989), isTrue);
      expect(r.matches(1990), isFalse);
    });

    test('equality + hashCode so StateNotifier can dedup identical writes', () {
      expect(
        const YearRange(minYear: 1970, maxYear: 1989),
        const YearRange(minYear: 1970, maxYear: 1989),
      );
      expect(
        const YearRange(minYear: 1970, maxYear: 1989).hashCode,
        const YearRange(minYear: 1970, maxYear: 1989).hashCode,
      );
      expect(
        const YearRange(minYear: 1970),
        isNot(const YearRange(minYear: 1970, maxYear: 1989)),
      );
    });
  });

  group('ModeYearRangeController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('setting solo does not affect together and vice versa', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeYearRangeController(
        prefs,
        ModeYearRangeController.readAll(prefs),
      );
      await c.set(ViewMode.solo, const YearRange(minYear: 1970, maxYear: 1989));
      expect(
        c.state[ViewMode.solo],
        const YearRange(minYear: 1970, maxYear: 1989),
      );
      expect(c.state[ViewMode.together], const YearRange.unbounded());

      await c.set(ViewMode.together, const YearRange(minYear: 2020));
      expect(
        c.state[ViewMode.solo],
        const YearRange(minYear: 1970, maxYear: 1989),
      );
      expect(c.state[ViewMode.together], const YearRange(minYear: 2020));
    });

    test('persists each bound under its own int key', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeYearRangeController(
        prefs,
        ModeYearRangeController.readAll(prefs),
      );
      await c.set(ViewMode.solo, const YearRange(minYear: 1970, maxYear: 1989));
      await c.set(ViewMode.together, const YearRange(maxYear: 2010));

      expect(prefs.getInt('wn_year_min_solo'), 1970);
      expect(prefs.getInt('wn_year_max_solo'), 1989);
      expect(prefs.containsKey('wn_year_min_together'), isFalse);
      expect(prefs.getInt('wn_year_max_together'), 2010);
    });

    test('setting null bound removes the corresponding key', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_year_min_solo': 1970,
        'wn_year_max_solo': 1989,
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeYearRangeController(
        prefs,
        ModeYearRangeController.readAll(prefs),
      );
      expect(
        c.state[ViewMode.solo],
        const YearRange(minYear: 1970, maxYear: 1989),
      );

      await c.set(ViewMode.solo, const YearRange(minYear: 1970));
      expect(c.state[ViewMode.solo], const YearRange(minYear: 1970));
      expect(prefs.containsKey('wn_year_max_solo'), isFalse);
      expect(prefs.getInt('wn_year_min_solo'), 1970);

      await c.clear(ViewMode.solo);
      expect(c.state[ViewMode.solo], const YearRange.unbounded());
      expect(prefs.containsKey('wn_year_min_solo'), isFalse);
      expect(prefs.containsKey('wn_year_max_solo'), isFalse);
    });

    test('readAll hydrates both modes independently', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_year_min_solo': 1970,
        'wn_year_max_solo': 1989,
        'wn_year_max_together': 2010,
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeYearRangeController.readAll(prefs);
      expect(map[ViewMode.solo],
          const YearRange(minYear: 1970, maxYear: 1989));
      expect(map[ViewMode.together], const YearRange(maxYear: 2010));
    });
  });
}
