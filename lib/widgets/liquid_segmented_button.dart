import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One option in a [LiquidSegmentedButton].
class LiquidSegment<T> {
  final T value;
  final String label;
  final IconData? icon;
  const LiquidSegment({required this.value, required this.label, this.icon});
}

/// Vertical size preset for [LiquidSegmentedButton]. `compact` matches the
/// sizing used by the home filter-panel's runtime/sort segments; `standard`
/// matches the media-type bar and mode toggle.
enum LiquidSegmentDensity {
  compact(height: 34, fontSize: 12, iconSize: 16),
  standard(height: 40, fontSize: 13, iconSize: 18);

  final double height;
  final double fontSize;
  final double iconSize;
  const LiquidSegmentDensity({
    required this.height,
    required this.fontSize,
    required this.iconSize,
  });
}

/// Sibling of [LiquidNavBar] for inline selectors. Replaces M3's
/// `SegmentedButton` with a track + sliding gradient "blob" whose styling
/// matches the nav bar's selector (accent gradient, soft shadow). Equal-width
/// segments, haptics on selection, and an `AnimatedPositioned` indicator that
/// slides under the selected label.
class LiquidSegmentedButton<T> extends StatelessWidget {
  final List<LiquidSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final LiquidSegmentDensity density;

  const LiquidSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.density = LiquidSegmentDensity.standard,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selectedIndex = segments.indexWhere((s) => s.value == selected);
    final hasSelection = selectedIndex >= 0;

    return SizedBox(
      height: density.height,
      width: double.infinity,
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(density.height / 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(density.height / 2),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segWidth = constraints.maxWidth / segments.length;
              const inset = 3.0;
              final indicatorLeft =
                  hasSelection ? selectedIndex * segWidth + inset : -segWidth;
              final indicatorWidth = segWidth - inset * 2;

              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    left: indicatorLeft,
                    top: inset,
                    bottom: inset,
                    width: indicatorWidth.clamp(0.0, double.infinity),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: hasSelection ? 1 : 0,
                      child: _SegmentBlob(
                        color: cs.primary,
                        radius: (density.height - inset * 2) / 2,
                      ),
                    ),
                  ),
                  Row(
                    children: List.generate(segments.length, (i) {
                      final s = segments[i];
                      final isSelected = i == selectedIndex;
                      return Expanded(
                        child: InkWell(
                          borderRadius:
                              BorderRadius.circular(density.height / 2),
                          onTap: () {
                            if (s.value == selected) return;
                            HapticFeedback.selectionClick();
                            onChanged(s.value);
                          },
                          splashColor: cs.primary.withValues(alpha: 0.1),
                          highlightColor: cs.primary.withValues(alpha: 0.05),
                          child: Center(
                            child: _SegmentLabel(
                              segment: s,
                              selected: isSelected,
                              density: density,
                              selectedColor: cs.onPrimary,
                              unselectedColor: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SegmentLabel<T> extends StatelessWidget {
  final LiquidSegment<T> segment;
  final bool selected;
  final LiquidSegmentDensity density;
  final Color selectedColor;
  final Color unselectedColor;

  const _SegmentLabel({
    required this.segment,
    required this.selected,
    required this.density,
    required this.selectedColor,
    required this.unselectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    return AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      style: TextStyle(
        fontSize: density.fontSize,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        color: color,
        letterSpacing: 0.1,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (segment.icon != null) ...[
            Icon(segment.icon, size: density.iconSize, color: color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              segment.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentBlob extends StatelessWidget {
  final Color color;
  final double radius;
  const _SegmentBlob({required this.color, required this.radius});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.95),
            color.withValues(alpha: 0.72),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.32),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}
