import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/household_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';

class WatchlistScreen extends ConsumerWidget {
  const WatchlistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(watchlistProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: const Text('Watchlist'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Nothing saved yet. Add titles from their detail screen.'),
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
                background: Container(color: Colors.redAccent, alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24), child: const Icon(Icons.delete)),
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
                          child: Image.network(poster, width: 48, height: 72, fit: BoxFit.cover),
                        )
                      : const SizedBox(width: 48, height: 72, child: Icon(Icons.movie)),
                  title: Text(w.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text([if (w.year != null) '${w.year}', if (w.genres.isNotEmpty) w.genres.first].join(' · ')),
                  onTap: () => context.push('/title/${w.mediaType}/${w.tmdbId}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
