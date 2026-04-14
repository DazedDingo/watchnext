import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/watch_entry.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../services/tmdb_service.dart';
import '../rating/rating_sheet.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('History'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Watched'),
            Tab(text: 'In progress'),
            Tab(text: 'Unrated'),
          ]),
        ),
        body: const TabBarView(
          children: [_WatchedTab(), _InProgressTab(), _UnratedTab()],
        ),
      ),
    );
  }
}

class _WatchedTab extends ConsumerWidget {
  const _WatchedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchEntriesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        final watched = entries.where((e) => e.inProgressStatus != 'watching').toList();
        if (watched.isEmpty) return const _Empty(text: 'No watched titles yet — link Trakt to import.');
        return ListView.separated(
          itemCount: watched.length,
          separatorBuilder: (_, __) => const Divider(height: 0),
          itemBuilder: (_, i) => _EntryTile(entry: watched[i]),
        );
      },
    );
  }
}

class _InProgressTab extends ConsumerWidget {
  const _InProgressTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchEntriesProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        final wip = entries.where((e) => e.inProgressStatus == 'watching').toList();
        if (wip.isEmpty) return const _Empty(text: 'Nothing in progress. Start a show and Trakt will put it here.');
        return ListView.separated(
          itemCount: wip.length,
          separatorBuilder: (_, __) => const Divider(height: 0),
          itemBuilder: (_, i) => _EntryTile(entry: wip[i]),
        );
      },
    );
  }
}

class _UnratedTab extends ConsumerWidget {
  const _UnratedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(unratedQueueProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        if (entries.isEmpty) return const _Empty(text: 'Caught up! Nothing unrated.');
        return ListView.separated(
          itemCount: entries.length,
          separatorBuilder: (_, __) => const Divider(height: 0),
          itemBuilder: (_, i) {
            final e = entries[i];
            final poster = TmdbService.imageUrl(e.posterPath, size: 'w185');
            return ListTile(
              leading: poster != null
                  ? ClipRRect(borderRadius: BorderRadius.circular(4),
                      child: Image.network(poster, width: 48, height: 72, fit: BoxFit.cover))
                  : const SizedBox(width: 48, height: 72, child: Icon(Icons.movie)),
              title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([if (e.year != null) '${e.year}', e.mediaType == 'tv' ? 'TV' : 'Movie'].join(' · ')),
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
              onTap: () => context.push('/title/${e.mediaType}/${e.tmdbId}'),
            );
          },
        );
      },
    );
  }
}

class _EntryTile extends ConsumerWidget {
  final WatchEntry entry;
  const _EntryTile({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poster = TmdbService.imageUrl(entry.posterPath, size: 'w185');
    final byTarget = ref.watch(ratingsByTargetProvider);
    final ratings = (byTarget[entry.id] ?? const []).where((r) {
      return r.level == (entry.mediaType == 'tv' ? 'show' : 'movie');
    }).toList();
    final stars = ratings.isEmpty ? null : ratings.map((r) => r.stars).reduce((a, b) => a + b) / ratings.length;

    return ListTile(
      leading: poster != null
          ? ClipRRect(borderRadius: BorderRadius.circular(4),
              child: Image.network(poster, width: 48, height: 72, fit: BoxFit.cover))
          : const SizedBox(width: 48, height: 72, child: Icon(Icons.movie)),
      title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (entry.year != null) '${entry.year}',
        entry.mediaType == 'tv' ? 'TV' : 'Movie',
        if (entry.lastWatchedAt != null) DateFormat.yMMMd().format(entry.lastWatchedAt!.toLocal()),
      ].join(' · ')),
      trailing: stars == null
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.star, size: 16, color: Colors.amber),
              const SizedBox(width: 2),
              Text(stars.toStringAsFixed(1)),
            ]),
      onTap: () => context.push('/title/${entry.mediaType}/${entry.tmdbId}'),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center)),
  );
}
