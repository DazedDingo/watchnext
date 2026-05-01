import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_icon_service.dart';

const _kPref = 'wn_app_icon';

final appIconServiceProvider = Provider<AppIconService>((ref) => AppIconService());

/// Holds the currently-selected launcher icon. Persisted under [_kPref] so
/// the picker reflects the choice on next launch even before the native
/// `getCurrent` call resolves; on first run with no stored value, falls back
/// to whatever Android's PackageManager reports (Classic by default).
class AppIconController extends StateNotifier<AppIconOption> {
  final AppIconService _service;
  final Future<SharedPreferences> _prefs;

  AppIconController(this._service, {Future<SharedPreferences>? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance(),
        super(AppIconOption.classic) {
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await _prefs;
    final stored = prefs.getString(_kPref);
    if (stored != null) {
      state = appIconOptionFromName(stored);
      return;
    }
    // First launch: fall back to whatever Android currently reports as the
    // enabled alias. This handles users who installed before the picker
    // existed (their alias is implicitly Classic).
    state = await _service.getCurrent();
  }

  /// Set + persist + push to native. No-op when the option matches the
  /// current state (avoids redundant PackageManager writes that the
  /// launcher would still register as "icon changed" and re-render).
  Future<void> set(AppIconOption option) async {
    if (state == option) return;
    state = option;
    await _service.setAlias(option);
    final prefs = await _prefs;
    await prefs.setString(_kPref, option.name);
  }
}

final appIconControllerProvider =
    StateNotifierProvider<AppIconController, AppIconOption>(
  (ref) => AppIconController(ref.watch(appIconServiceProvider)),
);
