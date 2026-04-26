import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/episode.dart';
import '../../models/watch_entry.dart';
import '../../models/watchlist_item.dart';
import '../../providers/auth_provider.dart';
import '../../providers/genre_filter_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/library_filter_provider.dart';
import '../../providers/media_type_filter_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/async_error.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/help_button.dart';
import '../../widgets/liquid_segmented_button.dart';
import '../../widgets/mode_toggle.dart';
import '../rating/rating_sheet.dart';

const _libraryHelp =
    'Everything the household has saved or watched, in four tabs.\n\n'
    '• Saved — shared watchlist (Together) or shared + your solo saves (Solo). '
    'Swipe left to remove. Tap to open the title.\n'
    '• Watching — TV in progress (from Trakt activity or "Watching" set on a title).\n'
    '• Watched — finished titles and movies, with the average household rating when rated.\n'
    '• Unrated — titles and episodes waiting on a star rating. Tap the star to rate.\n\n'
    'Link Trakt in Profile to auto-populate Watching, Watched, and Unrated.';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Library'),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 4),
              child: Center(child: ModeToggle()),
            ),
            HelpButton(title: 'Library', body: _libraryHelp),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Saved'),
              Tab(text: 'Watching'),
              Tab(text: 'Watched'),
              Tab(text: 'Unrated'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _SavedTab(),
            _WatchingTab(),
            _WatchedTab(),
            _UnratedTab(),
          ],
        ),
      ),
    );
  }
}

// ─── Saved (watchlist, unwatched) ─────────────────────────────────────────────

class _SavedTab extends ConsumerWidget {
  const _SavedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchlistProvider);
    final items = ref.watch(visibleWatchlistProvider);
    final entries =
        ref.watch(watchEntriesProvider).value ?? const <WatchEntry>[];
    final mode = ref.watch(viewModeProvider);
    final uid = ref.watch(authStateProvider).value?.uid;

    final mediaType = ref.watch(libraryMediaTypeProvider);
    final sort = ref.watch(librarySortProvider);
    final genres = ref.watch(libraryGenresProvider);
    final query = ref.watch(librarySearchProvider).trim().toLowerCase();

    bool isWatched(WatchlistItem w) {
      final entryId = WatchEntry.buildId(w.mediaType, w.tmdbId);
      final entry = entries.cast<WatchEntry?>().firstWhere(
            (e) => e?.id == entryId,
            orElse: () => null,
          );
      if (entry == null) return false;
      if (mode == ViewMode.solo) {
        return uid != null && (entry.watchedBy[uid] ?? false);
      }
      return entry.watchedBy.values.any((v) => v);
    }

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AsyncErrorView(
        error: e,
        onRetry: () => ref.invalidate(watchlistProvider),
      ),
      data: (_) {
        final unwatched = items.where((w) => !isWatched(w)).toList();
        if (unwatched.isEmpty) {
          return const EmptyState(
            icon: Icons.bookmark_border,
            title: 'Nothing saved yet',
            subtitle:
                'Add titles from their detail screen — tap "Add to watchlist" to save them here for both of you.',
          );
        }

        final filtered = applyLibraryFilters(
          items: unwatched,
          mediaType: mediaType,
          genres: genres,
          query: query,
          sort: sort,
        );
        final hasActiveFilters =
            mediaType != null || genres.isNotEmpty || query.isNotEmpty;

        return Column(
          children: [
            const _SavedFilterBar(),
            if (filtered.isEmpty)
              Expanded(
                child: hasActiveFilters
                    ? _NoMatchesEmpty(onClear: () => _clearAllFilters(ref))
                    : const EmptyState(
                        icon: Icons.bookmark_border,
                        title: 'Nothing saved yet',
                        subtitle: 'Add titles from their detail screen.',
                      ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const Divider(height: 0),
                  itemBuilder: (_, i) => _SavedTile(item: filtered[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

void _clearAllFilters(WidgetRef ref) {
  ref.read(libraryMediaTypeProvider.notifier).state = null;
  ref.read(libraryGenresProvider.notifier).state = const {};
  ref.read(librarySearchProvider.notifier).state = '';
}

// ─── Saved tab — filter bar ───────────────────────────────────────────────────
//
// Three rows: search field, media-type segment, then a genre + sort dropdown
// pair. Mirrors Home's filter-panel rhythm (LiquidSegmentedButton +
// dropdown shells) so the visual language stays consistent across the app.

class _SavedFilterBar extends ConsumerWidget {
  const _SavedFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaType = ref.watch(libraryMediaTypeProvider);
    final sort = ref.watch(librarySortProvider);
    final genres = ref.watch(libraryGenresProvider);
    final cs = Theme.of(context).colorScheme;

    final genreLabel = genres.isEmpty
        ? null
        : (genres.length == 1 ? genres.first : 'Genres (${genres.length})');

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _SavedSearchField(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: LiquidSegmentedButton<MediaTypeFilter?>(
              density: LiquidSegmentDensity.compact,
              selected: mediaType,
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
              onChanged: (v) =>
                  ref.read(libraryMediaTypeProvider.notifier).state = v,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: _SavedDropdownTrigger(
                    icon: Icons.theater_comedy_outlined,
                    activeLabel: genreLabel,
                    placeholder: 'Genres',
                    onTap: () => _openGenreSheet(context),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SavedSortPopup(
                    selected: sort,
                    onSelected: (v) =>
                        ref.read(librarySortProvider.notifier).state = v,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openGenreSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _LibraryGenreSheet(),
    );
  }
}

class _SavedSearchField extends ConsumerStatefulWidget {
  const _SavedSearchField();

  @override
  ConsumerState<_SavedSearchField> createState() => _SavedSearchFieldState();
}

class _SavedSearchFieldState extends ConsumerState<_SavedSearchField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(librarySearchProvider));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Sync the controller when the provider is reset externally (e.g.,
    // "Clear filters" from the no-matches empty state). The TextField doesn't
    // re-read provider state on rebuild, so without this an external clear
    // would update the filter but leave stale text in the field.
    ref.listen<String>(librarySearchProvider, (_, next) {
      if (next != _ctrl.text) {
        _ctrl.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });
    return TextField(
      controller: _ctrl,
      onChanged: (v) => ref.read(librarySearchProvider.notifier).state = v,
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Search saved titles',
        hintStyle: TextStyle(
          fontSize: 14,
          color: cs.onSurface.withValues(alpha: 0.5),
        ),
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _ctrl,
          builder: (_, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Clear search',
              onPressed: () {
                _ctrl.clear();
                ref.read(librarySearchProvider.notifier).state = '';
              },
            );
          },
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        filled: true,
        fillColor: cs.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.primary, width: 1.2),
        ),
      ),
    );
  }
}

/// Visual sibling of Home's `_FilterDropdownShell`. Stays in this file so
/// Library can give it Saved-tab-specific behaviours (icon prefix, custom
/// onTap) without parameterising the Home shell. Active state borrows the
/// same primary-tinted styling as Home's dropdowns.
class _SavedDropdownTrigger extends StatelessWidget {
  final IconData icon;
  final String? activeLabel;
  final String placeholder;
  final VoidCallback onTap;

  const _SavedDropdownTrigger({
    required this.icon,
    required this.activeLabel,
    required this.placeholder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = activeLabel != null;
    final borderColor = active ? cs.primary : cs.outline;
    final textColor = active ? cs.primary : cs.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
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
            Icon(icon, size: 16, color: textColor),
            const SizedBox(width: 8),
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
    );
  }
}

class _SavedSortPopup extends StatelessWidget {
  final LibrarySort selected;
  final ValueChanged<LibrarySort> onSelected;

  const _SavedSortPopup({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDefault = selected == LibrarySort.dateAddedDesc;
    final borderColor = isDefault ? cs.outline : cs.primary;
    final textColor = isDefault ? cs.onSurfaceVariant : cs.primary;
    return PopupMenuButton<LibrarySort>(
      tooltip: 'Sort',
      position: PopupMenuPosition.under,
      onSelected: (v) {
        HapticFeedback.selectionClick();
        onSelected(v);
      },
      itemBuilder: (_) => [
        for (final mode in LibrarySort.values)
          PopupMenuItem<LibrarySort>(
            value: mode,
            child: Row(
              children: [
                if (mode == selected)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(mode.label),
              ],
            ),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: borderColor, width: isDefault ? 1 : 1.5),
          borderRadius: BorderRadius.circular(8),
          color: isDefault ? null : cs.primary.withValues(alpha: 0.08),
        ),
        child: Row(
          children: [
            Icon(Icons.sort, size: 16, color: textColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                selected.label,
                style: TextStyle(
                  fontSize: 12,
                  color: textColor,
                  fontWeight: isDefault ? FontWeight.normal : FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: textColor),
          ],
        ),
      ),
    );
  }
}

/// Library-local genre picker. Mirrors `GenreSheet` but binds to
/// `libraryGenresProvider` so toggling here doesn't bleed into Home's
/// `modeGenreProvider` (which would silently change the recommendation pool).
class _LibraryGenreSheet extends ConsumerWidget {
  const _LibraryGenreSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(allGenresProvider);
    final selected = ref.watch(libraryGenresProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Filter by genre',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => ref
                          .read(libraryGenresProvider.notifier)
                          .state = const {},
                  child: const Text('Clear all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in all)
                      FilterChip(
                        label: Text(g),
                        selected: selected.contains(g),
                        onSelected: (v) {
                          final next = Set<String>.from(selected);
                          if (v) {
                            next.add(g);
                          } else {
                            next.remove(g);
                          }
                          ref.read(libraryGenresProvider.notifier).state =
                              next;
                        },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedTile extends ConsumerWidget {
  final WatchlistItem item;
  const _SavedTile({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = item;
    final poster = TmdbService.imageUrl(w.posterPath, size: 'w185');
    return Dismissible(
      key: ValueKey(w.id),
      background: Container(
        color: Colors.redAccent,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete),
      ),
      direction: DismissDirection.endToStart,
      onDismissed: (_) async {
        final householdId = await ref.read(householdIdProvider.future);
        if (householdId == null) return;
        await ref
            .read(watchlistServiceProvider)
            .remove(householdId: householdId, id: w.id);
      },
      child: ListTile(
        leading: poster != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  poster,
                  width: 48,
                  height: 72,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 48,
                    height: 72,
                    child: Icon(Icons.movie),
                  ),
                ),
              )
            : const SizedBox(
                width: 48, height: 72, child: Icon(Icons.movie)),
        title: Text(w.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          if (w.year != null) '${w.year}',
          if (w.genres.isNotEmpty) w.genres.first,
        ].join(' · ')),
        trailing: w.scope == 'solo'
            ? const Tooltip(
                message: 'Only on your Solo watchlist',
                child: Icon(Icons.person_outline, size: 18),
              )
            : null,
        onTap: () => context.push('/title/${w.mediaType}/${w.tmdbId}'),
      ),
    );
  }
}

class _NoMatchesEmpty extends StatelessWidget {
  final VoidCallback onClear;
  const _NoMatchesEmpty({required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_alt_off_outlined,
                size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            Text(
              'No saved titles match',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Try clearing a filter or your search.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white60,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Clear filters'),
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Watching (in-progress TV) ────────────────────────────────────────────────

class _WatchingTab extends ConsumerWidget {
  const _WatchingTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchEntriesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AsyncErrorView(
        error: e,
        onRetry: () => ref.invalidate(watchEntriesProvider),
      ),
      data: (entries) {
        final wip = entries
            .where((e) => e.inProgressStatus == 'watching')
            .toList();
        if (wip.isEmpty) {
          return const EmptyState(
            icon: Icons.play_circle_outline,
            title: 'Nothing in progress',
            subtitle:
                'Start a show and Trakt will put it here — or mark a TV title "Watching" from its detail screen.',
          );
        }
        return ListView.separated(
          itemCount: wip.length,
          separatorBuilder: (_, _) => const Divider(height: 0),
          itemBuilder: (_, i) => _EntryTile(entry: wip[i], showProgress: true),
        );
      },
    );
  }
}

// ─── Watched (finished titles) ────────────────────────────────────────────────

class _WatchedTab extends ConsumerWidget {
  const _WatchedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchEntriesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AsyncErrorView(
        error: e,
        onRetry: () => ref.invalidate(watchEntriesProvider),
      ),
      data: (entries) {
        final watched = entries
            .where((e) => e.inProgressStatus != 'watching')
            .toList();
        if (watched.isEmpty) {
          return const EmptyState(
            icon: Icons.history_toggle_off,
            title: 'No watch history yet',
            subtitle:
                'Link Trakt from Profile to import what you\'ve watched, or start rating titles.',
          );
        }
        return ListView.separated(
          itemCount: watched.length,
          separatorBuilder: (_, _) => const Divider(height: 0),
          itemBuilder: (_, i) => _EntryTile(entry: watched[i]),
        );
      },
    );
  }
}

// ─── Unrated (queue) ──────────────────────────────────────────────────────────

class _UnratedTab extends ConsumerWidget {
  const _UnratedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showAsync = ref.watch(unratedQueueProvider);
    final epAsync = ref.watch(unratedEpisodesProvider);
    final householdId = ref.watch(householdIdProvider).value ?? '';

    final shows = showAsync.value ?? const [];
    final epsByEntry = epAsync.value ?? const {};
    final loading = showAsync.isLoading || epAsync.isLoading;

    if (loading) return const Center(child: CircularProgressIndicator());

    if (shows.isEmpty && epsByEntry.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Caught up!',
        subtitle: 'Nothing waiting to be rated.',
      );
    }

    return CustomScrollView(
      slivers: [
        if (shows.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionDivider('MOVIES & SHOWS')),
          SliverList.separated(
            itemCount: shows.length,
            separatorBuilder: (_, _) => const Divider(height: 0),
            itemBuilder: (_, i) {
              final e = shows[i];
              final poster = TmdbService.imageUrl(e.posterPath, size: 'w185');
              return ListTile(
                leading: poster != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(
                          poster,
                          width: 48,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 48, height: 72, child: Icon(Icons.movie),
                          ),
                        ),
                      )
                    : const SizedBox(
                        width: 48, height: 72, child: Icon(Icons.movie)),
                title: Text(e.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  if (e.year != null) '${e.year}',
                  e.mediaType == 'tv' ? 'TV' : 'Movie',
                ].join(' · ')),
                trailing: IconButton(
                  icon: const Icon(Icons.star_outline),
                  onPressed: () => RatingSheet.show(
                    context,
                    level: e.mediaType == 'tv' ? 'show' : 'movie',
                    targetId: e.id,
                    title: e.title,
                    posterPath: e.posterPath,
                    traktId: e.traktId,
                  ),
                ),
                onTap: () =>
                    context.push('/title/${e.mediaType}/${e.tmdbId}'),
              );
            },
          ),
        ],
        if (epsByEntry.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionDivider('EPISODES')),
          SliverList.list(
            children: epsByEntry.entries.map((mapEntry) {
              return _EpisodeGroup(
                householdId: householdId,
                entryId: mapEntry.key,
                episodes: mapEntry.value,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}

// ─── Shared tiles / helpers ───────────────────────────────────────────────────

class _SectionDivider extends StatelessWidget {
  final String label;
  const _SectionDivider(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.2,
            color: Colors.white38,
          ),
        ),
      );
}

class _EntryTile extends ConsumerWidget {
  final WatchEntry entry;
  final bool showProgress;
  const _EntryTile({required this.entry, this.showProgress = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = TmdbService.imageUrl(entry.posterPath, size: 'w185');
    final byTarget = ref.watch(ratingsByTargetProvider);
    final ratings = (byTarget[entry.id] ?? const []).where((r) {
      return r.level == (entry.mediaType == 'tv' ? 'show' : 'movie');
    }).toList();
    final stars = ratings.isEmpty
        ? null
        : ratings.map((r) => r.stars).reduce((a, b) => a + b) / ratings.length;
    final progress = showProgress &&
            entry.lastSeason != null &&
            entry.lastEpisode != null
        ? 'S${entry.lastSeason!.toString().padLeft(2, '0')}E${entry.lastEpisode!.toString().padLeft(2, '0')}'
        : null;

    return ListTile(
      leading: poster != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                poster,
                width: 48,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  width: 48, height: 72, child: Icon(Icons.movie),
                ),
              ),
            )
          : const SizedBox(width: 48, height: 72, child: Icon(Icons.movie)),
      title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (entry.year != null) '${entry.year}',
        entry.mediaType == 'tv' ? 'TV' : 'Movie',
        ?progress,
        if (!showProgress && entry.lastWatchedAt != null)
          DateFormat.yMMMd().format(entry.lastWatchedAt!.toLocal()),
      ].join(' · ')),
      trailing: showProgress
          ? const Icon(Icons.play_circle_outline,
              size: 18, color: Colors.white54)
          : (stars == null
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.star, size: 16, color: Colors.amber),
                  const SizedBox(width: 2),
                  Text(stars.toStringAsFixed(1)),
                ])),
      onTap: () => context.push('/title/${entry.mediaType}/${entry.tmdbId}'),
    );
  }
}

class _EpisodeGroup extends ConsumerWidget {
  final String householdId;
  final String entryId;
  final List<Episode> episodes;

  const _EpisodeGroup({
    required this.householdId,
    required this.entryId,
    required this.episodes,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchEntries = ref.watch(watchEntriesProvider).value ?? const [];
    final entry = watchEntries.cast<WatchEntry?>().firstWhere(
          (e) => e?.id == entryId,
          orElse: () => null,
        );
    final showTitle = entry?.title ?? entryId;
    final poster = TmdbService.imageUrl(entry?.posterPath, size: 'w185');

    return ExpansionTile(
      leading: poster != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                poster,
                width: 40,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(
                  width: 40, height: 60, child: Icon(Icons.tv),
                ),
              ),
            )
          : const SizedBox(width: 40, height: 60, child: Icon(Icons.tv)),
      title: Text(showTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${episodes.length} unrated episode${episodes.length == 1 ? '' : 's'}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
          child: const Text('Rate All'),
          onPressed: () => _rateAll(context, showTitle, entry),
        ),
        const Icon(Icons.chevron_right),
      ]),
      children: episodes.map<Widget>((ep) {
        final label =
            'S${ep.season.toString().padLeft(2, '0')}E${ep.number.toString().padLeft(2, '0')}';
        final epTitle = ep.title != null ? ' — ${ep.title}' : '';
        return ListTile(
          contentPadding: const EdgeInsets.fromLTRB(32, 0, 16, 0),
          title: Text('$label$epTitle',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.star_outline),
            onPressed: () => RatingSheet.show(
              context,
              level: 'episode',
              targetId: '$entryId:${ep.id}',
              title: '$showTitle $label',
              posterPath: entry?.posterPath,
              season: ep.season,
              episode: ep.number,
            ),
          ),
        );
      }).toList(),
    );
  }

  void _rateAll(BuildContext context, String showTitle, WatchEntry? entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RateAllSheet(
        showTitle: showTitle,
        entryId: entryId,
        episodes: episodes,
        posterPath: entry?.posterPath,
      ),
    );
  }
}

class _RateAllSheet extends ConsumerStatefulWidget {
  final String showTitle;
  final String entryId;
  final List<Episode> episodes;
  final String? posterPath;

  const _RateAllSheet({
    required this.showTitle,
    required this.entryId,
    required this.episodes,
    this.posterPath,
  });

  @override
  ConsumerState<_RateAllSheet> createState() => _RateAllSheetState();
}

class _RateAllSheetState extends ConsumerState<_RateAllSheet> {
  late final Map<String, int> _stars = {};
  bool _saving = false;

  Future<void> _saveAll() async {
    final toSave = _stars.entries.where((e) => e.value > 0).toList();
    if (toSave.isEmpty) return;
    setState(() => _saving = true);
    try {
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) return;
      final svc = ref.read(ratingServiceProvider);
      final currentUid = ref.read(authStateProvider).value?.uid;
      if (currentUid == null) return;
      await Future.wait(toSave.map((e) {
        final ep = widget.episodes.firstWhere((ep) => ep.id == e.key);
        return svc.save(
          householdId: householdId,
          uid: currentUid,
          level: 'episode',
          targetId: '${widget.entryId}:${e.key}',
          stars: e.value,
          season: ep.season,
          episode: ep.number,
        );
      }));
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.showTitle,
              style: Theme.of(context).textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(
            'Rate ${widget.episodes.length} episode${widget.episodes.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.episodes.length,
              itemBuilder: (_, i) {
                final ep = widget.episodes[i];
                final label =
                    'S${ep.season.toString().padLeft(2, '0')}E${ep.number.toString().padLeft(2, '0')}';
                final epTitle = ep.title != null ? ' ${ep.title}' : '';
                final current = _stars[ep.id] ?? 0;
                return Row(children: [
                  Expanded(
                    child: Text('$label$epTitle',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(5, (j) {
                      final star = j + 1;
                      return InkWell(
                        onTap: () =>
                            setState(() => _stars[ep.id] = star),
                        child: Icon(
                          star <= current ? Icons.star : Icons.star_border,
                          size: 22,
                          color: star <= current ? Colors.amber : null,
                        ),
                      );
                    }),
                  ),
                ]);
              },
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _saveAll,
              child: _saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save ratings'),
            ),
          ),
        ],
      ),
    );
  }
}
