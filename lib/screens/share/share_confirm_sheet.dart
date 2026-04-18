import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/household_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/share_parser.dart';
import '../../services/tmdb_service.dart';

/// Bottom sheet shown after the Android share-sheet resolves a URL/text to
/// a TMDB title. Two states: resolving (spinner) and resolved (poster card
/// + "Add to Watchlist"). A null match shows a "couldn't find it" message.
class ShareConfirmSheet {
  static Future<void> show(BuildContext context, {required Future<ShareMatch?> future}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _Sheet(future: future),
    );
  }
}

class _Sheet extends ConsumerStatefulWidget {
  const _Sheet({required this.future});
  final Future<ShareMatch?> future;

  @override
  ConsumerState<_Sheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<_Sheet> {
  bool _saving = false;
  // Null until the first build reads viewModeProvider; user can override
  // before saving. Stays non-null once set.
  ViewMode? _scope;

  @override
  Widget build(BuildContext context) {
    final ViewMode scope = _scope ?? ref.watch(viewModeProvider);
    return FutureBuilder<ShareMatch?>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError || snap.data == null) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.help_outline, size: 48),
                const SizedBox(height: 12),
                const Text("Couldn't find a match", style: TextStyle(fontSize: 18)),
                const SizedBox(height: 6),
                Text(
                  snap.hasError ? '${snap.error}' : 'Try sharing a direct IMDb, Letterboxd, or TMDB link.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: () => context.pop(), child: const Text('Close')),
              ],
            ),
          );
        }
        return _ResolvedBody(
          match: snap.data!,
          saving: _saving,
          scope: scope,
          onScopeChanged: (s) => setState(() => _scope = s),
          onSave: (m) => _save(m, scope),
        );
      },
    );
  }

  Future<void> _save(ShareMatch m, ViewMode scope) async {
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final householdId = await ref.read(householdIdProvider.future);
      if (uid == null || householdId == null) throw StateError('Not signed in or no household');
      final scopeStr = scope == ViewMode.solo ? 'solo' : 'shared';
      await ref.read(watchlistServiceProvider).add(
            householdId: householdId,
            uid: uid,
            mediaType: m.mediaType,
            tmdbId: m.tmdbId,
            title: m.title,
            year: m.year,
            posterPath: m.posterPath,
            overview: m.overview,
            addedSource: 'share_sheet',
            scope: scopeStr,
          );
      if (!mounted) return;
      context.pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(scope == ViewMode.solo
            ? 'Added "${m.title}" to your Solo list'
            : 'Added "${m.title}" to shared watchlist')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _ResolvedBody extends StatelessWidget {
  const _ResolvedBody({
    required this.match,
    required this.saving,
    required this.scope,
    required this.onScopeChanged,
    required this.onSave,
  });
  final ShareMatch match;
  final bool saving;
  final ViewMode scope;
  final ValueChanged<ViewMode> onScopeChanged;
  final Future<void> Function(ShareMatch) onSave;

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(match.posterPath, size: 'w342');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: poster != null
                  ? Image.network(poster, width: 92, height: 138, fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(width: 92, height: 138, color: Colors.grey.shade800, child: const Icon(Icons.movie)))
                  : Container(width: 92, height: 138, color: Colors.grey.shade800, child: const Icon(Icons.movie)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(match.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text([
                  if (match.year != null) '${match.year}',
                  match.mediaType == 'tv' ? 'TV' : 'Movie',
                ].join(' · '), style: const TextStyle(color: Colors.white70)),
                if (match.overview != null && match.overview!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(match.overview!, maxLines: 5, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white60)),
                ],
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Center(
            child: SegmentedButton<ViewMode>(
              segments: const [
                ButtonSegment(
                  value: ViewMode.together,
                  label: Text('Shared'),
                  icon: Icon(Icons.people_outline),
                ),
                ButtonSegment(
                  value: ViewMode.solo,
                  label: Text('Solo'),
                  icon: Icon(Icons.person_outline),
                ),
              ],
              selected: {scope},
              onSelectionChanged: (s) => onScopeChanged(s.first),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined),
            label: Text(saving
                ? 'Adding…'
                : scope == ViewMode.solo ? 'Add to Solo list' : 'Add to shared watchlist'),
            onPressed: saving ? null : () => onSave(match),
          ),
        ],
      ),
    );
  }
}
