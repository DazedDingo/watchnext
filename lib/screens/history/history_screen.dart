import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/episode.dart';
import '../../models/watch_entry.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
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
    final showAsync = ref.watch(unratedQueueProvider);
    final epAsync = ref.watch(unratedEpisodesProvider);
    final householdId = ref.watch(householdIdProvider).value ?? '';

    final shows = showAsync.value ?? const [];
    final epsByEntry = epAsync.value ?? const {};
    final loading = showAsync.isLoading || epAsync.isLoading;

    if (loading) return const Center(child: CircularProgressIndicator());

    if (shows.isEmpty && epsByEntry.isEmpty) {
      return const _Empty(text: 'Caught up! Nothing unrated.');
    }

    // Build a flat item list: show-level items first, then episode groups.
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
                        child: Image.network(poster,
                            width: 48, height: 72, fit: BoxFit.cover))
                    : const SizedBox(
                        width: 48,
                        height: 72,
                        child: Icon(Icons.movie)),
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
              final entryId = mapEntry.key;
              final episodes = mapEntry.value;
              // Derive show title from entryId (tv:tmdbId) — look it up in
              // the watch entries list so we have the poster too.
              return _EpisodeGroup(
                householdId: householdId,
                entryId: entryId,
                episodes: episodes,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}

class _SectionDivider extends StatelessWidget {
  final String label;
  const _SectionDivider(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                color: Colors.white38)),
      );
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
              child: Image.network(poster,
                  width: 40, height: 60, fit: BoxFit.cover))
          : const SizedBox(width: 40, height: 60, child: Icon(Icons.tv)),
      title: Text(showTitle,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${episodes.length} unrated episode${episodes.length == 1 ? '' : 's'}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
          child: const Text('Rate All'),
          onPressed: () => _rateAll(context, showTitle),
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

  void _rateAll(BuildContext context, String showTitle) {
    // Show a bottom sheet with all episodes stacked for quick rating.
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RateAllSheet(
        showTitle: showTitle,
        entryId: entryId,
        episodes: episodes,
        posterPath: null,
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
        final ep = widget.episodes.firstWhere(
            (ep) => ep.id == e.key);
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
      if (mounted) Navigator.of(context).pop();
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
          Text('Rate ${widget.episodes.length} episode${widget.episodes.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.labelMedium),
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
                          star <= current
                              ? Icons.star
                              : Icons.star_border,
                          size: 22,
                          color:
                              star <= current ? Colors.amber : null,
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
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save ratings'),
            ),
          ),
        ],
      ),
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
