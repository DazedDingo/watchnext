import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/household_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../services/tmdb_service.dart';
import '../../utils/onboarding_seeds.dart';
import '../../widgets/watchnext_logo.dart';

/// First-run onboarding: a poster grid of curated titles. Tap a poster
/// to rate it 1–5 (or skip). The "Done" button flips the local prefs
/// flag so the Home screen stops showing this gate.
///
/// Ratings are written with `context: null` so they seed both the Solo
/// and Together taste profiles as shared backdrop — we can't know which
/// context the user was thinking of during onboarding, and treating
/// them as shared keeps the engine conservative.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  // Local state: which seeds the user has tapped through. Persisted to
  // Firestore via the rating service as they go; this map just drives
  // the "picked" chip on the grid so the UI stays responsive.
  final _picked = <int, int>{}; // tmdbId → stars (1–5)

  bool _saving = false;

  int get _ratedCount => _picked.length;

  Future<void> _rate(OnboardingSeed seed) async {
    final stars = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => _StarPickerSheet(
        title: seed.title,
        year: seed.year,
        initialStars: _picked[seed.tmdbId],
      ),
    );
    if (stars == null) return; // dismissed
    if (stars == 0) {
      // "Haven't seen it" — remove from picked set.
      setState(() => _picked.remove(seed.tmdbId));
      return;
    }

    setState(() => _picked[seed.tmdbId] = stars);

    // Fire-and-forget: write to /ratings. Failures (offline, household
    // not yet ready) just leave the UI chip — the user can tap again.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final hh = await ref.read(householdIdProvider.future);
    if (uid == null || hh == null) return;

    unawaited(ref.read(ratingServiceProvider).save(
          householdId: hh,
          uid: uid,
          level: seed.mediaType == 'movie' ? 'movie' : 'show',
          targetId: '${seed.tmdbId}',
          stars: stars,
          context: null,
        ));
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    await ref.read(onboardingDoneProvider.notifier).markDone();
    if (!mounted) return;
    // Home rebuilds next frame and sees the flag, so just pop-like
    // dismissal isn't needed — but clear the state for hygiene.
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const WatchNextLogo(),
        centerTitle: false,
        actions: [
          TextButton(
            onPressed: _saving ? null : _finish,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A few quick ratings to calibrate',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap any you\'ve seen and rate them 1–5. Skip the rest. '
                  'The more we know about what you love, the better Tonight\'s Pick gets.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white54,
                      ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 2 / 3.4, // poster + tiny label strip
              ),
              itemCount: kOnboardingSeeds.length,
              itemBuilder: (_, i) {
                final seed = kOnboardingSeeds[i];
                final stars = _picked[seed.tmdbId];
                return _PosterTile(
                  seed: seed,
                  stars: stars,
                  onTap: () => _rate(seed),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Text(
                    _ratedCount == 0
                        ? 'No ratings yet'
                        : '$_ratedCount rated',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _saving ? null : _finish,
                    child: Text(_ratedCount == 0 ? 'Skip for now' : 'Done'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterTile extends StatelessWidget {
  final OnboardingSeed seed;
  final int? stars;
  final VoidCallback onTap;

  const _PosterTile({
    required this.seed,
    required this.stars,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(seed.posterPath, size: 'w342');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (poster != null)
              Image.network(poster, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                        color: Colors.grey.shade900,
                        child: const Center(
                            child: Icon(Icons.movie, color: Colors.white24)),
                      ))
            else
              Container(
                color: Colors.grey.shade900,
                child: const Center(
                    child: Icon(Icons.movie, color: Colors.white24)),
              ),
            // Dim + title strip at bottom for legibility.
            Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      seed.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${seed.year}',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
            if (stars != null)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star_rounded,
                          size: 12, color: Colors.white),
                      const SizedBox(width: 2),
                      Text('$stars',
                          style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Simple 1–5 picker. "Haven't seen it" returns 0 so the caller can
/// clear any previously-set stars. Dismissing the sheet returns null,
/// which the caller treats as a no-op (user changed their mind).
class _StarPickerSheet extends StatefulWidget {
  final String title;
  final int year;
  final int? initialStars;

  const _StarPickerSheet({
    required this.title,
    required this.year,
    this.initialStars,
  });

  @override
  State<_StarPickerSheet> createState() => _StarPickerSheetState();
}

class _StarPickerSheetState extends State<_StarPickerSheet> {
  int _stars = 0;

  @override
  void initState() {
    super.initState();
    _stars = widget.initialStars ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                style: Theme.of(context).textTheme.titleMedium),
            Text('${widget.year}',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    iconSize: 36,
                    onPressed: () => setState(() => _stars = i),
                    icon: Icon(
                      i <= _stars ? Icons.star_rounded : Icons.star_border_rounded,
                      color: Colors.amber,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, 0),
                  child: const Text("Haven't seen it"),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _stars == 0
                      ? null
                      : () => Navigator.pop(context, _stars),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
