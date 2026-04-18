import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// Length-of-the-thing filter, sitting alongside the mood pills on Home.
///
/// Runtimes are stored in minutes on WatchEntry / WatchlistItem /
/// Recommendation. A null runtime on a rec means TMDB trending didn't
/// include it (trending endpoints omit runtime to keep payloads small).
/// When a bucket is active, we hide null-runtime recs — the user asked
/// for a specific length and we can't honestly say whether a mystery-length
/// item qualifies.
enum RuntimeBucket {
  short, // < 90 min
  medium, // 90–120 min
  long_, // > 120 min
}

extension RuntimeBucketExt on RuntimeBucket {
  String get label {
    switch (this) {
      case RuntimeBucket.short:
        return '< 90 min';
      case RuntimeBucket.medium:
        return '90–120';
      case RuntimeBucket.long_:
        return '> 2h';
    }
  }

  /// Returns true iff [runtimeMinutes] falls inside this bucket.
  /// A null runtime never matches — we'd rather drop it from a length-filtered
  /// list than show something whose length we can't confirm.
  bool matches(int? runtimeMinutes) {
    if (runtimeMinutes == null) return false;
    switch (this) {
      case RuntimeBucket.short:
        return runtimeMinutes < 90;
      case RuntimeBucket.medium:
        return runtimeMinutes >= 90 && runtimeMinutes <= 120;
      case RuntimeBucket.long_:
        return runtimeMinutes > 120;
    }
  }
}

/// Per-mode runtime-bucket selection, persisted to SharedPreferences under
/// `wn_runtime_solo` / `wn_runtime_together`. Mirrors [moodProvider]'s
/// mode-keyed shape: reads yield the current mode's slot, writes go only
/// to that slot.
class ModeRuntimeController extends StateNotifier<Map<ViewMode, RuntimeBucket?>> {
  ModeRuntimeController(this._prefs, Map<ViewMode, RuntimeBucket?> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_runtime_solo' : 'wn_runtime_together';

  static RuntimeBucket? _decode(String? raw) {
    if (raw == null) return null;
    for (final b in RuntimeBucket.values) {
      if (b.name == raw) return b;
    }
    return null;
  }

  static Map<ViewMode, RuntimeBucket?> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together: _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, RuntimeBucket? bucket) async {
    state = {...state, mode: bucket};
    final key = _keyFor(mode);
    if (bucket == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, bucket.name);
    }
  }
}

final _runtimePrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeRuntimeProvider = StateNotifierProvider<ModeRuntimeController,
    Map<ViewMode, RuntimeBucket?>>((ref) {
  final prefs = ref.watch(_runtimePrefsProvider).value;
  if (prefs == null) {
    return ModeRuntimeController(
      _UnsetPrefs(),
      const {ViewMode.solo: null, ViewMode.together: null},
    );
  }
  return ModeRuntimeController(prefs, ModeRuntimeController.readAll(prefs));
});

/// Runtime bucket for the active view mode. null = no filter.
final runtimeFilterProvider = Provider<RuntimeBucket?>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeRuntimeProvider);
  return map[mode];
});

/// Sentinel used while SharedPreferences loads on first build.
class _UnsetPrefs implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  String? getString(String key) => null;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
