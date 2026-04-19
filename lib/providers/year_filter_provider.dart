import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// Era / release-year filter, sitting alongside mood + runtime pills on Home.
///
/// Years are stored as `int?` on Recommendation. A null year on a rec means
/// the source didn't provide a release date (rare; Reddit mentions sometimes
/// lack it). When a bucket is active we hide null-year recs — mirrors the
/// runtime bucket contract so the user gets what they asked for.
enum YearBucket {
  y2020s,
  y2010s,
  y2000s,
  y90s,
  classic, // pre-1990
}

extension YearBucketExt on YearBucket {
  String get label {
    switch (this) {
      case YearBucket.y2020s:
        return "2020s";
      case YearBucket.y2010s:
        return "2010s";
      case YearBucket.y2000s:
        return "2000s";
      case YearBucket.y90s:
        return "90s";
      case YearBucket.classic:
        return "Classic";
    }
  }

  /// Returns true iff [year] falls inside this bucket. A null year never
  /// matches — we'd rather drop mystery-era items than mislead under a
  /// specific decade pill.
  bool matches(int? year) {
    if (year == null) return false;
    switch (this) {
      case YearBucket.y2020s:
        return year >= 2020;
      case YearBucket.y2010s:
        return year >= 2010 && year <= 2019;
      case YearBucket.y2000s:
        return year >= 2000 && year <= 2009;
      case YearBucket.y90s:
        return year >= 1990 && year <= 1999;
      case YearBucket.classic:
        return year < 1990;
    }
  }
}

/// Per-mode year-bucket selection, persisted to SharedPreferences under
/// `wn_year_solo` / `wn_year_together`. Mirrors [moodProvider] /
/// [modeRuntimeProvider]'s mode-keyed shape.
class ModeYearController extends StateNotifier<Map<ViewMode, YearBucket?>> {
  ModeYearController(this._prefs, Map<ViewMode, YearBucket?> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_year_solo' : 'wn_year_together';

  static YearBucket? _decode(String? raw) {
    if (raw == null) return null;
    for (final b in YearBucket.values) {
      if (b.name == raw) return b;
    }
    return null;
  }

  static Map<ViewMode, YearBucket?> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together: _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, YearBucket? bucket) async {
    state = {...state, mode: bucket};
    final key = _keyFor(mode);
    if (bucket == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, bucket.name);
    }
  }
}

final _yearPrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeYearProvider =
    StateNotifierProvider<ModeYearController, Map<ViewMode, YearBucket?>>((ref) {
  final prefs = ref.watch(_yearPrefsProvider).value;
  if (prefs == null) {
    return ModeYearController(
      _UnsetPrefs(),
      const {ViewMode.solo: null, ViewMode.together: null},
    );
  }
  return ModeYearController(prefs, ModeYearController.readAll(prefs));
});

/// Year bucket for the active view mode. null = no filter.
final yearFilterProvider = Provider<YearBucket?>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeYearProvider);
  return map[mode];
});

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
