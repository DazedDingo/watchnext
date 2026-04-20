import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/genre_filter_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/widgets/genre_sheet.dart';

/// Builds a fresh ModeGenreController wired to mock prefs and overrides the
/// prefs FutureProvider with a synchronous AsyncValue.data — without this,
/// `pumpAndSettle` still leaves the provider on AsyncLoading because the
/// mock platform channel response is deferred past the pump.
Future<ModeGenreController> _mkController({
  Map<String, Object> initialPrefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  // Force the cached singleton to re-read after setMockInitialValues.
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return ModeGenreController(prefs, ModeGenreController.readAll(prefs));
}

Future<void> _pump(
  WidgetTester tester, {
  ViewMode mode = ViewMode.solo,
  Map<String, Object> initialPrefs = const {},
}) async {
  final controller = await _mkController(initialPrefs: initialPrefs);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(controller, mode),
      child: MaterialApp(
        home: Scaffold(body: GenreSheet(mode: mode)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Overrides both the genre controller and the view-mode provider — the
/// sheet writes to whatever mode it was told, but reads from
/// selectedGenresProvider which picks up the mode from `viewModeProvider`.
/// Without overriding both, writes and reads target different mode keys.
List<Override> _overrides(ModeGenreController controller, ViewMode mode) => [
      modeGenreProvider.overrideWith((_) => controller),
      viewModeProvider.overrideWith((_) => _FixedModeController(mode)),
    ];

class _FixedModeController extends StateNotifier<ViewMode>
    implements ModeController {
  _FixedModeController(super.state);

  @override
  Future<void> set(ViewMode mode) async {
    state = mode;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Finder _chipByLabel(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(FilterChip),
    );

void main() {
  testWidgets('renders a FilterChip for every TMDB genre', (tester) async {
    await _pump(tester);
    // A few sampled genres that should be visible (movie + tv union).
    expect(_chipByLabel('War'), findsOneWidget);
    expect(_chipByLabel('Documentary'), findsOneWidget);
    expect(_chipByLabel('Action & Adventure'), findsOneWidget);
    expect(find.text('Filter by genre'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
  });

  testWidgets('tapping a chip toggles it selected', (tester) async {
    await _pump(tester);
    final war = _chipByLabel('War');
    expect(tester.widget<FilterChip>(war).selected, isFalse);

    await tester.ensureVisible(war);
    await tester.tap(war);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(war).selected, isTrue);

    await tester.tap(war);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(war).selected, isFalse);
  });

  testWidgets('selecting multiple chips accumulates in the provider',
      (tester) async {
    final controller = await _mkController();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(controller, ViewMode.solo),
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const GenreSheet(mode: ViewMode.solo);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(_chipByLabel('War'));
    await tester.tap(_chipByLabel('War'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_chipByLabel('Drama'));
    await tester.tap(_chipByLabel('Drama'));
    await tester.pumpAndSettle();

    expect(container.read(selectedGenresProvider), {'War', 'Drama'});
  });

  testWidgets('"Clear all" is disabled with empty selection and enabled once '
      'something is picked', (tester) async {
    await _pump(tester);
    final clearBtn = find.widgetWithText(TextButton, 'Clear all');
    expect(tester.widget<TextButton>(clearBtn).onPressed, isNull);

    await tester.ensureVisible(_chipByLabel('War'));
    await tester.tap(_chipByLabel('War'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(clearBtn).onPressed, isNotNull);

    await tester.tap(clearBtn);
    await tester.pumpAndSettle();
    // All chips should read unselected after Clear all.
    expect(tester.widget<FilterChip>(_chipByLabel('War')).selected, isFalse);
    expect(tester.widget<TextButton>(clearBtn).onPressed, isNull);
  });

  testWidgets('solo and together modes do not bleed into each other',
      (tester) async {
    // Pre-populate together mode with Comedy; solo mode should still render
    // Comedy as unselected.
    await _pump(
      tester,
      mode: ViewMode.solo,
      initialPrefs: const {
        'wn_genres_together': '["Comedy"]',
      },
    );
    expect(
        tester.widget<FilterChip>(_chipByLabel('Comedy')).selected, isFalse);
  });

  testWidgets('hydrates pre-selected chips from prefs for the active mode',
      (tester) async {
    await _pump(
      tester,
      mode: ViewMode.solo,
      initialPrefs: const {
        'wn_genres_solo': '["War","Drama"]',
      },
    );
    expect(tester.widget<FilterChip>(_chipByLabel('War')).selected, isTrue);
    expect(tester.widget<FilterChip>(_chipByLabel('Drama')).selected, isTrue);
    expect(tester.widget<FilterChip>(_chipByLabel('Comedy')).selected, isFalse);
  });

  testWidgets('Done pops the sheet', (tester) async {
    final controller = await _mkController();
    bool sheetOpen = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(controller, ViewMode.solo),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  await showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const GenreSheet(mode: ViewMode.solo),
                  );
                  sheetOpen = false;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Filter by genre'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('Filter by genre'), findsNothing);
    expect(sheetOpen, isFalse);
  });
}
