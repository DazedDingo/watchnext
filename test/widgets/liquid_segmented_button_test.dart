import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/widgets/liquid_segmented_button.dart';

enum _Demo { a, b, c }

Widget _harness({
  required _Demo selected,
  required ValueChanged<_Demo> onChanged,
}) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LiquidSegmentedButton<_Demo>(
            selected: selected,
            segments: const [
              LiquidSegment(value: _Demo.a, label: 'Alpha'),
              LiquidSegment(
                value: _Demo.b,
                label: 'Beta',
                icon: Icons.star,
              ),
              LiquidSegment(value: _Demo.c, label: 'Gamma'),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('LiquidSegmentedButton', () {
    testWidgets('renders all segment labels + icon', (tester) async {
      await tester.pumpWidget(_harness(selected: _Demo.a, onChanged: (_) {}));
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('tapping an unselected segment fires onChanged with its value',
        (tester) async {
      _Demo? chosen;
      await tester.pumpWidget(
        _harness(selected: _Demo.a, onChanged: (v) => chosen = v),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Gamma'));
      expect(chosen, _Demo.c);
    });

    testWidgets('tapping the already-selected segment is a no-op',
        (tester) async {
      int calls = 0;
      await tester.pumpWidget(
        _harness(selected: _Demo.b, onChanged: (_) => calls++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Beta'));
      expect(calls, 0);
    });

    testWidgets('advancing selection slides the indicator without error',
        (tester) async {
      await tester.pumpWidget(_harness(selected: _Demo.a, onChanged: (_) {}));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_harness(selected: _Demo.c, onChanged: (_) {}));
      // Pump through the indicator's 320ms slide animation.
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
