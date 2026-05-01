import 'package:flutter/services.dart';

/// One of the four launcher-icon variants the user can pick from
/// Profile → Preferences → App icon. Each maps to an `<activity-alias>`
/// in `AndroidManifest.xml`; the native [AppIconSwitcher] toggles which
/// is enabled.
enum AppIconOption { classic, vivid, minimal, clapper, cream }

extension AppIconOptionX on AppIconOption {
  /// Matches the alias's short name on the native side
  /// (e.g. `LauncherClassic` → `Classic`). Capitalised because
  /// AndroidManifest activity-alias names are PascalCase.
  String get nativeKey => switch (this) {
        AppIconOption.classic => 'Classic',
        AppIconOption.vivid => 'Vivid',
        AppIconOption.minimal => 'Minimal',
        AppIconOption.clapper => 'Clapper',
        AppIconOption.cream => 'Cream',
      };

  /// Path to the 512×512 preview shipped under `assets/icons/` so the
  /// settings picker can render the variant without poking native res.
  String get assetPath => switch (this) {
        AppIconOption.classic => 'assets/icons/ic_launcher_classic.png',
        AppIconOption.vivid => 'assets/icons/ic_launcher_vivid.png',
        AppIconOption.minimal => 'assets/icons/ic_launcher_minimal.png',
        AppIconOption.clapper => 'assets/icons/ic_launcher_clapper.png',
        AppIconOption.cream => 'assets/icons/ic_launcher_cream.png',
      };

  String get label => switch (this) {
        AppIconOption.classic => 'Classic',
        AppIconOption.vivid => 'Vivid',
        AppIconOption.minimal => 'Minimal',
        AppIconOption.clapper => 'Clapperboard',
        AppIconOption.cream => 'Cream',
      };

  String get description => switch (this) {
        AppIconOption.classic =>
          'The original film-reel-on-strip badge that shipped with v1.',
        AppIconOption.vivid =>
          'High-contrast film reel — bright sprocket holes + a play button hub.',
        AppIconOption.minimal =>
          'Solid violet square with a clean white play triangle. Modern and flat.',
        AppIconOption.clapper => 'Director\'s clapperboard slate with a gold WN.',
        AppIconOption.cream =>
          'Classic\'s navy + gold reel with cream perforated strips and cream-filled reel holes.',
      };
}

AppIconOption appIconOptionFromName(String? name) {
  if (name == null) return AppIconOption.classic;
  return AppIconOption.values.firstWhere(
    (o) => o.name == name,
    orElse: () => AppIconOption.classic,
  );
}

AppIconOption appIconOptionFromNativeKey(String? key) {
  if (key == null) return AppIconOption.classic;
  return AppIconOption.values.firstWhere(
    (o) => o.nativeKey == key,
    orElse: () => AppIconOption.classic,
  );
}

/// Wraps the `wn/app_icon` MethodChannel. Two operations: read the
/// currently-enabled activity-alias, or switch to a new one.
///
/// Errors are swallowed and the channel returns the safe default
/// (Classic) — non-Android platforms (none today, but defensive) never
/// answer the channel and we don't want a single missing native side
/// to crash a settings open.
class AppIconService {
  static const MethodChannel _channel = MethodChannel('wn/app_icon');

  /// Test seam — production code uses the static channel; tests can
  /// inject a mock by passing a custom channel instance.
  final MethodChannel channel;
  AppIconService({MethodChannel? channel}) : channel = channel ?? _channel;

  Future<AppIconOption> getCurrent() async {
    try {
      final String? key = await channel.invokeMethod<String>('getCurrent');
      return appIconOptionFromNativeKey(key);
    } catch (_) {
      return AppIconOption.classic;
    }
  }

  /// Asks Android to swap to the chosen alias. The launcher will reflect
  /// the change on its next refresh; on most launchers this is a couple
  /// of seconds and the home-screen shortcut updates in place. On a few
  /// (older Samsung One UI, some Xiaomi MIUI builds) the user may need
  /// to remove and re-add the shortcut manually — that's why the picker
  /// surfaces a snackbar warning on confirm.
  Future<void> setAlias(AppIconOption option) async {
    await channel.invokeMethod('setAlias', {'name': option.nativeKey});
  }
}
