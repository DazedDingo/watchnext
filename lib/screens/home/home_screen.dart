import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/watch_entries_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/mode_toggle.dart';

/// Minimal Home surface until Phase 7 wires Tonight's Pick + mood engine.
/// For now: watchlist summary + recently watched.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchlist = ref.watch(watchlistProvider).value ?? const [];
    final entries = ref.watch(watchEntriesProvider).value ?? const [];
    final recent = entries.take(10).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('WatchNext'),
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ModeToggle()))],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text('Watchlist (${watchlist.length})'),
            subtitle: const Text('Shared queue'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/watchlist'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('RECENTLY WATCHED', style: TextStyle(letterSpacing: 1.2, fontSize: 12)),
          ),
          if (recent.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Link Trakt to import your watch history.', textAlign: TextAlign.center),
            )
          else
            SizedBox(
              height: 180,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: recent.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final e = recent[i];
                  final poster = TmdbService.imageUrl(e.posterPath, size: 'w342');
                  return InkWell(
                    onTap: () => context.push('/title/${e.mediaType}/${e.tmdbId}'),
                    child: SizedBox(
                      width: 110,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: poster != null
                              ? Image.network(poster, width: 110, height: 160, fit: BoxFit.cover)
                              : Container(
                                  width: 110, height: 160, color: Colors.grey.shade800,
                                  child: const Icon(Icons.movie),
                                ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
