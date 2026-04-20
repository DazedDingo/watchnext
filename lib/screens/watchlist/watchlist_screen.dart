import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/watch_entry.dart';
import '../../models/watchlist_item.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/help_button.dart';
import '../../widgets/mode_toggle.dart';

const _watchlistHelp =
    'A shared queue of titles both members have saved.\n\n'
    '• Add — from a title\'s detail screen, tap "Add to watchlist". Pick '
    'Shared (both members), Solo (only you), or both.\n'
    '• Solo / Together toggle — top-right. Together shows only shared items; '
    'Solo shows shared + your own solo-saved items (your partner\'s solo list '
    'is never visible to you).\n'
    '• Filter — Unwatched (default) hides titles you\'ve already seen; '
    'Watching shows TV in progress (sourced from History, not the saved list); '
    'Watched shows finished titles; All shows everything on the list. In '
    'Together mode a title counts as watched when either member has watched it.\n'
    '• Remove — swipe left on any row (Watching rows aren\'t swipe-removable; '
    'update progress from the title\'s detail screen instead).\n'
    '• Tap a row to open the title and rate, predict, or start watching.\n\n'
    'The recommender uses your watchlist as its primary candidate pool.';

enum _WatchedFilter { unwatched, watching, watched, all }

class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({super.key});

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  _WatchedFilter _filter = _WatchedFilter.unwatched;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(watchlistProvider);
    final items = ref.watch(visibleWatchlistProvider);
    final entries = ref.watch(watchEntriesProvider).value ?? const <WatchEntry>[];
    final mode = ref.watch(viewModeProvider);
    final uid = ref.watch(authStateProvider).value?.uid;

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

    // Watching pulls from History directly — a show can be in progress
    // without ever being on the saved watchlist.
    final watchingEntries = entries
        .where((e) => e.inProgressStatus == 'watching')
        .toList();

    final filtered = items.where((w) {
      switch (_filter) {
        case _WatchedFilter.unwatched: return !isWatched(w);
        case _WatchedFilter.watched:   return isWatched(w);
        case _WatchedFilter.all:       return true;
        case _WatchedFilter.watching:  return false;
      }
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchlist'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 4),
            child: Center(child: ModeToggle()),
          ),
          HelpButton(title: 'Watchlist', body: _watchlistHelp),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (_) {
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SegmentedButton<_WatchedFilter>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                      value: _WatchedFilter.unwatched,
                      label: Text('Unwatched'),
                      icon: Icon(Icons.visibility_off_outlined)),
                  ButtonSegment(
                      value: _WatchedFilter.watching,
                      label: Text('Watching'),
                      icon: Icon(Icons.play_circle_outline)),
                  ButtonSegment(
                      value: _WatchedFilter.watched,
                      label: Text('Watched'),
                      icon: Icon(Icons.check_circle_outline)),
                  ButtonSegment(
                      value: _WatchedFilter.all,
                      label: Text('All'),
                      icon: Icon(Icons.list_alt)),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
              ),
            ),
            Expanded(
              child: _filter == _WatchedFilter.watching
                  ? _buildWatchingList(watchingEntries)
                  : _buildList(filtered),
            ),
          ]);
        },
      ),
    );
  }

  Widget _buildList(List<WatchlistItem> items) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            switch (_filter) {
              _WatchedFilter.unwatched =>
                'No unwatched titles. Try the Watched or All filter.',
              _WatchedFilter.watched =>
                'Nothing here has been marked watched yet.',
              _WatchedFilter.all =>
                'Nothing saved yet. Add titles from their detail screen.',
              _WatchedFilter.watching =>
                '', // unreachable — _buildWatchingList owns this state
            },
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 0),
      itemBuilder: (_, i) {
        final w = items[i];
        final poster = TmdbService.imageUrl(w.posterPath, size: 'w185');
        return Dismissible(
          key: ValueKey(w.id),
          background: Container(
              color: Colors.redAccent,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              child: const Icon(Icons.delete)),
          direction: DismissDirection.endToStart,
          onDismissed: (_) async {
            final householdId = await ref.read(householdIdProvider.future);
            if (householdId == null) return;
            await ref.read(watchlistServiceProvider).remove(householdId: householdId, id: w.id);
          },
          child: ListTile(
            leading: poster != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(poster, width: 48, height: 72, fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 72, child: Icon(Icons.movie))),
                  )
                : const SizedBox(width: 48, height: 72, child: Icon(Icons.movie)),
            title: Text(w.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([if (w.year != null) '${w.year}', if (w.genres.isNotEmpty) w.genres.first].join(' · ')),
            trailing: w.scope == 'solo'
                ? const Tooltip(
                    message: 'Only on your Solo watchlist',
                    child: Icon(Icons.person_outline, size: 18),
                  )
                : null,
            onTap: () => context.push('/title/${w.mediaType}/${w.tmdbId}'),
          ),
        );
      },
    );
  }

  Widget _buildWatchingList(List<WatchEntry> entries) {
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No shows in progress. Shows appear here once Trakt reports activity or you mark them "Watching" from their detail screen.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 0),
      itemBuilder: (_, i) {
        final e = entries[i];
        final poster = TmdbService.imageUrl(e.posterPath, size: 'w185');
        final progress = (e.lastSeason != null && e.lastEpisode != null)
            ? 'S${e.lastSeason!.toString().padLeft(2, '0')}E${e.lastEpisode!.toString().padLeft(2, '0')}'
            : null;
        return ListTile(
          leading: poster != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(poster, width: 48, height: 72, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 72, child: Icon(Icons.movie))),
                )
              : const SizedBox(width: 48, height: 72, child: Icon(Icons.movie)),
          title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text([
            if (e.year != null) '${e.year}',
            ?progress,
            if (e.genres.isNotEmpty) e.genres.first,
          ].join(' · ')),
          trailing: const Icon(Icons.play_circle_outline,
              size: 18, color: Colors.white54),
          onTap: () => context.push('/title/${e.mediaType}/${e.tmdbId}'),
        );
      },
    );
  }
}
