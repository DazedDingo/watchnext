import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/recommendation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/mood_provider.dart';
import '../../providers/recommendations_provider.dart';
import '../../screens/concierge/concierge_sheet.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/mode_toggle.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // IDs dismissed via "Not tonight" — local per-session, not persisted.
  final _dismissed = <String>{};

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(viewModeProvider);
    final mood = ref.watch(moodProvider);
    final uid = ref.watch(authStateProvider).value?.uid;
    final effectiveUid = mode == ViewMode.solo ? uid : null;

    final recs = ref.watch(recommendationsProvider).value ?? const [];

    // Mood filter — if no mood or no genre mapping, show everything.
    final moodGenres = mood?.genres ?? const [];
    final filtered = moodGenres.isEmpty
        ? recs
        : recs.where((r) => r.genres.any(moodGenres.contains)).toList();

    final available =
        filtered.where((r) => !_dismissed.contains(r.id)).toList();

    final tonightsPick = available.isNotEmpty ? available.first : null;
    final listRecs =
        available.length > 1 ? available.sublist(1) : const <Recommendation>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('WatchNext'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: ModeToggle()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => ConciergeSheet.show(context),
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Ask AI'),
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(refreshRecommendationsProvider(true).future),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (mode == ViewMode.together)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: FilledButton.icon(
                  icon: const Icon(Icons.groups),
                  label: const Text('Decide Together'),
                  onPressed: () => context.push('/decide'),
                ),
              ),
            _MoodPills(
              selected: mood,
              onSelect: (m) => ref.read(moodProvider.notifier).state = m,
            ),
            if (tonightsPick != null) ...[
              const _SectionLabel("TONIGHT'S PICK"),
              _TonightsPick(
                rec: tonightsPick,
                uid: effectiveUid,
                onWatch: () => context.push(
                    '/title/${tonightsPick.mediaType}/${tonightsPick.tmdbId}'),
                onNotTonight: () =>
                    setState(() => _dismissed.add(tonightsPick.id)),
              ),
            ],
            if (listRecs.isNotEmpty) ...[
              const _SectionLabel('RECOMMENDED FOR YOU'),
              ...listRecs.map(
                (r) => _RecCard(
                  rec: r,
                  uid: effectiveUid,
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
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Mood pills ───────────────────────────────────────────────────────────────

class _MoodPills extends StatelessWidget {
  final WatchMood? selected;
  final void Function(WatchMood?) onSelect;

  const _MoodPills({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: WatchMood.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final mood = WatchMood.values[i];
          final active = selected == mood;
          return FilterChip(
            label: Text(mood.label),
            selected: active,
            onSelected: (_) => onSelect(active ? null : mood),
          );
        },
      ),
    );
  }
}

// ─── Tonight's Pick hero card ─────────────────────────────────────────────────

class _TonightsPick extends StatelessWidget {
  final Recommendation rec;
  final String? uid;
  final VoidCallback onWatch;
  final VoidCallback onNotTonight;

  const _TonightsPick({
    required this.rec,
    this.uid,
    required this.onWatch,
    required this.onNotTonight,
  });

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(rec.posterPath, size: 'w500');
    final score = rec.scoreFor(uid);
    final blurb = rec.blurbFor(uid);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              alignment: Alignment.bottomLeft,
              children: [
                SizedBox(
                  height: 240,
                  child: poster != null
                      ? Image.network(poster,
                          width: double.infinity, fit: BoxFit.cover)
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

class _RecCard extends StatelessWidget {
  final Recommendation rec;
  final String? uid;
  final VoidCallback onTap;

  const _RecCard({required this.rec, this.uid, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(rec.posterPath, size: 'w185');
    final score = rec.scoreFor(uid);
    final blurb = rec.blurbFor(uid);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: poster != null
            ? Image.network(poster,
                width: 52, height: 78, fit: BoxFit.cover)
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
