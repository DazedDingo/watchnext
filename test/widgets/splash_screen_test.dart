import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:watchnext/screens/auth/splash_screen.dart';
import 'package:watchnext/widgets/watchnext_logo.dart';

void main() {
  group('SplashScreen', () {
    testWidgets('renders logo lockup with brand + signature', (tester) async {
      await tester.pumpWidget(_hostWithSplash());
      // Animation needs to progress far enough for the logo opacity to be > 0
      // before the text actually paints non-transparently, but the widgets are
      // in the tree from frame 1.
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(WatchNextLogo), findsOneWidget);
      expect(find.text('Watch'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      expect(find.text('by DazedDingo'), findsOneWidget);
    });

    testWidgets('tapping before animation finishes navigates to /login',
        (tester) async {
      final router = _testRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();

      expect(router.routerDelegate.currentConfiguration.fullPath, '/splash');

      await tester.tap(find.byType(SplashScreen));
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.fullPath, '/login');
    });

    testWidgets('auto-advances to /login when animation completes',
        (tester) async {
      final router = _testRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      // The splash animation runs 2400ms; pump past it.
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.fullPath, '/login');
    });
  });
}

Widget _hostWithSplash() {
  return MaterialApp.router(routerConfig: _testRouter());
}

GoRouter _testRouter() => GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
        GoRoute(
          path: '/login',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('LOGIN'))),
        ),
      ],
    );
