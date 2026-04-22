import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/onboarding_provider.dart';
import 'package:watchnext/utils/onboarding_seeds.dart';

void main() {
  group('OnboardingController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('defaults to false when no pref is set', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = OnboardingController(prefs);
      expect(c.state, isFalse);
    });

    test('reads persisted true flag on construction', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_onboarding_done': true,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final c = OnboardingController(prefs);
      expect(c.state, isTrue);
    });

    test('markDone flips state and persists', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = OnboardingController(prefs);
      expect(c.state, isFalse);
      await c.markDone();
      expect(c.state, isTrue);
      expect(prefs.getBool('wn_onboarding_done'), isTrue);
    });

    test('markDone is idempotent', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = OnboardingController(prefs);
      await c.markDone();
      await c.markDone();
      expect(c.state, isTrue);
    });
  });

  group('kOnboardingSeeds', () {
    test('contains a reasonable number of seeds', () {
      expect(kOnboardingSeeds.length, greaterThanOrEqualTo(10));
      expect(kOnboardingSeeds.length, lessThanOrEqualTo(30));
    });

    test('every seed carries the fields the UI depends on', () {
      for (final s in kOnboardingSeeds) {
        expect(s.tmdbId, greaterThan(0));
        expect(s.title, isNotEmpty);
        expect(s.year, greaterThan(1900));
        expect(s.mediaType, anyOf('movie', 'tv'));
        expect(s.posterPath, isNotEmpty,
            reason: '${s.title} has no poster — generator failed');
      }
    });

    test('mixes movies and TV so onboarding covers both formats', () {
      final movies = kOnboardingSeeds.where((s) => s.mediaType == 'movie');
      final tv = kOnboardingSeeds.where((s) => s.mediaType == 'tv');
      expect(movies, isNotEmpty);
      expect(tv, isNotEmpty);
    });
  });
}
