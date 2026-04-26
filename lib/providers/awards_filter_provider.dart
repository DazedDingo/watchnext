import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/oscar_winners.dart';
import 'mode_provider.dart';

/// Currently-selected awards filter — defaults to [AwardCategory.none]
/// (no gate). Persisted per mode (`wn_awards_solo/_together`).
///
/// `none` short-circuits the splice in `recommendations_service`; `any`
/// splices the deduped union of every supported award (`kAnyAwardWinners`);
/// every other value splices the matching category's list. Storage stays
/// on the legacy `is_oscar_winner` field for back-compat — see gotcha 25.
///
/// **Why non-nullable**: the dropdown previously used `null` for "Any",
/// but Flutter's `PopupMenuButton<T>` treats `value: null` items as menu
/// dismissal — `onSelected` never fires, so users couldn't switch back.
/// Modeling "no filter" as a real enum value sidesteps that.
class ModeAwardsController
    extends StateNotifier<Map<ViewMode, AwardCategory>> {
  ModeAwardsController(this._prefs, Map<ViewMode, AwardCategory> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_awards_solo' : 'wn_awards_together';

  /// Legacy boolean key from the Oscar-only era. When present and true we
  /// migrate to `AwardCategory.bestPicture` the first time the user opens
  /// the app after upgrade; the old key is then removed.
  static String _legacyKeyFor(ViewMode mode) => mode == ViewMode.solo
      ? 'wn_oscar_winners_solo'
      : 'wn_oscar_winners_together';

  static AwardCategory _decode(String? name) {
    if (name == null) return AwardCategory.none;
    for (final v in AwardCategory.values) {
      if (v.name == name) return v;
    }
    return AwardCategory.none;
  }

  static Map<ViewMode, AwardCategory> readAll(SharedPreferences prefs) {
    final result = <ViewMode, AwardCategory>{};
    for (final mode in ViewMode.values) {
      final stored = prefs.getString(_keyFor(mode));
      if (stored != null) {
        result[mode] = _decode(stored);
        continue;
      }
      // Legacy migration: preserve the previous Oscar-only toggle state.
      final legacy = prefs.getBool(_legacyKeyFor(mode));
      result[mode] =
          legacy == true ? AwardCategory.bestPicture : AwardCategory.none;
    }
    return result;
  }

  Future<void> set(ViewMode mode, AwardCategory value) async {
    state = {...state, mode: value};
    final key = _keyFor(mode);
    if (value == AwardCategory.none) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value.name);
    }
    // Clear the legacy key so migration runs once per install.
    await _prefs.remove(_legacyKeyFor(mode));
  }
}

final _awardsPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeAwardsProvider = StateNotifierProvider<ModeAwardsController,
    Map<ViewMode, AwardCategory>>((ref) {
  final prefs = ref.watch(_awardsPrefsProvider).value;
  if (prefs == null) {
    return ModeAwardsController(
      _UnsetPrefs(),
      const {
        ViewMode.solo: AwardCategory.none,
        ViewMode.together: AwardCategory.none,
      },
    );
  }
  return ModeAwardsController(prefs, ModeAwardsController.readAll(prefs));
});

/// Award filter resolved to the active view mode. [AwardCategory.none] is
/// the no-gate default.
final awardsFilterProvider = Provider<AwardCategory>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeAwardsProvider);
  return map[mode] ?? AwardCategory.none;
});

/// Sentinel used while SharedPreferences loads on first build.
class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async => true;
  @override
  Future<bool> setBool(String key, bool value) async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  String? getString(String key) => null;
  @override
  bool? getBool(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
