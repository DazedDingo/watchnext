import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/app_icon_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppIconOption mapping', () {
    test('nativeKey is PascalCase and matches AndroidManifest alias names', () {
      expect(AppIconOption.classic.nativeKey, 'Classic');
      expect(AppIconOption.vivid.nativeKey, 'Vivid');
      expect(AppIconOption.minimal.nativeKey, 'Minimal');
      expect(AppIconOption.clapper.nativeKey, 'Clapper');
      expect(AppIconOption.cream.nativeKey, 'Cream');
    });

    test('every option points at an existing asset path', () {
      for (final o in AppIconOption.values) {
        expect(o.assetPath, startsWith('assets/icons/'));
        expect(o.assetPath, endsWith('.png'));
      }
    });

    test('appIconOptionFromName round-trips and falls back safely', () {
      expect(appIconOptionFromName('classic'), AppIconOption.classic);
      expect(appIconOptionFromName('vivid'), AppIconOption.vivid);
      expect(appIconOptionFromName('minimal'), AppIconOption.minimal);
      expect(appIconOptionFromName('clapper'), AppIconOption.clapper);
      expect(appIconOptionFromName('cream'), AppIconOption.cream);
      expect(appIconOptionFromName(null), AppIconOption.classic);
      expect(appIconOptionFromName('garbage'), AppIconOption.classic);
    });

    test('appIconOptionFromNativeKey accepts capitalized native names', () {
      expect(appIconOptionFromNativeKey('Classic'), AppIconOption.classic);
      expect(appIconOptionFromNativeKey('Vivid'), AppIconOption.vivid);
      expect(appIconOptionFromNativeKey('Minimal'), AppIconOption.minimal);
      expect(appIconOptionFromNativeKey('Clapper'), AppIconOption.clapper);
      expect(appIconOptionFromNativeKey('Cream'), AppIconOption.cream);
      // Defensive: anything else collapses to Classic so the picker is never
      // stuck rendering an "unknown" state.
      expect(appIconOptionFromNativeKey(null), AppIconOption.classic);
      expect(appIconOptionFromNativeKey('LauncherClassic'),
          AppIconOption.classic);
    });
  });

  group('AppIconService channel', () {
    const channel = MethodChannel('wn/app_icon');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'getCurrent' => 'Vivid',
          'setAlias' => null,
          _ => null,
        };
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('getCurrent maps the native key to the matching option', () async {
      final service = AppIconService();
      final result = await service.getCurrent();
      expect(result, AppIconOption.vivid);
      expect(calls.single.method, 'getCurrent');
    });

    test('setAlias forwards the option\'s native key as the name argument',
        () async {
      final service = AppIconService();
      await service.setAlias(AppIconOption.clapper);
      expect(calls.single.method, 'setAlias');
      expect(calls.single.arguments, {'name': 'Clapper'});
    });

    test('getCurrent falls back to Classic when the native side throws',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'NO_NATIVE');
      });
      final result = await AppIconService().getCurrent();
      expect(result, AppIconOption.classic);
    });
  });
}
