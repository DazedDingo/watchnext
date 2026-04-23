import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/oscar_winners.dart';
import 'mode_provider.dart';

/// Currently-selected awards filter — `null` means "any" (no award gate).
/// Persisted per mode (`wn_awards_solo/_together`) so a user can keep
/// Best Picture on for Together night and leave Solo open.
///
/// When active, `recommendations_service.refresh()` splices the
/// corresponding list from `kAwardWinners` into the candidate pool and
/// stamps `is_oscar_winner=true` on those rows (the service layer keeps
/// the Oscar tag name for storage back-compat — see writeCandidateDocs).
class ModeAwardsController
    extends StateNotifier<Map<ViewMode, AwardCategory?>> {
  ModeAwardsController(this._prefs, Map<ViewMode, AwardCategory?> initial)
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

  static AwardCategory? _decode(String? name) {
    if (name == null) return null;
    for (final v in AwardCategory.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  static Map<ViewMode, AwardCategory?> readAll(SharedPreferences prefs) {
    final result = <ViewMode, AwardCategory?>{};
    for (final mode in ViewMode.values) {
      final stored = prefs.getString(_keyFor(mode));
      if (stored != null) {
        result[mode] = _decode(stored);
        continue;
      }
      // Legacy migration: preserve the previous Oscar-only toggle state.
      final legacy = prefs.getBool(_legacyKeyFor(mode));
      result[mode] = legacy == true ? AwardCategory.bestPicture : null;
    }
    return result;
  }

  Future<void> set(ViewMode mode, AwardCategory? value) async {
    state = {...state, mode: value};
    final key = _keyFor(mode);
    if (value == null) {
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
    Map<ViewMode, AwardCategory?>>((ref) {
  final prefs = ref.watch(_awardsPrefsProvider).value;
  if (prefs == null) {
    return ModeAwardsController(
      _UnsetPrefs(),
      const {ViewMode.solo: null, ViewMode.together: null},
    );
  }
  return ModeAwardsController(prefs, ModeAwardsController.readAll(prefs));
});

/// Award filter resolved to the active view mode. `null` = no gate.
final awardsFilterProvider = Provider<AwardCategory?>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeAwardsProvider);
  return map[mode];
});

/// Sentinel used while SharedPreferences loads on first build — mirrors
/// the pattern in `oscar_filter_provider.dart`.
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
