import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/app_icon_provider.dart';
import 'package:watchnext/services/app_icon_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wn/app_icon');
  final List<MethodCall> calls = [];

  void installNativeFake(String currentAlias) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'getCurrent' => currentAlias,
        'setAlias' => null,
        _ => null,
      };
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('first run with no stored pref reads the native current alias',
      () async {
    SharedPreferences.setMockInitialValues({});
    installNativeFake('Vivid');

    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Restore is async; pump until it lands.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    container.read(appIconControllerProvider); // trigger build
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(appIconControllerProvider), AppIconOption.vivid);
    // getCurrent fired exactly once during _restore.
    expect(calls.where((c) => c.method == 'getCurrent').length, 1);
  });

  test('stored pref takes precedence over native getCurrent', () async {
    SharedPreferences.setMockInitialValues({'wn_app_icon': 'minimal'});
    installNativeFake('Vivid');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appIconControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(appIconControllerProvider), AppIconOption.minimal);
    // No getCurrent fired — pref already answered the question.
    expect(calls.where((c) => c.method == 'getCurrent'), isEmpty);
  });

  test('set persists, pushes to native, and updates state', () async {
    SharedPreferences.setMockInitialValues({});
    installNativeFake('Classic');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appIconControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await container
        .read(appIconControllerProvider.notifier)
        .set(AppIconOption.clapper);

    expect(container.read(appIconControllerProvider), AppIconOption.clapper);
    expect(
      calls.where((c) => c.method == 'setAlias').single.arguments,
      {'name': 'Clapper'},
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('wn_app_icon'), 'clapper');
  });

  test('set is a no-op when the option matches current state', () async {
    SharedPreferences.setMockInitialValues({'wn_app_icon': 'vivid'});
    installNativeFake('Vivid');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appIconControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    calls.clear();

    await container
        .read(appIconControllerProvider.notifier)
        .set(AppIconOption.vivid);

    // No native call should have fired.
    expect(calls, isEmpty);
  });
}
