import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mode_provider.dart';

/// Compact segmented control for Solo | Together. Lives in the Home +
/// Discover AppBars. Recommendation engines (Phase 7) read the active mode
/// to pick between `match_score_solo` and `match_score`.
class ModeToggle extends ConsumerWidget {
  const ModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(viewModeProvider);
    return SegmentedButton<ViewMode>(
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: ViewMode.solo, label: Text('Solo')),
        ButtonSegment(value: ViewMode.together, label: Text('Together')),
      ],
      selected: {mode},
      onSelectionChanged: (s) => ref.read(viewModeProvider.notifier).set(s.first),
    );
  }
}
