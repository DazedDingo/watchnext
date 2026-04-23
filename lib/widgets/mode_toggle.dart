import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mode_provider.dart';
import 'liquid_segmented_button.dart';

/// Compact segmented control for Solo | Together. Lives in the Home +
/// Discover AppBars. Recommendation engines (Phase 7) read the active mode
/// to pick between `match_score_solo` and `match_score`. Styled to match
/// the nav bar's liquid selector.
class ModeToggle extends ConsumerWidget {
  const ModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(viewModeProvider);
    return SizedBox(
      width: 180,
      child: LiquidSegmentedButton<ViewMode>(
        density: LiquidSegmentDensity.compact,
        selected: mode,
        segments: const [
          LiquidSegment(value: ViewMode.solo, label: 'Solo'),
          LiquidSegment(value: ViewMode.together, label: 'Together'),
        ],
        onChanged: (v) => ref.read(viewModeProvider.notifier).set(v),
      ),
    );
  }
}
