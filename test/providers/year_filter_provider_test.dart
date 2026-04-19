import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/year_filter_provider.dart';

void main() {
  group('YearBucket.matches', () {
    test('2020s covers [2020, +∞)', () {
      expect(YearBucket.y2020s.matches(2020), isTrue);
      expect(YearBucket.y2020s.matches(2026), isTrue);
      expect(YearBucket.y2020s.matches(2019), isFalse);
    });

    test('2010s covers [2010, 2019]', () {
      expect(YearBucket.y2010s.matches(2009), isFalse);
      expect(YearBucket.y2010s.matches(2010), isTrue);
      expect(YearBucket.y2010s.matches(2019), isTrue);
      expect(YearBucket.y2010s.matches(2020), isFalse);
    });

    test('2000s covers [2000, 2009]', () {
      expect(YearBucket.y2000s.matches(1999), isFalse);
      expect(YearBucket.y2000s.matches(2000), isTrue);
      expect(YearBucket.y2000s.matches(2009), isTrue);
      expect(YearBucket.y2000s.matches(2010), isFalse);
    });

    test('90s covers [1990, 1999]', () {
      expect(YearBucket.y90s.matches(1989), isFalse);
      expect(YearBucket.y90s.matches(1990), isTrue);
      expect(YearBucket.y90s.matches(1999), isTrue);
      expect(YearBucket.y90s.matches(2000), isFalse);
    });

    test('classic covers (-∞, 1990)', () {
      expect(YearBucket.classic.matches(1989), isTrue);
      expect(YearBucket.classic.matches(1970), isTrue);
      expect(YearBucket.classic.matches(1990), isFalse);
    });

    test('buckets partition known years (every year hits exactly one)', () {
      for (var y = 1900; y <= 2030; y++) {
        final hits = YearBucket.values.where((b) => b.matches(y)).toList();
        expect(hits, hasLength(1),
            reason: '$y matched ${hits.length} buckets: $hits');
      }
    });

    test('null year matches nothing (unknown era is filtered out)', () {
      for (final b in YearBucket.values) {
        expect(b.matches(null), isFalse);
      }
    });

    test('labels are non-empty and unique', () {
      final labels = YearBucket.values.map((b) => b.label).toList();
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      expect(labels.toSet().length, labels.length);
    });
  });

  group('ModeYearController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('setting solo does not affect together and vice versa', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeYearController(prefs, ModeYearController.readAll(prefs));
      await c.set(ViewMode.solo, YearBucket.y90s);
      expect(c.state[ViewMode.solo], YearBucket.y90s);
      expect(c.state[ViewMode.together], isNull);

      await c.set(ViewMode.together, YearBucket.y2020s);
      expect(c.state[ViewMode.solo], YearBucket.y90s);
      expect(c.state[ViewMode.together], YearBucket.y2020s);
    });

    test('persists to SharedPreferences under two keys', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeYearController(prefs, ModeYearController.readAll(prefs));
      await c.set(ViewMode.solo, YearBucket.classic);
      await c.set(ViewMode.together, YearBucket.y2010s);

      expect(prefs.getString('wn_year_solo'), 'classic');
      expect(prefs.getString('wn_year_together'), 'y2010s');
    });

    test('set(null) removes the key', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_year_solo': 'y2020s',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeYearController(prefs, ModeYearController.readAll(prefs));
      expect(c.state[ViewMode.solo], YearBucket.y2020s);

      await c.set(ViewMode.solo, null);
      expect(c.state[ViewMode.solo], isNull);
      expect(prefs.containsKey('wn_year_solo'), isFalse);
    });

    test('unknown stored value decodes to null (forward-compat)', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_year_solo': 'silent_era',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeYearController.readAll(prefs);
      expect(map[ViewMode.solo], isNull);
    });
  });
}
