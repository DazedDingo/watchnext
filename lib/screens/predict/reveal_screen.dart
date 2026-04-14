import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/prediction.dart';
import '../../models/rating.dart';
import '../../providers/household_provider.dart';
import '../../providers/prediction_provider.dart';
import '../../providers/ratings_provider.dart';
import '../../services/tmdb_service.dart';

/// Full-screen reveal showing predicted vs actual ratings side by side.
/// Route: /reveal/:mediaType/:tmdbId
class RevealScreen extends ConsumerStatefulWidget {
  final String mediaType;
  final int tmdbId;

  const RevealScreen({
    super.key,
    required this.mediaType,
    required this.tmdbId,
  });

  @override
  ConsumerState<RevealScreen> createState() => _RevealScreenState();
}

class _RevealScreenState extends ConsumerState<RevealScreen> {
  bool _markedSeen = false;

  String get _predId =>
      '${widget.mediaType}:${widget.tmdbId}';

  Future<void> _markSeen(Prediction prediction, Rating? myRating) async {
    if (_markedSeen) return;
    _markedSeen = true;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null) return;

    // Determine if this user won (closer prediction to actual).
    final myEntry = prediction.entryFor(uid);
    final myPredicted = myEntry?.stars;
    final myActual = myRating?.stars;
    bool won = false;

    if (myPredicted != null && myActual != null) {
      final myDelta = (myPredicted - myActual).abs();
      // Find the best delta among all other non-skipped members.
      final otherDeltas = prediction.entries.entries
          .where((e) => e.key != uid && !e.value.skipped && e.value.stars != null)
          .map((e) {
            // Other member's actual rating
            final ratingLevel = widget.mediaType == 'movie' ? 'movie' : 'show';
            final otherRatings = ref.read(ratingsByTargetProvider)[_predId] ?? [];
            final otherActual = otherRatings
                .cast<Rating?>()
                .firstWhere((r) => r?.uid == e.key && r?.level == ratingLevel,
                    orElse: () => null)
                ?.stars;
            if (otherActual == null) return double.infinity;
            return (e.value.stars! - otherActual).abs().toDouble();
          })
          .toList();

      if (otherDeltas.isNotEmpty) {
        final bestOtherDelta = otherDeltas.reduce((a, b) => a < b ? a : b);
        won = myDelta < bestOtherDelta;
      }
    }

    await ref.read(predictionServiceProvider).markRevealSeen(
          householdId: householdId,
          uid: uid,
          predictionId: _predId,
          won: won,
        );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final prediction = ref.watch(predictionProvider(_predId)).value;
    final ratingsByTarget = ref.watch(ratingsByTargetProvider);
    final ratingLevel = widget.mediaType == 'movie' ? 'movie' : 'show';
    final titleRatings =
        (ratingsByTarget[_predId] ?? const <Rating>[])
            .where((r) => r.level == ratingLevel)
            .toList();

    if (prediction == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final myRating = titleRatings.cast<Rating?>().firstWhere(
          (r) => r?.uid == uid,
          orElse: () => null,
        );

    // Mark seen once we have everything loaded.
    if (myRating != null && !prediction.revealSeenBy(uid ?? '')) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _markSeen(prediction, myRating));
    }

    final poster =
        TmdbService.imageUrl(prediction.posterPath, size: 'w342');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Predict & Rate Reveal'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Poster + title
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (poster != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(poster,
                      width: 80, height: 120, fit: BoxFit.cover),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  prediction.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          // Side-by-side cards for each member who predicted
          _buildComparison(
            context,
            uid: uid,
            prediction: prediction,
            titleRatings: titleRatings,
            ratingLevel: ratingLevel,
          ),
        ],
      ),
    );
  }

  Widget _buildComparison(
    BuildContext context, {
    required String? uid,
    required Prediction prediction,
    required List<Rating> titleRatings,
    required String ratingLevel,
  }) {
    // Build a result row for each member who has a non-skipped prediction.
    final rows = prediction.entries.entries
        .where((e) => !e.value.skipped && e.value.stars != null)
        .map((e) {
      final memberUid = e.key;
      final predicted = e.value.stars!;
      final actual = titleRatings
          .cast<Rating?>()
          .firstWhere(
              (r) => r?.uid == memberUid && r?.level == ratingLevel,
              orElse: () => null)
          ?.stars;
      final delta = actual != null ? (predicted - actual).abs() : null;
      return _MemberResult(
        uid: memberUid,
        isMe: memberUid == uid,
        predicted: predicted,
        actual: actual,
        delta: delta,
      );
    }).toList();

    if (rows.isEmpty) {
      return const Center(
        child: Text('No predictions to reveal.',
            style: TextStyle(color: Colors.white54)),
      );
    }

    // Determine winner (smallest delta, both must have actual rating).
    final withDeltas = rows.where((r) => r.delta != null).toList();
    String? winnerUid;
    if (withDeltas.length >= 2) {
      withDeltas.sort((a, b) => a.delta!.compareTo(b.delta!));
      if (withDeltas[0].delta! < withDeltas[1].delta!) {
        winnerUid = withDeltas[0].uid;
      }
    }

    return Column(
      children: [
        if (rows.length >= 2)
          Row(
            children: rows
                .map((r) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _ResultCard(
                          result: r,
                          isWinner: winnerUid == r.uid,
                        ),
                      ),
                    ))
                .toList(),
          )
        else
          _ResultCard(result: rows.first, isWinner: false),

        if (winnerUid != null) ...[
          const SizedBox(height: 20),
          Text(
            winnerUid == uid ? 'You called it! 🎯' : 'Partner nailed it!',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.amber),
            textAlign: TextAlign.center,
          ),
        ] else if (withDeltas.length >= 2 &&
            withDeltas[0].delta == withDeltas[1].delta) ...[
          const SizedBox(height: 20),
          Text(
            "It's a tie!",
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

class _MemberResult {
  final String uid;
  final bool isMe;
  final int predicted;
  final int? actual;
  final int? delta;

  const _MemberResult({
    required this.uid,
    required this.isMe,
    required this.predicted,
    this.actual,
    this.delta,
  });
}

class _ResultCard extends StatelessWidget {
  final _MemberResult result;
  final bool isWinner;

  const _ResultCard({required this.result, required this.isWinner});

  @override
  Widget build(BuildContext context) {
    final deltaLabel = switch (result.delta) {
      null => 'Waiting...',
      0 => 'Spot on! 🎯',
      1 => 'Off by 1',
      final n => 'Off by $n',
    };

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isWinner
            ? const BorderSide(color: Colors.amber, width: 1.5)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              result.isMe ? 'You' : 'Partner',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 12),
            _StarRow(label: 'Predicted', stars: result.predicted),
            const SizedBox(height: 8),
            _StarRow(
                label: 'Actual',
                stars: result.actual,
                placeholder: '?'),
            const SizedBox(height: 12),
            Text(
              deltaLabel,
              style: TextStyle(
                fontSize: 13,
                color: result.delta == 0 ? Colors.greenAccent : Colors.white70,
                fontWeight: result.delta == 0 ? FontWeight.bold : null,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _StarRow extends StatelessWidget {
  final String label;
  final int? stars;
  final String? placeholder;

  const _StarRow({required this.label, this.stars, this.placeholder});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.white38)),
        const SizedBox(height: 4),
        stars != null
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  return Icon(
                    i < stars! ? Icons.star : Icons.star_border,
                    size: 20,
                    color: i < stars! ? Colors.amber : Colors.white24,
                  );
                }),
              )
            : Text(
                placeholder ?? '—',
                style: const TextStyle(color: Colors.white38),
              ),
      ],
    );
  }
}
