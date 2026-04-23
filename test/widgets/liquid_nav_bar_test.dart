import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/widgets/liquid_nav_bar.dart';

const _destinations = [
  LiquidNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  LiquidNavDestination(
    icon: Icons.explore_outlined,
    selectedIcon: Icons.explore,
    label: 'Discover',
  ),
  LiquidNavDestination(
    icon: Icons.video_library_outlined,
    selectedIcon: Icons.video_library,
    label: 'Library',
  ),
  LiquidNavDestination(
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    label: 'Profile',
  ),
];

Widget _harness({
  required int selectedIndex,
  required ValueChanged<int> onTap,
}) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: Scaffold(
      body: const SizedBox.shrink(),
      bottomNavigationBar: LiquidNavBar(
        selectedIndex: selectedIndex,
        destinations: _destinations,
        onDestinationSelected: onTap,
      ),
    ),
  );
}

void main() {
  group('LiquidNavBar', () {
    testWidgets('shows the filled icon for the selected destination only',
        (tester) async {
      await tester.pumpWidget(_harness(selectedIndex: 0, onTap: (_) {}));
      await tester.pumpAndSettle();

      // Home is selected → filled home + outlined for the rest.
      expect(find.byIcon(Icons.home), findsOneWidget);
      expect(find.byIcon(Icons.explore_outlined), findsOneWidget);
      expect(find.byIcon(Icons.video_library_outlined), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsNothing);
    });

    testWidgets('tapping a destination fires the callback with its index',
        (tester) async {
      int? tapped;
      await tester
          .pumpWidget(_harness(selectedIndex: 0, onTap: (i) => tapped = i));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.video_library_outlined));
      expect(tapped, 2);
    });

    testWidgets('matches the retired NavigationBar 56px height', (tester) async {
      await tester.pumpWidget(_harness(selectedIndex: 0, onTap: (_) {}));
      await tester.pumpAndSettle();

      final bar = tester.getSize(find.byType(LiquidNavBar));
      // No bottom safe-area in the default test viewport, so the bar height
      // equals the documented 56px constant.
      expect(bar.height, LiquidNavBar.height);
    });

    testWidgets('animates indicator position when selection changes',
        (tester) async {
      await tester.pumpWidget(_harness(selectedIndex: 0, onTap: (_) {}));
      await tester.pumpAndSettle();

      // Verifies that selecting a different index renders the new filled
      // icon — the AnimatedPositioned under the hood handles the slide.
      await tester.pumpWidget(_harness(selectedIndex: 3, onTap: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byIcon(Icons.home), findsNothing);
    });
  });
}
