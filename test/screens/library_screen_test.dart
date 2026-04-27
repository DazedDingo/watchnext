import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/models/episode.dart';
import 'package:watchnext/models/rating.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/providers/auth_provider.dart';
import 'package:watchnext/providers/household_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/ratings_provider.dart';
import 'package:watchnext/providers/watch_entries_provider.dart';
import 'package:watchnext/providers/watchlist_provider.dart';
import 'package:watchnext/screens/library/library_screen.dart';

/// Library screen — Saved tab: filter + sort + search behaviour through the
/// real widget tree. Pure pipeline coverage lives in
/// `library_filter_provider_test.dart`; this file proves the UI wires the
/// pipeline up end-to-end (typing in the search box reaches the list, the
/// LiquidSegmentedButton emits the right MediaTypeFilter, the genre sheet
/// updates the dropdown badge, the no-matches empty state surfaces a working
/// "Clear filters" button, etc.).
void main() {
  WatchlistItem item({
    required int id,
    required String title,
    String mediaType = 'movie',
    int? year,
    int? runtime,
    List<String> genres = const [],
    DateTime? addedAt,
  }) =>
      WatchlistItem(
        id: '$mediaType:$id',
        mediaType: mediaType,
        tmdbId: id,
        title: title,
        addedBy: 'u1',
        addedAt: addedAt ?? DateTime.utc(2025, 1, 1),
        year: year,
        runtime: runtime,
        genres: genres,
      );

  Future<void> pumpLibrary(
    WidgetTester tester, {
    required List<WatchlistItem> watchlist,
    List<WatchEntry> entries = const [],
    ViewMode mode = ViewMode.together,
  }) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final mockUser = MockUser(uid: 'u1', email: 'a@b.com', displayName: 'A');
    final mockAuth = MockFirebaseAuth(mockUser: mockUser, signedIn: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          watchlistProvider.overrideWith((_) => Stream.value(watchlist)),
          watchEntriesProvider.overrideWith((_) => Stream.value(entries)),
          unratedQueueProvider.overrideWith((_) => Stream.value(const [])),
          unratedEpisodesProvider.overrideWith(
            (_) => Stream.value(const <String, List<Episode>>{}),
          ),
          ratingsProvider.overrideWith((_) => Stream.value(const <Rating>[])),
          householdIdProvider.overrideWith((_) async => 'h1'),
          authStateProvider.overrideWith(
            (_) => Stream<fb_auth.User?>.value(mockAuth.currentUser),
          ),
          viewModeProvider.overrideWith((_) => ModeController(prefs, mode)),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Saved tab — empty state', () {
    testWidgets('renders empty state when no items saved', (tester) async {
      await pumpLibrary(tester, watchlist: const []);
      expect(find.text('Nothing saved yet'), findsOneWidget);
      // Filter bar shouldn't render before there's anything to filter.
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('Saved tab — list rendering + filter bar', () {
    testWidgets('renders saved items + filter bar when populated',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Pulp Fiction'),
        ],
      );
      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Genres'), findsOneWidget);
      expect(find.text('Recently added'), findsOneWidget);
    });

    testWidgets('default sort is "Recently added" — newest first',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(
            id: 1,
            title: 'Older Pick',
            addedAt: DateTime.utc(2024, 1, 1),
          ),
          item(
            id: 2,
            title: 'Newer Pick',
            addedAt: DateTime.utc(2025, 6, 1),
          ),
        ],
      );
      final tiles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(tiles, ['Newer Pick', 'Older Pick']);
    });
  });

  group('Saved tab — search', () {
    testWidgets('typing in the search field filters the list live',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Pulp Fiction'),
          item(id: 3, title: 'Inception'),
        ],
      );

      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsNothing);
      expect(find.text('Inception'), findsNothing);
    });

    testWidgets('clearing the search via × restores the full list',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Pulp Fiction'),
        ],
      );
      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pumpAndSettle();
      expect(find.text('Pulp Fiction'), findsNothing);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsOneWidget);
    });
  });

  group('Saved tab — media type segment', () {
    testWidgets('tapping Movies hides TV rows', (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Westworld', mediaType: 'tv'),
        ],
      );
      expect(find.text('Westworld'), findsOneWidget);

      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Westworld'), findsNothing);
    });

    testWidgets('tapping TV hides movies', (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Westworld', mediaType: 'tv'),
        ],
      );

      await tester.tap(find.text('TV'));
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsNothing);
      expect(find.text('Westworld'), findsOneWidget);
    });
  });

  group('Saved tab — sort popup', () {
    testWidgets('selecting "Title (A–Z)" reorders the list alphabetically',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(
            id: 1,
            title: 'Zodiac',
            addedAt: DateTime.utc(2025, 1, 1),
          ),
          item(
            id: 2,
            title: 'The Matrix',
            addedAt: DateTime.utc(2025, 6, 1),
          ),
          item(
            id: 3,
            title: 'A Beautiful Mind',
            addedAt: DateTime.utc(2025, 3, 1),
          ),
        ],
      );

      // Default sort is dateAddedDesc → Matrix, Beautiful Mind, Zodiac.
      var titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text).data)
          .toList();
      expect(titles, ['The Matrix', 'A Beautiful Mind', 'Zodiac']);

      await tester.tap(find.text('Recently added'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Title (A–Z)').last);
      await tester.pumpAndSettle();

      titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text).data)
          .toList();
      // Articles ("The"/"A") get stripped before sorting → A Beautiful Mind,
      // The Matrix, Zodiac.
      expect(titles, ['A Beautiful Mind', 'The Matrix', 'Zodiac']);
    });

    testWidgets('sort label updates to reflect the active mode',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [item(id: 1, title: 'A')],
      );

      await tester.tap(find.text('Recently added'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Year (newest)').last);
      await tester.pumpAndSettle();

      expect(find.text('Year (newest)'), findsOneWidget);
      expect(find.text('Recently added'), findsNothing);
    });
  });

  group('Saved tab — genre sheet', () {
    testWidgets('tapping Genres opens the sheet; selecting a chip narrows '
        'the list and stamps the dropdown badge', (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'War Pick', genres: const ['War']),
          item(id: 2, title: 'Drama Pick', genres: const ['Drama']),
        ],
      );

      await tester.tap(find.text('Genres'));
      await tester.pumpAndSettle();
      expect(find.text('Filter by genre'), findsOneWidget);

      // Tap the War chip, then Done.
      final war = find.ancestor(
        of: find.text('War'),
        matching: find.byType(FilterChip),
      );
      await tester.ensureVisible(war);
      await tester.tap(war);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      // Only the War-tagged title remains; dropdown shows the active label.
      expect(find.text('War Pick'), findsOneWidget);
      expect(find.text('Drama Pick'), findsNothing);
      // With one genre selected, the dropdown shows the single name.
      expect(find.text('War'), findsWidgets);
    });
  });

  group('Saved tab — no matches + clear filters', () {
    testWidgets('search with no matches shows the no-matches empty state '
        'with a "Clear filters" button that resets the search',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Pulp Fiction'),
        ],
      );
      await tester.enterText(find.byType(TextField), 'zzz nothing matches');
      await tester.pumpAndSettle();

      expect(find.text('No saved titles match'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Clear filters'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
      await tester.pumpAndSettle();

      expect(find.text('No saved titles match'), findsNothing);
      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsOneWidget);

      // Search field text reflects the cleared provider state.
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller!.text, isEmpty);
    });

    testWidgets('"Clear filters" also resets media type + genres', (tester) async {
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Westworld', mediaType: 'tv'),
        ],
      );

      // Narrow to Movies, then search for something unmatched to surface the
      // clear-filters affordance.
      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No saved titles match'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
      await tester.pumpAndSettle();

      // Both items visible — media type filter cleared too.
      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Westworld'), findsOneWidget);
    });
  });

  WatchEntry watchedEntry({
    required int id,
    required String title,
    String mediaType = 'movie',
    int? year,
    List<String> genres = const [],
    DateTime? lastWatchedAt,
  }) =>
      WatchEntry(
        id: WatchEntry.buildId(mediaType, id),
        mediaType: mediaType,
        tmdbId: id,
        title: title,
        year: year,
        genres: genres,
        lastWatchedAt: lastWatchedAt ?? DateTime.utc(2025, 1, 1),
      );

  Future<void> openWatchedTab(WidgetTester tester) async {
    await tester.tap(find.text('Watched'));
    await tester.pumpAndSettle();
  }

  group('Watched tab — filters', () {
    testWidgets('default render shows entries (no filters active)',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: const [],
        entries: [
          watchedEntry(id: 1, title: 'The Matrix'),
          watchedEntry(id: 2, title: 'Pulp Fiction'),
        ],
      );
      await openWatchedTab(tester);
      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsOneWidget);
      // Filter bar visible.
      expect(find.text('Recently watched'), findsOneWidget);
      expect(find.text('Genres'), findsOneWidget);
    });

    testWidgets('typing in search narrows the list live', (tester) async {
      await pumpLibrary(
        tester,
        watchlist: const [],
        entries: [
          watchedEntry(id: 1, title: 'The Matrix'),
          watchedEntry(id: 2, title: 'Pulp Fiction'),
          watchedEntry(id: 3, title: 'Inception'),
        ],
      );
      await openWatchedTab(tester);

      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsNothing);
      expect(find.text('Inception'), findsNothing);
    });

    testWidgets('clearing the search via × restores the full list',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: const [],
        entries: [
          watchedEntry(id: 1, title: 'The Matrix'),
          watchedEntry(id: 2, title: 'Pulp Fiction'),
        ],
      );
      await openWatchedTab(tester);

      await tester.enterText(find.byType(TextField), 'matrix');
      await tester.pumpAndSettle();
      expect(find.text('Pulp Fiction'), findsNothing);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsOneWidget);
    });

    testWidgets('switching media type hides non-matching rows',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: const [],
        entries: [
          watchedEntry(id: 1, title: 'The Matrix'),
          watchedEntry(id: 2, title: 'Westworld', mediaType: 'tv'),
        ],
      );
      await openWatchedTab(tester);
      expect(find.text('Westworld'), findsOneWidget);

      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();

      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Westworld'), findsNothing);
    });

    testWidgets('search with no matches surfaces "Clear filters" empty state '
        'that resets the search', (tester) async {
      await pumpLibrary(
        tester,
        watchlist: const [],
        entries: [
          watchedEntry(id: 1, title: 'The Matrix'),
          watchedEntry(id: 2, title: 'Pulp Fiction'),
        ],
      );
      await openWatchedTab(tester);

      await tester.enterText(find.byType(TextField), 'zzz nothing');
      await tester.pumpAndSettle();

      expect(find.text('No watched titles match'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Clear filters'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
      await tester.pumpAndSettle();

      expect(find.text('No watched titles match'), findsNothing);
      expect(find.text('The Matrix'), findsOneWidget);
      expect(find.text('Pulp Fiction'), findsOneWidget);

      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller!.text, isEmpty);
    });

    testWidgets('sort popup label updates when selection changes',
        (tester) async {
      await pumpLibrary(
        tester,
        watchlist: const [],
        entries: [
          watchedEntry(id: 1, title: 'A', year: 2020),
        ],
      );
      await openWatchedTab(tester);

      await tester.tap(find.text('Recently watched'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Year (newest)').last);
      await tester.pumpAndSettle();

      expect(find.text('Year (newest)'), findsOneWidget);
      expect(find.text('Recently watched'), findsNothing);
    });
  });

  group('Saved tab — watched items hidden', () {
    testWidgets('items the household has watched do not appear in Saved',
        (tester) async {
      // Together-mode rule: any member who watched the title hides it from
      // Saved (matches the existing pre-filter behaviour). Build a watched
      // entry whose id matches the watchlist item.
      final watched = WatchEntry(
        id: WatchEntry.buildId('movie', 1),
        mediaType: 'movie',
        tmdbId: 1,
        title: 'The Matrix',
        watchedBy: const {'u1': true},
      );
      await pumpLibrary(
        tester,
        watchlist: [
          item(id: 1, title: 'The Matrix'),
          item(id: 2, title: 'Pulp Fiction'),
        ],
        entries: [watched],
      );

      expect(find.text('The Matrix'), findsNothing);
      expect(find.text('Pulp Fiction'), findsOneWidget);
    });
  });
}
