import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/awards_filter_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/utils/oscar_winners.dart';

void main() {
  group('ModeAwardsController', () {
    test('decode returns enum value when name stored', () async {
      SharedPreferences.setMockInitialValues({
        'wn_awards_solo': 'palmeDor',
        'wn_awards_together': 'baftaBestFilm',
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final state = ModeAwardsController.readAll(prefs);
      expect(state[ViewMode.solo], AwardCategory.palmeDor);
      expect(state[ViewMode.together], AwardCategory.baftaBestFilm);
    });

    test('legacy wn_oscar_winners_* migrates to bestPicture', () async {
      SharedPreferences.setMockInitialValues({
        'wn_oscar_winners_solo': true,
        'wn_oscar_winners_together': false,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final state = ModeAwardsController.readAll(prefs);
      expect(state[ViewMode.solo], AwardCategory.bestPicture,
          reason: 'legacy oscar=true must upgrade to Best Picture');
      expect(state[ViewMode.together], AwardCategory.none);
    });

    test('set persists value and clears legacy key', () async {
      SharedPreferences.setMockInitialValues({
        'wn_oscar_winners_solo': true,
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ctrl = ModeAwardsController(
        prefs,
        ModeAwardsController.readAll(prefs),
      );
      await ctrl.set(ViewMode.solo, AwardCategory.palmeDor);
      expect(prefs.getString('wn_awards_solo'), 'palmeDor');
      expect(prefs.getBool('wn_oscar_winners_solo'), isNull,
          reason: 'legacy key must be cleared to avoid double-read');
    });

    test('set(none) clears the key', () async {
      SharedPreferences.setMockInitialValues({'wn_awards_solo': 'bestPicture'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ctrl = ModeAwardsController(
        prefs,
        ModeAwardsController.readAll(prefs),
      );
      await ctrl.set(ViewMode.solo, AwardCategory.none);
      expect(prefs.getString('wn_awards_solo'), isNull);
    });

    test('unknown stored value decodes as none', () async {
      SharedPreferences.setMockInitialValues({
        'wn_awards_solo': 'notARealCategory',
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final state = ModeAwardsController.readAll(prefs);
      expect(state[ViewMode.solo], AwardCategory.none);
    });

    test('any category persists + decodes', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ctrl = ModeAwardsController(
        prefs,
        ModeAwardsController.readAll(prefs),
      );
      await ctrl.set(ViewMode.solo, AwardCategory.any);
      expect(prefs.getString('wn_awards_solo'), 'any');
      final reloaded = ModeAwardsController.readAll(prefs);
      expect(reloaded[ViewMode.solo], AwardCategory.any);
    });
  });

  group('awardsFilterProvider mirrors per-mode state', () {
    test('reads solo mode when viewMode=solo, together when together',
        () async {
      SharedPreferences.setMockInitialValues({
        'wn_awards_solo': 'palmeDor',
        'wn_awards_together': 'bestPicture',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Let the SharedPreferences future resolve inside the provider.
      container.read(modeAwardsProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      container.read(viewModeProvider.notifier).set(ViewMode.solo);
      expect(container.read(awardsFilterProvider), AwardCategory.palmeDor);

      container.read(viewModeProvider.notifier).set(ViewMode.together);
      expect(container.read(awardsFilterProvider), AwardCategory.bestPicture);
    });
  });
}
