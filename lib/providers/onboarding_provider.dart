import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device "has the user completed onboarding" flag.
///
/// Persistence is per-device on purpose — onboarding is about training
/// the *user's* ratings intuition, and both partners independently
/// complete it on their own phone. Since `ratings` already flows through
/// Firestore, the actual signal is shared; only the "show the screen"
/// decision is local.
///
/// Missing flag is treated as "not done yet" — but the Home screen also
/// gates on `ratings.isEmpty && watchEntries.isEmpty` so existing users
/// who install an update aren't forced through a setup flow they've
/// already effectively completed.
class OnboardingController extends StateNotifier<bool> {
  OnboardingController(this._prefs)
      : super(_prefs.getBool(_key) ?? false);

  final SharedPreferences _prefs;
  static const _key = 'wn_onboarding_done';

  Future<void> markDone() async {
    if (state) return;
    state = true;
    await _prefs.setBool(_key, true);
  }
}

final onboardingDoneProvider =
    StateNotifierProvider<OnboardingController, bool>((ref) {
  throw UnimplementedError(
      'Override onboardingDoneProvider with a controller initialised from '
      'SharedPreferences before runApp() — see main.dart.');
});
