import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/recommendation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/awards_filter_provider.dart';
import '../../providers/curated_source_provider.dart';
import '../../providers/rewatch_provider.dart';
import '../../providers/external_ratings_provider.dart';
import '../../providers/genre_filter_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/include_watched_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../onboarding/onboarding_screen.dart';
import '../../providers/media_type_filter_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/recommendations_provider.dart';
import '../../providers/runtime_filter_provider.dart';
import '../../providers/sort_mode_provider.dart';
import '../../providers/upcoming_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../providers/year_filter_provider.dart';
import '../../screens/concierge/concierge_sheet.dart';
import '../../screens/like_these/like_these_sheet.dart';
import '../../services/tmdb_service.dart';
import '../../utils/animation_cap.dart';
import '../../utils/oscar_winners.dart';
import '../../utils/rec_explainer.dart';
import '../../utils/surprise_picker.dart';
import '../../widgets/async_error.dart';
import '../../widgets/genre_sheet.dart';
import '../../widgets/help_button.dart';
import '../../widgets/liquid_segmented_button.dart';
import '../../widgets/mode_toggle.dart';
import '../../widgets/watchnext_logo.dart';
import '../../widgets/year_range_slider.dart';

const _homeHelp =
    'WatchNext picks something to watch that works for both of you.\n\n'
    '• Tonight\'s Pick — the top scored title. Tap "Let\'s watch this" to open it, or "Not tonight" to skip for this session.\n'
    '• Recommended for you — the rest of the ranked list. Tap any to see details.\n'
    '• Filters — tap to expand. Genres (multi-select), runtime bucket, year range, sort mode (Top-rated / Popularity / Recent / Underseen), curated source (A24, Neon, Studio Ghibli, Searchlight), and awards (Best Picture, Palme d\'Or, BAFTA Best Film) live here. The header summarises what\'s active.\n'
    '• Search — type to narrow to titles containing your query.\n'
    '• Solo / Together toggle — top-right. Solo ranks for you alone; Together ranks for the household.\n'
    '• Pull down to refresh — regenerates recommendations from your watchlist + trending + Reddit buzz + filtered discover.\n'
    '• Ask AI (bottom-right) — chat with the concierge for a bespoke recommendation.\n'
    '• Decide Together — quick tap-through to break a tie with your partner.';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // IDs dismissed via "Not tonight" — local per-session, not persisted.
  final _dismissed = <String>{};

  // Live search query. Local per-session; cleared on screen rebuild.
  final _searchCtrl = TextEditingController();
  String _search = '';

  // Debounces filter-change → auto-refresh so tapping through chip
  // combinations only fires one request. 700ms is tight enough to feel
  // immediate and loose enough to coalesce bursts.
  Timer? _autoRefreshDebounce;

  // One-shot: kick off a backfill of `imdb_id` on existing rec docs as soon
  // as Home loads. Without this, the row-level IMDb chip only populates
  // after a pull-to-refresh, which feels broken if you just installed the
  // app and opened Home. Fire once per session.
  bool _imdbBackfillStarted = false;

  // Session guard for the keyword→genre augmenter. Widens `genres` on
  // existing rec docs so AND-intersection filters (e.g. Sci-Fi + War)
  // pick up cross-genre titles TMDB tags narrowly.
  bool _keywordsBackfillStarted = false;

  @override
  void dispose() {
    _autoRefreshDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Kicks off a non-forcing refresh after the debounce window elapses.
  /// Non-forcing = don't regenerate the taste profile; just rebuild the pool
  /// with the currently selected filters. Errors are surfaced via snackbar.
  void _scheduleAutoRefresh() {
    _autoRefreshDebounce?.cancel();
    _autoRefreshDebounce = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      ref.invalidate(refreshRecommendationsProvider);
      unawaited(
        ref.read(refreshRecommendationsProvider(false).future).catchError((e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Refresh failed: $e')),
            );
          }
        }),
      );
    });
  }

  Future<void> _openGenreSheet(
    BuildContext context,
    WidgetRef ref,
    ViewMode mode,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => GenreSheet(mode: mode),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Onboarding gate — show the first-run poster-rating grid when BOTH:
    //   (a) the user hasn't flipped the local "done" flag yet, AND
    //   (b) the household has no ratings and no watch entries (so we're
    //       not forcing existing users through onboarding after updates).
    // Self-heals: once any rating or watch entry exists, the gate is
    // permanently skipped on this device. Skipping the flag also works
    // (it sets the flag directly).
    final onboardingDone = ref.watch(onboardingDoneProvider);
    if (!onboardingDone) {
      final ratingsAsync = ref.watch(ratingsProvider);
      final entriesAsync = ref.watch(watchEntriesProvider);
      final ratingsEmpty = ratingsAsync.asData?.value.isEmpty ?? true;
      final entriesEmpty = entriesAsync.asData?.value.isEmpty ?? true;
      if (ratingsEmpty && entriesEmpty) {
        return const OnboardingScreen();
      }
      // Household has data — silently flip the flag so future builds
      // skip the async checks entirely.
      Future.microtask(
          () => ref.read(onboardingDoneProvider.notifier).markDone());
    }

    final mode = ref.watch(viewModeProvider);
    final selectedGenres = ref.watch(selectedGenresProvider);
    final runtime = ref.watch(runtimeFilterProvider);
    final yearRange = ref.watch(yearRangeProvider);
    final mediaType = ref.watch(mediaTypeFilterProvider);
    final awards = ref.watch(awardsFilterProvider);
    final sortMode = ref.watch(sortModeProvider);
    final curatedSource = ref.watch(curatedSourceProvider);
    final includeWatched = ref.watch(includeWatchedProvider);
    final watchedKeys = ref.watch(watchedKeysProvider);
    final uid = ref.watch(authStateProvider).value?.uid;
    final effectiveUid = mode == ViewMode.solo ? uid : null;

    // First-open imdb_id backfill — fires once per session as soon as the
    // household id resolves. Without this the row-level IMDb chip stays
    // blank until the user pulls to refresh, which feels like the feature
    // isn't working at all on fresh installs.
    if (!_imdbBackfillStarted) {
      final hh = ref.watch(householdIdProvider).value;
      if (hh != null) {
        _imdbBackfillStarted = true;
        unawaited(ref
            .read(recommendationsServiceProvider)
            .backfillMissingImdbIds(hh));
      }
    }

    // First-open keyword→genre augmentation — fires once per session to
    // widen `genres` on rec docs via TMDB keywords, so AND-intersection
    // filters (Sci-Fi + War, etc.) pick up cross-genre titles TMDB tags
    // narrowly. `keywords_fetched=true` is sticky, so this only does real
    // work on new/unprocessed docs after the first pass.
    if (!_keywordsBackfillStarted) {
      final hh = ref.watch(householdIdProvider).value;
      if (hh != null) {
        _keywordsBackfillStarted = true;
        unawaited(ref
            .read(recommendationsServiceProvider)
            .backfillMissingAugmentedGenres(hh));
      }
    }

    // Any filter change schedules a debounced auto-refresh so the pool is
    // rebuilt against the current filter state. Without this, narrowing to a
    // combination the current pool doesn't cover would show an empty list
    // until the user manually pulled to refresh. `ref.listen` only fires on
    // actual change, so the initial build (prev = null) is a no-op.
    ref.listen<Set<String>>(selectedGenresProvider, (prev, curr) {
      if (prev != null && !setEquals(prev, curr)) _scheduleAutoRefresh();
    });
    ref.listen<RuntimeBucket?>(runtimeFilterProvider, (prev, curr) {
      if (prev != curr) _scheduleAutoRefresh();
    });
    ref.listen<YearRange>(yearRangeProvider, (prev, curr) {
      if (prev != null && prev != curr) _scheduleAutoRefresh();
    });
    ref.listen<MediaTypeFilter?>(mediaTypeFilterProvider, (prev, curr) {
      if (prev != curr) _scheduleAutoRefresh();
    });
    ref.listen<AwardCategory?>(awardsFilterProvider, (prev, curr) {
      if (prev != curr) _scheduleAutoRefresh();
    });
    ref.listen<SortMode>(sortModeProvider, (prev, curr) {
      if (prev != curr) _scheduleAutoRefresh();
    });
    ref.listen<CuratedSource>(curatedSourceProvider, (prev, curr) {
      if (prev != curr) _scheduleAutoRefresh();
    });

    final recsAsync = ref.watch(recommendationsProvider);
    final recs = recsAsync.value ?? const [];

    // Genre filter — intersection, not union: selecting Western + Sci-Fi
    // must surface only titles tagged as BOTH. Empty-genre recs drop out
    // under an active filter because "classed as all of these" can't be
    // verified on an unclassified title.
    final genreFiltered = selectedGenres.isEmpty
        ? recs
        : recs
            .where((r) => selectedGenres.every(r.genres.contains))
            .toList();

    // Runtime filter — null bucket = show everything. An active bucket is
    // strict: unknown-runtime recs drop out. The service fires a runtime-aware
    // `/discover` pass when a bucket is active, so the pool has candidates
    // TMDB has confirmed in-bounds (discover rows are stamped with a
    // representative runtime). Trending/top-rated rows lack runtime and are
    // intentionally excluded — we can't honestly show them under a specific
    // length filter.
    final runtimeFiltered = runtime == null
        ? genreFiltered
        : genreFiltered.where((r) => runtime.matches(r.runtime)).toList();

    // Year filter — unbounded range = show everything; any active bound
    // drops unknown-year items (same "don't mislead under a specific era"
    // contract the old YearBucket pills had).
    final yearFiltered = !yearRange.hasAnyBound
        ? runtimeFiltered
        : runtimeFiltered.where((r) => yearRange.matches(r.year)).toList();

    // Media-type filter — null = show both movies and TV. When active, strict
    // equality against Recommendation.mediaType.
    final mediaFiltered = mediaType == null
        ? yearFiltered
        : yearFiltered
            .where((r) => r.mediaType == mediaType.recMediaType)
            .toList();

    // Awards filter — strict: only recs with the is_oscar_winner sticky tag
    // survive (the storage field is reused for every award type; see
    // gotcha 25). The specific list spliced into the pool is keyed off
    // `awards`, so toggling between Best Picture / Palme d'Or / BAFTA
    // narrows the visible set to just the matching baked list.
    final awardIds = awards == null
        ? null
        : (kAwardWinners[awards] ?? const <AwardWinner>[])
            .map((w) => 'movie:${w.tmdbId}')
            .toSet();
    final oscarFiltered = awards == null
        ? mediaFiltered
        : mediaFiltered
            .where((r) => r.isOscarWinner && awardIds!.contains(r.id))
            .toList();

    // Curated-source filter — strict: only recs a past discover pass tagged
    // with the matching curator survive. Mirrors the Oscar contract. Stale
    // non-curator recs in the pool would otherwise leak through under a
    // curator filter because the filter scopes TMDB server-side, not the
    // existing Firestore pool.
    final curatorFiltered = curatedSource == CuratedSource.none
        ? oscarFiltered
        : oscarFiltered
            .where((r) => r.curator == curatedSource.name)
            .toList();

    // Search filter — trimmed case-insensitive substring on title.
    final q = _search.trim().toLowerCase();
    final searchFiltered = q.isEmpty
        ? curatorFiltered
        : curatorFiltered
            .where((r) => r.title.toLowerCase().contains(q))
            .toList();

    // Watched filter — default excludes anything the household (Together) or
    // current user (Solo) has already watched. User can flip the toggle in the
    // filter panel to bring them back.
    final filtered = includeWatched
        ? searchFiltered
        : searchFiltered.where((r) => !watchedKeys.contains(r.id)).toList();

    // Animation soft cap — trending TV + top-rated TV are heavily anime-
    // weighted on TMDB and there's no server-side exclude, so the list
    // reads as "mostly anime" for households that aren't anime-first.
    // Cap to `kAnimationSoftCap` rows unless the user opted into
    // Animation via the genre filter (in which case they asked for it).
    final capped = capAnimation(
      filtered,
      userSelectedAnimation: selectedGenres.contains('Animation'),
    );

    final available =
        capped.where((r) => !_dismissed.contains(r.id)).toList();

    final tonightsPick = available.isNotEmpty ? available.first : null;
    final listRecs =
        available.length > 1 ? available.sublist(1) : const <Recommendation>[];

    // Solo mode: build "Because you loved X" chips once per build.
    final explainers = <String, String>{};
    if (effectiveUid != null) {
      final allRatings = ref.watch(ratingsProvider).value ?? const [];
      final myRatings = allRatings.where((r) => r.uid == effectiveUid);
      final entries = ref.watch(watchEntriesProvider).value ?? const [];
      for (final r in available) {
        final cite = pickExplainer(
          rec: r,
          myRatings: myRatings,
          entries: entries,
        );
        if (cite != null) explainers[r.id] = explainerLabel(cite);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const WatchNextLogo(),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 4),
            child: Center(child: ModeToggle()),
          ),
          HelpButton(title: 'Home', body: _homeHelp),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => ConciergeSheet.show(context),
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Ask AI'),
      ),
      body: recsAsync.hasError
          ? AsyncErrorView(
              error: recsAsync.error!,
              onRetry: () => ref.invalidate(recommendationsProvider),
            )
          : RefreshIndicator(
        // Deliberately heavy: standard displacement is 40 — too easy to
        // trip by accident on a scroll overshoot. 140 forces a real pull
        // gesture before the indicator activates. strokeWidth 3.5 makes
        // the spinner visually substantial so the feedback reads clearly.
        displacement: 140,
        strokeWidth: 3.5,
        onRefresh: () async {
          HapticFeedback.mediumImpact();
          final messenger = ScaffoldMessenger.of(context);
          messenger.clearSnackBars();
          messenger.showSnackBar(
            const SnackBar(
              content: Row(children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 12),
                Text('Refreshing recommendations…'),
              ]),
              duration: Duration(seconds: 8),
              behavior: SnackBarBehavior.floating,
            ),
          );
          try {
            // Fire the refresh AND a minimum-visible delay in parallel, so
            // the indicator + snackbar stay up for at least 1.2s even if
            // Phase A returns faster. Prevents a one-frame spinner flash
            // that doesn't register as deliberate feedback.
            await Future.wait([
              ref.read(refreshRecommendationsProvider(true).future),
              Future<void>.delayed(const Duration(milliseconds: 1200)),
            ]);
            messenger.clearSnackBars();
          } catch (e) {
            messenger.clearSnackBars();
            if (context.mounted) {
              messenger.showSnackBar(
                SnackBar(content: Text('Refresh failed: $e')),
              );
            }
          } finally {
            // Force the provider to re-run on next pull rather than returning
            // the cached completed future.
            ref.invalidate(refreshRecommendationsProvider);
          }
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  if (mode == ViewMode.together) ...[
                    Expanded(
                      child: _HomeAction(
                        icon: Icons.groups,
                        label: 'Decide',
                        filled: true,
                        onPressed: () => context.push('/decide'),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: _HomeAction(
                      icon: Icons.casino,
                      label: 'Surprise',
                      onPressed: available.isEmpty
                          ? null
                          : () {
                              final pick = pickSurprise(available);
                              if (pick == null) return;
                              context.push(
                                  '/title/${pick.mediaType}/${pick.tmdbId}');
                            },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _HomeAction(
                      icon: Icons.group_work_outlined,
                      label: 'Like these',
                      onPressed: () => LikeTheseSheet.show(context),
                    ),
                  ),
                ],
              ),
            ),
            _MediaTypeBar(
              selected: mediaType,
              onSelect: (v) =>
                  ref.read(modeMediaTypeProvider.notifier).set(mode, v),
            ),
            _FiltersPanel(
              selectedGenres: selectedGenres,
              runtime: runtime,
              yearRange: yearRange,
              mediaType: mediaType,
              awards: awards,
              sortMode: sortMode,
              curatedSource: curatedSource,
              includeWatched: includeWatched,
              onEditGenres: () => _openGenreSheet(context, ref, mode),
              onClearGenres: () =>
                  ref.read(modeGenreProvider.notifier).clear(mode),
              onRuntimeSelect: (b) =>
                  ref.read(modeRuntimeProvider.notifier).set(mode, b),
              onYearRangeChanged: (r) =>
                  ref.read(modeYearRangeProvider.notifier).set(mode, r),
              onMediaTypeSelect: (v) =>
                  ref.read(modeMediaTypeProvider.notifier).set(mode, v),
              onAwardsSelect: (v) =>
                  ref.read(modeAwardsProvider.notifier).set(mode, v),
              onSortModeSelect: (v) =>
                  ref.read(modeSortProvider.notifier).set(mode, v),
              onCuratedSourceSelect: (v) =>
                  ref.read(modeCuratedSourceProvider.notifier).set(mode, v),
              onIncludeWatchedChanged: (v) =>
                  ref.read(includeWatchedProvider.notifier).set(v),
              onApplyAndClose: () {
                // Skip the 700ms filter-change debounce — user explicitly
                // committed. Non-forcing so we don't regenerate the taste
                // profile (filters reshape the pool, not the preferences).
                _autoRefreshDebounce?.cancel();
                final messenger = ScaffoldMessenger.of(context);
                ref.invalidate(refreshRecommendationsProvider);
                unawaited(
                  ref.read(refreshRecommendationsProvider(false).future).catchError((e) {
                    if (mounted) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Refresh failed: $e')),
                      );
                    }
                  }),
                );
              },
            ),
            _SearchField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _search = v),
            ),
            if (tonightsPick != null) ...[
              const _SectionLabel("TONIGHT'S PICK"),
              _TonightsPick(
                rec: tonightsPick,
                uid: effectiveUid,
                explainer: explainers[tonightsPick.id],
                onWatch: () => context.push(
                    '/title/${tonightsPick.mediaType}/${tonightsPick.tmdbId}'),
                onNotTonight: () =>
                    setState(() => _dismissed.add(tonightsPick.id)),
              ),
            ],
            const _UpcomingForYouRow(),
            const _RewatchRow(),
            if (listRecs.isNotEmpty) ...[
              const _SectionLabel('RECOMMENDED FOR YOU'),
              ...listRecs.map(
                (r) => _RecCard(
                  rec: r,
                  uid: effectiveUid,
                  explainer: explainers[r.id],
                  onTap: () =>
                      context.push('/title/${r.mediaType}/${r.tmdbId}'),
                ),
              ),
            ],
            if (recs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.movie_filter_outlined,
                        size: 56, color: Colors.white24),
                    SizedBox(height: 12),
                    Text(
                      'Pull down to generate recommendations.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              )
            else if (available.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
                child: Column(
                  children: [
                    const Icon(Icons.filter_alt_off_outlined,
                        size: 56, color: Colors.white24),
                    const SizedBox(height: 12),
                    Text(
                      _emptyFilterMessage(selectedGenres),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Copy for the Home "no matches" empty state. Genre filter is AND
/// (intersection), so multi-genre selections can produce rare combos with
/// zero results — call that out specifically so the user doesn't think the
/// app is broken.
String _emptyFilterMessage(Set<String> selectedGenres) {
  if (selectedGenres.length >= 2) {
    final sorted = selectedGenres.toList()..sort();
    return 'No titles match all of ${sorted.join(' + ')}.\n'
        'Try removing one — or pull down to rebuild the pool.';
  }
  return 'No matches for your current filters.\n'
      'Widen genre, year, runtime, or media type — '
      'or pull down to rebuild the pool.';
}

// ─── Home action row ──────────────────────────────────────────────────────────

class _HomeAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  const _HomeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStatePropertyAll(
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
    return filled
        ? FilledButton(style: style, onPressed: onPressed, child: child)
        : OutlinedButton(style: style, onPressed: onPressed, child: child);
  }
}

// ─── Collapsible filters panel ────────────────────────────────────────────────

/// Collapses the three secondary filters (genres, runtime, year range) into
/// a single ExpansionTile so the scored rec list is higher up the fold.
/// Header subtitle summarises what's active so users don't have to expand
/// to check state.
class _FiltersPanel extends StatefulWidget {
  final Set<String> selectedGenres;
  final RuntimeBucket? runtime;
  final YearRange yearRange;
  final MediaTypeFilter? mediaType;
  final AwardCategory? awards;
  final SortMode sortMode;
  final CuratedSource curatedSource;
  final bool includeWatched;
  final VoidCallback onEditGenres;
  final VoidCallback onClearGenres;
  final ValueChanged<RuntimeBucket?> onRuntimeSelect;
  final ValueChanged<YearRange> onYearRangeChanged;
  final ValueChanged<MediaTypeFilter?> onMediaTypeSelect;
  final ValueChanged<AwardCategory?> onAwardsSelect;
  final ValueChanged<SortMode> onSortModeSelect;
  final ValueChanged<CuratedSource> onCuratedSourceSelect;
  final ValueChanged<bool> onIncludeWatchedChanged;
  final VoidCallback onApplyAndClose;

  const _FiltersPanel({
    required this.selectedGenres,
    required this.runtime,
    required this.yearRange,
    required this.mediaType,
    required this.awards,
    required this.sortMode,
    required this.curatedSource,
    required this.includeWatched,
    required this.onEditGenres,
    required this.onClearGenres,
    required this.onRuntimeSelect,
    required this.onYearRangeChanged,
    required this.onMediaTypeSelect,
    required this.onAwardsSelect,
    required this.onSortModeSelect,
    required this.onCuratedSourceSelect,
    required this.onIncludeWatchedChanged,
    required this.onApplyAndClose,
  });

  @override
  State<_FiltersPanel> createState() => _FiltersPanelState();
}

class _FiltersPanelState extends State<_FiltersPanel> {
  bool _isExpanded = false;

  int get _activeCount {
    var n = 0;
    if (widget.selectedGenres.isNotEmpty) n += 1;
    if (widget.runtime != null) n += 1;
    if (widget.yearRange.hasAnyBound) n += 1;
    if (widget.mediaType != null) n += 1;
    if (widget.awards != null) n += 1;
    if (widget.sortMode != SortMode.topRated) n += 1;
    if (widget.curatedSource != CuratedSource.none) n += 1;
    // "Include watched" is counted as an active filter when it diverges from
    // the default (hide watched). Most users want the default, so flipping it
    // on should be visibly flagged.
    if (widget.includeWatched) n += 1;
    return n;
  }

  String _summary() {
    final parts = <String>[];
    if (widget.selectedGenres.isNotEmpty) {
      final list = widget.selectedGenres.toList()..sort();
      parts.add(list.length <= 2
          ? list.join(', ')
          : '${list.length} genres');
    }
    if (widget.mediaType != null) parts.add(widget.mediaType!.label);
    if (widget.runtime != null) parts.add(widget.runtime!.label);
    if (widget.yearRange.hasAnyBound) {
      final lo = widget.yearRange.minYear;
      final hi = widget.yearRange.maxYear;
      if (lo != null && hi != null) {
        parts.add('$lo–$hi');
      } else if (lo != null) {
        parts.add('$lo+');
      } else if (hi != null) {
        parts.add('≤$hi');
      }
    }
    if (widget.sortMode != SortMode.topRated) parts.add(widget.sortMode.label);
    if (widget.curatedSource != CuratedSource.none) {
      parts.add(widget.curatedSource.label);
    }
    if (widget.awards != null) parts.add(widget.awards!.label);
    if (widget.includeWatched) parts.add('+ watched');
    return parts.isEmpty ? 'None' : parts.join(' · ');
  }

  void _toggle() {
    setState(() => _isExpanded = !_isExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeCount;
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Compact single-line header. ~42px tall: 8px vertical padding on each
          // side of a 26px content row.
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: SizedBox(
                height: 26,
                child: Row(
                  children: [
                    Icon(
                      Icons.tune,
                      size: 18,
                      color: active > 0 ? primary : null,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Filters',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    if (active > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$active',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: primary,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _summary(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _isExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.keyboard_arrow_down,
                        size: 20,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeIn,
            sizeCurve: Curves.easeInOut,
            crossFadeState: _isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FilterSectionLabel('Genres'),
                _GenreChipsRow(
                  selected: widget.selectedGenres,
                  onEdit: widget.onEditGenres,
                  onClear: widget.onClearGenres,
                ),
                const _FilterSectionLabel('Length'),
                _RuntimeSegment(
                  selected: widget.runtime,
                  onSelect: widget.onRuntimeSelect,
                ),
                const _FilterSectionLabel('Sort by'),
                _SortModeSegment(
                  selected: widget.sortMode,
                  onSelect: widget.onSortModeSelect,
                ),
                const _FilterSectionLabel('Awards'),
                _AwardsDropdown(
                  selected: widget.awards,
                  onSelect: widget.onAwardsSelect,
                ),
                const _FilterSectionLabel('Curated'),
                _CuratedSourceSegment(
                  selected: widget.curatedSource,
                  onSelect: widget.onCuratedSourceSelect,
                ),
                const _FilterSectionLabel('Year'),
                YearRangeSlider(
                  range: widget.yearRange,
                  onChanged: widget.onYearRangeChanged,
                ),
                const SizedBox(height: 4),
                const Divider(height: 1, indent: 16, endIndent: 16),
                _FilterSwitchRow(
                  icon: Icons.visibility_outlined,
                  label: 'Include watched',
                  value: widget.includeWatched,
                  onChanged: widget.onIncludeWatchedChanged,
                ),
                const SizedBox(height: 12),
                // Primary "apply" affordance — filter changes auto-refresh via
                // the 700ms debounce (gotcha 15), but the explicit CTA commits
                // immediately AND collapses the panel so the rec list isn't
                // buried. Styled to match the Liquid UI family (gotcha 42):
                // accent gradient + glow ring visually mirrors the segmented
                // button blob so it reads as "the primary action in this
                // panel" without the user having to hunt for it.
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: _ApplyFiltersCta(
                    onPressed: () {
                      widget.onApplyAndClose();
                      setState(() => _isExpanded = false);
                    },
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Apply filters CTA ───────────────────────────────────────────────────────

/// Liquid-UI-flavoured primary CTA at the bottom of the expanded filters
/// panel. Uses the same accent gradient + glow as `LiquidSegmentedButton`'s
/// selection blob so the button reads as "the next thing to press" in a way
/// that clearly belongs to the rest of the panel instead of dropping in
/// Material's default filled chrome.
class _ApplyFiltersCta extends StatelessWidget {
  final VoidCallback onPressed;
  const _ApplyFiltersCta({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 50,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                primary.withValues(alpha: 0.95),
                primary.withValues(alpha: 0.72),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: primary.withValues(alpha: 0.38),
                blurRadius: 14,
                offset: const Offset(0, 3),
              ),
              BoxShadow(
                color: primary.withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome,
                    size: 18, color: Theme.of(context).colorScheme.onPrimary),
                const SizedBox(width: 8),
                Text(
                  'Show recommendations',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Genre chips row ──────────────────────────────────────────────────────────

/// Shows selected genres as removable chips plus an "Edit" action that opens
/// the full picker sheet. When nothing is selected, reads as a single "Add
/// genre filter" button so the feature is discoverable.
class _GenreChipsRow extends ConsumerWidget {
  final Set<String> selected;
  final VoidCallback onEdit;
  final VoidCallback onClear;

  const _GenreChipsRow({
    required this.selected,
    required this.onEdit,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (selected.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('Add genre filter'),
            onPressed: onEdit,
          ),
        ),
      );
    }
    // Render as a scrollable row so long selections don't wrap into the list.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            ...selected.map(
              (g) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InputChip(
                  label: Text(g),
                  onDeleted: () {
                    final next = {...selected}..remove(g);
                    final mode = ref.read(viewModeProvider);
                    ref.read(modeGenreProvider.notifier).set(mode, next);
                  },
                ),
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.tune, size: 16),
              label: const Text('Edit'),
              onPressed: onEdit,
            ),
            const SizedBox(width: 6),
            ActionChip(
              avatar: const Icon(Icons.clear, size: 16),
              label: const Text('Clear'),
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Flat filter section helpers ──────────────────────────────────────────────

/// Small muted section label that sits above a segmented/slider/switch group.
/// Replaces the implicit labelling the old FilterChip avatars used to carry.
class _FilterSectionLabel extends StatelessWidget {
  final String label;
  const _FilterSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

Widget _segmentWrapper({required Widget child}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: SizedBox(
        width: double.infinity,
        child: child,
      ),
    );

// ─── Media-type bar (top-level, above filters panel) ──────────────────────────
//
// Media type is the most common first-pass filter ("I want a movie tonight" vs
// "let's pick up a show"), so it sits as a full-width selector under the
// action row instead of behind the Filters ExpansionTile. LiquidSegmentedButton
// carries the haptics + matches the nav bar's selector styling.
class _MediaTypeBar extends StatelessWidget {
  final MediaTypeFilter? selected;
  final void Function(MediaTypeFilter?) onSelect;

  const _MediaTypeBar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: LiquidSegmentedButton<MediaTypeFilter?>(
        density: LiquidSegmentDensity.standard,
        selected: selected,
        segments: const [
          LiquidSegment(value: null, label: 'All'),
          LiquidSegment(
            value: MediaTypeFilter.movie,
            label: 'Movies',
            icon: Icons.movie_outlined,
          ),
          LiquidSegment(
            value: MediaTypeFilter.tv,
            label: 'TV',
            icon: Icons.tv,
          ),
        ],
        onChanged: onSelect,
      ),
    );
  }
}

// ─── Runtime segment ──────────────────────────────────────────────────────────

class _RuntimeSegment extends StatelessWidget {
  final RuntimeBucket? selected;
  final void Function(RuntimeBucket?) onSelect;

  const _RuntimeSegment({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return _segmentWrapper(
      child: LiquidSegmentedButton<RuntimeBucket?>(
        density: LiquidSegmentDensity.compact,
        selected: selected,
        segments: [
          const LiquidSegment(value: null, label: 'Any'),
          for (final b in RuntimeBucket.values)
            LiquidSegment(value: b, label: b.label),
        ],
        onChanged: onSelect,
      ),
    );
  }
}

// ─── Sort mode segment ────────────────────────────────────────────────────────

class _SortModeSegment extends StatelessWidget {
  final SortMode selected;
  final ValueChanged<SortMode> onSelect;

  const _SortModeSegment({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return _segmentWrapper(
      child: LiquidSegmentedButton<SortMode>(
        density: LiquidSegmentDensity.compact,
        selected: selected,
        segments: [
          for (final m in SortMode.values)
            LiquidSegment(value: m, label: m.label),
        ],
        onChanged: onSelect,
      ),
    );
  }
}

// ─── Curated source — dropdown ────────────────────────────────────────────────
//
// Curator grew past what a SegmentedButton can render cleanly (six options
// including None, and labels like "Studio Ghibli" squish below legibility at
// 1/6 width on a 360dp phone). A popup-menu-backed button keeps the flat
// aesthetic of the rest of the panel while scaling to any number of curators.
// The selected value reads directly on the control so the state is obvious at
// a glance — no tap required.

class _CuratedSourceSegment extends StatelessWidget {
  final CuratedSource selected;
  final ValueChanged<CuratedSource> onSelect;

  const _CuratedSourceSegment({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final active = selected != CuratedSource.none;
    return _FilterDropdownShell<CuratedSource>(
      tooltip: 'Pick a curator',
      activeLabel: active ? selected.label : null,
      placeholder: selected.label,
      onSelected: onSelect,
      items: [
        for (final v in CuratedSource.values)
          (value: v, label: v.label, isSelected: v == selected),
      ],
    );
  }
}

// ─── Awards dropdown ──────────────────────────────────────────────────────────
//
// Replaces the original Oscar-only switch with a picker. Supports Best Picture,
// Palme d'Or, and BAFTA Best Film — the underlying baked lists are declared in
// `utils/oscar_winners.dart`. When an award is selected the control accent-
// themes itself so "a filter is active" reads at a glance.

class _AwardsDropdown extends StatelessWidget {
  final AwardCategory? selected;
  final ValueChanged<AwardCategory?> onSelect;

  const _AwardsDropdown({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return _FilterDropdownShell<AwardCategory?>(
      tooltip: 'Pick an award',
      activeLabel: selected?.label,
      placeholder: 'Any',
      onSelected: onSelect,
      items: [
        (value: null, label: 'Any', isSelected: selected == null),
        for (final v in AwardCategory.values)
          (value: v, label: v.label, isSelected: v == selected),
      ],
    );
  }
}

typedef _DropdownItem<T> = ({T value, String label, bool isSelected});

/// Shared dropdown shell for the filter panel's popup-menu-backed controls.
/// When [activeLabel] is non-null the border + label + chevron pick up the
/// accent colour, so Awards and Curator share the "an option is selected"
/// visual without duplicating button chrome.
class _FilterDropdownShell<T> extends StatelessWidget {
  final String tooltip;
  final String? activeLabel;
  final String placeholder;
  final ValueChanged<T> onSelected;
  final List<_DropdownItem<T>> items;

  const _FilterDropdownShell({
    required this.tooltip,
    required this.activeLabel,
    required this.placeholder,
    required this.onSelected,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = activeLabel != null;
    final borderColor = active ? cs.primary : cs.outline;
    final textColor = active ? cs.primary : null;
    return _segmentWrapper(
      child: PopupMenuButton<T>(
        tooltip: tooltip,
        position: PopupMenuPosition.under,
        onSelected: (v) {
          HapticFeedback.selectionClick();
          onSelected(v);
        },
        itemBuilder: (_) => [
          for (final item in items)
            PopupMenuItem<T>(
              value: item.value,
              child: Row(
                children: [
                  if (item.isSelected)
                    const Icon(Icons.check, size: 16)
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  Text(item.label),
                ],
              ),
            ),
        ],
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: active ? 1.5 : 1),
            borderRadius: BorderRadius.circular(8),
            color: active ? cs.primary.withValues(alpha: 0.08) : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  activeLabel ?? placeholder,
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 18, color: textColor),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Boolean filter row (Oscar / No animation / Include watched) ──────────────

/// Compact label-first row with a trailing Switch. Flatter alternative to
/// FilterChips for boolean filters — the label and state are always readable
/// side-by-side instead of hiding the state behind a selected-vs-unselected
/// chip colour.
class _FilterSwitchRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _FilterSwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).iconTheme.color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Search field ─────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search titles…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}

// ─── Tonight's Pick hero card ─────────────────────────────────────────────────

class _TonightsPick extends ConsumerWidget {
  final Recommendation rec;
  final String? uid;
  final String? explainer;
  final VoidCallback onWatch;
  final VoidCallback onNotTonight;

  const _TonightsPick({
    required this.rec,
    this.uid,
    this.explainer,
    required this.onWatch,
    required this.onNotTonight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = TmdbService.imageUrl(rec.posterPath, size: 'w500');
    final score = rec.scoreFor(uid);
    final blurb = rec.blurbFor(uid);

    double? imdbRating;
    double? rtRating;
    double? metascore;
    if (rec.imdbId != null) {
      final async = ref.watch(externalRatingsProvider(rec.imdbId!));
      final ext = async.asData?.value;
      imdbRating = ext?.imdbRating;
      rtRating = ext?.rtRating;
      metascore = ext?.metascore;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Tapping the poster/title area opens title detail. The action
            // buttons below live outside this InkWell so "Not tonight" still
            // dismisses without opening the title.
            InkWell(
              onTap: onWatch,
              child: Stack(
                alignment: Alignment.bottomLeft,
                children: [
                  SizedBox(
                    height: 240,
                    child: poster != null
                        ? Image.network(poster,
                            width: double.infinity, fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: Colors.grey.shade900,
                              child: const Center(
                                child: Icon(Icons.movie,
                                    size: 64, color: Colors.white24),
                              ),
                            ))
                        : Container(
                            color: Colors.grey.shade900,
                            child: const Center(
                              child: Icon(Icons.movie,
                                  size: 64, color: Colors.white24),
                            ),
                          ),
                  ),
                  // Gradient overlay
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.45, 1.0],
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.85),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            rec.title,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _ScoreBadge(score),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (rec.genres.isNotEmpty)
                    Text(
                      rec.genres.take(3).join(' · '),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white54),
                    ),
                  if (imdbRating != null ||
                      rtRating != null ||
                      metascore != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (imdbRating != null) _ImdbChip(imdbRating),
                        if (rtRating != null) _RtChip(rtRating),
                        if (metascore != null) _MetascoreChip(metascore),
                      ],
                    ),
                  ],
                  if (explainer != null) ...[
                    const SizedBox(height: 6),
                    _ExplainerChip(explainer!),
                  ],
                  if (blurb.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      blurb,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Colors.white70),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: onWatch,
                          child: const Text("Let's watch this"),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: onNotTonight,
                        child: const Text('Not tonight'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Recommendation list card ─────────────────────────────────────────────────

class _RecCard extends ConsumerWidget {
  final Recommendation rec;
  final String? uid;
  final String? explainer;
  final VoidCallback onTap;

  const _RecCard({
    required this.rec,
    this.uid,
    this.explainer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = TmdbService.imageUrl(rec.posterPath, size: 'w185');
    final score = rec.scoreFor(uid);
    final blurb = rec.blurbFor(uid);

    // Lazy external ratings — silent when the rec doc hasn't been stamped
    // with an imdb_id yet (the background resolver runs after Phase A) or
    // when OMDb hasn't returned scores for this title.
    double? imdbRating;
    double? rtRating;
    if (rec.imdbId != null) {
      final async = ref.watch(externalRatingsProvider(rec.imdbId!));
      imdbRating = async.asData?.value?.imdbRating;
      rtRating = async.asData?.value?.rtRating;
    }

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: poster != null
            ? Image.network(poster,
                width: 52, height: 78, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 52,
                  height: 78,
                  color: Colors.grey.shade900,
                  child: const Icon(Icons.movie, color: Colors.white24),
                ))
            : Container(
                width: 52,
                height: 78,
                color: Colors.grey.shade900,
                child: const Icon(Icons.movie, color: Colors.white24),
              ),
      ),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(rec.title,
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          if (imdbRating != null) ...[
            _ImdbChip(imdbRating),
            const SizedBox(width: 4),
          ],
          if (rtRating != null) ...[
            _RtChip(rtRating),
            const SizedBox(width: 6),
          ] else if (imdbRating != null)
            const SizedBox(width: 2),
          _ScoreBadge(score),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rec.genres.isNotEmpty)
            Text(
              rec.genres.take(3).join(' · '),
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          if (explainer != null) ...[
            const SizedBox(height: 2),
            _ExplainerChip(explainer!),
          ],
          if (blurb.isNotEmpty)
            Text(
              blurb,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          _SourceBadge(rec.source),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Compact IMDb-rating chip shown on the Home recommendation row.
/// Silent when no IMDb rating is available (see `_RecCard`).
class _ImdbChip extends StatelessWidget {
  final double rating;
  const _ImdbChip(this.rating);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFF5C518).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
            color: const Color(0xFFF5C518).withValues(alpha: 0.6), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'IMDb',
            style: TextStyle(
              fontSize: 9,
              color: Color(0xFFF5C518),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rotten Tomatoes chip — red when "fresh" (≥60%), green-yellow otherwise.
/// OMDb returns the Tomatometer (critic score) as a 0–100 int.
class _RtChip extends StatelessWidget {
  final double rating;
  const _RtChip(this.rating);

  @override
  Widget build(BuildContext context) {
    final fresh = rating >= 60;
    final color = fresh ? const Color(0xFFFA320A) : const Color(0xFF00B04F);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'RT',
            style: TextStyle(
              fontSize: 9,
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            '${rating.toInt()}%',
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Metacritic chip — green ≥61 (favorable), yellow 40–60 (mixed), red ≤39
/// (unfavorable). Matches the Metacritic colour band convention so users
/// read the chip the same way they'd read it on the site.
class _MetascoreChip extends StatelessWidget {
  final double score;
  const _MetascoreChip(this.score);

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (score >= 61) {
      color = const Color(0xFF66CC33);
    } else if (score >= 40) {
      color = const Color(0xFFFFCC33);
    } else {
      color = const Color(0xFFFF0000);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'MC',
            style: TextStyle(
              fontSize: 9,
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            score.toInt().toString(),
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small badge shown in solo mode citing a highly-rated title the user has
/// watched that shares genres with this rec. Quiet palette — shouldn't
/// outshout the AI blurb.
class _ExplainerChip extends StatelessWidget {
  final String label;
  const _ExplainerChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite, size: 12, color: Colors.pinkAccent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.pinkAccent,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _ScoreBadge extends StatelessWidget {
  final int score;
  const _ScoreBadge(this.score);

  Color get _color {
    if (score >= 80) return Colors.greenAccent;
    if (score >= 60) return Colors.amber;
    return Colors.white38;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _color, width: 0.5),
      ),
      child: Text(
        '$score%',
        style: TextStyle(
            fontSize: 12, color: _color, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String source;
  const _SourceBadge(this.source);

  String get _label {
    switch (source) {
      case 'watchlist':
        return 'On Your List';
      case 'trending':
        return 'Trending';
      case 'top_rated':
        return 'Top Rated';
      case 'reddit':
        return 'Reddit Hype';
      case 'similar':
        return 'Similar';
      default:
        return 'AI Pick';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(_label,
          style: const TextStyle(fontSize: 11, color: Colors.white38)),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
            letterSpacing: 1.2, fontSize: 12, color: Colors.white54),
      ),
    );
  }
}

// ─── Upcoming for you carousel ──────────────────────────────────────────────

/// Horizontal poster row sourced from `upcomingForYouProvider`. Silent when
/// the provider is loading or has nothing to show — the Home screen is busy
/// enough already that "Upcoming for you — nothing found" would just be noise.
class _UpcomingForYouRow extends ConsumerWidget {
  const _UpcomingForYouRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(upcomingForYouProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel('UPCOMING FOR YOU'),
            SizedBox(
              height: 230,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final t = items[i];
                  return _UpcomingCard(
                    item: t,
                    onTap: () =>
                        context.push('/title/${t.mediaType}/${t.tmdbId}'),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _UpcomingCard extends StatelessWidget {
  final UpcomingTitle item;
  final VoidCallback onTap;

  const _UpcomingCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(item.posterPath, size: 'w342');
    return SizedBox(
      width: 120,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: poster != null
                    ? Image.network(
                        poster,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: Color(0xFF1A1A1A)),
                      )
                    : const ColoredBox(color: Color(0xFF1A1A1A)),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Text(
              _dateLabel(item.releaseDate),
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  static String _dateLabel(DateTime? d) {
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

// ─── Rewatch carousel ─────────────────────────────────────────────────────────

/// Horizontal poster row sourced from `rewatchForYouProvider`. Past favorites
/// the household hasn't touched in a year+. Silent when empty so the Home
/// surface doesn't sprout an apologetic "nothing to rewatch" row on fresh
/// accounts.
class _RewatchRow extends ConsumerWidget {
  const _RewatchRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(rewatchForYouProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('REWATCH?'),
        SizedBox(
          height: 230,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final t = items[i];
              return _RewatchCard(
                item: t,
                onTap: () =>
                    context.push('/title/${t.mediaType}/${t.tmdbId}'),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RewatchCard extends StatelessWidget {
  final RewatchTitle item;
  final VoidCallback onTap;

  const _RewatchCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(item.posterPath, size: 'w342');
    return SizedBox(
      width: 120,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: poster != null
                    ? Image.network(
                        poster,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: Color(0xFF1A1A1A)),
                      )
                    : const ColoredBox(color: Color(0xFF1A1A1A)),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            Row(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    item.stars.clamp(0, 5),
                    (_) => const Icon(Icons.star,
                        size: 11, color: Colors.amber),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _agoLabel(item.lastWatchedAt),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white54),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _agoLabel(DateTime? d) {
    if (d == null) return '';
    final days = DateTime.now().difference(d).inDays;
    if (days < 730) return '${(days / 30).round()}mo ago';
    return '${(days / 365).round()}y ago';
  }
}
