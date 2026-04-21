import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/decision.dart';
import '../../providers/decide_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/include_watched_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../providers/watchlist_provider.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/help_button.dart';
import '../predict/prediction_sheet.dart';

const _decideHelp =
    'Break a tie fast by passing the phone back and forth.\n\n'
    '• Each member independently swipes through candidates (watchlist + top recommendations).\n'
    '• When both have flagged the same title as "want to watch", it pops up as a match.\n'
    '• "None of these — shuffle" rerolls the five candidates from your watchlist + this week\'s trending.\n'
    '• "Surprise me" fishes a random pre-2020 decade for older catalog titles when nothing on screen is grabbing either of you.\n'
    '• Close any time — your progress isn\'t saved.\n\n'
    'Pro tip: use Solo mode first if you want personalised ranking before starting.';

/// Two-person Decide Together flow. Runs pass-and-play on one device.
///
/// Phases map 1:1 to [DecidePhase]; each has its own sub-widget below.
/// Candidate source is the shared watchlist + TMDB trending for now; Phase 7
/// will replace this with Claude-scored per-user recommendations.
class DecideScreen extends ConsumerStatefulWidget {
  const DecideScreen({super.key});

  @override
  ConsumerState<DecideScreen> createState() => _DecideScreenState();
}

class _DecideScreenState extends ConsumerState<DecideScreen> {
  _Members? _members;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null || !mounted) return;
    final members = await _loadMembers(householdId);
    if (!mounted) return;
    setState(() => _members = members);
  }

  Future<_Members> _loadMembers(String householdId) async {
    final snap = await FirebaseFirestore.instance
        .collection('households/$householdId/members')
        .get();
    final me = FirebaseAuth.instance.currentUser?.uid;
    final docs = snap.docs.toList();
    // Order so the current user is always "A" — makes pass-and-play copy
    // ("Pass to <partner>") read naturally on their own device.
    docs.sort((a, b) {
      if (a.id == me) return -1;
      if (b.id == me) return 1;
      return 0;
    });
    return _Members(
      a: _Member(
        uid: docs.isNotEmpty ? docs[0].id : '',
        displayName: docs.isNotEmpty
            ? (docs[0].data()['display_name'] as String? ?? 'You')
            : 'You',
      ),
      b: docs.length >= 2
          ? _Member(
              uid: docs[1].id,
              displayName:
                  docs[1].data()['display_name'] as String? ?? 'Partner',
            )
          : null,
    );
  }

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    // Candidate pool follows the visibility rules for the current mode:
    // Together excludes all solo items; Solo keeps my own solo items.
    final watchlist = ref.read(visibleWatchlistProvider);
    // Unless the user explicitly opted in via the Home filter, skip anything
    // the household has already watched — Decide is almost always "what
    // should we watch tonight?", not a rewatch picker.
    final includeWatched = ref.read(includeWatchedProvider);
    final watchedKeys = includeWatched
        ? const <String>{}
        : ref.read(watchedKeysProvider);
    await ref
        .read(decideSessionProvider.notifier)
        .start(watchlist, watchedKeys: watchedKeys);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(decideSessionProvider);
    ref.listen(watchlistProvider, (_, _) => _ensureStarted());
    _ensureStarted();

    final members = _members;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            ref.read(decideSessionProvider.notifier).reset();
            context.pop();
          },
        ),
        title: const Text('Decide Together'),
        actions: const [HelpButton(title: 'Decide Together', body: _decideHelp)],
      ),
      body: members == null
          ? const Center(child: CircularProgressIndicator())
          : _PhaseView(session: session, members: members),
    );
  }
}

class _PhaseView extends ConsumerWidget {
  final DecideSessionState session;
  final _Members members;

  const _PhaseView({required this.session, required this.members});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (session.phase) {
      case DecidePhase.loading:
        return const Center(child: CircularProgressIndicator());
      case DecidePhase.negotiate:
        return _Negotiate(session: session, members: members);
      case DecidePhase.pick:
        return _Pick(session: session, members: members);
      case DecidePhase.compromise:
        return _Compromise(session: session, members: members);
      case DecidePhase.tiebreak:
        return _Tiebreak(session: session, members: members);
      case DecidePhase.decided:
        return _Decided(session: session, members: members);
    }
  }
}

// ── Negotiate ───────────────────────────────────────────────────────────────

class _Negotiate extends ConsumerStatefulWidget {
  final DecideSessionState session;
  final _Members members;
  const _Negotiate({required this.session, required this.members});

  @override
  ConsumerState<_Negotiate> createState() => _NegotiateState();
}

class _NegotiateState extends ConsumerState<_Negotiate> {
  bool _shuffling = false;
  bool _surprising = false;

  Future<void> _shuffle() async {
    setState(() => _shuffling = true);
    try {
      final watchlist = ref.read(visibleWatchlistProvider);
      final includeWatched = ref.read(includeWatchedProvider);
      final watchedKeys =
          includeWatched ? const <String>{} : ref.read(watchedKeysProvider);
      await ref
          .read(decideSessionProvider.notifier)
          .rerollCandidates(watchlist, watchedKeys: watchedKeys);
    } finally {
      if (mounted) setState(() => _shuffling = false);
    }
  }

  Future<void> _surprise() async {
    setState(() => _surprising = true);
    try {
      final includeWatched = ref.read(includeWatchedProvider);
      final watchedKeys =
          includeWatched ? const <String>{} : ref.read(watchedKeysProvider);
      await ref
          .read(decideSessionProvider.notifier)
          .rerollExploratory(watchedKeys: watchedKeys);
    } finally {
      if (mounted) setState(() => _surprising = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    if (session.candidates.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text(
              'No candidates yet — add a few titles to your watchlist first.'),
        ),
      );
    }
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Text("Tonight's candidates",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Both agree? Tap "Match". Otherwise, pick separately.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: session.candidates.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = session.candidates[i];
              return _CandidateTile(
                candidate: c,
                trailing: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: _shuffling
                      ? null
                      : () => ref
                          .read(decideSessionProvider.notifier)
                          .instantMatch(c),
                  child: const Text('Match'),
                ),
              );
            },
          ),
        ),
        if (session.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              session.error!,
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: FilledButton(
            onPressed: (_shuffling || _surprising)
                ? null
                : () => ref
                    .read(decideSessionProvider.notifier)
                    .proceedToPick(),
            child: const Text("Can't agree — pick separately"),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      (_shuffling || _surprising) ? null : _shuffle,
                  icon: _shuffling
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.casino_outlined, size: 18),
                  label: const Text('Shuffle'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      (_shuffling || _surprising) ? null : _surprise,
                  icon: _surprising
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('Surprise me'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Pick (pass-and-play) ────────────────────────────────────────────────────

class _Pick extends ConsumerStatefulWidget {
  final DecideSessionState session;
  final _Members members;
  const _Pick({required this.session, required this.members});

  @override
  ConsumerState<_Pick> createState() => _PickState();
}

class _PickState extends ConsumerState<_Pick> {
  bool _handedOff = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final whoseTurn = session.pickA == null
        ? widget.members.a
        : widget.members.b ?? widget.members.a;
    final isAPhase = session.pickA == null;

    if (session.pickA != null && !_handedOff) {
      return _PassOff(
        to: widget.members.b?.displayName ?? 'Partner',
        onReady: () => setState(() => _handedOff = true),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
          child: Text('${whoseTurn.displayName}, pick your favorite',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Your partner won\'t see this until both pick.',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: session.candidates.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = session.candidates[i];
              return _CandidateTile(
                candidate: c,
                trailing: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () {
                    final ctrl = ref.read(decideSessionProvider.notifier);
                    if (isAPhase) {
                      ctrl.submitPickA(c);
                    } else {
                      ctrl.submitPickB(c);
                    }
                    _handedOff = false;
                  },
                  child: const Text('Pick'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PassOff extends StatelessWidget {
  final String to;
  final VoidCallback onReady;
  const _PassOff({required this.to, required this.onReady});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sync_alt, size: 64),
            const SizedBox(height: 16),
            Text('Pass the phone to $to',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: onReady,
                child: Text("I'm $to — ready")),
          ],
        ),
      ),
    );
  }
}

// ── Compromise ──────────────────────────────────────────────────────────────

class _Compromise extends ConsumerStatefulWidget {
  final DecideSessionState session;
  final _Members members;
  const _Compromise({required this.session, required this.members});

  @override
  ConsumerState<_Compromise> createState() => _CompromiseState();
}

class _CompromiseState extends ConsumerState<_Compromise> {
  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final c = session.currentCompromise;
    if (c == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final vetoesLeftA = 2 - session.vetoesA;
    final vetoesLeftB = 2 - session.vetoesB;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('Compromise pick',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'A title both of your tastes point toward. Watch it, or veto.',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
          _CandidateCard(candidate: c),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () =>
                ref.read(decideSessionProvider.notifier).acceptCompromise(),
            child: const Text("Let's watch this"),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: vetoesLeftA > 0
                      ? () => ref
                          .read(decideSessionProvider.notifier)
                          .veto(userIsA: true)
                      : null,
                  child: Text(
                      '${widget.members.a.displayName} veto ($vetoesLeftA left)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.members.b != null && vetoesLeftB > 0
                      ? () => ref
                          .read(decideSessionProvider.notifier)
                          .veto(userIsA: false)
                      : null,
                  child: Text(
                      '${widget.members.b?.displayName ?? '-'} veto ($vetoesLeftB left)'),
                ),
              ),
            ],
          ),
          if (session.error != null) ...[
            const SizedBox(height: 12),
            Text(session.error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

// ── Tiebreak ────────────────────────────────────────────────────────────────

class _Tiebreak extends ConsumerStatefulWidget {
  final DecideSessionState session;
  final _Members members;
  const _Tiebreak({required this.session, required this.members});

  @override
  ConsumerState<_Tiebreak> createState() => _TiebreakState();
}

class _TiebreakState extends ConsumerState<_Tiebreak> {
  _Member? _tieWinner;
  DecideCandidate? _winnerPick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null || !mounted) return;
    final whose =
        await ref.read(decideServiceProvider).readWhoseTurn(householdId);
    final a = widget.members.a;
    final b = widget.members.b;
    if (b == null) {
      setState(() {
        _tieWinner = a;
        _winnerPick = widget.session.pickA ?? widget.session.currentCompromise;
      });
      return;
    }
    // Spec: "tiebreaker to person with fewer lifetime wins" — that person
    // picks (i.e., wins this session).
    final aWins = whose[a.uid] ?? 0;
    final bWins = whose[b.uid] ?? 0;
    final winner = aWins <= bWins ? a : b;
    final winnerPick = winner.uid == a.uid
        ? widget.session.pickA
        : widget.session.pickB;
    setState(() {
      _tieWinner = winner;
      _winnerPick = winnerPick ?? widget.session.currentCompromise;
    });
  }

  @override
  Widget build(BuildContext context) {
    final winner = _tieWinner;
    final pick = _winnerPick;
    if (winner == null || pick == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.emoji_events_outlined, size: 36),
          const SizedBox(height: 8),
          Text('Tiebreak — ${winner.displayName} picks',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          const Text('Fewest lifetime wins in this household.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 16),
          _CandidateCard(candidate: pick),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => ref
                .read(decideSessionProvider.notifier)
                .resolveTiebreak(pick),
            child: const Text("Let's watch it"),
          ),
        ],
      ),
    );
  }
}

// ── Decided ─────────────────────────────────────────────────────────────────

class _Decided extends ConsumerStatefulWidget {
  final DecideSessionState session;
  final _Members members;
  const _Decided({required this.session, required this.members});

  @override
  ConsumerState<_Decided> createState() => _DecidedState();
}

class _DecidedState extends ConsumerState<_Decided> {
  bool _saving = false;
  bool _saved = false;
  bool _rerolling = false;

  @override
  Widget build(BuildContext context) {
    final winner = widget.session.winner;
    if (winner == null) {
      return const Center(child: Text('No winner?'));
    }
    final error = widget.session.error;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.movie_filter, size: 36),
          const SizedBox(height: 8),
          const Text("Tonight's pick",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _WinnerSummary(candidate: winner),
          const SizedBox(height: 16),
          if (!_saved) ...[
            FilledButton(
              onPressed: (_saving || _rerolling) ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save decision'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: (_saving || _rerolling) ? null : _reroll,
              icon: _rerolling
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.casino_outlined),
              label: const Text('Reroll'),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            ],
          ] else ...[
            const Center(child: Text('Saved!')),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => PredictionSheet.show(
                context,
                mediaType: winner.mediaType,
                tmdbId: winner.tmdbId,
                title: winner.title,
                posterPath: winner.posterPath,
              ),
              child: const Text('Predict your rating'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () {
                ref.read(decideSessionProvider.notifier).reset();
                context.pop();
              },
              child: const Text('Done'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _reroll() async {
    setState(() => _rerolling = true);
    try {
      await ref.read(decideSessionProvider.notifier).reroll();
    } finally {
      if (mounted) setState(() => _rerolling = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) {
        throw Exception('No household');
      }
      final winner = widget.session.winner!;
      final s = widget.session;

      final picks = <String, DecisionPick>{};
      if (s.pickA != null) {
        picks[widget.members.a.uid] = DecisionPick(
          uid: widget.members.a.uid,
          mediaType: s.pickA!.mediaType,
          tmdbId: s.pickA!.tmdbId,
          title: s.pickA!.title,
          posterPath: s.pickA!.posterPath,
        );
      }
      if (s.pickB != null && widget.members.b != null) {
        picks[widget.members.b!.uid] = DecisionPick(
          uid: widget.members.b!.uid,
          mediaType: s.pickB!.mediaType,
          tmdbId: s.pickB!.tmdbId,
          title: s.pickB!.title,
          posterPath: s.pickB!.posterPath,
        );
      }

      final decision = Decision(
        id: '',
        winnerMediaType: winner.mediaType,
        winnerTmdbId: winner.tmdbId,
        winnerTitle: winner.title,
        winnerPosterPath: winner.posterPath,
        picks: picks,
        vetoes: const [],
        wasCompromise: s.wasCompromise,
        wasTiebreak: s.wasTiebreak,
        decidedAt: DateTime.now(),
      );

      // Winner uid for gamification bump: whoever's pick matched the winner,
      // else the first member (when an Instant Match happened there are no
      // distinct picks, so just credit A).
      String winnerUid = widget.members.a.uid;
      if (s.pickB != null && widget.members.b != null &&
          s.pickB!.key == winner.key) {
        winnerUid = widget.members.b!.uid;
      }

      await ref.read(decideServiceProvider).recordDecision(
            householdId,
            decision,
            winnerUid: winnerUid,
            loserUid: widget.members.b?.uid,
          );
      if (mounted) setState(() => _saved = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
        setState(() => _saving = false);
      }
    }
  }
}

// ── Shared widgets ──────────────────────────────────────────────────────────

class _CandidateTile extends StatelessWidget {
  final DecideCandidate candidate;
  final Widget trailing;
  const _CandidateTile({required this.candidate, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(candidate.posterPath, size: 'w185');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: poster != null
                ? Image.network(poster,
                    width: 40,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                        width: 40, height: 60, child: Icon(Icons.movie)))
                : const SizedBox(
                    width: 40, height: 60, child: Icon(Icons.movie)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(candidate.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  [
                    if (candidate.year != null) '${candidate.year}',
                    candidate.source,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}

class _WinnerSummary extends StatelessWidget {
  final DecideCandidate candidate;
  const _WinnerSummary({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(candidate.posterPath, size: 'w342');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: poster != null
              ? Image.network(poster,
                  width: 80,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                      width: 80, height: 120, child: Icon(Icons.movie, size: 40)))
              : const SizedBox(
                  width: 80, height: 120, child: Icon(Icons.movie, size: 40)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(candidate.title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              if (candidate.year != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${candidate.year}'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CandidateCard extends StatelessWidget {
  final DecideCandidate candidate;
  const _CandidateCard({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final poster = TmdbService.imageUrl(candidate.posterPath, size: 'w342');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: poster != null
              ? Image.network(poster,
                  width: 120,
                  height: 180,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                      width: 120,
                      height: 180,
                      child: Icon(Icons.movie, size: 48)))
              : const SizedBox(
                  width: 120, height: 180, child: Icon(Icons.movie, size: 48)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(candidate.title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              if (candidate.year != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${candidate.year}'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Local value types ───────────────────────────────────────────────────────

class _Member {
  final String uid;
  final String displayName;
  const _Member({required this.uid, required this.displayName});
}

class _Members {
  final _Member a;
  final _Member? b;
  const _Members({required this.a, this.b});
}
