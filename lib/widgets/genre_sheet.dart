import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/genre_filter_provider.dart';
import '../providers/mode_provider.dart';

/// Full-list multi-select over every TMDB genre (movie + TV union, deduped
/// and alphabetised). Writes land on `modeGenreProvider` immediately so the
/// home-screen filter reacts while the sheet is still open. "Done" dismisses,
/// "Clear all" resets the mode's set to empty.
class GenreSheet extends ConsumerWidget {
  final ViewMode mode;
  const GenreSheet({super.key, required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(allGenresProvider);
    final selected = ref.watch(selectedGenresProvider);
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
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => ref.read(modeGenreProvider.notifier).clear(mode),
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
                        onSelected: (_) => ref
                            .read(modeGenreProvider.notifier)
                            .toggle(mode, g),
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
