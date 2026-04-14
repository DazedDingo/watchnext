import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/household_provider.dart';
import '../../providers/ratings_provider.dart';

/// Bottom-sheet rating flow. Works at movie/show/season/episode level.
/// Caller passes trakt ids + (for TV) season/episode so we can push to Trakt.
class RatingSheet extends ConsumerStatefulWidget {
  final String level; // 'movie' | 'show' | 'season' | 'episode'
  final String targetId;
  final String title;
  final String? posterPath;
  final int? traktId;
  final int? season;
  final int? episode;
  final int? initialStars;
  final List<String>? initialTags;
  final String? initialNote;

  const RatingSheet({
    super.key,
    required this.level,
    required this.targetId,
    required this.title,
    this.posterPath,
    this.traktId,
    this.season,
    this.episode,
    this.initialStars,
    this.initialTags,
    this.initialNote,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String level,
    required String targetId,
    required String title,
    String? posterPath,
    int? traktId,
    int? season,
    int? episode,
    int? initialStars,
    List<String>? initialTags,
    String? initialNote,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RatingSheet(
        level: level,
        targetId: targetId,
        title: title,
        posterPath: posterPath,
        traktId: traktId,
        season: season,
        episode: episode,
        initialStars: initialStars,
        initialTags: initialTags,
        initialNote: initialNote,
      ),
    );
  }

  @override
  ConsumerState<RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends ConsumerState<RatingSheet> {
  static const _tagOptions = [
    'funny', 'slow', 'beautiful', 'overhyped', 'intense', 'cozy', 'confusing', 'rewatchable',
  ];

  late int _stars = widget.initialStars ?? 0;
  late final Set<String> _selectedTags = {...?widget.initialTags};
  late final TextEditingController _noteCtrl = TextEditingController(text: widget.initialNote);
  bool _saving = false;

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_stars == 0) return;
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) throw StateError('No household.');
      await ref.read(ratingServiceProvider).save(
            householdId: householdId,
            uid: uid,
            level: widget.level,
            targetId: widget.targetId,
            stars: _stars,
            tags: _selectedTags.toList(),
            note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
            traktId: widget.traktId,
            season: widget.season,
            episode: widget.episode,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(_levelLabel(), style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 20),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(5, (i) {
                final star = i + 1;
                return IconButton(
                  iconSize: 40,
                  icon: Icon(star <= _stars ? Icons.star : Icons.star_border),
                  color: star <= _stars ? Colors.amber : null,
                  onPressed: () => setState(() => _stars = star),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
          Text('Tags (optional)', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: -6,
            children: _tagOptions.map((t) => FilterChip(
              label: Text(t),
              selected: _selectedTags.contains(t),
              onSelected: (v) => setState(() => v ? _selectedTags.add(t) : _selectedTags.remove(t)),
            )).toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteCtrl,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
            maxLength: 140,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: (_stars == 0 || _saving) ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save rating'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _levelLabel() {
    switch (widget.level) {
      case 'movie': return 'Rating the movie';
      case 'show': return 'Rating the show';
      case 'season': return 'Rating season ${widget.season}';
      case 'episode': return 'Rating S${widget.season}E${widget.episode}';
      default: return widget.level;
    }
  }
}
