import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../providers/stats_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../widgets/async_error.dart';
import '../../widgets/help_button.dart';

const _statsHelp =
    'Stats rolls up everything your household has watched and rated.\n\n'
    '• Watched / Movies / TV Shows — counts across both members.\n'
    '• Runtime — total viewing time where TMDB had runtime data.\n'
    '• Compatibility — how often both members rate the same title within 1 star.\n'
    '• Ratings — per-member star distribution and averages, plus rating streaks.\n'
    '• Top genres — based on what you\'ve actually watched.\n'
    '• Badges — unlock milestones as you watch, rate, and predict.\n'
    '• Predict & Rate — leaderboard for the prediction game.\n\n'
    'Numbers update in real time as you rate and log watches.';

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the underlying streams directly so we can surface errors instead
    // of silently showing a spinner forever when a Firestore listener fails.
    final entriesAsync = ref.watch(watchEntriesProvider);
    final ratingsAsync = ref.watch(ratingsProvider);
    final stats = ref.watch(statsProvider);
    final members = ref.watch(membersProvider).value ?? const [];
    final uid = ref.watch(authStateProvider).value?.uid;

    final error = entriesAsync.hasError
        ? entriesAsync.error
        : (ratingsAsync.hasError ? ratingsAsync.error : null);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats'),
        actions: const [HelpButton(title: 'Stats', body: _statsHelp)],
      ),
      body: error != null
          ? AsyncErrorView(
              error: error,
              onRetry: () {
                ref.invalidate(watchEntriesProvider);
                ref.invalidate(ratingsProvider);
              },
            )
          : stats == null
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _SummaryCards(stats: stats),
                      const SizedBox(height: 16),
                      if (stats.compatibilityPct >= 0) ...[
                        _CompatibilityCard(pct: stats.compatibilityPct),
                        const SizedBox(height: 16),
                      ],
                      _RatingSection(stats: stats, members: members, uid: uid),
                      const SizedBox(height: 16),
                      if (stats.topGenres.isNotEmpty) ...[
                        _GenresCard(genres: stats.topGenres),
                        const SizedBox(height: 16),
                      ],
                      if (stats.badges.isNotEmpty) ...[
                        _BadgesCard(
                            badges: stats.badges,
                            members: members,
                            uid: uid),
                        const SizedBox(height: 16),
                      ],
                      if (members.isNotEmpty &&
                          members.any((m) => m.predictTotal > 0)) ...[
                        _PredictLeaderboard(members: members, uid: uid),
                        const SizedBox(height: 16),
                      ],
                      const SizedBox(height: 24),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Summary cards
// ---------------------------------------------------------------------------

class _SummaryCards extends StatelessWidget {
  final HouseholdStats stats;
  const _SummaryCards({required this.stats});

  String _formatHours(int minutes) {
    if (minutes == 0) return '0h';
    final h = minutes ~/ 60;
    return h >= 24 ? '${h ~/ 24}d ${h % 24}h' : '${h}h';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
            child: _StatCard(
                label: 'Watched',
                value: '${stats.totalTitles}',
                icon: Icons.visibility_outlined)),
        const SizedBox(width: 10),
        Expanded(
            child: _StatCard(
                label: 'Movies',
                value: '${stats.movieCount}',
                icon: Icons.movie_outlined)),
        const SizedBox(width: 10),
        Expanded(
            child: _StatCard(
                label: 'TV Shows',
                value: '${stats.tvCount}',
                icon: Icons.tv_outlined)),
        if (stats.totalMinutes > 0) ...[
          const SizedBox(width: 10),
          Expanded(
              child: _StatCard(
                  label: 'Runtime',
                  value: _formatHours(stats.totalMinutes),
                  icon: Icons.timer_outlined)),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _StatCard(
      {required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        child: Column(
          children: [
            Icon(icon, size: 20, color: cs.primary),
            const SizedBox(height: 4),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Compatibility card
// ---------------------------------------------------------------------------

class _CompatibilityCard extends StatelessWidget {
  final double pct; // 0-1
  const _CompatibilityCard({required this.pct});

  String _label(double p) {
    if (p >= 0.85) return 'Cinematic soulmates';
    if (p >= 0.70) return 'Great taste match';
    if (p >= 0.55) return 'Solid common ground';
    return 'Interesting contrast';
  }

  Color _color(double p) {
    if (p >= 0.85) return Colors.greenAccent;
    if (p >= 0.70) return Colors.lightGreenAccent;
    if (p >= 0.55) return Colors.amber;
    return Colors.orange;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(pct);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('COUPLE COMPATIBILITY',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: Colors.white54)),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  '${(pct * 100).round()}%',
                  style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.bold,
                      color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label(pct),
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      const Text('ratings agree within 1 star',
                          style: TextStyle(
                              fontSize: 12, color: Colors.white54)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: pct,
              color: color,
              backgroundColor: Colors.white10,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rating distribution section
// ---------------------------------------------------------------------------

class _RatingSection extends StatelessWidget {
  final HouseholdStats stats;
  final List<HouseholdMember> members;
  final String? uid;
  const _RatingSection(
      {required this.stats, required this.members, this.uid});

  @override
  Widget build(BuildContext context) {
    if (stats.perUser.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RATINGS',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: Colors.white54)),
            const SizedBox(height: 12),
            ...stats.perUser.entries.map((entry) {
              final member = members.firstWhere(
                (m) => m.uid == entry.key,
                orElse: () => HouseholdMember(
                    uid: entry.key,
                    displayName: entry.key == uid ? 'You' : 'Partner'),
              );
              final isSelf = entry.key == uid;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _UserRatingBars(
                  name: isSelf ? 'You' : member.displayName,
                  stats: entry.value,
                  solo: stats.perUserSolo[entry.key],
                  together: stats.perUserTogether[entry.key],
                  streak: stats.ratingStreaks[entry.key],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _UserRatingBars extends StatelessWidget {
  final String name;
  final UserStats stats;
  /// Solo-only subset of this user's ratings. Only rendered when non-null and
  /// ratedCount > 0 — keeps the card clean for households on legacy data.
  final UserStats? solo;
  /// Together-only subset (same null/empty suppression).
  final UserStats? together;
  /// Consecutive-day rating streak. Null or empty → no chip rendered.
  final RatingStreak? streak;
  const _UserRatingBars({
    required this.name,
    required this.stats,
    this.solo,
    this.together,
    this.streak,
  });

  @override
  Widget build(BuildContext context) {
    final maxCount =
        stats.distribution.values.fold(0, (a, b) => a > b ? a : b);
    final hasSoloData = (solo?.ratedCount ?? 0) > 0;
    final hasTogetherData = (together?.ratedCount ?? 0) > 0;
    final hasStreak =
        streak != null && (streak!.current > 0 || streak!.best > 0);
    final showChipRow = hasSoloData || hasTogetherData || hasStreak;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(
              '${stats.avgRating.toStringAsFixed(1)} avg · ${stats.ratedCount} rated',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
        if (showChipRow) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (hasStreak) _StreakChip(streak: streak!),
              if (hasSoloData)
                _ContextChip(
                  label: 'Solo',
                  avg: solo!.avgRating,
                  count: solo!.ratedCount,
                ),
              if (hasTogetherData)
                _ContextChip(
                  label: 'Together',
                  avg: together!.avgRating,
                  count: together!.ratedCount,
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        for (int s = 5; s >= 1; s--)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text('$s★',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white54)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: LinearProgressIndicator(
                    value: maxCount == 0
                        ? 0
                        : (stats.distribution[s] ?? 0) / maxCount,
                    color: _starColor(s),
                    backgroundColor: Colors.white10,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 24,
                  child: Text(
                    '${stats.distribution[s] ?? 0}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white38),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Color _starColor(int stars) {
    switch (stars) {
      case 5:
        return Colors.greenAccent;
      case 4:
        return Colors.lightGreenAccent;
      case 3:
        return Colors.amber;
      case 2:
        return Colors.orange;
      default:
        return Colors.redAccent;
    }
  }
}

class _StreakChip extends StatelessWidget {
  final RatingStreak streak;
  const _StreakChip({required this.streak});

  @override
  Widget build(BuildContext context) {
    final hot = streak.current >= 3;
    final showBest =
        streak.best > streak.current && streak.best > 1;

    final String label;
    if (streak.current > 0) {
      label = '${hot ? '🔥 ' : ''}${streak.current}-day streak';
    } else {
      label = 'Best: ${streak.best}';
    }
    final extra = showBest ? ' · best ${streak.best}' : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: hot
            ? Colors.deepOrange.withValues(alpha: 0.15)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hot ? Colors.deepOrange : Colors.white12,
          width: 0.5,
        ),
      ),
      child: Text(
        '$label$extra',
        style: TextStyle(
          fontSize: 11,
          color: hot ? Colors.deepOrangeAccent : Colors.white70,
          fontWeight: hot ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}

class _ContextChip extends StatelessWidget {
  final String label;
  final double avg;
  final int count;
  const _ContextChip({
    required this.label,
    required this.avg,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12, width: 0.5),
      ),
      child: Text(
        '$label · ${avg.toStringAsFixed(1)} · $count',
        style: const TextStyle(fontSize: 11, color: Colors.white70),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top genres card
// ---------------------------------------------------------------------------

class _GenresCard extends StatelessWidget {
  final List<({String genre, int count})> genres;
  const _GenresCard({required this.genres});

  @override
  Widget build(BuildContext context) {
    final maxCount = genres.isEmpty ? 1 : genres.first.count;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('TOP GENRES',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: Colors.white54)),
            const SizedBox(height: 12),
            for (final g in genres)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Text(g.genre,
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: g.count / maxCount,
                        color: Theme.of(context).colorScheme.primary,
                        backgroundColor: Colors.white10,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 28,
                      child: Text('${g.count}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white38),
                          textAlign: TextAlign.right),
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

// ---------------------------------------------------------------------------
// Badges card
// ---------------------------------------------------------------------------

class _BadgesCard extends StatelessWidget {
  final List<BadgeDef> badges;
  final List<HouseholdMember> members;
  final String? uid;
  const _BadgesCard(
      {required this.badges, required this.members, this.uid});

  @override
  Widget build(BuildContext context) {
    final earnedCount = badges.where((b) => b.earned).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('BADGES',
                    style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        color: Colors.white54)),
                const Spacer(),
                Text('$earnedCount / ${badges.length}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white54)),
              ],
            ),
            const SizedBox(height: 12),
            for (final b in badges)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _BadgeRow(
                  badge: b,
                  memberLabel: _labelFor(b.memberUid),
                  predictMember: b.memberUid == null
                      ? null
                      : members.firstWhere(
                          (m) => m.uid == b.memberUid,
                          orElse: () => HouseholdMember(
                              uid: b.memberUid!, displayName: 'Member'),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _labelFor(String? memberUid) {
    if (memberUid == null) return null;
    if (memberUid == uid) return 'You';
    final m = members.where((m) => m.uid == memberUid);
    return m.isEmpty ? 'Partner' : m.first.displayName;
  }
}

class _BadgeRow extends StatelessWidget {
  final BadgeDef badge;
  final String? memberLabel;
  /// Only non-null for per-user badges — used to print the accuracy line once
  /// the volume gate is cleared.
  final HouseholdMember? predictMember;
  const _BadgeRow(
      {required this.badge, this.memberLabel, this.predictMember});

  IconData _icon(String key) {
    switch (key) {
      case 'trophy':
        return Icons.emoji_events_outlined;
      case 'explore':
        return Icons.explore_outlined;
      case 'psychology':
        return Icons.psychology_outlined;
      default:
        return Icons.workspace_premium_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = badge.earned ? cs.primary : Colors.white38;
    final title = memberLabel == null
        ? badge.name
        : '${badge.name} · $memberLabel';

    // Prediction Machine: once 20+ predictions exist, swap the progress line
    // from "N/20" to the current accuracy so users see how close they are.
    String? progressLabel;
    if (badge.earned) {
      progressLabel = 'Earned';
    } else if (predictMember != null && predictMember!.predictTotal >= 20) {
      final acc = predictMember!.predictTotal == 0
          ? 0
          : (predictMember!.predictWins /
                  predictMember!.predictTotal *
                  100)
              .round();
      progressLabel = '$acc% accuracy · need 80%';
    } else {
      progressLabel = '${badge.progress} / ${badge.target}';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(_icon(badge.iconKey), size: 26, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: badge.earned ? Colors.white : Colors.white70,
                        )),
                  ),
                  if (badge.earned)
                    Icon(Icons.check_circle,
                        size: 16, color: cs.primary)
                  else
                    Text(progressLabel,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white54)),
                ],
              ),
              const SizedBox(height: 2),
              Text(badge.description,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: badge.progressPct,
                color: color,
                backgroundColor: Colors.white10,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Predict & Rate leaderboard
// ---------------------------------------------------------------------------

class _PredictLeaderboard extends StatelessWidget {
  final List<HouseholdMember> members;
  final String? uid;
  const _PredictLeaderboard({required this.members, this.uid});

  @override
  Widget build(BuildContext context) {
    final sorted = [...members]..sort((a, b) {
        final rateComp = b.predictWinRate.compareTo(a.predictWinRate);
        if (rateComp != 0) return rateComp;
        return b.predictTotal.compareTo(a.predictTotal);
      });

    final leader = sorted.isNotEmpty ? sorted.first : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PREDICT & RATE',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: Colors.white54)),
            const SizedBox(height: 12),
            Row(
              children: members.map((m) {
                final isLeading = leader != null &&
                    m.uid == leader.uid &&
                    m.predictTotal > 0;
                final isSelf = m.uid == uid;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _MemberPredictCard(
                      member: m,
                      name: isSelf ? 'You' : m.displayName,
                      isLeading: isLeading && members.length > 1,
                    ),
                  ),
                );
              }).toList(),
            ),
            if (members.every((m) => m.predictTotal == 0))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Make predictions on title detail pages to start the leaderboard.',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MemberPredictCard extends StatelessWidget {
  final HouseholdMember member;
  final String name;
  final bool isLeading;
  const _MemberPredictCard({
    required this.member,
    required this.name,
    required this.isLeading,
  });

  @override
  Widget build(BuildContext context) {
    final total = member.predictTotal;
    final wins = member.predictWins;
    final pct = total == 0 ? 0 : (wins / total * 100).round();

    final showSplit = member.predictTotalSolo > 0 ||
        member.predictTotalTogether > 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isLeading
            ? Colors.amber.withValues(alpha: 0.1)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLeading ? Colors.amber : Colors.white12,
          width: isLeading ? 1.5 : 0.5,
        ),
      ),
      child: Column(
        children: [
          if (isLeading)
            const Text('👑', style: TextStyle(fontSize: 18))
          else
            const SizedBox(height: 4),
          Text(name,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Text(
            total == 0 ? '—' : '$pct%',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: isLeading ? Colors.amber : Colors.white,
            ),
          ),
          Text(
            total == 0
                ? 'No predictions'
                : '$wins/$total correct',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
            textAlign: TextAlign.center,
          ),
          if (showSplit) ...[
            const SizedBox(height: 8),
            const Divider(height: 1, color: Colors.white12),
            const SizedBox(height: 6),
            _PredictSplitRow(
              label: 'Solo',
              total: member.predictTotalSolo,
              wins: member.predictWinsSolo,
            ),
            const SizedBox(height: 2),
            _PredictSplitRow(
              label: 'Together',
              total: member.predictTotalTogether,
              wins: member.predictWinsTogether,
            ),
          ],
        ],
      ),
    );
  }
}

class _PredictSplitRow extends StatelessWidget {
  final String label;
  final int total;
  final int wins;
  const _PredictSplitRow({
    required this.label,
    required this.total,
    required this.wins,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? null : (wins / total * 100).round();
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style:
                  const TextStyle(fontSize: 11, color: Colors.white54)),
        ),
        Text(
          pct == null ? '—' : '$pct% · $wins/$total',
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      ],
    );
  }
}
