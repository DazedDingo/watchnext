import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mode_provider.dart';

/// Movie / TV filter for the Home recommendation list.
///
/// `null` = no filter (show both). Enum-valued so the filter chip row can
/// bind 1:1 and the home filter can do a straight equality check against
/// `Recommendation.mediaType`.
enum MediaTypeFilter {
  movie,
  tv,
}

extension MediaTypeFilterExt on MediaTypeFilter {
  String get label {
    switch (this) {
      case MediaTypeFilter.movie:
        return 'Movies';
      case MediaTypeFilter.tv:
        return 'TV';
    }
  }

  /// Matches the `media_type` string we write into `/recommendations` docs.
  String get recMediaType {
    switch (this) {
      case MediaTypeFilter.movie:
        return 'movie';
      case MediaTypeFilter.tv:
        return 'tv';
    }
  }
}

class ModeMediaTypeController
    extends StateNotifier<Map<ViewMode, MediaTypeFilter?>> {
  ModeMediaTypeController(this._prefs, Map<ViewMode, MediaTypeFilter?> initial)
      : super(initial);
  final SharedPreferences _prefs;

  static String _keyFor(ViewMode mode) =>
      mode == ViewMode.solo ? 'wn_media_type_solo' : 'wn_media_type_together';

  static MediaTypeFilter? _decode(String? raw) {
    if (raw == null) return null;
    for (final v in MediaTypeFilter.values) {
      if (v.name == raw) return v;
    }
    return null;
  }

  static Map<ViewMode, MediaTypeFilter?> readAll(SharedPreferences prefs) => {
        ViewMode.solo: _decode(prefs.getString(_keyFor(ViewMode.solo))),
        ViewMode.together:
            _decode(prefs.getString(_keyFor(ViewMode.together))),
      };

  Future<void> set(ViewMode mode, MediaTypeFilter? value) async {
    state = {...state, mode: value};
    final key = _keyFor(mode);
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value.name);
    }
  }
}

final _mediaTypePrefsProvider =
    FutureProvider<SharedPreferences>((_) => SharedPreferences.getInstance());

final modeMediaTypeProvider = StateNotifierProvider<ModeMediaTypeController,
    Map<ViewMode, MediaTypeFilter?>>((ref) {
  final prefs = ref.watch(_mediaTypePrefsProvider).value;
  if (prefs == null) {
    return ModeMediaTypeController(
      _UnsetPrefs(),
      const {ViewMode.solo: null, ViewMode.together: null},
    );
  }
  return ModeMediaTypeController(prefs, ModeMediaTypeController.readAll(prefs));
});

/// Media-type filter for the active view mode. null = show both.
final mediaTypeFilterProvider = Provider<MediaTypeFilter?>((ref) {
  final mode = ref.watch(viewModeProvider);
  final map = ref.watch(modeMediaTypeProvider);
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
