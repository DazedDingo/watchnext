import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/widgets/empty_state.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: child));

  group('EmptyState', () {
    testWidgets('renders icon, title, and subtitle', (tester) async {
      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.bookmark_border,
        title: 'Nothing here',
        subtitle: 'Add titles to see them.',
      )));
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.text('Add titles to see them.'), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
    });

    testWidgets('subtitle is optional', (tester) async {
      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
      )));
      expect(find.text('No matches'), findsOneWidget);
      // Just title present, no random extra text.
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('action button fires when labelled + onAction provided',
        (tester) async {
      var tapped = 0;
      await tester.pumpWidget(host(EmptyState(
        icon: Icons.link_off,
        title: 'Not linked',
        actionLabel: 'Link now',
        onAction: () => tapped++,
      )));
      await tester.tap(find.text('Link now'));
      expect(tapped, 1);
    });

    testWidgets('action hidden when onAction is null even with label',
        (tester) async {
      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.link_off,
        title: 'x',
        actionLabel: 'Link now',
      )));
      expect(find.widgetWithText(FilledButton, 'Link now'), findsNothing);
    });

    testWidgets('compact variant uses smaller icon', (tester) async {
      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.error_outline,
        title: 'x',
        compact: true,
      )));
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(icon.size, lessThan(40));
    });
  });
}
