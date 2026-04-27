import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/up_next_style_provider.dart';

void main() {
  group('UpNextStyle', () {
    test('fromName returns the named style', () {
      expect(UpNextStyle.fromName('marquee'), UpNextStyle.marquee);
      expect(UpNextStyle.fromName('strip'), UpNextStyle.strip);
    });

    test('fromName falls back to marquee (the default) on null / unknown',
        () {
      // Existing installs land here on first read post-upgrade — the
      // marquee is the intended default presentation, so unknown / null
      // values should resolve there rather than the static strip.
      expect(UpNextStyle.fromName(null), UpNextStyle.marquee);
      expect(UpNextStyle.fromName('nonsense'), UpNextStyle.marquee);
    });
  });

  group('UpNextStyleController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to marquee when no prior selection is stored', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = UpNextStyleController(prefs);
      expect(c.state, UpNextStyle.marquee);
    });

    test('rehydrates stored style on construction', () async {
      SharedPreferences.setMockInitialValues({'wn_up_next_style': 'strip'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = UpNextStyleController(prefs);
      expect(c.state, UpNextStyle.strip);
    });

    test('set persists to SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = UpNextStyleController(prefs);
      await c.set(UpNextStyle.strip);
      expect(prefs.getString('wn_up_next_style'), 'strip');
      expect(c.state, UpNextStyle.strip);
    });

    test('falls back to marquee when stored value is a stale name',
        () async {
      SharedPreferences.setMockInitialValues(
          {'wn_up_next_style': 'carousel'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = UpNextStyleController(prefs);
      expect(c.state, UpNextStyle.marquee);
    });
  });
}
