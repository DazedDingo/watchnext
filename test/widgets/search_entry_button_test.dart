import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:watchnext/widgets/search_entry_button.dart';

class _DiscoverProbe extends StatelessWidget {
  const _DiscoverProbe();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('discover-probe')));
}

Widget _harness() {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: SearchEntryButton()),
      ),
      GoRoute(path: '/discover', builder: (_, _) => const _DiscoverProbe()),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  group('SearchEntryButton', () {
    testWidgets('renders the search hint + leading + trailing affordances',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      expect(find.text('Search movies & TV'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      // Trailing chevron — signals "tap to open another surface" so users
      // don't tap-and-type expecting characters in place.
      expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    });

    testWidgets('is NOT a TextField — tap-and-type cannot land characters',
        (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();
      // The whole point of the redesign: it's a button, not an input.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(InkWell), findsOneWidget);
    });

    testWidgets('tapping pushes /discover', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SearchEntryButton));
      await tester.pumpAndSettle();

      expect(find.text('discover-probe'), findsOneWidget);
    });
  });
}
