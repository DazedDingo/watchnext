import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/widgets/help_button.dart';

void main() {
  group('HelpButton', () {
    testWidgets('renders as a help icon in an AppBar', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          appBar: _TestAppBar(),
        ),
      ));

      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('tapping opens a dialog with title and body', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          appBar: _TestAppBar(),
        ),
      ));

      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();

      expect(find.text('Demo screen'), findsOneWidget);
      expect(find.textContaining('Explains what it does'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
    });

    testWidgets('Got it dismisses the dialog', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          appBar: _TestAppBar(),
        ),
      ));

      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

class _TestAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _TestAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
        title: const Text('X'),
        actions: const [
          HelpButton(title: 'Demo screen', body: 'Explains what it does.'),
        ],
      );
}
