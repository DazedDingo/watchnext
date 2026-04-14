import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/household_provider.dart';
import '../../providers/prediction_provider.dart';

/// Bottom sheet where a user predicts their rating before watching.
/// Predictions are hidden from the partner until both submit (or skip).
class PredictionSheet extends ConsumerStatefulWidget {
  final String mediaType;
  final int tmdbId;
  final String title;
  final String? posterPath;

  const PredictionSheet({
    super.key,
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.posterPath,
  });

  /// Returns true if the user submitted a star prediction (not skipped).
  static Future<bool?> show(
    BuildContext context, {
    required String mediaType,
    required int tmdbId,
    required String title,
    String? posterPath,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PredictionSheet(
        mediaType: mediaType,
        tmdbId: tmdbId,
        title: title,
        posterPath: posterPath,
      ),
    );
  }

  @override
  ConsumerState<PredictionSheet> createState() => _PredictionSheetState();
}

class _PredictionSheetState extends ConsumerState<PredictionSheet> {
  int _stars = 0;
  bool _saving = false;

  Future<void> _submit() async {
    if (_stars == 0) return;
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw StateError('Not signed in.');
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) throw StateError('No household.');
      await ref.read(predictionServiceProvider).submitPrediction(
            householdId: householdId,
            uid: uid,
            mediaType: widget.mediaType,
            tmdbId: widget.tmdbId,
            title: widget.title,
            posterPath: widget.posterPath,
            stars: _stars,
          );
      if (mounted) context.pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _skip() async {
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw StateError('Not signed in.');
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) throw StateError('No household.');
      await ref.read(predictionServiceProvider).skipPrediction(
            householdId: householdId,
            uid: uid,
            mediaType: widget.mediaType,
            tmdbId: widget.tmdbId,
            title: widget.title,
            posterPath: widget.posterPath,
          );
      if (mounted) context.pop(false);
    } catch (_) {
      if (mounted) context.pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Predict your rating',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            widget.title,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.white70),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            "Your partner won't see this until you both predict.",
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final star = i + 1;
              return IconButton(
                iconSize: 44,
                icon: Icon(star <= _stars ? Icons.star : Icons.star_border),
                color: star <= _stars ? Colors.amber : null,
                onPressed: () => setState(() => _stars = star),
              );
            }),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : _skip,
                  child: const Text('Skip'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: (_stars == 0 || _saving) ? null : _submit,
                  child: _saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Predict'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
