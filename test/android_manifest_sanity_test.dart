import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static checks against `android/app/src/main/AndroidManifest.xml`.
///
/// These are NOT integration tests — no emulator, no plugin code runs. They
/// catch the platform-config misses that no Dart unit test could otherwise
/// reach: a missing OAuth callback intent-filter silently breaks Trakt
/// linking, a missing SEND filter silently disables Share-to-Save, etc.
///
/// Inspired by a sister project (gps-pinger v0.1.2) where two missing
/// `local_auth` perms shipped to the first APK because nothing in CI knew
/// to check the manifest.
const _manifestPath = 'android/app/src/main/AndroidManifest.xml';

String _manifest() => File(_manifestPath).readAsStringSync();

bool _hasPermission(String name) =>
    _manifest().contains('android:name="android.permission.$name"');

void main() {
  group('AndroidManifest — runtime perms', () {
    test('declares INTERNET (Firebase, Trakt, TMDB)', () {
      // Without it the app can't reach Firestore, the Trakt API, or TMDB —
      // every screen lights up with network errors. INTERNET is granted
      // automatically on most devices but MUST still be declared.
      expect(_hasPermission('INTERNET'), isTrue);
    });

    test('declares POST_NOTIFICATIONS (FCM nudges, Android 13+)', () {
      // Android 13+ won't deliver any FCM notifications without this.
      expect(_hasPermission('POST_NOTIFICATIONS'), isTrue);
    });
  });

  group('AndroidManifest — Trakt OAuth callback (flutter_web_auth_2)', () {
    test('declares CallbackActivity with the trakt-callback scheme + host',
        () {
      // flutter_web_auth_2 routes the OAuth redirect back into the in-flight
      // future via this activity. If the scheme/host drifts, the browser
      // tab opens, completes, and then hangs forever because nothing
      // catches the redirect — the Trakt link flow silently never
      // resolves.
      final m = _manifest();
      expect(m.contains('com.linusu.flutter_web_auth_2.CallbackActivity'),
          isTrue,
          reason: 'CallbackActivity must be declared so the OAuth redirect '
              'has a target to land on.');
      expect(m.contains('android:scheme="com.household.watchnext"'), isTrue,
          reason: 'OAuth redirect URI scheme must match what TraktService '
              'sends to Trakt — drift = silent hang.');
      expect(m.contains('android:host="trakt-callback"'), isTrue,
          reason: 'Host must be `trakt-callback` to match the redirect URI.');
      expect(m.contains('android.intent.category.BROWSABLE'), isTrue,
          reason: 'BROWSABLE is required for Android to deliver the URL '
              'from the browser tab back to the activity.');
    });
  });

  group('AndroidManifest — Share-to-Save', () {
    test('declares the SEND intent filter for text/plain', () {
      // receive_sharing_intent listens for ACTION_SEND with text/plain on
      // MainActivity. Without this filter, WatchNext doesn't appear in the
      // Android share sheet for IMDb/Letterboxd/TMDB links and the whole
      // share-to-save flow is invisible to the user.
      final m = _manifest();
      expect(m.contains('android.intent.action.SEND'), isTrue,
          reason: 'No SEND filter = WatchNext is missing from the share '
              'sheet, share-to-save is dead.');
      expect(m.contains('android:mimeType="text/plain"'), isTrue,
          reason: 'mimeType must be text/plain — that\'s what IMDb / '
              'Letterboxd / browsers use when sharing a URL.');
    });
  });

  group('AndroidManifest — launcher icon switcher', () {
    // Four `<activity-alias>` entries (Classic / Vivid / Minimal / Clapper)
    // back the in-app launcher-icon picker. The native AppIconSwitcher
    // toggles which is enabled. Invariant: exactly one is enabled at any
    // time, otherwise the user either sees zero icons (no aliases enabled)
    // or duplicates (two aliases enabled).
    test('exactly four LAUNCHER aliases — one per icon variant', () {
      final m = _manifest();
      final mainCount =
          'android.intent.action.MAIN'.allMatches(m).length;
      final launcherCount =
          'android.intent.category.LAUNCHER'.allMatches(m).length;
      expect(mainCount, 4,
          reason: 'four MAIN intents — one per launcher-icon alias '
              '(Classic, Vivid, Minimal, Clapper).');
      expect(launcherCount, 4,
          reason: 'four LAUNCHER intents — one per alias.');
    });

    test('every variant alias is declared by name', () {
      final m = _manifest();
      for (final alias in const [
        'LauncherClassic',
        'LauncherVivid',
        'LauncherMinimal',
        'LauncherClapper',
      ]) {
        expect(m.contains('android:name=".$alias"'), isTrue,
            reason: '$alias missing — the AppIconSwitcher targets four '
                'aliases by name, dropping one breaks setAlias().');
      }
    });

    test('exactly one alias starts enabled (Classic)', () {
      // If zero aliases are enabled, the launcher loses the app icon. If
      // two are enabled, the launcher shows two icons. Manifest must ship
      // with Classic on, the rest off — runtime swaps preserve the
      // invariant.
      final m = _manifest();
      final enabledTrue = 'android:enabled="true"'.allMatches(m).length;
      final enabledFalse = 'android:enabled="false"'.allMatches(m).length;
      expect(enabledTrue, 1,
          reason: 'exactly one alias may declare enabled="true" at install '
              'time (Classic).');
      expect(enabledFalse, 3,
          reason: 'three aliases must declare enabled="false" so the '
              'native switcher is the only path to enable them.');
    });

    test('every alias targets MainActivity', () {
      final m = _manifest();
      final targetCount =
          'android:targetActivity=".MainActivity"'.allMatches(m).length;
      expect(targetCount, 4,
          reason: 'all four aliases must point at MainActivity — '
              'targeting elsewhere would launch a different entrypoint.');
    });

    test('MainActivity itself no longer carries the LAUNCHER filter', () {
      // The LAUNCHER filter has moved off MainActivity and onto the four
      // activity-aliases. If a future edit reintroduces it on MainActivity,
      // we'd ship five launcher icons — four from aliases, one from the
      // activity itself.
      final m = _manifest();
      final mainStart = m.indexOf('<activity\n            android:name=".MainActivity"');
      final mainEnd = m.indexOf('</activity>', mainStart);
      final mainBlock = m.substring(mainStart, mainEnd);
      expect(mainBlock.contains('android.intent.category.LAUNCHER'), isFalse,
          reason: 'MainActivity must NOT carry LAUNCHER — the aliases '
              'own that responsibility for the icon-switcher feature.');
    });
  });
}
